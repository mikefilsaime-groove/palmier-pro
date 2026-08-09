import Foundation

struct CreatorStudioConfiguration: Sendable {
    let creatorStudioAPI: URL
    let clickCampaignsAPI: URL
    let leaseAudience = "creatorstudio-editor"

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws -> CreatorStudioConfiguration {
        func value(_ environmentKey: String, _ plistKey: String, default fallback: String) -> String? {
            let raw = environment[environmentKey]
                ?? bundle.object(forInfoDictionaryKey: plistKey) as? String
                ?? fallback
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let creatorValue = value(
            "CREATORSTUDIO_API_BASE_URL",
            "CreatorStudioAPIBaseURL",
            default: "https://creatorstudio.gg"
        ), let creatorStudioAPI = secureServiceURL(creatorValue) else {
            throw ConfigurationError.missing("CreatorStudioAPIBaseURL")
        }
        guard let clickValue = value(
            "CLICKCAMPAIGNS_API_BASE_URL",
            "ClickCampaignsAPIBaseURL",
            default: "https://clickcampaigns.ai"
        ), let clickCampaignsAPI = secureServiceURL(clickValue) else {
            throw ConfigurationError.missing("ClickCampaignsAPIBaseURL")
        }

        return CreatorStudioConfiguration(
            creatorStudioAPI: creatorStudioAPI,
            clickCampaignsAPI: clickCampaignsAPI
        )
    }

    private static func secureServiceURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            return nil
        }
        return url
    }

    enum ConfigurationError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let key): "CreatorStudio Editor is missing \(key)."
            }
        }
    }
}
