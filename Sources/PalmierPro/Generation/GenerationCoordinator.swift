import Foundation

struct GenerationProviderSelection: Sendable {
    let provider: GenerationProviderID
    let credentialSource: GenerationCredentialSource
}

actor GenerationCoordinator {
    static let shared = GenerationCoordinator()

    func selectProvider(modelID: String) async throws -> GenerationProviderSelection {
        if modelID == CodexImageGeneration.modelID {
            try await CreatorStudioSession.shared.require(.generation, refreshBeforeLocalGeneration: true)
            let available: Bool
            do {
                available = try await CodexAppServer.image.supportsImageGeneration()
            } catch {
                throw GenerationCoordinatorError.codexImageUnavailable(error.localizedDescription)
            }
            return try Self.codexProviderSelection(imageGenerationAvailable: available)
        }

        if modelID.hasPrefix("elevenlabs/") {
            try await CreatorStudioSession.shared.require(.generation, refreshBeforeLocalGeneration: true)
            guard await GenerationCredentialStore.credential(.elevenLabs) != nil else {
                throw GenerationCoordinatorError.elevenLabsKeyMissing
            }
            return GenerationProviderSelection(provider: .elevenLabs, credentialSource: .elevenLabsKeychain)
        }

        try await CreatorStudioSession.shared.require(.generation, refreshBeforeLocalGeneration: true)
        await CreatorStudioSession.shared.refreshCreatorStudioConnection()
        return try Self.providerSelection(
            falConnection: await CreatorStudioSession.shared.falConnection,
            hasLocalFalKey: await GenerationCredentialStore.credential(.fal) != nil
        )
    }

    static func providerSelection(
        falConnection: CreatorStudioFalConnection,
        hasLocalFalKey: Bool
    ) throws -> GenerationProviderSelection {
        switch falConnection {
        case .configured:
            return GenerationProviderSelection(provider: .creatorStudioFal, credentialSource: .creatorStudio)
        case .missing:
            guard hasLocalFalKey else {
                throw GenerationCoordinatorError.falKeyMissing
            }
            return GenerationProviderSelection(provider: .localFal, credentialSource: .localFalKeychain)
        case .unavailable(let message):
            throw GenerationCoordinatorError.creatorStudioUnavailable(message)
        case .unknown:
            throw GenerationCoordinatorError.creatorStudioUnavailable("CreatorStudio connection status is unavailable.")
        }
    }

    static func codexProviderSelection(imageGenerationAvailable: Bool) throws -> GenerationProviderSelection {
        guard imageGenerationAvailable else {
            throw GenerationCoordinatorError.codexImageUnavailable(
                "Update Codex and sign in to use GPT Image 2, or select a Fal.ai image model."
            )
        }
        return GenerationProviderSelection(provider: .codexImage, credentialSource: .codexSubscription)
    }

    func uploadReference(
        fileURL: URL,
        contentType: String,
        kind: String,
        selection: GenerationProviderSelection
    ) async throws -> GenerationUploadReference {
        guard selection.provider != .elevenLabs, selection.provider != .codexImage else {
            throw GenerationCoordinatorError.unsupportedModel("Local provider reference upload")
        }
        return try await CreatorStudioAPIClient.upload(fileURL: fileURL, contentType: contentType, mediaKind: kind)
    }

    func submit(
        modelID: String,
        params: BackendGenerationParams,
        references: [GenerationUploadReference],
        selection: GenerationProviderSelection,
        preparedReference: GenerationJobReference? = nil
    ) async throws -> GenerationJobUpdate {
        let operation = try await MainActor.run {
            guard let operation = ModelCatalog.shared.operation(for: modelID) else {
                throw GenerationCoordinatorError.unsupportedModel(modelID)
            }
            return operation
        }
        let catalogVersion = await MainActor.run { ModelCatalog.shared.catalogVersion(for: modelID) }
        let body = try Self.requestBody(
            modelID: modelID,
            operation: operation,
            params: params,
            references: references
        )
        let snapshot = try Self.snapshot(body)

        switch selection.provider {
        case .codexImage:
            guard case .image(let imageParams) = params else {
                throw GenerationCoordinatorError.unsupportedModel(modelID)
            }
            let localReferences = references.compactMap(\.localFileURL)
            guard localReferences.count == references.count else {
                throw GenerationCoordinatorError.invalidProviderResponse
            }
            let reference = preparedReference ?? Self.codexReference(
                modelID: modelID,
                catalogVersion: catalogVersion,
                snapshot: snapshot
            )
            let output = try await CodexAppServer.image.generateImage(
                prompt: imageParams.prompt,
                aspectRatio: imageParams.aspectRatio,
                quality: imageParams.quality,
                referenceImages: localReferences
            )
            return GenerationJobUpdate(reference: reference, state: .succeeded, resultURLs: [output], error: nil)
        case .creatorStudioFal:
            let idempotencyKey = UUID().uuidString
            let job = try await CreatorStudioAPIClient.submit(body, idempotencyKey: idempotencyKey)
            let reference = GenerationJobReference(
                jobID: job.id,
                provider: .creatorStudioFal,
                credentialSource: .creatorStudio,
                modelID: modelID,
                catalogVersion: job.catalogVersion,
                endpointIDs: job.endpointIds,
                providerRequests: job.providerJobIds,
                requestSnapshot: snapshot,
                resumable: true
            )
            return Self.update(job, reference: reference)
        case .localFal:
            guard let key = await GenerationCredentialStore.credential(.fal) else {
                throw GenerationCoordinatorError.falKeyMissing
            }
            let compiled = try await CreatorStudioAPIClient.compile(body)
            var requests: [GenerationProviderRequest] = []
            do {
                for execution in compiled.executions {
                    requests.append(try await FalQueueClient.submit(execution: execution, apiKey: key))
                }
            } catch {
                for request in requests { try? await FalQueueClient.cancel(request, apiKey: key) }
                throw error
            }
            let reference = GenerationJobReference(
                jobID: UUID().uuidString,
                provider: .localFal,
                credentialSource: .localFalKeychain,
                modelID: modelID,
                catalogVersion: compiled.catalogVersion,
                endpointIDs: compiled.executions.map(\.endpointId),
                providerRequests: requests,
                requestSnapshot: snapshot,
                resumable: true
            )
            return GenerationJobUpdate(reference: reference, state: .queued, resultURLs: [], error: nil)
        case .elevenLabs:
            guard let key = await GenerationCredentialStore.credential(.elevenLabs),
                  case .audio(let audioParams) = params else {
                throw GenerationCoordinatorError.elevenLabsKeyMissing
            }
            let reference = preparedReference ?? Self.elevenLabsReference(
                modelID: modelID,
                catalogVersion: catalogVersion,
                snapshot: snapshot
            )
            let output = try await ElevenLabsClient.generate(
                modelID: modelID,
                params: audioParams,
                references: references,
                apiKey: key
            )
            return GenerationJobUpdate(reference: reference, state: .succeeded, resultURLs: [output], error: nil)
        }
    }

    func prepareNonResumableReference(
        modelID: String,
        params: BackendGenerationParams,
        references: [GenerationUploadReference],
        selection: GenerationProviderSelection
    ) async throws -> GenerationJobReference? {
        guard selection.provider == .elevenLabs || selection.provider == .codexImage else { return nil }
        let operation = try await MainActor.run {
            guard let operation = ModelCatalog.shared.operation(for: modelID) else {
                throw GenerationCoordinatorError.unsupportedModel(modelID)
            }
            return operation
        }
        let body = try Self.requestBody(
            modelID: modelID,
            operation: operation,
            params: params,
            references: references
        )
        let catalogVersion = await MainActor.run { ModelCatalog.shared.catalogVersion(for: modelID) }
        let snapshot = try Self.snapshot(body)
        return switch selection.provider {
        case .codexImage:
            Self.codexReference(modelID: modelID, catalogVersion: catalogVersion, snapshot: snapshot)
        case .elevenLabs:
            Self.elevenLabsReference(modelID: modelID, catalogVersion: catalogVersion, snapshot: snapshot)
        case .creatorStudioFal, .localFal:
            nil
        }
    }

    func refresh(_ reference: GenerationJobReference) async throws -> GenerationJobUpdate {
        switch reference.provider {
        case .codexImage:
            throw GenerationCoordinatorError.interruptedNonResumableRequest(.codexImage)
        case .creatorStudioFal:
            return Self.update(try await CreatorStudioAPIClient.job(id: reference.jobID), reference: reference)
        case .localFal:
            guard let key = await GenerationCredentialStore.credential(.fal) else {
                throw GenerationCoordinatorError.falKeyMissing
            }
            var hasQueued = false
            var hasRunning = false
            for providerRequest in reference.providerRequests {
                switch try await FalQueueClient.status(providerRequest, apiKey: key) {
                case .queued: hasQueued = true
                case .running: hasRunning = true
                case .succeeded: break
                case .failed:
                    return GenerationJobUpdate(
                        reference: reference,
                        state: .failed,
                        resultURLs: [],
                        error: GenerationJobError(code: "fal_job_failed", message: "Fal.ai could not complete this generation.", retryable: false)
                    )
                case .cancelled:
                    return GenerationJobUpdate(
                        reference: reference,
                        state: .cancelled,
                        resultURLs: [],
                        error: nil
                    )
                }
            }
            if hasRunning || hasQueued {
                return GenerationJobUpdate(reference: reference, state: hasRunning ? .running : .queued, resultURLs: [], error: nil)
            }
            var urls: [URL] = []
            for providerRequest in reference.providerRequests {
                urls.append(contentsOf: try await FalQueueClient.resultURLs(providerRequest, apiKey: key))
            }
            return GenerationJobUpdate(reference: reference, state: .succeeded, resultURLs: Self.unique(urls), error: nil)
        case .elevenLabs:
            throw GenerationCoordinatorError.interruptedNonResumableRequest(.elevenLabs)
        }
    }

    func cancel(_ reference: GenerationJobReference) async throws {
        switch reference.provider {
        case .codexImage:
            break
        case .creatorStudioFal:
            _ = try await CreatorStudioAPIClient.cancel(jobID: reference.jobID)
        case .localFal:
            guard let key = await GenerationCredentialStore.credential(.fal) else {
                throw GenerationCoordinatorError.falKeyMissing
            }
            for request in reference.providerRequests { try await FalQueueClient.cancel(request, apiKey: key) }
        case .elevenLabs:
            break
        }
    }

    private static func requestBody(
        modelID: String,
        operation: String,
        params: BackendGenerationParams,
        references: [GenerationUploadReference]
    ) throws -> JSONValue {
        guard var object = try params.encodedJSONValue().objectValue,
              let kind = object.removeValue(forKey: "kind")?.stringValue,
              let prompt = object.removeValue(forKey: "prompt")?.stringValue else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }
        let outputCount: Int
        if case .number(let raw)? = object.removeValue(forKey: "numImages") {
            outputCount = max(1, Int(raw))
        } else {
            outputCount = 1
        }
        let referenceKeys = [
            "sourceVideoURL", "startFrameURL", "endFrameURL", "referenceImageURLs",
            "referenceVideoURLs", "referenceAudioURLs", "imageURLs", "videoURL",
            "sourceURL", "referenceImageURL"
        ]
        for key in referenceKeys { object.removeValue(forKey: key) }
        object["duration"] = object.removeValue(forKey: "durationSeconds") ?? object["duration"]
        return .object([
            "kind": .string(kind),
            "operation": .string(operation),
            "modelId": .string(modelID),
            "prompt": .string(prompt),
            "settings": .object(object),
            "inputReferences": .array(references.map { reference in
                .object(["id": .string(reference.id), "kind": .string(reference.kind)])
            }),
            "outputCount": .number(Double(outputCount)),
        ])
    }

    private static func snapshot(_ body: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(body)
        guard let string = String(data: data, encoding: .utf8) else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }
        return string
    }

    private static func update(_ job: CreatorStudioJob, reference: GenerationJobReference) -> GenerationJobUpdate {
        GenerationJobUpdate(
            reference: GenerationJobReference(
                jobID: reference.jobID,
                provider: reference.provider,
                credentialSource: reference.credentialSource,
                modelID: reference.modelID,
                catalogVersion: job.catalogVersion,
                endpointIDs: job.endpointIds,
                providerRequests: job.providerJobIds,
                requestSnapshot: reference.requestSnapshot,
                resumable: true
            ),
            state: job.status,
            resultURLs: job.outputs.map(\.downloadUrl),
            error: job.error
        )
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func elevenLabsEndpoint(for modelID: String) -> String {
        switch modelID {
        case "elevenlabs/sound-effects": "v1/sound-generation"
        case "elevenlabs/video-to-music": "v1/music/video-to-music"
        case "elevenlabs/music": "v1/music"
        default: "v1/text-to-speech"
        }
    }

    static func codexReference(
        modelID: String,
        catalogVersion: String?,
        snapshot: String
    ) -> GenerationJobReference {
        GenerationJobReference(
            jobID: UUID().uuidString,
            provider: .codexImage,
            credentialSource: .codexSubscription,
            modelID: modelID,
            catalogVersion: catalogVersion,
            endpointIDs: [CodexImageGeneration.endpointID],
            providerRequests: [],
            requestSnapshot: snapshot,
            resumable: false
        )
    }

    private static func elevenLabsReference(
        modelID: String,
        catalogVersion: String?,
        snapshot: String
    ) -> GenerationJobReference {
        GenerationJobReference(
            jobID: UUID().uuidString,
            provider: .elevenLabs,
            credentialSource: .elevenLabsKeychain,
            modelID: modelID,
            catalogVersion: catalogVersion,
            endpointIDs: [elevenLabsEndpoint(for: modelID)],
            providerRequests: [],
            requestSnapshot: snapshot,
            resumable: false
        )
    }
}
