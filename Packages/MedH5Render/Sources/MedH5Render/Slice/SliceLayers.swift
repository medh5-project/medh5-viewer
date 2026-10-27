import Foundation
import simd
import MedH5Core

/// How a volume is sampled between voxel centres.
public enum Interpolation: String, Sendable, CaseIterable, Codable {
    /// The voxel whose cell holds the point (blocky; exact values).
    case nearest
    /// Trilinear.
    case linear
    /// Interpolating tricubic (Catmull-Rom).
    case cubic
}

/// Where a layer's samples come from relative to the view's world (the
/// reference frame): `x_moving = M · (x + d(x))`, with an optional
/// displacement field `d` on its own grid in the reference frame, then an
/// optional affine `M`. Both default to the identity, which is right for a
/// layer on another grid of the same frame (its grid's affine places it).
public struct LayerPlacement: Sendable {
    /// An affine registration, `x_moving = M · x_fixed` (world → world).
    public var registration: simd_double4x4?
    /// A displacement field (world-space vectors in mm) on a grid of the
    /// reference frame, `x_moving = x + d(x)`; applied before `registration`.
    public var displacement: VolumeTexture?

    public init(registration: simd_double4x4? = nil, displacement: VolumeTexture? = nil) {
        self.registration = registration
        self.displacement = displacement
    }

    /// No transform.
    public static let identity = LayerPlacement()
}

/// An image layer: a scalar or RGB volume windowed through a colormap.
public struct ImageLayer: Sendable {
    /// The volume.
    public var volume: VolumeTexture
    /// Physical value = raw × slope + intercept (spec §4.2).
    public var rescaleSlope: Double
    public var rescaleIntercept: Double
    /// Window centre and width in physical units (raw units for RGB).
    public var windowCenter: Double
    public var windowWidth: Double
    /// The colormap (ignored for RGB volumes, and when ``lookupTable`` is set).
    public var colormap: Colormap
    /// A custom lookup table that replaces ``colormap``.
    public var lookupTable: LookupTable?
    /// Layer opacity, 0…1.
    public var opacity: Double
    public var interpolation: Interpolation
    /// Physical values below this are transparent (fusion overlays).
    public var threshold: Double?
    /// Inverts the windowed value.
    public var invert: Bool
    /// Registration / displacement applied before sampling.
    public var placement: LayerPlacement
    /// Whether the scene's thick-slab mode applies to this layer.
    public var usesSlab: Bool
    public var isVisible: Bool

    public init(
        volume: VolumeTexture,
        windowCenter: Double,
        windowWidth: Double,
        rescaleSlope: Double = 1,
        rescaleIntercept: Double = 0,
        colormap: Colormap = .grayscale,
        opacity: Double = 1,
        interpolation: Interpolation = .linear,
        threshold: Double? = nil,
        invert: Bool = false,
        placement: LayerPlacement = .identity
    ) {
        self.volume = volume
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.colormap = colormap
        self.lookupTable = nil
        self.opacity = opacity
        self.interpolation = interpolation
        self.threshold = threshold
        self.invert = invert
        self.placement = placement
        self.usesSlab = true
        self.isVisible = true
    }

    /// A layer for an image: its rescale, and its first window preset (or
    /// `window` when given).
    public init(image: ImageVolume, volume: VolumeTexture, window: WindowPreset? = nil) {
        let w = window ?? image.allWindowPresets.first
            ?? (image.isRGB ? WindowPreset(name: "RGB", center: 127.5, width: 255)
                : WindowPreset(name: "Default", center: 0.5, width: 1))
        self.init(volume: volume, windowCenter: w.center, windowWidth: w.width,
                  rescaleSlope: image.rescaleSlope, rescaleIntercept: image.rescaleIntercept)
    }

    /// Sets the window to a preset.
    public mutating func apply(_ preset: WindowPreset) {
        windowCenter = preset.center
        windowWidth = preset.width
    }
}

/// How segmentation classes are drawn.
public enum LabelDisplayStyle: String, Sendable, CaseIterable, Codable {
    case fill
    case outline
    case fillAndOutline
}

/// A segmentation layer (uint16 class ids, classes mutually exclusive).
public struct LabelLayer: Sendable {
    /// The label volume (content `.label`).
    public var volume: VolumeTexture
    /// Class colours and visibility.
    public var lookupTable: LabelLookupTable
    public var style: LabelDisplayStyle
    /// Fill opacity (multiplied by the class colour's alpha).
    public var fillOpacity: Double
    /// Outline opacity.
    public var outlineOpacity: Double
    /// Outline width in points.
    public var outlineWidth: Double
    /// The ignore id (spec §5.3: 65535 unless the annotation names another).
    public var ignoreID: UInt16
    /// Whether the ignore region is drawn (as grey hatching).
    public var showsIgnoreRegion: Bool
    /// Colour of the ignore hatching (straight RGBA).
    public var ignoreColor: SIMD4<Double>
    /// Distance between hatch lines, in points.
    public var ignoreHatchSpacing: Double
    public var placement: LayerPlacement
    public var isVisible: Bool

    public init(
        volume: VolumeTexture,
        lookupTable: LabelLookupTable,
        style: LabelDisplayStyle = .fillAndOutline,
        fillOpacity: Double = 0.35,
        outlineOpacity: Double = 1,
        outlineWidth: Double = 1,
        ignoreID: UInt16 = ClassID.ignore,
        showsIgnoreRegion: Bool = true,
        placement: LayerPlacement = .identity
    ) {
        self.volume = volume
        self.lookupTable = lookupTable
        self.style = style
        self.fillOpacity = fillOpacity
        self.outlineOpacity = outlineOpacity
        self.outlineWidth = outlineWidth
        self.ignoreID = ignoreID
        self.showsIgnoreRegion = showsIgnoreRegion
        let c = LabelPalette.ignoreColor.normalized
        self.ignoreColor = SIMD4(Double(c.x), Double(c.y), Double(c.z), Double(c.w))
        self.ignoreHatchSpacing = 6
        self.placement = placement
        self.isVisible = true
    }
}

/// A probability map: a colormap above a threshold, and an optional contour
/// at the threshold.
public struct ProbabilityLayer: Sendable {
    public var volume: VolumeTexture
    public var rescaleSlope: Double
    public var rescaleIntercept: Double
    public var colormap: Colormap
    public var lookupTable: LookupTable?
    /// The physical values mapped to the colormap's ends.
    public var range: ClosedRange<Double>
    /// Values below are transparent; the contour is drawn here.
    public var threshold: Double
    /// Fill opacity.
    public var opacity: Double
    public var showsFill: Bool
    public var showsContour: Bool
    /// Contour colour (straight RGBA).
    public var contourColor: SIMD4<Double>
    /// Contour width in points.
    public var contourWidth: Double
    public var interpolation: Interpolation
    public var placement: LayerPlacement
    public var isVisible: Bool

    public init(
        volume: VolumeTexture,
        rescaleSlope: Double = 1,
        rescaleIntercept: Double = 0,
        colormap: Colormap = .hotIron,
        range: ClosedRange<Double> = 0...1,
        threshold: Double = 0.5,
        opacity: Double = 0.5,
        showsFill: Bool = true,
        showsContour: Bool = true,
        contourColor: SIMD4<Double> = SIMD4(1, 0.85, 0.1, 1),
        contourWidth: Double = 1.5,
        placement: LayerPlacement = .identity
    ) {
        self.volume = volume
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.colormap = colormap
        self.lookupTable = nil
        self.range = range
        self.threshold = threshold
        self.opacity = opacity
        self.showsFill = showsFill
        self.showsContour = showsContour
        self.contourColor = contourColor
        self.contourWidth = contourWidth
        self.interpolation = .linear
        self.placement = placement
        self.isVisible = true
    }
}

/// One layer of a slice view, composited in order (first at the bottom).
public enum SliceLayer: Sendable {
    case image(ImageLayer)
    case label(LabelLayer)
    case probability(ProbabilityLayer)

    public var isVisible: Bool {
        switch self {
        case .image(let l): return l.isVisible
        case .label(let l): return l.isVisible
        case .probability(let l): return l.isVisible
        }
    }

    /// The layer's volume.
    public var volume: VolumeTexture {
        switch self {
        case .image(let l): return l.volume
        case .label(let l): return l.volume
        case .probability(let l): return l.volume
        }
    }

    public var placement: LayerPlacement {
        switch self {
        case .image(let l): return l.placement
        case .label(let l): return l.placement
        case .probability(let l): return l.placement
        }
    }
}

/// Thick-slab projection over a slab along the plane normal (image layers).
public enum SlabMode: String, Sendable, CaseIterable, Codable {
    case none
    /// Maximum intensity projection (MIP).
    case maximum
    /// Minimum intensity projection (MinIP).
    case minimum
    /// Mean (average intensity projection).
    case mean
}

/// The thick-slab settings of a slice view.
public struct SlabSettings: Sendable, Hashable {
    public var mode: SlabMode
    /// Slab thickness in mm, centred on the plane.
    public var thickness: Double

    public init(mode: SlabMode = .none, thickness: Double = 0) {
        self.mode = mode
        self.thickness = thickness
    }

    /// Whether a slab is active.
    public var isActive: Bool { mode != .none && thickness > 0 }
}
