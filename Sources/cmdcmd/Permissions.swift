import ApplicationServices
import AppKit
import CoreGraphics

enum Permissions {
    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts once via the system dialog if not yet granted.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    /// Deep link into System Settings' privacy panes.
    static func openSystemSettings(_ pane: PrivacyPane) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!)
    }

    enum PrivacyPane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
    }
}
