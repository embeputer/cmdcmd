import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshot of the display under the cursor, written to a temp PNG.
enum Capture {
    @MainActor
    static func screen() async -> URL? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            // Display under the mouse pointer, falling back to the first.
            let mouse = NSEvent.mouseLocation
            let target = content.displays.first { display in
                guard let screen = NSScreen.screens.first(where: {
                    $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == display.displayID as NSNumber
                }) else { return false }
                return screen.frame.contains(mouse)
            } ?? content.displays.first
            guard let display = target else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmdcmd-\(UUID().uuidString).png")
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return url
        } catch {
            return nil
        }
    }
}
