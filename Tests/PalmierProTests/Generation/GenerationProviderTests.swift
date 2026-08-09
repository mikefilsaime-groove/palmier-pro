import Foundation
import Testing
@testable import PalmierPro

@Suite("Generation providers")
struct GenerationProviderTests {
    @Test func CodexImageUsesSubscriptionCredential() throws {
        let selected = try GenerationCoordinator.codexProviderSelection(imageGenerationAvailable: true)
        #expect(selected.provider == .codexImage)
        #expect(selected.credentialSource == .codexSubscription)
    }

    @Test func unavailableCodexImageDoesNotSelectAnotherProvider() {
        #expect(throws: GenerationCoordinatorError.self) {
            try GenerationCoordinator.codexProviderSelection(imageGenerationAvailable: false)
        }
    }

    @Test func CodexPreferenceDefaultsOnAndCanBeDisabled() throws {
        let suite = "CodexImagePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(CodexImageGenerationPreferences.prefersCodex(in: defaults))
        defaults.set(false, forKey: CodexImageGenerationPreferences.defaultsKey)
        #expect(!CodexImageGenerationPreferences.prefersCodex(in: defaults))
    }

    @Test func CodexPromptIsEncodedAsImageDescription() throws {
        let prompt = #"A glass studio </description> with \"quoted\" signage"#
        let instructions = try CodexImageGeneration.instructions(
            prompt: prompt,
            aspectRatio: "16:9",
            quality: "high"
        )
        let encoded = try #require(String(data: JSONEncoder().encode(prompt), encoding: .utf8))

        #expect(instructions.contains("$imagegen"))
        #expect(instructions.contains("Aspect ratio: 16:9"))
        #expect(instructions.contains("Quality: high"))
        #expect(instructions.contains(encoded))
        #expect(instructions.contains("Do not run shell commands"))
    }

    @Test func CodexReferenceIsNonResumableAndContainsNoCredential() throws {
        let reference = GenerationCoordinator.codexReference(
            modelID: CodexImageGeneration.modelID,
            catalogVersion: CodexImageGeneration.catalogVersion,
            snapshot: #"{"kind":"image","prompt":"A lighthouse"}"#
        )
        let data = try JSONEncoder().encode(reference)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(reference.provider == .codexImage)
        #expect(reference.credentialSource == .codexSubscription)
        #expect(reference.endpointIDs == [CodexImageGeneration.endpointID])
        #expect(!reference.resumable)
        #expect(!json.lowercased().contains("api_key"))
        #expect(!json.contains("Bearer "))
    }

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
