import SwiftUI

struct CaptionTab: View {
    @Environment(EditorViewModel.self) var editor

    @State private var style: TextStyle = .caption
    @State private var center = AppTheme.Caption.defaultCenter
    @State private var selectedTrackId: String?
    @State private var selectedClipTargets: [String] = []
    @State private var provider: TranscriptionProvider = .local
    @State private var animationPreset: TextAnimation.Preset = .none
    @State private var animationHighlight: TextStyle.RGBA = TextAnimation.defaultHighlight
    @State private var censorProfanity = false
    @State private var maxWords: Int?
    @State private var maxCharacters: Int?
    @State private var maximumGapSeconds = CaptionGapSettings.default.maximumGapSeconds
    @State private var locale: Locale?
    @State private var supportedLocales: [Locale] = []
    @State private var isGenerating = false
    @State private var note: String?
    @State private var sourceExpanded = true
    @State private var settingsExpanded = true
    @State private var styleExpanded = false
    @State private var animationExpanded = false
    @State private var placementExpanded = true

    private static let previewText = L10n.key("Captions will look like this")
    private static let maxWordRange = 0.0...50.0
    private static let maxCharacterRange = 0.0...200.0

    private var aspect: CGFloat { CGFloat(editor.timeline.width) / CGFloat(max(1, editor.timeline.height)) }

    private var liveTargets: [String] {
        let sel = editor.selectedClipIds
        guard !sel.isEmpty else { return [] }
        return editor.captionTargets(ids: Array(sel)).map(\.id)
    }
    private var isAutoSource: Bool { selectedTrackId == nil && selectedClipTargets.isEmpty }
    private var sourceClipIds: [String] {
        if let selectedTrackId { return editor.captionTargets(trackIds: [selectedTrackId]).map(\.id) }
        return selectedClipTargets   // Auto resolves its source during generation
    }
    private var automaticSourceSummary: String {
        if !selectedClipTargets.isEmpty { return L10n.string("Selected Clips · \(selectedClipTargets.count)") }
        return editor.captionTargets(ids: []).isEmpty ? L10n.string("No audio") : L10n.string("Auto")
    }
    private var effectiveCount: Int {
        isAutoSource ? editor.captionTargets(ids: []).count : sourceClipIds.count
    }
    private var captionTrackIndices: [Int] {
        editor.timeline.tracks.indices.filter { !editor.captionTargets(trackIds: [editor.timeline.tracks[$0].id]).isEmpty }
    }
    private var canGenerateCaptions: Bool {
        effectiveCount > 0 && !isGenerating
    }

    private static let translateLanguages = [
        (code: "es", promptName: "Spanish"),
        (code: "fr", promptName: "French"),
        (code: "de", promptName: "German"),
        (code: "it", promptName: "Italian"),
        (code: "pt", promptName: "Portuguese"),
        (code: "ja", promptName: "Japanese"),
        (code: "ko", promptName: "Korean"),
        (code: "zh-Hans", promptName: "Chinese"),
        (code: "hi", promptName: "Hindi"),
        (code: "ar", promptName: "Arabic"),
    ]

    private var sourceSummary: String {
        guard let selectedTrackId else { return automaticSourceSummary }
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == selectedTrackId }) else { return L10n.string("No track") }
        return L10n.string("\(trackTitle(index)) · \(sourceClipIds.count)")
    }

    var body: some View {
        ZStack {
            VStack(spacing: AppTheme.Spacing.zero) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        sourceSection
                        settingsSection
                        styleSection
                        animationSection
                        placementSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: L10n.string("Transcribing…"), size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .task {
            guard supportedLocales.isEmpty else { return }
            supportedLocales = (await Transcription.supportedLocales())
                .sorted { languageName($0) < languageName($1) }
        }
        .onAppear { rememberSelectedClipTargets() }
        .onChange(of: editor.selectedClipIds) { _, _ in
            guard !editor.isMarqueeSelecting else { return }
            rememberSelectedClipTargets()
        }
        .onChange(of: editor.isMarqueeSelecting) { wasSelecting, isSelecting in
            guard wasSelecting, !isSelecting else { return }
            rememberSelectedClipTargets()
        }
    }

    private var sourceSection: some View {
        EditorPanelGroup(L10n.string("Source"), isExpanded: $sourceExpanded) {
            InspectorRow(
                label: L10n.string("Source"),
                labelHelp: L10n.string("Uses selected clips when available, otherwise all captionable audio. Choose a track to limit captions."),
                onReset: {
                    selectedTrackId = nil
                    selectedClipTargets = []
                }
            ) { sourceMenu }
            InspectorRow(
                label: L10n.string("Mode"),
                labelHelp: L10n.string("Captions use Apple’s on-device SpeechAnalyzer."),
                onReset: { provider = .local }
            ) { providerPicker }
        }
    }

    private var settingsSection: some View {
        EditorPanelGroup(L10n.string("Settings"), isExpanded: $settingsExpanded) {
            InspectorRow(label: L10n.string("Language"), onReset: { locale = nil }) {
                Menu {
                    Button(L10n.string("Auto")) { locale = nil }
                    if !supportedLocales.isEmpty {
                        Divider()
                        ForEach(supportedLocales, id: \.identifier) { loc in
                            Button(languageName(loc)) { locale = loc }
                        }
                    }
                } label: { EditorMenuValue(text: locale.map(languageName) ?? L10n.string("Auto"), expanded: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
                .frame(maxWidth: .infinity)
            }
            InspectorRow(
                label: L10n.string("Max words"),
                labelHelp: L10n.string("Cap the words shown per caption. None fits each line to the box."),
                onReset: { maxWords = nil }
            ) {
                ScrubbableNumberField(
                    value: Double(maxWords ?? 0),
                    range: Self.maxWordRange,
                    dragValueAdjustment: { $0.rounded() },
                    displayTextOverride: { $0 < 1 ? L10n.string("None") : nil },
                    onChanged: updateMaxWords,
                    onCommit: updateMaxWords
                )
                .accessibilityLabel(L10n.string("Max words"))
            }
            InspectorRow(
                label: L10n.string("Max characters"),
                labelHelp: L10n.string("Cap characters per caption, including spaces and punctuation. A single word may exceed the limit."),
                onReset: { maxCharacters = nil }
            ) {
                ScrubbableNumberField(
                    value: Double(maxCharacters ?? 0),
                    range: Self.maxCharacterRange,
                    dragValueAdjustment: { $0.rounded() },
                    displayTextOverride: { $0 < 1 ? L10n.string("None") : nil },
                    onChanged: updateMaxCharacters,
                    onCommit: updateMaxCharacters
                )
                .accessibilityLabel(L10n.string("Max characters"))
            }
            InspectorRow(
                label: L10n.string("Close gaps"),
                labelHelp: L10n.string("Extends captions across short gaps and holds the final caption."),
                onReset: {
                    maximumGapSeconds = CaptionGapSettings.default.maximumGapSeconds
                }
            ) {
                ScrubbableNumberField(
                    value: maximumGapSeconds,
                    range: CaptionGapSettings.maximumGapRange,
                    displayMultiplier: 1_000,
                    format: "%.0f",
                    valueSuffix: " ms",
                    dragSensitivity: 10,
                    dragValueAdjustment: { ($0 / 0.05).rounded() * 0.05 },
                    onChanged: { maximumGapSeconds = $0 },
                    onCommit: { maximumGapSeconds = $0 }
                )
                .accessibilityLabel(L10n.string("Close gaps"))
            }
            InspectorRow(label: L10n.string("Censor profanity"), onReset: { censorProfanity = false }) {
                Toggle(String(), isOn: $censorProfanity)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel(L10n.string("Censor profanity"))
                    .tint(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
            }
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button {
                selectedTrackId = nil
            } label: {
                Label(automaticSourceSummary, systemImage: selectedTrackId == nil ? "checkmark" : "")
            }

            Divider()

            if captionTrackIndices.isEmpty {
                Text(L10n.string("No Tracks"))
            } else {
                ForEach(captionTrackIndices, id: \.self) { index in
                    if editor.timeline.tracks.indices.contains(index) {
                        let track = editor.timeline.tracks[index]
                        let count = editor.captionTargets(trackIds: [track.id]).count
                        let clipCount = count == 1 ? L10n.string("1 clip") : L10n.string("\(count) clips")
                        Button {
                            selectedTrackId = track.id
                        } label: {
                            Label(
                                L10n.string("\(trackTitle(index)) · \(clipCount)"),
                                systemImage: selectedTrackId == track.id ? "checkmark" : ""
                            )
                        }
                    }
                }
            }
        } label: {
            EditorMenuValue(text: sourceSummary, expanded: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
        .frame(maxWidth: .infinity)
    }

    private var providerPicker: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            providerOption(.local, title: TranscriptionProvider.local.label)
        }
        .fixedSize()
    }

    private func providerOption(_ option: TranscriptionProvider, title: String) -> some View {
        let selected = provider == option
        return Button {
            provider = option
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                RadioIndicator(selected: selected, size: AppTheme.IconSize.xxs, innerPadding: AppTheme.Spacing.xxs)
                Text(L10n.string(key: title))
                    .font(.system(size: AppTheme.FontSize.sm, weight: selected ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                    .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Local runs with Apple's SpeechAnalyzer."))
    }

    private func rememberSelectedClipTargets() {
        let targets = liveTargets
        guard !targets.isEmpty || editor.focusedPanel != .media else { return }
        selectedClipTargets = targets
    }

    private func trackTitle(_ index: Int) -> String {
        editor.timelineTrackDisplayLabel(at: index)
    }

    private func languageName(_ loc: Locale) -> String {
        AppLocalization.shared.activeLocale.localizedString(forIdentifier: loc.identifier)
            ?? loc.identifier(.bcp47)
    }

    private func translationLanguageName(_ identifier: String) -> String {
        AppLocalization.shared.activeLocale.localizedString(forLanguageCode: identifier)
            ?? identifier
    }

    private var styleSection: some View {
        TextStyleControls(
            selection: TextStyleSelection(styles: [style], fallback: .caption),
            defaults: .caption,
            styleExpanded: $styleExpanded,
            groupsExpandedByDefault: false,
            actions: styleActions
        )
    }

    private var styleActions: TextStyleEditingActions {
        TextStyleEditingActions(
            apply: { _, mutation in mutation(&style) },
            commit: { _, mutation in mutation(&style) },
            commitColor: { _, mutation in mutation(&style) },
            cancelPending: { _ in },
            cancelFontPreview: { originalFont in
                if let originalFont { style.fontName = originalFont }
            }
        )
    }

    private var animationSection: some View {
        EditorPanelGroup(L10n.string("Animation"), isExpanded: $animationExpanded) {
            CaptionPresetGallery(selection: $animationPreset, highlight: animationHighlight)
            if animationPreset.usesHighlight {
                InspectorRow(
                    label: L10n.string("Highlight"),
                    labelHelp: L10n.string("Color for the active word."),
                    onReset: { animationHighlight = TextAnimation.defaultHighlight }
                ) {
                    ColorField(displayColor: animationHighlight.swiftUIColor, onUserChange: { animationHighlight = TextStyle.RGBA($0) })
                }
            }
        }
    }

    private var placementSection: some View {
        EditorPanelGroup(L10n.string("Placement"), isExpanded: $placementExpanded) {
            previewBox
            HStack(spacing: AppTheme.Spacing.mdLg) {
                Spacer(minLength: AppTheme.Spacing.xs)
                posField("X", value: center.x) { center.x = $0 }
                posField("Y", value: center.y) { center.y = $0 }
            }
        }
    }

    private var agentMenu: some View {
        EditorAgentMenu(
            help: L10n.string("Let Agent create captions for you. Choose a predefined task, or ask Agent in the chat.")
        ) {
            Button {
                captionTask("remove filler words (um, uh, er, like, you know) from the captions, keeping each caption's timing unchanged.")
            } label: { Label(L10n.string("Remove filler words"), systemImage: "text.badge.minus") }
            Button {
                captionTask("fix any misspelled names, brand names, or technical jargon in the captions using the surrounding context, keeping timing unchanged.")
            } label: { Label(L10n.string("Fix names & jargon"), systemImage: "checkmark.bubble") }
            Button {
                captionTask("add relevant emoji to the captions, keeping the text and timing otherwise unchanged.")
            } label: { Label(L10n.string("Add emoji"), systemImage: "face.smiling") }
            Menu {
                ForEach(Self.translateLanguages, id: \.code) { language in
                    Button(translationLanguageName(language.code)) {
                        captionTask("translate the captions to \(language.promptName), keeping each caption's timing unchanged.")
                    }
                }
            } label: { Label(L10n.string("Translate"), systemImage: "globe") }
        }
    }

    private func captionTask(_ task: String) {
        handoff("If the timeline has no captions yet, transcribe the spoken audio and add captions on word boundaries first. Then \(task)")
    }

    private func handoff(_ prompt: String) {
        let service = editor.agentService
        service.newChat()
        service.draft = prompt
        editor.agentPanelVisible = true
    }

    private var previewBox: some View {
        ZStack {
            AppTheme.Background.previewCanvasColor
            centerGuides
            GeometryReader { geo in
                CaptionAnimatedPreview(
                    text: L10n.string(key: Self.previewText), style: style, center: center,
                    preset: animationPreset, highlight: animationHighlight,
                    canvas: CGSize(width: max(1, editor.timeline.width), height: max(1, editor.timeline.height)),
                    size: geo.size
                )
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: AppTheme.ComponentSize.captionPreviewMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private var centerGuides: some View {
        GeometryReader { geo in
            let guide = AppTheme.Accent.timecodeColor.opacity(AppTheme.Opacity.prominent)
            ZStack {
                if center.x == AppTheme.Caption.centerSnapValue {
                    Rectangle().fill(guide).frame(width: AppTheme.BorderWidth.hairline, height: geo.size.height)
                }
                if center.y == AppTheme.Caption.centerSnapValue {
                    Rectangle().fill(guide).frame(width: geo.size.width, height: AppTheme.BorderWidth.hairline)
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private func snapCenter(_ v: Double) -> CGFloat {
        let centerValue = Double(AppTheme.Caption.centerSnapValue)
        return CGFloat(abs(v - centerValue) < AppTheme.Caption.centerSnapThreshold ? centerValue : v)
    }

    private func posField(_ label: String, value: CGFloat, onChange: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            ScrubbableNumberField(
                value: Double(value),
                range: AppTheme.Caption.minPosition...AppTheme.Caption.maxPosition,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                onChanged: { onChange(snapCenter($0)) }
            ) { onChange(snapCenter($0)) }
        }
    }

    private var generateBar: some View {
        EditorActionFooter(message: note) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(action: generate) {
                    Text(L10n.string("Generate Captions"))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorPrimary)
                .focusable(false)
                .disabled(!canGenerateCaptions)

                agentMenu
            }
        }
    }

    private func generate() {
        note = nil
        let sourceIds = sourceClipIds
        if selectedTrackId != nil && sourceIds.isEmpty {
            note = L10n.string("No audio selected.")
            return
        }
        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: sourceIds,
            autoDetect: isAutoSource,
            style: style,
            center: center,
            censorProfanity: provider == .local && censorProfanity,
            locale: locale,
            maxWords: maxWords,
            maxCharacters: maxCharacters,
            gapSettings: CaptionGapSettings(maximumGapSeconds: maximumGapSeconds) ?? .default,
            provider: provider,
            animation: TextAnimation(preset: animationPreset, highlight: animationHighlight)
        )
        Task {
            isGenerating = true
            defer { isGenerating = false }
            do {
                if try await editor.generateCaptions(for: request).isEmpty { note = L10n.string("No speech detected.") }
            } catch {
                note = localizedCaptionError(error)
            }
        }
    }

    private func updateMaxCharacters(_ value: Double) {
        let count = Int(value.rounded())
        maxCharacters = count > 0 ? count : nil
    }

    private func updateMaxWords(_ value: Double) {
        let count = Int(value.rounded())
        maxWords = count > 0 ? count : nil
    }

    private func localizedCaptionError(_ error: Error) -> String {
        guard let error = error as? TranscriptionError else { return error.localizedDescription }
        switch error {
        case .unsupportedLocale(let identifier):
            return L10n.string("On-device transcription is not available for \(identifier).")
        case .modelInstallFailed(let reason):
            return L10n.string("Could not install the on-device speech model: \(reason)")
        case .decodeFailed:
            return L10n.string("Could not parse transcription result.")
        case .audioExtractionFailed(let reason):
            return L10n.string("Audio extraction failed: \(reason)")
        case .analysisFailed(let reason):
            return L10n.string("Transcription failed: \(reason)")
        }
    }
}
