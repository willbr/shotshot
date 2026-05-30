import AppKit
import CoreGraphics
import IOKit.hidsystem

final class HotkeyController {
    private var eventTap: CFMachPort?
    private let rectSelectionController = RectSelectionController()

    init() {
        checkPermissions()
        setupHotkey()
    }

    private func checkPermissions() {
        let hasAccessibility = AXIsProcessTrusted()
        let hasScreenRecording = CGPreflightScreenCaptureAccess()

        print("[permissions] Accessibility trusted: \(hasAccessibility ? "YES" : "NO")")
        print("[permissions] Screen Recording preflight: \(hasScreenRecording ? "YES" : "NO")")

        if #available(macOS 10.15, *) {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        if !hasAccessibility || !hasScreenRecording {
            print("\nShotshot needs permissions (opening System Settings for you)...\n")

            if !hasAccessibility {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }

            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }

            if !hasScreenRecording {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func setupHotkey() {
        let trustedNow = AXIsProcessTrusted()
        print("[permissions] AXIsProcessTrusted right before creating event tap: \(trustedNow ? "YES" : "NO")")

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }
            return HotkeyController.handleKeyEvent(event, userInfo: userInfo)
        }

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("[hotkey] Event tap created successfully")
        } else {
            print("Failed to create event tap. Accessibility/Input Monitoring permission is missing.")

            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func handleKeyEvent(_ event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        let hasCommand = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)

        guard let controllerPtr = userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let controller = Unmanaged<HotkeyController>.fromOpaque(controllerPtr).takeUnretainedValue()

        // ANSI keycodes (same values used in the original)
        let kKeyS: CGKeyCode = 1
        let kKey4: CGKeyCode = 21

        if hasCommand && hasShift && keycode == kKeyS {
            controller.startRectSelection()
            return nil // consume
        }

        if hasCommand && hasShift && keycode == kKey4 {
            controller.takeScreenshot()
            return nil // consume
        }

        return Unmanaged.passUnretained(event)
    }

    private func takeScreenshot() {
        #if DEBUG
        print("Hotkey received — attempting capture...")
        #endif

        guard let pngData = Capture.fullscreen() else {
            print("Capture failed")
            return
        }

        #if DEBUG
        print("Capture succeeded, PNG size = \(pngData.count) bytes")
        #endif

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        let success = pasteboard.writeObjects([item])

        if success {
            #if DEBUG
            print("Successfully wrote PNG to clipboard (\(pngData.count) bytes)")
            #endif
        } else {
            print("Failed to write PNG to clipboard")
        }
    }

    private func startRectSelection() {
        rectSelectionController.startSelection()
    }
}
