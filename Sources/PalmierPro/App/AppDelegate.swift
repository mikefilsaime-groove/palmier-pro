import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private var isTerminating = false
    private var restartRequested = false

    private override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app (required when launched from CLI, not a .app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu?.items.first?.title = AppIdentity.name
        NSApp.mainMenu?.items.first?.submenu?.title = AppIdentity.name
        NSApp.activate(ignoringOtherApps: true)

        HomeWindowController.shared.showWindow(nil)
        SkillStore.shared.startSkillSync()
        Task.detached(priority: .utility) {
            Project.ensureStorageDirectory()
        }

        AppNotifications.configure()
        _ = Updater.shared

        AppState.shared.startMCPService()

        // Pre-warm NSOpenPanel to avoid main thread blocking during cold start.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !self.isTerminating else { return }
            _ = NSOpenPanel()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.showHome()
        }
        return true
    }

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            AppDelegate.shared.beginTermination()
        }
        return .terminateLater
    }

    private func beginTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        let projects = AppState.shared.openProjects
        let shouldRestart = restartRequested

        Task { @MainActor in
            do {
                for project in projects {
                    try await project.saveBeforeClosing()
                }
                if shouldRestart {
                    try await Self.scheduleRelaunch(
                        applicationURL: Bundle.main.bundleURL,
                        processID: ProcessInfo.processInfo.processIdentifier
                    )
                }
                await SkillStore.shared.prepareForTermination()
                if !MLXRuntime.beginTermination() {
                    await MLXRuntime.waitUntilIdle()
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
                projects.forEach { $0.editorViewModel.projectPackageCoordinator.cancelClosing() }
                restartRequested = false
                isTerminating = false
                NSApp.presentError(error)
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    func restart() {
        guard !isTerminating else { return }
        restartRequested = true
        NSApp.terminate(nil)
    }

    @concurrent
    private static func scheduleRelaunch(applicationURL: URL, processID: Int32) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open -n \"$2\"",
            "palmier-restart",
            String(processID),
            applicationURL.path,
        ]
        try process.run()
    }

    @MainActor
    @objc func newProject(_ sender: Any?) {
        AppState.shared.createProjectInteractively()
    }

    @MainActor
    @objc func openProject(_ sender: Any?) {
        AppState.shared.openProjectFromPanel()
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        SettingsCoordinator.shared.show()
    }

    @MainActor
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .shortcuts)
    }

    @MainActor
    @objc func showMCPInstructions(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .mcp)
    }

    @MainActor
    @objc func showTutorial(_ sender: Any?) {
        guard let editor = AppState.shared.activeProject?.editorViewModel else { return }
        editor.tour.start(in: editor)
    }
}
