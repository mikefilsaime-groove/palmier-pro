import AppKit
import Foundation

enum CreatorStudioFalConnection: Sendable, Equatable {
    case unknown
    case configured(maskedKey: String?)
    case missing
    case unavailable(String)
}

@Observable
@MainActor
final class CreatorStudioSession {
    static let shared = CreatorStudioSession()

    private(set) var falConnection: CreatorStudioFalConnection = .unknown
    private(set) var displayName: String?
    private(set) var isSigningIn = false
    private(set) var isRestoringConnection = true
    private(set) var pairingCode: String?
    private(set) var pairingExpiresAt: Date?
    private(set) var lastError: String?
    private(set) var configuration: CreatorStudioConfiguration?
    private(set) var isSignedIn = false
    var isConfigured: Bool { configuration != nil }
    var pairingInstructions: String? {
        guard let pairingCode else { return nil }
        return Self.pairingInstruction(for: pairingCode)
    }

    @ObservationIgnored private var appToken: String?
    @ObservationIgnored private var pairingAttemptID: UUID?
    @ObservationIgnored private var configureTask: Task<Void, Never>?

    private let tokenAccount = "creatorstudio.godmode.mcp-token"

    private init() {}

    func configure() {
        guard configureTask == nil else { return }
        do {
            configuration = try CreatorStudioConfiguration.load()
        } catch {
            isRestoringConnection = false
            lastError = error.localizedDescription
            return
        }
        configureTask = Task { @MainActor [weak self] in
            await self?.restoreConnection()
        }
    }

    func signIn() async {
        guard let configuration, !isSigningIn, !isSignedIn else { return }
        let attemptID = UUID()
        pairingAttemptID = attemptID
        isSigningIn = true
        lastError = nil
        defer {
            if pairingAttemptID == attemptID {
                pairingAttemptID = nil
                pairingCode = nil
                pairingExpiresAt = nil
                isSigningIn = false
            }
        }

        do {
            let pairing = try await createPairing(using: configuration)
            guard pairingAttemptID == attemptID else { return }
            guard let expiry = Self.parseServerDate(pairing.expiresAt) else {
                throw SessionError.invalidPairingResponse
            }
            pairingCode = pairing.userCode
            pairingExpiresAt = expiry

            while Date() < expiry {
                try Task.checkCancellation()
                guard pairingAttemptID == attemptID else { return }
                let exchange: PairingExchangeResponse
                do {
                    exchange = try await exchangePairing(pairing, using: configuration)
                } catch SessionError.pairingRateLimited(let retryAfter) {
                    let remaining = expiry.timeIntervalSinceNow
                    guard remaining > 0 else { break }
                    try await Task.sleep(for: .seconds(min(retryAfter, remaining)))
                    continue
                }
                guard pairingAttemptID == attemptID else { return }
                if exchange.status == "approved" {
                    guard let token = exchange.accessToken, token.hasPrefix("cliauth-") else {
                        throw SessionError.invalidPairingResponse
                    }
                    try await SecureKeychain.save(
                        AppTokenRecord(accessToken: token),
                        account: tokenAccount
                    )
                    appToken = token
                    isSignedIn = true
                    displayName = "CreatorStudio connected"
                    pairingCode = nil
                    pairingExpiresAt = nil
                    await refreshCreatorStudioConnection()
                    await ModelCatalog.shared.reload()
                    return
                }
                guard exchange.status == "pending" else {
                    throw SessionError.invalidPairingResponse
                }
                try await Task.sleep(for: .seconds(2))
            }
            throw SessionError.pairingExpired
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelSignIn() {
        pairingAttemptID = nil
        pairingCode = nil
        pairingExpiresAt = nil
        isSigningIn = false
    }

    func copyPairingInstructions() {
        guard let pairingInstructions else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingInstructions, forType: .string)
    }

    func signOut() async {
        cancelSignIn()
        var revocationError: Error?
        if let configuration, let appToken {
            do {
                var request = URLRequest(url: configuration.clickCampaignsAPI.appending(path: "api/godmode/v1/logout"))
                request.httpMethod = "POST"
                request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SessionError.invalidResponse }
                guard http.statusCode == 204 else { throw APIError.decode(data: data, status: http.statusCode) }
            } catch {
                revocationError = error
            }
        }
        await clearConnection()
        displayName = nil
        falConnection = .unknown
        lastError = revocationError?.localizedDescription
        await ModelCatalog.shared.reload()
    }

    func validAccessToken() async throws -> String {
        guard let appToken else { throw SessionError.signedOut }
        return appToken
    }

    func refreshCreatorStudioConnection() async {
        guard isSignedIn, let configuration else {
            falConnection = .unknown
            return
        }
        do {
            let token = try await validAccessToken()
            var request = URLRequest(url: configuration.creatorStudioAPI.appending(path: "api/godmode/v1/connection"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SessionError.invalidResponse }
            guard http.statusCode == 200 else { throw APIError.decode(data: data, status: http.statusCode) }
            let payload = try Self.decoder.decode(ConnectionResponse.self, from: data)
            falConnection = payload.connected
                ? .configured(maskedKey: payload.maskedKey)
                : .missing
            lastError = nil
        } catch {
            falConnection = .unavailable(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    static func pairingInstruction(for code: String) -> String {
        "Use the ScalePlus ProMax SuperPowers Plugin or ClickCampaigns GodMode MCP to authorize CreatorStudio Editor code \(code)."
    }

    static func pairingRetryDelay(retryAfterHeader: String?) -> TimeInterval {
        guard let retryAfterHeader,
              let seconds = TimeInterval(retryAfterHeader.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite else {
            return 5
        }
        return min(max(seconds, 1), 60)
    }

    private func restoreConnection() async {
        defer { isRestoringConnection = false }
        do {
            guard let record = try await SecureKeychain.load(AppTokenRecord.self, account: tokenAccount) else {
                return
            }
            appToken = record.accessToken
            isSignedIn = true
            displayName = "CreatorStudio connected"
            lastError = nil
            await refreshCreatorStudioConnection()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func createPairing(using configuration: CreatorStudioConfiguration) async throws -> PairingSessionResponse {
        var request = URLRequest(
            url: configuration.clickCampaignsAPI.appending(path: "api/godmode/v1/pairing-sessions")
        )
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SessionError.invalidResponse }
        guard http.statusCode == 201 else { throw APIError.decode(data: data, status: http.statusCode) }
        return try Self.decoder.decode(PairingSessionResponse.self, from: data)
    }

    private func exchangePairing(
        _ pairing: PairingSessionResponse,
        using configuration: CreatorStudioConfiguration
    ) async throws -> PairingExchangeResponse {
        var request = URLRequest(
            url: configuration.clickCampaignsAPI.appending(
                path: "api/godmode/v1/pairing-sessions/\(pairing.id)/exchange"
            )
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairingExchangeRequest(pollSecret: pairing.pollSecret))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SessionError.invalidResponse }
        if http.statusCode == 429 {
            throw SessionError.pairingRateLimited(
                retryAfter: Self.pairingRetryDelay(
                    retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
        guard http.statusCode == 200 || http.statusCode == 202 else {
            throw APIError.decode(data: data, status: http.statusCode)
        }
        return try Self.decoder.decode(PairingExchangeResponse.self, from: data)
    }

    private func clearConnection() async {
        appToken = nil
        isSignedIn = false
        await SecureKeychain.delete(accounts: [tokenAccount])
    }

    private static func parseServerDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

private struct AppTokenRecord: Codable, Sendable {
    let accessToken: String
}

private struct PairingSessionResponse: Decodable, Sendable {
    let id: String
    let userCode: String
    let pollSecret: String
    let expiresAt: String
}

private struct PairingExchangeRequest: Encodable, Sendable {
    let pollSecret: String
}

private struct PairingExchangeResponse: Decodable, Sendable {
    let status: String
    let accessToken: String?
}

private struct ConnectionResponse: Decodable, Sendable {
    let connected: Bool
    let maskedKey: String?
}

enum APIError: LocalizedError, Sendable {
    case response(code: String, message: String, retryable: Bool, status: Int)

    var errorDescription: String? {
        switch self {
        case .response(_, let message, _, _): message
        }
    }

    static func decode(data: Data, status: Int) -> APIError {
        struct Payload: Decodable { let code: String?; let message: String?; let retryable: Bool? }
        let payload = try? JSONDecoder().decode(Payload.self, from: data)
        return .response(
            code: payload?.code ?? "http_\(status)",
            message: payload?.message ?? "The server returned HTTP \(status).",
            retryable: payload?.retryable ?? (status >= 500),
            status: status
        )
    }
}

private enum SessionError: LocalizedError {
    case signedOut
    case invalidResponse
    case invalidPairingResponse
    case pairingExpired
    case pairingRateLimited(retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .signedOut: "Connect CreatorStudio account sync in Settings."
        case .invalidResponse: "The connection server returned an invalid response."
        case .invalidPairingResponse: "The CreatorStudio pairing response could not be verified."
        case .pairingExpired: "The CreatorStudio pairing code expired. Start again."
        case .pairingRateLimited: "ClickCampaigns asked CreatorStudio Editor to wait before checking again."
        }
    }
}

enum SecureKeychain {
    @concurrent static func save<T: Encodable & Sendable>(_ value: T, account: String) async throws {
        let data = try JSONEncoder().encode(value)
        try saveDataSync(data, account: account)
    }

    @concurrent static func load<T: Decodable & Sendable>(_ type: T.Type, account: String) async throws -> T? {
        guard let data = loadDataSync(account: account) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    @concurrent static func saveString(_ value: String, account: String) async throws {
        try saveDataSync(Data(value.utf8), account: account)
    }

    @concurrent static func loadString(account: String) async -> String? {
        guard let data = loadDataSync(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @concurrent static func delete(accounts: [String]) async {
        for account in accounts { KeychainStore.delete(account: account) }
    }

    private static func saveDataSync(_ data: Data, account: String) throws {
        let encoded = data.base64EncodedString()
        KeychainStore.save(encoded, account: account)
        guard KeychainStore.load(account: account) == encoded else { throw KeychainError.writeFailed }
    }

    private static func loadDataSync(account: String) -> Data? {
        guard let encoded = KeychainStore.load(account: account) else { return nil }
        return Data(base64Encoded: encoded)
    }

    private enum KeychainError: LocalizedError {
        case writeFailed
        var errorDescription: String? { "The credential could not be stored in Keychain." }
    }
}
