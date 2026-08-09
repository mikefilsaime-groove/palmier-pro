import SwiftUI
import WebKit

struct VideoModelSelectorSelection: Sendable {
    let modelID: String
    let operation: String
    let resolution: String
    let duration: Int
    let aspectRatio: String
    let generateAudio: Bool
}

struct VideoModelSelectorView: View {
    let onSelection: @MainActor (VideoModelSelectorSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: CreatorStudioSelectorSession?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                Text(L10n.string("Help me choose a video model"))
                    .font(.system(size: AppTheme.FontSize.title2, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: AppTheme.Spacing.lg)
                Button(L10n.string("Close")) { dismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
            }

            if let session {
                VideoModelSelectorWebView(session: session) { selection in
                    guard ModelCatalog.shared.video.contains(where: { $0.id == selection.modelID }) else {
                        error = L10n.string("That model is no longer available. Refresh the catalog and try again.")
                        return
                    }
                    onSelection(selection)
                    dismiss()
                } onError: { message in
                    error = message
                }
            } else if let error {
                ContentUnavailableView(
                    L10n.string("Selector unavailable"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(verbatim: error)
                )
            } else {
                ProgressView(L10n.string("Opening CreatorStudio…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error, session != nil {
                Text(verbatim: error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(minWidth: AppTheme.Window.settingsMin.width, minHeight: AppTheme.Window.settingsMin.height)
        .background(AppTheme.Background.baseColor)
        .task {
            do { session = try await CreatorStudioAPIClient.createSelectorSession() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct VideoModelSelectorWebView: NSViewRepresentable {
    let session: CreatorStudioSelectorSession
    let onSelection: @MainActor (VideoModelSelectorSelection) -> Void
    let onError: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onSelection: onSelection, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(context.coordinator, name: "creatorStudioEditor")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: session.url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "creatorStudioEditor")
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let session: CreatorStudioSelectorSession
        private let onSelection: @MainActor (VideoModelSelectorSelection) -> Void
        private let onError: @MainActor (String) -> Void

        init(
            session: CreatorStudioSelectorSession,
            onSelection: @escaping @MainActor (VideoModelSelectorSelection) -> Void,
            onError: @escaping @MainActor (String) -> Void
        ) {
            self.session = session
            self.onSelection = onSelection
            self.onError = onError
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.securityOrigin.protocol == "https",
                  message.frameInfo.securityOrigin.host == session.url.host,
                  let body = message.body as? [String: Any],
                  body["source"] as? String == "creatorstudio.video-selector",
                  body["version"] as? Int == session.protocolVersion,
                  body["type"] as? String == "selection.confirmed",
                  body["selectorSessionId"] as? String == session.id,
                  let selection = body["selection"] as? [String: Any],
                  let modelID = selection["modelId"] as? String,
                  let operation = selection["operation"] as? String,
                  let resolution = selection["resolution"] as? String,
                  let duration = selection["duration"] as? Int,
                  let aspectRatio = selection["aspectRatio"] as? String,
                  let generateAudio = selection["audio"] as? Bool else {
                Task { @MainActor in onError("CreatorStudio returned an invalid selector message.") }
                return
            }
            let result = VideoModelSelectorSelection(
                modelID: modelID,
                operation: operation,
                resolution: resolution,
                duration: duration,
                aspectRatio: aspectRatio,
                generateAudio: generateAudio
            )
            Task { @MainActor in onSelection(result) }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame != false else {
                decisionHandler(.allow)
                return
            }
            guard let url = navigationAction.request.url,
                  url.scheme == "https", url.host == session.url.host else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
