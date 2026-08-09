import Foundation
import Testing
@testable import PalmierPro

@Suite("Generation providers")
struct GenerationProviderTests {
    @Test func CreatorStudioKeyHasPriorityOverLocalKey() throws {
        let selected = try GenerationCoordinator.providerSelection(
            falConnection: .configured(maskedKey: "••••1234"),
            hasLocalFalKey: true
        )
        #expect(selected.provider == .creatorStudioFal)
        #expect(selected.credentialSource == .creatorStudio)
    }

    @Test func localKeyIsUsedOnlyWhenCreatorStudioReportsMissing() throws {
        let selected = try GenerationCoordinator.providerSelection(
            falConnection: .missing,
            hasLocalFalKey: true
        )
        #expect(selected.provider == .localFal)
        #expect(selected.credentialSource == .localFalKeychain)
    }

    @Test func CreatorStudioFailureDoesNotSilentlySwitchKeys() {
        #expect(throws: GenerationCoordinatorError.self) {
            try GenerationCoordinator.providerSelection(
                falConnection: .unavailable("Connection failed."),
                hasLocalFalKey: true
            )
        }
    }

    @Test func generationMetadataRoundTripsWithoutCredentials() throws {
        let providerRequest = GenerationProviderRequest(
            endpointID: "fal-ai/flux/schnell",
            requestID: "provider-request-1"
        )
        var input = GenerationInput(
            prompt: "A lighthouse at dusk",
            model: "fal-ai/flux/schnell",
            duration: 0,
            aspectRatio: "16:9"
        )
        input.providerID = .localFal
        input.credentialSource = .localFalKeychain
        input.catalogVersion = "2026-08-07.1"
        input.endpointIDs = [providerRequest.endpointID]
        input.externalJobID = "job-1"
        input.providerRequests = [providerRequest]
        input.requestSnapshot = #"{"kind":"image","modelId":"fal-ai/flux/schnell"}"#
        input.isJobResumable = true

        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(GenerationInput.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded == input)
        #expect(!json.lowercased().contains("api_key"))
        #expect(!json.contains("Key "))
        #expect(!json.contains("Bearer "))
    }

    @Test(arguments: ["request-1", "abc_DEF_123"])
    func acceptsSafeFalRequestIdentifiers(_ value: String) {
        #expect(FalQueueClient.isValidRequestID(value))
    }

    @Test(arguments: ["", "../status", "request/other", "request?token=secret"])
    func rejectsUnsafeFalRequestIdentifiers(_ value: String) {
        #expect(!FalQueueClient.isValidRequestID(value))
    }
}
