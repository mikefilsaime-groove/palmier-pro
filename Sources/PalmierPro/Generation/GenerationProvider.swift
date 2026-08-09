import Foundation

enum GenerationProviderID: String, Codable, Sendable, Hashable {
    case codexImage = "codex-image"
    case creatorStudioFal = "creatorstudio-fal"
    case localFal = "local-fal"
    case elevenLabs = "elevenlabs"
}

enum GenerationCredentialSource: String, Codable, Sendable, Hashable {
    case codexSubscription = "codex-subscription"
    case creatorStudio = "creatorstudio-key"
    case localFalKeychain = "local-fal-keychain"
    case elevenLabsKeychain = "elevenlabs-keychain"
}

struct GenerationProviderRequest: Codable, Sendable, Hashable {
    let endpointID: String
    let requestID: String
}

struct GenerationJobReference: Codable, Sendable, Hashable {
    let jobID: String
    let provider: GenerationProviderID
    let credentialSource: GenerationCredentialSource
    let modelID: String
    let catalogVersion: String?
    let endpointIDs: [String]
    let providerRequests: [GenerationProviderRequest]
    let requestSnapshot: String
    let resumable: Bool
}

struct GenerationUploadReference: Sendable, Equatable {
    let id: String
    let kind: String
    let localFileURL: URL?

    init(id: String, kind: String, localFileURL: URL? = nil) {
        self.id = id
        self.kind = kind
        self.localFileURL = localFileURL
    }
}

enum GenerationJobState: String, Codable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

struct GenerationJobError: Codable, Sendable, Equatable {
    let code: String
    let message: String
    let retryable: Bool
}

struct GenerationJobUpdate: Sendable {
    let reference: GenerationJobReference
    let state: GenerationJobState
    let resultURLs: [URL]
    let error: GenerationJobError?
}

enum GenerationCoordinatorError: LocalizedError, Sendable {
    case codexImageUnavailable(String)
    case creatorStudioUnavailable(String)
    case falKeyMissing
    case elevenLabsKeyMissing
    case unsupportedModel(String)
    case invalidProviderResponse
    case interruptedNonResumableRequest(GenerationProviderID)

    var errorDescription: String? {
        switch self {
        case .codexImageUnavailable(let message): message
        case .creatorStudioUnavailable(let message): message
        case .falKeyMissing: "Connect Fal.ai in CreatorStudio or add a local Fal.ai key in Settings."
        case .elevenLabsKeyMissing: "Add an ElevenLabs API key in Settings."
        case .unsupportedModel(let model): "The selected model is unavailable: \(model)."
        case .invalidProviderResponse: "The generation provider returned an invalid response."
        case .interruptedNonResumableRequest(let provider):
            switch provider {
            case .codexImage: "This Codex image request was interrupted and cannot be resumed. Generate it again."
            case .elevenLabs: "This ElevenLabs request was interrupted and cannot be resumed. Generate it again."
            case .creatorStudioFal, .localFal: "This generation was interrupted and cannot be resumed. Generate it again."
            }
        }
    }
}

enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

extension Encodable {
    func encodedJSONValue() throws -> JSONValue {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
