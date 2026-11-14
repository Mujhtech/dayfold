import Foundation
import CryptoKit
import Security

/// Deliberately not Codable: an API key must never become a preference, exported
/// draft, conversation record or diagnostics field. Only the transport reads value.
public struct AssistantAPIKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 8192,
              value.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw AssistantCredentialError.invalidKey
        }
        self.value = value
    }

    public var description: String { "AssistantAPIKey([REDACTED])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": "[REDACTED]"]) }
}

public enum AssistantCredentialError: Error, LocalizedError, Sendable, Equatable {
    case invalidKey
    case invalidNamespace
    case corruptRecord
    case keychainUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "Enter a valid API key without spaces or line breaks."
        case .invalidNamespace: "The assistant credential storage identifier is invalid."
        case .corruptRecord: "The saved assistant API key could not be read. Save your key again."
        case .keychainUnavailable: "The assistant API key is unavailable. Unlock your Mac and retry."
        }
    }
}

/// One key per stable local-store namespace. Security.framework work runs on this
/// actor, away from the UI actor. Invalidating is a barrier for all old-store work;
/// it does not delete a user's saved key.
public actor AssistantCredentialStore {
    private let account: String?
    private let storage: any AssistantCredentialStorage
    private var active = true
    private var generation: UInt64 = 0

    public init(namespace: String) {
        self.init(namespace: namespace, storage: SystemAssistantCredentialStorage())
    }

    init(namespace: String, storage: any AssistantCredentialStorage) {
        if !namespace.isEmpty, namespace.utf8.count <= 4096 {
            let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
            account = "key." + digest
        } else { account = nil }
        self.storage = storage
    }

    public func load() throws -> AssistantAPIKey? {
        let operation = try beginOperation()
        let data = try storage.read(account: operation.account)
        try requireCurrent(operation.generation)
        guard let data else { return nil }
        guard data.count <= 8192, let value = String(data: data, encoding: .utf8),
              let key = try? AssistantAPIKey(value) else {
            throw AssistantCredentialError.corruptRecord
        }
        return key
    }

    public func save(_ key: AssistantAPIKey) throws {
        let operation = try beginOperation()
        // CredentialKeychainItems updates the existing item in place. It never
        // deletes the recoverable old key before a replacement has succeeded.
        try storage.save(Data(key.value.utf8), account: operation.account)
    }

    public func delete() throws {
        let operation = try beginOperation()
        try storage.remove(account: operation.account)
    }

    public func invalidate() {
        active = false
        generation &+= 1
    }

    private func beginOperation() throws -> (account: String, generation: UInt64) {
        try requireCurrent(generation)
        guard let account else { throw AssistantCredentialError.invalidNamespace }
        return (account, generation)
    }

    private func requireCurrent(_ expectedGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard active, generation == expectedGeneration else { throw CancellationError() }
    }
}

// An internal seam keeps deterministic tests away from the actual Keychain.
protocol AssistantCredentialStorage: Sendable {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func remove(account: String) throws
}

struct SystemAssistantCredentialStorage: AssistantCredentialStorage {
    static let service = "mujhtech.dayfold.assistant.openai"
    private let items: CredentialKeychainItems

    init(mode: CredentialKeychainMode? = nil, client: any CredentialKeychainAPI = SystemCredentialKeychainAPI()) {
        items = CredentialKeychainItems(service: Self.service, mode: mode, client: client)
    }

    func read(account: String) throws -> Data? {
        do { return try items.read(account: account) }
        catch { throw AssistantCredentialError.keychainUnavailable }
    }

    func save(_ data: Data, account: String) throws {
        do { try items.save(data, account: account) }
        catch { throw AssistantCredentialError.keychainUnavailable }
    }

    func remove(account: String) throws {
        do { try items.remove(account: account) }
        catch { throw AssistantCredentialError.keychainUnavailable }
    }
}
