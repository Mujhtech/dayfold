import Foundation
import Testing
import AppAuth
import CalendarCore
@testable import CalendarPlatform

@MainActor private func authorizationFixture() -> OIDAuthorizationRequest {
    let configuration = OIDServiceConfiguration(authorizationEndpoint: URL(string: "https://example.invalid/authorize")!, tokenEndpoint: URL(string: "https://example.invalid/token")!)
    return OIDAuthorizationRequest(configuration: configuration, clientId: "fixture-client", clientSecret: nil, scopes: ["openid", "email"], redirectURL: URL(string: "http://127.0.0.1:53123/callback")!, responseType: OIDResponseTypeCode, additionalParameters: nil)
}

@Test @MainActor func appAuthGeneratesFreshStatePKCEAndRetainsRefreshToken() throws {
    let request = authorizationFixture(), second = authorizationFixture()
    #expect(request.state != second.state && request.state?.isEmpty == false)
    #expect(request.codeChallengeMethod == "S256")
    #expect(request.codeVerifier != second.codeVerifier && (request.codeVerifier?.count ?? 0) >= 43)
    let authorization = OIDAuthorizationResponse(request: request, parameters: ["code": "fixture-code" as NSString, "state": request.state! as NSString])
    let tokenRequest = authorization.tokenExchangeRequest()!
    let initial = OIDTokenResponse(request: tokenRequest, parameters: ["access_token": "fixture-access" as NSString, "refresh_token": "fixture-refresh" as NSString, "token_type": "Bearer" as NSString, "expires_in": NSNumber(value: 3600)])
    let state = OIDAuthState(authorizationResponse: authorization, tokenResponse: initial)
    #expect(GoogleAuthorization.grantedScopes(state) == ["openid", "email"])
    let refreshed = OIDTokenResponse(request: tokenRequest, parameters: ["access_token": "fixture-next" as NSString, "token_type": "Bearer" as NSString, "expires_in": NSNumber(value: 3600)])
    state.update(with: refreshed, error: nil)
    #expect(state.refreshToken == "fixture-refresh")
    let archive = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
    #expect(try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archive)?.refreshToken == "fixture-refresh")
    let partial = OIDTokenResponse(request: tokenRequest, parameters: ["access_token": "fixture-partial" as NSString, "token_type": "Bearer" as NSString, "scope": "openid" as NSString])
    state.update(with: partial, error: nil)
    #expect(GoogleAuthorization.grantedScopes(state) == ["openid"])
}

private struct LockedCredentialFixture: CredentialStore {
    func read(account: String) throws -> Data? { throw ProviderError.credentialsUnavailable }
    func save(_ data: Data, account: String) throws { throw ProviderError.credentialsUnavailable }
    func remove(account: String) throws { Issue.record("Transient Keychain errors must never remove stored credentials") }
}
@Test @MainActor func missingConfigurationAndLockedKeychainRemainRecoverable() async throws {
    let auth = GoogleAuthorization(configuration: OAuthConfiguration(), credentials: LockedCredentialFixture())
    await #expect(throws: (any Error).self) { try await auth.authorize() }
    await #expect(throws: ProviderError.credentialsUnavailable) { try await auth.accessToken(for: AccountID(), forceRefresh: false) }
}

@Test func externalDisplayRemovalReturnsReachableFrame() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let old = CGRect(x: 1800, y: 300, width: 1320, height: 860)
    let restored = WindowPlacementPolicy.reachable(old, screens: [screen])
    #expect(screen.contains(restored))
    #expect(WindowPlacementPolicy.reachable(restored, screens: [screen]) == restored)
}

@Test func processOwnershipExcludesSecondDispatcher() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lock").path
    let first = try ProcessOwnership(path: file)
    withExtendedLifetime(first) { #expect(throws: (any Error).self) { try ProcessOwnership(path: file) } }
}
