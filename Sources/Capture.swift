import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// MARK: - Workarounds for SDK-unavailable capture APIs (same reason as original dlsym hacks)

@_silgen_name("CGWindowListCreateImage")
private func CGWindowListCreateImageWorkaround(
    _ screenBounds: CGRect,
    _ listOption: CGWindowListOption,
    _ windowID: CGWindowID,
    _ imageOption: CGWindowImageOption
) -> CGImage?

@_silgen_name("CGDisplayCreateImageForRect")
private func CGDisplayCreateImageForRectWorkaround(
    _ display: CGDirectDisplayID,
    _ rect: CGRect
) -> CGImage?

// MARK: - Public API

enum Capture {

    /// Shared implementation for capturing a desktop rect as CGImage.
    /// Tries per-display first for best multi-monitor results, then falls back to window list.
    private static func cgImage(for rect: CGRect) -> CGImage? {
        var cgImage: CGImage?

        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var displayCount: UInt32 = 0
        CGGetDisplaysWithRect(rect, 8, &displays, &displayCount)

        if displayCount > 0 {
            var bestDisplay: CGDirectDisplayID = displays[0]
            var bestArea: CGFloat = 0
            var bestIntersection = CGRect.zero

            for i in 0..<Int(displayCount) {
                let dbounds = CGDisplayBounds(displays[i])
                let inter = rect.intersection(dbounds)
                let area = inter.width * inter.height
                if area > bestArea {
                    bestArea = area
                    bestDisplay = displays[i]
                    bestIntersection = inter
                }
            }

            if bestArea > 0 {
                cgImage = CGDisplayCreateImageForRectWorkaround(bestDisplay, bestIntersection)
            }
        }

        if cgImage == nil {
            cgImage = CGWindowListCreateImageWorkaround(
                rect,
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID,
                []
            )
        }

        return cgImage
    }


    /// Captures the full desktop (all on-screen content except desktop elements) as PNG data.
    static func fullscreen() -> Data? {
        #if DEBUG
        print("[capture] fullscreen called")
        #endif

        guard let cgImage = CGWindowListCreateImageWorkaround(
            CGRect.infinite,
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID,
            []
        ) else {
            #if DEBUG
            print("[capture] CGWindowListCreateImageWorkaround returned nil")
            #endif
            return nil
        }

        #if DEBUG
        print("[capture] Got CGImage \(cgImage.width)x\(cgImage.height)")
        #endif

        return pngData(from: cgImage)
    }

    /// Captures a specific global rect. Uses per-display capture when possible for reliability
    /// across multiple monitors (including secondary displays and negative-origin setups).
    static func rect(x: Int, y: Int, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }

        #if DEBUG
        print("[capture] rect called (\(x),\(y) \(width)x\(height))")
        #endif

        let captureRect = CGRect(x: x, y: y, width: width, height: height)
        guard let image = cgImage(for: captureRect) else {
            #if DEBUG
            print("[capture] rect capture returned nil")
            #endif
            return nil
        }

        #if DEBUG
        print("[capture] Got CGImage for rect \(image.width)x\(image.height)")
        #endif

        return pngData(from: image)
    }

    /// Captures the given global rect of the desktop as a raw CGImage (no PNG encoding).
    /// Used to freeze the desktop content inside the selection rectangle during drag.
    static func image(for rect: CGRect) -> CGImage? {
        return cgImage(for: rect)
    }

    /// Captures the full desktop as a raw CGImage (no PNG encoding).
    static func fullscreenImage() -> CGImage? {
        return CGWindowListCreateImageWorkaround(
            CGRect.infinite,
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID,
            []
        )
    }

    // MARK: - Private helpers

    private static func pngData(from cgImage: CGImage) -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bufferSize = width * height * bytesPerPixel

        // Allocate our own buffer so we can zero it after encoding (security).
        guard let pixelBuffer = malloc(bufferSize) else {
            return nil
        }
        defer {
            // Zero the raw screenshot bytes before we release them.
            memset(pixelBuffer, 0, bufferSize)
            free(pixelBuffer)
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let context = CGContext(
            data: pixelBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Create a CGImage from the context's buffer so ImageIO can encode it.
        guard let outputImage = context.makeImage() else {
            return nil
        }

        // Encode as PNG using ImageIO (replacement for stb_image_write).
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, outputImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        #if DEBUG
        print("[capture] PNG encoded successfully (\(mutableData.length) bytes)")
        #endif

        return mutableData as Data
    }
}
