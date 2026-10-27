import AppKit
import SwiftUI
import simd
import MedH5Kit
import MedH5Render

/// Builds the 3-D view's scene from the primary stack: the base image ray
/// cast (MIP, MinIP, average, DVR, isosurface), segmentation surfaces (ray
/// cast from the label textures, or smoothed meshes), mesh annotations, the
/// three slice planes through the cursor, and the clipping box.
@MainActor
struct VolumeSceneBuilder {
    let workspace: Workspace

    var viewer: ViewerModel { workspace.viewer }
    var store: VolumeStore { workspace.store }
    var summary: SampleSummary { workspace.summary }

    struct Result {
        var scene: VolumeScene?
        var reference: GridGeometry?
        var presentation: PresentationData
    }

    /// The camera framing a grid from the front.
    static func homeCamera(for grid: GridGeometry, size: SIMD2<Int>) -> VolumeCamera {
        var c = VolumeCamera.framing(bounds: grid.worldBounds, from: .anterior, coordinateSystem: grid.coordinateSystem,
                                     viewportSize: size)
        c.orbit(byPixels: SIMD2(-60, -35))
        return c
    }

    func build(size: SIMD2<Int>, camera existing: VolumeCamera?) -> Result {
        _ = workspace.editRevision   // redraw after voxel edits
        var p = PresentationData()
        p.isActive = viewer.activeViewport == .volume && viewer.visibleViewports.count > 1
        p.title = "3-D"
        p.titleColor = Color(white: 0.85)
        p.showsOrientation = viewer.showsOrientationLabels
        let stack = workspace.primary
        guard let reference = workspace.referenceGrid(of: stack), let base = stack.base,
              let info = summary.image(base.id) else {
            p.placeholder = "No image to show"
            return Result(scene: nil, reference: nil, presentation: p)
        }
        let state = viewer.volume
        var camera = existing ?? Self.homeCamera(for: reference, size: size)
        camera.viewportSize = size
        var scene = VolumeScene(camera: camera)
        scene.backgroundColor = SIMD4(0, 0, 0, 1)
        var loading: [LoadingItem] = []
        var notes: [String] = []
        func noteLoading(_ key: ResourceKey, _ title: String) {
            if store.isLoading(key) {
                loading.append(LoadingItem(id: key.description, title: title, progress: store.progress[key]))
            } else if let f = store.failure(key) {
                notes.append("\(key.objectID): \(f)")
            }
        }

        // The image.
        let frame = base.frameIndex(for: reference)
        let histogram = store.ready(.histogram(base.id, frame: frame), as: HistogramResource.self)
        if state.showsImage, base.isVisible, info.valueType != "rgb" {
            if let tex = store.ready(.imageFrame(base.id, frame: frame), as: TextureResource.self) {
                var image = VolumeImage(volume: tex.texture, windowCenter: base.windowCenter, windowWidth: base.windowWidth,
                                        rescaleSlope: info.rescaleSlope, rescaleIntercept: info.rescaleIntercept,
                                        colormap: base.colormap)
                image.invert = base.invert
                scene.image = image
            } else {
                noteLoading(.image(base.id), "Reading \(base.id)")
            }
        }
        scene.mode = state.mode
        let range = histogram.map { ($0.percentiles[1] ?? $0.minimum)...max(($0.percentiles[99] ?? $0.maximum), ($0.percentiles[1] ?? $0.minimum) + 1e-6) }
        scene.transferFunction = TransferFunction.preset(state.preset, range: range)
        scene.isoValue = state.isoValue
        scene.quality = Preferences.volumeQuality.renderQuality

        // Segmentations.
        if state.showsLabels {
            var labelCount = 0
            for layer in stack.layers where layer.isVisible && (layer.kind == .segmentation || (layer.kind == .instances && !layer.colorByInstance)) {
                guard let a = summary.annotation(layer.id) else { continue }
                let grid = a.grid.flatMap { summary.grid($0) }
                let placement = PlacementResolver.samplingState(
                    PlacementResolver.samplingKey(reference: reference, objectGrid: grid, objectFrame: a.frameUID), store: store)
                guard let m = placement.matrix else {
                    if case .refused(let why) = placement { notes.append("\(layer.id): \(why)") }
                    continue
                }
                guard let res = store.ready(.segmentation(layer.id), as: SegmentationResource.self), let context = store.context else {
                    noteLoading(.segmentation(layer.id), "Reading \(layer.id)")
                    continue
                }
                res.syncTextures()
                if state.surfaceStyle == .meshes {
                    guard let surfaces = store.ready(.surfaces(layer.id), as: SurfaceResource.self) else {
                        if store.isLoading(.surfaces(layer.id)) {
                            loading.append(LoadingItem(id: "surfaces \(layer.id)", title: "Extracting surfaces of \(layer.id)", progress: nil))
                        }
                        continue
                    }
                    let toReference = m.inverse
                    for s in surfaces.surfaces where layer.isClassVisible(s.classID) {
                        var color = (res.model.classInfo(UInt16(s.classID))?.color ?? classColor(s.classID, labelSet: summary.labelSet)).rgba
                        color.w = state.labelOpacity
                        scene.meshes.append(MeshInstance(mesh: s.mesh, color: color, transform: toReference))
                    }
                } else {
                    var colors: [UInt16: RGBA8] = [:]
                    for c in res.model.classes { colors[c.id] = c.color }
                    guard let table = layer.labelTable(context: context, colors: colors) else { continue }
                    for texture in res.textures where labelCount < 4 {
                        var l = VolumeLabelLayer(volume: texture, lookupTable: table, opacity: state.labelOpacity)
                        if placement.matrix != matrix_identity_double4x4 { l.registration = m }
                        scene.labels.append(l)
                        labelCount += 1
                    }
                }
            }
        }

        // Mesh annotations.
        if state.showsMeshes {
            for layer in stack.layers where layer.isVisible && layer.kind == .geometric("mesh") {
                guard let a = summary.annotation(layer.id) else { continue }
                guard let g = store.ready(.geometry(layer.id), as: GeometryResource.self) else {
                    noteLoading(.geometry(layer.id), "Reading \(layer.id)")
                    continue
                }
                let grid = a.grid.flatMap { summary.grid($0) }
                let key = PlacementResolver.pointKey(reference: reference, annotationGrid: grid, annotationFrame: a.frameUID)
                let (mapper, why) = PlacementResolver.pointMapper(key, store: store)
                guard let mapper, mapper.field == nil else {
                    if let why { notes.append("\(layer.id): \(why)") }
                    continue
                }
                for part in g.meshes where part.classID.map(layer.isClassVisible) ?? true {
                    guard let gpu = part.gpu else { continue }
                    var color = (part.classID.map { classColor($0, labelSet: summary.labelSet) } ?? GeometryOverlayBuilder.defaultColor).rgba
                    color.w = min(1, layer.opacity)
                    scene.meshes.append(MeshInstance(mesh: gpu, color: color, transform: mapper.matrix ?? matrix_identity_double4x4))
                }
            }
        }

        // The slice planes through the cursor.
        if state.showsPlanes {
            for plane in ViewPlane.allCases {
                let cam = SliceSceneBuilder(workspace: workspace, viewport: .slice(plane))
                    .fitCamera(reference: reference, size: SIMD2(64, 64), scale: 1)
                var through = cam
                through.center += cam.normal * simd_dot(viewer.cursor - cam.center, cam.normal)
                var color = PlaneColors.rgba(plane)
                color.w = 0.9
                scene.planes.append(.slice(through, in: reference, color: color))
            }
        }

        if state.clipEnabled {
            let n = SIMD3<Double>(reference.paddedShape)
            let lo = simd_min(state.clipLower, state.clipUpper), hi = simd_max(state.clipLower, state.clipUpper)
            scene.clipBox = .index(lower: lo * n - 0.5, upper: hi * n - 0.5)
        }

        var tl = [base.id + " · " + modeTitle(state.mode)]
        if state.mode == .dvr { tl.append(state.preset.displayName) }
        if state.mode == .isosurface { tl.append("Level \(Format.number(state.isoValue, digits: 1))") }
        if state.clipEnabled { tl.append("Clipped") }
        p.topLeft = tl
        p.hint = ["Drag to orbit · ⌥-drag to pan · scroll to zoom", "Drag to orbit"]
        p.loading = loading
        p.notes = notes
        if viewer.showsOrientationLabels {
            let cs = reference.coordinateSystem
            p.orientation = OrientationLetters(left: cs.label(forWorldDirection: -camera.right),
                                               right: cs.label(forWorldDirection: camera.right),
                                               top: cs.label(forWorldDirection: camera.up),
                                               bottom: cs.label(forWorldDirection: -camera.up))
        }
        if store.context == nil { p.placeholder = "Metal is not available on this Mac" }
        return Result(scene: scene, reference: reference, presentation: p)
    }

    func modeTitle(_ mode: VolumeRenderMode) -> String {
        switch mode {
        case .mip: return "MIP"
        case .minip: return "MinIP"
        case .average: return "Average"
        case .dvr: return "DVR"
        case .isosurface: return "Isosurface"
        }
    }
}

/// Drives the 3-D view: rebuilds its scene as the workspace changes,
/// keeping the camera the user orbits; resets it on request.
@MainActor
final class VolumeViewportController: NSObject {
    private unowned let workspace: Workspace
    let container: ViewportContainerView
    let presentation = ViewportPresentation()
    private(set) var volumeView: VolumeView?
    private var referenceID: String?
    private var resetToken = 0
    private var scheduled = false
    private var isTornDown = false

    init(workspace: Workspace) {
        self.workspace = workspace
        var view: VolumeView?
        if let context = workspace.store.context {
            let camera = VolumeCamera(target: .zero, orientation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), distance: 500,
                                      viewportSize: SIMD2(1, 1), sceneRadius: 100)
            view = try? VolumeView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), context: context,
                                   scene: VolumeScene(camera: camera))
        }
        let overlay = PassthroughHostingView(rootView: SliceViewportOverlay(presentation: presentation))
        container = ViewportContainerView(content: view ?? PlaceholderView(), overlay: overlay)
        volumeView = view
        super.init()
        container.onResize = { [weak self] in self?.scheduleUpdate() }
        view?.sceneChangedByInteraction = { [weak self] _ in
            guard let self else { return }
            if self.workspace.viewer.activeViewport != .volume { self.workspace.viewer.activeViewport = .volume }
        }
        update()
    }

    func tearDown() {
        isTornDown = true
        volumeView?.sceneChangedByInteraction = nil
    }

    private var viewportSize: SIMD2<Int> {
        let scale = Double(container.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let b = container.bounds.size
        return SIMD2(Int((Double(b.width) * scale).rounded()), Int((Double(b.height) * scale).rounded()))
    }

    func scheduleUpdate() {
        guard !scheduled, !isTornDown else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.update()
        }
    }

    func update() {
        guard !isTornDown else { return }
        withObservationTracking {
            rebuild()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.scheduleUpdate() }
        }
    }

    private func rebuild() {
        let size = viewportSize
        let token = workspace.viewer.volume.resetToken
        var camera = volumeView?.scene.camera
        let reference = workspace.referenceGrid(of: workspace.primary)
        if reference?.id != referenceID || token != resetToken || (camera?.viewportSize ?? SIMD2(1, 1)) == SIMD2(1, 1) {
            camera = nil
        }
        let result = VolumeSceneBuilder(workspace: workspace).build(size: size, camera: camera)
        referenceID = result.reference?.id
        resetToken = token
        if let scene = result.scene, let view = volumeView {
            if let ref = result.reference, size.x > 0, size.y > 0 {
                view.homeCamera = VolumeSceneBuilder.homeCamera(for: ref, size: size)
            }
            view.finalQuality = Preferences.volumeQuality.renderQuality
            view.scene = scene
        }
        presentation.update(result.presentation)
    }

    /// Renders the view offscreen at `scale` pixels per point.
    func renderImage(scale: Double) throws -> CGImage? {
        guard let view = volumeView else { return nil }
        let b = container.bounds.size
        let size = SIMD2(Int((Double(b.width) * scale).rounded()), Int((Double(b.height) * scale).rounded()))
        guard size.x > 0, size.y > 0 else { return nil }
        let current = view.scene.camera
        var result = VolumeSceneBuilder(workspace: workspace).build(size: size, camera: current.viewportSize.x > 1 ? current : nil)
        guard var scene = result.scene else { return nil }
        scene.camera.viewportSize = size
        scene.quality = Preferences.volumeQuality.renderQuality
        result.scene = scene
        return try view.renderer.makeImage(scene: scene)
    }
}
