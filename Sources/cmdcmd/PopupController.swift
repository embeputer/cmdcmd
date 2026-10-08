import AppKit
import SwiftUI

/// The floating mini-panel anchored bottom-center of the screen under the
/// cursor. Unlike function's click-through overlay this one takes keyboard
/// focus — it activates the app on open so the text field gets first
/// responder immediately.
@MainActor
final class PopupController {
    private var panel: NSPanel?
    private var localKeyMonitor: Any?
    private var clickMonitor: Any?

    static var cursorScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Called when Esc is pressed or the panel is dismissed.
    var onDismiss: () -> Void = {}

    func present(content: some View) {
        dismiss(immediately: true)

        let screen = Self.cursorScreen
        let vf = screen.visibleFrame
        let size = NSSize(width: 600, height: 420)

        let panel = KeyablePanel(
            contentRect: NSRect(
                x: vf.midX - size.width / 2,
                y: vf.minY + 40,
                width: size.width, height: size.height
            ),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.onEscape = { [weak self] in self?.dismiss() }
        panel.onDeactivate = { [weak self] in self?.dismiss() }

        let host = NSHostingView(rootView: content)
        panel.contentView = host
        panel.orderFrontRegardless()

        // pop up from below
        let target = panel.frame
        var start = target
        start.origin.y -= 26
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        // take keyboard focus
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)

        // Esc / click-away handling
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 {
                Task { @MainActor in self?.dismiss() }
                return nil   // Esc
            }
            return e
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let inside = self.panel?.frame.contains(NSEvent.mouseLocation) == true
            if !inside {
                Task { @MainActor in self.dismiss() }
            }
        }
    }

    func dismiss(immediately: Bool = false) {
        guard let panel else { return }
        self.panel = nil
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        onDismiss()
        if immediately {
            panel.orderOut(nil)
            panel.close()
            return
        }
        var target = panel.frame
        target.origin.y -= 18
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.close()
            }
        })
    }
}

/// Borderless panel that can become key — required for the text field.
private final class KeyablePanel: NSPanel {
    var onEscape: @MainActor () -> Void = {}
    var onDeactivate: @MainActor () -> Void = {}
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            MainActor.assumeIsolated { onEscape() }
            return
        }
        super.keyDown(with: event)
    }
    override func resignKey() {
        super.resignKey()
        MainActor.assumeIsolated { onDeactivate() }
    }
}
