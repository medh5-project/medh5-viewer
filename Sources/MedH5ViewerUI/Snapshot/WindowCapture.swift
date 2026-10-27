import AppKit

/// Captures a window as the user sees it, without screen recording: the
/// AppKit/SwiftUI chrome drawn with `cacheDisplay`, each Metal viewport's own
/// offscreen render composited at its frame, and the viewport's text
/// overlay drawn again on top.
@MainActor
enum WindowCapture {
    struct Viewport {
        var container: ViewportContainerView
        /// The viewport rendered at the capture scale.
        var image: CGImage?
    }

    struct Result {
        var window: CGImage
        /// Each viewport cropped from the composite (with its overlay).
        var viewports: [CGImage]
    }

    static func capture(window: NSWindow, scale: CGFloat, viewports: [Viewport]) throws -> Result {
        guard let frameView = window.contentView?.superview ?? window.contentView else {
            throw SnapshotError("the window has no view")
        }
        let bounds = frameView.bounds
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw SnapshotError("could not make a \(width)×\(height) bitmap") }

        // The window background, then the chrome.
        context.setFillColor((window.backgroundColor ?? .windowBackgroundColor).usingColorSpace(.sRGB)?.cgColor
                             ?? CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let chrome = render(frameView, rect: bounds, scale: scale) {
            context.draw(chrome, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        // The viewports: Metal image, then the overlay.
        var rects: [CGRect] = []
        for v in viewports {
            let r = v.container.convert(v.container.bounds, to: frameView)
            let flippedY = frameView.isFlipped ? bounds.height - r.maxY : r.minY
            let pixelRect = CGRect(x: r.minX * scale, y: flippedY * scale, width: r.width * scale, height: r.height * scale)
            rects.append(pixelRect)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(pixelRect)
            if let image = v.image {
                context.draw(image, in: pixelRect)
            }
            if let overlay = render(v.container.overlay, rect: v.container.overlay.bounds, scale: scale) {
                context.draw(overlay, in: pixelRect)
            }
        }
        guard let image = context.makeImage() else { throw SnapshotError("could not make the window image") }
        let crops = rects.compactMap { r -> CGImage? in
            let top = CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height).integral
            return image.cropping(to: top)
        }
        return Result(window: image, viewports: crops)
    }

    /// One viewport as it looks: its Metal render with its text overlay on
    /// top (screenshots).
    static func viewportImage(_ container: ViewportContainerView, render: CGImage, scale: CGFloat) -> CGImage? {
        let width = render.width, height = render.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(render, in: rect)
        if let overlay = Self.render(container.overlay, rect: container.overlay.bounds, scale: scale) {
            context.draw(overlay, in: rect)
        }
        return context.makeImage()
    }

    /// A view drawn into a bitmap at `scale`, transparent where it draws
    /// nothing.
    static func render(_ view: NSView, rect: CGRect, scale: CGFloat) -> CGImage? {
        let w = Int((rect.width * scale).rounded()), h = Int((rect.height * scale).rounded())
        guard w > 0, h > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        view.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }
}
