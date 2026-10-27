import Foundation
import Metal
import simd

/// Brick maps for empty-space skipping: one texel per 8³ voxels (plus a
/// one-voxel apron). Images store the (min, max) texel of the brick
/// (`rg32Float`), label indicators whether any visible class is there
/// (`r8Unorm`).
enum BrickMap {
    static let size = 8

    /// The brick grid of a volume of padded shape `dims`, texture order (x, y, z).
    static func dimensions(_ dims: SIMD3<Int>) -> SIMD3<Int> {
        SIMD3((dims.z + size - 1) / size, (dims.y + size - 1) / size, (dims.x + size - 1) / size)
    }

    static func makeTexture(context: RenderContext, volumeDimensions dims: SIMD3<Int>, format: MTLPixelFormat,
                            label: String) throws -> any MTLTexture {
        let b = dimensions(dims)
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = format
        d.width = b.x
        d.height = b.y
        d.depth = b.z
        d.storageMode = .private
        d.usage = [.shaderRead, .shaderWrite]
        guard let t = context.device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("brick map \(b)")
        }
        t.label = label
        return t
    }

    /// Encodes `kernel` over the bricks a voxel region (padded index order)
    /// touches, apron included.
    static func encode(_ kernel: String, context: RenderContext, source: any MTLTexture, target: any MTLTexture,
                       region: VoxelRegion, dimensions dims: SIMD3<Int>,
                       commandBuffer: any MTLCommandBuffer) throws {
        guard let r = region.expanded(by: 1).clamped(to: dims) else { return }
        // Voxel (k0, k1, k2) → brick (x, y, z) = (k2, k1, k0) / 8.
        let lo = SIMD3(r.origin.z / size, r.origin.y / size, r.origin.x / size)
        let hi = SIMD3((r.upper.z - 1) / size, (r.upper.y - 1) / size, (r.upper.x - 1) / size)
        let count = hi &- lo &+ 1
        let pipeline = try context.computePipeline(kernel)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.allocationFailed("compute encoder")
        }
        encoder.label = kernel
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        var origin = SIMD4<UInt32>(UInt32(lo.x), UInt32(lo.y), UInt32(lo.z), 0)
        var n = SIMD4<UInt32>(UInt32(count.x), UInt32(count.y), UInt32(count.z), 0)
        encoder.setBytes(&origin, length: 16, index: 0)
        encoder.setBytes(&n, length: 16, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (count.x + 3) / 4, height: (count.y + 3) / 4, depth: (count.z + 3) / 4),
                                     threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4))
        encoder.endEncoding()
    }
}

/// Per image volume of the 3-D view, its (min, max) brick map, rebuilt over
/// the regions that changed.
final class ImageBrickCache {
    private final class Entry {
        weak var volume: VolumeTexture?
        let texture: any MTLTexture
        var version: Int
        init(volume: VolumeTexture, texture: any MTLTexture) {
            self.volume = volume
            self.texture = texture
            version = -1
        }
    }

    private let context: RenderContext
    private var entries: [Entry] = []

    init(context: RenderContext) {
        self.context = context
    }

    func bricks(for volume: VolumeTexture, commandBuffer: any MTLCommandBuffer) throws -> any MTLTexture {
        entries.removeAll { $0.volume == nil }
        let entry: Entry
        if let e = entries.first(where: { $0.volume === volume }) {
            entry = e
        } else {
            entry = Entry(volume: volume, texture: try BrickMap.makeTexture(
                context: context, volumeDimensions: volume.dimensions, format: .rg32Float, label: "image bricks"))
            entries.append(entry)
        }
        let version = volume.version
        if entry.version != version {
            let region = entry.version < 0 ? .whole(volume.dimensions)
                : (volume.changedRegion(since: entry.version) ?? .whole(volume.dimensions))
            try BrickMap.encode("brick_minmax_kernel", context: context, source: volume.texture, target: entry.texture,
                                region: region, dimensions: volume.dimensions, commandBuffer: commandBuffer)
            entry.version = version
        }
        return entry.texture
    }

    var allocatedSize: Int { entries.reduce(0) { $0 + $1.texture.allocatedSize } }
}

/// For each label layer of the 3-D view, an `r8Unorm` texture holding 1
/// where a visible class is and 0 elsewhere, and its occupancy brick map.
/// Rays sample the indicator with hardware trilinear filtering: its 0.5
/// level is the segmentation surface, and a wide gradient of it gives
/// smooth normals on blocky segmentations.
///
/// It is rebuilt on the GPU when the table's set of visible classes
/// changes, and only over the regions the editor updated when the labels
/// change, so painting stays interactive in the 3-D view.
final class LabelIndicatorCache {
    private final class Entry {
        weak var volume: VolumeTexture?
        weak var table: LabelLookupTable?
        let texture: any MTLTexture
        let bricks: any MTLTexture
        var volumeVersion: Int
        var tableVersion: Int

        init(volume: VolumeTexture, table: LabelLookupTable, texture: any MTLTexture, bricks: any MTLTexture) {
            self.volume = volume
            self.table = table
            self.texture = texture
            self.bricks = bricks
            volumeVersion = -1
            tableVersion = -1
        }
    }

    private let context: RenderContext
    private var entries: [Entry] = []

    init(context: RenderContext) {
        self.context = context
    }

    /// The indicator and its brick map for a layer, encoding whatever
    /// rebuild they need into `commandBuffer` (before the ray pass).
    func indicator(volume: VolumeTexture, table: LabelLookupTable,
                   commandBuffer: any MTLCommandBuffer) throws -> (indicator: any MTLTexture, bricks: any MTLTexture) {
        entries.removeAll { $0.volume == nil || $0.table == nil }
        let entry: Entry
        if let e = entries.first(where: { $0.volume === volume && $0.table === table }) {
            entry = e
        } else {
            let n = volume.dimensions
            let d = MTLTextureDescriptor()
            d.textureType = .type3D
            d.pixelFormat = .r8Unorm
            d.width = n.z
            d.height = n.y
            d.depth = n.x
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite]
            guard let t = context.device.makeTexture(descriptor: d) else {
                throw RenderError.allocationFailed("label indicator \(n)")
            }
            t.label = "label indicator"
            let bricks = try BrickMap.makeTexture(context: context, volumeDimensions: n, format: .r8Unorm,
                                                  label: "label bricks")
            entry = Entry(volume: volume, table: table, texture: t, bricks: bricks)
            entries.append(entry)
        }
        let tableVersion = table.visibilityVersion
        let volumeVersion = volume.version
        var region: VoxelRegion?
        if entry.tableVersion != tableVersion || entry.volumeVersion < 0 {
            region = .whole(volume.dimensions)
        } else if entry.volumeVersion != volumeVersion {
            region = volume.changedRegion(since: entry.volumeVersion)
        }
        if let region {
            table.synchronize()
            try encodeIndicator(volume: volume, table: table, target: entry.texture, region: region,
                                commandBuffer: commandBuffer)
            try BrickMap.encode("brick_occupancy_kernel", context: context, source: entry.texture, target: entry.bricks,
                                region: region, dimensions: volume.dimensions, commandBuffer: commandBuffer)
            entry.tableVersion = tableVersion
            entry.volumeVersion = volumeVersion
        }
        return (entry.texture, entry.bricks)
    }

    private func encodeIndicator(volume: VolumeTexture, table: LabelLookupTable, target: any MTLTexture,
                                 region: VoxelRegion, commandBuffer: any MTLCommandBuffer) throws {
        guard let r = region.clamped(to: volume.dimensions) else { return }
        let pipeline = try context.computePipeline("label_indicator_kernel")
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.allocationFailed("compute encoder")
        }
        encoder.label = "label indicator \(r)"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(volume.texture, index: 0)
        encoder.setTexture(table.texture, index: 1)
        encoder.setTexture(target, index: 2)
        // Texture order (x, y, z) = (k2, k1, k0).
        var origin = SIMD4<UInt32>(UInt32(r.origin.z), UInt32(r.origin.y), UInt32(r.origin.x), 0)
        var size = SIMD4<UInt32>(UInt32(r.size.z), UInt32(r.size.y), UInt32(r.size.x), 0)
        encoder.setBytes(&origin, length: 16, index: 0)
        encoder.setBytes(&size, length: 16, index: 1)
        let group = MTLSize(width: 8, height: 8, depth: 4)
        encoder.dispatchThreadgroups(MTLSize(width: (r.size.z + 7) / 8, height: (r.size.y + 7) / 8,
                                             depth: (r.size.x + 3) / 4), threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    /// GPU memory of the cached indicators and brick maps.
    var allocatedSize: Int { entries.reduce(0) { $0 + $1.texture.allocatedSize + $1.bricks.allocatedSize } }
}
