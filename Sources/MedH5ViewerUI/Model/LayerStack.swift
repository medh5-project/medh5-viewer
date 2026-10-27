import Foundation
import Observation
import simd
import MedH5Kit
import MedH5Render

/// How a layer is drawn, decided by what the object is.
enum LayerKind: Hashable {
    /// An image: windowed through a colormap (the base, or a fusion overlay).
    case image
    /// A voxel annotation read as layers (`labelmap`, `layers`, `bitmask`,
    /// or `instances` coloured by class).
    case segmentation
    /// An `instances` annotation coloured by instance.
    case instances
    /// A `probmap`: each class as a colour ramp with a contour at the threshold.
    case probability
    /// A `mask`.
    case mask
    /// A geometric annotation (`boxes`, `obb`, `keypoints`, `points`,
    /// `contours`, `polylines`, `mesh`), drawn as vector overlays.
    case geometric(String)
    /// A classification: no geometry; shown as a corner badge and in Info.
    case classification

    var isVoxel: Bool {
        switch self {
        case .image, .segmentation, .instances, .probability, .mask: return true
        default: return false
        }
    }

    /// Whether the layer holds classes the inspector can toggle.
    var hasClasses: Bool {
        switch self {
        case .segmentation, .probability, .geometric, .classification: return true
        default: return false
        }
    }
}

/// One layer of a view's stack: the object it shows and how it is shown.
/// Display settings live here, not in the document: they are not saved.
@MainActor
@Observable
final class DisplayLayer: Identifiable {
    /// The medh5 object (image or annotation id); unique in a stack.
    let id: String
    let kind: LayerKind
    /// The annotation kind (`layers`, `boxes`, …), or the image's modality.
    let detail: String

    var isVisible = true
    var opacity: Double

    // Images
    var windowCenter: Double = 0.5
    var windowWidth: Double = 1
    /// The preset the window came from (`nil` once dragged).
    var windowPreset: String?
    /// Set until a window is chosen from the image's own values (an image
    /// without stored presets): the store's percentiles fill it in.
    var needsAutoWindow = false
    var colormap: Colormap = .grayscale
    var interpolation: Interpolation = .linear
    /// Physical values below are transparent (fusion).
    var threshold: Double?
    var invert = false
    var timeIndex = 0
    var channelIndex = 0

    // Voxel annotations
    var labelStyle: LabelDisplayStyle = .fillAndOutline
    var outlineWidth: Double = 1
    var hiddenClasses: Set<Int> = []
    var showsIgnoreRegion = true
    /// `instances` annotations: by instance (the instance map) or by class.
    var colorByInstance = true

    // Probability maps
    var probabilityThreshold: Double = 0.5
    var showsContour = true

    // Geometric annotations
    var showsNames = true
    var lineWidth: Double = 1.5

    /// The label colour table, made on first use and kept in step with
    /// `hiddenClasses` (not observed: the renderer reads it).
    @ObservationIgnored var labelTable: LabelLookupTable?
    @ObservationIgnored var labelTableHidden: Set<Int>?
    @ObservationIgnored var labelTableColors: [UInt16: RGBA8]?
    /// Colour ramps of a probability map's classes.
    @ObservationIgnored var rampTables: [Int: LookupTable] = [:]

    init(id: String, kind: LayerKind, detail: String, opacity: Double = 1) {
        self.id = id
        self.kind = kind
        self.detail = detail
        self.opacity = opacity
    }

    var isImage: Bool { kind == .image }

    /// The leading index of the image frame shown.
    func frameIndex(for geometry: GridGeometry) -> [Int] {
        ImageFrames.leadingIndex(for: geometry, time: timeIndex, channel: channelIndex)
    }

    /// Sets the window to a preset.
    func apply(_ preset: WindowPreset) {
        windowCenter = preset.center
        windowWidth = max(1e-6, preset.width)
        windowPreset = preset.name
        needsAutoWindow = false
    }

    func setClass(_ id: Int, visible: Bool) {
        if visible { hiddenClasses.remove(id) } else { hiddenClasses.insert(id) }
    }

    func isClassVisible(_ id: Int) -> Bool { !hiddenClasses.contains(id) }

    /// The label table of this layer: class colours, hidden classes
    /// transparent. Made once; later calls apply only what changed.
    /// With `hidesClasses` false (an instance map, whose values are not
    /// classes) `hiddenClasses` is left to the colours.
    func labelTable(context: RenderContext, colors: [UInt16: RGBA8], hidesClasses: Bool = true) -> LabelLookupTable? {
        if labelTable == nil {
            labelTable = try? LabelLookupTable(context: context, colors: colors)
            labelTableColors = colors
            labelTableHidden = []
        }
        guard let table = labelTable else { return nil }
        if labelTableColors != colors {
            let previous = labelTableColors ?? [:]
            var changes = colors.filter { previous[$0.key] != $0.value }
            for id in previous.keys where colors[id] == nil { changes[id] = LabelPalette.color(forClassID: Int(id)) }
            table.setColors(changes)
            labelTableColors = colors
        }
        let hidden = hidesClasses ? hiddenClasses : []
        if labelTableHidden != hidden {
            let previous = labelTableHidden ?? []
            for id in previous.subtracting(hidden) where id > 0 && id < 65535 {
                table.setVisible(true, forClass: UInt16(id))
            }
            for id in hidden.subtracting(previous) where id > 0 && id < 65535 {
                table.setVisible(false, forClass: UInt16(id))
            }
            labelTableHidden = hidden
        }
        return table
    }

    /// A ramp from transparent to a class colour (probability maps).
    func rampTable(context: RenderContext, classID: Int, color: RGBA8) -> LookupTable? {
        if let t = rampTables[classID] { return t }
        let colors = [RGBA8(color.r, color.g, color.b, 0), RGBA8(color.r, color.g, color.b, 150),
                      RGBA8(color.r, color.g, color.b, 235)]
        let t = try? LookupTable(context: context, colors: colors)
        rampTables[classID] = t
        return t
    }
}

/// The layers a view shows, bottom first: a base image, then overlays.
/// The base image's grid is the stack's reference frame.
@MainActor
@Observable
final class LayerStack: Identifiable {
    let id: String
    /// Index 0 is the base (an image); the rest draw over it in order.
    private(set) var layers: [DisplayLayer] = []
    /// The layer the inspector edits.
    var selectedLayerID: String?

    init(id: String) {
        self.id = id
    }

    /// The base image layer.
    var base: DisplayLayer? {
        guard let first = layers.first, first.isImage else { return nil }
        return first
    }

    var overlays: [DisplayLayer] { base == nil ? layers : Array(layers.dropFirst()) }

    func layer(_ id: String) -> DisplayLayer? { layers.first { $0.id == id } }

    func contains(_ id: String) -> Bool { layers.contains { $0.id == id } }

    var selectedLayer: DisplayLayer? { selectedLayerID.flatMap(layer) ?? base }

    /// Makes `layer` the base, replacing the current one.
    func setBase(_ layer: DisplayLayer) {
        layers.removeAll { $0.id == layer.id }
        if base != nil { layers[0] = layer } else { layers.insert(layer, at: 0) }
        if selectedLayerID == nil || self.layer(selectedLayerID ?? "") == nil { selectedLayerID = layer.id }
    }

    /// Adds an overlay on top.
    func add(_ layer: DisplayLayer) {
        guard !contains(layer.id) else { return }
        layers.append(layer)
    }

    func remove(_ id: String) {
        guard let i = layers.firstIndex(where: { $0.id == id }), !(i == 0 && layers[0].isImage) else { return }
        layers.remove(at: i)
        if selectedLayerID == id { selectedLayerID = base?.id }
    }

    /// Replaces every layer.
    func replaceAll(_ newLayers: [DisplayLayer]) {
        layers = newLayers
        selectedLayerID = newLayers.first?.id
    }

    /// Moves an overlay up (towards the top) or down; the base stays first.
    func move(_ id: String, by offset: Int) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        let lowest = base == nil ? 0 : 1
        guard i >= lowest else { return }
        let j = min(layers.count - 1, max(lowest, i + offset))
        guard j != i else { return }
        let l = layers.remove(at: i)
        layers.insert(l, at: j)
    }

    /// Moves overlays as a list reorder does (indices into `overlays`
    /// listed top first, as the inspector shows them).
    func moveOverlays(fromTopFirst source: IndexSet, to destination: Int) {
        let topFirst = Array(overlays.reversed())
        let moving = source.sorted().compactMap { topFirst.indices.contains($0) ? topFirst[$0] : nil }
        var rest = topFirst.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = min(rest.count, max(0, destination - source.filter { $0 < destination }.count))
        rest.insert(contentsOf: moving, at: insertAt)
        layers = (base.map { [$0] } ?? []) + rest.reversed()
    }
}
