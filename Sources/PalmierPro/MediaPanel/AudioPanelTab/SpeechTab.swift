import SwiftUI

struct SpeechAnalysisSections: View {
    @Environment(EditorViewModel.self) private var editor
    @Binding var silenceExpanded: Bool
    @Binding var speakerExpanded: Bool

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                    silenceSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let phase = editor.speakerIdentifyPhase {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: phase, size: .preview)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var silenceSection: some View {
        EditorPanelGroup(
            L10n.string("Silence Detection"),
            isExpanded: $silenceExpanded
        ) {
            InspectorRow(
                label: L10n.string("Mark Silence"),
                labelHelp: L10n.string("Speech is detected on-device in the background. Dims quiet, speech-free spans on timeline waveforms."),
                labelAlignment: .leading,
                onReset: { editor.markDeadAir = false }
            ) {
                Toggle(String(), isOn: Binding(
                    get: { editor.markDeadAir },
                    set: { editor.markDeadAir = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L10n.string("Mark Silence"))
            }
            if editor.speechAnalyzingCount > 0 {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(editor.speechAnalyzingCount == 1
                        ? L10n.string("Detecting speech…")
                        : L10n.string("Detecting speech in \(editor.speechAnalyzingCount) files…"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            silenceTimingControls
            silenceActions
        }
    }

    private var silenceTimingControls: some View {
        Group {
            InspectorRow(
                label: L10n.string("Minimum Pause"),
                labelHelp: L10n.string("Ignores speech-free pauses shorter than this."),
                labelAlignment: .leading,
                onReset: {
                    editor.setMinimumSilenceDuration(SilenceRemovalSettings.default.minimumPauseSeconds)
                }
            ) {
                durationField(
                    label: L10n.string("Minimum Pause"),
                    value: editor.silenceRemovalSettings.minimumPauseSeconds,
                    range: SilenceRemovalSettings.minimumPauseRange,
                    step: 0.05,
                    set: editor.setMinimumSilenceDuration
                )
            }
            InspectorRow(
                label: L10n.string("Speech Padding"),
                labelHelp: L10n.string("Keeps this much audio before and after detected speech."),
                labelAlignment: .leading,
                onReset: {
                    editor.setSpeechPaddingDuration(SilenceRemovalSettings.default.speechPaddingSeconds)
                }
            ) {
                durationField(
                    label: L10n.string("Speech Padding"),
                    value: editor.silenceRemovalSettings.speechPaddingSeconds,
                    range: SilenceRemovalSettings.speechPaddingRange,
                    step: 0.025,
                    set: editor.setSpeechPaddingDuration
                )
            }
        }
    }

    private func durationField(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        set: @escaping (Double) -> Void
    ) -> some View {
        ScrubbableNumberField(
            value: value,
            range: range,
            displayMultiplier: 1_000,
            format: "%.0f",
            valueSuffix: " ms",
            dragSensitivity: 10,
            dragValueAdjustment: { ($0 / step).rounded() * step },
            onChanged: set,
            onCommit: set
        )
        .accessibilityLabel(L10n.string(key: label))
    }

    private var silenceActions: some View {
        let count = editor.allDeadAir().reduce(0) { $0 + $1.ranges.count }
        return HStack(spacing: AppTheme.Spacing.sm) {
            Spacer(minLength: AppTheme.Spacing.zero)
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .monospacedDigit()
            }
            Button(L10n.string("Remove")) { editor.removeAllDeadAir() }
                .buttonStyle(.capsule(.secondary))
                .disabled(count == 0)
                .help(L10n.string("Ripple-deletes every silent section; downstream clips close the gaps."))
        }
    }
}
