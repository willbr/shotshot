import CoreGraphics
import Foundation

/// An sRGB color stored as components, with a `CGColor` bridge. AppKit-free.
struct RGBAColor: Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static let red    = RGBAColor(r: 0.89, g: 0.23, b: 0.23, a: 1)
    static let yellow = RGBAColor(r: 0.96, g: 0.77, b: 0.09, a: 1)
    static let green  = RGBAColor(r: 0.23, g: 0.81, b: 0.42, a: 1)
    static let white  = RGBAColor(r: 1,    g: 1,    b: 1,    a: 1)

    /// The swatches shown in the toolbar, in order.
    static let palette: [RGBAColor] = [.red, .yellow, .green, .white]
}

/// A single annotation drawn over the base image. Geometry is in image pixel
/// coordinates (origin top-left, y increasing downward).
struct Annotation: Equatable {
    enum Tool: Equatable {
        case rectangle
        case ellipse
        case freehand
        case highlighter
    }

    var tool: Tool
    /// rectangle/ellipse: two corner points (any order).
    /// freehand/highlighter: the polyline path.
    var points: [CGPoint]
    var color: RGBAColor
    var thickness: CGFloat

    /// Normalized bounding box of `points`.
    var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
