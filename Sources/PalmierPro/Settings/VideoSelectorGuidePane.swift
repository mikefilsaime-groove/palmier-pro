import SwiftUI

struct VideoSelectorGuidePane: View {
    private let guideURL = URL(string: "https://creatorstudio.gg/video-selector")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("Choose the right video model")) {
                Text(L10n.string("Not sure which model fits your shot? The CreatorStudio Video Selector Guide helps compare current models by workflow, source media, duration, aspect ratio, resolution, audio support, and estimated provider cost."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: guideURL) {
                    Label(L10n.string("Open Video Selector Guide"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
            }

            SettingsSection(title: L10n.string("Use it while generating")) {
                Text(L10n.string("In the Generate panel, choose Video and click Help me choose. When CreatorStudio account sync is connected, the selector can apply its recommended model and compatible settings directly to your generation."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
