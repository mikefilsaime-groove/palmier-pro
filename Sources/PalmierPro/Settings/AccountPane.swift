import SwiftUI

struct AccountPane: View {
    @Bindable private var session = CreatorStudioSession.shared
    @Bindable private var credentials = GenerationCredentialStore.shared

    @State private var falKey = ""
    @State private var elevenLabsKey = ""
    @AppStorage(CodexImageGenerationPreferences.defaultsKey) private var preferCodexImages = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            accountSection
            codexImageSection
            if session.isSignedIn { creatorStudioSection }
            localFalSection
            elevenLabsSection
            if let error = session.lastError ?? credentials.lastError {
                Text(verbatim: error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
        .onChange(of: preferCodexImages) { _, _ in
            Task { await ModelCatalog.shared.reload() }
        }
    }

    private var accountSection: some View {
        SettingsSection(title: L10n.string("CreatorStudio account sync")) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack(spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(verbatim: accountTitle)
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(verbatim: accountDetail)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(session.isSignedIn ? AppTheme.Status.successColor : AppTheme.Text.tertiaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: AppTheme.Spacing.lg)
                    if session.isSignedIn {
                        Button(L10n.string("Refresh Fal.ai status")) {
                            Task {
                                await session.refreshCreatorStudioConnection()
                                await ModelCatalog.shared.reload()
                            }
                        }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        Button(L10n.string("Disconnect")) { Task { await session.signOut() } }
                            .buttonStyle(.capsule(.secondary, size: .regular))
                    } else if session.pairingCode == nil {
                        Button(
                            session.isSigningIn
                                ? L10n.string("Starting connection…")
                                : L10n.string("Connect once")
                        ) {
                            Task { await session.signIn() }
                        }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .disabled(session.isSigningIn || session.isRestoringConnection || !session.isConfigured)
                    }
                }

                if let code = session.pairingCode, let instructions = session.pairingInstructions {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Text(L10n.string("1. Open a new chat in Codex or Claude Code."))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text(verbatim: code)
                            .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .textSelection(.enabled)
                        Text(L10n.string("2. Paste these instructions:"))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text(verbatim: instructions)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Button(L10n.string("Copy instructions")) {
                                session.copyPairingInstructions()
                            }
                            .buttonStyle(.capsule(.secondary, size: .regular))
                            Button(L10n.string("Cancel")) {
                                session.cancelSignIn()
                            }
                            .buttonStyle(.capsule(.secondary, size: .regular))
                        }
                    }
                }
            }
        }
    }

    private var codexImageSection: some View {
        SettingsSection(title: L10n.string("Image generation")) {
            SettingsToggleRow(
                title: L10n.string("Prefer Codex GPT Image 2"),
                subtitle: L10n.string(
                    "Uses the signed-in Codex subscription allowance by default. Fal.ai image models remain available in the model picker."
                ),
                isOn: $preferCodexImages
            )
        }
    }

    private var creatorStudioSection: some View {
        SettingsSection(title: L10n.string("CreatorStudio Fal.ai")) {
            credentialStatusRow(
                title: creatorStudioTitle,
                detail: creatorStudioDetail,
                systemImage: creatorStudioConfigured ? "checkmark.circle.fill" : "exclamationmark.circle"
            )
        }
    }

    private var localFalSection: some View {
        SettingsSection(title: L10n.string("Fal.ai API key on this Mac")) {
            apiKeyRow(
                placeholder: credentials.hasFalKey ? "••••••••••••" : L10n.string("Fal.ai API key"),
                value: $falKey,
                isStored: credentials.hasFalKey,
                save: {
                    guard await credentials.save(falKey, kind: .fal) else { return }
                    falKey = ""
                },
                delete: { await credentials.delete(.fal) }
            )
            Text(L10n.string("Used directly when your connected CreatorStudio account has no Fal.ai key on file."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }

    private var elevenLabsSection: some View {
        SettingsSection(title: L10n.string("ElevenLabs")) {
            apiKeyRow(
                placeholder: credentials.hasElevenLabsKey ? "••••••••••••" : L10n.string("ElevenLabs API key"),
                value: $elevenLabsKey,
                isStored: credentials.hasElevenLabsKey,
                save: {
                    guard await credentials.save(elevenLabsKey, kind: .elevenLabs) else { return }
                    elevenLabsKey = ""
                    await ModelCatalog.shared.reload()
                },
                delete: {
                    await credentials.delete(.elevenLabs)
                    await ModelCatalog.shared.reload()
                }
            )
            Text(L10n.string("Stored only in this Mac’s Keychain and sent directly to ElevenLabs."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }

    private func credentialStatusRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(creatorStudioConfigured ? AppTheme.Status.successColor : AppTheme.Text.tertiaryColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(verbatim: title)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(verbatim: detail)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.lg)
        }
    }

    private func apiKeyRow(
        placeholder: String,
        value: Binding<String>,
        isStored: Bool,
        save: @escaping @MainActor () async -> Void,
        delete: @escaping @MainActor () async -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            SecureField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm))
            Button(L10n.string("Validate and save")) { Task { await save() } }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || credentials.isValidating)
            if isStored {
                Button(L10n.string("Delete")) { Task { await delete() } }
                    .buttonStyle(.capsule(.secondary, size: .regular))
            }
        }
    }

    private var accountTitle: String {
        if session.isRestoringConnection { return L10n.string("Restoring saved connection…") }
        return session.isSignedIn ? L10n.string("Connected") : L10n.string("Not connected")
    }

    private var accountDetail: String {
        session.isSignedIn
            ? L10n.string("Saved in this Mac’s Keychain. CreatorStudio Editor will not ask you to connect again unless you disconnect.")
            : L10n.string("Optional. Connect once to sync the Fal.ai key stored in your CreatorStudio account. The editor works without this connection.")
    }

    private var creatorStudioConfigured: Bool {
        if case .configured = session.falConnection { return true }
        return false
    }

    private var creatorStudioTitle: String {
        switch session.falConnection {
        case .configured: L10n.string("Connected")
        case .missing: L10n.string("No Fal.ai key on file")
        case .unknown: L10n.string("Connection not checked")
        case .unavailable: L10n.string("Connection unavailable")
        }
    }

    private var creatorStudioDetail: String {
        switch session.falConnection {
        case .configured(let masked): masked ?? L10n.string("CreatorStudio will run Fal.ai jobs with your encrypted key.")
        case .missing: L10n.string("Add a local Fal.ai key below or connect Fal.ai in CreatorStudio.")
        case .unknown: L10n.string("Refresh the Fal.ai connection status.")
        case .unavailable(let message): message
        }
    }
}
