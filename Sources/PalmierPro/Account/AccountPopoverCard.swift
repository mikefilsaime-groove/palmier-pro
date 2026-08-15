import SwiftUI

struct AccountPopoverCard: View {
    @Bindable private var account = AccountService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.md) {
                UserAvatar(diameter: AppTheme.IconSize.xl, fontSize: AppTheme.FontSize.mdLg)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(account.displayPrimaryText)
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                    if let secondary = account.displaySecondaryText {
                        Text(verbatim: secondary)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if account.isConnected {
                Divider().overlay(AppTheme.Border.subtleColor)
                Label(L10n.string("CreatorStudio account sync connected"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.successColor)
            }

            Divider().overlay(AppTheme.Border.subtleColor)
            footerButton(label: L10n.string("Settings"), systemImage: "gearshape") {
                SettingsCoordinator.shared.show(tab: .account)
                dismiss()
            }
            if account.isConnected {
                footerButton(label: L10n.string("Disconnect CreatorStudio"), systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await account.disconnectCreatorStudio() }
                    dismiss()
                }
            } else {
                footerButton(label: L10n.string("Connect CreatorStudio"), systemImage: "person.crop.circle") {
                    account.connectCreatorStudio()
                    dismiss()
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: AppTheme.Settings.popoverWidth)
        .focusEffectDisabled()
    }

    private func footerButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: systemImage).font(.system(size: AppTheme.FontSize.smMd))
                Text(verbatim: label).font(.system(size: AppTheme.FontSize.sm))
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
    }
}
