import SwiftUI

struct GeneralPane: View {
    @Bindable private var localization = AppLocalization.shared
    @Bindable private var updater = Updater.shared

    private var languageOptions: [AppLanguage] {
        [.system] + localization.availableLanguages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("General")) {
                HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(L10n.string("Language"))
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                            .foregroundStyle(AppTheme.Text.primaryColor)

                        Text(L10n.string("Language for the editor UI"))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }

                    Spacer(minLength: AppTheme.Spacing.lg)

                    Picker(String(), selection: $localization.selection) {
                        ForEach(languageOptions) { language in
                            Text(verbatim: localization.displayName(for: language))
                                .tag(language)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L10n.string("Language"))
                    .accessibilityHint(L10n.string("Language for the editor UI"))
                }

                if localization.requiresRestart {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                        Text(L10n.string("Changes take effect after restarting CreatorStudio Editor."))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: AppTheme.Spacing.lg)

                        Button(L10n.string("Restart CreatorStudio Editor")) {
                            AppDelegate.shared.restart()
                        }
                        .buttonStyle(.capsule(.secondary))
                        .fixedSize()
                    }
                }
            }

            SettingsSection(title: L10n.string("Notifications")) {
                NotificationsPane()
            }

            SettingsSection(title: L10n.string("Software Updates")) {
                HStack(alignment: .center, spacing: AppTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(L10n.string("CreatorStudio Editor checks GitHub for updates automatically."))
                            .font(.system(size: AppTheme.FontSize.md))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(L10n.string("When an update is available, use the Update button in the Home sidebar or project title bar to download and install it."))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: AppTheme.Spacing.lg)
                    Button(L10n.string("Check for Updates…")) {
                        updater.checkForUpdates(nil)
                    }
                    .buttonStyle(.capsule(.secondary))
                    .fixedSize()
                }
            }

            SettingsSection(title: L10n.string("Privacy & Diagnostics")) {
                PrivacyPane()
            }
        }
    }
}
