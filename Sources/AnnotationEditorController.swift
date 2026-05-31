import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Owns one annotation editor window: a top toolbar (layout B) plus the canvas.
/// Manages the app's activation policy so the menubar agent can show a real
/// window while an editor is open, then returns to `.accessory`.
final class AnnotationEditorController: NSObject, NSWindowDelegate {

    /// Number of editor windows currently open (drives activation policy).
    private static var openCount = 0

    private let window: NSWindow
    private let canvas: AnnotationCanvasView
    private let sourceURL: URL?
    private var toolButtons: [Annotation.Tool: NSButton] = [:]
    private var cropButton: NSButton?

    /// Called when the window closes so the coordinator can release this controller.
    var onClose: ((AnnotationEditorController) -> Void)?

    /// Loads `url` as a CGImage and builds the editor. Returns nil if unreadable.
    init?(imageURL url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.sourceURL = url
        self.canvas = AnnotationCanvasView(image: image)
        self.window = AnnotationEditorController.makeWindow(imageSize:
            CGSize(width: image.width, height: image.height))
        super.init()
        buildUI()
    }

    /// Builds an editor directly from a CGImage (used for capture-then-annotate).
    init(image: CGImage, sourceURL: URL?) {
        self.sourceURL = sourceURL
        self.canvas = AnnotationCanvasView(image: image)
        self.window = AnnotationEditorController.makeWindow(imageSize:
            CGSize(width: image.width, height: image.height))
        super.init()
        buildUI()
    }

    private static func makeWindow(imageSize: CGSize) -> NSWindow {
        // Fit the initial content to the image but cap it to a sane size.
        let maxW: CGFloat = 1100, maxH: CGFloat = 800
        let scale = min(1, min(maxW / imageSize.width, maxH / imageSize.height))
        let canvasW = max(400, imageSize.width * scale)
        let canvasH = max(300, imageSize.height * scale)
        let toolbarH: CGFloat = 44
        let actionsH: CGFloat = 48
        let content = NSRect(x: 0, y: 0, width: canvasW, height: canvasH + toolbarH + actionsH)
        let w = NSWindow(contentRect: content,
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Annotate"
        w.isReleasedWhenClosed = false
        return w
    }

    // MARK: - UI construction

    private func buildUI() {
        window.delegate = self
        guard let root = window.contentView else { return }
        root.wantsLayer = true

        let toolbarH: CGFloat = 44
        let actionsH: CGFloat = 48

        // --- Top toolbar (tools | color swatches | thickness | undo/redo) ---
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        addToolButton(to: toolbar, tool: .rectangle, title: "▭")
        addToolButton(to: toolbar, tool: .ellipse,   title: "◯")
        addToolButton(to: toolbar, tool: .freehand,  title: "✎")
        addToolButton(to: toolbar, tool: .highlighter, title: "🖍")

        let cropBtn = NSButton(title: "Crop", target: self, action: #selector(selectCrop))
        cropBtn.setButtonType(.toggle)
        cropButton = cropBtn
        toolbar.addArrangedSubview(cropBtn)

        let fillBtn = NSButton(title: "Fill", target: self, action: #selector(toggleFill(_:)))
        fillBtn.setButtonType(.pushOnPushOff)
        fillBtn.state = canvas.fillShapes ? .on : .off
        toolbar.addArrangedSubview(fillBtn)

        toolbar.addArrangedSubview(makeSeparator())

        for color in RGBAColor.palette {
            toolbar.addArrangedSubview(makeColorSwatch(color))
        }

        // Custom color picker (opens the macOS color panel).
        let colorWell = NSColorWell()
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged(_:))
        colorWell.color = NSColor(srgbRed: canvas.currentColor.r, green: canvas.currentColor.g,
                                  blue: canvas.currentColor.b, alpha: canvas.currentColor.a)
        colorWell.widthAnchor.constraint(equalToConstant: 28).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        toolbar.addArrangedSubview(colorWell)

        let slider = NSSlider(value: Double(canvas.currentThickness), minValue: 1, maxValue: 24,
                              target: self, action: #selector(thicknessChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        toolbar.addArrangedSubview(slider)

        toolbar.addArrangedSubview(makeSeparator())
        toolbar.addArrangedSubview(NSButton(title: "↶", target: self, action: #selector(undo)))
        toolbar.addArrangedSubview(NSButton(title: "↷", target: self, action: #selector(redo)))

        // --- Bottom action bar (Reset crop | Save copy) ---
        // Edits auto-copy to the clipboard, so there is no explicit Copy button.
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.alignment = .centerY
        actions.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.addArrangedSubview(NSView()) // spacer pushes buttons right
        let clearCropBtn = NSButton(title: "Reset crop", target: self, action: #selector(resetCrop))
        actions.addArrangedSubview(clearCropBtn)
        let saveBtn = NSButton(title: "Save copy", target: self, action: #selector(saveCopy))
        actions.addArrangedSubview(saveBtn)

        // Auto-copy the flattened image to the clipboard after every edit.
        canvas.onChange = { [weak self] in self?.copyToClipboard() }

        canvas.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(canvas)
        root.addSubview(actions)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarH),

            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: actions.topAnchor),

            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            actions.heightAnchor.constraint(equalToConstant: actionsH),
        ])

        selectTool(.freehand)
    }

    private func makeSeparator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 24).isActive = true
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func addToolButton(to stack: NSStackView, tool: Annotation.Tool, title: String) {
        let b = NSButton(title: title, target: self, action: #selector(toolButtonClicked(_:)))
        b.setButtonType(.pushOnPushOff)
        b.tag = toolTag(tool)
        toolButtons[tool] = b
        stack.addArrangedSubview(b)
    }

    private func toolTag(_ tool: Annotation.Tool) -> Int {
        switch tool {
        case .rectangle: return 0
        case .ellipse: return 1
        case .freehand: return 2
        case .highlighter: return 3
        }
    }

    private func toolForTag(_ tag: Int) -> Annotation.Tool {
        switch tag {
        case 1: return .ellipse
        case 2: return .freehand
        case 3: return .highlighter
        default: return .rectangle
        }
    }

    private func makeColorSwatch(_ color: RGBAColor) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(colorClicked(_:)))
        b.wantsLayer = true
        b.isBordered = false
        b.layer?.backgroundColor = color.cgColor
        b.layer?.cornerRadius = 9
        b.widthAnchor.constraint(equalToConstant: 18).isActive = true
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        b.identifier = NSUserInterfaceItemIdentifier(
            "\(color.r),\(color.g),\(color.b),\(color.a)")
        return b
    }

    // MARK: - Actions

    @objc private func toolButtonClicked(_ sender: NSButton) {
        selectTool(toolForTag(sender.tag))
    }

    private func selectTool(_ tool: Annotation.Tool) {
        canvas.cropMode = false
        canvas.currentTool = tool
        cropButton?.state = .off
        for (t, b) in toolButtons { b.state = (t == tool) ? .on : .off }
    }

    @objc private func selectCrop() {
        canvas.cropMode = true
        cropButton?.state = .on
        for (_, b) in toolButtons { b.state = .off }
    }

    @objc private func colorClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return }
        canvas.currentColor = RGBAColor(r: parts[0], g: parts[1], b: parts[2], a: parts[3])
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        canvas.currentColor = RGBAColor(r: c.redComponent, g: c.greenComponent,
                                        b: c.blueComponent, a: c.alphaComponent)
    }

    @objc private func toggleFill(_ sender: NSButton) {
        canvas.fillShapes = (sender.state == .on)
    }

    @objc private func thicknessChanged(_ sender: NSSlider) {
        canvas.currentThickness = CGFloat(sender.doubleValue)
    }

    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }
    @objc private func resetCrop() { canvas.clearCrop() }

    @objc private func copyToClipboard() {
        guard let png = canvas.flattenedPNG() else { warn("Could not render the image."); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pb.writeObjects([item])
    }

    @objc private func saveCopy() {
        guard let png = canvas.flattenedPNG() else { warn("Could not render the image."); return }
        let original = sourceURL
            ?? CaptureStore.directoryURL?.appendingPathComponent(
                CaptureStore.timestampedFilename(date: Date()))
        guard let original = original,
              let saved = CaptureStore.saveAnnotatedCopy(of: original, pngData: png) else {
            warn("Could not save the annotated copy.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([saved])
    }

    private func warn(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: - Presentation + lifecycle

    func showWindow() {
        AnnotationEditorController.openCount += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        AnnotationEditorController.openCount = max(0, AnnotationEditorController.openCount - 1)
        if AnnotationEditorController.openCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
        onClose?(self)
    }
}
