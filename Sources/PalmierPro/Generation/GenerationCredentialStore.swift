import Foundation

enum GenerationCredentialKind: String, Sendable {
    case fal
    case elevenLabs

    var account: String {
        switch self {
        case .fal: "creatorstudio.local.fal-api-key"
        case .elevenLabs: "creatorstudio.local.elevenlabs-api-key"
        }
    }
}

@Observable
@MainActor
final class GenerationCredentialStore {
    static let shared = GenerationCredentialStore()

    private(set) var hasFalKey = false
    private(set) var hasElevenLabsKey = false
    private(set) var isValidating = false
    private(set) var lastError: String?

    private init() {}

    func configure() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            async let fal = Self.credential(.fal)
            async let eleven = Self.credential(.elevenLabs)
            hasFalKey = await fal != nil
            hasElevenLabsKey = await eleven != nil
        }
    }

    func save(_ rawValue: String, kind: GenerationCredentialKind) async -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            lastError = "Enter an API key."
            return false
        }
        isValidating = true
        lastError = nil
        defer { isValidating = false }
        do {
            switch kind {
            case .fal: try await FalQueueClient.validate(apiKey: value)
            case .elevenLabs: try await ElevenLabsClient.validate(apiKey: value)
            }
            try await SecureKeychain.saveString(value, account: kind.account)
            setPresence(true, for: kind)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func delete(_ kind: GenerationCredentialKind) async {
        await SecureKeychain.delete(accounts: [kind.account])
        setPresence(false, for: kind)
        lastError = nil
    }

    static func credential(_ kind: GenerationCredentialKind) async -> String? {
        await SecureKeychain.loadString(account: kind.account)
    }

    private func setPresence(_ present: Bool, for kind: GenerationCredentialKind) {
        switch kind {
        case .fal: hasFalKey = present
        case .elevenLabs: hasElevenLabsKey = present
        }
    }
}
