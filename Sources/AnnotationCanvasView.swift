import AppKit
import CoreGraphics

/// A flipped (y-down) canvas that displays the base screenshot, draws the
/// annotation overlay, handles tool input, and owns snapshot-based undo.
final class AnnotationCanvasView: NSView {

    let baseImage: CGImage
    private(set) var annotations: [Annotation] = []
    private(set) var cropRect: CGRect?          // image pixel coords

    var currentTool: Annotation.Tool = .rectangle
    var currentColor: RGBAColor = .red
    var currentThickness: CGFloat = 4

    /// When true, drags define a crop rectangle instead of an annotation.
    var cropMode: Bool = false

    private var draft: Annotation?              // in-progress annotation while dragging
    private var draftCrop: CGRect?              // in-progress crop rect while dragging

    private let canvasUndoManager = UndoManager()

    init(image: CGImage) {
        self.baseImage = image
        super.init(frame: NSRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { canvasUndoManager }

    private var imageSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    // MARK: - Mutation with snapshot undo

    /// Applies `mutate`, registering the inverse (restore previous overlay) so
    /// that undo/redo work for adds, moves, and crops.
    private func applyChange(_ mutate: () -> Void) {
        let prevAnnotations = annotations
        let prevCrop = cropRect
        mutate()
        canvasUndoManager.registerUndo(withTarget: self) { target in
            target.applyChange {
                target.annotations = prevAnnotations
                target.cropRect = prevCrop
            }
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()

        let frame = AnnotationRenderer.imageFrame(imageSize: imageSize, in: bounds.size)
        guard frame.width > 0 else { return }

        var shown = annotations
        if let draft = draft { shown.append(draft) }

        ctx.saveGState()
        ctx.translateBy(x: frame.origin.x, y: frame.origin.y)
        let s = frame.width / CGFloat(baseImage.width)
        ctx.scaleBy(x: s, y: s)
        AnnotationRenderer.drawScene(base: baseImage, annotations: shown, in: ctx)
        ctx.restoreGState()

        // Crop preview: dim everything outside the (draft or committed) crop rect.
        if let crop = draftCrop ?? cropRect {
            let tl = AnnotationRenderer.imageToView(crop.origin,
                        imageSize: imageSize, viewSize: bounds.size)
            let br = AnnotationRenderer.imageToView(
                        CGPoint(x: crop.maxX, y: crop.maxY),
                        imageSize: imageSize, viewSize: bounds.size)
            let viewCrop = NSRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
            NSColor(calibratedWhite: 0, alpha: 0.45).setFill()
            for r in regionsOutside(viewCrop, within: frame) { r.fill() }
            NSColor.white.setStroke()
            NSBezierPath(rect: viewCrop).stroke()
        }
    }

    private func regionsOutside(_ inner: NSRect, within outer: NSRect) -> [NSRect] {
        [
            NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: inner.minY - outer.minY),
            NSRect(x: outer.minX, y: inner.maxY, width: outer.width, height: outer.maxY - inner.maxY),
            NSRect(x: outer.minX, y: inner.minY, width: inner.minX - outer.minX, height: inner.height),
            NSRect(x: inner.maxX, y: inner.minY, width: outer.maxX - inner.maxX, height: inner.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    // MARK: - Mouse handling

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return AnnotationRenderer.viewToImage(local, imageSize: imageSize, viewSize: bounds.size)
    }

    override func mouseDown(with event: NSEvent) {
        let p = imagePoint(event)
        if cropMode {
            draftCrop = CGRect(origin: p, size: .zero)
        } else if isStrokeTool(currentTool) {
            draft = Annotation(tool: currentTool, points: [p],
                               color: currentColor, thickness: currentThickness)
        } else {
            draft = Annotation(tool: currentTool, points: [p, p],
                               color: currentColor, thickness: currentThickness)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        if cropMode, let start = draftCrop?.origin {
            draftCrop = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                               width: abs(p.x - start.x), height: abs(p.y - start.y))
        } else if var d = draft {
            if isStrokeTool(d.tool) { d.points.append(p) }
            else { d.points = [d.points[0], p] }
            draft = d
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if cropMode {
            let r = draftCrop
            draftCrop = nil
            if let r = r, r.width >= 2, r.height >= 2 { setCrop(r) }
            needsDisplay = true
            return
        }
        guard let d = draft else { return }
        draft = nil
        if !isStrokeTool(d.tool), d.boundingRect.width < 2, d.boundingRect.height < 2 {
            needsDisplay = true
            return
        }
        applyChange { annotations.append(d) }
    }

    private func isStrokeTool(_ tool: Annotation.Tool) -> Bool {
        tool == .freehand || tool == .highlighter
    }

    // MARK: - Public actions (called by the controller)

    func setCrop(_ rect: CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let r = rect.integral.intersection(bounds)
        guard r.width >= 2, r.height >= 2 else { return }
        applyChange { cropRect = r }
    }

    func clearCrop() { applyChange { cropRect = nil } }

    func undo() { if canvasUndoManager.canUndo { canvasUndoManager.undo() } }
    func redo() { if canvasUndoManager.canRedo { canvasUndoManager.redo() } }

    /// Flattens the current scene (respecting crop) to a native-resolution PNG.
    func flattenedPNG() -> Data? {
        guard let image = AnnotationRenderer.render(
            base: baseImage, annotations: annotations, crop: cropRect) else { return nil }
        return AnnotationRenderer.pngData(from: image)
    }
}
