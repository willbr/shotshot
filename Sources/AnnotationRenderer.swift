import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Coordinate mapping and flattening for annotations. Pure CoreGraphics — no
/// AppKit. The canvas view uses a flipped (y-down) coordinate space so that
/// view points and image pixels share an origin convention (top-left, y-down).
enum AnnotationRenderer {

    // MARK: - Coordinate mapping

    /// The rect (in flipped view coords) where the image is drawn, aspect-fit
    /// and centered.
    static func imageFrame(imageSize: CGSize, in viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / imageSize.width,
                        viewSize.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (viewSize.width - w) / 2,
                      y: (viewSize.height - h) / 2, width: w, height: h)
    }

    /// Converts a flipped (y-down) view point to image pixel coords.
    static func viewToImage(_ p: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let frame = imageFrame(imageSize: imageSize, in: viewSize)
        guard frame.width > 0 else { return .zero }
        let scale = imageSize.width / frame.width
        return CGPoint(x: (p.x - frame.origin.x) * scale,
                       y: (p.y - frame.origin.y) * scale)
    }

    /// Converts an image pixel point to flipped (y-down) view coords.
    static func imageToView(_ p: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        let frame = imageFrame(imageSize: imageSize, in: viewSize)
        guard imageSize.width > 0 else { return .zero }
        let scale = frame.width / imageSize.width
        return CGPoint(x: frame.origin.x + p.x * scale,
                       y: frame.origin.y + p.y * scale)
    }

    // MARK: - Scene drawing

    /// Draws `base` upright and then `annotations`, all in the current y-down
    /// coordinate space (caller sets up the transform). Shared by the canvas
    /// view (on-screen) and `render` (export) so they stay WYSIWYG.
    static func drawScene(base: CGImage, annotations: [Annotation], in ctx: CGContext) {
        let w = CGFloat(base.width), h = CGFloat(base.height)
        // The surrounding space is y-down; flip again so the image draws upright.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()

        for a in annotations { drawAnnotation(a, in: ctx) }
    }

    private static func drawAnnotation(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        switch a.tool {
        case .rectangle:
            if a.filled {
                ctx.setFillColor(a.color.cgColor)
                ctx.fill(a.boundingRect)
            } else {
                ctx.setLineWidth(a.thickness)
                ctx.setStrokeColor(a.color.cgColor)
                ctx.stroke(a.boundingRect)
            }
        case .ellipse:
            if a.filled {
                ctx.setFillColor(a.color.cgColor)
                ctx.fillEllipse(in: a.boundingRect)
            } else {
                ctx.setLineWidth(a.thickness)
                ctx.setStrokeColor(a.color.cgColor)
                ctx.strokeEllipse(in: a.boundingRect)
            }
        case .freehand:
            ctx.setLineWidth(a.thickness)
            ctx.setStrokeColor(a.color.cgColor)
            strokePolyline(a.points, in: ctx)
        case .highlighter:
            // Translucent, thicker stroke for a marker effect.
            var c = a.color; c.a = 0.35
            ctx.setLineWidth(a.thickness * 2.5)
            ctx.setStrokeColor(c.cgColor)
            strokePolyline(a.points, in: ctx)
        }
        ctx.restoreGState()
    }

    private static func strokePolyline(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.move(to: first)
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    // MARK: - Flatten / export

    /// Renders `base` with `annotations` on top, optionally cropped to `crop`
    /// (image pixel coords). Returns a native-resolution CGImage.
    static func render(base: CGImage, annotations: [Annotation], crop: CGRect?) -> CGImage? {
        let w = base.width, h = base.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Establish a y-down (top-left origin) user space, then draw the scene.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawScene(base: base, annotations: annotations, in: ctx)

        guard let fullImage = ctx.makeImage() else { return nil }
        guard let crop = crop else { return fullImage }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let r = crop.integral.intersection(bounds)
        if r.isEmpty { return fullImage }
        return fullImage.cropping(to: r) ?? fullImage
    }

    /// Encodes a CGImage as PNG data.
    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
