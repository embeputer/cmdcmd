import AppKit
import CoreGraphics
import Foundation

/// Fires `onTrigger` when the user either
///   1. taps one Command key twice quickly (down+up, down+up — "cmdcmd"), or
///   2. holds left Command and presses right Command (or vice-versa).
///
/// Implemented with a session CGEventTap on flagsChanged + keyDown.
/// Events are observed, never swallowed — a lone Command press does nothing
/// in macOS anyway, so passively watching is enough.
///
/// Tap callbacks may run on a background queue, so nothing on the callback
/// path is actor-isolated — we hop to MainActor for the trigger instead.
/// Mutable state is confined to the serial tap callback plus start/stop.
final class HotkeyMonitor: @unchecked Sendable {
    /// Invoked on the main actor.
    var onTrigger: @MainActor @Sendable () -> Void = {}

    /// Max duration of a single Command press for it to count as a "tap".
    var tapThreshold: TimeInterval = 0.35
    /// Max gap between the first tap's key-up and the second tap's key-down.
    var doubleTapWindow: TimeInterval = 0.5

    /// kVK_RightCommand / kVK_Command
    private let cmdKeys: Set<Int64> = [54, 55]

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fallbackMonitors: [Any] = []

    /// Tap-callback-only state.
    private var downSince: [Int64: Date] = [:]
    private var cmdHeld: Set<Int64> = []
    private var lastTapUp: Date?
    private var bothFired = false

    var isRunning: Bool { tap != nil || !fallbackMonitors.isEmpty }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (CGEventMask(1) << UInt64(CGEventType.flagsChanged.rawValue)) |
            (CGEventMask(1) << UInt64(CGEventType.keyDown.rawValue))
        let ref = Unmanaged.passUnretained(self).toOpaque()

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyEventCallback,
            userInfo: ref
        ) {
            self.tap = tap
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            FileHandle.standardError.write(Data("[cmdcmd] event tap installed\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[cmdcmd] event tap unavailable (no Accessibility?) — passive monitor\n".utf8))
            startFallbackMonitor()
        }
    }

    /// Retry the event tap — called when Accessibility is granted after launch.
    func rearm() {
        guard tap == nil else { return }
        stopFallback()
        start()
        if tap == nil { startFallbackMonitor() }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
        }
        stopFallback()
    }

    private func stopFallback() {
        for m in fallbackMonitors { NSEvent.removeMonitor(m) }
        fallbackMonitors = []
    }

    /// Without Accessibility we can still observe events globally — the only
    /// difference is we can't inspect the event before delivery, which we
    /// don't need anyway.
    private func startFallbackMonitor() {
        guard fallbackMonitors.isEmpty else { return }
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(
                keyCode: Int64(event.keyCode),
                commandDown: event.modifierFlags.contains(.command),
                at: Date()
            )
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.resetTapSequence()
        }
        fallbackMonitors = [flags, keys].compactMap { $0 }
    }

    fileprivate func reEnableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Any non-modifier key press breaks a tap sequence (cmd+letter combos).
    fileprivate func resetTapSequence() {
        lastTapUp = nil
    }

    fileprivate func handleFlagsChanged(keyCode: Int64, commandDown: Bool, at now: Date) {
        guard cmdKeys.contains(keyCode) else {
            // Another modifier joined — treat as a chord, reset tap progress.
            resetTapSequence()
            return
        }

        if commandDown, !cmdHeld.contains(keyCode) {
            // Command key went down.
            if !cmdHeld.isEmpty, !bothFired {
                // Second Command while the first is still held → L+R combo.
                bothFired = true
                fire()
            }
            cmdHeld.insert(keyCode)
            downSince[keyCode] = now
        } else if !commandDown, cmdHeld.contains(keyCode) {
            // Command key went up.
            cmdHeld.remove(keyCode)
            let down = downSince.removeValue(forKey: keyCode)
            if cmdHeld.isEmpty { bothFired = false }

            guard let down, now.timeIntervalSince(down) < tapThreshold else {
                lastTapUp = nil   // held too long — not a tap
                return
            }
            if let last = lastTapUp, now.timeIntervalSince(last) < doubleTapWindow {
                lastTapUp = nil
                fire()
            } else {
                lastTapUp = now
            }
        }
    }

    private func fire() {
        lastTapUp = nil
        let cb = onTrigger
        Task { @MainActor in cb() }
    }
}

private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reEnableTap()
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    switch type {
    case .flagsChanged:
        monitor.handleFlagsChanged(
            keyCode: keyCode,
            commandDown: event.flags.contains(.maskCommand),
            at: Date()
        )
    case .keyDown:
        monitor.resetTapSequence()
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
