import Foundation
import simd
import MedH5Core

/// Everything a slice view draws: the camera (plane and zoom), an ordered
/// stack of layers (first at the bottom), vector overlays on top, and the
/// thick-slab setting.
///
/// The view's world is the reference frame (the base image's world); each
/// layer is placed by its own grid and ``LayerPlacement``.
public struct SliceScene: Sendable {
    public var camera: SliceCamera
    public var layers: [SliceLayer]
    public var overlays: [Overlay]
    public var slab: SlabSettings
    /// The colour behind everything (straight RGBA; images are read on black).
    public var backgroundColor: SIMD4<Double>
    /// Distance (mm) beyond which `.automatic` overlays are hidden; `nil`
    /// uses half the base image's voxel step along the normal (or half the
    /// slab thickness when a slab is shown, if larger).
    public var overlayDepthTolerance: Double?

    public init(camera: SliceCamera, layers: [SliceLayer] = [], overlays: [Overlay] = [],
                slab: SlabSettings = SlabSettings()) {
        self.camera = camera
        self.layers = layers
        self.overlays = overlays
        self.slab = slab
        self.backgroundColor = SIMD4(0, 0, 0, 1)
        self.overlayDepthTolerance = nil
    }

    /// The index of the base layer: the first visible image layer, else the
    /// first layer.
    public var baseLayerIndex: Int? {
        if let i = layers.firstIndex(where: {
            if case .image = $0, $0.isVisible { return true }
            return false
        }) { return i }
        return layers.isEmpty ? nil : 0
    }

    /// The base layer's grid (where slice steps and the overlay tolerance
    /// come from).
    public var baseGrid: GridGeometry? {
        baseLayerIndex.map { layers[$0].volume.geometry }
    }

    /// One voxel step of the base grid along the plane normal (1 mm without
    /// layers).
    public var sliceStep: Double {
        guard let g = baseGrid else { return 1 }
        return camera.voxelStep(of: g)
    }

    /// The tolerance in effect for `.automatic` overlays.
    public var effectiveOverlayTolerance: Double {
        if let t = overlayDepthTolerance { return t }
        var t = sliceStep / 2
        if slab.isActive { t = max(t, slab.thickness / 2) }
        return t
    }

    /// The first image layer, if any, for window/level interactions.
    public var baseImageLayer: ImageLayer? {
        get {
            guard let i = baseLayerIndex, case .image(let l) = layers[i] else { return nil }
            return l
        }
        set {
            guard let i = baseLayerIndex, case .image = layers[i], let newValue else { return }
            layers[i] = .image(newValue)
        }
    }
}
