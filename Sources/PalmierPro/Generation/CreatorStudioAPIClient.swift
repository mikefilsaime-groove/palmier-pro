import Foundation

struct CreatorStudioCatalogResponse: Decodable, Sendable {
    let catalogVersion: String
    let models: [CreatorStudioCatalogModel]
}

struct CreatorStudioCatalogModel: Decodable, Sendable {
    let id: String
    let label: String
    let mediaKind: String
    let operation: String
    let capabilities: JSONValue
    let catalogVersion: String
    let estimatedProviderCost: Double?
}

struct CreatorStudioSelectorSession: Decodable, Sendable {
    let id: String
    let protocolVersion: Int
    let url: URL
    let expiresAt: Date
}

enum CreatorStudioAPIClient {
    static func catalog(kind: String) async throws -> CreatorStudioCatalogResponse {
        let request = try await authorizedRequest(path: "api/godmode/v1/models/\(kind)")
        return try await response(request, as: CreatorStudioCatalogResponse.self)
    }

    static func upload(fileURL: URL, contentType: String, mediaKind: String) async throws -> GenerationUploadReference {
        let byteLength = try await fileByteLength(fileURL)
        let body: JSONValue = .object([
            "contentType": .string(contentType),
            "byteLength": .number(Double(byteLength)),
        ])
        var create = try await authorizedRequest(path: "api/godmode/v1/uploads", method: "POST")
        create.httpBody = try JSONEncoder().encode(body)
        let session = try await response(create, as: UploadSession.self)
        guard trustedStorageURL(session.uploadUrl) else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }

        var upload = URLRequest(url: session.uploadUrl)
        upload.httpMethod = "PUT"
        upload.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, uploadResponse) = try await URLSession.shared.upload(for: upload, fromFile: fileURL)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse,
              (200..<300).contains(uploadHTTP.statusCode) else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }

        let complete = try await authorizedRequest(
            path: "api/godmode/v1/uploads/\(session.id)/complete",
            method: "POST"
        )
        let completed = try await response(complete, as: UploadCompletion.self)
        guard completed.inputReference.mediaKind == mediaKind else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }
        return GenerationUploadReference(id: completed.inputReference.id, kind: completed.inputReference.mediaKind)
    }

    static func compile(_ requestBody: JSONValue) async throws -> FalCompiledRequest {
        var request = try await authorizedRequest(path: "api/godmode/v1/requests/compile", method: "POST")
        request.httpBody = try JSONEncoder().encode(requestBody)
        return try await response(request, as: FalCompiledRequest.self)
    }

    static func submit(_ requestBody: JSONValue, idempotencyKey: String) async throws -> CreatorStudioJob {
        var request = try await authorizedRequest(path: "api/godmode/v1/jobs", method: "POST")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(requestBody)
        return try validatedJob(await response(request, as: CreatorStudioJob.self))
    }

    static func job(id: String) async throws -> CreatorStudioJob {
        let request = try await authorizedRequest(path: "api/godmode/v1/jobs/\(id)")
        return try validatedJob(await response(request, as: CreatorStudioJob.self))
    }

    static func cancel(jobID: String) async throws -> CreatorStudioJob {
        let request = try await authorizedRequest(path: "api/godmode/v1/jobs/\(jobID)/cancel", method: "POST")
        return try validatedJob(await response(request, as: CreatorStudioJob.self))
    }

    static func createSelectorSession() async throws -> CreatorStudioSelectorSession {
        let request = try await authorizedRequest(path: "api/godmode/v1/selector-sessions", method: "POST")
        let session = try await response(request, as: CreatorStudioSelectorSession.self)
        guard let base = await CreatorStudioSession.shared.configuration?.creatorStudioAPI,
              session.url.scheme == "https", session.url.host == base.host,
              session.url.user == nil, session.url.password == nil,
              session.url.port == base.port else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }
        return session
    }

    private static func authorizedRequest(path: String, method: String = "GET") async throws -> URLRequest {
        guard let base = await CreatorStudioSession.shared.configuration?.creatorStudioAPI else {
            throw GenerationCoordinatorError.creatorStudioUnavailable("CreatorStudio is not configured.")
        }
        let token = try await CreatorStudioSession.shared.validAccessToken()
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.timeoutInterval = 60
        return request
    }

    private static func response<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationCoordinatorError.invalidProviderResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.decode(data: data, status: http.statusCode) }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw GenerationCoordinatorError.invalidProviderResponse }
    }

    @concurrent private static func fileByteLength(_ url: URL) async throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Int64(fileSize)
    }

    private static func validatedJob(_ job: CreatorStudioJob) throws -> CreatorStudioJob {
        guard job.outputs.allSatisfy({ trustedStorageURL($0.downloadUrl) }) else {
            throw GenerationCoordinatorError.invalidProviderResponse
        }
        return job
    }

    private static func trustedStorageURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "storage.googleapis.com" || host.hasSuffix(".storage.googleapis.com")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid ISO 8601 date."
                )
            }
            return date
        }
        return decoder
    }()

    private struct UploadSession: Decodable {
        let id: String
        let mediaKind: String
        let uploadUrl: URL
    }

    private struct UploadCompletion: Decodable {
        struct Reference: Decodable { let id: String; let mediaKind: String }
        let inputReference: Reference
    }
}

struct CreatorStudioJob: Decodable, Sendable {
    struct Output: Decodable, Sendable {
        let id: String
        let mediaKind: String
        let downloadUrl: URL
    }

    let id: String
    let kind: String
    let operation: String
    let modelId: String
    let catalogVersion: String
    let endpointIds: [String]
    let providerJobIds: [GenerationProviderRequest]
    let credentialSource: String
    let status: GenerationJobState
    let outputs: [Output]
    let error: GenerationJobError?
}
