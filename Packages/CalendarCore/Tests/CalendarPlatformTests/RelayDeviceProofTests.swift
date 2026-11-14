import CalendarCore
import CryptoKit
import Foundation
import Testing
@testable import CalendarPlatform

private let proofFixtureTime = Date(timeIntervalSince1970: 1_793_966_400)
private let proofFixtureKey = Data(repeating: 1, count: 32)

private struct DecodedDeviceProof {
    let header: [String: Any]
    let claims: [String: Any]
    let signingInput: Data
    let signature: Data

    init(_ proof: String) throws {
        let parts = proof.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        header = try #require(JSONSerialization.jsonObject(with: Self.decode(String(parts[0]))) as? [String: Any])
        claims = try #require(JSONSerialization.jsonObject(with: Self.decode(String(parts[1]))) as? [String: Any])
        signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        signature = try Self.decode(String(parts[2]))
    }

    static func decode(_ value: String) throws -> Data {
        #expect(!value.contains("="))
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return try #require(Data(base64Encoded: base64))
    }

    func publicKey() throws -> P256.Signing.PublicKey {
        let jwk = try #require(header["jwk"] as? [String: String])
        let x = try Self.decode(#require(jwk["x"]))
        let y = try Self.decode(#require(jwk["y"]))
        #expect(x.count == 32 && y.count == 32)
        return try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
    }
}

private func deviceProofFixture() throws -> RelayDeviceProof {
    try RelayDeviceProof(origin: URL(string: "https://relay.example/")!, privateKey: proofFixtureKey, now: { proofFixtureTime })
}

@Test func relayDeviceProofSignatureVerifiesWithOnlyItsPublicHeaderKey() async throws {
    let signer = try deviceProofFixture()
    let token = try await signer.proof(method: "POST", url: URL(string: "https://relay.example/v1/auth/enroll")!, accessToken: nil)
    let proof = try DecodedDeviceProof(token)
    #expect(proof.header["typ"] as? String == "dpop+jwt")
    #expect(proof.header["alg"] as? String == "ES256")
    #expect(Set(proof.header.keys) == Set(["typ", "alg", "jwk"]))
    let jwk = try #require(proof.header["jwk"] as? [String: String])
    #expect(Set(jwk.keys) == Set(["kty", "crv", "x", "y"]))
    #expect(jwk["kty"] == "EC" && jwk["crv"] == "P-256")
    #expect(proof.signature.count == 64)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: proof.signature)
    let publicKey = try proof.publicKey()
    #expect(publicKey.isValidSignature(signature, for: proof.signingInput))
    #expect(!publicKey.isValidSignature(signature, for: proof.signingInput + Data("tampered".utf8)))
    let otherKey = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
    #expect(!otherKey.publicKey.isValidSignature(signature, for: proof.signingInput))
}

@Test func relayDeviceProofThumbprintMatchesIndependentRFC7638Vector() async throws {
    // Public coordinates were derived with OpenSSL from the public test scalar
    // 0x01 repeated32 times; canonical JSON was hashed independently with SHA256.
    let signer = try deviceProofFixture()
    let thumbprint = try await signer.thumbprint()
    #expect(thumbprint == "Nrqg3-M_Xwtx-1tbtc1J7Xul2DyeC0bUSy9u_5NSG6g")
    let proof = try DecodedDeviceProof(await signer.proof(method: "POST", url: URL(string: "https://relay.example/v1/auth/challenges")!, accessToken: nil))
    let jwk = try #require(proof.header["jwk"] as? [String: String])
    #expect(jwk["x"] == "b_A7lJJBzh2t1DUZ5pYOCoW0GmmgXDKBA6orzhWUyhY")
    #expect(jwk["y"] == "PE91OlW_AdxT9sCwx-7ni0DG_30lqW4igrmJzvccFEo")
}

@Test func relayDeviceProofBindsMethodAndNormalizedOriginPathWithoutQueryOrFragment() async throws {
    let signer = try deviceProofFixture()
    let proof = try DecodedDeviceProof(await signer.proof(method: "GET", url: URL(string: "https://RELAY.example:443/v1/notifications?after=42#ignored")!, accessToken: "fixture-access"))
    #expect(proof.claims["htm"] as? String == "GET")
    #expect(proof.claims["htu"] as? String == "https://relay.example/v1/notifications")
    #expect((proof.claims["iat"] as? NSNumber)?.int64Value == 1_793_966_400)
    #expect(proof.claims["nonce"] == nil)
}

@Test func relayDeviceProofHashesAccessTokensOnlyOnProtectedResourceRequests() async throws {
    let signer = try deviceProofFixture()
    let target = URL(string: "https://relay.example/v1/notifications")!
    let accessToken = "fixture-access-token"
    let resource = try DecodedDeviceProof(await signer.proof(method: "GET", url: target, accessToken: accessToken))
    let actual = try DecodedDeviceProof.decode(#require(resource.claims["ath"] as? String))
    #expect(actual == Data(SHA256.hash(data: Data(accessToken.utf8))))
    for path in ["/v1/auth/challenges", "/v1/auth/enroll", "/v1/auth/refresh"] {
        let proof = try DecodedDeviceProof(await signer.proof(method: "POST", url: URL(string: "https://relay.example\(path)")!, accessToken: nil))
        #expect(proof.claims["ath"] == nil)
    }
}

@Test func relayDeviceProofUsesFreshUUIDForEveryRequestEvenAtTheSameInstant() async throws {
    let signer = try deviceProofFixture()
    var identifiers = Set<UUID>()
    for _ in 0..<16 {
        let proof = try DecodedDeviceProof(await signer.proof(method: "POST", url: URL(string: "https://relay.example/v1/auth/refresh")!, accessToken: nil))
        let text = try #require(proof.claims["jti"] as? String)
        let identifier = try #require(UUID(uuidString: text))
        #expect(text.count == 36 && text == text.lowercased())
        #expect(identifiers.insert(identifier).inserted)
    }
}

@Test func relayDeviceProofRejectsCrossOriginCredentialsPortsAndInvalidMethods() async throws {
    let signer = try deviceProofFixture()
    for target in [
        "https://other.example/v1/auth/enroll", "http://relay.example/v1/auth/enroll",
        "https://relay.example:444/v1/auth/enroll", "https://user@relay.example/v1/auth/enroll",
        "https://user:password@relay.example/v1/auth/enroll"
    ] {
        await #expect(throws: RelayClientError.invalidRequest) {
            try await signer.proof(method: "POST", url: URL(string: target)!, accessToken: nil)
        }
    }
    for method in ["post", "get", "", "POST\n", "TRACE"] {
        await #expect(throws: RelayClientError.invalidRequest) {
            try await signer.proof(method: method, url: URL(string: "https://relay.example/v1/auth/enroll")!, accessToken: nil)
        }
    }
}

@Test func relayDeviceProofRejectsInsecureOriginsUnlessExplicitLoopbackDevelopment() throws {
    for origin in ["http://relay.example/", "https://user@relay.example/", "https://relay.example/path", "https://relay.example/?query"] {
        #expect(throws: RelayClientError.invalidConfiguration) {
            try RelayDeviceProof(origin: URL(string: origin)!, privateKey: proofFixtureKey)
        }
    }
    #expect(throws: RelayClientError.invalidConfiguration) {
        try RelayDeviceProof(origin: URL(string: "http://127.0.0.1:8080")!, privateKey: proofFixtureKey)
    }
    _ = try RelayDeviceProof(origin: URL(string: "http://127.0.0.1:8080")!, privateKey: proofFixtureKey, allowLoopbackHTTP: true)
}
