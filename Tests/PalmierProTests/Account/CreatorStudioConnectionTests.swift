import Foundation
import Testing
@testable import PalmierPro

@Suite("CreatorStudio account connection")
@MainActor
struct CreatorStudioConnectionTests {
    @Test func pairingInstructionsNameBothSupportedAuthorizers() {
        #expect(
            CreatorStudioSession.pairingInstruction(for: "ABCD-EFGH")
                == "Use the ScalePlus ProMax SuperPowers Plugin or ClickCampaigns GodMode MCP to authorize CreatorStudio Editor code ABCD-EFGH."
        )
    }

    @Test func pairingBackoffHonorsServerDelay() {
        #expect(CreatorStudioSession.pairingRetryDelay(retryAfterHeader: "17") == 17)
    }

    @Test func pairingBackoffBoundsInvalidServerDelay() {
        #expect(CreatorStudioSession.pairingRetryDelay(retryAfterHeader: nil) == 5)
        #expect(CreatorStudioSession.pairingRetryDelay(retryAfterHeader: "invalid") == 5)
        #expect(CreatorStudioSession.pairingRetryDelay(retryAfterHeader: "0") == 1)
        #expect(CreatorStudioSession.pairingRetryDelay(retryAfterHeader: "600") == 60)
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
}
