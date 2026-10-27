import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Pixels read back from a render target: 8-bit BGRA (premultiplied, as
/// rendered), top row first. Used for screenshots, exports and pixel tests.
public struct RenderedImage: @unchecked Sendable {
    /// Size in pixels.
    public let width: Int
    public let height: Int
    /// Bytes per row of `bytes` (at least `4 × width`).
    public let bytesPerRow: Int
    /// BGRA bytes, `bytesPerRow × height`.
    public let bytes: [UInt8]

    public init(width: Int, height: Int, bytesPerRow: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bytes = bytes
    }

    /// The pixel at column `x`, row `y` (top-left origin) as RGBA.
    public func pixel(x: Int, y: Int) -> SIMD4<UInt8> {
        let o = y * bytesPerRow + x * 4
        return SIMD4(bytes[o + 2], bytes[o + 1], bytes[o], bytes[o + 3])
    }

    /// The pixel as RGBA in `[0, 1]`.
    public func color(x: Int, y: Int) -> SIMD4<Double> {
        SIMD4<Double>(pixel(x: x, y: y)) / 255
    }

    /// A Core Graphics image of the pixels (sRGB).
    public func cgImage() -> CGImage? {
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Writes a PNG.
    public func writePNG(to url: URL) throws {
        guard let image = cgImage() else { throw RenderError.imageExport("could not make a CGImage") }
        try ImageExport.writePNG(image, to: url)
    }

    /// Reads a `bgra8Unorm` texture back: encodes a blit into `commandBuffer`,
    /// commits it and waits.
    static func readback(texture: any MTLTexture, commandBuffer: any MTLCommandBuffer,
                         context: RenderContext) throws -> RenderedImage {
        let w = texture.width, h = texture.height
        let bytesPerRow = (w * 4 + 255) / 256 * 256
        guard let buffer = context.device.makeBuffer(length: bytesPerRow * h, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RenderError.allocationFailed("readback buffer")
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * h)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw RenderError.commandBufferFailed("\(error)")
        }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: buffer.contents(), count: bytesPerRow * h))
        return RenderedImage(width: w, height: h, bytesPerRow: bytesPerRow, bytes: bytes)
    }

    /// A private render target for offscreen rendering.
    static func makeTarget(context: RenderContext, size: SIMD2<Int>,
                           format: MTLPixelFormat = .bgra8Unorm) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, size.x),
                                                         height: max(1, size.y), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = context.device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("offscreen target \(size)")
        }
        t.label = "offscreen target"
        return t
    }
}

/// Image file output.
public enum ImageExport {
    /// Writes a CGImage as PNG.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.imageExport("cannot create \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw RenderError.imageExport("cannot write \(url.path)")
        }
    }

    /// PNG data of a CGImage.
    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.imageExport("cannot create a PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.imageExport("cannot encode PNG") }
        return data as Data
    }
}
