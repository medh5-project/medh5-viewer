import Foundation
import Metal
import simd
import MedH5Core

/// One spatial volume on the GPU: a private 3-D texture of width `n2`,
/// height `n1` and depth `n0` (the padded shape `(n0, n1, n2)`), with the
/// grid that places it in world space.
///
/// Values stay raw, as stored: the texel a shader samples maps back to the
/// stored value by `raw = texel × texelScale + texelOffset` (normalised
/// integer formats), and the shaders then apply the image's rescale and
/// window. Formats:
///
/// | stored | content | texture |
/// |---|---|---|
/// | `uint8`, `bool` | image | `r8Unorm` |
/// | `int8` | image | `r8Snorm` |
/// | `uint16` | image | `r16Unorm` |
/// | `int16` | image | `r16Snorm` |
/// | `float16` | image | `r16Float` |
/// | `float32` and wider types | image | `r32Float` (interpolated manually when the GPU cannot filter it) |
/// | `uint8` / `uint16` / `uint32` | labels | `r8Uint` / `r16Uint` / `r32Uint` (read with nearest) |
/// | 3 or 4 `uint8` channels | RGB(A) | `rgba8Unorm` |
/// | 2 or 3 float channels | vectors (displacement) | `rgba32Float` or `rgba16Float` |
///
/// Signed normalised formats hold the type's minimum (−128, −32768) as one
/// more than it (−127, −32767); nothing else is lost.
///
/// Uploads are asynchronous: types whose bytes the texture holds as they
/// are blit straight from the volume's page-aligned storage (no copy);
/// others are converted in bounded chunks through staging buffers while the
/// GPU copies the previous chunk. Everything goes through the context's one
/// queue, so a render submitted later sees the finished texture.
public final class VolumeTexture: @unchecked Sendable {
    /// What the texels hold.
    public enum Content: Sendable, Hashable {
        /// One scalar per voxel (intensity, probability, mask).
        case scalar
        /// Integer class ids (segmentation layers).
        case label
        /// Colour (RGB or RGBA, 8 bits per channel).
        case rgb
        /// A vector per voxel (a displacement field, world components x, y, z).
        case vector
    }

    /// The context the texture belongs to.
    public let context: RenderContext
    /// The 3-D texture.
    public let texture: any MTLTexture
    /// What the texels hold.
    public let content: Content
    /// The grid (spatial axes only).
    public let geometry: GridGeometry
    /// The padded shape `(n0, n1, n2)`: the texture's depth, height, width.
    public let dimensions: SIMD3<Int>
    /// The stored type of the data uploaded.
    public let sourceType: ScalarType
    /// `raw = texel × texelScale + texelOffset`.
    public let texelScale: Double
    /// See ``texelScale``.
    public let texelOffset: Double
    /// Whether the hardware can filter the texture linearly.
    public let isFilterable: Bool

    private let format: TextureFormat
    private let lock = NSLock()
    private var lastUpload: (any MTLCommandBuffer)?
    private var contentVersion = 0
    private var changeLog: [(version: Int, region: VoxelBox)] = []
    private static let changeLogLimit = 256
    // Zero-copy link to the source storage, kept for labels so an edited
    // region is blit straight from the editor's memory.
    private var linkedData: VolumeData?
    private var linkedBuffer: (any MTLBuffer)?
    private var linkedOffset = 0

    /// GPU memory the texture occupies, in bytes.
    public var allocatedSize: Int { texture.allocatedSize }

    /// Largest extent of a 3-D texture on Apple GPUs.
    public static let maximumExtent = 2048

    // MARK: Creation

    /// Uploads one frame of an image: a scalar image (intensity, probability,
    /// mask), an RGB image (value type `rgb`, a channel axis of 3 or 4
    /// `uint8`) or a displacement field (value type `displacement`).
    ///
    /// - Parameter leading: the index along the leading axes other than the
    ///   channel axis (time, other); zeros when `nil`.
    public convenience init(context: RenderContext, image: ImageVolume, frame leading: [Int]? = nil) throws {
        let g = image.geometry
        let isMultiChannel = image.isRGB || image.valueType == "displacement"
        if isMultiChannel {
            guard let channelAxis = g.channelAxis else {
                throw RenderError.unsupportedVolume("\(image.valueType) image \(image.id) has no channel axis")
            }
            let leadingAxes = g.leadingShape.indices.filter { $0 != channelAxis }
            let index = leading ?? Array(repeating: 0, count: leadingAxes.count)
            guard index.count == leadingAxes.count else {
                throw RenderError.invalidArgument("frame \(index) does not match leading axes \(g.leadingShape)")
            }
            let channels = g.shape[channelAxis]
            var planes: [VolumeData] = []
            for c in 0..<channels {
                var full = [Int](repeating: 0, count: g.leadingShape.count)
                full[channelAxis] = c
                for (k, axis) in leadingAxes.enumerated() { full[axis] = index[k] }
                planes.append(image.spatialFrame(full))
            }
            if image.isRGB {
                try self.init(context: context, rgbPlanes: planes, geometry: g)
            } else {
                try self.init(context: context, vectorPlanes: planes, geometry: g)
            }
        } else {
            let index = leading ?? Array(repeating: 0, count: g.leadingShape.count)
            guard index.count == g.leadingShape.count else {
                throw RenderError.invalidArgument("frame \(index) does not match leading axes \(g.leadingShape)")
            }
            try self.init(context: context, scalars: image.spatialFrame(index), geometry: g)
        }
    }

    /// Uploads a scalar volume (one spatial frame: `data.count` must equal
    /// the grid's spatial voxel count).
    public convenience init(context: RenderContext, scalars data: VolumeData, geometry: GridGeometry) throws {
        let format = TextureFormat.scalar(data.scalarType, float32Filterable: context.supportsFloat32Filtering)
        try self.init(context: context, content: .scalar, format: format, planes: [data], geometry: geometry,
                      keepLinked: false)
    }

    /// Uploads a label (segmentation layer) volume: integer class ids, read
    /// with nearest sampling. The texture stays linked to `data` (no copy),
    /// so ``update(region:from:)`` with the same object blits edited voxels
    /// straight from it.
    public convenience init(context: RenderContext, labels data: VolumeData, geometry: GridGeometry) throws {
        let format = TextureFormat.label(data.scalarType)
        try self.init(context: context, content: .label, format: format, planes: [data], geometry: geometry,
                      keepLinked: true)
    }

    /// Uploads an RGB(A) image from 3 or 4 channel planes of `uint8`.
    public convenience init(context: RenderContext, rgbPlanes planes: [VolumeData], geometry: GridGeometry) throws {
        guard planes.count == 3 || planes.count == 4 else {
            throw RenderError.unsupportedVolume("an RGB image needs 3 or 4 channels, not \(planes.count)")
        }
        guard planes.allSatisfy({ $0.scalarType == .uint8 }) else {
            throw RenderError.unsupportedVolume("RGB channels must be uint8")
        }
        try self.init(context: context, content: .rgb, format: TextureFormat.rgba8, planes: planes,
                      geometry: geometry, keepLinked: false)
    }

    /// Uploads a vector field (a displacement field: 2 or 3 channel planes of
    /// world components x, y, z in the grid's units).
    public convenience init(context: RenderContext, vectorPlanes planes: [VolumeData], geometry: GridGeometry) throws {
        guard planes.count == 2 || planes.count == 3 else {
            throw RenderError.unsupportedVolume("a vector field needs 2 or 3 channels, not \(planes.count)")
        }
        let format = context.supportsFloat32Filtering ? TextureFormat.vector32 : TextureFormat.vector16
        try self.init(context: context, content: .vector, format: format, planes: planes, geometry: geometry,
                      keepLinked: false)
    }

    private init(context: RenderContext, content: Content, format: TextureFormat, planes: [VolumeData],
                 geometry: GridGeometry, keepLinked: Bool) throws {
        let spatial = geometry.spatialOnly
        let dims = spatial.paddedShape
        guard dims.x > 0, dims.y > 0, dims.z > 0 else {
            throw RenderError.unsupportedVolume("empty grid \(spatial.spatialShape)")
        }
        guard dims.max() <= VolumeTexture.maximumExtent else {
            throw RenderError.unsupportedVolume(
                "grid \(spatial.spatialShape) exceeds the 3-D texture limit of \(VolumeTexture.maximumExtent)")
        }
        let voxels = dims.x * dims.y * dims.z
        for p in planes where p.count != voxels {
            throw RenderError.unsupportedVolume("volume of \(p.count) elements does not fill grid \(spatial.spatialShape)")
        }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = format.pixelFormat
        d.width = dims.z
        d.height = dims.y
        d.depth = dims.x
        d.storageMode = .private
        d.usage = .shaderRead
        d.hazardTrackingMode = .tracked
        guard let texture = context.device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("3-D texture \(dims) \(format.pixelFormat)")
        }
        texture.label = "\(content) \(geometry.id)"
        self.context = context
        self.texture = texture
        self.content = content
        self.geometry = spatial
        self.dimensions = dims
        self.sourceType = planes[0].scalarType
        self.texelScale = format.texelScale
        self.texelOffset = format.texelOffset
        self.isFilterable = format.filterable
        self.format = format
        try upload(planes: planes, keepLinked: keepLinked)
    }

    // MARK: Uploading

    /// Whether every upload submitted so far has finished.
    public var isUploaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let cb = lastUpload else { return true }
        return cb.status == .completed || cb.status == .error
    }

    /// Blocks until every upload submitted so far has finished.
    public func waitUntilUploaded() {
        lock.lock()
        let cb = lastUpload
        lock.unlock()
        cb?.waitUntilCompleted()
    }

    private func track(_ cb: any MTLCommandBuffer) {
        lock.lock()
        lastUpload = cb
        lock.unlock()
    }

    private func upload(planes: [VolumeData], keepLinked: Bool) throws {
        let n = dimensions
        let bpp = format.bytesPerTexel
        let bytesPerRow = n.z * bpp
        let bytesPerImage = n.y * bytesPerRow

        if format.conversion == .none, planes.count == 1, let (buffer, offset) = Self.wrap(context.device, planes[0]) {
            let data = planes[0]
            let cb = try context.makeCommandBuffer(label: "upload \(geometry.id)")
            guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.allocationFailed("blit encoder") }
            // Slabs of at most 256 MB keep each copy bounded.
            let slab = max(1, min(n.x, (256 << 20) / max(1, bytesPerImage)))
            var z = 0
            while z < n.x {
                let depth = min(slab, n.x - z)
                blit.copy(from: buffer, sourceOffset: offset + z * bytesPerImage, sourceBytesPerRow: bytesPerRow,
                          sourceBytesPerImage: bytesPerImage, sourceSize: MTLSize(width: n.z, height: n.y, depth: depth),
                          to: texture, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: z))
                z += depth
            }
            blit.endEncoding()
            cb.addCompletedHandler { _ in withExtendedLifetime(data) {} }
            cb.commit()
            track(cb)
            if keepLinked {
                lock.lock()
                linkedData = data
                linkedBuffer = buffer
                linkedOffset = offset
                lock.unlock()
            }
            return
        }

        // Staging path: convert slabs on the CPU into a ring of shared
        // buffers while the GPU copies the previous slab.
        let converter = TexelConverter(conversion: format.conversion, planes: planes)
        let chunkBytes = 32 << 20
        let slab = max(1, min(n.x, chunkBytes / max(1, bytesPerImage)))
        let ringSize = 3
        let free = DispatchSemaphore(value: ringSize)
        var ring: [any MTLBuffer] = []
        for _ in 0..<min(ringSize, (n.x + slab - 1) / slab) {
            guard let b = context.device.makeBuffer(length: slab * bytesPerImage, options: .storageModeShared) else {
                throw RenderError.allocationFailed("staging buffer of \(slab * bytesPerImage) bytes")
            }
            ring.append(b)
        }
        var z = 0
        var k = 0
        while z < n.x {
            let depth = min(slab, n.x - z)
            free.wait()
            let buffer = ring[k % ring.count]
            let first = z * n.y * n.z
            converter.convert(texels: first..<(first + depth * n.y * n.z), into: buffer.contents(), parallel: true)
            let cb = try context.makeCommandBuffer(label: "upload \(geometry.id) slab \(z)")
            guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.allocationFailed("blit encoder") }
            blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerImage,
                      sourceSize: MTLSize(width: n.z, height: n.y, depth: depth), to: texture, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: z))
            blit.endEncoding()
            cb.addCompletedHandler { _ in free.signal() }
            cb.commit()
            track(cb)
            z += depth
            k += 1
        }
    }

    /// A buffer over `data`'s storage without copying: the page-aligned
    /// span holding it, and the byte offset of its first element.
    private static func wrap(_ device: any MTLDevice, _ data: VolumeData) -> (any MTLBuffer, Int)? {
        let page = UInt(VolumeData.pageSize)
        let start = UInt(bitPattern: data.baseAddress)
        let alignedStart = start & ~(page - 1)
        let end = start + UInt(max(1, data.byteCount))
        let alignedEnd = (end + page - 1) & ~(page - 1)
        let length = Int(alignedEnd - alignedStart)
        guard length > 0, length <= device.maxBufferLength,
              let pointer = UnsafeMutableRawPointer(bitPattern: alignedStart) else { return nil }
        guard let buffer = device.makeBuffer(bytesNoCopy: pointer, length: length, options: .storageModeShared,
                                             deallocator: nil) else { return nil }
        buffer.label = "volume storage (no copy)"
        return (buffer, Int(start - alignedStart))
    }

    // MARK: Partial updates

    /// Re-uploads the voxels of `region` (padded index order) from `data`,
    /// which must have this texture's layout (the same grid and type as the
    /// data it was made from). For a label texture made from the same
    /// `VolumeData` object, the region is blit straight from its storage.
    ///
    /// Returns immediately; the copy is ordered before any render submitted
    /// afterwards on the context's queue, so an edit is on screen in the
    /// next frame.
    public func update(region: VoxelBox, from data: VolumeData) throws {
        try update(region: region, planes: [data])
    }

    /// ``update(region:from:)`` for multi-channel textures (RGB, vectors).
    public func update(region: VoxelBox, planes: [VolumeData]) throws {
        let r = region.clamped(to: dimensions)
        guard !r.isEmpty else { return }
        let n = dimensions
        guard planes.allSatisfy({ $0.count == n.x * n.y * n.z }) else {
            throw RenderError.invalidArgument("update data does not have the texture's \(n) layout")
        }
        let bpp = format.bytesPerTexel
        let cb = try context.makeCommandBuffer(label: "update \(geometry.id) \(r)")
        guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.allocationFailed("blit encoder") }
        let size = MTLSize(width: r.size.z, height: r.size.y, depth: r.size.x)
        let dest = MTLOrigin(x: r.origin.z, y: r.origin.y, z: r.origin.x)

        lock.lock()
        let linked = (planes.count == 1 && planes[0] === linkedData) ? linkedBuffer : nil
        let linkedOffset = self.linkedOffset
        lock.unlock()

        if let linked {
            let first = (r.origin.x * n.y + r.origin.y) * n.z + r.origin.z
            blit.copy(from: linked, sourceOffset: linkedOffset + first * bpp, sourceBytesPerRow: n.z * bpp,
                      sourceBytesPerImage: n.y * n.z * bpp, sourceSize: size, to: texture, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: dest)
        } else {
            let rowBytes = r.size.z * bpp
            guard let staging = context.device.makeBuffer(length: max(16, r.voxelCount * bpp),
                                                          options: .storageModeShared) else {
                throw RenderError.allocationFailed("staging buffer")
            }
            let converter = TexelConverter(conversion: format.conversion, planes: planes)
            let dst = staging.contents()
            var row = 0
            for k0 in r.origin.x..<r.upper.x {
                for k1 in r.origin.y..<r.upper.y {
                    let first = (k0 * n.y + k1) * n.z + r.origin.z
                    converter.convert(texels: first..<(first + r.size.z), into: dst + row * rowBytes, parallel: false)
                    row += 1
                }
            }
            blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes,
                      sourceBytesPerImage: rowBytes * r.size.y, sourceSize: size, to: texture, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: dest)
        }
        blit.endEncoding()
        let keep = planes
        cb.addCompletedHandler { _ in withExtendedLifetime(keep) {} }
        cb.commit()
        track(cb)
        recordChange(r)
    }

    // MARK: Change tracking

    /// Incremented by every ``update(region:from:)``; consumers that derive
    /// data from the texture (the 3-D view's label surfaces) compare it.
    public var version: Int {
        lock.lock()
        defer { lock.unlock() }
        return contentVersion
    }

    /// The union of the regions updated after `version`, `nil` when nothing
    /// changed, or the whole volume when the history no longer reaches back.
    public func changedRegion(since version: Int) -> VoxelBox? {
        lock.lock()
        defer { lock.unlock() }
        if version >= contentVersion { return nil }
        guard let first = changeLog.first, first.version <= version + 1 else { return .whole(dimensions) }
        var region: VoxelBox?
        for entry in changeLog where entry.version > version {
            region = region.map { $0.union(entry.region) } ?? entry.region
        }
        return region ?? .whole(dimensions)
    }

    private func recordChange(_ region: VoxelBox) {
        lock.lock()
        contentVersion += 1
        changeLog.append((contentVersion, region))
        if changeLog.count > Self.changeLogLimit { changeLog.removeFirst(changeLog.count - Self.changeLogLimit) }
        lock.unlock()
    }

    // MARK: Values

    /// The raw (stored) value a texel holds.
    @inline(__always)
    public func raw(fromTexel t: Double) -> Double { t * texelScale + texelOffset }

    /// World → this texture's normalised coordinate.
    public var worldToTexture: simd_double4x4 { geometry.worldToTexture }
}

// MARK: - Formats and conversion

/// How stored values become texels.
enum TexelConversion: Equatable {
    /// The texture holds the stored bytes as they are.
    case none
    /// Any numeric type to `Float`.
    case float32
    /// Any integer type to `UInt16`, clamped.
    case uint16
    /// 3 or 4 `uint8` planes to interleaved RGBA8 (alpha 255 for 3).
    case rgba8
    /// 2 or 3 numeric planes to interleaved float4.
    case vectorFloat32
    /// 2 or 3 numeric planes to interleaved half4.
    case vectorFloat16
}

/// A texture format for a content and stored type.
struct TextureFormat {
    var pixelFormat: MTLPixelFormat
    var bytesPerTexel: Int
    var texelScale: Double
    var texelOffset: Double
    var filterable: Bool
    var conversion: TexelConversion

    static func scalar(_ type: ScalarType, float32Filterable: Bool) -> TextureFormat {
        switch type {
        case .bool, .uint8:
            return TextureFormat(pixelFormat: .r8Unorm, bytesPerTexel: 1, texelScale: 255, texelOffset: 0,
                                 filterable: true, conversion: .none)
        case .int8:
            return TextureFormat(pixelFormat: .r8Snorm, bytesPerTexel: 1, texelScale: 127, texelOffset: 0,
                                 filterable: true, conversion: .none)
        case .uint16:
            return TextureFormat(pixelFormat: .r16Unorm, bytesPerTexel: 2, texelScale: 65535, texelOffset: 0,
                                 filterable: true, conversion: .none)
        case .int16:
            return TextureFormat(pixelFormat: .r16Snorm, bytesPerTexel: 2, texelScale: 32767, texelOffset: 0,
                                 filterable: true, conversion: .none)
        case .float16:
            return TextureFormat(pixelFormat: .r16Float, bytesPerTexel: 2, texelScale: 1, texelOffset: 0,
                                 filterable: true, conversion: .none)
        case .float32:
            return TextureFormat(pixelFormat: .r32Float, bytesPerTexel: 4, texelScale: 1, texelOffset: 0,
                                 filterable: float32Filterable, conversion: .none)
        case .uint32, .int32, .uint64, .int64, .float64:
            return TextureFormat(pixelFormat: .r32Float, bytesPerTexel: 4, texelScale: 1, texelOffset: 0,
                                 filterable: float32Filterable, conversion: .float32)
        }
    }

    static func label(_ type: ScalarType) -> TextureFormat {
        switch type {
        case .bool, .uint8:
            return TextureFormat(pixelFormat: .r8Uint, bytesPerTexel: 1, texelScale: 1, texelOffset: 0,
                                 filterable: false, conversion: .none)
        case .uint16:
            return TextureFormat(pixelFormat: .r16Uint, bytesPerTexel: 2, texelScale: 1, texelOffset: 0,
                                 filterable: false, conversion: .none)
        case .uint32:
            return TextureFormat(pixelFormat: .r32Uint, bytesPerTexel: 4, texelScale: 1, texelOffset: 0,
                                 filterable: false, conversion: .none)
        default:
            return TextureFormat(pixelFormat: .r16Uint, bytesPerTexel: 2, texelScale: 1, texelOffset: 0,
                                 filterable: false, conversion: .uint16)
        }
    }

    static let rgba8 = TextureFormat(pixelFormat: .rgba8Unorm, bytesPerTexel: 4, texelScale: 255, texelOffset: 0,
                                     filterable: true, conversion: .rgba8)
    static let vector32 = TextureFormat(pixelFormat: .rgba32Float, bytesPerTexel: 16, texelScale: 1, texelOffset: 0,
                                        filterable: true, conversion: .vectorFloat32)
    static let vector16 = TextureFormat(pixelFormat: .rgba16Float, bytesPerTexel: 8, texelScale: 1, texelOffset: 0,
                                        filterable: true, conversion: .vectorFloat16)
}

/// Converts runs of texels (linear indices within one spatial frame) from
/// their stored planes into a texture's layout.
struct TexelConverter {
    let conversion: TexelConversion
    let planes: [VolumeData]

    func convert(texels range: Range<Int>, into dst: UnsafeMutableRawPointer, parallel: Bool) {
        let count = range.count
        guard count > 0 else { return }
        let chunk = 1 << 18
        if parallel && count > chunk {
            let chunks = (count + chunk - 1) / chunk
            let base = UInt(bitPattern: dst)
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = range.lowerBound + c * chunk
                let hi = min(range.upperBound, lo + chunk)
                let out = UnsafeMutableRawPointer(bitPattern: base)! + (lo - range.lowerBound) * self.bytesPerTexel
                self.convertSerial(lo..<hi, out)
            }
        } else {
            convertSerial(range, dst)
        }
    }

    private var bytesPerTexel: Int {
        switch conversion {
        case .none: return planes[0].scalarType.byteSize
        case .float32: return 4
        case .uint16: return 2
        case .rgba8: return 4
        case .vectorFloat32: return 16
        case .vectorFloat16: return 8
        }
    }

    private func convertSerial(_ range: Range<Int>, _ dst: UnsafeMutableRawPointer) {
        switch conversion {
        case .none:
            let size = planes[0].scalarType.byteSize
            dst.copyMemory(from: planes[0].baseAddress + range.lowerBound * size, byteCount: range.count * size)
        case .float32:
            planes[0].visit(ToFloat(range: range, out: dst.assumingMemoryBound(to: Float.self)))
        case .uint16:
            planes[0].visit(ToUInt16(range: range, out: dst.assumingMemoryBound(to: UInt16.self)))
        case .rgba8:
            let out = dst.assumingMemoryBound(to: UInt8.self)
            let sources = planes.map { UnsafePointer($0.baseAddress.assumingMemoryBound(to: UInt8.self)) }
            let channels = sources.count
            for (j, i) in range.enumerated() {
                let o = out + j * 4
                o[0] = sources[0][i]
                o[1] = sources[1][i]
                o[2] = sources[2][i]
                o[3] = channels == 4 ? sources[3][i] : 255
            }
        case .vectorFloat32:
            let out = dst.assumingMemoryBound(to: Float.self)
            for (c, plane) in planes.enumerated() where c < 4 {
                plane.visit(Strided(range: range, out: out, channel: c))
            }
            for j in 0..<range.count {
                for c in planes.count..<4 { out[j * 4 + c] = 0 }
            }
        case .vectorFloat16:
            let out = dst.assumingMemoryBound(to: Float16.self)
            for (c, plane) in planes.enumerated() where c < 4 {
                plane.visit(StridedHalf(range: range, out: out, channel: c))
            }
            for j in 0..<range.count {
                for c in planes.count..<4 { out[j * 4 + c] = 0 }
            }
        }
    }

    private struct ToFloat: VoxelVisitor {
        let range: Range<Int>
        let out: UnsafeMutablePointer<Float>
        func visit<T: VoxelScalar>(_ values: UnsafeBufferPointer<T>) {
            var j = 0
            for i in range {
                out[j] = Float(values[i].doubleValue)
                j += 1
            }
        }
    }

    private struct ToUInt16: VoxelVisitor {
        let range: Range<Int>
        let out: UnsafeMutablePointer<UInt16>
        func visit<T: VoxelScalar>(_ values: UnsafeBufferPointer<T>) {
            var j = 0
            for i in range {
                out[j] = UInt16(clampingDouble: values[i].doubleValue)
                j += 1
            }
        }
    }

    private struct Strided: VoxelVisitor {
        let range: Range<Int>
        let out: UnsafeMutablePointer<Float>
        let channel: Int
        func visit<T: VoxelScalar>(_ values: UnsafeBufferPointer<T>) {
            var j = 0
            for i in range {
                out[j * 4 + channel] = Float(values[i].doubleValue)
                j += 1
            }
        }
    }

    private struct StridedHalf: VoxelVisitor {
        let range: Range<Int>
        let out: UnsafeMutablePointer<Float16>
        let channel: Int
        func visit<T: VoxelScalar>(_ values: UnsafeBufferPointer<T>) {
            var j = 0
            for i in range {
                out[j * 4 + channel] = Float16(Float(values[i].doubleValue))
                j += 1
            }
        }
    }
}
