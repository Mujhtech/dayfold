import AppKit
@preconcurrency import AppAuth
import CalendarCore
import Security

public struct OAuthConfiguration: Codable, Sendable {
    public var clientID: String
    public var clientSecret: String?
    public var configured: Bool { clientID.hasSuffix(".apps.googleusercontent.com") }
    public init(clientID: String = "", clientSecret: String? = nil) { self.clientID = clientID; self.clientSecret = clientSecret }
}
public struct AuthorizedIdentity: Sendable {
    public var subject: String
    public var email: String
    public var scopes: Set<String>
    public var archive: Data
}

@MainActor public final class GoogleAuthorization: AccessTokenSource {
    public let configuration: OAuthConfiguration
    private var listener: OIDRedirectHTTPHandler?
    private var flow: (any OIDExternalUserAgentSession)?
    private var timeout: Task<Void, Never>?
    private var states: [AccountID: OIDAuthState] = [:]
    private let tokenPool = TokenRequestPool()
    private let credentials: any CredentialStore
    public init(configuration: OAuthConfiguration, credentials: (any CredentialStore)? = nil) {
        self.configuration = configuration
        self.credentials = credentials ?? KeychainCredentialStore(service: "mujhtech.dayfold.google." + configuration.clientID)
    }
    public func cancel() { flow?.cancel(); listener?.cancelHTTPListener(); flow = nil; listener = nil; timeout?.cancel() }
    public func authorize() async throws -> AuthorizedIdentity {
        guard configuration.configured else { throw CalendarError.unavailable("Google connection needs a Desktop OAuth client ID. Copy Config/OAuth.example.json to Config/OAuth.local.json, enter the client configuration, then rebuild. Explore Demo is available now.") }
        guard flow == nil else { throw CalendarError.unavailable("A Google sign-in is already open in your browser.") }
        let listener = OIDRedirectHTTPHandler(successURL: nil)
        var listenerError: NSError?
        let redirect = listener.startHTTPListener(&listenerError)
        if listenerError != nil { listener.cancelHTTPListener(); throw CalendarError.unavailable("The Google callback port could not be opened. Try signing in again.") }
        guard redirect.host == "127.0.0.1" || redirect.host == "::1" else { listener.cancelHTTPListener(); throw CalendarError.invalid("Authorization requires a loopback callback.") }
        self.listener = listener
        let config = OIDServiceConfiguration(authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!, tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!)
        let request = OIDAuthorizationRequest(configuration: config, clientId: configuration.clientID, clientSecret: configuration.clientSecret?.isEmpty == false ? configuration.clientSecret : nil, scopes: GoogleScope.all.sorted(), redirectURL: redirect, responseType: OIDResponseTypeCode, additionalParameters: ["access_type": "offline", "prompt": "select_account consent"])
        defer { timeout?.cancel(); listener.cancelHTTPListener(); flow = nil; self.listener = nil }
        let archive: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            // The external-browser overload is deliberately used for the desktop loopback flow.
            flow = OIDAuthState.authState(byPresenting: request) { state, error in
                if let state {
                    do { continuation.resume(returning: try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)) }
                    catch { continuation.resume(throwing: CalendarError.unavailable("Could not preserve the Google authorization.")) }
                } else {
                    let e = error as NSError?
                    let code = (e?.userInfo[OIDOAuthErrorResponseErrorKey] as? [String: Any])?["error"] as? String
                    continuation.resume(throwing: code == "admin_policy_enforced" ? ProviderError.organization : CalendarError.unavailable("Google sign-in was cancelled, denied, or expired. You can try again."))
                }
            }
            listener.currentAuthorizationFlow = flow
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                if !Task.isCancelled { self?.cancel() }
            }
        }
        guard let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archive), let token = state.lastTokenResponse?.accessToken else { throw ProviderError.unauthorized }
        var requestInfo = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        requestInfo.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let response = try await URLSessionTransport().send(requestInfo)
        guard response.status == 200, let json = try? JSONDecoder().decode(JSONObject.self, from: response.data), let subject = json["sub"]?.string, !subject.isEmpty else { throw ProviderError.unauthorized }
        return AuthorizedIdentity(subject: subject, email: json.text("email", default: "Google account"), scopes: Self.grantedScopes(state), archive: archive)
    }
    static func grantedScopes(_ state: OIDAuthState) -> Set<String> {
        // OAuth permits scope to be omitted only when it is identical to the request.
        let scope = state.lastTokenResponse?.scope ?? state.lastAuthorizationResponse.scope ?? state.lastAuthorizationResponse.request.scope ?? ""
        return Set(scope.split(separator: " ").map(String.init))
    }
    public func store(_ identity: AuthorizedIdentity, account: AccountID) async throws {
        await tokenPool.invalidate(account)
        try credentials.save(identity.archive, account: account.rawValue)
        states[account] = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: identity.archive)
    }
    public func remove(_ account: AccountID) async throws {
        await tokenPool.invalidate(account); states[account] = nil
        try credentials.remove(account: account.rawValue)
    }
    public func accessToken(for account: AccountID, forceRefresh: Bool) async throws -> String {
        try await tokenPool.value(for: account, forceRefresh: forceRefresh) { [self] force in
            try await loadToken(for: account, forceRefresh: force)
        }
    }
    private func loadToken(for account: AccountID, forceRefresh: Bool) async throws -> String {
            let state: OIDAuthState
            if let cached = states[account] { state = cached }
            else {
                guard let data = try credentials.read(account: account.rawValue), let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data) else { throw ProviderError.unauthorized }
                state = decoded; states[account] = decoded
            }
            if forceRefresh || (state.lastTokenResponse?.accessTokenExpirationDate?.timeIntervalSinceNow ?? 0) < 60 { state.setNeedsTokenRefresh() }
            let token: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                state.performAction { token, _, error in
                    if let token { continuation.resume(returning: token) }
                    else {
                        let code = ((error as NSError?)?.userInfo[OIDOAuthErrorResponseErrorKey] as? [String: Any])?["error"] as? String
                        continuation.resume(throwing: code == "invalid_grant" ? ProviderError.unauthorized : ProviderError.network)
                    }
                }
            }
            try Task.checkCancellation()
            try credentials.save(NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true), account: account.rawValue)
            return token
    }
}

public protocol CredentialStore: Sendable {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func remove(account: String) throws
}

public struct KeychainCredentialStore: CredentialStore {
    public var service: String
    public init(service: String) { self.service = service }
    private func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "https://accounts.google.com|" + account] }
    public func read(account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess else { throw ProviderError.credentialsUnavailable }; return item as? Data
    }
    public func save(_ data: Data, account: String) throws {
        let q = query(account)
        let update = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var insert = q; insert[kSecValueData as String] = data; insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw ProviderError.credentialsUnavailable }
        } else if update != errSecSuccess { throw ProviderError.credentialsUnavailable }
    }
    public func remove(account: String) throws {
        let result = SecItemDelete(query(account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CalendarError.unavailable("Keychain cleanup failed. Unlock your Mac and retry disconnecting.") }
    }
}
