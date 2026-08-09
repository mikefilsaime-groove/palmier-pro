import Combine
import Foundation

enum GenerationBackend {
    static func subscribeToProjectActivity(
        projectId: String
    ) -> AnyPublisher<[BackendProjectActivityEntry], GenerationBackendActivityError>? {
        nil
    }
}

enum BackendGenerationParams: Encodable, Sendable {
    case video(VideoGenerationParams)
    case image(ImageGenerationParams)
    case audio(AudioGenerationParams)
    case upscale(UpscaleGenerationParams)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .video(let params): try container.encode(params)
        case .image(let params): try container.encode(params)
        case .audio(let params): try container.encode(params)
        case .upscale(let params): try container.encode(params)
        }
    }
}

struct BackendProjectActivityEntry: Decodable, Sendable, Identifiable {
    enum Kind: String, Decodable, Sendable { case generation, failed, refund }
    let id: String
    let kind: Kind
    let model: String
    let credits: Int
    let createdAt: Double
    var creditImpact: Int { kind == .refund ? -credits : credits }
    var createdDate: Date { Date(timeIntervalSince1970: createdAt / 1_000) }
}

struct GenerationBackendActivityError: Error {}
