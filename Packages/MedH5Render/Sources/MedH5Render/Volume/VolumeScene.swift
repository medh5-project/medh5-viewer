import Foundation
import Metal
import simd
import MedH5Core

/// How the 3-D view renders its image volume.
public enum VolumeRenderMode: String, Sendable, CaseIterable, Codable {
    /// Maximum intensity projection.
    case mip
    /// Minimum intensity projection.
    case minip
    /// Average intensity along the ray.
    case average
    /// Direct volume rendering through the transfer function.
    case dvr
    /// The first surface at ``VolumeScene/isoValue``, shaded.
    case isosurface
}

/// The image volume of a 3-D view and how its values map to display.
public struct VolumeImage: Sendable {
    public var volume: VolumeTexture
    public var rescaleSlope: Double
    public var rescaleIntercept: Double
    /// Window for MIP / MinIP / average (physical units).
    public var windowCenter: Double
    public var windowWidth: Double
    /// Colormap for MIP / MinIP / average.
    public var colormap: Colormap
    public var invert: Bool
    /// Registration of the volume into the view's world (`x_moving = M · x`).
    public var registration: simd_double4x4?

    public init(volume: VolumeTexture, windowCenter: Double, windowWidth: Double, rescaleSlope: Double = 1,
                rescaleIntercept: Double = 0, colormap: Colormap = .grayscale) {
        self.volume = volume
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.colormap = colormap
        self.invert = false
        self.registration = nil
    }
}

/// A segmentation layer rendered as shaded surfaces in its class colours
/// (hidden classes, alpha 0 in the table, are skipped).
public struct VolumeLabelLayer: Sendable {
    public var volume: VolumeTexture
    public var lookupTable: LabelLookupTable
    /// Surface opacity (multiplied by the class colour's alpha).
    public var opacity: Double
    public var registration: simd_double4x4?
    public var isVisible: Bool

    public init(volume: VolumeTexture, lookupTable: LabelLookupTable, opacity: Double = 1) {
        self.volume = volume
        self.lookupTable = lookupTable
        self.opacity = opacity
        self.registration = nil
        self.isVisible = true
    }
}

/// A clipping box: rays are cut to its inside.
public enum VolumeClipBox: Sendable, Hashable {
    /// In the reference volume's padded index coordinates (continuous; the
    /// whole volume is `[-0.5, n - 0.5]`).
    case index(lower: SIMD3<Double>, upper: SIMD3<Double>)
    /// Axis-aligned in world coordinates.
    case world(lower: SIMD3<Double>, upper: SIMD3<Double>)
}

/// Shading of surfaces (DVR gradients, isosurfaces, labels).
public struct VolumeShading: Sendable, Hashable {
    public var enabled: Bool
    public var ambient: Double
    public var diffuse: Double
    public var specular: Double
    public var shininess: Double

    public init(enabled: Bool = true, ambient: Double = 0.25, diffuse: Double = 0.75, specular: Double = 0.3,
                shininess: Double = 32) {
        self.enabled = enabled
        self.ambient = ambient
        self.diffuse = diffuse
        self.specular = specular
        self.shininess = shininess
    }
}

/// Sampling quality: render resolution and samples per voxel along rays.
public struct VolumeRenderQuality: Sendable, Hashable {
    /// Fraction of the drawable's resolution rays are cast at (upsampled).
    public var resolutionScale: Double
    /// Ray samples per (smallest) voxel spacing.
    public var samplesPerVoxel: Double

    public init(resolutionScale: Double, samplesPerVoxel: Double) {
        self.resolutionScale = resolutionScale
        self.samplesPerVoxel = samplesPerVoxel
    }

    /// While the camera moves.
    public static let interactive = VolumeRenderQuality(resolutionScale: 0.5, samplesPerVoxel: 1)
    /// When idle.
    public static let full = VolumeRenderQuality(resolutionScale: 1, samplesPerVoxel: 2)
}

/// A slice plane shown in the 3-D view: its intersection with a volume's
/// region, outlined, optionally filled or textured with the slice image.
public struct VolumePlane: @unchecked Sendable {
    /// The polygon (world) — usually `PlaneIntersection.polygon(grid:plane:)`.
    public var polygon: [SIMD3<Double>]
    /// Outline colour (straight RGBA); alpha 0 hides the outline.
    public var outlineColor: SIMD4<Double>
    /// Fill colour (straight RGBA); alpha 0 hides the fill. With a texture,
    /// the texture is tinted by the colour and drawn at its alpha.
    public var fillColor: SIMD4<Double>
    /// A slice image to texture the polygon with, and the slice camera that
    /// rendered it (to map world points to texture coordinates).
    public var texture: (any MTLTexture)?
    public var textureCamera: SliceCamera?

    public init(polygon: [SIMD3<Double>], outlineColor: SIMD4<Double>,
                fillColor: SIMD4<Double> = SIMD4(0, 0, 0, 0)) {
        self.polygon = polygon
        self.outlineColor = outlineColor
        self.fillColor = fillColor
        self.texture = nil
        self.textureCamera = nil
    }

    /// The plane of a slice camera cut to a grid's region, outlined.
    public static func slice(_ camera: SliceCamera, in grid: GridGeometry, color: SIMD4<Double>) -> VolumePlane {
        VolumePlane(polygon: PlaneIntersection.polygon(grid: grid, plane: camera.plane), outlineColor: color)
    }
}

/// Everything the 3-D view draws.
public struct VolumeScene: Sendable {
    /// The 3-D camera.
    public var camera: VolumeCamera
    /// The ray-cast image (optional: a scene can hold only labels or meshes).
    public var image: VolumeImage?
    /// How the image is rendered.
    public var mode: VolumeRenderMode
    /// Colour and opacity over physical values (DVR).
    public var transferFunction: TransferFunction
    /// Threshold for ``VolumeRenderMode/isosurface`` (physical units).
    public var isoValue: Double
    /// Isosurface colour (straight RGBA).
    public var isoColor: SIMD4<Double>
    public var shading: VolumeShading
    /// Rays are cut to this box.
    public var clipBox: VolumeClipBox?
    /// Keeps the half-space the normal points into.
    public var clipPlane: Plane?
    /// Segmentation layers (up to four are ray cast).
    public var labels: [VolumeLabelLayer]
    /// Meshes, depth-composited with the rays.
    public var meshes: [MeshInstance]
    /// Slice planes drawn in 3-D.
    public var planes: [VolumePlane]
    /// Resolution and sampling rate (the view switches it while interacting).
    public var quality: VolumeRenderQuality
    /// Ray step in mm; `nil` derives it from the volume's spacing and ``quality``.
    public var stepSize: Double?
    /// Straight RGBA.
    public var backgroundColor: SIMD4<Double>

    /// A scene; isosurface level 300, bone-coloured, shading on, full quality.
    public init(camera: VolumeCamera, image: VolumeImage? = nil, mode: VolumeRenderMode = .dvr,
                transferFunction: TransferFunction = .preset(.ctBone)) {
        self.camera = camera
        self.image = image
        self.mode = mode
        self.transferFunction = transferFunction
        self.isoValue = 300
        self.isoColor = SIMD4(0.92, 0.87, 0.78, 1)
        self.shading = VolumeShading()
        self.clipBox = nil
        self.clipPlane = nil
        self.labels = []
        self.meshes = []
        self.planes = []
        self.quality = .full
        self.stepSize = nil
        self.backgroundColor = SIMD4(0, 0, 0, 1)
    }

    /// World bounds of everything in the scene (volumes and meshes).
    public var worldBounds: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        var any = false
        func add(_ b: (min: SIMD3<Double>, max: SIMD3<Double>)) {
            lo = simd_min(lo, b.min)
            hi = simd_max(hi, b.max)
            any = true
        }
        if let image { add(image.volume.geometry.worldBounds) }
        for l in labels { add(l.volume.geometry.worldBounds) }
        for m in meshes where m.isVisible { add(m.mesh.bounds) }
        return any ? (lo, hi) : nil
    }
}
