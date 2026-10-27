import Foundation
import SwiftUI
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// Builds a slice view's render scene, and what its text overlay shows,
/// from the workspace: the stack's layers with their loaded textures and
/// placements, the geometric overlays, the crosshair and the camera.
///
/// A pure read of the models (no side effects but the store's
/// least-recently-used clock and the layers' colour tables), so the
/// controller can run it inside `withObservationTracking` and the snapshot
/// runner at any size.
@MainActor
struct SliceSceneBuilder {
    let workspace: Workspace
    let viewport: ViewportID

    struct Result {
        var scene: SliceScene?
        /// The camera of the scene and the fitted camera its framing is
        /// relative to.
        var camera: SliceCamera?
        var fitCamera: SliceCamera?
        var presentation: PresentationData
    }

    var viewer: ViewerModel { workspace.viewer }
    var store: VolumeStore { workspace.store }
    var summary: SampleSummary { workspace.summary }
    var stack: LayerStack { workspace.stack(for: viewport) }

    /// The camera fitted to the reference grid (no zoom or pan), at the
    /// cursor's slice.
    func fitCamera(reference: GridGeometry, size: SIMD2<Int>, scale: Double) -> SliceCamera {
        let plane = viewer.plane(of: viewport)
        let camera = SliceCamera.standard(plane, grid: reference, orientation: viewer.orientation,
                                          convention: viewer.convention, viewportSize: size, pixelsPerPoint: scale)
        if Self.isUsable(camera) || viewer.orientation == .anatomical { return camera }
        // An aligned plane a degenerate grid cannot give: the anatomical one.
        return SliceCamera.standard(plane, grid: reference, orientation: .anatomical, convention: viewer.convention,
                                    viewportSize: size, pixelsPerPoint: scale)
    }

    /// Whether a camera's plane and framing are finite (a damaged grid can
    /// make them NaN).
    static func isUsable(_ c: SliceCamera) -> Bool {
        let n = c.normal
        return n.x.isFinite && n.y.isFinite && n.z.isFinite && c.center.x.isFinite && c.center.y.isFinite
            && c.center.z.isFinite && c.millimetersPerPixel.isFinite && c.millimetersPerPixel > 0
    }

    /// The crosshair of this view, in its reference frame.
    func cursor(reference: GridGeometry) -> SIMD3<Double> {
        if viewport == .compareRight { return workspace.compareCursor ?? reference.worldCenter }
        return viewer.cursor
    }

    func camera(fit: SliceCamera, cursor: SIMD3<Double>) -> SliceCamera {
        var cam = fit
        let state = viewer.viewState(viewport)
        cam.millimetersPerPixel = fit.millimetersPerPixel / max(1e-6, state.zoom)
        cam.center += cam.axes.right * state.pan.x + cam.axes.down * state.pan.y
        cam.center += cam.normal * simd_dot(cursor - cam.center, cam.normal)
        return cam
    }

    func build(size: SIMD2<Int>, scale: Double) -> Result {
        _ = workspace.editRevision   // redraw after voxel edits
        var p = PresentationData()
        p.isActive = viewer.activeViewport == viewport && viewer.visibleViewports.count > 1
        let plane = viewer.plane(of: viewport)
        p.title = plane.title
        p.titleColor = PlaneColors.color(plane)
        p.showsOrientation = viewer.showsOrientationLabels
        if viewport == .compareLeft || viewport == .compareRight, let tp = workspace.timepoint(of: stack) {
            p.title = "\(plane.title) · \(workspace.timepointTitle(tp))"
        }
        guard let reference = workspace.referenceGrid(of: stack), let base = stack.base else {
            p.placeholder = stack.layers.isEmpty ? "No image to show" : "Choose a base image"
            return Result(scene: nil, camera: nil, fitCamera: nil, presentation: p)
        }
        guard size.x > 0, size.y > 0 else { return Result(scene: nil, camera: nil, fitCamera: nil, presentation: p) }
        let fit = fitCamera(reference: reference, size: size, scale: scale)
        let cursor = cursor(reference: reference)
        let cam = camera(fit: fit, cursor: cursor)
        guard Self.isUsable(cam) else {
            p.placeholder = "The geometry of \(reference.id) gives no \(plane.title.lowercased()) plane"
            return Result(scene: nil, camera: nil, fitCamera: nil, presentation: p)
        }
        let context = store.context

        var scene = SliceScene(camera: cam)
        var overlays: [Overlay] = []
        var labels: [ViewportLabel] = []
        var loading: [LoadingItem] = []
        var notes: [String] = []
        var badges: [String] = []
        let sliceStep = cam.voxelStep(of: reference)

        func noteLoading(_ key: ResourceKey, _ title: String) {
            if store.isLoading(key) {
                let fraction = store.progress[key]
                loading.append(LoadingItem(id: key.description, title: title, progress: fraction))
            } else if let failure = store.failure(key) {
                notes.append("\(key.objectID): \(failure)")
            }
        }

        for layer in stack.layers where layer.isVisible {
            switch layer.kind {
            case .image:
                guard let info = summary.image(layer.id), let grid = summary.grid(info.grid) else { continue }
                let placement = PlacementResolver.samplingState(
                    PlacementResolver.samplingKey(reference: reference, objectGrid: grid, objectFrame: grid.frameUID), store: store)
                if case .refused(let why) = placement { notes.append("\(layer.id): \(why)"); continue }
                let key = ResourceKey.imageFrame(layer.id, frame: layer.frameIndex(for: grid))
                guard let tex = store.ready(key, as: TextureResource.self), placement.isDrawable, !layer.needsAutoWindow else {
                    if !store.isLoading(.image(layer.id)) { noteLoading(key, "Preparing \(layer.id)") }
                    noteLoading(.image(layer.id), "Reading \(layer.id)")
                    continue
                }
                var image = ImageLayer(volume: tex.texture, windowCenter: layer.windowCenter, windowWidth: layer.windowWidth,
                                       rescaleSlope: info.rescaleSlope, rescaleIntercept: info.rescaleIntercept,
                                       colormap: layer.colormap, opacity: layer.opacity, interpolation: layer.interpolation,
                                       threshold: layer === base ? nil : layer.threshold, invert: layer.invert,
                                       placement: placement.placement)
                image.usesSlab = true
                scene.layers.append(.image(image))

            case .segmentation, .instances, .probability, .mask:
                guard let info = summary.annotation(layer.id) else { continue }
                let grid = info.grid.flatMap { summary.grid($0) }
                let placement = PlacementResolver.samplingState(
                    PlacementResolver.samplingKey(reference: reference, objectGrid: grid, objectFrame: info.frameUID), store: store)
                if case .refused(let why) = placement { notes.append("\(layer.id): \(why)"); continue }
                if case .pending = placement {
                    loading.append(LoadingItem(id: "placement \(layer.id)", title: "Resolving the transform of \(layer.id)", progress: nil))
                    continue
                }
                guard let context else { continue }
                scene.layers += voxelLayers(layer, info: info, placement: placement.placement, context: context,
                                            noteLoading: noteLoading)

            case .geometric:
                guard let info = summary.annotation(layer.id) else { continue }
                if workspace.editing.hasPendingDraft(layer.id) {
                    // Unsaved changes: drawn from the pending edit.
                    let built = ToolOverlayBuilder(workspace: workspace, viewport: viewport, camera: cam, reference: reference,
                                                   sliceStep: sliceStep).pendingDraft(layer, info: info)
                    overlays += built.overlays
                    labels += built.labels
                    notes += built.notes
                    continue
                }
                guard let g = store.ready(.geometry(layer.id), as: GeometryResource.self) else {
                    noteLoading(.geometry(layer.id), "Reading \(layer.id)")
                    continue
                }
                if let why = g.annotation.header?.worldError {
                    notes.append("\(layer.id): \(why)")
                    continue
                }
                let grid = info.grid.flatMap { summary.grid($0) }
                let key = PlacementResolver.pointKey(reference: reference, annotationGrid: grid, annotationFrame: info.frameUID)
                let (mapper, why) = PlacementResolver.pointMapper(key, store: store)
                guard let mapper else {
                    if let why { notes.append("\(layer.id): \(why)") }
                    continue
                }
                guard viewer.showsOverlays else { continue }
                let builder = GeometryOverlayBuilder(labelSet: summary.labelSet, camera: cam, sliceStep: sliceStep)
                let built = builder.build(g.annotation, meshes: g.meshes, layer: layer, mapper: mapper)
                overlays += built.overlays
                labels += built.labels

            case .classification:
                guard let g = store.ready(.geometry(layer.id), as: GeometryResource.self),
                      case .classification(let c) = g.annotation else {
                    noteLoading(.geometry(layer.id), "Reading \(layer.id)")
                    continue
                }
                badges.append(ClassificationText.badge(c, labelSet: summary.labelSet))
            }
        }

        // Measurements, the brush cursor, gestures in progress, selections.
        let tools = ToolOverlayBuilder(workspace: workspace, viewport: viewport, camera: cam, reference: reference,
                                       sliceStep: sliceStep).build()
        overlays += tools.overlays
        labels += tools.labels
        if viewer.showsCrosshair {
            overlays.append(.crosshair(at: cursor, camera: cam, color: SIMD4(0.35, 0.75, 1, 0.75), lineWidth: 1, gap: 10))
        }
        scene.overlays = overlays

        // Corner text.
        let baseInfo = summary.image(base.id)
        var tl = [base.id + (baseInfo.map { " · \($0.modality)" } ?? "")]
        let s = cam.sliceIndex(in: reference)
        let axis = Self.dominantAxis(cam.normal)
        let axisName = ["x", "y", "z"][axis]
        let slice = s.index.roundedInt.map { "\($0 + 1)/\(s.count)" } ?? "—"
        tl.append("Slice \(slice) · \(axisName) \(Format.fixed(cam.center[axis], digits: 1)) \(reference.units)")
        if let info = baseInfo, let grid = summary.grid(info.grid) {
            if let t = grid.timeAxis, grid.shape[t] > 1 {
                let value = grid.timeValues?[safe: base.timeIndex].map { " (\(Format.number($0)) \(grid.timeUnits ?? ""))" } ?? ""
                tl.append("Time \(base.timeIndex + 1)/\(grid.shape[t])\(value)")
            }
            if let c = grid.channelAxis, grid.shape[c] > 1, !ImageFrames.isColorInfo(info, grid: grid) {
                let name = info.channelNames?[safe: base.channelIndex] ?? "\(base.channelIndex + 1)"
                tl.append("Channel \(name)")
            }
        }
        p.topLeft = tl
        var tr: [String] = []
        if baseInfo?.valueType != "rgb" {
            let units = baseInfo.flatMap(WindowLevel.units).map { " \($0)" } ?? ""
            tr.append("W \(Format.number(base.windowWidth, digits: 1)) · L \(Format.number(base.windowCenter, digits: 1))\(units)")
        }
        p.topRight = tr
        p.bottomRight = ["Zoom \((viewer.viewState(viewport).zoom * 100).roundedInt ?? 100)% · \(base.interpolation.rawValue.capitalized)"]
        var bl: [String] = []
        if let tp = workspace.timepoint(of: stack), viewport != .compareLeft && viewport != .compareRight {
            bl.append(workspace.timepointTitle(tp))
        }
        if viewport == .compareRight, let mapping = workspace.compareMapping() {
            switch mapping.link {
            case .registered(let s): bl.append("Linked through \(s)")
            case .notRegistered: bl.append("Not registered — linked by voxel index")
            case .pending: bl.append("Resolving the transform…")
            }
        }
        p.bottomLeft = bl
        p.badges = badges
        p.notes = notes
        p.loading = loading
        p.labels = labels
        if viewer.showsOrientationLabels {
            let cs = reference.coordinateSystem
            p.orientation = OrientationLetters(left: cs.label(forWorldDirection: -cam.axes.right),
                                               right: cs.label(forWorldDirection: cam.axes.right),
                                               top: cs.label(forWorldDirection: -cam.axes.down),
                                               bottom: cs.label(forWorldDirection: cam.axes.down))
        }
        if scene.layers.isEmpty, loading.isEmpty, context == nil {
            p.placeholder = "Metal is not available on this Mac"
        }
        return Result(scene: scene, camera: cam, fitCamera: fit, presentation: p)
    }

    /// The renderer's layers for a voxel annotation.
    private func voxelLayers(_ layer: DisplayLayer, info: AnnotationInfo, placement: LayerPlacement, context: RenderContext,
                             noteLoading: (ResourceKey, String) -> Void) -> [SliceLayer] {
        let outlineOpacity = min(1, 0.4 + layer.opacity * 1.5)
        let kind: LayerKind = layer.kind == .instances && !layer.colorByInstance ? .segmentation : layer.kind
        switch kind {
        case .segmentation:
            let key = ResourceKey.segmentation(layer.id)
            guard let res = store.ready(key, as: SegmentationResource.self) else {
                noteLoading(key, "Reading \(layer.id)")
                return []
            }
            res.syncTextures()
            var colors: [UInt16: RGBA8] = [:]
            for c in res.model.classes { colors[c.id] = c.color }
            guard let table = layer.labelTable(context: context, colors: colors) else { return [] }
            var out: [SliceLayer] = res.textures.map { texture in
                .label(LabelLayer(volume: texture, lookupTable: table, style: layer.labelStyle, fillOpacity: layer.opacity,
                                  outlineOpacity: outlineOpacity, outlineWidth: layer.outlineWidth,
                                  ignoreID: res.model.ignoreValue, showsIgnoreRegion: layer.showsIgnoreRegion,
                                  placement: placement))
            }
            if let ignore = res.ignoreTexture, layer.showsIgnoreRegion {
                out.append(.label(LabelLayer(volume: ignore, lookupTable: table, style: .fill, fillOpacity: 0,
                                             outlineOpacity: 0, ignoreID: 1, showsIgnoreRegion: true, placement: placement)))
            }
            return out
        case .instances:
            let key = ResourceKey.instanceMap(layer.id)
            guard let res = store.ready(key, as: VoxelResource.self), let texture = res.texture else {
                noteLoading(key, "Reading \(layer.id)")
                return []
            }
            var colors: [UInt16: RGBA8] = [:]
            for (i, inst) in res.instances.enumerated() where i + 1 < 65535 {
                colors[UInt16(i + 1)] = LabelPalette.color(forClassID: Int(inst.instanceID % 65_000) + 1)
            }
            // Instances hidden by class.
            for (i, inst) in res.instances.enumerated() where i + 1 < 65535 && layer.hiddenClasses.contains(inst.classID) {
                colors[UInt16(i + 1)] = RGBA8(0, 0, 0, 0)
            }
            guard let table = layer.labelTable(context: context, colors: colors, hidesClasses: false) else { return [] }
            return [.label(LabelLayer(volume: texture, lookupTable: table, style: layer.labelStyle, fillOpacity: layer.opacity,
                                      outlineOpacity: outlineOpacity, outlineWidth: layer.outlineWidth,
                                      ignoreID: 0, showsIgnoreRegion: false, placement: placement))]
        case .probability:
            var out: [SliceLayer] = []
            for c in info.classIDs where layer.isClassVisible(c) {
                let key = ResourceKey.probability(layer.id, classID: c)
                guard let res = store.ready(key, as: VoxelResource.self), let texture = res.texture else {
                    noteLoading(key, "Reading \(layer.id)")
                    continue
                }
                let color = classColor(c, labelSet: summary.labelSet)
                var p = ProbabilityLayer(volume: texture, range: layer.probabilityThreshold...1, threshold: layer.probabilityThreshold,
                                         opacity: layer.opacity, showsFill: true, showsContour: layer.showsContour,
                                         contourColor: color.rgba, contourWidth: 1.5, placement: placement)
                p.lookupTable = layer.rampTable(context: context, classID: c, color: color)
                out.append(.probability(p))
            }
            return out
        case .mask:
            let key = ResourceKey.mask(layer.id)
            guard let res = store.ready(key, as: VoxelResource.self), let texture = res.texture else {
                noteLoading(key, "Reading \(layer.id)")
                return []
            }
            guard let table = layer.labelTable(context: context, colors: [1: MaskStyle.color]) else { return [] }
            return [.label(LabelLayer(volume: texture, lookupTable: table, style: layer.labelStyle, fillOpacity: layer.opacity,
                                      outlineOpacity: outlineOpacity, outlineWidth: layer.outlineWidth, ignoreID: 0,
                                      showsIgnoreRegion: false, placement: placement))]
        default:
            return []
        }
    }

    static func dominantAxis(_ v: SIMD3<Double>) -> Int {
        let a = abs(v)
        return a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2)
    }
}

/// How masks are drawn.
enum MaskStyle {
    static let color = RGBA8(64, 200, 220)
}

/// The text of a classification annotation.
enum ClassificationText {
    /// `response: stable disease` (the positive classes), or the values.
    static func badge(_ c: GeometricAnnotation.Classification, labelSet: LabelSetInfo?) -> String {
        let positives = c.assertions.filter { $0.value >= 0.5 }.map { className($0.classID, labelSet: labelSet) }
        let text = positives.isEmpty ? "no positive class" : positives.joined(separator: ", ")
        return "\(c.annotation): \(text)"
    }
}

extension ImageFrames {
    /// Whether an image (by its summary) renders as colour.
    static func isColorInfo(_ info: ImageInfo, grid: GridGeometry) -> Bool {
        guard info.valueType == "rgb", let c = grid.channelAxis else { return false }
        return (grid.shape[c] == 3 || grid.shape[c] == 4) && info.scalarType == .uint8
    }
}
