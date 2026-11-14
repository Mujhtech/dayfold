import CalendarCore
import CryptoKit
import Foundation
import Testing
@testable import CalendarPlatform

private let accountOrigin = try! RelayEndpoint.validatedOrigin(URL(string: "https://relay.example.test")!)

private final class SessionVaultFixture: RelayCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    private var writesBlocked = false
    private var deletesBlocked = false
    func blockDeletes(_ blocked: Bool) { lock.withLock { deletesBlocked = blocked } }
    func blockWrites(_ blocked: Bool) { lock.withLock { writesBlocked = blocked } }
    func read(account: String) throws -> Data? { lock.withLock { records[account] } }
    func save(_ data: Data, account: String) throws {
        try lock.withLock {
            if writesBlocked { throw RelayCredentialError.keychainUnavailable }
            records[account] = data
        }
    }
    func remove(account: String) throws {
        try lock.withLock {
            if deletesBlocked { throw RelayCredentialError.keychainUnavailable }
            records[account] = nil
        }
    }
}

private actor SessionBarrier {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func waitForEntry() async { while !entered { await Task.yield() } }
}

private actor AccountTransportFixture: RelayTransport {
    let challenge = RelayEnrollmentChallenge(id: UUID(), nonce: "server-one-use-nonce", expiresAt: Date().addingTimeInterval(300))
    var enrollmentTokens: RelaySessionTokens
    var refreshTokens: RelaySessionTokens
    var requests: [URLRequest] = []
    var failEnrollment = false
    var failRefresh = false
    var refreshError: (Int, String)?
    var revokeError: Int?
    var afterRefresh: (@Sendable () -> Void)?
    var barrier: SessionBarrier?
    init(enrollmentTokens: RelaySessionTokens, refreshTokens: RelaySessionTokens) {
        self.enrollmentTokens = enrollmentTokens; self.refreshTokens = refreshTokens
    }
    func loseNextEnrollment() { failEnrollment = true }
    func loseNextRefresh() { failRefresh = true }
    func configureRevokeError(_ status: Int?) { revokeError = status }
    func configureRefreshError(_ error: (Int, String)?) { refreshError = error }
    func configureAfterRefresh(_ action: @escaping @Sendable () -> Void) { afterRefresh = action }
    func configureBarrier(_ value: SessionBarrier) { barrier = value }
    func matching(_ path: String) -> [URLRequest] { requests.filter { $0.url?.path == path } }
    func send(_ request: URLRequest) async throws -> RelayHTTPResponse {
        requests.append(request)
        let path = request.url!.path
        switch path {
        case "/v1/auth/challenges": return try response(challenge, request: request)
        case "/v1/auth/enroll":
            if failEnrollment { failEnrollment = false; throw URLError(.networkConnectionLost) }
            return try response(enrollmentTokens, request: request)
        case "/v1/auth/refresh":
            if let barrier { await barrier.pause() }
            if failRefresh { failRefresh = false; throw URLError(.networkConnectionLost) }
            if let (status, code) = refreshError {
                return RelayHTTPResponse(head: RelayHTTPHead(url: request.url!, status: status, headers: [:]), body: try JSONEncoder().encode(["error": code]))
            }
            afterRefresh?()
            return try response(refreshTokens, request: request)
        case "/v1/device": return RelayHTTPResponse(head: RelayHTTPHead(url: request.url!, status: revokeError ?? 204, headers: [:]))
        case "/v1/notifications/cursor":
            if request.value(forHTTPHeaderField: "Authorization") == "DPoP " + refreshTokens.accessToken {
                return try response(RelayCursor(floor: 0, current: 7), request: request)
            }
            return RelayHTTPResponse(head: RelayHTTPHead(url: request.url!, status: 401, headers: [:]))
        default: throw RelayClientError.invalidRequest
        }
    }
    nonisolated func stream(_ request: URLRequest) -> RelayTransportStream { RelayTransportStream(events: AsyncThrowingStream { $0.finish() }, cancel: {}) }
    private func response<T: Encodable>(_ value: T, request: URLRequest) throws -> RelayHTTPResponse {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return RelayHTTPResponse(head: RelayHTTPHead(url: request.url!, status: 200, headers: ["Content-Type": "application/json"]), body: try encoder.encode(value))
    }
}

private func tokenPair(user: UUID = UUID(), device: UUID = UUID(), access: Character = "a", refresh: Character = "b", expiredAccess: Bool = false) -> RelaySessionTokens {
    RelaySessionTokens(userID: user, deviceID: device, accessToken: String(repeating: String(access), count: 64), refreshToken: String(repeating: String(refresh), count: 64),
                       accessExpiresAt: Date().addingTimeInterval(expiredAccess ? -1 : 600), refreshExpiresAt: Date().addingTimeInterval(7 * 86400))
}

private struct AccountFixture {
    let storage: SessionVaultFixture
    let vault: RelayCredentialStore
    let api: AccountTransportFixture
    let session: RelayAccountSession
    let old: RelaySessionTokens
    let next: RelaySessionTokens
    static func make(expiredAccess: Bool = false) async throws -> Self {
        let storage = SessionVaultFixture()
        let vault = RelayCredentialStore(namespace: UUID().uuidString, storage: storage)
        let old = tokenPair(expiredAccess: expiredAccess)
        let next = tokenPair(user: old.userID, device: old.deviceID, access: "c", refresh: "d")
        try await vault.saveAccountRecord(RelayAccountRecord(origin: accountOrigin, privateKey: P256.Signing.PrivateKey().rawRepresentation, tokens: old))
        let api = AccountTransportFixture(enrollmentTokens: old, refreshTokens: next)
        let session = try await RelayAccountSession.open(origin: accountOrigin, vault: vault, transport: api)
        return Self(storage: storage, vault: vault, api: api, session: session, old: old, next: next)
    }
}

private func proofClaims(_ request: URLRequest) throws -> [String: Any] {
    let compact = try #require(request.value(forHTTPHeaderField: "DPoP"))
    let pieces = compact.split(separator: ".")
    var segment = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    segment += String(repeating: "=", count: (4 - segment.count % 4) % 4)
    return try JSONSerialization.jsonObject(with: #require(Data(base64Encoded: segment))) as! [String: Any]
}

@Test func relayAccountRefreshIsSingleFlightAndRejectingAnOldLeaseReusesTheNewToken() async throws {
    let fixture = try await AccountFixture.make()
    let url = accountOrigin.appendingPathComponent("v1/notifications")
    let oldLease = try await fixture.session.authorization(method: "GET", url: url, rejecting: nil)
    let leases = try await withThrowingTaskGroup(of: RelayRequestAuthorization.self) { group in
        for _ in 0..<12 { group.addTask { try await fixture.session.authorization(method: "GET", url: url, rejecting: oldLease.id) } }
        var values: [RelayRequestAuthorization] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(leases.allSatisfy { $0.headers["Authorization"] == "DPoP " + fixture.next.accessToken })
    #expect(Set(leases.map(\.id)).count == 1)
    #expect(await fixture.api.matching("/v1/auth/refresh").count == 1)
    _ = try await fixture.session.authorization(method: "GET", url: url, rejecting: oldLease.id)
    #expect(await fixture.api.matching("/v1/auth/refresh").count == 1)
    #expect(try await fixture.vault.loadAccountRecord()?.tokens?.refreshToken == fixture.next.refreshToken)
}

@Test func relayAccountLostRotationResponseSurvivesRestartWithSameRequestIDAndFreshProof() async throws {
    let fixture = try await AccountFixture.make(expiredAccess: true)
    await fixture.api.loseNextRefresh()
    let url = accountOrigin.appendingPathComponent("v1/notifications")
    await #expect(throws: RelayClientError.transport) { try await fixture.session.authorization(method: "GET", url: url, rejecting: nil) }
    let pending = try #require(try await fixture.vault.loadAccountRecord()?.rotation)
    await fixture.session.invalidate()
    let restored = try await RelayAccountSession.open(origin: accountOrigin, vault: fixture.vault, transport: fixture.api)
    let lease = try await restored.authorization(method: "GET", url: url, rejecting: nil)
    #expect(lease.headers["Authorization"] == "DPoP " + fixture.next.accessToken)
    let attempts = await fixture.api.matching("/v1/auth/refresh")
    #expect(attempts.count == 2)
    for attempt in attempts {
        let json = try JSONSerialization.jsonObject(with: #require(attempt.httpBody)) as! [String: Any]
        #expect(json["request_id"] as? String == pending.requestID.uuidString)
        #expect(json["refresh_token"] as? String == fixture.old.refreshToken)
        #expect(try proofClaims(attempt)["ath"] == nil)
    }
    #expect(try proofClaims(attempts[0])["jti"] as? String != proofClaims(attempts[1])["jti"] as? String)
    #expect(try await fixture.vault.loadAccountRecord()?.rotation == nil)
}

@Test func relayAccountDoesNotExposeRotationUntilSuccessorIsDurable() async throws {
    let fixture = try await AccountFixture.make(expiredAccess: true)
    await fixture.api.configureAfterRefresh { fixture.storage.blockWrites(true) }
    let url = accountOrigin.appendingPathComponent("v1/notifications")
    await #expect(throws: RelayClientError.credentialsUnavailable) { try await fixture.session.authorization(method: "GET", url: url, rejecting: nil) }
    #expect(try await fixture.vault.loadAccountRecord()?.tokens?.refreshToken == fixture.old.refreshToken)
    #expect(try await fixture.vault.loadAccountRecord()?.rotation != nil)
    fixture.storage.blockWrites(false)
    await fixture.api.configureAfterRefresh { }
    let lease = try await fixture.session.authorization(method: "GET", url: url, rejecting: nil)
    #expect(lease.headers["Authorization"] == "DPoP " + fixture.next.accessToken)
    let attempts = await fixture.api.matching("/v1/auth/refresh")
    #expect(attempts.count == 2)
    let first = try JSONDecoder().decode([String: String].self, from: #require(attempts[0].httpBody))
    let second = try JSONDecoder().decode([String: String].self, from: #require(attempts[1].httpBody))
    #expect(first == second)
}

@Test func relayAccountEnrollmentResponseLossRecoversTheSameDeviceAfterRestart() async throws {
    let vault = RelayCredentialStore(namespace: UUID().uuidString, storage: SessionVaultFixture())
    let tokens = tokenPair()
    let api = AccountTransportFixture(enrollmentTokens: tokens, refreshTokens: tokens)
    let session = try await RelayAccountSession.open(origin: accountOrigin, vault: vault, transport: api)
    _ = try await session.beginEnrollment(clientID: "native-client")
    await api.loseNextEnrollment()
    await #expect(throws: RelayClientError.transport) { try await session.completeEnrollment(idToken: "fixture-id-token") }
    #expect(try await vault.loadAccountRecord()?.enrollment?.idToken == "fixture-id-token")
    await session.invalidate()
    let restored = try await RelayAccountSession.open(origin: accountOrigin, vault: vault, transport: api)
    #expect(try await restored.recoverEnrollment().deviceID == tokens.deviceID)
    let attempts = await api.matching("/v1/auth/enroll")
    #expect(attempts.count == 2)
    let first = try JSONDecoder().decode([String: String].self, from: #require(attempts[0].httpBody))
    let second = try JSONDecoder().decode([String: String].self, from: #require(attempts[1].httpBody))
    #expect(first == second)
    #expect(try proofClaims(attempts[0])["jti"] as? String != proofClaims(attempts[1])["jti"] as? String)
    #expect(try await vault.loadAccountRecord()?.enrollment == nil)
}

@Test func relayAccountWrongUserEnrollmentIsRevokedWithoutReplacingTheOriginalAccount() async throws {
    let fixture = try await AccountFixture.make()
    let foreign = tokenPair(access: "e", refresh: "f")
    let api = AccountTransportFixture(enrollmentTokens: foreign, refreshTokens: fixture.next)
    let session = try await RelayAccountSession.open(origin: accountOrigin, vault: fixture.vault, transport: api)
    _ = try await session.beginEnrollment(clientID: "native-client", reauthenticate: true)
    await #expect(throws: RelayClientError.identityMismatch) { try await session.completeEnrollment(idToken: "different-user-token") }
    #expect(try await fixture.vault.loadAccountRecord()?.tokens?.userID == fixture.old.userID)
    let revoke = try #require(await api.matching("/v1/device").first)
    #expect(revoke.value(forHTTPHeaderField: "Authorization") == "DPoP " + foreign.accessToken)
    #expect(try proofClaims(revoke)["ath"] != nil)
    #expect(try await fixture.vault.loadAccountRecord()?.foreignSession == nil)
}

@Test func relayAccountGenericAuthorizationFailuresDoNotClaimDeviceRevocation() async throws {
    let fixture = try await AccountFixture.make(expiredAccess: true)
    let url = accountOrigin.appendingPathComponent("v1/notifications")
    await fixture.api.configureRefreshError((401, "unauthorized"))
    await #expect(throws: RelayClientError.unauthorized) { try await fixture.session.authorization(method: "GET", url: url, rejecting: nil) }
    #expect(try await fixture.vault.loadAccountRecord()?.requiresAuthentication != true)
    await fixture.api.configureRefreshError((409, "rotation_superseded"))
    await #expect(throws: RelayClientError.sessionSuperseded) { try await fixture.session.authorization(method: "GET", url: url, rejecting: nil) }
    #expect(try await fixture.vault.loadAccountRecord()?.requiresAuthentication != true)
    await fixture.api.configureRefreshError((401, "reauthentication_required"))
    await #expect(throws: RelayClientError.reauthenticationRequired) { try await fixture.session.authorization(method: "GET", url: url, rejecting: nil) }
    #expect(try await fixture.vault.loadAccountRecord()?.requiresAuthentication == true)
}

@Test func relayAccountInvalidationPreventsAnInFlightRefreshFromOverwritingCredentials() async throws {
    let fixture = try await AccountFixture.make(expiredAccess: true)
    let barrier = SessionBarrier(); await fixture.api.configureBarrier(barrier)
    let pending = Task { try await fixture.session.authorization(method: "GET", url: accountOrigin.appendingPathComponent("v1/events"), rejecting: nil) }
    await barrier.waitForEntry()
    let release = Task {
        try await Task.sleep(for: .milliseconds(20))
        await barrier.release()
    }
    await fixture.session.invalidate()
    try await release.value
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(try await fixture.vault.loadAccountRecord()?.tokens?.refreshToken == fixture.old.refreshToken)
    #expect(try await fixture.vault.loadAccountRecord()?.rotation != nil)
}

@Test func relayClientRecoversOneUnauthorizedResourceRequestWithDPoP() async throws {
    let fixture = try await AccountFixture.make()
    let client = try RelayClient(baseURL: accountOrigin, authorizer: fixture.session, transport: fixture.api)
    #expect(try await client.cursor().current == 7)
    let requests = await fixture.api.matching("/v1/notifications/cursor")
    #expect(requests.count == 2)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "DPoP " + fixture.old.accessToken)
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "DPoP " + fixture.next.accessToken)
    #expect(try proofClaims(requests[0])["ath"] as? String != proofClaims(requests[1])["ath"] as? String)
}

@Test func relayAccountConfirmedCleanupSurvivesKeychainDeleteFailureAndRestart() async throws {
    let fixture = try await AccountFixture.make()
    try await fixture.session.confirmRevocation()
    fixture.storage.blockDeletes(true)
    await #expect(throws: RelayClientError.credentialsUnavailable) { try await fixture.session.clear() }
    #expect(try await fixture.vault.loadAccountRecord()?.cleanupPending == true)
    await #expect(throws: RelayClientError.reauthenticationRequired) {
        try await fixture.session.authorization(method: "GET", url: accountOrigin.appendingPathComponent("v1/events"), rejecting: nil)
    }
    let restored = try await RelayAccountSession.open(origin: accountOrigin, vault: fixture.vault, transport: fixture.api)
    #expect(await restored.revocationConfirmed())
    fixture.storage.blockDeletes(false)
    try await restored.clear()
    try await restored.clear()
    try await restored.confirmRevocation()
    #expect(try await fixture.vault.loadAccountRecord() == nil)
    #expect(await fixture.api.matching("/v1/auth/refresh").isEmpty)
}

@Test func relayAccountRevocationMarkerWriteFailureRemainsRetryableInMemory() async throws {
    let fixture = try await AccountFixture.make()
    fixture.storage.blockWrites(true)
    await #expect(throws: RelayClientError.credentialsUnavailable) { try await fixture.session.confirmRevocation() }
    #expect(await fixture.session.revocationConfirmed())
    fixture.storage.blockWrites(false)
    try await fixture.session.confirmRevocation()
    #expect(try await fixture.vault.loadAccountRecord()?.cleanupPending == true)
    try await fixture.session.clear()
    #expect(try await fixture.vault.loadAccountRecord() == nil)
}

@Test func relayAccountUnsubmittedBrowserEnrollmentPausesAuthorizationUntilCancelled() async throws {
    let fixture = try await AccountFixture.make(expiredAccess: true)
    _ = try await fixture.session.beginEnrollment(clientID: "native-client", reauthenticate: true)
    await #expect(throws: RelayClientError.authenticationInProgress) {
        try await fixture.session.authorization(method: "GET", url: accountOrigin.appendingPathComponent("v1/events"), rejecting: nil)
    }
    #expect(await fixture.api.matching("/v1/auth/refresh").isEmpty)
    try await fixture.session.cancelUnsubmittedEnrollment()
    let authorization = try await fixture.session.authorization(method: "GET", url: accountOrigin.appendingPathComponent("v1/events"), rejecting: nil)
    #expect(authorization.headers["Authorization"] == "DPoP " + fixture.next.accessToken)
}

@Test func relayAccountEnrollmentWaitsForRotationAndPreservesItsDurableSuccessor() async throws {
    let fixture = try await AccountFixture.make(expiredAccess: true)
    let barrier = SessionBarrier(); await fixture.api.configureBarrier(barrier)
    let refresh = Task { try await fixture.session.authorization(method: "GET", url: accountOrigin.appendingPathComponent("v1/events"), rejecting: nil) }
    await barrier.waitForEntry()
    let enrollment = Task { try await fixture.session.beginEnrollment(clientID: "native-client", reauthenticate: true) }
    await barrier.release()
    _ = try await refresh.value
    _ = try await enrollment.value
    let record = try #require(try await fixture.vault.loadAccountRecord())
    #expect(record.tokens?.refreshToken == fixture.next.refreshToken)
    #expect(record.rotation == nil)
    #expect(record.enrollment != nil)
}

@Test func relayAccountCanDiscardOnlyAnUnissuedSetup() async throws {
    let vault = RelayCredentialStore(namespace: UUID().uuidString, storage: SessionVaultFixture())
    let tokens = tokenPair()
    let api = AccountTransportFixture(enrollmentTokens: tokens, refreshTokens: tokens)
    let session = try await RelayAccountSession.open(origin: accountOrigin, vault: vault, transport: api)
    _ = try await session.beginEnrollment(clientID: "native-client")
    #expect(try await session.discardUnissuedSetup())
    #expect(try await vault.loadAccountRecord() == nil)
    let pending = try await RelayAccountSession.open(origin: accountOrigin, vault: vault, transport: api)
    _ = try await pending.beginEnrollment(clientID: "native-client")
    await api.loseNextEnrollment()
    await #expect(throws: RelayClientError.transport) { try await pending.completeEnrollment(idToken: "fixture-id-token") }
    #expect(try await pending.discardUnissuedSetup() == false)
    await #expect(throws: RelayClientError.invalidRequest) { try await pending.clear() }
    #expect(try await vault.loadAccountRecord()?.enrollment?.idToken == "fixture-id-token")
    try await pending.cancelUnsubmittedEnrollment()
    #expect(try await vault.loadAccountRecord()?.enrollment?.idToken == "fixture-id-token")
}

@Test func relayAccountForeignSessionCleanupPreservesIntentUntilKeyVerifiedTerminalRefresh() async throws {
    let fixture = try await AccountFixture.make()
    let foreign = tokenPair(access: "e", refresh: "f")
    let api = AccountTransportFixture(enrollmentTokens: foreign, refreshTokens: fixture.next)
    let session = try await RelayAccountSession.open(origin: accountOrigin, vault: fixture.vault, transport: api)
    await api.configureRevokeError(503)
    _ = try await session.beginEnrollment(clientID: "native-client", reauthenticate: true)
    await #expect(throws: RelayClientError.unavailable(retryAfter: nil)) { try await session.completeEnrollment(idToken: "different-user-token") }
    #expect(try await fixture.vault.loadAccountRecord()?.foreignSession?.userID == foreign.userID)
    await api.configureRevokeError(401)
    await api.configureRefreshError((401, "unauthorized"))
    await #expect(throws: RelayClientError.unauthorized) { try await session.recoverEnrollment() }
    #expect(try await fixture.vault.loadAccountRecord()?.foreignSession != nil)
    await api.configureRefreshError((409, "rotation_superseded"))
    await #expect(throws: RelayClientError.sessionSuperseded) { try await session.recoverEnrollment() }
    #expect(try await fixture.vault.loadAccountRecord()?.foreignSession != nil)
    await api.configureRefreshError((401, "reauthentication_required"))
    await #expect(throws: RelayClientError.identityMismatch) { try await session.recoverEnrollment() }
    let record = try #require(try await fixture.vault.loadAccountRecord())
    #expect(record.foreignSession == nil && record.foreignRotation == nil && record.enrollment == nil)
    #expect(record.tokens?.userID == fixture.old.userID)
    #expect(record.requiresAuthentication != true)
}
