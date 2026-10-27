import Foundation
import Observation
import simd
import MedH5Kit
import MedH5Render

/// The pan and zoom of one slice view, relative to the view fitted to its
/// reference grid (so a resized window keeps its framing).
struct SliceViewState: Equatable {
    /// Magnification over the fitted view.
    var zoom: Double = 1
    /// Offset of the view centre from the fitted centre, in millimetres
    /// along screen-right and screen-down.
    var pan: SIMD2<Double> = .zero
}

/// How the label volumes appear in 3-D.
enum SurfaceStyle: String, CaseIterable, Identifiable {
    /// Ray cast from the label textures (exact, voxel-faithful).
    case rayCast
    /// Smooth meshes extracted by marching cubes (`SurfaceExtractor`).
    case meshes

    var id: String { rawValue }
    var title: String { self == .rayCast ? "Ray cast" : "Smoothed meshes" }
}

/// The settings of the 3-D view.
struct VolumeViewState: Equatable {
    var mode: VolumeRenderMode = .dvr
    var preset: TransferFunctionPreset = .ctBone
    var showsImage = true
    var showsPlanes = true
    var showsLabels = true
    var surfaceStyle: SurfaceStyle = .rayCast
    var labelOpacity = 1.0
    var showsMeshes = true
    /// Isosurface level (physical units).
    var isoValue = 300.0
    /// The clipping box as fractions of the reference volume along each
    /// padded index axis.
    var clipEnabled = false
    var clipLower = SIMD3<Double>(0, 0, 0)
    var clipUpper = SIMD3<Double>(1, 1, 1)
    /// Incremented by "Reset 3-D View".
    var resetToken = 0
}

/// What the pointer is over: the status bar's content.
struct HoverInfo: Equatable {
    var viewport: ViewportID
    /// World coordinates in the reference frame of the view's stack.
    var world: SIMD3<Double>
    var coordinateSystem: String
    var units: String
    /// The base grid's voxel under the pointer (padded index), when inside.
    var voxel: SIMD3<Int>?
    var spatialRank: Int
    var rawValue: Double?
    var physicalValue: Double?
    var valueUnits: String?
    var isRescaled: Bool
    /// The classes under the pointer in each visible voxel annotation.
    var labels: [LabelHit]
    var timepoint: String?

    struct LabelHit: Equatable {
        var annotation: String
        var classes: [String]
    }
}

/// The viewer's state shared by its views: layout, planes, the cursor
/// (crosshair), tool, per-view framing and the 3-D settings.
@MainActor
@Observable
final class ViewerModel {
    var layout: ViewerLayout
    /// The plane of the single view.
    var singlePlane: ViewPlane = .axial
    /// The plane both sides of Compare show.
    var comparePlane: ViewPlane = .axial
    var orientation: PlaneOrientationMode
    var convention: DisplayConvention
    var tool: ViewerTool = .navigate
    var showsCrosshair = true
    var showsOverlays = true
    var showsOrientationLabels = true
    /// The view that receives keyboard commands and whose stack the
    /// inspector shows: the one last chosen, or the first visible one when
    /// the layout no longer shows it.
    var activeViewport: ViewportID {
        get {
            let visible = visibleViewports
            return visible.contains(chosenViewport) ? chosenViewport : (visible.first ?? chosenViewport)
        }
        set { chosenViewport = newValue }
    }
    private var chosenViewport: ViewportID = .slice(.axial)
    /// The crosshair: a world point in the primary stack's reference frame.
    var cursor = SIMD3<Double>(0, 0, 0)
    /// Framing per slice view.
    var views: [ViewportID: SliceViewState] = [:]
    var volume = VolumeViewState()
    /// What the pointer is over (status bar).
    var hover: HoverInfo?

    init(layout: ViewerLayout = Preferences.defaultLayout,
         orientation: PlaneOrientationMode = Preferences.planeOrientation,
         convention: DisplayConvention = Preferences.convention) {
        self.layout = layout
        self.orientation = orientation
        self.convention = convention
        chosenViewport = layout == .volume ? .volume : (layout == .compare ? .compareLeft : .slice(.axial))
    }

    /// The viewports the layout shows, in reading order.
    var visibleViewports: [ViewportID] {
        switch layout {
        case .single: return [.slice(singlePlane)]
        case .oneByThree: return [.slice(.axial), .slice(.coronal), .slice(.sagittal)]
        case .twoByTwo: return [.slice(.axial), .slice(.coronal), .slice(.sagittal), .volume]
        case .volume: return [.volume]
        case .compare: return [.compareLeft, .compareRight]
        }
    }

    /// The plane a slice viewport shows.
    func plane(of viewport: ViewportID) -> ViewPlane {
        switch viewport {
        case .slice(let p): return p
        case .compareLeft, .compareRight: return comparePlane
        case .volume: return .axial
        }
    }

    func viewState(_ id: ViewportID) -> SliceViewState { views[id] ?? SliceViewState() }

    /// Resets every view's framing.
    func resetFraming() {
        views = [:]
        volume.resetToken += 1
    }

    /// Makes the active viewport a visible one after a layout change.
    func normalizeActiveViewport() {
        chosenViewport = activeViewport
    }

    /// Zooms the active slice view (or all of them) by a factor.
    func zoom(by factor: Double, viewport: ViewportID? = nil) {
        let targets = viewport.map { [$0] } ?? visibleViewports.filter(\.isSlice)
        for id in targets {
            var s = viewState(id)
            // The pan (mm) is kept: the view zooms about its centre.
            s.zoom = min(64, max(0.05, s.zoom * factor))
            views[id] = s
        }
    }
}
