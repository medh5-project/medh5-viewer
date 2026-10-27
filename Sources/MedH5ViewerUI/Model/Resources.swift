import Foundation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

// The things the volume store loads and keeps: voxels in memory, the GPU
// textures made from them once (and shared by every view), geometric
// annotations with their meshes, resolved transforms.

/// What the store holds, by identity.
enum ResourceKey: Hashable, Sendable, CustomStringConvertible {
    /// An image, every frame, raw values (`ImageVolume`).
    case image(String)
    /// The texture of one spatial frame of an image (`frame`: the full
    /// leading index; for an RGB image the channel entry is ignored).
    case imageFrame(String, frame: [Int])
    /// Statistics, histogram and percentiles of one frame of an image.
    case histogram(String, frame: [Int])
    /// A voxel annotation read as layers (any encoding): the editor's
    /// `SegmentationModel` and one label texture per layer.
    case segmentation(String)
    /// An `instances` annotation as one map of instance indices.
    case instanceMap(String)
    /// One class of a probability map.
    case probability(String, classID: Int)
    /// A `mask` annotation (0/1).
    case mask(String)
    /// A geometric or classification annotation, with its meshes.
    case geometry(String)
    /// The transform the engine resolves between two keys.
    case placement(PlacementKey)
    /// Smooth surface meshes of a segmentation's classes (3-D view).
    case surfaces(String)

    var description: String {
        switch self {
        case .image(let id): return "image \(id)"
        case .imageFrame(let id, let f): return "texture \(id)\(f.isEmpty ? "" : " \(f)")"
        case .histogram(let id, _): return "histogram \(id)"
        case .segmentation(let id): return "segmentation \(id)"
        case .instanceMap(let id): return "instances \(id)"
        case .probability(let id, let c): return "probability \(id) class \(c)"
        case .mask(let id): return "mask \(id)"
        case .geometry(let id): return "geometry \(id)"
        case .placement(let k): return "transform \(k.from) → \(k.to)"
        case .surfaces(let id): return "surfaces \(id)"
        }
    }

    /// The medh5 object the resource comes from, for progress labels.
    var objectID: String {
        switch self {
        case .image(let id), .imageFrame(let id, _), .histogram(let id, _), .segmentation(let id),
             .instanceMap(let id), .probability(let id, _), .mask(let id), .geometry(let id), .surfaces(let id):
            return id
        case .placement(let k): return k.to
        }
    }

    /// Whether loading it reads voxels (shown as progress in the viewport).
    var readsVoxels: Bool {
        switch self {
        case .image, .segmentation, .instanceMap, .probability, .mask: return true
        default: return false
        }
    }
}

/// Which transform to resolve: `x_to = T(x_from)` (spec §10.2), each key a
/// timepoint, grid or frame uid; a non-linear one is sampled on `fieldGrid`.
struct PlacementKey: Hashable, Sendable {
    var from: String
    var to: String
    var fieldGrid: String?
}

/// A loaded resource and the memory it holds.
protocol StoredResource: AnyObject, Sendable {
    /// CPU and GPU bytes (Apple silicon shares one memory).
    var byteCount: Int { get }
}

/// An image in memory.
final class ImageResource: StoredResource, @unchecked Sendable {
    let volume: ImageVolume
    init(volume: ImageVolume) { self.volume = volume }
    var byteCount: Int { volume.data.allocatedByteCount }
}

/// One texture.
final class TextureResource: StoredResource, @unchecked Sendable {
    let texture: VolumeTexture
    init(texture: VolumeTexture) { self.texture = texture }
    var byteCount: Int { texture.allocatedSize }
}

/// What the window/level controls need of a frame: statistics, a histogram
/// and percentiles, all in physical values.
final class HistogramResource: StoredResource, @unchecked Sendable {
    let minimum: Double
    let maximum: Double
    let mean: Double
    let standardDeviation: Double
    /// Counts over `minimum...maximum` (physical).
    let bins: [Int]
    /// Percentile (0–100) → physical value.
    let percentiles: [Double: Double]

    init(minimum: Double, maximum: Double, mean: Double, standardDeviation: Double, bins: [Int],
         percentiles: [Double: Double]) {
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.bins = bins
        self.percentiles = percentiles
    }

    var byteCount: Int { bins.count * 8 + 256 }

    /// The percentiles the store computes.
    static let percentileLevels: [Double] = [0.5, 1, 2, 5, 95, 98, 99, 99.5]
}

/// A voxel annotation held as layers (spec §7.2) by the editing model, with
/// one label texture per layer linked to the layer's memory (an edit
/// uploads only its dirty boxes, straight from the layer).
final class SegmentationResource: StoredResource, @unchecked Sendable {
    let info: AnnotationInfo
    let plan: LayerPlan
    let model: SegmentationModel
    private(set) var textures: [VolumeTexture]
    /// The ignore region when a sibling `mask` holds it (0/1); in band, the
    /// layers hold it.
    let ignoreRegion: VolumeData?
    let ignoreTexture: VolumeTexture?
    /// Voxels and box of each class, as the engine counted them at load.
    let classStats: [Int: AnnotationClassStats]
    private let context: RenderContext?

    init(info: AnnotationInfo, plan: LayerPlan, model: SegmentationModel, textures: [VolumeTexture],
         ignoreRegion: VolumeData?, ignoreTexture: VolumeTexture?, classStats: [Int: AnnotationClassStats],
         context: RenderContext?) {
        self.info = info
        self.plan = plan
        self.model = model
        self.textures = textures
        self.ignoreRegion = ignoreRegion
        self.ignoreTexture = ignoreTexture
        self.classStats = classStats
        self.context = context
    }

    var byteCount: Int {
        model.layers.reduce(0) { $0 + $1.allocatedByteCount } + textures.reduce(0) { $0 + $1.allocatedSize }
            + (ignoreRegion?.allocatedByteCount ?? 0) + (ignoreTexture?.allocatedSize ?? 0)
    }

    /// Brings the textures up to date with the model after edits: uploads
    /// the dirty boxes, or remakes the textures when the layer count
    /// changed. Call on the main actor before drawing.
    @MainActor
    @discardableResult
    func syncTextures() -> Bool {
        guard model.hasPendingRenderUpdate else { return false }
        let update = model.takeRenderUpdate()
        if update.layersChanged || textures.count != model.layers.count, let context {
            textures = (try? model.layers.map { try VolumeTexture(context: context, labels: $0, geometry: model.geometry) }) ?? []
            return true
        }
        for (layer, boxes) in update.regions where layer < textures.count {
            for box in boxes { try? textures[layer].update(region: box, from: model.layers[layer]) }
        }
        return true
    }
}

/// A mask, a probability class or an instance map: one volume and its texture.
final class VoxelResource: StoredResource, @unchecked Sendable {
    let data: VolumeData
    let texture: VolumeTexture?
    /// The objects of an instance map, in map order (value `1 + index`).
    let instances: [InstanceInfo]

    init(data: VolumeData, texture: VolumeTexture?, instances: [InstanceInfo] = []) {
        self.data = data
        self.texture = texture
        self.instances = instances
    }

    var byteCount: Int { data.allocatedByteCount + (texture?.allocatedSize ?? 0) }
}

/// One surface of a mesh annotation (a submesh), in world coordinates of
/// the annotation's frame.
struct MeshPart: @unchecked Sendable {
    var classID: Int?
    var mesh: TriangleMesh
    var slicer: MeshSlicer
    var gpu: GPUMesh?
}

/// A geometric or classification annotation as the engine gives it.
final class GeometryResource: StoredResource, @unchecked Sendable {
    let annotation: GeometricAnnotation
    let meshes: [MeshPart]

    init(annotation: GeometricAnnotation, meshes: [MeshPart]) {
        self.annotation = annotation
        self.meshes = meshes
    }

    var byteCount: Int {
        meshes.reduce(4096) { $0 + $1.mesh.vertexCount * 24 + $1.mesh.indices.count * 4 + ($1.gpu?.allocatedSize ?? 0) }
    }
}

/// A resolved transform: a matrix, or a displacement field as a texture
/// (sampled on the reference grid), or nothing (no transform relates them).
final class PlacementResource: StoredResource, @unchecked Sendable {
    let transform: ResolvedTransform?
    let fieldTexture: VolumeTexture?

    init(transform: ResolvedTransform?, fieldTexture: VolumeTexture?) {
        self.transform = transform
        self.fieldTexture = fieldTexture
    }

    var byteCount: Int {
        var n = 1024 + (fieldTexture?.allocatedSize ?? 0)
        if case .field(let d, _)? = transform?.mapping { n += d.allocatedByteCount }
        return n
    }

    /// How a reader would name the path: `tp0_to_tp1 (affine)`, `inverse of …`.
    var summary: String {
        guard let t = transform else { return "no transform" }
        if t.isIdentity { return "same frame" }
        let steps = zip(t.path, t.inverted + Array(repeating: false, count: max(0, t.path.count - t.inverted.count)))
            .map { $1 ? "inverse of \($0)" : $0 }
        let kind = t.kind.map { " (\($0))" } ?? ""
        return (steps.isEmpty ? "resolved transform" : steps.joined(separator: " ∘ ")) + kind
    }
}

/// Smooth per-class surfaces of a segmentation for the 3-D view.
final class SurfaceResource: StoredResource, @unchecked Sendable {
    struct Surface: @unchecked Sendable {
        var classID: Int
        var mesh: GPUMesh
        var triangles: Int
    }

    let surfaces: [Surface]
    init(surfaces: [Surface]) { self.surfaces = surfaces }
    var byteCount: Int { surfaces.reduce(0) { $0 + $1.mesh.allocatedSize } }
}

/// Builds the editor's segmentation model from what the engine read.
enum SegmentationFactory {
    static func model(from data: SegmentationData) throws -> SegmentationModel {
        var classes: [SegmentClass] = []
        for c in data.classes {
            guard c.id > 0 && c.id < 65535 && c.id != data.ignoreID else { continue }
            let layer = data.plan.layer(of: c.id) ?? 0
            classes.append(SegmentClass(id: UInt16(c.id), key: c.key, name: c.name, color: c.displayColor, layer: layer))
        }
        let ids = data.classIDs.filter { $0 > 0 && $0 < 65535 && $0 != data.ignoreID }.map { UInt16($0) }
        let annotated = data.annotatedClassIDs.filter { ids.contains(UInt16(clamping: $0)) }.map { UInt16($0) }
        var layers = data.layers
        if layers.isEmpty { layers = [VolumeData(scalarType: .uint16, shape: data.geometry.spatialShape)] }
        let metadata = SegmentationMetadata(
            classes: classes, classIDs: ids, annotatedClassIDs: annotated, layerCount: layers.count,
            ignoreValue: UInt16(clamping: data.ignoreID))
        return try SegmentationModel(geometry: data.geometry, layers: layers, metadata: metadata,
                                     registerUnknownLabels: true)
    }
}
