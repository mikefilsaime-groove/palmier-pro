import Foundation

enum ElevenLabsClient {
    struct Voice: Decodable, Sendable {
        let voiceId: String
        let name: String
    }

    struct Model: Decodable, Sendable {
        let modelId: String
        let name: String
        let canDoTextToSpeech: Bool?
    }

    static func validate(apiKey: String) async throws {
        _ = try await voices(apiKey: apiKey)
    }

    static func voices(apiKey: String) async throws -> [Voice] {
        let data = try await get(path: "v1/voices", apiKey: apiKey)
        return try decoder.decode(VoicesResponse.self, from: data).voices
    }

    static func models(apiKey: String) async throws -> [Model] {
        let data = try await get(path: "v1/models", apiKey: apiKey)
        return try decoder.decode([Model].self, from: data)
    }

    static func generate(
        modelID: String,
        params: AudioGenerationParams,
        references: [GenerationUploadReference],
        apiKey: String
    ) async throws -> URL {
        if modelID == "elevenlabs/video-to-music" {
            guard let videoURL = references.first(where: { $0.kind == ClipType.video.rawValue })?.localFileURL else {
                throw ClientError.videoRequired
            }
            return try await generateVideoMusic(videoURL: videoURL, description: params.prompt, apiKey: apiKey)
        }
        let request: URLRequest
        if modelID == "elevenlabs/sound-effects" {
            request = try post(
                path: "v1/sound-generation",
                apiKey: apiKey,
                body: SoundEffectRequest(
                    text: params.prompt,
                    durationSeconds: params.durationSeconds.map(Double.init),
                    promptInfluence: 0.3
                )
            )
        } else if modelID == "elevenlabs/music" {
            request = try post(
                path: "v1/music",
                apiKey: apiKey,
                body: MusicRequest(
                    prompt: params.prompt,
                    musicLengthMs: max(3_000, (params.durationSeconds ?? 30) * 1_000),
                    forceInstrumental: params.instrumental
                )
            )
        } else {
            guard let voice = params.voice, !voice.isEmpty else { throw ClientError.voiceRequired }
            request = try post(
                path: "v1/text-to-speech/\(voice)",
                apiKey: apiKey,
                body: SpeechRequest(
                    text: params.prompt,
                    modelId: modelID.replacingOccurrences(of: "elevenlabs/", with: ""),
                    languageCode: params.targetLanguage
                )
            )
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationCoordinatorError.invalidProviderResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.decode(data: data, status: http.statusCode) }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "audio/mpeg"
        return try await writeTemporaryAudio(data, fileExtension: contentType.contains("wav") ? "wav" : "mp3")
    }

    private static func generateVideoMusic(
        videoURL: URL,
        description: String,
        apiKey: String
    ) async throws -> URL {
        let multipart = try await makeVideoMusicMultipart(videoURL: videoURL, description: description)
        do {
            var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/music/video-to-music")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15 * 60
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: multipart.fileURL)
            await removeTemporaryFile(multipart.fileURL)
            guard let http = response as? HTTPURLResponse else {
                throw GenerationCoordinatorError.invalidProviderResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.decode(data: data, status: http.statusCode)
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "audio/mpeg"
            return try await writeTemporaryAudio(data, fileExtension: contentType.contains("wav") ? "wav" : "mp3")
        } catch {
            await removeTemporaryFile(multipart.fileURL)
            throw error
        }
    }

    @concurrent private static func makeVideoMusicMultipart(
        videoURL: URL,
        description: String
    ) async throws -> (fileURL: URL, boundary: String) {
        let values = try videoURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else {
            throw ClientError.invalidVideo
        }
        guard fileSize <= 200 * 1024 * 1024 else { throw ClientError.videoTooLarge }

        let boundary = "CreatorStudioEditor-\(UUID().uuidString)"
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "creatorstudio-elevenlabs-upload-\(UUID().uuidString)")
            .appendingPathExtension("multipart")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let input = try FileHandle(forReadingFrom: videoURL)
        do {
            let filename = videoURL.lastPathComponent
                .replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\n", with: "_")
            let contentType = videoURL.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
            try output.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"videos[]\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8
            ))
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            let trimmed = String(description.prefix(1_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try output.write(contentsOf: Data(
                    "\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"description\"\r\n\r\n\(trimmed)".utf8
                ))
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.close()
            try input.close()
            return (outputURL, boundary)
        } catch {
            try? output.close()
            try? input.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    @concurrent private static func removeTemporaryFile(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    private static func get(path: String, apiKey: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/\(path)")!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationCoordinatorError.invalidProviderResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.decode(data: data, status: http.statusCode) }
        return data
    }

    private static func post<T: Encodable>(path: String, apiKey: String, body: T) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/\(path)")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    @concurrent private static func writeTemporaryAudio(_ data: Data, fileExtension: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "creatorstudio-elevenlabs-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct VoicesResponse: Decodable { let voices: [Voice] }
    private struct SpeechRequest: Encodable {
        let text: String
        let modelId: String
        let languageCode: String?
    }
    private struct SoundEffectRequest: Encodable {
        let text: String
        let durationSeconds: Double?
        let promptInfluence: Double
    }
    private struct MusicRequest: Encodable {
        let prompt: String
        let musicLengthMs: Int
        let forceInstrumental: Bool
    }

    private enum ClientError: LocalizedError {
        case voiceRequired
        case videoRequired
        case invalidVideo
        case videoTooLarge

        var errorDescription: String? {
            switch self {
            case .voiceRequired: "Choose an ElevenLabs voice."
            case .videoRequired: "Choose a video or timeline span to score."
            case .invalidVideo: "The source video could not be read."
            case .videoTooLarge: "ElevenLabs video-to-music accepts source videos up to 200 MB."
            }
        }
    }
}
