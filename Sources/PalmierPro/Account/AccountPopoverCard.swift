import SwiftUI

struct AccountPopoverCard: View {
    @Bindable private var account = AccountService.shared
    @Bindable private var session = CreatorStudioSession.shared
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

            if account.isSignedIn {
                Divider().overlay(AppTheme.Border.subtleColor)
                Label(accessLabel, systemImage: session.canUseProtectedFeatures ? "checkmark.circle.fill" : "lock.circle")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(session.canUseProtectedFeatures ? AppTheme.Status.successColor : AppTheme.Text.tertiaryColor)
            }

            Divider().overlay(AppTheme.Border.subtleColor)
            footerButton(label: L10n.string("Settings"), systemImage: "gearshape") {
                SettingsWindowController.shared.show(tab: .account)
                dismiss()
            }
            if account.isSignedIn {
                footerButton(label: L10n.string("Sign out"), systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await account.signOut() }
                    dismiss()
                }
            } else {
                footerButton(label: L10n.string("Connect GodMode MCP"), systemImage: "person.crop.circle") {
                    account.connectGodModeMCP()
                    dismiss()
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: AppTheme.Settings.popoverWidth)
        .focusEffectDisabled()
    }

    private var accessLabel: String {
        session.canUseProtectedFeatures
            ? L10n.string("GodMode active")
            : L10n.string("GodMode inactive · safe mode")
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
