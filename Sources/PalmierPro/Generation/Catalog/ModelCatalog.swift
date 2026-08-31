import Foundation

enum ModelKind: Sendable {
    case video(VideoModelConfig)
    case image(ImageModelConfig)
    case audio(AudioModelConfig)
    case upscale(UpscaleModelConfig)
}

enum ModelRegistry {
    @MainActor static var byId: [String: ModelKind] { ModelCatalog.shared.byId }

    @MainActor static func exists(id: String) -> Bool { byId[id] != nil }


    @MainActor static func displayName(for id: String) -> String {
        switch byId[id] {
        case .video(let m): m.displayName
        case .image(let m): m.displayName
        case .audio(let m): m.displayName
        case .upscale(let m): m.displayName
        case .none: id
        }
    }

    @MainActor static func providerIconKey(for id: String) -> String? {
        switch byId[id] {
        case .video(let m): m.entry.providerIconKey
        case .image(let m): m.entry.providerIconKey
        case .audio(let m): m.entry.providerIconKey
        case .upscale(let m): m.entry.providerIconKey
        case .none: nil
        }
    }
}

@Observable
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()

    private(set) var video: [VideoModelConfig] = []
    private(set) var image: [ImageModelConfig] = []
    private(set) var audio: [AudioModelConfig] = []
    private(set) var upscale: [UpscaleModelConfig] = []
    private(set) var byId: [String: ModelKind] = [:]
    private(set) var isLoaded: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored private var didConfigure = false
    @ObservationIgnored private var operations: [String: String] = [:]
    @ObservationIgnored private var catalogVersions: [String: String] = [:]

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        apply(Self.builtInAudioEntries(voices: [], ttsModels: []))
        Task { @MainActor [weak self] in await self?.reload() }
    }

    func reload() async {
        var entries = Self.builtInAudioEntries(voices: [], ttsModels: [])
        if let key = await GenerationCredentialStore.credential(.elevenLabs) {
            async let voices = ElevenLabsClient.voices(apiKey: key)
            async let models = ElevenLabsClient.models(apiKey: key)
            if let resolvedVoices = try? await voices, let resolvedModels = try? await models {
                entries = Self.builtInAudioEntries(voices: resolvedVoices, ttsModels: resolvedModels)
            }
        }
        let codexInstalled = await CodexAppServer.isInstalled()
        guard CreatorStudioSession.shared.isSignedIn else {
            apply(Self.addingCodexImage(to: entries, installed: codexInstalled))
            return
        }
        do {
            async let video = CreatorStudioAPIClient.catalog(kind: "video")
            async let image = CreatorStudioAPIClient.catalog(kind: "image")
            let remote = try await (video, image)
            entries.append(contentsOf: remote.0.models.compactMap(Self.videoEntry))
            entries.append(contentsOf: remote.1.models.compactMap(Self.imageEntry))
            apply(Self.addingCodexImage(to: entries, installed: codexInstalled))
        } catch {
            apply(Self.addingCodexImage(to: entries, installed: codexInstalled))
            lastError = error.localizedDescription
            Log.generation.warning("CreatorStudio model catalog unavailable: \(error.localizedDescription)")
        }
    }

    func operation(for modelID: String) -> String? { operations[modelID] }
    func catalogVersion(for modelID: String) -> String? { catalogVersions[modelID] }

    private func apply(_ entries: [CatalogEntry]) {
        var newVideo: [VideoModelConfig] = []
        var newImage: [ImageModelConfig] = []
        var newAudio: [AudioModelConfig] = []
        var newUpscale: [UpscaleModelConfig] = []
        var newById: [String: ModelKind] = [:]
        var newOperations: [String: String] = [:]
        var newCatalogVersions: [String: String] = [:]
        newVideo.reserveCapacity(entries.count)
        newImage.reserveCapacity(entries.count)
        newAudio.reserveCapacity(entries.count)
        newUpscale.reserveCapacity(entries.count)
        newById.reserveCapacity(entries.count)

        for entry in entries {
            newOperations[entry.id] = entry.operation
            newCatalogVersions[entry.id] = entry.catalogVersion
            switch entry.uiCapabilities {
            case .video(let caps):
                let m = VideoModelConfig(entry: entry, caps: caps)
                newVideo.append(m)
                newById[m.id] = .video(m)
            case .image(let caps):
                let m = ImageModelConfig(entry: entry, caps: caps)
                newImage.append(m)
                newById[m.id] = .image(m)
            case .audio(let caps):
                let m = AudioModelConfig(entry: entry, caps: caps)
                newAudio.append(m)
                newById[m.id] = .audio(m)
            case .upscale(let caps):
                let m = UpscaleModelConfig(entry: entry, caps: caps)
                newUpscale.append(m)
                newById[m.id] = .upscale(m)
            }
        }

        self.video = newVideo
        self.image = newImage
        self.audio = newAudio
        self.upscale = newUpscale
        self.byId = newById
        self.operations = newOperations
        self.catalogVersions = newCatalogVersions
        self.isLoaded = true
        self.lastError = nil
    }

    private static func videoEntry(_ model: CreatorStudioCatalogModel) -> CatalogEntry? {
        guard model.mediaKind == "video", let capabilities = model.capabilities.objectValue else { return nil }
        let durations = capabilities.intArray("durations")
        let resolutions = capabilities.stringArray("resolutions")
        let aspectRatios = capabilities.stringArray("aspectRatios")
        let maximumReferences = capabilities.int("maximumReferences") ?? 1
        let operation = model.operation
        let isReferences = operation == "reference_to_video"
        let isExtend = operation == "extend_video"
        let supportsFirst = operation == "image_to_video" || operation == "first_last_frame"
        let supportsLast = operation == "first_last_frame"
        let caps = VideoCaps(
            supportsPrompt: true,
            durations: durations,
            resolutions: resolutions.isEmpty ? nil : resolutions,
            aspectRatios: aspectRatios,
            supportsFirstFrame: supportsFirst,
            supportsLastFrame: supportsLast,
            maxReferenceImages: isReferences ? maximumReferences : 0,
            maxReferenceVideos: isReferences ? maximumReferences : 0,
            maxReferenceAudios: isReferences ? maximumReferences : 0,
            maxTotalReferences: isReferences ? maximumReferences : nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "reference",
            requiresSourceVideo: isExtend,
            maxSourceVideoSeconds: nil,
            maxSourceVideoResolution: nil,
            requiredSourceVideoEncoding: nil,
            requiresReferenceImage: false,
            requiresReferenceAudio: false,
            draftCreditsPerSecond: nil,
            draftEnhanceCreditsPerSecond: nil,
            sourceVideoCreditsPerSecond: nil,
            sourceVideoDraftCreditsPerSecond: nil
        )
        return CatalogEntry(
            id: model.id,
            kind: .video,
            displayName: model.label,
            providerIconKey: "fal",
            providerName: "Fal.ai",
            description: nil,
            allowedEndpoints: [],
            responseShape: .video,
            uiCapabilities: .video(caps),
            paidOnly: false,
            operation: operation,
            catalogVersion: model.catalogVersion,
            estimatedProviderCost: model.estimatedProviderCost
        )
    }

    private static func imageEntry(_ model: CreatorStudioCatalogModel) -> CatalogEntry? {
        guard model.mediaKind == "image", let capabilities = model.capabilities.objectValue else { return nil }
        let refs = capabilities["referenceImages"]?.objectValue
        let maximumReferences = refs?.int("maximum") ?? 0
        let caps = ImageCaps(
            resolutions: nil,
            aspectRatios: capabilities.stringArray("aspectRatios"),
            qualities: capabilities.stringArray("qualities").nilIfEmpty,
            supportsImageReference: maximumReferences > 0,
            maxImages: capabilities.intArray("outputCounts").max() ?? 1
        )
        return CatalogEntry(
            id: model.id,
            kind: .image,
            displayName: model.label,
            providerIconKey: "fal",
            providerName: "Fal.ai",
            description: nil,
            allowedEndpoints: [],
            responseShape: .images,
            uiCapabilities: .image(caps),
            paidOnly: false,
            operation: model.operation,
            catalogVersion: model.catalogVersion,
            estimatedProviderCost: model.estimatedProviderCost
        )
    }

    private static func addingCodexImage(to entries: [CatalogEntry], installed: Bool) -> [CatalogEntry] {
        guard installed else { return entries }
        if CodexImageGenerationPreferences.prefersCodex() {
            return [codexImageEntry] + entries
        }
        return entries + [codexImageEntry]
    }

    private static var codexImageEntry: CatalogEntry {
        CatalogEntry(
            id: CodexImageGeneration.modelID,
            kind: .image,
            displayName: "GPT Image 2",
            providerIconKey: "openai",
            providerName: "Codex",
            description: "Uses the signed-in Codex subscription allowance.",
            allowedEndpoints: [CodexImageGeneration.endpointID],
            responseShape: .images,
            uiCapabilities: .image(ImageCaps(
                resolutions: nil,
                aspectRatios: ["1:1", "16:9", "9:16", "4:3", "3:4"],
                qualities: ["low", "medium", "high"],
                supportsImageReference: true,
                maxImages: 1
            )),
            paidOnly: false,
            operation: "image-generation",
            catalogVersion: CodexImageGeneration.catalogVersion,
            estimatedProviderCost: nil
        )
    }

    private static func builtInAudioEntries(
        voices: [ElevenLabsClient.Voice],
        ttsModels: [ElevenLabsClient.Model]
    ) -> [CatalogEntry] {
        let voiceIDs = voices.map(\.voiceId)
        let defaultVoice = voiceIDs.first
        let availableTTS = ttsModels.filter { $0.canDoTextToSpeech != false }
        let resolvedTTS = availableTTS.isEmpty
            ? [ElevenLabsClient.Model(modelId: "eleven_multilingual_v2", name: "Eleven Multilingual v2", canDoTextToSpeech: true)]
            : availableTTS
        var entries = resolvedTTS.map { model in
            CatalogEntry(
                id: "elevenlabs/\(model.modelId)",
                kind: .audio,
                displayName: model.name,
                providerIconKey: nil,
                providerName: "ElevenLabs",
                description: nil,
                allowedEndpoints: [],
                responseShape: .audio,
                uiCapabilities: .audio(AudioCaps(
                    category: "tts", voices: voiceIDs, defaultVoice: defaultVoice,
                    supportsLyrics: false, supportsInstrumental: false,
                    supportsStyleInstructions: false, durations: nil, durationRange: nil,
                    minPromptLength: 1, maxReferenceImages: 0, maxReferenceAudios: 0,
                    maxReferenceAudioSeconds: nil, referenceAudioExtensions: nil,
                    referenceImagesAndAudiosExclusive: false, supportsMultilingual: true,
                    inputs: ["text"], promptLabel: "Text to speak", minSeconds: nil,
                    maxSeconds: nil, targetLanguages: nil, defaultTargetLanguage: nil
                )),
                paidOnly: false,
                operation: "text-to-speech",
                catalogVersion: "elevenlabs-live",
                estimatedProviderCost: nil
            )
        }
        entries.append(CatalogEntry.audio(
            id: "elevenlabs/sound-effects", name: "Sound Effects", category: "sfx",
            operation: "text-to-sound-effects", inputs: ["text"], duration: .init(minimum: 1, maximum: 22, defaultValue: 5)
        ))
        entries.append(CatalogEntry.audio(
            id: "elevenlabs/music", name: "Music", category: "music",
            operation: "text-to-music", inputs: ["text"], duration: .init(minimum: 3, maximum: 600, defaultValue: 30), instrumental: true
        ))
        entries.append(CatalogEntry.audio(
            id: "elevenlabs/video-to-music", name: "Music for Video", category: "music",
            operation: "video-to-music", inputs: ["video"], duration: .init(minimum: 3, maximum: 600, defaultValue: 30), instrumental: true
        ))
        return entries
    }
}

struct CatalogEntry: Decodable, Sendable {
    let id: String
    let kind: Kind
    let displayName: String
    let providerIconKey: String?
    let providerName: String?
    let description: String?
    let allowedEndpoints: [String]
    let responseShape: ResponseShape
    let uiCapabilities: UICapabilities
    let creditsPerSecond: [String: Double]?
    let audioDiscountRate: [String: Double]?
    let creditsPerImage: [String: Double]?
    let qualities: [String]?
    let audioPricing: AudioPricing?
    let creditsPerSecondUpscale: Double?
    let upscalePricing: UpscalePricing?
    let paidOnly: Bool
    let operation: String
    let catalogVersion: String
    let estimatedProviderCost: Double?

    enum Kind: String, Decodable, Sendable { case video, image, audio, upscale }
    enum ResponseShape: String, Decodable, Sendable {
        case video, images, audio, upscaledImage
    }

    enum UICapabilities: Sendable {
        case video(VideoCaps)
        case image(ImageCaps)
        case audio(AudioCaps)
        case upscale(UpscaleCaps)
    }

    enum AudioPricing: Decodable, Sendable {
        case perThousandChars(rate: Double)
        case perSecond(rate: Double, textRate: Double?)
        case flat(price: Double)

        private enum K: String, CodingKey { case mode, rate, textRate, price }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            switch try c.decode(String.self, forKey: .mode) {
            case "perThousandChars":
                self = .perThousandChars(rate: try c.decode(Double.self, forKey: .rate))
            case "perSecond":
                self = .perSecond(
                    rate: try c.decode(Double.self, forKey: .rate),
                    textRate: try c.decodeIfPresent(Double.self, forKey: .textRate)
                )
            case "flat":
                self = .flat(price: try c.decode(Double.self, forKey: .price))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .mode, in: c,
                    debugDescription: "Unknown audio pricing mode"
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, providerIconKey, providerName, description, allowedEndpoints, responseShape, uiCapabilities
        case creditsPerSecond, audioDiscountRate, creditsPerImage, qualities
        case audioPricing, creditsPerSecondUpscale, upscalePricing, paidOnly
        case operation, catalogVersion, estimatedProviderCost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.providerIconKey = try c.decodeIfPresent(String.self, forKey: .providerIconKey)
        self.providerName = try c.decodeIfPresent(String.self, forKey: .providerName)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.allowedEndpoints = try c.decode([String].self, forKey: .allowedEndpoints)
        self.responseShape = try c.decode(ResponseShape.self, forKey: .responseShape)
        self.creditsPerSecond = try c.decodeIfPresent([String: Double].self, forKey: .creditsPerSecond)
        self.audioDiscountRate = try c.decodeIfPresent([String: Double].self, forKey: .audioDiscountRate)
        self.creditsPerImage = try c.decodeIfPresent([String: Double].self, forKey: .creditsPerImage)
        self.qualities = try c.decodeIfPresent([String].self, forKey: .qualities)
        self.audioPricing = try c.decodeIfPresent(AudioPricing.self, forKey: .audioPricing)
        self.creditsPerSecondUpscale = try c.decodeIfPresent(Double.self, forKey: .creditsPerSecondUpscale)
        self.upscalePricing = try c.decodeIfPresent(UpscalePricing.self, forKey: .upscalePricing)
        self.paidOnly = try c.decodeIfPresent(Bool.self, forKey: .paidOnly) ?? false
        self.operation = try c.decodeIfPresent(String.self, forKey: .operation) ?? kind.rawValue
        self.catalogVersion = try c.decodeIfPresent(String.self, forKey: .catalogVersion) ?? "legacy"
        self.estimatedProviderCost = try c.decodeIfPresent(Double.self, forKey: .estimatedProviderCost)
        switch self.kind {
        case .video:
            self.uiCapabilities = .video(try c.decode(VideoCaps.self, forKey: .uiCapabilities))
        case .image:
            self.uiCapabilities = .image(try c.decode(ImageCaps.self, forKey: .uiCapabilities))
        case .audio:
            self.uiCapabilities = .audio(try c.decode(AudioCaps.self, forKey: .uiCapabilities))
        case .upscale:
            self.uiCapabilities = .upscale(try c.decode(UpscaleCaps.self, forKey: .uiCapabilities))
        }
    }

    init(
        id: String,
        kind: Kind,
        displayName: String,
        providerIconKey: String?,
        providerName: String?,
        description: String?,
        allowedEndpoints: [String],
        responseShape: ResponseShape,
        uiCapabilities: UICapabilities,
        paidOnly: Bool,
        operation: String,
        catalogVersion: String,
        estimatedProviderCost: Double?
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.providerIconKey = providerIconKey
        self.providerName = providerName
        self.description = description
        self.allowedEndpoints = allowedEndpoints
        self.responseShape = responseShape
        self.uiCapabilities = uiCapabilities
        self.creditsPerSecond = nil
        self.audioDiscountRate = nil
        self.creditsPerImage = nil
        self.qualities = nil
        self.audioPricing = nil
        self.creditsPerSecondUpscale = nil
        self.upscalePricing = nil
        self.paidOnly = paidOnly
        self.operation = operation
        self.catalogVersion = catalogVersion
        self.estimatedProviderCost = estimatedProviderCost
    }

    static func audio(
        id: String,
        name: String,
        category: String,
        operation: String,
        inputs: [String],
        duration: AudioDurationRange,
        instrumental: Bool = false
    ) -> CatalogEntry {
        CatalogEntry(
            id: id, kind: .audio, displayName: name, providerIconKey: nil,
            providerName: "ElevenLabs", description: nil, allowedEndpoints: [],
            responseShape: .audio,
            uiCapabilities: .audio(AudioCaps(
                category: category, voices: nil, defaultVoice: nil, supportsLyrics: false,
                supportsInstrumental: instrumental, supportsStyleInstructions: false,
                durations: nil, durationRange: duration, minPromptLength: 1,
                maxReferenceImages: 0, maxReferenceAudios: 0,
                maxReferenceAudioSeconds: nil, referenceAudioExtensions: nil,
                referenceImagesAndAudiosExclusive: false, supportsMultilingual: false,
                inputs: inputs, promptLabel: category == "music" ? "Describe the music" : "Describe the sound",
                minSeconds: duration.minimum, maxSeconds: duration.maximum,
                targetLanguages: nil, defaultTargetLanguage: nil
            )),
            paidOnly: false, operation: operation, catalogVersion: "elevenlabs-live",
            estimatedProviderCost: nil
        )
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func stringArray(_ key: String) -> [String] {
        guard case .array(let values)? = self[key] else { return [] }
        return values.compactMap(\.stringValue)
    }

    func intArray(_ key: String) -> [Int] {
        guard case .array(let values)? = self[key] else { return [] }
        return values.compactMap { value in
            guard case .number(let number) = value, number.isFinite else { return nil }
            return Int(exactly: number)
        }
    }

    func int(_ key: String) -> Int? {
        guard case .number(let number)? = self[key], number.isFinite else { return nil }
        return Int(exactly: number)
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

struct VideoCaps: Decodable, Sendable {
    let supportsPrompt: Bool?
    let durations: [Int]
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let maxReferenceImages: Int
    let maxReferenceVideos: Int
    let maxReferenceAudios: Int
    let maxTotalReferences: Int?
    let maxCombinedVideoRefSeconds: Double?
    let maxCombinedAudioRefSeconds: Double?
    let framesAndReferencesExclusive: Bool
    let referenceTagNoun: String
    let requiresSourceVideo: Bool
    let maxSourceVideoSeconds: Double?
    let maxSourceVideoResolution: SourceVideoResolution?
    let requiredSourceVideoEncoding: SourceVideoEncoding?
    let requiresReferenceImage: Bool
    let requiresReferenceAudio: Bool?
    let draftCreditsPerSecond: Double?
    let draftEnhanceCreditsPerSecond: Double?
    let sourceVideoCreditsPerSecond: [String: Double]?
    let sourceVideoDraftCreditsPerSecond: Double?
}

enum SourceVideoResolution: String, Decodable, Sendable {
    case p720 = "720p", p1080 = "1080p", p4k = "4k"
}

enum SourceVideoEncoding: String, Decodable, Sendable {
    case h264MP4 = "h264-mp4"
}

struct ImageCaps: Decodable, Sendable {
    let resolutions: [String]?
    let aspectRatios: [String]
    let qualities: [String]?
    let supportsImageReference: Bool
    let maxImages: Int
}

struct AudioCaps: Decodable, Sendable {
    let category: String
    let voices: [String]?
    let defaultVoice: String?
    let supportsLyrics: Bool
    let supportsInstrumental: Bool
    let supportsStyleInstructions: Bool
    let durations: [Int]?
    let durationRange: AudioDurationRange?
    let minPromptLength: Int
    let maxReferenceImages: Int?
    let maxReferenceAudios: Int?
    let maxReferenceAudioSeconds: Double?
    let referenceAudioExtensions: [String]?
    let referenceImagesAndAudiosExclusive: Bool?
    let supportsMultilingual: Bool?
    let inputs: [String]?
    let promptLabel: String?
    let minSeconds: Int?
    let maxSeconds: Int?
    let targetLanguages: [String]?
    let defaultTargetLanguage: String?
}

struct AudioDurationRange: Decodable, Sendable {
    let minimum: Int
    let maximum: Int
    let defaultValue: Int
}

struct UpscaleCaps: Decodable, Sendable {
    let speed: String   // "Fast" | "Medium" | "Slow"
    let p75DurationSeconds: Int
    let maximumUpscaleFactor: Double?
    let supportedTypes: [String]   // "video" | "image"
    let selectSettings: [UpscaleSelectSetting]?
    let numericSettings: [UpscaleNumericSetting]?
    let toggleSettings: [UpscaleToggleSetting]?
}
