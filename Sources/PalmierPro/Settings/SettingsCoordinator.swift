import AppKit
import SwiftUI

enum SettingsPresentationTarget: Hashable {
    case home
    case project(ObjectIdentifier)
}

struct SettingsPresentation: Identifiable {
    let id = UUID()
    let target: SettingsPresentationTarget
    let initialTab: SettingsTab
}

@Observable
@MainActor
final class SettingsCoordinator {
    static let shared = SettingsCoordinator()

    private(set) var presentation: SettingsPresentation?

    private init() {}

    func show(tab: SettingsTab = .account) {
        if let project = AppState.shared.activeProject {
            let target = SettingsPresentationTarget.project(ObjectIdentifier(project))
            presentation = SettingsPresentation(target: target, initialTab: tab)
            project.showWindows()
            project.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        } else {
            presentation = SettingsPresentation(target: .home, initialTab: tab)
            HomeWindowController.shared.showWindow(nil)
            HomeWindowController.shared.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func presentation(for target: SettingsPresentationTarget) -> SettingsPresentation? {
        guard presentation?.target == target else { return nil }
        return presentation
    }

    func isPresented(in target: SettingsPresentationTarget) -> Bool {
        presentation?.target == target
    }

    func dismiss(in target: SettingsPresentationTarget) {
        guard presentation?.target == target else { return }
        presentation = nil
    }
}

struct ApplicationSettingsHost<Content: View>: View {
    let target: SettingsPresentationTarget
    let content: Content

    @Bindable private var settings = SettingsCoordinator.shared

    init(target: SettingsPresentationTarget, @ViewBuilder content: () -> Content) {
        self.target = target
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .allowsHitTesting(!settings.isPresented(in: target))
                .accessibilityHidden(settings.isPresented(in: target))

            if let presentation = settings.presentation(for: target) {
                SettingsView(initialTab: presentation.initialTab) {
                    settings.dismiss(in: target)
                }
                .id(presentation.id)
            }
        }
    }
}
