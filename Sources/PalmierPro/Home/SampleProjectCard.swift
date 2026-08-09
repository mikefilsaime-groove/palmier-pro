import SwiftUI

struct SampleDownload {
    let slug: String
    var progress: Double = 0
    var failed = false
}

struct SampleProjectCard: View {
    let sample: SampleProjectService.Summary
    let download: SampleDownload?
    let action: () -> Void

    @State private var isHovered = false

    private let cardRadius: CGFloat = AppTheme.Radius.mdLg
    private let downloadBlur: CGFloat = 4

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            poster
                .frame(width: AppTheme.ComponentSize.projectCardWidth, height: AppTheme.ComponentSize.projectCardHeight)
                .blur(radius: download == nil ? 0 : downloadBlur)
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.high), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 60)
            .allowsHitTesting(false)

            Text(sample.title)
                .font(.system(size: AppTheme.FontSize.smMd, weight: .regular))
                .foregroundStyle(AppTheme.MediaOverlay.primaryColor)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.smMd)

            if let download {
                downloadOverlay(download)
            }
        }
        .frame(width: AppTheme.ComponentSize.projectCardWidth, height: AppTheme.ComponentSize.projectCardHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if download == nil || download?.failed == true { action() }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(
                    AppTheme.Interaction.fill(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .help(sample.title)
        .padding(AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private func downloadOverlay(_ download: SampleDownload) -> some View {
        ZStack {
            AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.faint)
            if download.failed {
                VStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    Text(L10n.string("Retry"))
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                }
                .foregroundStyle(AppTheme.MediaOverlay.primaryColor)
            } else {
                ProgressView(value: download.progress)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.MediaOverlay.primaryColor)
                    .padding(.horizontal, AppTheme.Spacing.lg)
            }
        }
        .frame(width: AppTheme.ComponentSize.projectCardWidth, height: AppTheme.ComponentSize.projectCardHeight)
    }

    @ViewBuilder
    private var poster: some View {
        if let urlString = sample.posterUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                AppTheme.Background.placeholderColor
            }
        } else {
            AppTheme.Background.placeholderColor
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
        }
    }
}
