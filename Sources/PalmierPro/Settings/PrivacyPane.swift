import SwiftUI

struct PrivacyPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(L10n.string("CreatorStudio Editor does not send Palmier analytics or crash reports."))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.string("Project media stays on this Mac unless you explicitly submit media to CreatorStudio, Fal.ai, ElevenLabs, or another connected service."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
