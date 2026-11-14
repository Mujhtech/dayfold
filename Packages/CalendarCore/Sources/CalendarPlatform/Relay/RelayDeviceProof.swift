import CalendarCore
import CryptoKit
import Foundation

/// RFC 9449 proof of possession. The P-256 key is software-generated and kept
/// in this Mac's Keychain; this is key possession, not hardware attestation.
public actor RelayDeviceProof: RelayProofSigning {
    private let key: P256.Signing.PrivateKey
    private let origin: URL
    private let now: @Sendable () -> Date

    public init(origin: URL, privateKey: Data? = nil, allowLoopbackHTTP: Bool = false) throws {
        self.origin = try RelayEndpoint.validatedOrigin(origin, allowLoopbackHTTP: allowLoopbackHTTP)
        self.key = try privateKey.map { try P256.Signing.PrivateKey(rawRepresentation: $0) } ?? P256.Signing.PrivateKey()
        self.now = { Date() }
    }
    init(origin: URL, privateKey: Data, now: @escaping @Sendable () -> Date) throws {
        self.origin = origin; self.key = try P256.Signing.PrivateKey(rawRepresentation: privateKey); self.now = now
    }
    func privateRepresentation() -> Data { key.rawRepresentation }

    public func thumbprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return RelayBase64URL.encode(Data(SHA256.hash(data: try encoder.encode(publicJWK()))))
    }

    public func proof(method: String, url: URL, accessToken: String?) throws -> String {
        try Task.checkCancellation()
        let target = try Self.target(url)
        guard let expected = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let actual = URLComponents(string: target), expected.scheme == actual.scheme,
              expected.host == actual.host, Self.port(expected) == Self.port(actual),
              ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"].contains(method) else { throw RelayClientError.invalidRequest }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = try encoder.encode(Header(jwk: publicJWK()))
        let claims = Claims(htm: method, htu: target, iat: Int64(now().timeIntervalSince1970), jti: UUID().uuidString.lowercased(),
                            ath: accessToken.map { RelayBase64URL.encode(Data(SHA256.hash(data: Data($0.utf8)))) })
        let signingInput = RelayBase64URL.encode(header) + "." + RelayBase64URL.encode(try encoder.encode(claims))
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + RelayBase64URL.encode(signature)
    }

    static func target(_ url: URL) throws -> String {
        guard var value = URLComponents(url: url, resolvingAgainstBaseURL: false), value.host != nil,
              value.user == nil, value.password == nil else { throw RelayClientError.invalidRequest }
        value.scheme = value.scheme?.lowercased(); value.host = value.host?.lowercased()
        value.query = nil; value.fragment = nil
        if (value.scheme == "https" && value.port == 443) || (value.scheme == "http" && value.port == 80) { value.port = nil }
        if value.path.isEmpty { value.path = "/" }
        guard let target = value.url?.absoluteString else { throw RelayClientError.invalidRequest }
        return target
    }
    private static func port(_ parts: URLComponents) -> Int { parts.port ?? (parts.scheme == "https" ? 443 : 80) }
    private func publicJWK() -> JWK {
        let bytes = key.publicKey.x963Representation
        return JWK(x: RelayBase64URL.encode(bytes.subdata(in: 1..<33)), y: RelayBase64URL.encode(bytes.subdata(in: 33..<65)))
    }
    private struct JWK: Encodable { let kty = "EC"; let crv = "P-256"; let x: String; let y: String }
    private struct Header: Encodable { let typ = "dpop+jwt"; let alg = "ES256"; let jwk: JWK }
    private struct Claims: Encodable { let htm: String; let htu: String; let iat: Int64; let jti: String; let ath: String? }
}

enum RelayBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
