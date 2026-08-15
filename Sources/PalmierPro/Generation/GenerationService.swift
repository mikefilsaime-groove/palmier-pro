import Foundation

/// Used by replace-clip callbacks so only the
/// first successful asset of an N-image generation swaps the clip
@MainActor
final class FirstOnlyFlag {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

@MainActor
final class GenerationService {

    private var resumedBackendJobIds: Set<String> = []
    private var generationTasks: [String: GenerationTask] = [:]

    private struct GenerationTask {
        let groupID: UUID
        let task: Task<Void, Never>
    }

    private struct PreparedReferences {
        let uploaded: [GenerationUploadReference]
        let tempFiles: [URL]
    }

    @discardableResult
    func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        placeholderDuration: Double,
        references: [MediaAsset] = [],
        transientReferences: [GenerationUploadReference] = [],
        temporaryFiles: [URL] = [],
        trimmedSourceOverride: TrimmedSource? = nil,
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil,
        buildParams: @escaping ([String]) -> BackendGenerationParams,
        snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)? = nil,
        preprocessRef: (@Sendable (Int, MediaAsset, URL) async throws -> URL?)? = nil,
        preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)? = nil,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let count = max(1, min(4, numImages))
        let baseName = name ?? String(genInput.prompt.prefix(30))

        let resolvedFolderId = folderId.flatMap { id in
            editor.folder(id: id) != nil ? id : nil
        }
        var placeholders: [MediaAsset] = []
        let destDir = Self.destinationDirectory(for: projectURL)

        for outputIndex in 0..<count {
            var placeholderInput = genInput
            placeholderInput.outputIndex = outputIndex
            let placeholder = createPlaceholder(
                type: assetType,
                name: baseName,
                duration: placeholderDuration,
                genInput: placeholderInput,
                folderId: resolvedFolderId,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            placeholders.append(placeholder)
        }
        let primaryId = placeholders[0].id
        captureSubmission(genInput: genInput, assetType: assetType, outputCount: count, editor: editor)

        let taskGroupID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                for placeholder in placeholders
                where self.generationTasks[placeholder.id]?.groupID == taskGroupID {
                    self.generationTasks.removeValue(forKey: placeholder.id)
                }
            }
            do {
                let selection = try await GenerationCoordinator.shared.selectProvider(modelID: genInput.model)
                let prepared = try await self.prepareReferences(
                    references: references,
                    transientReferences: transientReferences,
                    temporaryFiles: temporaryFiles,
                    trimmedSourceOverride: trimmedSourceOverride,
                    preprocessRef: preprocessRef,
                    preprocessSourceVideo: preprocessSourceVideo,
                    selection: selection
                )
                let uploaded = prepared.uploaded.map(\.id)

                var finalGenInput = genInput
                if let snapshotRefs {
                    snapshotRefs(&finalGenInput, uploaded)
                } else {
                    finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
                }
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                for (outputIndex, placeholder) in placeholders.enumerated() {
                    var storedInput = finalGenInput
                    storedInput.outputIndex = outputIndex
                    updateGenerationMetadata(placeholder, editor: editor) { input in
                        input = storedInput
                    }
                }

                let params = buildParams(uploaded)
                do {
                    let preparedReference = try await GenerationCoordinator.shared.prepareNonResumableReference(
                        modelID: finalGenInput.model,
                        params: params,
                        references: prepared.uploaded,
                        selection: selection
                    )
                    if let preparedReference {
                        for placeholder in placeholders {
                            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                                Self.apply(preparedReference, to: &input)
                            }
                        }
                        editor.onProjectCheckpointRequired?()
                    }
                    let update = try await GenerationCoordinator.shared.submit(
                        modelID: finalGenInput.model,
                        params: params,
                        references: prepared.uploaded,
                        selection: selection,
                        preparedReference: preparedReference
                    )
                    await self.runJob(
                        placeholders: placeholders,
                        genInput: finalGenInput,
                        initialUpdate: update,
                        editor: editor,
                        onComplete: onComplete,
                        onFailure: onFailure
                    )
                    await Self.cleanupTempFiles(prepared.tempFiles)
                } catch {
                    await Self.cleanupTempFiles(prepared.tempFiles)
                    throw error
                }
            } catch {
                await Self.cleanupTempFiles(temporaryFiles)
                let message = Task.isCancelled ? "Generation cancelled" : error.localizedDescription
                Log.generation.error("generation preparation failed model=\(genInput.model) error=\(message)")
                for placeholder in placeholders {
                    updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
                }
                onFailure?()
            }
        }
        for placeholder in placeholders {
            generationTasks[placeholder.id] = GenerationTask(groupID: taskGroupID, task: task)
        }

        return primaryId
    }

    private func captureSubmission(
        genInput: GenerationInput,
        assetType: ClipType,
        outputCount: Int,
        editor: EditorViewModel
    ) {
        Log.generation.notice(
            "generation submitted model=\(genInput.model) type=\(Self.generationType(assetType: assetType, genInput: genInput)) outputs=\(outputCount)"
        )
    }

    nonisolated static func generationType(assetType: ClipType, genInput: GenerationInput) -> String {
        genInput.upscaleSettings == nil ? assetType.rawValue : "upscale"
    }

    private func prepareReferences(
        references: [MediaAsset],
        transientReferences: [GenerationUploadReference],
        temporaryFiles: [URL],
        trimmedSourceOverride: TrimmedSource?,
        preprocessRef: (@Sendable (Int, MediaAsset, URL) async throws -> URL?)?,
        preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)?,
        selection: GenerationProviderSelection
    ) async throws -> PreparedReferences {
        var tempFiles = temporaryFiles
        do {
            var urlsToUpload = references.map(\.url)
            let refTypes = references.map(\.type)
            if let trim = trimmedSourceOverride, trim.hasTrim,
               let index = urlsToUpload.firstIndex(of: trim.sourceURL) {
                Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[index].lastPathComponent)")
                let extracted = try await VideoTrimExtractor.extract(trim)
                urlsToUpload[index] = extracted
                tempFiles.append(extracted)
            }
            if let preprocessSourceVideo, let sourceURL = urlsToUpload.first,
               let processed = try await preprocessSourceVideo(sourceURL) {
                urlsToUpload[0] = processed
                tempFiles.append(processed)
            }
            if let preprocessRef, !references.isEmpty {
                let rewrites = try await preprocessedReferenceURLs(
                    references: references,
                    currentURLs: urlsToUpload,
                    preprocessRef: preprocessRef
                )
                for (i, rewritten) in rewrites {
                    guard let rewritten else { continue }
                    urlsToUpload[i] = rewritten
                    tempFiles.append(rewritten)
                }
            }
            let uploaded = try await uploadReferences(
                at: urlsToUpload,
                types: refTypes,
                stableIDs: references.map(\.id),
                selection: selection
            )
            return PreparedReferences(uploaded: uploaded + transientReferences, tempFiles: tempFiles)
        } catch {
            await Self.cleanupTempFiles(tempFiles)
            throw error
        }
    }

    private func preprocessedReferenceURLs(
        references: [MediaAsset],
        currentURLs: [URL],
        preprocessRef: @escaping @Sendable (Int, MediaAsset, URL) async throws -> URL?
    ) async throws -> [(Int, URL?)] {
        try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
            for (i, asset) in references.enumerated() {
                let currentURL = currentURLs[i]
                group.addTask { (i, try await preprocessRef(i, asset, currentURL)) }
            }
            var results: [(Int, URL?)] = []
            for try await result in group { results.append(result) }
            return results
        }
    }

    @concurrent private static func cleanupTempFiles(_ urls: [URL]) async {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Shared

    private func createPlaceholder(
        type: ClipType,
        name: String,
        duration: Double,
        genInput: GenerationInput,
        folderId: String?,
        destDir: URL,
        fileExtension: String,
        editor: EditorViewModel
    ) -> MediaAsset {
        let id = UUID().uuidString
        let destURL = destDir.appendingPathComponent("gen-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(
            id: id,
            url: destURL,
            type: type,
            name: name,
            duration: duration,
            generationInput: genInput
        )
        placeholder.generationStatus = .preparing
        placeholder.folderId = folderId
        editor.importMediaAsset(placeholder)
        return placeholder
    }

    private static func destinationDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            return projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    @discardableResult
    private func downloadAndFinalize(asset: MediaAsset, remoteURL: URL, editor: EditorViewModel) async -> Bool {
        if asset.generationStatus != .downloading {
            updateGenerationMetadata(asset, editor: editor, status: .downloading)
        }
        do {
            let tempURL = if remoteURL.isFileURL {
                remoteURL
            } else {
                try await URLSession.shared.download(from: remoteURL).0
            }
            let realExt = remoteURL.pathExtension.lowercased()
            if !realExt.isEmpty, realExt != asset.url.pathExtension.lowercased(),
               ClipType(fileExtension: realExt) != nil {
                asset.url = asset.url.deletingPathExtension().appendingPathExtension(realExt)
            }
            asset.url = try await editor.commitStagedProjectMedia(tempURL, filename: asset.url.lastPathComponent)

            asset.pendingDownloadURL = nil
            editor.importMediaAsset(asset, skipAppend: true)
            let finalized = await editor.finalizeImportedAsset(asset)
            return finalized
        } catch {
            let message = error.localizedDescription
            Log.generation.error("download failed host=\(remoteURL.host ?? "local") error=\(message)")
            asset.pendingDownloadURL = remoteURL
            updateGenerationMetadata(asset, editor: editor, status: .failed(message))
            return false
        }
    }

    func retryDownload(asset: MediaAsset, editor: EditorViewModel) {
        guard let remoteURL = asset.pendingDownloadURL else { return }
        Task { @MainActor in
            await downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
        }
    }

    func cancelGeneration(asset: MediaAsset, editor: EditorViewModel) {
        guard asset.isGenerating else { return }
        let taskRecord = generationTasks[asset.id]
        let relatedAssets = taskRecord.map { record in
            editor.mediaAssets.filter { generationTasks[$0.id]?.groupID == record.groupID }
        } ?? [asset]
        taskRecord?.task.cancel()
        let reference = asset.generationInput.flatMap(Self.jobReference(from:))
        Task { @MainActor in
            do {
                if let reference {
                    try await GenerationCoordinator.shared.cancel(reference)
                }
                for relatedAsset in relatedAssets {
                    updateGenerationMetadata(relatedAsset, editor: editor, status: .failed("Generation cancelled"))
                }
            } catch {
                for relatedAsset in relatedAssets {
                    updateGenerationMetadata(
                        relatedAsset,
                        editor: editor,
                        status: .failed("Cancellation failed: \(error.localizedDescription)")
                    )
                }
            }
            editor.onProjectCheckpointRequired?()
        }
    }

    @discardableResult
    func enhanceDraft(asset: MediaAsset, editor: EditorViewModel) -> String? {
        nil
    }

    func resumePendingGenerations(editor: EditorViewModel) {
        func sorted(_ assets: [MediaAsset]) -> [MediaAsset] {
            assets.sorted {
                let left = $0.generationInput?.outputIndex ?? 0
                let right = $1.generationInput?.outputIndex ?? 0
                return left < right
            }
        }

        let pending = editor.mediaAssets.filter(\.isRecoveringGeneration)

        let byBackendJob = Dictionary(grouping: pending.compactMap { asset -> (GenerationJobReference, MediaAsset)? in
            guard let input = asset.generationInput, let reference = Self.jobReference(from: input) else { return nil }
            return (reference, asset)
        }, by: { $0.0 })

        for (reference, group) in byBackendJob where !resumedBackendJobIds.contains(reference.jobID) {
            let placeholders = sorted(group.map { $0.1 })
            resumedBackendJobIds.insert(reference.jobID)
            Task { @MainActor [weak self, weak editor] in
                guard let self, let editor else { return }
                await self.monitorBackendJob(
                    reference: reference,
                    placeholders: placeholders,
                    editor: editor,
                    onComplete: nil,
                    onFailure: nil
                )
                self.resumedBackendJobIds.remove(reference.jobID)
            }
        }
    }

    private static func jobReference(from input: GenerationInput) -> GenerationJobReference? {
        guard let jobID = input.externalJobID ?? input.backendJobId,
              let provider = input.providerID,
              let credentialSource = input.credentialSource,
              let requestSnapshot = input.requestSnapshot else { return nil }
        return GenerationJobReference(
            jobID: jobID,
            provider: provider,
            credentialSource: credentialSource,
            modelID: input.model,
            catalogVersion: input.catalogVersion,
            endpointIDs: input.endpointIDs ?? [],
            providerRequests: input.providerRequests ?? [],
            requestSnapshot: requestSnapshot,
            resumable: input.isJobResumable == true
        )
    }

    private func updateGenerationMetadata(
        _ asset: MediaAsset,
        editor: EditorViewModel,
        status: MediaAsset.GenerationStatus? = nil,
        mutateInput: ((inout GenerationInput) -> Void)? = nil
    ) {
        if let status {
            asset.generationStatus = status
        }
        if let mutateInput, var input = asset.generationInput {
            mutateInput(&input)
            asset.generationInput = input
        }
        editor.updateManifestMetadata(for: [asset])
    }

    /// Uploads each reference and returns the hosted URLs.
    private func uploadReferences(
        at urls: [URL],
        types: [ClipType],
        stableIDs: [String],
        selection: GenerationProviderSelection
    ) async throws -> [GenerationUploadReference] {
        guard !urls.isEmpty else { return [] }
        if selection.provider == .elevenLabs || selection.provider == .codexImage {
            return urls.enumerated().map { index, url in
                GenerationUploadReference(
                    id: stableIDs.indices.contains(index) ? stableIDs[index] : UUID().uuidString,
                    kind: types.indices.contains(index) ? types[index].rawValue : ClipType.image.rawValue,
                    localFileURL: url
                )
            }
        }
        return try await withThrowingTaskGroup(of: (Int, GenerationUploadReference).self) { group in
            for (i, url) in urls.enumerated() {
                let type = types.indices.contains(i) ? types[i] : .image
                let requiresConversion = type == .image
                    && ImageConverter.requiresConversion(url)
                let contentType = requiresConversion
                    ? "image/jpeg"
                    : Self.contentType(for: url, fallback: type)
                group.addTask {
                    let convertedURL = requiresConversion
                        ? try await ImageConverter.convertToJPEG(url)
                        : nil
                    do {
                        let uploaded = try await GenerationCoordinator.shared.uploadReference(
                            fileURL: convertedURL ?? url,
                            contentType: contentType,
                            kind: type.rawValue,
                            selection: selection
                        )
                        if let convertedURL {
                            await ImageConverter.removeConvertedFile(convertedURL)
                        }
                        return (i, uploaded)
                    } catch {
                        if let convertedURL {
                            await ImageConverter.removeConvertedFile(convertedURL)
                        }
                        throw error
                    }
                }
            }
            var results = [(Int, GenerationUploadReference)]()
            for try await r in group { results.append(r) }
            return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    private static func contentType(for url: URL, fallback: ClipType) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aiff", "aif", "aifc": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default:
            switch fallback {
            case .image: return "image/jpeg"
            case .video: return "video/mp4"
            case .audio: return "audio/mpeg"
            case .text, .subtitle: return "application/octet-stream"
            case .lottie: return "application/json"
            case .sequence: return "video/mp4"
            }
        }
    }

    // MARK: - Job execution

    private func runJob(
        placeholders: [MediaAsset],
        genInput: GenerationInput,
        initialUpdate: GenerationJobUpdate,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        let runId = String(UUID().uuidString.prefix(8))
        Log.generation.notice("run \(runId) start model=\(genInput.model) placeholders=\(placeholders.count)")
        defer { Log.generation.notice("run \(runId) settled") }

        for placeholder in placeholders {
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                Self.apply(initialUpdate.reference, to: &input)
            }
        }
        editor.onProjectCheckpointRequired?()

        if await applyJobUpdate(
            initialUpdate,
            placeholders: placeholders,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        ) { return }

        await monitorBackendJob(
            reference: initialUpdate.reference,
            placeholders: placeholders,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    private func monitorBackendJob(
        reference: GenerationJobReference,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard reference.resumable else {
            let message = GenerationCoordinatorError.interruptedNonResumableRequest(reference.provider).localizedDescription
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
            }
            onFailure?()
            return
        }
        do {
            while !Task.isCancelled {
                let update = try await GenerationCoordinator.shared.refresh(reference)
                if await applyJobUpdate(
                    update,
                    placeholders: placeholders,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                ) { return }
                try await Task.sleep(for: .seconds(2))
            }
        } catch is CancellationError {
            return
        } catch {
            let message = error.localizedDescription
            Log.generation.error("job \(reference.jobID) monitoring failed: \(message)")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message)) { input in
                    Self.apply(reference, to: &input)
                }
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
        }
    }

    private func applyJobUpdate(
        _ update: GenerationJobUpdate,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async -> Bool {
        switch update.state {
        case .succeeded:
            updateJobMetadata(placeholders, reference: update.reference, editor: editor)
            editor.onProjectCheckpointRequired?()
            await finalizeSuccess(
                urls: update.resultURLs,
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
            return true
        case .failed:
            let message = update.error?.message ?? "Generation failed"
            Log.generation.error("job \(update.reference.jobID) failed: \(message)")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message)) { input in
                    Self.apply(update.reference, to: &input)
                }
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return true
        case .cancelled:
            let message = "Generation cancelled"
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message)) { input in
                    Self.apply(update.reference, to: &input)
                }
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return true
        case .queued, .running:
            if updateJobMetadata(placeholders, reference: update.reference, editor: editor) {
                editor.onProjectCheckpointRequired?()
            }
            return false
        }
    }

    @discardableResult
    private func updateJobMetadata(
        _ placeholders: [MediaAsset],
        reference: GenerationJobReference,
        editor: EditorViewModel
    ) -> Bool {
        var changed = false
        for placeholder in placeholders {
            guard placeholder.generationStatus != .downloading,
                    placeholder.generationStatus != .generating ||
                    placeholder.generationInput?.externalJobID != reference.jobID else {
                continue
            }
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                Self.apply(reference, to: &input)
            }
            changed = true
        }
        return changed
    }

    private func finalizeSuccess(
        urls: [URL],
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard !urls.isEmpty else {
            Log.generation.error("generation job succeeded with no results")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No URL in response"))
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return
        }
        if urls.count < placeholders.count {
            Log.generation.notice("provider returned \(urls.count) result(s) for \(placeholders.count) placeholder(s); marking extras as failed")
        }

        var finalized: [MediaAsset] = []
        for (i, placeholder) in placeholders.enumerated() {
            let outputIndex = placeholder.generationInput?.outputIndex ?? i
            guard outputIndex < urls.count else {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No URL for placeholder"))
                continue
            }
            let remote = urls[outputIndex]
            updateGenerationMetadata(placeholder, editor: editor, status: .downloading)
            if await downloadAndFinalize(asset: placeholder, remoteURL: remote, editor: editor) {
                onComplete?(placeholder)
                finalized.append(placeholder)
            }
        }
        editor.onProjectCheckpointRequired?()

        if let first = finalized.first {
            AppNotifications.generationComplete(
                assetId: first.id,
                projectURL: editor.projectURL,
                assetName: first.name,
                assetType: first.type,
                count: finalized.count
            )
        } else {
            onFailure?()
        }
    }

    private static func apply(_ reference: GenerationJobReference, to input: inout GenerationInput) {
        input.backendJobId = reference.jobID
        input.externalJobID = reference.jobID
        input.providerID = reference.provider
        input.credentialSource = reference.credentialSource
        input.catalogVersion = reference.catalogVersion
        input.endpointIDs = reference.endpointIDs
        input.providerRequests = reference.providerRequests
        input.requestSnapshot = reference.requestSnapshot
        input.isJobResumable = reference.resumable
        input.resultURLs = nil
    }

}
