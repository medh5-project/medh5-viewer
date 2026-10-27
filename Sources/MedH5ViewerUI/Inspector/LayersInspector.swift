import SwiftUI
import MedH5Kit
import MedH5Render

/// The layer stack of the active view and the settings of the selected
/// layer: window/level with presets, auto and a histogram, colormap and
/// interpolation for images; display mode, outline and per-class toggles for
/// segmentations; the transform used for layers from other frames.
struct LayersInspector: View {
    let workspace: Workspace

    var body: some View {
        let stack = workspace.activeStack
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if workspace.viewer.activeViewport == .volume {
                    VolumeSettings(workspace: workspace)
                    Divider().padding(.horizontal, 14)
                }
                InspectorSection("Layers", trailing: AnyView(orderButtons(stack))) {
                    LayerList(workspace: workspace, stack: stack)
                    Text(stackCaption(stack))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                if let layer = stack.selectedLayer {
                    Divider().padding(.horizontal, 14)
                    LayerDetail(workspace: workspace, stack: stack, layer: layer)
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func stackCaption(_ stack: LayerStack) -> String {
        var view: String
        switch workspace.viewer.activeViewport {
        case .slice(let p): view = "\(p.title) view"
        case .volume: view = "3-D view"
        case .compareLeft: view = "Compare, left"
        case .compareRight: view = "Compare, right"
        }
        if let tp = workspace.timepoint(of: stack) { view += " · " + workspace.timepointTitle(tp) }
        return "Shown in the \(view). Add overlays with the eye buttons in the sidebar."
    }

    private func orderButtons(_ stack: LayerStack) -> some View {
        let selected = stack.selectedLayer
        let isOverlay = selected != nil && selected !== stack.base
        return HStack(spacing: 2) {
            Button { if let s = selected { stack.move(s.id, by: 1) } } label: { Image(systemName: "arrow.up") }
                .help("Move the layer up").disabled(!isOverlay)
            Button { if let s = selected { stack.move(s.id, by: -1) } } label: { Image(systemName: "arrow.down") }
                .help("Move the layer down").disabled(!isOverlay)
            Button { if let s = selected { stack.remove(s.id) } } label: { Image(systemName: "minus") }
                .help("Remove the layer from the view").disabled(!isOverlay)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

/// The layers, top first.
struct LayerList: View {
    let workspace: Workspace
    let stack: LayerStack

    var body: some View {
        VStack(spacing: 0) {
            let layers = Array(stack.layers.reversed())
            ForEach(Array(layers.enumerated()), id: \.element.id) { i, layer in
                LayerRow(workspace: workspace, stack: stack, layer: layer)
                if i < layers.count - 1 { Divider().padding(.leading, 34) }
            }
            if layers.isEmpty {
                Text("No layers").foregroundStyle(.secondary).padding(8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
    }
}

struct LayerRow: View {
    let workspace: Workspace
    let stack: LayerStack
    let layer: DisplayLayer

    var body: some View {
        let selected = stack.selectedLayer === layer
        HStack(spacing: 8) {
            Button { layer.isVisible.toggle() } label: {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(layer.isVisible ? "Hide" : "Show")
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.id).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if case .refused = placement {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(placement.summary)
            } else if case .resolved = placement {
                Image(systemName: "link").foregroundStyle(.secondary).help("Placed through \(placement.summary)")
            }
            if layer === stack.base {
                Text("BASE").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { stack.selectedLayerID = layer.id }
        .opacity(layer.isVisible ? 1 : 0.6)
    }

    private var symbol: String {
        if layer.isImage, let info = workspace.summary.image(layer.id) {
            return Symbols.image(modality: info.modality, valueType: info.valueType)
        }
        return Symbols.annotation(kind: layer.detail)
    }

    private var subtitle: String {
        if layer.isImage {
            return layer === stack.base ? "\(layer.detail) · base image" : "\(layer.detail) · fusion, \(Int(layer.opacity * 100))%"
        }
        return KindNames.annotation(layer.detail)
    }

    private var placement: PlacementState {
        LayerPlacementInfo.state(workspace: workspace, stack: stack, layer: layer)
    }
}

/// How a layer is placed in its stack's reference frame.
@MainActor
enum LayerPlacementInfo {
    static func state(workspace: Workspace, stack: LayerStack, layer: DisplayLayer) -> PlacementState {
        guard let reference = workspace.referenceGrid(of: stack) else { return .identity }
        let s = workspace.summary
        if let image = s.image(layer.id) {
            let grid = s.grid(image.grid)
            return PlacementResolver.samplingState(
                PlacementResolver.samplingKey(reference: reference, objectGrid: grid, objectFrame: grid?.frameUID),
                store: workspace.store)
        }
        guard let a = s.annotation(layer.id) else { return .identity }
        let grid = a.grid.flatMap { s.grid($0) }
        switch layer.kind {
        case .geometric:
            let key = PlacementResolver.pointKey(reference: reference, annotationGrid: grid, annotationFrame: a.frameUID)
            guard let key else { return .identity }
            let (mapper, why) = PlacementResolver.pointMapper(key, store: workspace.store)
            if let why { return .refused(why) }
            guard mapper != nil else { return .pending }
            let r = workspace.store.ready(.placement(key), as: PlacementResource.self)
            return .resolved(.identity, summary: r?.summary ?? "resolved transform", isLinear: mapper?.field == nil)
        case .classification:
            return .identity
        default:
            return PlacementResolver.samplingState(
                PlacementResolver.samplingKey(reference: reference, objectGrid: grid, objectFrame: a.frameUID),
                store: workspace.store)
        }
    }
}

/// The settings of one layer.
struct LayerDetail: View {
    let workspace: Workspace
    let stack: LayerStack
    @Bindable var layer: DisplayLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch layer.kind {
            case .image: ImageLayerSettings(workspace: workspace, stack: stack, layer: layer)
            case .segmentation, .instances: SegmentationLayerSettings(workspace: workspace, layer: layer)
            case .probability: ProbabilityLayerSettings(workspace: workspace, layer: layer)
            case .mask: MaskLayerSettings(layer: layer)
            case .geometric: GeometricLayerSettings(workspace: workspace, layer: layer)
            case .classification: ClassificationLayerSettings(workspace: workspace, layer: layer)
            }
            placementSection
        }
    }

    @ViewBuilder
    private var placementSection: some View {
        let state = LayerPlacementInfo.state(workspace: workspace, stack: stack, layer: layer)
        switch state {
        case .identity:
            EmptyView()
        default:
            Divider().padding(.horizontal, 14)
            InspectorSection("Placement") {
                switch state {
                case .resolved(_, let summary, let linear):
                    Label {
                        Text("In another frame, placed through \(summary)\(linear ? "" : " (a displacement field sampled on the reference grid)").")
                    } icon: { Image(systemName: "link") }
                    .font(.callout)
                case .refused(let why):
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                case .pending:
                    HStack { ProgressView().controlSize(.small); Text("Resolving the transform…").foregroundStyle(.secondary) }
                case .identity:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Images

struct ImageLayerSettings: View {
    let workspace: Workspace
    let stack: LayerStack
    @Bindable var layer: DisplayLayer

    var body: some View {
        let info = workspace.summary.image(layer.id)
        let grid = info.flatMap { workspace.summary.grid($0.grid) }
        let histogram = grid.flatMap { workspace.store.ready(.histogram(layer.id, frame: layer.frameIndex(for: $0)), as: HistogramResource.self) }
        let isRGB = info?.valueType == "rgb"
        VStack(alignment: .leading, spacing: 0) {
            if !isRGB {
                InspectorSection("Window", trailing: AnyView(presetMenu(info: info, histogram: histogram))) {
                    HistogramView(histogram: histogram, center: layer.windowCenter, width: layer.windowWidth,
                                  colormap: layer.colormap, invert: layer.invert)
                        .frame(height: 64)
                    let ranges = WindowLevel.sliderRange(histogram, current: (layer.windowCenter, layer.windowWidth))
                    let units = info.flatMap(WindowLevel.units) ?? ""
                    LabeledSlider(title: "Level", value: Binding(get: { layer.windowCenter }, set: {
                        layer.windowCenter = $0
                        layer.windowPreset = nil
                    }), range: ranges.center, units: units)
                    LabeledSlider(title: "Width", value: Binding(get: { layer.windowWidth }, set: {
                        layer.windowWidth = max(1e-6, $0)
                        layer.windowPreset = nil
                    }), range: ranges.width, units: units)
                    if let h = histogram {
                        Text("Range \(Format.number(h.minimum, digits: 1)) to \(Format.number(h.maximum, digits: 1)) \(units) · mean \(Format.number(h.mean, digits: 1)) · SD \(Format.number(h.standardDeviation, digits: 1))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.horizontal, 14)
            }
            InspectorSection("Display") {
                if !isRGB {
                    LabeledRow("Colormap") {
                        Picker("Colormap", selection: $layer.colormap) {
                            ForEach(Colormap.allCases) { map in
                                Text(map.displayName).tag(map)
                            }
                        }
                        .labelsHidden()
                    }
                }
                LabeledRow("Interpolation") {
                    Picker("Interpolation", selection: $layer.interpolation) {
                        Text("Nearest").tag(Interpolation.nearest)
                        Text("Linear").tag(Interpolation.linear)
                        Text("Cubic").tag(Interpolation.cubic)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                LabeledSlider(title: "Opacity", value: $layer.opacity, range: 0...1, percent: true)
                if !isRGB {
                    Toggle("Invert", isOn: $layer.invert)
                }
                if layer !== stack.base && !isRGB {
                    Toggle("Hide values below a threshold", isOn: Binding(get: { layer.threshold != nil }, set: {
                        layer.threshold = $0 ? (histogram.map { $0.percentiles[50] ?? $0.mean } ?? layer.windowCenter - layer.windowWidth / 2) : nil
                    }))
                    if let t = layer.threshold {
                        let r = histogram.map { $0.minimum...max($0.maximum, $0.minimum + 1e-6) } ?? (t - 1000)...(t + 1000)
                        LabeledSlider(title: "Threshold", value: Binding(get: { t }, set: { layer.threshold = $0 }),
                                      range: r, units: info.flatMap(WindowLevel.units) ?? "")
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private func presetMenu(info: ImageInfo?, histogram: HistogramResource?) -> some View {
        Menu {
            if let info {
                let presets = WindowLevel.presets(for: info)
                ForEach(presets) { p in
                    Button("\(p.name)  (W \(Format.number(p.width)) L \(Format.number(p.center)))") { layer.apply(p) }
                }
                if !presets.isEmpty { Divider() }
            }
            Button("Auto (1st–99th percentile)") { if let h = histogram { layer.apply(WindowLevel.automatic(h)) } }
                .disabled(histogram == nil)
            Button("Full Range") { if let h = histogram { layer.apply(WindowLevel.fullRange(h)) } }
                .disabled(histogram == nil)
        } label: {
            Text(layer.windowPreset ?? "Custom").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Window presets")
    }
}

/// A histogram of the frame's values with the window marked, over a
/// colormap bar.
struct HistogramView: View {
    let histogram: HistogramResource?
    let center: Double
    let width: Double
    let colormap: Colormap
    let invert: Bool

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Color(white: 0.1)))
            guard let h = histogram, h.maximum > h.minimum, !h.bins.isEmpty else { return }
            let lo = h.minimum, hi = h.maximum
            func x(_ v: Double) -> CGFloat { CGFloat((v - lo) / (hi - lo)) * size.width }
            // The window.
            let wl = x(center - width / 2), wr = x(center + width / 2)
            let windowRect = CGRect(x: max(0, wl), y: 0, width: max(1, min(size.width, wr) - max(0, wl)), height: size.height)
            context.fill(Path(windowRect), with: .color(Color.accentColor.opacity(0.22)))
            // Bars, log-scaled.
            let peak = log1p(Double(h.bins.max() ?? 1))
            let barHeight = size.height - 8
            var path = Path()
            let n = h.bins.count
            for (i, count) in h.bins.enumerated() where count > 0 {
                let x0 = CGFloat(i) / CGFloat(n) * size.width
                let hgt = CGFloat(log1p(Double(count)) / max(1e-9, peak)) * barHeight
                path.addRect(CGRect(x: x0, y: barHeight - hgt, width: max(1, size.width / CGFloat(n)), height: hgt))
            }
            context.fill(path, with: .color(Color(white: 0.72)))
            // The colormap under the window.
            let steps = 48
            for s in 0..<steps {
                let t = Double(s) / Double(steps - 1)
                var c = colormap.color(at: invert ? 1 - t : t)
                if colormap == .grayscale && invert { c = SIMD3(repeating: 1 - t) }
                let x0 = windowRect.minX + CGFloat(s) / CGFloat(steps) * windowRect.width
                context.fill(Path(CGRect(x: x0, y: size.height - 6, width: windowRect.width / CGFloat(steps) + 0.5, height: 6)),
                             with: .color(Color(red: c.x, green: c.y, blue: c.z)))
            }
            for edge in [wl, wr] where edge >= 0 && edge <= size.width {
                context.stroke(Path { p in p.move(to: CGPoint(x: edge, y: 0)); p.addLine(to: CGPoint(x: edge, y: size.height)) },
                               with: .color(Color.accentColor), lineWidth: 1)
            }
        }
        .overlay {
            if histogram == nil { ProgressView().controlSize(.small) }
        }
        .accessibilityLabel("Histogram of the image values with the window")
    }
}

// MARK: - Annotations

struct SegmentationLayerSettings: View {
    let workspace: Workspace
    @Bindable var layer: DisplayLayer

    var body: some View {
        let info = workspace.summary.annotation(layer.id)
        let res = workspace.store.ready(.segmentation(layer.id), as: SegmentationResource.self)
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection("Display") {
                if layer.kind == .instances {
                    LabeledRow("Colour by") {
                        Picker("Colour by", selection: $layer.colorByInstance) {
                            Text("Instance").tag(true)
                            Text("Class").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                LabeledRow("Style") {
                    Picker("Style", selection: $layer.labelStyle) {
                        Text("Fill").tag(LabelDisplayStyle.fill)
                        Text("Outline").tag(LabelDisplayStyle.outline)
                        Text("Both").tag(LabelDisplayStyle.fillAndOutline)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                LabeledSlider(title: "Fill opacity", value: $layer.opacity, range: 0...1, percent: true)
                LabeledSlider(title: "Outline", value: $layer.outlineWidth, range: 0.5...4, units: "pt")
                if layer.kind == .segmentation {
                    Toggle("Show the ignore region", isOn: $layer.showsIgnoreRegion)
                        .help("Voxels outside what was annotated (ignore id \(info?.ignoreID ?? 65535)) are hatched")
                }
            }
            .controlSize(.small)
            Divider().padding(.horizontal, 14)
            if let info {
                ClassList(workspace: workspace, layer: layer, info: info, voxelCounts: voxelCounts(res))
            }
            if layer.kind == .instances, let map = workspace.store.ready(.instanceMap(layer.id), as: VoxelResource.self) {
                Divider().padding(.horizontal, 14)
                InspectorSection("Instances") {
                    ForEach(Array(map.instances.prefix(50).enumerated()), id: \.offset) { i, inst in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(LabelPalette.color(forClassID: Int(inst.instanceID % 65_000) + 1).color)
                                .frame(width: 10, height: 10)
                            Text("#\(inst.instanceID)").monospacedDigit()
                            Text(className(inst.classID, labelSet: workspace.summary.labelSet)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Format.integer(inst.voxelCount)) vx").foregroundStyle(.secondary).monospacedDigit()
                            if let score = inst.score { Text(Format.number(score, digits: 2)).foregroundStyle(.secondary) }
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        }
    }

    private func voxelCounts(_ res: SegmentationResource?) -> [Int: (UInt64, Double)] {
        guard let res else { return [:] }
        let volume = res.model.geometry.voxelVolume
        var out: [Int: (UInt64, Double)] = [:]
        for (id, s) in res.classStats { out[id] = (s.voxels, Double(s.voxels) * volume) }
        return out
    }
}

/// The classes of an annotation: colour, name, visibility, coverage.
struct ClassList: View {
    let workspace: Workspace
    @Bindable var layer: DisplayLayer
    let info: AnnotationInfo
    /// Voxels and physical volume per class, when known.
    var voxelCounts: [Int: (UInt64, Double)] = [:]

    var body: some View {
        let labels = workspace.summary.labelSet
        InspectorSection("Classes", trailing: AnyView(showButtons)) {
            VStack(spacing: 4) {
                ForEach(info.classIDs, id: \.self) { id in
                    HStack(spacing: 7) {
                        Button { layer.setClass(id, visible: !layer.isClassVisible(id)) } label: {
                            Image(systemName: layer.isClassVisible(id) ? "eye.fill" : "eye.slash")
                                .foregroundStyle(layer.isClassVisible(id) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                                .frame(width: 16)
                        }
                        .buttonStyle(.borderless)
                        RoundedRectangle(cornerRadius: 3).fill(classColor(id, labelSet: labels).color)
                            .frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(className(id, labelSet: labels)).lineLimit(1)
                            HStack(spacing: 4) {
                                Text("\(id)").monospacedDigit()
                                if let (voxels, volume) = voxelCounts[id] {
                                    Text("· \(Format.integer(voxels)) vx · \(Format.number(volume / 1000, digits: 1)) mL")
                                        .monospacedDigit()
                                }
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        coverage(id)
                    }
                    .font(.system(size: 11.5))
                    .opacity(layer.isClassVisible(id) ? 1 : 0.55)
                }
                if info.classIDs.isEmpty {
                    Text("No classes").foregroundStyle(.secondary).font(.callout)
                }
            }
            if !info.unexaminedClassIDs.isEmpty {
                Text("“Can express only”: the annotation can hold the class but it was not looked for, so its absence means nothing.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func coverage(_ id: Int) -> some View {
        let examined = info.isAnnotated(id)
        return Text(examined ? "examined" : "can express only")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(examined ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(examined ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.orange.opacity(0.15))))
            .help(examined ? "Looked for: a voxel without it is an examined absence" : "Not examined: the annotation can express it but nobody looked for it")
    }

    private var showButtons: some View {
        HStack(spacing: 6) {
            Button("Show All") { layer.hiddenClasses = [] }
            Button("Hide All") { layer.hiddenClasses = Set(info.classIDs) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5))
    }
}

struct ProbabilityLayerSettings: View {
    let workspace: Workspace
    @Bindable var layer: DisplayLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection("Display") {
                LabeledSlider(title: "Threshold", value: $layer.probabilityThreshold, range: 0.01...0.99)
                LabeledSlider(title: "Opacity", value: $layer.opacity, range: 0...1, percent: true)
                Toggle("Contour at the threshold", isOn: $layer.showsContour)
                if let t = workspace.summary.annotation(layer.id)?.threshold {
                    Text("Stored threshold \(Format.number(t, digits: 2))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            Divider().padding(.horizontal, 14)
            if let info = workspace.summary.annotation(layer.id) {
                ClassList(workspace: workspace, layer: layer, info: info)
            }
        }
    }
}

struct MaskLayerSettings: View {
    @Bindable var layer: DisplayLayer

    var body: some View {
        InspectorSection("Display") {
            LabeledRow("Style") {
                Picker("Style", selection: $layer.labelStyle) {
                    Text("Fill").tag(LabelDisplayStyle.fill)
                    Text("Outline").tag(LabelDisplayStyle.outline)
                    Text("Both").tag(LabelDisplayStyle.fillAndOutline)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            LabeledSlider(title: "Fill opacity", value: $layer.opacity, range: 0...1, percent: true)
            LabeledSlider(title: "Outline", value: $layer.outlineWidth, range: 0.5...4, units: "pt")
        }
        .controlSize(.small)
    }
}

struct GeometricLayerSettings: View {
    let workspace: Workspace
    @Bindable var layer: DisplayLayer

    var body: some View {
        let info = workspace.summary.annotation(layer.id)
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection("Display") {
                LabeledSlider(title: "Opacity", value: $layer.opacity, range: 0...1, percent: true)
                LabeledSlider(title: "Line width", value: $layer.lineWidth, range: 0.5...4, units: "pt")
                Toggle("Show names", isOn: $layer.showsNames)
                if let items = info?.items {
                    Text("\(items) item\(items == 1 ? "" : "s") · \(info?.space ?? "index") space")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            if let info, !info.classIDs.isEmpty {
                Divider().padding(.horizontal, 14)
                ClassList(workspace: workspace, layer: layer, info: info)
            }
        }
    }
}

struct ClassificationLayerSettings: View {
    let workspace: Workspace
    let layer: DisplayLayer

    var body: some View {
        InspectorSection("Assertions") {
            if let g = workspace.store.ready(.geometry(layer.id), as: GeometryResource.self), case .classification(let c) = g.annotation {
                ClassificationAssertions(classification: c, labelSet: workspace.summary.labelSet)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

struct ClassificationAssertions: View {
    let classification: GeometricAnnotation.Classification
    let labelSet: LabelSetInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(classification.assertions.enumerated()), id: \.offset) { _, a in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(classColor(a.classID, labelSet: labelSet).color).frame(width: 10, height: 10)
                    Text(className(a.classID, labelSet: labelSet))
                    Spacer()
                    Text(a.value >= 0.5 ? "positive" : (a.value <= 0 ? "negative" : Format.number(a.value, digits: 2)))
                        .foregroundStyle(a.value >= 0.5 ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                }
                .font(.system(size: 11.5))
            }
            Text("Scope \(classification.scope)\(classification.isChangeLabel ? " · change between \(classification.comparedTimepoints.joined(separator: " and "))" : "")\(classification.multilabel ? " · multi-label" : "")")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Controls

/// A label and a control on one row.
struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            content
        }
        .font(.system(size: 11.5))
    }
}

/// A slider with its title and value.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var units = ""
    var percent = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: { value = $0 }), in: range)
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 11.5))
    }

    private var text: String {
        if percent { return "\(Int((value * 100).rounded()))%" }
        let span = range.upperBound - range.lowerBound
        let digits = span > 200 ? 0 : (span > 5 ? 1 : 2)
        return Format.number(value, digits: digits) + (units.isEmpty ? "" : " \(units)")
    }
}

// MARK: - 3-D view

/// The 3-D view's settings (shown while it is the active view).
struct VolumeSettings: View {
    let workspace: Workspace

    var body: some View {
        let viewer = workspace.viewer
        InspectorSection("3-D View", trailing: AnyView(Button("Reset") { viewer.volume.resetToken += 1 }
            .buttonStyle(.borderless).font(.system(size: 10.5)))) {
            LabeledRow("Rendering") {
                Picker("Rendering", selection: Binding(get: { viewer.volume.mode }, set: { viewer.volume.mode = $0 })) {
                    Text("DVR").tag(VolumeRenderMode.dvr)
                    Text("MIP").tag(VolumeRenderMode.mip)
                    Text("MinIP").tag(VolumeRenderMode.minip)
                    Text("Average").tag(VolumeRenderMode.average)
                    Text("Isosurface").tag(VolumeRenderMode.isosurface)
                }
                .labelsHidden()
            }
            if viewer.volume.mode == .dvr {
                LabeledRow("Preset") {
                    Picker("Preset", selection: Binding(get: { viewer.volume.preset }, set: { viewer.volume.preset = $0 })) {
                        ForEach(TransferFunctionPreset.allCases) { p in Text(p.displayName).tag(p) }
                    }
                    .labelsHidden()
                }
            }
            if viewer.volume.mode == .isosurface {
                LabeledSlider(title: "Level", value: Binding(get: { viewer.volume.isoValue }, set: { viewer.volume.isoValue = $0 }),
                              range: isoRange)
            }
            LabeledRow("Surfaces") {
                Picker("Surfaces", selection: Binding(get: { viewer.volume.surfaceStyle }, set: { viewer.volume.surfaceStyle = $0 })) {
                    ForEach(SurfaceStyle.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            LabeledSlider(title: "Opacity", value: Binding(get: { viewer.volume.labelOpacity }, set: { viewer.volume.labelOpacity = $0 }),
                          range: 0.05...1, percent: true)
            HStack(spacing: 14) {
                Toggle("Image", isOn: Binding(get: { viewer.volume.showsImage }, set: { viewer.volume.showsImage = $0 }))
                Toggle("Segmentations", isOn: Binding(get: { viewer.volume.showsLabels }, set: { viewer.volume.showsLabels = $0 }))
            }
            HStack(spacing: 14) {
                Toggle("Meshes", isOn: Binding(get: { viewer.volume.showsMeshes }, set: { viewer.volume.showsMeshes = $0 }))
                Toggle("Planes", isOn: Binding(get: { viewer.volume.showsPlanes }, set: { viewer.volume.showsPlanes = $0 }))
            }
            Toggle("Clipping box", isOn: Binding(get: { viewer.volume.clipEnabled }, set: { viewer.volume.clipEnabled = $0 }))
            if viewer.volume.clipEnabled {
                ForEach(0..<3, id: \.self) { axis in
                    ClipAxisRow(workspace: workspace, axis: axis)
                }
            }
        }
        .controlSize(.small)
    }

    private var isoRange: ClosedRange<Double> {
        guard let base = workspace.primary.base, let info = workspace.summary.image(base.id),
              let grid = workspace.summary.grid(info.grid),
              let h = workspace.store.ready(.histogram(base.id, frame: base.frameIndex(for: grid)), as: HistogramResource.self)
        else { return -1000...3000 }
        return h.minimum...max(h.maximum, h.minimum + 1e-6)
    }
}

/// The lower and upper clip planes along one index axis of the reference grid.
struct ClipAxisRow: View {
    let workspace: Workspace
    let axis: Int

    var body: some View {
        let viewer = workspace.viewer
        let name = axisName
        VStack(alignment: .leading, spacing: 2) {
            LabeledSlider(title: "\(name) from", value: Binding(get: { viewer.volume.clipLower[axis] },
                                                                set: { viewer.volume.clipLower[axis] = min($0, viewer.volume.clipUpper[axis] - 0.01) }),
                          range: 0...1, percent: true)
            LabeledSlider(title: "\(name) to", value: Binding(get: { viewer.volume.clipUpper[axis] },
                                                              set: { viewer.volume.clipUpper[axis] = max($0, viewer.volume.clipLower[axis] + 0.01) }),
                          range: 0...1, percent: true)
        }
    }

    /// The anatomical direction the index axis runs along (`S–I`).
    private var axisName: String {
        guard let grid = workspace.referenceGrid(of: workspace.primary) else { return ["k0", "k1", "k2"][axis] }
        let d = grid.axisDirections[axis]
        let cs = grid.coordinateSystem
        let a = cs.label(forWorldDirection: -d, threshold: 0.5), b = cs.label(forWorldDirection: d, threshold: 0.5)
        return "\(a)–\(b)"
    }
}
