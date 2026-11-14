import AppKit
@preconcurrency import AppAuth
import CalendarCore
import CryptoKit
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
    private let credentials: SerializedCredentialStore
    private var active = true
    private var credentialGenerations: [AccountID: Int] = [:]
    private var changingCredentials: Set<AccountID> = []
    public init(configuration: OAuthConfiguration, namespace: String = "default", allowLegacyMigration: Bool = false, credentials: (any CredentialStore)? = nil) {
        OAuthTokenTransport.configureAppAuth()
        self.configuration = configuration
        let legacyService = "mujhtech.dayfold.google." + configuration.clientID
        self.credentials = SerializedCredentialStore(storage: credentials ?? KeychainCredentialStore(
            service: Self.credentialService(clientID: configuration.clientID, namespace: namespace),
            legacyService: allowLegacyMigration ? legacyService : nil
        ))
    }
    nonisolated static func credentialService(clientID: String, namespace: String) -> String {
        let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        return "mujhtech.dayfold.google." + clientID + ".store." + digest
    }
    public func cancel() { flow?.cancel(); listener?.cancelHTTPListener(); flow = nil; listener = nil; timeout?.cancel() }
    /// A store switch waits for this barrier before binding another authorizer.
    /// The pool owns refresh tasks, so cancelling their caller alone isn't enough.
    /// This permanently retires this authorizer; persisted credentials remain
    /// available to a new authorizer bound to the same store.
    public func cancelPendingRequests() async {
        active = false
        let revisions = Array(credentialGenerations.keys).map { ($0, beginCredentialChange($0)) }
        for (account, generation) in revisions {
            await tokenPool.invalidate(account)
            await credentials.invalidate(account: account.rawValue, generation: generation)
            if credentialGenerations[account] == generation { changingCredentials.remove(account) }
        }
    }
    public func authorize() async throws -> AuthorizedIdentity {
        guard active else { throw CancellationError() }
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
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
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
        guard active else { throw CancellationError() }
        let decoded = try decodeState(identity.archive)
        let generation = beginCredentialChange(account)
        defer { if credentialGenerations[account] == generation { changingCredentials.remove(account) } }
        await tokenPool.invalidate(account)
        try validateGeneration(generation, account: account)
        try await credentials.replace(identity.archive, account: account.rawValue, generation: generation)
        try validateGeneration(generation, account: account)
        states[account] = decoded
    }
    public func remove(_ account: AccountID) async throws {
        guard active else { throw CancellationError() }
        let generation = beginCredentialChange(account)
        defer { if credentialGenerations[account] == generation { changingCredentials.remove(account) } }
        await tokenPool.invalidate(account)
        try validateGeneration(generation, account: account)
        try await credentials.remove(account: account.rawValue, generation: generation)
        try validateGeneration(generation, account: account)
    }
    public func accessToken(for account: AccountID, forceRefresh: Bool) async throws -> String {
        guard active else { throw CancellationError() }
        if credentialGenerations[account] == nil { credentialGenerations[account] = 0 }
        return try await tokenPool.value(for: account, forceRefresh: forceRefresh) { [self] force in
            try await loadToken(for: account, forceRefresh: force)
        }
    }
    private func loadToken(for account: AccountID, forceRefresh: Bool) async throws -> String {
            guard active, !changingCredentials.contains(account) else { throw CancellationError() }
            let generation = credentialGenerations[account, default: 0]
            let state: OIDAuthState
            if let cached = states[account] { state = cached }
            else {
                guard let data = try await credentials.read(account: account.rawValue, generation: generation) else { throw ProviderError.unauthorized }
                try validateGeneration(generation, account: account)
                let decoded = try decodeState(data)
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
            try validateGeneration(generation, account: account)
            let archive = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
            try await credentials.save(archive, account: account.rawValue, generation: generation)
            try validateGeneration(generation, account: account)
            return token
    }

    private func beginCredentialChange(_ account: AccountID) -> Int {
        credentialGenerations[account, default: 0] += 1
        changingCredentials.insert(account)
        states[account] = nil
        return credentialGenerations[account, default: 0]
    }

    private func validateGeneration(_ generation: Int, account: AccountID) throws {
        try Task.checkCancellation()
        guard active, credentialGenerations[account, default: 0] == generation else { throw CancellationError() }
    }

    private func decodeState(_ data: Data) throws -> OIDAuthState {
        guard data.count <= 1_048_576,
              let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data),
              state.lastAuthorizationResponse.request.clientID == configuration.clientID,
              state.lastAuthorizationResponse.request.configuration.authorizationEndpoint.absoluteString == "https://accounts.google.com/o/oauth2/v2/auth",
              state.lastAuthorizationResponse.request.configuration.tokenEndpoint.absoluteString == "https://oauth2.googleapis.com/token" else {
            throw ProviderError.credentialsUnavailable
        }
        return state
    }
}

public protocol CredentialStore: Sendable {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func remove(account: String) throws
}

enum OAuthTokenTransport {
    @MainActor private static let configure: Void = { OIDURLSessionProvider.setSession(makeSession()) }()
    @MainActor static func configureAppAuth() { _ = configure }
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration, delegate: OAuthTokenRedirectPolicy(), delegateQueue: nil)
    }
}

private final class OAuthTokenRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // A 307/308 can forward the complete refresh-token POST body, including
        // to another origin. The fixed Google token endpoint must answer directly.
        completionHandler(nil)
        task.cancel()
    }
}

public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    private let items: CredentialKeychainItems
    public init(service: String, legacyService: String? = nil) {
        self.service = service
        items = CredentialKeychainItems(service: service, legacyService: legacyService)
    }
    init(service: String, legacyService: String? = nil, mode: CredentialKeychainMode, client: any CredentialKeychainAPI) {
        self.service = service
        items = CredentialKeychainItems(service: service, legacyService: legacyService, mode: mode, client: client)
    }
    public func read(account: String) throws -> Data? {
        do { return try items.read(account: "https://accounts.google.com|" + account) }
        catch { throw ProviderError.credentialsUnavailable }
    }
    public func save(_ data: Data, account: String) throws {
        do { try items.save(data, account: "https://accounts.google.com|" + account) }
        catch { throw ProviderError.credentialsUnavailable }
    }
    public func remove(account: String) throws {
        do { try items.remove(account: "https://accounts.google.com|" + account) }
        catch { throw ProviderError.credentialsUnavailable }
    }
}

/// Blocking Security.framework calls and injected stores run on this actor,
/// never on the UI actor. Generations prevent a late refresh from restoring a
/// credential after a disconnect or reconnect has replaced it.
actor SerializedCredentialStore {
    private let storage: any CredentialStore
    private var generations: [String: Int] = [:]
    init(storage: any CredentialStore) { self.storage = storage }
    func read(account: String, generation: Int) throws -> Data? {
        try check(account, generation: generation)
        return try storage.read(account: account)
    }
    func save(_ data: Data, account: String, generation: Int) throws {
        try check(account, generation: generation)
        try storage.save(data, account: account)
    }
    func replace(_ data: Data, account: String, generation: Int) throws {
        try advance(account, generation: generation)
        try storage.save(data, account: account)
    }
    func remove(account: String, generation: Int) throws {
        try advance(account, generation: generation)
        try storage.remove(account: account)
    }
    func invalidate(account: String, generation: Int) {
        // Cleanup must still run if the store-switch task itself was cancelled.
        generations[account] = max(generations[account, default: 0], generation)
    }
    private func check(_ account: String, generation: Int) throws {
        try Task.checkCancellation()
        guard generations[account, default: 0] == generation else { throw CancellationError() }
    }
    private func advance(_ account: String, generation: Int) throws {
        try Task.checkCancellation()
        guard generation >= generations[account, default: 0] else { throw CancellationError() }
        generations[account] = generation
    }
}

/// Data-protection Keychain is available on macOS 10.15+. Production access is
/// tied to the private, provisioned app identifier rather than a shared group.
/// Local ad-hoc tools deliberately retain their existing login-Keychain ACLs.
enum CredentialKeychainMode: Sendable, Equatable {
    case legacyFileBased
    case dataProtection(accessGroup: String)
    case unavailable

    static func select(isAdHoc: Bool, applicationID: String?, teamID: String?, bundleID: String?) -> Self {
        if isAdHoc { return .legacyFileBased }
        guard let applicationID, let teamID, !teamID.isEmpty, let bundleID, !bundleID.isEmpty,
              applicationID == teamID + "." + bundleID else { return .unavailable }
        return .dataProtection(accessGroup: applicationID)
    }

    static func current() -> Self {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let flags = values[kSecCodeInfoFlags as String] as? NSNumber else { return .unavailable }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return select(isAdHoc: flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0,
                      applicationID: entitlements?["com.apple.application-identifier"] as? String,
                      teamID: values[kSecCodeInfoTeamIdentifier as String] as? String,
                      bundleID: Bundle.main.bundleIdentifier)
    }
}

/// A narrow synchronous seam for status, query-shape, and migration tests.
/// Only the actors above and RelayCredentialStore call this in the app.
protocol CredentialKeychainAPI: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemCredentialKeychainAPI: CredentialKeychainAPI {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

struct CredentialKeychainFailure: Error { let status: OSStatus }

struct CredentialKeychainItems: Sendable {
    let service: String
    var legacyService: String?
    var mode: CredentialKeychainMode?
    var client: any CredentialKeychainAPI = SystemCredentialKeychainAPI()

    func query(account: String, mode: CredentialKeychainMode, service: String? = nil) throws -> [String: Any] {
        guard !account.isEmpty, account.utf8.count <= 8192, !self.service.isEmpty else {
            throw CredentialKeychainFailure(status: errSecParam)
        }
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service ?? self.service,
                                   kSecAttrAccount as String: account]
        switch mode {
        case .dataProtection(let group):
            result[kSecUseDataProtectionKeychain as String] = true
            result[kSecAttrAccessGroup as String] = group
            result[kSecAttrSynchronizable as String] = false
        case .legacyFileBased: break
        case .unavailable: throw CredentialKeychainFailure(status: errSecMissingEntitlement)
        }
        return result
    }

    private func queries(account: String) throws -> (primary: [String: Any], legacy: [[String: Any]]) {
        let selected = mode ?? .current()
        let primary = try query(account: account, mode: selected)
        var legacy: [[String: Any]] = []
        if case .dataProtection = selected { legacy.append(try query(account: account, mode: .legacyFileBased)) }
        if let legacyService, legacyService != service {
            legacy.append(try query(account: account, mode: selected, service: legacyService))
            if case .dataProtection = selected {
                legacy.append(try query(account: account, mode: .legacyFileBased, service: legacyService))
            }
        }
        return (primary, legacy)
    }

    func read(account: String) throws -> Data? {
        let queries = try queries(account: account)
        if let data = try read(queries.primary) {
            // Retry interrupted migrations only while both copies match. A
            // different legacy value may be the last recoverable original.
            for legacy in queries.legacy where try read(legacy) == data { try remove(legacy) }
            return data
        }
        for legacy in queries.legacy {
            if let data = try read(legacy) {
                // Verify persistence before removing the exact legacy identity.
                // A locked, denied, or failed write leaves the original intact.
                try save(data, query: queries.primary)
                guard try read(queries.primary) == data else { throw CredentialKeychainFailure(status: errSecDecode) }
                try remove(legacy)
                return data
            }
        }
        return nil
    }

    func save(_ data: Data, account: String) throws {
        let queries = try queries(account: account)
        try save(data, query: queries.primary)
        if !queries.legacy.isEmpty {
            guard try read(queries.primary) == data else { throw CredentialKeychainFailure(status: errSecDecode) }
            for legacy in queries.legacy { try remove(legacy) }
        }
    }

    func remove(account: String) throws {
        let queries = try queries(account: account)
        // Remove fallbacks first so a failed cleanup cannot resurrect a token.
        for legacy in queries.legacy { try remove(legacy) }
        try remove(queries.primary)
    }

    private func read(_ identity: [String: Any]) throws -> Data? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = client.copy(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw CredentialKeychainFailure(status: status == errSecSuccess ? errSecDecode : status) }
        return data
    }

    private func save(_ data: Data, query: [String: Any]) throws {
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        switch client.add(insert) {
        case errSecSuccess: return
        case errSecDuplicateItem:
            let status = client.update(query, attributes: [kSecValueData as String: data])
            guard status == errSecSuccess else { throw CredentialKeychainFailure(status: status) }
        case let status: throw CredentialKeychainFailure(status: status)
        }
    }

    private func remove(_ query: [String: Any]) throws {
        let status = client.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialKeychainFailure(status: status) }
    }
}
