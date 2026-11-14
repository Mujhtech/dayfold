import CalendarCore
import Foundation

public struct RelayAccountIdentity: Sendable, Equatable {
    public let origin: URL
    public let userID: UUID
    public let deviceID: UUID
    public let refreshExpiresAt: Date
}

/// This entire record is one Keychain item. Token pairs and retry intent must
/// never be split across SQLite and Keychain or committed in separate writes.
struct RelayAccountRecord: Codable, Sendable {
    var version = 2
    var origin: URL
    var privateKey: Data
    var tokens: RelaySessionTokens?
    var enrollment: Enrollment?
    var rotation: Rotation?
    var requiresAuthentication: Bool?
    var foreignSession: RelaySessionTokens?
    var foreignRotation: Rotation?
    var cleanupPending: Bool?
    struct Enrollment: Codable, Sendable {
        var challenge: RelayEnrollmentChallenge
        var idToken: String?
        var submittedAt: Date?
    }
    struct Rotation: Codable, Sendable { var requestID: UUID; var startedAt: Date }
}

public actor RelayAccountSession: RelayRequestAuthorizing {
    public nonisolated let origin: URL
    private let vault: RelayCredentialStore
    private let signer: RelayDeviceProof
    private let api: RelayAuthenticationClient
    private let now: @Sendable () -> Date
    private var record: RelayAccountRecord
    private var tokenID = UUID()
    private var active = true
    private var cleared = false
    private var mutationHeld = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    private init(record: RelayAccountRecord, vault: RelayCredentialStore, signer: RelayDeviceProof,
                 api: RelayAuthenticationClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.origin = record.origin; self.record = record; self.vault = vault; self.signer = signer; self.api = api; self.now = now
    }

    public static func open(origin: URL, vault: RelayCredentialStore, allowLoopbackHTTP: Bool = false,
                            transport: (any RelayTransport)? = nil) async throws -> RelayAccountSession {
        let origin = try RelayEndpoint.validatedOrigin(origin, allowLoopbackHTTP: allowLoopbackHTTP)
        if let saved = try await vault.loadAccountRecord() {
            guard saved.origin == origin else { throw RelayClientError.invalidConfiguration }
            let signer = try RelayDeviceProof(origin: origin, privateKey: saved.privateKey, allowLoopbackHTTP: allowLoopbackHTTP)
            return RelayAccountSession(record: saved, vault: vault, signer: signer,
                                       api: try RelayAuthenticationClient(origin: origin, allowLoopbackHTTP: allowLoopbackHTTP, transport: transport))
        }
        let signer = try RelayDeviceProof(origin: origin, allowLoopbackHTTP: allowLoopbackHTTP)
        let record = RelayAccountRecord(origin: origin, privateKey: await signer.privateRepresentation())
        try await vault.saveAccountRecord(record)
        return RelayAccountSession(record: record, vault: vault, signer: signer,
                                   api: try RelayAuthenticationClient(origin: origin, allowLoopbackHTTP: allowLoopbackHTTP, transport: transport))
    }

    public static func savedOrigin(vault: RelayCredentialStore) async throws -> URL? { try await vault.loadAccountRecord()?.origin }

    public func identity() -> RelayAccountIdentity? {
        record.tokens.map { RelayAccountIdentity(origin: origin, userID: $0.userID, deviceID: $0.deviceID, refreshExpiresAt: $0.refreshExpiresAt) }
    }
    public func configuration() async throws -> RelayOIDCConfiguration { try requireActive(); return try await api.configuration() }

    public func beginEnrollment(clientID: String, deviceName: String = "Dayfold for macOS", reauthenticate: Bool = false) async throws -> RelayEnrollmentChallenge {
        await acquireMutation(); defer { releaseMutation() }
        try requireActive()
        guard record.cleanupPending != true else { throw RelayClientError.reauthenticationRequired }
        guard (record.tokens == nil || reauthenticate), record.enrollment?.idToken == nil else { throw RelayClientError.invalidRequest }
        let challenge = try await api.challenge(clientID: clientID, deviceName: deviceName, signer: signer)
        try requireActive()
        guard challenge.expiresAt > now(), challenge.expiresAt <= now().addingTimeInterval(600) else { throw RelayClientError.invalidResponse }
        var next = record; next.enrollment = .init(challenge: challenge)
        try await persist(next)
        return challenge
    }

    public func completeEnrollment(idToken: String) async throws -> RelayAccountIdentity {
        await acquireMutation(); defer { releaseMutation() }
        try requireActive()
        guard !idToken.isEmpty, idToken.utf8.count <= 12_000, var pending = record.enrollment,
              pending.challenge.expiresAt > now() else { throw RelayClientError.unauthorized }
        pending.idToken = idToken; pending.submittedAt = now()
        var next = record; next.enrollment = pending
        try await persist(next)
        return try await recoverEnrollmentLocked()
    }

    public func hasPendingEnrollment() -> Bool { record.enrollment?.idToken != nil }
    public func restartExpiredEnrollment() async throws -> Bool {
        await acquireMutation(); defer { releaseMutation() }
        try requireActive()
        guard let submitted = record.enrollment?.submittedAt, submitted.addingTimeInterval(300) <= now(), record.foreignSession == nil else { return false }
        // A new browser login reuses this key. The server can recover the same
        // device; never replace the key merely because a response was lost.
        var next = record; next.enrollment = nil
        try await persist(next)
        return true
    }
    public func needsAuthentication() -> Bool {
        record.requiresAuthentication == true || record.tokens.map { $0.refreshExpiresAt <= now() } == true
    }

    public func recoverEnrollment() async throws -> RelayAccountIdentity {
        await acquireMutation(); defer { releaseMutation() }
        return try await recoverEnrollmentLocked()
    }

    private func recoverEnrollmentLocked() async throws -> RelayAccountIdentity {
        try requireActive()
        if record.foreignSession != nil {
            try await revokeForeignSession()
            throw RelayClientError.identityMismatch
        }
        if let identity = identity(), record.enrollment == nil { return identity }
        guard let pending = record.enrollment, let idToken = pending.idToken, let submitted = pending.submittedAt,
              submitted.addingTimeInterval(300) > now() else { throw RelayClientError.unauthorized }
        let tokens = try await api.enroll(challengeID: pending.challenge.id, idToken: idToken, signer: signer)
        try requireActive(); try tokens.validate(now: now())
        if let previous = record.tokens, previous.userID != tokens.userID {
            var next = record; next.foreignSession = tokens
            try await persist(next)
            try await revokeForeignSession()
            throw RelayClientError.identityMismatch
        }
        var next = record; next.tokens = tokens; next.enrollment = nil; next.rotation = nil; next.requiresAuthentication = false
        try await persist(next)
        tokenID = UUID()
        return identity()!
    }

    public func authorization(method: String, url: URL, rejecting id: UUID?) async throws -> RelayRequestAuthorization {
        await acquireMutation(); defer { releaseMutation() }
        try requireActive()
        guard record.requiresAuthentication != true, record.cleanupPending != true else { throw RelayClientError.reauthenticationRequired }
        guard record.enrollment == nil else { throw RelayClientError.authenticationInProgress }
        guard let current = record.tokens else { throw RelayClientError.unauthorized }
        let tokens: RelaySessionTokens
        if record.rotation != nil || current.accessExpiresAt <= now().addingTimeInterval(60) || id == tokenID {
            tokens = try await performRefresh()
        } else { tokens = current }
        try requireActive()
        let proof = try await signer.proof(method: method, url: url, accessToken: tokens.accessToken)
        try requireActive()
        return RelayRequestAuthorization(id: tokenID, headers: ["Authorization": "DPoP " + tokens.accessToken, "DPoP": proof], expiresAt: tokens.accessExpiresAt)
    }

    private func performRefresh() async throws -> RelaySessionTokens {
        try requireActive()
        guard let old = record.tokens else { throw RelayClientError.unauthorized }
        if record.rotation == nil {
            var next = record; next.rotation = .init(requestID: UUID(), startedAt: now())
            try await persist(next)
        }
        guard let pending = record.rotation else { throw RelayClientError.invalidRequest }
        let tokens: RelaySessionTokens
        do { tokens = try await api.refresh(token: old.refreshToken, requestID: pending.requestID, signer: signer) }
        catch RelayClientError.reauthenticationRequired {
            record.requiresAuthentication = true
            try await persist(record)
            throw RelayClientError.reauthenticationRequired
        }
        try requireActive(); try tokens.validate(now: now())
        guard tokens.userID == old.userID, tokens.deviceID == old.deviceID,
              tokens.refreshToken != old.refreshToken else { throw RelayClientError.invalidResponse }
        var next = record; next.tokens = tokens; next.rotation = nil
        // Do not expose a rotated access token until its refresh successor is
        // durable. On failure the old pair + operation ID remain retryable.
        try await persist(next)
        tokenID = UUID()
        return tokens
    }

    private func persist(_ next: RelayAccountRecord) async throws {
        try requireActive()
        do { try await vault.saveAccountRecord(next) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RelayClientError.credentialsUnavailable }
        try requireActive()
        record = next
    }

    private func revokeForeignSession() async throws {
        guard var foreign = record.foreignSession else { return }
        do {
            if foreign.accessExpiresAt <= now().addingTimeInterval(60) { foreign = try await refreshForeignSession(foreign) }
            do { try await api.revokeIssuedSession(foreign, signer: signer) }
            catch RelayClientError.unauthorized {
                // A lost DELETE response is confirmed by terminal refresh;
                // generic proof or clock errors must not erase the retry intent.
                foreign = try await refreshForeignSession(foreign)
                try await api.revokeIssuedSession(foreign, signer: signer)
            }
        } catch RelayClientError.reauthenticationRequired { /* The server confirmed revocation. */ }
        var next = record; next.foreignSession = nil; next.foreignRotation = nil; next.enrollment = nil
        try await persist(next)
    }

    private func refreshForeignSession(_ old: RelaySessionTokens) async throws -> RelaySessionTokens {
        if record.foreignRotation == nil {
            var next = record; next.foreignRotation = .init(requestID: UUID(), startedAt: now())
            try await persist(next)
        }
        let tokens = try await api.refresh(token: old.refreshToken, requestID: record.foreignRotation!.requestID, signer: signer)
        try tokens.validate(now: now())
        guard tokens.userID == old.userID, tokens.deviceID == old.deviceID else { throw RelayClientError.invalidResponse }
        var next = record; next.foreignSession = tokens; next.foreignRotation = nil
        try await persist(next)
        return tokens
    }

    /// A successful remote revoke is recorded before local cleanup. A failed
    /// Keychain delete leaves an explicit, retryable local-only cleanup state.
    public func confirmRevocation() async throws {
        await acquireMutation(); defer { releaseMutation() }
        if cleared { return }
        try requireActive()
        record.cleanupPending = true
        try await persist(record)
    }

    public func revocationConfirmed() -> Bool {
        record.cleanupPending == true || record.requiresAuthentication == true
    }

    public func discardUnissuedSetup() async throws -> Bool {
        await acquireMutation(); defer { releaseMutation() }
        try requireActive()
        guard record.tokens == nil, record.enrollment?.idToken == nil, record.foreignSession == nil else { return false }
        try await deleteRecordLocked()
        return true
    }

    public func cancelUnsubmittedEnrollment() async throws {
        await acquireMutation(); defer { releaseMutation() }
        try requireActive()
        guard record.enrollment?.idToken == nil else { return }
        var next = record; next.enrollment = nil
        try await persist(next)
    }

    public func clear() async throws {
        await acquireMutation(); defer { releaseMutation() }
        if cleared { return }
        try requireActive()
        guard (record.tokens == nil && record.enrollment?.idToken == nil && record.foreignSession == nil) || revocationConfirmed() else { throw RelayClientError.invalidRequest }
        try await deleteRecordLocked()
    }

    private func deleteRecordLocked() async throws {
        do { try await vault.deleteAccountRecord() }
        catch is CancellationError { throw CancellationError() }
        catch { throw RelayClientError.credentialsUnavailable }
        active = false; cleared = true
    }

    public func invalidate() async {
        active = false
        // Wait for the outstanding Keychain operation before the caller rebinds
        // its vault. No queued operation may write after this barrier returns.
        await acquireMutation(); releaseMutation()
    }

    private func acquireMutation() async {
        if !mutationHeld { mutationHeld = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }
    private func releaseMutation() {
        if mutationWaiters.isEmpty { mutationHeld = false }
        else { mutationWaiters.removeFirst().resume() }
    }
    private func requireActive() throws {
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
    }
}
