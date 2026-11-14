import AppKit
@preconcurrency import AppAuth
import CalendarCore

/// Dayfold identity is independent of Google Calendar authorization. Only an
/// OIDC ID token is exchanged with the configured relay; no calendar token is used.
@MainActor public final class DayfoldAccountAuthorization {
    private var listener: OIDRedirectHTTPHandler?
    private var flow: (any OIDExternalUserAgentSession)?
    private var timeout: Task<Void, Never>?
    private var active = true
    public init() { OAuthTokenTransport.configureAppAuth() }

    public func cancel() {
        active = false; flow?.cancel(); listener?.cancelHTTPListener()
        flow = nil; listener = nil; timeout?.cancel()
    }

    public func signIn(configuration: RelayOIDCConfiguration, session: RelayAccountSession, reauthenticate: Bool = false) async throws -> RelayAccountIdentity {
        do { return try await performSignIn(configuration: configuration, session: session, reauthenticate: reauthenticate) }
        catch {
            // A cancelled browser flow has not submitted enrollment. Release its
            // pause without erasing a recoverable, already-submitted ID token.
            try? await session.cancelUnsubmittedEnrollment()
            throw error
        }
    }

    private func performSignIn(configuration: RelayOIDCConfiguration, session: RelayAccountSession, reauthenticate: Bool) async throws -> RelayAccountIdentity {
        guard active, flow == nil else { throw CancellationError() }
        try configuration.validate()
        _ = try await session.restartExpiredEnrollment()
        if await session.hasPendingEnrollment() { return try await session.recoverEnrollment() }
        let challenge = try await session.beginEnrollment(clientID: configuration.clientID, reauthenticate: reauthenticate)
        guard active else { throw CancellationError() }
        let listener = OIDRedirectHTTPHandler(successURL: nil)
        var listenerError: NSError?
        let redirect = listener.startHTTPListener(&listenerError)
        guard listenerError == nil, ["127.0.0.1", "::1", "[::1]"].contains(redirect.host ?? "") else {
            listener.cancelHTTPListener()
            throw CalendarError.unavailable("Dayfold could not open its sign-in callback. Try again.")
        }
        self.listener = listener
        let service = OIDServiceConfiguration(authorizationEndpoint: configuration.authorizationEndpoint, tokenEndpoint: configuration.tokenEndpoint)
        // AppAuth generates state and an S256 PKCE verifier. Use the server's
        // one-use OIDC nonce explicitly so identity is bound to this device key.
        let request = OIDAuthorizationRequest(configuration: service, clientId: configuration.clientID, scopes: ["openid"],
                                              redirectURL: redirect, responseType: OIDResponseTypeCode, nonce: challenge.nonce,
                                              additionalParameters: ["prompt": "select_account"])
        defer { timeout?.cancel(); listener.cancelHTTPListener(); flow = nil; self.listener = nil }
        let idToken: String = try await withCheckedThrowingContinuation { continuation in
            flow = OIDAuthState.authState(byPresenting: request) { state, _ in
                if let token = state?.lastTokenResponse?.idToken, !token.isEmpty { continuation.resume(returning: token) }
                else { continuation.resume(throwing: CalendarError.unavailable("Dayfold sign-in was cancelled, denied, or expired. Try again.")) }
            }
            listener.currentAuthorizationFlow = flow
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)) }
                catch { return }
                self?.cancel()
            }
        }
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
        return try await session.completeEnrollment(idToken: idToken)
    }
}
