import Foundation
import Security
import Testing
import AppAuth
import CalendarCore
@testable import CalendarPlatform

/// All mutable fixture state is behind this lock; only value snapshots escape.
private final class KeychainAPIFixture: CredentialKeychainAPI, @unchecked Sendable {
    struct Identity: Hashable, Sendable {
        let service: String
        let account: String
        let group: String?
    }
    struct Call: Sendable {
        let operation: String
        let identity: Identity
        let dataProtection: Bool
        let synchronized: Bool?
        let accessible: String?
        let hasReturn: Bool
        let hasMatch: Bool
        let attributeKeys: Set<String>
    }
    private let lock = NSLock()
    private var records: [Identity: Data] = [:]
    private var history: [Call] = []
    private var writeStatus: OSStatus?
    private var deleteStatus: OSStatus?
    private var invalidData = false
    private var verificationMismatch = false
    private var mainThreadAccess = false

    var calls: [Call] { lock.withLock { history } }
    var touchedMainThread: Bool { lock.withLock { mainThreadAccess } }
    func failWrites(_ status: OSStatus?) { lock.withLock { writeStatus = status } }
    func failDeletes(_ status: OSStatus?) { lock.withLock { deleteStatus = status } }
    func returnInvalidData(_ value: Bool) { lock.withLock { invalidData = value } }
    func mismatchVerification(_ value: Bool) { lock.withLock { verificationMismatch = value } }
    func seed(_ data: Data, service: String, account: String, group: String? = nil) {
        lock.withLock { records[Identity(service: service, account: account, group: group)] = data }
    }
    func value(service: String, account: String, group: String? = nil) -> Data? {
        lock.withLock { records[Identity(service: service, account: account, group: group)] }
    }
    private func record(_ operation: String, _ query: [String: Any], attributes: [String: Any] = [:]) -> Identity {
        let identity = Identity(service: query[kSecAttrService as String] as! String,
                                account: query[kSecAttrAccount as String] as! String,
                                group: query[kSecAttrAccessGroup as String] as? String)
        history.append(Call(operation: operation, identity: identity,
                            dataProtection: query[kSecUseDataProtectionKeychain as String] as? Bool ?? false,
                            synchronized: query[kSecAttrSynchronizable as String] as? Bool,
                            accessible: query[kSecAttrAccessible as String] as? String,
                            hasReturn: query[kSecReturnData as String] != nil,
                            hasMatch: query[kSecMatchLimit as String] != nil,
                            attributeKeys: Set(attributes.keys)))
        mainThreadAccess = mainThreadAccess || Thread.isMainThread
        return identity
    }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock {
            let identity = record("copy", query)
            guard let data = records[identity] else { return (errSecItemNotFound, nil) }
            if invalidData { return (errSecSuccess, nil) }
            if verificationMismatch && identity.group != nil { return (errSecSuccess, Data("mismatch".utf8)) }
            return (errSecSuccess, data)
        }
    }
    func add(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let identity = record("add", query)
            if records[identity] != nil { return errSecDuplicateItem }
            if let writeStatus { return writeStatus }
            records[identity] = query[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let identity = record("update", query, attributes: attributes)
            if let writeStatus { return writeStatus }
            guard records[identity] != nil else { return errSecItemNotFound }
            records[identity] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let identity = record("delete", query)
            if let deleteStatus { return deleteStatus }
            return records.removeValue(forKey: identity) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

@Test func credentialKeychainSelectsPrivateProvisionedIdentityAndDeliberateAdHocFallback() throws {
    #expect(CredentialKeychainMode.select(isAdHoc: true, applicationID: "forged", teamID: nil, bundleID: nil) == .legacyFileBased)
    #expect(CredentialKeychainMode.select(isAdHoc: false, applicationID: nil, teamID: "TEAM", bundleID: "dayfold") == .unavailable)
    #expect(CredentialKeychainMode.select(isAdHoc: false, applicationID: "OTHER.dayfold", teamID: "TEAM", bundleID: "dayfold") == .unavailable)
    let mode = CredentialKeychainMode.select(isAdHoc: false, applicationID: "TEAM.dayfold", teamID: "TEAM", bundleID: "dayfold")
    #expect(mode == .dataProtection(accessGroup: "TEAM.dayfold"))
    let storage = SystemRelayCredentialStorage()
    let query = try storage.query(account: "installation.fixture", mode: mode)
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(query[kSecAttrAccessGroup as String] as? String == "TEAM.dayfold")
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(query[kSecAttrAccessible as String] == nil)
    #expect(throws: CredentialKeychainFailure.self) { try storage.query(account: "installation.fixture", mode: .unavailable) }
}

@Test func credentialKeychainWritesKeepNarrowIdentitiesAndRecoverableSecrets() throws {
    let api = KeychainAPIFixture()
    let store = KeychainCredentialStore(service: "fixture.service", mode: .legacyFileBased, client: api)
    let first = Data("first".utf8), second = Data("second".utf8)
    try store.save(first, account: "one")
    try store.save(first, account: "two")
    try store.save(second, account: "one")
    #expect(try store.read(account: "one") == second)
    #expect(try store.read(account: "two") == first)
    #expect(api.calls.filter { $0.operation == "add" }.allSatisfy { $0.accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String })
    let update = try #require(api.calls.first { $0.operation == "update" })
    #expect(update.attributeKeys == [kSecValueData as String])
    #expect(!update.hasMatch && !update.hasReturn)
    api.failWrites(errSecInteractionNotAllowed)
    #expect(throws: ProviderError.credentialsUnavailable) { try store.save(first, account: "one") }
    #expect(try store.read(account: "one") == second)
    #expect(!api.calls.contains { $0.operation == "delete" })
    api.returnInvalidData(true)
    #expect(throws: ProviderError.credentialsUnavailable) { try store.read(account: "one") }
    api.returnInvalidData(false)
    try store.remove(account: "one")
    try store.remove(account: "one")
    #expect(try store.read(account: "one") == nil)
    #expect(try store.read(account: "two") == first)
    #expect(api.calls.filter { $0.operation == "delete" }.allSatisfy { !$0.hasMatch && !$0.hasReturn && $0.identity.account == "https://accounts.google.com|one" })
}

@Test func credentialMigrationIsExplicitVerifiedAndAccountScoped() throws {
    let api = KeychainAPIFixture(), account = "https://accounts.google.com|one"
    let secret = Data("old-secret".utf8)
    api.seed(secret, service: "old", account: account)
    api.seed(secret, service: "old", account: "https://accounts.google.com|two")
    let isolated = KeychainCredentialStore(service: "new", mode: .dataProtection(accessGroup: "TEAM.dayfold"), client: api)
    #expect(try isolated.read(account: "one") == nil)
    #expect(api.value(service: "old", account: account) == secret)
    let migrating = KeychainCredentialStore(service: "new", legacyService: "old", mode: .dataProtection(accessGroup: "TEAM.dayfold"), client: api)
    #expect(try migrating.read(account: "one") == secret)
    #expect(api.value(service: "new", account: account, group: "TEAM.dayfold") == secret)
    #expect(api.value(service: "old", account: account) == nil)
    #expect(api.value(service: "old", account: "https://accounts.google.com|two") == secret)
    let calls = api.calls
    let removal = try #require(calls.firstIndex { $0.operation == "delete" })
    #expect(calls[..<removal].contains { $0.operation == "copy" && $0.dataProtection && $0.identity.service == "new" })
    #expect(calls.filter { $0.operation == "add" }.allSatisfy { $0.synchronized == false && $0.dataProtection })
}

@Test func failedCredentialMigrationNeverDeletesTheOriginal() throws {
    for failVerification in [false, true] {
        let api = KeychainAPIFixture(), account = "https://accounts.google.com|one"
        let original = Data("original".utf8)
        api.seed(original, service: "old", account: account)
        if failVerification { api.mismatchVerification(true) }
        else { api.failWrites(errSecInteractionNotAllowed) }
        let store = KeychainCredentialStore(service: "new", legacyService: "old", mode: .dataProtection(accessGroup: "TEAM.dayfold"), client: api)
        #expect(throws: ProviderError.credentialsUnavailable) { try store.read(account: "one") }
        #expect(api.value(service: "old", account: account) == original)
        #expect(!api.calls.contains { $0.operation == "delete" })
    }
}

@Test func credentialRemovalCannotResurrectALegacyFallbackAfterAFailedDelete() throws {
    let api = KeychainAPIFixture(), account = "https://accounts.google.com|one"
    let old = Data("old".utf8), current = Data("current".utf8)
    api.seed(old, service: "old", account: account)
    api.seed(current, service: "new", account: account, group: "TEAM.dayfold")
    let store = KeychainCredentialStore(service: "new", legacyService: "old", mode: .dataProtection(accessGroup: "TEAM.dayfold"), client: api)
    api.failDeletes(errSecInteractionNotAllowed)
    #expect(throws: ProviderError.credentialsUnavailable) { try store.remove(account: "one") }
    #expect(api.value(service: "new", account: account, group: "TEAM.dayfold") == current)
    #expect(try store.read(account: "one") == current)
    api.failDeletes(nil)
    #expect(try store.read(account: "one") == current)
    #expect(api.value(service: "old", account: account) == old)
    try store.remove(account: "one")
    #expect(try store.read(account: "one") == nil)
}

@Test @MainActor func credentialActorsKeepBlockingCallsOffMainAndRejectStaleRefreshWrites() async throws {
    let api = KeychainAPIFixture()
    let storage = KeychainCredentialStore(service: "fixture", mode: .legacyFileBased, client: api)
    let vault = SerializedCredentialStore(storage: storage)
    try await vault.replace(Data("current".utf8), account: "one", generation: 1)
    #expect(try await vault.read(account: "one", generation: 1) == Data("current".utf8))
    try await vault.remove(account: "one", generation: 2)
    await #expect(throws: CancellationError.self) { try await vault.save(Data("late-refresh".utf8), account: "one", generation: 1) }
    await #expect(throws: CancellationError.self) { try await vault.replace(Data("late-signin".utf8), account: "one", generation: 1) }
    #expect(try await vault.read(account: "one", generation: 2) == nil)
    let auth = GoogleAuthorization(configuration: OAuthConfiguration(), credentials: storage)
    await #expect(throws: ProviderError.unauthorized) { try await auth.accessToken(for: AccountID(rawValue: "missing"), forceRefresh: false) }
    await auth.cancelPendingRequests()
    await #expect(throws: CancellationError.self) { try await auth.accessToken(for: AccountID(rawValue: "missing"), forceRefresh: false) }
    await #expect(throws: CancellationError.self) { try await auth.accessToken(for: AccountID(rawValue: "never-seen"), forceRefresh: false) }
    let relay = RelayCredentialStore(namespace: "fixture", storage: SystemRelayCredentialStorage(mode: .legacyFileBased, client: api))
    let credentials = RelayCredentials(origin: URL(string: "https://relay.example.test")!, deviceID: UUID(), token: String(repeating: "e", count: 64))
    try await relay.save(credentials)
    #expect(try await relay.load()?.token == credentials.token)
    try await relay.delete()
    await relay.invalidate()
    await #expect(throws: RelayProcessingError.configurationChanged) { try await relay.save(credentials) }
    await #expect(throws: RelayProcessingError.configurationChanged) { try await relay.load() }
    #expect(!api.touchedMainThread)
}

@Test func googleCredentialNamespacesSeparateStoresAndClientConfigurations() {
    let real = GoogleAuthorization.credentialService(clientID: "client-a", namespace: "/stores/real")
    let test = GoogleAuthorization.credentialService(clientID: "client-a", namespace: "/stores/test")
    let otherClient = GoogleAuthorization.credentialService(clientID: "client-b", namespace: "/stores/real")
    #expect(real != test && real != otherClient)
    #expect(!real.contains("/stores/real"))
    #expect(real == GoogleAuthorization.credentialService(clientID: "client-a", namespace: "/stores/real"))
}

@Test @MainActor func googleRejectsArchivedCredentialsForAnotherClientOrTokenOrigin() async throws {
    let api = KeychainAPIFixture()
    let storage = KeychainCredentialStore(service: "fixture", mode: .legacyFileBased, client: api)
    let auth = GoogleAuthorization(configuration: OAuthConfiguration(clientID: "expected.apps.googleusercontent.com"), credentials: storage)
    for (client, tokenURL) in [("expected.apps.googleusercontent.com", "https://attacker.example/token"),
                               ("different.apps.googleusercontent.com", "https://oauth2.googleapis.com/token")] {
        let configuration = OIDServiceConfiguration(authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!, tokenEndpoint: URL(string: tokenURL)!)
        let request = OIDAuthorizationRequest(configuration: configuration, clientId: client, clientSecret: nil, scopes: ["openid"], redirectURL: URL(string: "http://127.0.0.1:50000/")!, responseType: OIDResponseTypeCode, additionalParameters: nil)
        let response = OIDAuthorizationResponse(request: request, parameters: ["code": "fixture" as NSString, "state": request.state! as NSString])
        let archive = try NSKeyedArchiver.archivedData(withRootObject: OIDAuthState(authorizationResponse: response), requiringSecureCoding: true)
        let identity = AuthorizedIdentity(subject: "fixture", email: "fixture@example.invalid", scopes: ["openid"], archive: archive)
        await #expect(throws: ProviderError.credentialsUnavailable) { try await auth.store(identity, account: AccountID()) }
    }
    #expect(api.calls.isEmpty)
}
