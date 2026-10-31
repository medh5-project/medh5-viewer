import SwiftUI
import MedH5Kit
import MedH5Render

/// The viewer: the layout's viewports, the frame controls (plane, compared
/// timepoint, time, channel) when they apply, and the status bar.
struct ViewerView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            layoutContent
                .background(Color(white: 0.20), ignoresSafeAreaEdges: [])
                .environment(\.colorScheme, .dark)
            if ViewerControls.isNeeded(workspace) {
                Divider()
                ViewerControls(workspace: workspace)
            }
            Divider()
            StatusBarView(workspace: workspace)
        }
    }

    @ViewBuilder
    private var layoutContent: some View {
        let viewer = workspace.viewer
        switch viewer.layout {
        case .single:
            cell(.slice(viewer.singlePlane))
        case .oneByThree:
            HStack(spacing: 1) {
                cell(.slice(.axial))
                cell(.slice(.coronal))
                cell(.slice(.sagittal))
            }
        case .twoByTwo:
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    cell(.slice(.axial))
                    cell(.slice(.coronal))
                }
                HStack(spacing: 1) {
                    cell(.slice(.sagittal))
                    cell(.volume)
                }
            }
        case .volume:
            cell(.volume)
        case .compare:
            HStack(spacing: 1) {
                cell(.compareLeft)
                cell(.compareRight)
            }
        }
    }

    private func cell(_ id: ViewportID) -> some View {
        ViewportCell(workspace: workspace, id: id)
    }
}

/// One viewport in the layout, with the active-view outline.
struct ViewportCell: View {
    let workspace: Workspace
    let id: ViewportID

    var body: some View {
        ViewportRepresentable(view: container)
            .accessibilityElement()
            .accessibilityLabel(accessibilityTitle)
    }

    private var container: ViewportContainerView {
        switch id {
        case .volume:
            return workspace.viewports.volume { VolumeViewportController(workspace: workspace) }.container
        default:
            return workspace.viewports.slice(id) { SliceViewportController(id: id, workspace: workspace) }.container
        }
    }

    private var accessibilityTitle: String {
        switch id {
        case .slice(let p): return "\(p.title) view"
        case .volume: return "3-D view"
        case .compareLeft: return "Compare, left"
        case .compareRight: return "Compare, right"
        }
    }
}

/// The plane picker (single view, Compare), the compared timepoint, and the
/// time and channel of the base image.
struct ViewerControls: View {
    let workspace: Workspace

    static func isNeeded(_ w: Workspace) -> Bool {
        let layout = w.viewer.layout
        let planar = w.referenceGrid(of: w.primary)?.is2D == true
        return (layout == .single && !planar) || layout == .compare || frameAxes(w).time != nil || frameAxes(w).channel != nil
    }

    /// The base image's time axis length (with values) and channel names.
    static func frameAxes(_ w: Workspace) -> (time: (count: Int, values: [Double]?, units: String?)?, channel: [String]?) {
        guard let base = w.primary.base, let info = w.summary.image(base.id), let grid = w.summary.grid(info.grid) else {
            return (nil, nil)
        }
        var time: (Int, [Double]?, String?)?
        if let t = grid.timeAxis, grid.shape[t] > 1 { time = (grid.shape[t], grid.timeValues, grid.timeUnits) }
        var channel: [String]?
        if let c = grid.channelAxis, grid.shape[c] > 1, !ImageFrames.isColorInfo(info, grid: grid) {
            channel = (0..<grid.shape[c]).map { info.channelNames?[safe: $0] ?? "Channel \($0 + 1)" }
        }
        return (time, channel)
    }

    var body: some View {
        let viewer = workspace.viewer
        // A 2-D image shows its own plane only: no plane to pick.
        let planar = workspace.referenceGrid(of: workspace.primary)?.is2D == true
        HStack(spacing: 16) {
            if viewer.layout == .single && !planar {
                planePicker(selection: Binding(get: { viewer.singlePlane }, set: { viewer.singlePlane = $0 }))
            }
            if viewer.layout == .compare {
                if !planar {
                    planePicker(selection: Binding(get: { viewer.comparePlane }, set: { viewer.comparePlane = $0 }))
                }
                compareTimepoints
            }
            let axes = Self.frameAxes(workspace)
            if let time = axes.time, let base = workspace.primary.base {
                HStack(spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(base.timeIndex) }, set: { base.timeIndex = Int($0.rounded()) }),
                           in: 0...Double(max(1, time.count - 1)), step: 1)
                        .frame(width: 180)
                    let value = time.values?[safe: base.timeIndex].map { "\(Format.number($0)) \(time.units ?? "")" }
                    Text(value ?? "\(base.timeIndex + 1) of \(time.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .leading)
                }
            }
            if let channels = axes.channel, let base = workspace.primary.base {
                Picker("Channel", selection: Binding(get: { base.channelIndex }, set: { base.channelIndex = $0 })) {
                    ForEach(Array(channels.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
                }
                .fillsWidth()
                .frame(maxWidth: 200)
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func planePicker(selection: Binding<ViewPlane>) -> some View {
        Picker("Plane", selection: selection) {
            ForEach(ViewPlane.allCases, id: \.self) { p in Text(p.title).tag(p) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fillsWidth()
        .frame(width: 230)
    }

    @ViewBuilder
    private var compareTimepoints: some View {
        let ids = workspace.timepointIDs
        if ids.count > 1, let compare = workspace.compare {
            HStack(spacing: 6) {
                Text(workspace.timepoint(of: workspace.primary).map(workspace.timepointTitle) ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
                Picker("Compared timepoint", selection: Binding(
                    get: { workspace.timepoint(of: compare) ?? "" },
                    set: { workspace.setCompareTimepoint($0) })) {
                    ForEach(ids, id: \.self) { Text(workspace.timepointTitle($0)).tag($0) }
                }
                .labelsHidden()
                .fillsWidth()
                .frame(maxWidth: 200)
                linkLabel
            }
        } else {
            Text("Compare needs a second timepoint").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var linkLabel: some View {
        switch workspace.compareMapping()?.link {
        case .registered(let s)?:
            Label("Linked through \(s)", systemImage: "link").foregroundStyle(.secondary).lineLimit(1)
        case .notRegistered?:
            Label("Not registered — linked by voxel index", systemImage: "link.badge.plus")
                .foregroundStyle(.orange).lineLimit(1)
        case .pending?:
            ProgressView().controlSize(.mini)
        case nil:
            EmptyView()
        }
    }
}

/// The status bar: world position with its coordinate system, voxel index,
/// raw and physical value with units, classes under the pointer, timepoint.
struct StatusBarView: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 14) {
            if let h = workspace.viewer.hover {
                field("scope", "\(Format.point(h.world)) \(h.units) · \(h.coordinateSystem)")
                if let k = h.voxel {
                    let index = h.spatialRank == 2 ? "\(k.y), \(k.z)" : "\(k.x), \(k.y), \(k.z)"
                    field("square.grid.3x3", "[\(index)]")
                }
                if let raw = h.rawValue {
                    let units = h.valueUnits.map { " \($0)" } ?? ""
                    if h.isRescaled, let phys = h.physicalValue {
                        field("waveform.path.ecg", "\(Format.number(phys, digits: 2))\(units)  (raw \(Format.number(raw, digits: 3)))")
                    } else {
                        field("waveform.path.ecg", "\(Format.number(raw, digits: 3))\(units)")
                    }
                }
                ForEach(Array(h.labels.enumerated()), id: \.offset) { _, hit in
                    field("tag", "\(hit.annotation): \(hit.classes.joined(separator: ", "))")
                }
                Spacer(minLength: 8)
                if let tp = h.timepoint { field("calendar", workspace.timepointTitle(tp)) }
            } else {
                Text("Move the pointer over an image to read its position and value")
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
            }
            storeStatus
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }

    private func field(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.secondary).imageScale(.small)
            Text(text).foregroundStyle(.primary)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var storeStatus: some View {
        let store = workspace.store
        let pending = store.pendingKeys.count
        HStack(spacing: 4) {
            if pending > 0 {
                ProgressView().controlSize(.mini)
                Text("Loading \(pending)…").foregroundStyle(.secondary)
            }
            Image(systemName: "memorychip").foregroundStyle(.secondary).imageScale(.small)
            Text(Format.bytes(store.totalBytes)).foregroundStyle(.secondary)
        }
        .fixedSize()
        .help("Memory held by loaded volumes and textures (budget \(Format.bytes(Preferences.memoryBudgetBytes)))")
    }
}
