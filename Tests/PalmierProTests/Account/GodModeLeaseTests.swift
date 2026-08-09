import CryptoKit
import Foundation
import Testing
@testable import PalmierPro

@Suite("GodMode offline lease")
@MainActor
struct GodModeLeaseTests {
    @Test func localBypassRequiresExactOptIn() {
        #expect(LocalGodModeBypass.isRequested(in: [LocalGodModeBypass.environmentKey: "1"]))
        #expect(!LocalGodModeBypass.isRequested(in: [:]))
        #expect(!LocalGodModeBypass.isRequested(in: [LocalGodModeBypass.environmentKey: "true"]))
    }

    @Test func expiredAccessStateDoesNotPermitProtectedFeatures() {
        #expect(!GodModeAccess.active(expiresAt: .distantPast).permitsProtectedFeatures)
        #expect(!GodModeAccess.offlineLease(expiresAt: .distantPast).permitsProtectedFeatures)
        #expect(GodModeAccess.active(expiresAt: .distantFuture).permitsProtectedFeatures)
    }

    @Test func rejectsInsecureAPIDestinations() {
        #expect(throws: (any Error).self) {
            try CreatorStudioConfiguration.load(environment: [
                "CREATORSTUDIO_API_BASE_URL": "http://creator.example.test",
                "CLICKCAMPAIGNS_API_BASE_URL": "https://click.example.test",
            ])
        }
        #expect(throws: (any Error).self) {
            try CreatorStudioConfiguration.load(environment: [
                "CREATORSTUDIO_API_BASE_URL": "https://creator.example.test?redirect=https://attacker.test",
                "CLICKCAMPAIGNS_API_BASE_URL": "https://click.example.test",
            ])
        }
    }

    @Test func acceptsValidSignedLease() throws {
        let key = Curve25519.Signing.PrivateKey()
        let lease = try makeLease(key: key)

        let claims = try CreatorStudioSession.verifyLease(
            lease,
            publicKey: key.publicKey.rawRepresentation,
            audience: "creatorstudio-editor",
            subject: "user-1"
        )

        #expect(claims.subject == "user-1")
        #expect(claims.godmode)
    }

    @Test(arguments: [LeaseDefect.expired, .wrongAudience, .wrongSubject, .overlong, .wrongAlgorithm])
    func rejectsInvalidClaims(_ defect: LeaseDefect) throws {
        let key = Curve25519.Signing.PrivateKey()
        let lease = try makeLease(key: key, defect: defect)

        #expect(throws: (any Error).self) {
            try CreatorStudioSession.verifyLease(
                lease,
                publicKey: key.publicKey.rawRepresentation,
                audience: "creatorstudio-editor",
                subject: "user-1"
            )
        }
    }

    @Test func rejectsForgedSignature() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let differentKey = Curve25519.Signing.PrivateKey()
        let lease = try makeLease(key: signer)

        #expect(throws: (any Error).self) {
            try CreatorStudioSession.verifyLease(
                lease,
                publicKey: differentKey.publicKey.rawRepresentation,
                audience: "creatorstudio-editor",
                subject: "user-1"
            )
        }
    }

    enum LeaseDefect: Sendable, Equatable {
        case expired
        case wrongAudience
        case wrongSubject
        case overlong
        case wrongAlgorithm
    }

    private func makeLease(
        key: Curve25519.Signing.PrivateKey,
        defect: LeaseDefect? = nil
    ) throws -> String {
        let now = Date().timeIntervalSince1970
        let issuedAt = defect == .expired ? now - 7_200 : now - 30
        let expiry: TimeInterval = switch defect {
        case .expired: now - 3_600
        case .overlong: issuedAt + 8 * 24 * 60 * 60
        default: now + 6 * 24 * 60 * 60
        }
        let header: [String: Any] = [
            "alg": defect == .wrongAlgorithm ? "RS256" : "EdDSA",
            "kid": "creatorstudio-editor-test",
            "typ": "JWT",
        ]
        let payload: [String: Any] = [
            "sub": defect == .wrongSubject ? "user-2" : "user-1",
            "aud": defect == .wrongAudience ? ["another-client"] : ["creatorstudio-editor"],
            "iat": issuedAt,
            "exp": expiry,
            "godmode": true,
        ]
        let encodedHeader = try base64URL(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let encodedPayload = try base64URL(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URL(signature))"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
