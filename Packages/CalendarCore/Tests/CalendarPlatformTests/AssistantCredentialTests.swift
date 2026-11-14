import Foundation
import Security
import Testing
@testable import CalendarPlatform

private final class AssistantKeychainFixture: CredentialKeychainAPI, @unchecked Sendable {
    private struct Identity: Hashable {
        let service: String
        let account: String
        let group: String?
    }
    private let lock = NSLock()
    private var records: [Identity: Data] = [:]
    private var operations: [String] = []
    private var writeFailure = false
    private var deleteFailure = false
    private var mainThreadAccess = false

    var calls: [String] { lock.withLock { operations } }
    var accounts: Set<String> { lock.withLock { Set(records.keys.map(\.account)) } }
    var services: Set<String> { lock.withLock { Set(records.keys.map(\.service)) } }
    var touchedMainThread: Bool { lock.withLock { mainThreadAccess } }
    func failWrites(_ value: Bool) { lock.withLock { writeFailure = value } }
    func failDeletes(_ value: Bool) { lock.withLock { deleteFailure = value } }
    func corruptRecords(_ data: Data) { lock.withLock { for key in Array(records.keys) { records[key] = data } } }

    private func record(_ operation: String, query: [String: Any]) -> Identity {
        operations.append(operation)
        mainThreadAccess = mainThreadAccess || Thread.isMainThread
        return Identity(service: query[kSecAttrService as String] as! String, account: query[kSecAttrAccount as String] as! String, group: query[kSecAttrAccessGroup as String] as? String)
    }

    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock {
            let identity = record("read", query: query)
            return records[identity].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }

    func add(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let identity = record("add", query: query)
            guard records[identity] == nil else { return errSecDuplicateItem }
            guard !writeFailure else { return errSecInteractionNotAllowed }
            records[identity] = query[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let identity = record("update", query: query)
            guard !writeFailure else { return errSecInteractionNotAllowed }
            guard records[identity] != nil else { return errSecItemNotFound }
            records[identity] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let identity = record("delete", query: query)
            guard !deleteFailure else { return errSecInteractionNotAllowed }
            return records.removeValue(forKey: identity) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

@Test @MainActor func assistantCredentialsAreNamespacedAndBlockingWorkStaysOffMain() async throws {
    let api = AssistantKeychainFixture(), storage = SystemAssistantCredentialStorage(mode: .legacyFileBased, client: api)
    let real = AssistantCredentialStore(namespace: "/stores/real", storage: storage)
    let demo = AssistantCredentialStore(namespace: "/stores/demo", storage: storage)
    let same = AssistantCredentialStore(namespace: "/stores/real", storage: storage)
    let first = try AssistantAPIKey("sk-fixture-real"), second = try AssistantAPIKey("sk-fixture-demo")
    try await real.save(first)
    try await demo.save(second)
    #expect(try await same.load() == first)
    #expect(try await demo.load() == second)
    #expect(api.accounts.count == 2)
    #expect(api.accounts.allSatisfy { $0.hasPrefix("key.") && $0.count == 68 && !$0.contains("/stores") })
    #expect(api.services == ["mujhtech.dayfold.assistant.openai"])
    #expect(!api.touchedMainThread)
}

@Test func assistantCredentialOverwriteFailureRetainsExistingKey() async throws {
    let api = AssistantKeychainFixture(), store = AssistantCredentialStore(namespace: "fixture", storage: SystemAssistantCredentialStorage(mode: .legacyFileBased, client: api))
    let original = try AssistantAPIKey("sk-original-fixture"), replacement = try AssistantAPIKey("sk-replacement-fixture")
    try await store.save(original)
    api.failWrites(true)
    await #expect(throws: AssistantCredentialError.keychainUnavailable) { try await store.save(replacement) }
    #expect(try await store.load() == original)
    #expect(api.calls.contains("update") && !api.calls.contains("delete"))
    api.failWrites(false)
    try await store.save(replacement)
    #expect(try await store.load() == replacement)
}

@Test func assistantCredentialDeleteFailureRetainsKeyForRetry() async throws {
    let api = AssistantKeychainFixture(), store = AssistantCredentialStore(namespace: "fixture", storage: SystemAssistantCredentialStorage(mode: .legacyFileBased, client: api))
    let key = try AssistantAPIKey("sk-fixture")
    try await store.save(key)
    api.failDeletes(true)
    await #expect(throws: AssistantCredentialError.keychainUnavailable) { try await store.delete() }
    #expect(try await store.load() == key)
    api.failDeletes(false)
    try await store.delete()
    try await store.delete()
    #expect(try await store.load() == nil)
}

@Test func assistantCredentialInvalidationRejectsOldOperationsWithoutDeleting() async throws {
    let api = AssistantKeychainFixture(), storage = SystemAssistantCredentialStorage(mode: .legacyFileBased, client: api)
    let store = AssistantCredentialStore(namespace: "fixture", storage: storage), key = try AssistantAPIKey("sk-fixture")
    try await store.save(key)
    await store.invalidate()
    let before = api.calls
    await #expect(throws: CancellationError.self) { try await store.load() }
    await #expect(throws: CancellationError.self) { try await store.save(key) }
    await #expect(throws: CancellationError.self) { try await store.delete() }
    #expect(api.calls == before)
    let reopened = AssistantCredentialStore(namespace: "fixture", storage: storage)
    #expect(try await reopened.load() == key)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await reopened.load()
    }
    let beforeCancelledRead = api.calls
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(api.calls == beforeCancelledRead)
}

@Test func assistantCredentialInputAndSavedRecordValidationNeverExposeSecrets() async throws {
    let key = try AssistantAPIKey("sk-do-not-display-this-fixture")
    #expect(!String(describing: key).contains(key.value))
    #expect(!String(reflecting: key).contains(key.value))
    #expect(key.description.contains("[REDACTED]"))
    #expect(Mirror(reflecting: key).children.first?.value as? String == "[REDACTED]")
    for value in ["", " ", "sk trailing", "sk\nnewline", "sk\t-tab", "sk-\u{007f}", "sk-café", String(repeating: "x", count: 8193)] {
        #expect(throws: AssistantCredentialError.invalidKey) { try AssistantAPIKey(value) }
    }
    #expect(try AssistantAPIKey(String(repeating: "x", count: 8192)).value.count == 8192)
    let api = AssistantKeychainFixture(), storage = SystemAssistantCredentialStorage(mode: .legacyFileBased, client: api)
    let store = AssistantCredentialStore(namespace: "fixture", storage: storage)
    try await store.save(key)
    for corrupt in [Data(), Data([0xff]), Data("invalid key".utf8), Data(repeating: 120, count: 8193)] {
        api.corruptRecords(corrupt)
        await #expect(throws: AssistantCredentialError.corruptRecord) { try await store.load() }
    }
    let invalid = AssistantCredentialStore(namespace: "", storage: storage)
    let before = api.calls
    await #expect(throws: AssistantCredentialError.invalidNamespace) { try await invalid.save(key) }
    #expect(api.calls == before)
}
