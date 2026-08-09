import Foundation

struct FalCompiledRequest: Decodable, Sendable {
    struct Execution: Decodable, Sendable {
        let provider: String
        let modelId: String
        let endpointId: String
        let input: JSONValue
    }

    let mediaKind: String
    let operation: String
    let requestedModelId: String
    let catalogVersion: String
    let executions: [Execution]
}

enum FalQueueClient {
    static func validate(apiKey: String) async throws {
        guard apiKey.hasPrefix("key-") || apiKey.count >= 20 else {
            throw ValidationError.invalidKey
        }
        var components = URLComponents(string: "https://api.fal.ai/v1/models/pricing")
        components?.queryItems = [URLQueryItem(name: "endpoint_id", value: "fal-ai/flux/schnell")]
        guard let url = components?.url else { throw GenerationCoordinatorError.invalidProviderResponse }
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationCoordinatorError.invalidProviderResponse }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw ValidationError.rejected
        default:
            throw APIError.decode(data: data, status: http.statusCode)
        }
    }

    static func submit(execution: FalCompiledRequest.Execution, apiKey: String) async throws -> GenerationProviderRequest {
        let url = try endpointURL(execution.endpointId)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(execution.input)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationCoordinatorError.invalidProviderResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.decode(data: data, status: http.statusCode) }
        let payload = try JSONDecoder().decode(SubmitResponse.self, from: data)
        guard isValidRequestID(payload.requestId) else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }
        return GenerationProviderRequest(endpointID: execution.endpointId, requestID: payload.requestId)
    }

    static func status(_ requestReference: GenerationProviderRequest, apiKey: String) async throws -> GenerationJobState {
        var request = URLRequest(url: try requestURL(requestReference, suffix: "status"))
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationCoordinatorError.invalidProviderResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.decode(data: data, status: http.statusCode) }
        let payload = try JSONDecoder().decode(StatusResponse.self, from: data)
        if payload.error != nil || payload.errorType != nil { return .failed }
        return switch payload.status {
        case "IN_QUEUE": .queued
        case "IN_PROGRESS": .running
        case "COMPLETED": .succeeded
        case "CANCELLATION_REQUESTED", "CANCELLED": .cancelled
        default: .failed
        }
    }

    static func resultURLs(_ requestReference: GenerationProviderRequest, apiKey: String) async throws -> [URL] {
        var request = URLRequest(url: try requestURL(requestReference, suffix: nil))
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationCoordinatorError.invalidProviderResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.decode(data: data, status: http.statusCode) }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return collectURLs(value)
    }

    static func cancel(_ requestReference: GenerationProviderRequest, apiKey: String) async throws {
        var request = URLRequest(url: try requestURL(requestReference, suffix: "cancel"))
        request.httpMethod = "PUT"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationCoordinatorError.invalidProviderResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.decode(data: data, status: http.statusCode) }
    }

    private static func endpointURL(_ endpointID: String) throws -> URL {
        let components = endpointID.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              endpointID.allSatisfy({ $0.isLetter || $0.isNumber || "-_/.".contains($0) }),
              let url = URL(string: "https://queue.fal.run/\(endpointID)") else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }
        return url
    }

    private static func requestURL(_ reference: GenerationProviderRequest, suffix: String?) throws -> URL {
        guard isValidRequestID(reference.requestID) else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }
        let base = try endpointURL(reference.endpointID).appending(path: "requests").appending(path: reference.requestID)
        return suffix.map { base.appending(path: $0) } ?? base
    }

    static func isValidRequestID(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 200
            && value.allSatisfy { $0.isLetter || $0.isNumber || "-_".contains($0) }
    }

    private static func collectURLs(_ value: JSONValue) -> [URL] {
        switch value {
        case .object(let object):
            let direct = object["url"]?.stringValue.flatMap(validResultURL).map { [$0] } ?? []
            return direct + object.values.flatMap(collectURLs)
        case .array(let values): return values.flatMap(collectURLs)
        case .string, .number, .bool, .null: return []
        }
    }

    private static func validResultURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), host == "fal.media" || host.hasSuffix(".fal.media") else {
            return nil
        }
        return url
    }

    private struct SubmitResponse: Decodable {
        let requestId: String
        private enum CodingKeys: String, CodingKey { case requestId = "request_id" }
    }
    private struct StatusResponse: Decodable {
        let status: String
        let error: String?
        let errorType: String?

        private enum CodingKeys: String, CodingKey {
            case status, error
            case errorType = "error_type"
        }
    }

    private enum ValidationError: LocalizedError {
        case invalidKey
        case rejected
        var errorDescription: String? {
            switch self {
            case .invalidKey: "Enter a valid Fal.ai API key."
            case .rejected: "Fal.ai rejected this API key."
            }
        }
    }
}
