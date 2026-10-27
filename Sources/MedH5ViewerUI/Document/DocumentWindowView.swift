import SwiftUI
import MedH5Kit
import MedH5Render

/// The document window's content: sidebar, viewer and inspector, with the
/// toolbar (layout, tools, timepoint, window preset, 3-D, inspector).
struct DocumentWindowView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { workspace.showsSidebar ? .all : .detailOnly },
            set: { workspace.showsSidebar = $0 != .detailOnly })) {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
        } detail: {
            VStack(spacing: 0) {
                ForEach(workspace.readOnlyReasons, id: \.self) { reason in
                    ReadOnlyBanner(reason: reason)
                    Divider()
                }
                if workspace.isSaving {
                    SavingBanner()
                    Divider()
                }
                ViewerView(workspace: workspace)
            }
            .inspector(isPresented: $workspace.showsInspector) {
                InspectorView(workspace: workspace)
                    .inspectorColumnWidth(min: 270, ideal: 310, max: 460)
            }
        }
        .toolbar { DocumentToolbar(workspace: workspace) }
        .alert(item: $workspace.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

/// Why the document opened read-only.
struct ReadOnlyBanner: View {
    let reason: ReadOnlyReason

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reason.symbol)
                .foregroundStyle(tint)
                .font(.system(size: 14, weight: .semibold))
            Text(reason.message)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(reason.message)
            Text("READ-ONLY")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }

    private var tint: Color {
        switch reason {
        case .verificationFailed: return .red
        case .projection: return .orange
        case .collectionMember: return .secondary
        }
    }
}

struct SavingBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Saving — the engine amends the file and validates it…").font(.callout)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// The window's toolbar.
struct DocumentToolbar: ToolbarContent {
    let workspace: Workspace

    var body: some ToolbarContent {
        let viewer = workspace.viewer
        ToolbarItem(placement: .navigation) {
            Picker("Layout", selection: Binding(get: { viewer.layout }, set: { workspace.setLayout($0) })) {
                ForEach(ViewerLayout.allCases) { layout in
                    Label(layout.title, systemImage: layout.symbol).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Layout (1–5)")
        }
        ToolbarItem(placement: .navigation) {
            Picker("Tool", selection: Binding(get: { viewer.tool }, set: { viewer.tool = $0 })) {
                ForEach(ViewerTool.viewingTools) { tool in
                    Label(tool.title, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Tool: Navigate (V), Window/Level (W), Pan (H), Zoom (Z)")
        }
        ToolbarItem(placement: .navigation) {
            EditingToolPicker(workspace: workspace)
        }
        ToolbarItem(placement: .principal) {
            TimepointMenu(workspace: workspace)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            WindowPresetMenu(workspace: workspace)
            VolumeMenu(workspace: workspace)
            Button {
                workspace.showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(workspace.showsInspector ? "Hide the inspector" : "Show the inspector")
        }
    }
}

/// The timepoint the main views show.
struct TimepointMenu: View {
    let workspace: Workspace

    var body: some View {
        let ids = workspace.timepointIDs
        let current = workspace.timepoint(of: workspace.primary)
        Menu {
            ForEach(ids, id: \.self) { id in
                Button {
                    workspace.showTimepoint(id)
                } label: {
                    if id == current {
                        Label(workspace.timepointTitle(id), systemImage: "checkmark")
                    } else {
                        Text(workspace.timepointTitle(id))
                    }
                }
            }
        } label: {
            Label(current.map(workspace.timepointTitle) ?? "No timepoint", systemImage: "calendar")
                .labelStyle(.titleAndIcon)
        }
        .disabled(ids.count < 2)
        .help("The timepoint shown (⌘] and ⌘[ step through them)")
    }
}

/// Window presets of the base image.
struct WindowPresetMenu: View {
    let workspace: Workspace

    var body: some View {
        let base = workspace.activeStack.base
        let info = base.flatMap { workspace.summary.image($0.id) }
        Menu {
            if let base, let info {
                ForEach(WindowLevel.presets(for: info)) { p in
                    Button("\(p.name) — W \(Format.number(p.width)) L \(Format.number(p.center))") { base.apply(p) }
                }
                Divider()
                Button("Auto Window") {
                    if let grid = workspace.summary.grid(info.grid),
                       let h = workspace.store.ready(.histogram(base.id, frame: base.frameIndex(for: grid)), as: HistogramResource.self) {
                        base.apply(WindowLevel.automatic(h))
                    }
                }
            }
        } label: {
            Label("Window", systemImage: "circle.lefthalf.filled.righthalf.striped.horizontal")
        }
        .disabled(info == nil || info?.valueType == "rgb")
        .help("Window/level presets")
    }
}

/// The 3-D view's rendering mode, transfer function preset and contents.
struct VolumeMenu: View {
    let workspace: Workspace

    var body: some View {
        let viewer = workspace.viewer
        Menu {
            Picker("Rendering", selection: Binding(get: { viewer.volume.mode }, set: { viewer.volume.mode = $0 })) {
                Text("Volume Rendering (DVR)").tag(VolumeRenderMode.dvr)
                Text("Maximum Intensity (MIP)").tag(VolumeRenderMode.mip)
                Text("Minimum Intensity (MinIP)").tag(VolumeRenderMode.minip)
                Text("Average Intensity").tag(VolumeRenderMode.average)
                Text("Isosurface").tag(VolumeRenderMode.isosurface)
            }
            .pickerStyle(.inline)
            Picker("Transfer Function", selection: Binding(get: { viewer.volume.preset }, set: {
                viewer.volume.preset = $0
                viewer.volume.mode = .dvr
            })) {
                ForEach(TransferFunctionPreset.allCases) { p in Text(p.displayName).tag(p) }
            }
            Divider()
            Toggle("Show Image", isOn: Binding(get: { viewer.volume.showsImage }, set: { viewer.volume.showsImage = $0 }))
            Toggle("Show Segmentations", isOn: Binding(get: { viewer.volume.showsLabels }, set: { viewer.volume.showsLabels = $0 }))
            Picker("Segmentation Surfaces", selection: Binding(get: { viewer.volume.surfaceStyle }, set: { viewer.volume.surfaceStyle = $0 })) {
                ForEach(SurfaceStyle.allCases) { s in Text(s.title).tag(s) }
            }
            Toggle("Show Meshes", isOn: Binding(get: { viewer.volume.showsMeshes }, set: { viewer.volume.showsMeshes = $0 }))
            Toggle("Show Slice Planes", isOn: Binding(get: { viewer.volume.showsPlanes }, set: { viewer.volume.showsPlanes = $0 }))
            Toggle("Clipping Box", isOn: Binding(get: { viewer.volume.clipEnabled }, set: { viewer.volume.clipEnabled = $0 }))
            Divider()
            Button("Reset 3-D View") { viewer.volume.resetToken += 1 }
        } label: {
            Label("3-D", systemImage: "cube.transparent")
        }
        .help("3-D rendering")
    }
}
