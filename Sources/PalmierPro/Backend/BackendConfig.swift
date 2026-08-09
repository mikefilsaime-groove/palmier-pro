import Foundation

enum BackendConfig {
    static let sampleProjectBaseURL: URL? = string("CreatorStudioSampleProjectBaseURL")
        .flatMap { URL(string: $0) }
        ?? URL(string: "https://groovy-kiwi-408.convex.site")

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}
