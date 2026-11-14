import Foundation
import CryptoKit
import Security
import CalendarCore

/// Relay credentials belong in Keychain. This type deliberately isn't Codable
/// so it cannot accidentally become part of the app's preferences or relay state.
public struct RelayCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let origin: URL
    public let deviceID: UUID
    public let token: String

    public init(origin: URL, deviceID: UUID, token: String) {
        self.origin = origin
        self.deviceID = deviceID
        self.token = token
    }

    public var description: String { "RelayCredentials(deviceID: \(deviceID), token: [REDACTED])" }
    public var debugDescription: String { description }
}

public enum RelayCredentialError: Error, LocalizedError, Sendable, Equatable {
    case invalidNamespace
    case invalidCredentials
    case corruptRecord
    case keychainUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidNamespace: "The relay credential storage identifier is invalid."
        case .invalidCredentials: "Enter a valid relay origin and installation token."
        case .corruptRecord: "The saved relay credentials could not be read. Reconnect the relay."
        case .keychainUnavailable: "Relay credentials are unavailable. Unlock your Mac and retry."
        }
    }
}

/// One active relay installation per local store namespace. Demo and real stores
/// must use different, stable namespaces. Replacing an installation is atomic at
/// the Keychain item level; a failed read or update never deletes the old item.
public actor RelayCredentialStore {
    private let namespace: String
    private let allowLoopbackHTTP: Bool
    private let storage: any RelayCredentialStorage
    private var active = true

    public init(namespace: String, allowLoopbackHTTP: Bool = false) {
        self.init(namespace: namespace, allowLoopbackHTTP: allowLoopbackHTTP, storage: SystemRelayCredentialStorage())
    }

    init(namespace: String, allowLoopbackHTTP: Bool = false, storage: any RelayCredentialStorage) {
        self.namespace = namespace
        self.allowLoopbackHTTP = allowLoopbackHTTP
        self.storage = storage
    }

    public func load() throws -> RelayCredentials? {
        try requireActive()
        guard let data = try storage.read(account: account()) else { return nil }
        guard data.count <= 16_384,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1 else {
            throw RelayCredentialError.corruptRecord
        }
        do {
            return try validated(RelayCredentials(origin: record.origin, deviceID: record.deviceID, token: record.token))
        } catch {
            throw RelayCredentialError.corruptRecord
        }
    }

    public func save(_ credentials: RelayCredentials) throws {
        try requireActive()
        let account = try account()
        let credentials = try validated(credentials)
        let record = Record(version: 1, origin: credentials.origin, deviceID: credentials.deviceID, token: credentials.token)
        try storage.save(JSONEncoder().encode(record), account: account)
    }

    public func delete() throws {
        try requireActive()
        try storage.remove(account: account())
    }

    func loadAccountRecord() throws -> RelayAccountRecord? {
        try requireActive()
        guard let data = try storage.read(account: account() + ".account.v2") else { return nil }
        guard data.count <= 131_072, let record = try? JSONDecoder().decode(RelayAccountRecord.self, from: data),
              record.version == 2 else { throw RelayCredentialError.corruptRecord }
        return record
    }
    func saveAccountRecord(_ record: RelayAccountRecord) throws {
        try requireActive()
        try storage.save(JSONEncoder().encode(record), account: account() + ".account.v2")
    }
    func deleteAccountRecord() throws {
        try requireActive()
        try storage.remove(account: account() + ".account.v2")
    }

    /// Drain or reject operations from the old store before a new vault is bound.
    /// The synchronous storage work cannot interleave with this actor barrier.
    public func invalidate() { active = false }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard active else { throw RelayProcessingError.configurationChanged }
    }

    private func validated(_ credentials: RelayCredentials) throws -> RelayCredentials {
        do {
            let origin = try RelayEndpoint.validatedOrigin(credentials.origin, allowLoopbackHTTP: allowLoopbackHTTP)
            try RelayEndpoint.validateToken(credentials.token)
            return RelayCredentials(origin: origin, deviceID: credentials.deviceID, token: credentials.token)
        } catch {
            throw RelayCredentialError.invalidCredentials
        }
    }

    private func account() throws -> String {
        guard !namespace.isEmpty, namespace.utf8.count <= 4096 else { throw RelayCredentialError.invalidNamespace }
        // Store paths and user-selected namespace text need not appear in Keychain metadata.
        let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        return "installation." + digest
    }

    private struct Record: Codable {
        let version: Int
        let origin: URL
        let deviceID: UUID
        let token: String
    }
}

// Internal seam keeps unit tests away from the user's actual Keychain.
protocol RelayCredentialStorage: Sendable {
    func read(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func remove(account: String) throws
}

struct SystemRelayCredentialStorage: RelayCredentialStorage {
    static let service = "mujhtech.dayfold.relay"
    private let items: CredentialKeychainItems

    init(mode: CredentialKeychainMode? = nil, client: any CredentialKeychainAPI = SystemCredentialKeychainAPI()) {
        items = CredentialKeychainItems(service: Self.service, mode: mode, client: client)
    }

    func query(account: String, mode: CredentialKeychainMode) throws -> [String: Any] {
        try items.query(account: account, mode: mode)
    }

    func read(account: String) throws -> Data? {
        do { return try items.read(account: account) }
        catch { throw RelayCredentialError.keychainUnavailable }
    }

    func save(_ data: Data, account: String) throws {
        do { try items.save(data, account: account) }
        catch { throw RelayCredentialError.keychainUnavailable }
    }

    func remove(account: String) throws {
        do { try items.remove(account: account) }
        catch { throw RelayCredentialError.keychainUnavailable }
    }
}
