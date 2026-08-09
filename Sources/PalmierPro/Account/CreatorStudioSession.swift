import AppKit
import CryptoKit
import Foundation

enum GodModeAccess: Sendable, Equatable {
    case checking
    case active(expiresAt: Date)
    case offlineLease(expiresAt: Date)
    case inactive
    case signedOut
    case unavailable(String)

    var permitsProtectedFeatures: Bool {
        switch self {
        case .active(let expiresAt), .offlineLease(let expiresAt): expiresAt > Date()
        case .checking, .inactive, .signedOut, .unavailable: false
        }
    }
}

enum CreatorStudioFalConnection: Sendable, Equatable {
    case unknown
    case configured(maskedKey: String?)
    case missing
    case unavailable(String)
}

enum ProtectedFeature: String, Sendable {
    case newProject
    case generation
    case agent
    case mutatingTool
}

enum LocalGodModeBypass {
    static let environmentKey = "CREATORSTUDIO_EDITOR_LOCAL_GODMODE"

    static func isRequested(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }
}

struct GodModeRequiredError: LocalizedError, Sendable {
    let feature: ProtectedFeature
    let reason: String

    var errorDescription: String? { reason }
}

@Observable
@MainActor
final class CreatorStudioSession {
    static let shared = CreatorStudioSession()

    private(set) var access: GodModeAccess = .checking
    private(set) var falConnection: CreatorStudioFalConnection = .unknown
    private(set) var email: String?
    private(set) var displayName: String?
    private(set) var isSigningIn = false
    private(set) var pairingCode: String?
    private(set) var pairingExpiresAt: Date?
    private(set) var lastError: String?
    private(set) var configuration: CreatorStudioConfiguration?

    var isSignedIn: Bool {
        #if DEBUG
        if usesLocalGodModeBypass { return true }
        #endif
        return appToken != nil
    }
    var isConfigured: Bool { configuration != nil }
    var canUseProtectedFeatures: Bool { access.permitsProtectedFeatures }
    var pairingInstructions: String? {
        guard let pairingCode else { return nil }
        return "In Codex or Claude, ask ClickCampaigns GodMode to authorize CreatorStudio Editor code \(pairingCode)."
    }

    @ObservationIgnored private var appToken: String?
    @ObservationIgnored private var subject: String?
    @ObservationIgnored private var signedLease: String?
    @ObservationIgnored private var leasePublicKey: Data?
    @ObservationIgnored private var pairingAttemptID: UUID?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var configureTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var usesLocalGodModeBypass = false
    #endif

    private let tokenAccount = "creatorstudio.godmode.mcp-token"
    private let leaseAccount = "creatorstudio.godmode.lease"
    private let leaseKeyAccount = "creatorstudio.godmode.lease-key"

    private init() {}

    func configure() {
        guard configureTask == nil else { return }
        do {
            configuration = try CreatorStudioConfiguration.load()
        } catch {
            access = .unavailable(error.localizedDescription)
            lastError = error.localizedDescription
            return
        }

        #if DEBUG
        if LocalGodModeBypass.isRequested() {
            usesLocalGodModeBypass = true
            displayName = "Local GodMode Test"
            access = .active(expiresAt: .distantFuture)
            falConnection = .missing
            lastError = nil
            configureTask = Task {}
            return
        }
        #endif

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshEntitlement() }
        }
        configureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await restore()
        }
    }

    func signIn() async {
        #if DEBUG
        if usesLocalGodModeBypass { return }
        #endif
        guard let configuration, !isSigningIn else { return }
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
                let exchange = try await exchangePairing(pairing, using: configuration)
                guard pairingAttemptID == attemptID else { return }
                if exchange.status == "approved" {
                    guard let token = exchange.accessToken, token.hasPrefix("cliauth-") else {
                        throw SessionError.invalidPairingResponse
                    }
                    appToken = token
                    try await SecureKeychain.save(
                        AppTokenRecord(accessToken: token, subject: nil),
                        account: tokenAccount
                    )
                    pairingCode = nil
                    pairingExpiresAt = nil
                    await refreshEntitlement()
                    if access.permitsProtectedFeatures {
                        await refreshCreatorStudioConnection()
                        await ModelCatalog.shared.reload()
                    }
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
            access = .signedOut
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
        #if DEBUG
        if usesLocalGodModeBypass { return }
        #endif
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
        await clearAllCredentials()
        email = nil
        displayName = nil
        access = .signedOut
        falConnection = .unknown
        lastError = revocationError?.localizedDescription
    }

    func validAccessToken() async throws -> String {
        guard let appToken else { throw SessionError.signedOut }
        return appToken
    }

    func require(_ feature: ProtectedFeature, refreshBeforeLocalGeneration: Bool = false) async throws {
        #if DEBUG
        if usesLocalGodModeBypass { return }
        #endif
        if refreshBeforeLocalGeneration { await refreshEntitlement() }
        guard access.permitsProtectedFeatures else {
            throw GodModeRequiredError(
                feature: feature,
                reason: "Active ClickCampaigns GodMode is required to use this feature."
            )
        }
    }

    func refreshEntitlement() async {
        #if DEBUG
        if usesLocalGodModeBypass {
            access = .active(expiresAt: .distantFuture)
            return
        }
        #endif
        guard let appToken, let configuration else {
            access = .signedOut
            return
        }
        do {
            var request = URLRequest(url: configuration.clickCampaignsAPI.appending(path: "api/godmode/v1/entitlement"))
            request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SessionError.invalidResponse }
            guard http.statusCode == 200 else { throw APIError.decode(data: data, status: http.statusCode) }
            let payload = try Self.decoder.decode(EntitlementResponse.self, from: data)
            subject = payload.subject
            if payload.active, let lease = payload.lease {
                let key = try await fetchLeaseKey(for: lease)
                let claims = try Self.verifyLease(
                    lease,
                    publicKey: key,
                    audience: configuration.leaseAudience,
                    subject: payload.subject
                )
                signedLease = lease
                leasePublicKey = key
                displayName = "ClickCampaigns GodMode"
                access = .active(expiresAt: claims.expiry)
                try await SecureKeychain.save(
                    AppTokenRecord(accessToken: appToken, subject: payload.subject),
                    account: tokenAccount
                )
                try await SecureKeychain.saveString(lease, account: leaseAccount)
                try await SecureKeychain.saveData(key, account: leaseKeyAccount)
                lastError = nil
            } else {
                await clearLeaseMaterial()
                access = .inactive
                falConnection = .unknown
            }
        } catch {
            if let apiError = error as? APIError,
               case .response(_, _, _, let status) = apiError {
                if status == 401 {
                    await clearAllCredentials()
                    access = .signedOut
                    falConnection = .unknown
                    lastError = error.localizedDescription
                    return
                }
                if status == 403 {
                    await clearLeaseMaterial()
                    access = .inactive
                    falConnection = .unknown
                    lastError = error.localizedDescription
                    return
                }
            }
            if !Self.canUseOfflineLease(after: error) {
                await clearLeaseMaterial()
                access = .unavailable("GodMode could not be verified. Reconnect ClickCampaigns GodMode and retry.")
                falConnection = .unknown
                lastError = error.localizedDescription
                return
            }
            if let lease = signedLease, let key = leasePublicKey,
               let claims = try? Self.verifyLease(
                   lease,
                   publicKey: key,
                   audience: configuration.leaseAudience,
                   subject: subject
               ),
               claims.expiry > Date() {
                access = .offlineLease(expiresAt: claims.expiry)
            } else {
                access = .unavailable("GodMode could not be verified. Connect to the internet and try again.")
            }
            lastError = error.localizedDescription
        }
    }

    func refreshCreatorStudioConnection() async {
        #if DEBUG
        if usesLocalGodModeBypass {
            falConnection = .missing
            return
        }
        #endif
        guard access.permitsProtectedFeatures, let configuration else {
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
        } catch {
            falConnection = .unavailable(error.localizedDescription)
        }
    }

    private func restore() async {
        if let record: AppTokenRecord = try? await SecureKeychain.load(AppTokenRecord.self, account: tokenAccount) {
            appToken = record.accessToken
            subject = record.subject
            displayName = "ClickCampaigns GodMode"
        }
        signedLease = await SecureKeychain.loadString(account: leaseAccount)
        leasePublicKey = await SecureKeychain.loadData(account: leaseKeyAccount)

        guard appToken != nil else {
            access = .signedOut
            return
        }
        await refreshEntitlement()
        if access.permitsProtectedFeatures {
            await refreshCreatorStudioConnection()
            await ModelCatalog.shared.reload()
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
        guard http.statusCode == 200 || http.statusCode == 202 else {
            throw APIError.decode(data: data, status: http.statusCode)
        }
        return try Self.decoder.decode(PairingExchangeResponse.self, from: data)
    }

    private func fetchLeaseKey(for lease: String) async throws -> Data {
        guard let configuration else { throw SessionError.notConfigured }
        guard let header = Self.jwtHeader(lease),
              header["alg"] as? String == "EdDSA",
              let keyID = header["kid"] as? String, !keyID.isEmpty else {
            throw SessionError.invalidLeaseKey
        }
        let request = URLRequest(url: configuration.clickCampaignsAPI.appending(path: "api/godmode/v1/lease-keys"))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.decode(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let payload = try Self.decoder.decode(LeaseKeysResponse.self, from: data)
        guard let key = payload.keys.first(where: { $0.kid == keyID }),
              key.kty == "OKP", key.crv == "Ed25519", key.alg == "EdDSA",
              let raw = Self.base64URLData(key.x), raw.count == 32 else {
            throw SessionError.invalidLeaseKey
        }
        return raw
    }

    private func clearLeaseMaterial() async {
        signedLease = nil
        leasePublicKey = nil
        await SecureKeychain.delete(accounts: [leaseAccount, leaseKeyAccount])
    }

    private func clearAllCredentials() async {
        appToken = nil
        subject = nil
        signedLease = nil
        leasePublicKey = nil
        await SecureKeychain.delete(accounts: [tokenAccount, leaseAccount, leaseKeyAccount])
    }

    static func verifyLease(
        _ jwt: String,
        publicKey: Data,
        audience: String,
        subject expectedSubject: String?
    ) throws -> LeaseClaims {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = base64URLData(String(parts[0])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "EdDSA",
              (header["kid"] as? String)?.isEmpty == false,
              let payloadData = base64URLData(String(parts[1])),
              let signature = base64URLData(String(parts[2])) else {
            throw SessionError.invalidLease
        }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signature, for: signed) else { throw SessionError.invalidLease }
        let claims = try decoder.decode(LeaseClaims.self, from: payloadData)
        let now = Date()
        guard claims.audience.contains(audience),
              claims.subject == expectedSubject,
              claims.godmode,
              claims.issuedAt <= now.addingTimeInterval(30),
              claims.expiry > now,
              claims.expiry.timeIntervalSince(claims.issuedAt) <= 7 * 24 * 60 * 60 + 30 else {
            throw SessionError.invalidLease
        }
        return claims
    }

    private static func canUseOfflineLease(after error: Error) -> Bool {
        if error is URLError { return true }
        guard let apiError = error as? APIError,
              case .response(_, _, let retryable, let status) = apiError else { return false }
        return retryable && status >= 500
    }

    private static func jwtHeader(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let data = base64URLData(String(parts[0])) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func base64URLData(_ value: String) -> Data? {
        var padded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
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
    let subject: String?
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

private struct EntitlementResponse: Decodable, Sendable {
    let active: Bool
    let lease: String?
    let subject: String

    private enum CodingKeys: String, CodingKey {
        case active, lease
        case subject = "sub"
    }
}

private struct ConnectionResponse: Decodable, Sendable {
    let connected: Bool
    let maskedKey: String?
}

private struct LeaseKeysResponse: Decodable, Sendable {
    struct Key: Decodable, Sendable {
        let kid: String
        let kty: String
        let crv: String
        let alg: String
        let x: String
    }
    let keys: [Key]
}

struct LeaseClaims: Decodable, Sendable {
    let subject: String
    let audience: [String]
    let issuedAt: Date
    let expiry: Date
    let godmode: Bool

    private enum CodingKeys: String, CodingKey { case sub, aud, iat, exp, godmode }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let values = try? container.decode([String].self, forKey: .aud) {
            audience = values
        } else {
            audience = [try container.decode(String.self, forKey: .aud)]
        }
        subject = try container.decode(String.self, forKey: .sub)
        issuedAt = Date(timeIntervalSince1970: try container.decode(TimeInterval.self, forKey: .iat))
        expiry = Date(timeIntervalSince1970: try container.decode(TimeInterval.self, forKey: .exp))
        godmode = try container.decode(Bool.self, forKey: .godmode)
    }
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
    case notConfigured
    case signedOut
    case invalidResponse
    case invalidPairingResponse
    case pairingExpired
    case invalidLeaseKey
    case invalidLease

    var errorDescription: String? {
        switch self {
        case .notConfigured: "CreatorStudio Editor authentication is not configured."
        case .signedOut: "Connect ClickCampaigns GodMode MCP to CreatorStudio Editor."
        case .invalidResponse: "The authentication server returned an invalid response."
        case .invalidPairingResponse: "The ClickCampaigns MCP pairing response could not be verified."
        case .pairingExpired: "The ClickCampaigns MCP pairing code expired. Start again."
        case .invalidLeaseKey, .invalidLease: "The GodMode offline lease could not be verified."
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

    @concurrent static func saveData(_ data: Data, account: String) async throws {
        try saveDataSync(data, account: account)
    }

    @concurrent static func loadData(account: String) async -> Data? {
        loadDataSync(account: account)
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
