import Foundation

public struct RelayRequestAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let headers: [String: String]
    public let expiresAt: Date?
    public var description: String { "RelayRequestAuthorization(credentials: [REDACTED])" }
    public var debugDescription: String { description }
    public init(id: UUID, headers: [String: String], expiresAt: Date? = nil) {
        self.id = id; self.headers = headers; self.expiresAt = expiresAt
    }
}

public protocol RelayRequestAuthorizing: Sendable {
    /// Rejecting an old token must reuse a newer token already issued to another
    /// concurrent request, rather than rotating the refresh family twice.
    func authorization(method: String, url: URL, rejecting id: UUID?) async throws -> RelayRequestAuthorization
}

public protocol RelayProofSigning: Sendable {
    func proof(method: String, url: URL, accessToken: String?) async throws -> String
}

public struct RelayOIDCConfiguration: Codable, Sendable, Equatable {
    public let issuer: URL
    public let clientID: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    enum CodingKeys: String, CodingKey {
        case issuer; case clientID = "client_id", authorizationEndpoint = "authorization_endpoint", tokenEndpoint = "token_endpoint"
    }
    public init(issuer: URL, clientID: String, authorizationEndpoint: URL, tokenEndpoint: URL) {
        self.issuer = issuer; self.clientID = clientID; self.authorizationEndpoint = authorizationEndpoint; self.tokenEndpoint = tokenEndpoint
    }
    public func validate() throws {
        guard !clientID.isEmpty, clientID.utf8.count <= 512 else { throw RelayClientError.invalidResponse }
        for url in [issuer, authorizationEndpoint, tokenEndpoint] {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
                  parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.fragment == nil else {
                throw RelayClientError.invalidResponse
            }
        }
    }
}

public struct RelayEnrollmentChallenge: Codable, Sendable, Equatable {
    public let id: UUID
    public let nonce: String
    public let expiresAt: Date
    enum CodingKeys: String, CodingKey { case id, nonce; case expiresAt = "expires_at" }
    public init(id: UUID, nonce: String, expiresAt: Date) { self.id = id; self.nonce = nonce; self.expiresAt = expiresAt }
}

public struct RelaySessionTokens: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let userID: UUID
    public let deviceID: UUID
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    public let accessExpiresAt: Date
    public let refreshExpiresAt: Date
    public var description: String { "RelaySessionTokens(credentials: [REDACTED])" }
    public var debugDescription: String { description }
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", deviceID = "device_id", accessToken = "access_token", refreshToken = "refresh_token"
        case tokenType = "token_type", accessExpiresAt = "access_expires_at", refreshExpiresAt = "refresh_expires_at"
    }
    public init(userID: UUID, deviceID: UUID, accessToken: String, refreshToken: String, tokenType: String = "DPoP", accessExpiresAt: Date, refreshExpiresAt: Date) {
        self.userID = userID; self.deviceID = deviceID; self.accessToken = accessToken; self.refreshToken = refreshToken
        self.tokenType = tokenType; self.accessExpiresAt = accessExpiresAt; self.refreshExpiresAt = refreshExpiresAt
    }
    public func validate(now: Date = Date()) throws {
        guard tokenType == "DPoP", accessExpiresAt > now.addingTimeInterval(-60), refreshExpiresAt > now,
              accessExpiresAt <= refreshExpiresAt else { throw RelayClientError.invalidResponse }
        do { try RelayEndpoint.validateToken(accessToken); try RelayEndpoint.validateToken(refreshToken) }
        catch { throw RelayClientError.invalidResponse }
    }
}

public struct RelayAccountDevice: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let deviceName: String
    public let createdAt: Date
    public let lastSeenAt: Date?
    enum CodingKeys: String, CodingKey { case id; case deviceName = "device_name", createdAt = "created_at", lastSeenAt = "last_seen_at" }
}

/// No Google Calendar tokens or permissions cross this account-authentication API.
public struct RelayAuthenticationClient: Sendable {
    public let origin: URL
    private let transport: any RelayTransport
    public init(origin: URL, allowLoopbackHTTP: Bool = false, transport: (any RelayTransport)? = nil) throws {
        self.origin = try RelayEndpoint.validatedOrigin(origin, allowLoopbackHTTP: allowLoopbackHTTP)
        self.transport = transport ?? RelayURLSessionTransport(includeErrorBody: true)
    }
    public func configuration() async throws -> RelayOIDCConfiguration {
        let value: RelayOIDCConfiguration = try await request("GET", path: "v1/auth/config")
        try value.validate()
        return value
    }
    public func challenge(clientID: String, deviceName: String, signer: any RelayProofSigning) async throws -> RelayEnrollmentChallenge {
        let body = ChallengeRequest(clientID: clientID, deviceName: deviceName)
        let value: RelayEnrollmentChallenge = try await request("POST", path: "v1/auth/challenges", body: RelayJSON.encoder().encode(body), signer: signer)
        guard !value.nonce.isEmpty, value.nonce.utf8.count <= 512 else { throw RelayClientError.invalidResponse }
        return value
    }
    public func enroll(challengeID: UUID, idToken: String, signer: any RelayProofSigning) async throws -> RelaySessionTokens {
        try await request("POST", path: "v1/auth/enroll", body: RelayJSON.encoder().encode(EnrollmentRequest(challengeID: challengeID, idToken: idToken)), signer: signer)
    }
    public func refresh(token: String, requestID: UUID, signer: any RelayProofSigning) async throws -> RelaySessionTokens {
        try await request("POST", path: "v1/auth/refresh", body: RelayJSON.encoder().encode(RefreshRequest(refreshToken: token, requestID: requestID)), signer: signer)
    }
    public func revokeIssuedSession(_ tokens: RelaySessionTokens, signer: any RelayProofSigning) async throws {
        let url = origin.appendingPathComponent("v1/device")
        var request = URLRequest(url: url); request.httpMethod = "DELETE"
        request.setValue("DPoP " + tokens.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(try await signer.proof(method: "DELETE", url: url, accessToken: tokens.accessToken), forHTTPHeaderField: "DPoP")
        let response = try await transport.send(request)
        guard response.head.url == url else { throw RelayClientError.invalidResponse }
        switch response.head.status {
        case 200..<300: return
        case 401: throw RelayClientError.unauthorized
        case 429: throw RelayClientError.rateLimited(retryAfter: RelayClient.retryAfter(response.head.header("Retry-After")))
        case 500...599: throw RelayClientError.unavailable(retryAfter: RelayClient.retryAfter(response.head.header("Retry-After")))
        default: throw RelayClientError.rejected(status: response.head.status)
        }
    }
    private func request<T: Decodable & Sendable>(_ method: String, path: String, body: Data? = nil, signer: (any RelayProofSigning)? = nil) async throws -> T {
        let url = origin.appendingPathComponent(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let signer { request.setValue(try await signer.proof(method: method, url: url, accessToken: nil), forHTTPHeaderField: "DPoP") }
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            guard response.head.url == url, response.body.count <= 65_536 else { throw RelayClientError.invalidResponse }
            switch response.head.status {
            case 200..<300: break
            case 401:
                let code = (try? JSONDecoder().decode(AuthError.self, from: response.body))?.error
                if path == "v1/auth/refresh", code == "reauthentication_required" { throw RelayClientError.reauthenticationRequired }
                throw RelayClientError.unauthorized
            case 409: throw RelayClientError.sessionSuperseded
            case 403, 410: throw RelayClientError.unauthorized
            case 429: throw RelayClientError.rateLimited(retryAfter: RelayClient.retryAfter(response.head.header("Retry-After")))
            case 500...599: throw RelayClientError.unavailable(retryAfter: RelayClient.retryAfter(response.head.header("Retry-After")))
            default: throw RelayClientError.rejected(status: response.head.status)
            }
            do { return try RelayJSON.decoder().decode(T.self, from: response.body) }
            catch { throw RelayClientError.invalidResponse }
        } catch { throw RelayClient.sanitized(error) }
    }
}

private struct ChallengeRequest: Encodable {
    let clientID: String; let deviceName: String
    enum CodingKeys: String, CodingKey { case clientID = "client_id", deviceName = "device_name" }
}
private struct EnrollmentRequest: Encodable {
    let challengeID: UUID; let idToken: String
    enum CodingKeys: String, CodingKey { case challengeID = "challenge_id", idToken = "id_token" }
}
private struct RefreshRequest: Encodable {
    let refreshToken: String; let requestID: UUID
    enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token", requestID = "request_id" }
}
private struct AuthError: Decodable { let error: String }
