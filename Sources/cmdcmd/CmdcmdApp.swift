import AppKit
import SwiftUI

@main
struct CmdcmdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("cmdcmd", systemImage: "command") {
            MenuContent()
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    var body: some View {
        Button("Open cmdcmd") { AppDelegate.shared.openPopup() }
            .keyboardShortcut("o", modifiers: .command)
        Divider()

        Menu("Agent") {
            ForEach(Config.agents) { a in
                Button {
                    Config.current.selectedAgent = a.id
                    Config.save()
                    AppDelegate.shared.session.reconnect()
                } label: {
                    if a.id == Config.current.selectedAgent {
                        Label(a.name, systemImage: "checkmark")
                    } else { Text(a.name) }
                }
            }
        }

        Menu("Workspace") {
            ForEach(["~", "~/Desktop", "~/Documents", "~/Downloads"], id: \.self) { p in
                Button {
                    Config.current.workspace = p
                    Config.save()
                    AppDelegate.shared.session.reconnect()
                } label: {
                    if Config.current.workspace == p {
                        Label(p, systemImage: "checkmark")
                    } else { Text(p) }
                }
            }
            Divider()
            Button("Choose…") {
                let p = NSOpenPanel()
                p.canChooseFiles = false
                p.canChooseDirectories = true
                if p.runModal() == .OK, let u = p.url {
                    Config.current.workspace = u.path
                    Config.save()
                    AppDelegate.shared.session.reconnect()
                }
            }
        }
        Divider()

        if !Permissions.accessibilityGranted() {
            Button("Grant Accessibility (for ⌘⌘ trigger)…") {
                Permissions.requestAccessibility()
                Permissions.openSystemSettings(.accessibility)
            }
        }
        if !Permissions.screenRecordingGranted() {
            Button("Grant Screen Recording (for screenshots)…") {
                Permissions.requestScreenRecording()
                Permissions.openSystemSettings(.screenRecording)
            }
        }
        if Permissions.accessibilityGranted() && Permissions.screenRecordingGranted() {
            Text("⌘⌘ armed · ⌘+⌘ armed")
                .foregroundStyle(.secondary)
        }
        Divider()

        Button("Open ~/.cmdcmd") {
            NSWorkspace.shared.open(Config.dir)
        }
        Button("Quit cmdcmd") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var shared: AppDelegate!

    lazy var session = AgentSession()
    private let popup = PopupController()
    private let hotkey = HotkeyMonitor()
    private var permTimer: Timer?

    override init() {
        super.init()
        MainActor.assumeIsolated {
            AppDelegate.shared = self
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Config.load()

        hotkey.onTrigger = { [weak self] in self?.triggered() }
        hotkey.start()

        popup.onDismiss = { /* keep the agent session alive */ }

        // Poll for Accessibility so the tap re-arms after the user grants it.
        permTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Permissions.accessibilityGranted() {
                    self.hotkey.rearm()
                }
            }
        }

        // Warm the agent so the first popup is instant.
        session.ensureConnected()

        if !Permissions.accessibilityGranted() {
            Permissions.requestAccessibility()
        }
        // Registers cmdcmd in the Screen Recording list so the toggle can be
        // flipped before the first capture attempt.
        if !Permissions.screenRecordingGranted() {
            Permissions.requestScreenRecording()
        }
    }

    private func triggered() {
        if popup.isVisible {
            popup.dismiss()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        Task { @MainActor in
            // Capture before the panel exists so we're not in our own shot.
            let shot = Config.current.attachScreenshot ? await Capture.screen() : nil
            openPopup(screenshot: shot, frontApp: front)
        }
    }

    func openPopup(screenshot: URL? = nil, frontApp: String = "") {
        popup.present(content: PopupView(
            session: session,
            screenshot: screenshot,
            frontApp: frontApp,
            onClose: { [weak self] in self?.popup.dismiss() }
        ))
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
        hotkey.stop()
    }
}
