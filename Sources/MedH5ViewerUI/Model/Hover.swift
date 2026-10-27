import Foundation
import simd
import MedH5Kit
import MedH5Editing

extension Workspace {
    /// Updates the status bar for the pointer at a world point of a
    /// viewport's frame (`nil` when it left the view).
    func updateHover(world: SIMD3<Double>?, viewport: ViewportID) {
        guard let world else {
            if viewer.hover?.viewport == viewport { viewer.hover = nil }
            return
        }
        viewer.hover = hoverInfo(at: world, viewport: viewport)
    }

    func hoverInfo(at world: SIMD3<Double>, viewport: ViewportID) -> HoverInfo? {
        let stack = stack(for: viewport)
        guard let reference = referenceGrid(of: stack), let base = stack.base, let info = summary.image(base.id) else {
            return nil
        }
        var hover = HoverInfo(viewport: viewport, world: world, coordinateSystem: reference.coordSystem,
                              units: reference.units, voxel: reference.voxel(containingWorld: world),
                              spatialRank: reference.spatialRank, rawValue: nil, physicalValue: nil,
                              valueUnits: WindowLevel.units(of: info), isRescaled: info.rescaled, labels: [],
                              timepoint: timepoint(of: stack))
        if let k = hover.voxel, info.valueType != "rgb",
           let image = store.ready(.image(base.id), as: ImageResource.self)?.volume {
            let frame = image.spatialFrame(base.frameIndex(for: image.geometry))
            let linear = reference.linearOffset(k)
            if linear >= 0 && linear < frame.count {
                let raw = frame.value(at: linear)
                hover.rawValue = raw
                hover.physicalValue = image.physical(fromRaw: raw)
            }
        }
        for layer in stack.layers where layer.isVisible {
            guard let a = summary.annotation(layer.id) else { continue }
            let grid = a.grid.flatMap { summary.grid($0) }
            let state = PlacementResolver.samplingState(
                PlacementResolver.samplingKey(reference: reference, objectGrid: grid, objectFrame: a.frameUID), store: store)
            guard let m = state.matrix else { continue }
            let p = m.transformPoint(world)
            let kind: LayerKind = layer.kind == .instances && !layer.colorByInstance ? .segmentation : layer.kind
            switch kind {
            case .segmentation:
                guard let res = store.ready(.segmentation(layer.id), as: SegmentationResource.self) else { continue }
                let model = res.model
                if let k = model.geometry.voxel(containingWorld: p), model.isIgnored(at: k) {
                    hover.labels.append(.init(annotation: layer.id, classes: ["ignored"]))
                    continue
                }
                let names = model.labels(atWorld: p).filter { layer.isClassVisible(Int($0)) }
                    .map { model.classInfo($0)?.name ?? className(Int($0), labelSet: summary.labelSet) }
                if !names.isEmpty { hover.labels.append(.init(annotation: layer.id, classes: names)) }
            case .instances:
                guard let res = store.ready(.instanceMap(layer.id), as: VoxelResource.self), let g = grid?.spatialOnly,
                      let k = g.voxel(containingWorld: p) else { continue }
                let v = Int(res.data.value(at: g.linearOffset(k)))
                if v > 0, let inst = res.instances[safe: v - 1] {
                    hover.labels.append(.init(annotation: layer.id, classes: [
                        "instance \(inst.instanceID) (\(className(inst.classID, labelSet: summary.labelSet)))",
                    ]))
                }
            case .mask:
                guard let res = store.ready(.mask(layer.id), as: VoxelResource.self), let g = grid?.spatialOnly,
                      let k = g.voxel(containingWorld: p) else { continue }
                if res.data.value(at: g.linearOffset(k)) != 0 {
                    hover.labels.append(.init(annotation: layer.id, classes: ["inside"]))
                }
            case .probability:
                guard let g = grid?.spatialOnly, let k = g.voxel(containingWorld: p) else { continue }
                var parts: [String] = []
                for c in a.classIDs where layer.isClassVisible(c) {
                    guard let res = store.ready(.probability(layer.id, classID: c), as: VoxelResource.self) else { continue }
                    let v = res.data.value(at: g.linearOffset(k))
                    if v > 0.005 { parts.append("\(className(c, labelSet: summary.labelSet)) \(Format.number(v, digits: 2))") }
                }
                if !parts.isEmpty { hover.labels.append(.init(annotation: layer.id, classes: parts)) }
            default:
                continue
            }
        }
        return hover
    }
}
