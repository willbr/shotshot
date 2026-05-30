import AppKit
import CoreGraphics
import Foundation

// MARK: - SelectionView

/// The view that draws the dimmed overlay + transparent selection hole + border + size label
/// for a single physical screen.
final class SelectionView: NSView {
    var dimColor: NSColor = NSColor.black.withAlphaComponent(0.5)
    /// The portion of the selection that should be "cut out" on *this* view's screen, in local view coordinates.
    var localSelectionRect: NSRect = .zero
    var isSelecting: Bool = false
    /// Only one view (the one with largest overlap) shows the dimension label.
    var showsSizeLabel: Bool = false

    // The view uses a flipped coordinate system (Y=0 at top of this screen's window,
    // Y increasing downward). This matches how global-to-local conversion + the
    // existing drawing math (NSMaxY for label "below", hole origin, etc.) expect
    // to lay out content relative to the physical monitor.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Intentionally not layer-backed — layer-backed transparent windows at max level
        // often produce striped/garbage corruption on secondary monitors.
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { true }

    // Local mouse handlers are intentionally minimal. Drag tracking is driven by a CGEventTap
    // (see mouseSelectionEventCallback) so that clicks are consumed and do not reach apps
    // under the dimmed overlay, while still supporting cross-monitor drags.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func cancelOperation(_ sender: Any?) {
        // Escape handling is done via NSEvent local monitor installed by RectSelectionController.
        // We keep this for completeness but do nothing here.
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Critical for non-opaque NSBackingStoreBuffered windows used as full-screen overlays:
        // Always start by clearing the dirty area to fully transparent. Without this, pixels from
        // the previous frame (especially the white border and white size label) remain in the
        // backing store. The subsequent 50% black dim fill then blends over those remnants,
        // producing exactly the 1px white horizontal and vertical lines visible while dragging.
        NSColor.clear.set()
        dirtyRect.fill()

        let bounds = self.bounds

        if !isSelecting || localSelectionRect.isEmpty {
            // Full dim for this physical screen (either before drag starts, or selection is entirely on other monitors)
            dimColor.set()
            bounds.fill()
            return
        }

        var sel = localSelectionRect

        // Normalize in case upstream ever hands us a rect with negative width/height
        // (this has been the source of "only visible when dragging in one direction" bugs).
        if sel.width < 0 {
            sel.origin.x += sel.width
            sel.size.width = -sel.width
        }
        if sel.height < 0 {
            sel.origin.y += sel.height
            sel.size.height = -sel.height
        }

        // Snap the selection rect to pixel boundaries for the hole punch and border.
        // Fractional coordinates from live mouse drag + NSRectFill (even with kCGBlendModeCopy)
        // produce anti-aliased fringes exactly where the dim fill meets the transparent hole.
        // This is the source of the 1px white vertical and horizontal lines at the inner edges.
        var hole = NSRect.zero
        hole.origin.x = floor(sel.origin.x)
        hole.origin.y = floor(sel.origin.y)
        hole.size.width = ceil(NSMaxX(sel) - hole.origin.x)
        hole.size.height = ceil(NSMaxY(sel) - hole.origin.y)

        // Fill the entire screen with dim, then punch a clean transparent hole for the
        // selection area. The hole rect is integer-aligned so the dim/hole boundary has
        // no subpixel fringe.
        dimColor.set()
        bounds.fill()

        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.setShouldAntialias(false)
            NSColor.clear.set()
            hole.fill()
            ctx.restoreGState()
        }

        // White border drawn snapped for a crisp 1px line right at the dim/hole boundary.
        NSColor.white.set()
        let borderRect = NSRect(
            x: hole.origin.x + 0.5,
            y: hole.origin.y + 0.5,
            width: hole.width,
            height: hole.height
        )
        borderRect.frame(withWidth: 1.0)

        // Size label only on the screen the controller chose (avoids duplicates when selection spans monitors)
        if showsSizeLabel {
            let sizeString = "\(Int(round(sel.width))) × \(Int(round(sel.height)))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white
            ]
            let textSize = sizeString.size(withAttributes: attrs)
            let textPoint = NSPoint(
                x: NSMidX(sel) - textSize.width / 2.0,
                y: NSMaxY(sel) + 4
            )
            sizeString.draw(at: textPoint, withAttributes: attrs)
        }
    }
}

// MARK: - SelectionWindow

/// A borderless, high-level, transparent overlay window for one physical screen.
final class SelectionWindow: NSWindow {
    let selectionView: SelectionView

    init(contentRect: NSRect) {
        // The view must have a 0,0-based frame. The window's frame (set later) carries the
        // global origin of the union rect. Using the raw contentRect (which can have negative
        // .origin on setups with screens left/above the primary) would give the view a
        // non-zero origin, breaking all per-screen strip math and causing only the primary
        // to receive dimming / drawing.
        let viewFrame = NSRect(origin: .zero, size: contentRect.size)
        selectionView = SelectionView(frame: viewFrame)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // critical for clean full-desktop overlays, especially multi-monitor
        ignoresMouseEvents = true // overlay is transparent to normal responder chain; CGEventTap consumes events
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}



// MARK: - RectSelectionController

final class RectSelectionController {
    private var windows: [SelectionWindow] = []
    private var mouseEventTap: CFMachPort?
    private var mouseEventTapSource: CFRunLoopSource?
    private var escapeMonitor: Any?
    private var dragStartGlobal: NSPoint = .zero

    var globalSelectionRect: NSRect = .zero
    var isSelecting: Bool = false

    func startSelection() {
        endSelection()

        let screens = NSScreen.screens
        #if DEBUG
        print("[rect] startSelection — \(screens.count) physical screen(s) detected")
        #endif
        guard !screens.isEmpty else { return }

        // One properly-sized, max-level window per physical screen.
        // This is the most reliable way on macOS to get dimming + drawing on *every* monitor,
        // especially with negative global origins or mixed-scale setups.
        for screen in screens {
            let screenFrame = screen.frame
            let win = SelectionWindow(contentRect: screenFrame)
            win.setFrame(screenFrame, display: true)

            windows.append(win)
            win.orderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)

        // Make the first window (usually primary) key so local events (Esc) have a home.
        if let firstWin = windows.first {
            firstWin.makeKeyAndOrderFront(nil)
            firstWin.makeMain()
            firstWin.makeFirstResponder(firstWin.selectionView)
        }

        isSelecting = true
        globalSelectionRect = .zero

        updateAllViews()

        // CGEventTap for mouse events during selection. We consume the events (return NULL)
        // so the user's clicks do not activate or click through to applications behind the
        // dimmed overlay. This is much more reliable than the old NSEvent global monitor approach.
        let mouseMask = CGEventMask(
            1 << CGEventType.leftMouseDown.rawValue |
            1 << CGEventType.leftMouseDragged.rawValue |
            1 << CGEventType.leftMouseUp.rawValue
        )

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let controllerPtr = userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let controller = Unmanaged<RectSelectionController>.fromOpaque(controllerPtr).takeUnretainedValue()

            guard controller.isSelecting else {
                return Unmanaged.passUnretained(event)
            }

            let location = NSPointFromCGPoint(event.location)

            switch type {
            case .leftMouseDown:
                controller.handleMouseDown(at: location)
                return nil
            case .leftMouseDragged:
                controller.handleMouseDragged(at: location)
                return nil
            case .leftMouseUp:
                controller.handleMouseUp(at: location)
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        }

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mouseMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            mouseEventTap = tap
            mouseEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source = mouseEventTapSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            print("[rect] WARNING: failed to create mouse event tap (missing Input Monitoring permission?)")
        }

        // Local Esc monitor (works because one window is key).
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.endSelection()
                return nil
            }
            return event
        }
    }

    func endSelection() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }

        if let tap = mouseEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = mouseEventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                mouseEventTapSource = nil
            }
            mouseEventTap = nil
        }

        for win in windows {
            win.orderOut(nil)
        }
        windows.removeAll()

        isSelecting = false
        globalSelectionRect = .zero
    }

    private func updateAllViews() {
        #if DEBUG
        print("[mouse] updateAllViews called  globalRect=\(globalSelectionRect)  isSelecting=\(isSelecting)  windows=\(windows.count)")
        #endif

        // Decide which screen (if any) should display the size label — the one with the largest overlap.
        var labelView: SelectionView?
        var maxArea: CGFloat = 0

        for win in windows {
            let screenGlobal = win.frame
            let intersection = globalSelectionRect.intersection(screenGlobal)

            let v = win.selectionView
            v.isSelecting = isSelecting
            v.showsSizeLabel = false

            if intersection.isEmpty {
                v.localSelectionRect = .zero
                #if DEBUG
                print("[mouse]   screen \(win.frame) → no intersection (full dim)")
                #endif
            } else {
                var local = win.convertFromScreen(intersection)
                local = local.intersection(v.bounds)

                // Normalize defensively
                var normalized = local
                if normalized.width < 0 {
                    normalized.origin.x += normalized.width
                    normalized.size.width = -normalized.width
                }
                if normalized.height < 0 {
                    normalized.origin.y += normalized.height
                    normalized.size.height = -normalized.height
                }

                v.localSelectionRect = normalized

                #if DEBUG
                print("[mouse]   screen \(win.frame) → intersection global=\(intersection)  local=\(normalized)")
                #endif

                let area = intersection.width * intersection.height
                if area > maxArea {
                    maxArea = area
                    labelView = v
                }
            }
        }

        labelView?.showsSizeLabel = true

        // Redraw every window
        for win in windows {
            win.selectionView.needsDisplay = true
            win.displayIfNeeded()
            win.selectionView.displayIfNeeded()
        }
    }

    // MARK: - Mouse handling (driven by CGEventTap)

    private func handleMouseDown(at point: NSPoint) {
        print("[mouse] mouseDown at (\(point.x), \(point.y))  windows=\(windows.count)  isSelecting=\(isSelecting)")

        dragStartGlobal = point
        globalSelectionRect = NSRect(origin: point, size: .zero)
        isSelecting = true
        updateAllViews()
    }

    private func handleMouseDragged(at current: NSPoint) {
        guard isSelecting else { return }

        #if DEBUG
        print("[mouse] mouseDragged at (\(current.x), \(current.y))")
        #endif

        let x = min(dragStartGlobal.x, current.x)
        let y = min(dragStartGlobal.y, current.y)
        let w = abs(current.x - dragStartGlobal.x)
        let h = abs(current.y - dragStartGlobal.y)

        globalSelectionRect = NSRect(x: x, y: y, width: w, height: h)
        updateAllViews()
    }

    private func handleMouseUp(at ignoredLocation: NSPoint) {
        print("[mouse] mouseUp  current global rect=\(globalSelectionRect)")

        guard isSelecting else { return }

        let rect = globalSelectionRect
        endSelection() // disables the mouse event tap

        print("[mouse]   after endSelection, about to capture rect=\(rect)")

        if rect.isEmpty || rect.width < 1 || rect.height < 1 {
            print("[mouse]   rect too small, skipping capture")
            return
        }

        let x = Int(round(rect.origin.x))
        let y = Int(round(rect.origin.y))
        let w = Int(round(rect.width))
        let h = Int(round(rect.height))

        guard let pngData = Capture.rect(x: x, y: y, width: w, height: h) else {
            print("[mouse] Rect capture failed")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        let ok = pasteboard.writeObjects([item])

        if ok {
            #if DEBUG
            print("[mouse] Rect capture copied to clipboard (\(pngData.count) bytes)")
            #endif
        } else {
            print("[mouse] Rect capture: failed to write to pasteboard")
        }
    }

    // Legacy compatibility shims (kept so nothing external breaks if it calls them)
    func globalMouseDown(_ event: NSEvent) {
        handleMouseDown(at: NSEvent.mouseLocation)
    }
    func globalMouseDragged(_ event: NSEvent) {
        handleMouseDragged(at: NSEvent.mouseLocation)
    }
    func globalMouseUp(_ event: NSEvent) {
        handleMouseUp(at: NSEvent.mouseLocation)
    }

    func finishSelectionWithGlobalRect(_ globalRect: NSRect) {
        globalMouseUp(NSEvent())
    }
}
