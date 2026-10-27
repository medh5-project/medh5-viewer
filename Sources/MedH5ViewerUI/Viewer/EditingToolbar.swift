import SwiftUI

/// The measuring, segmentation and annotation tools in the window's toolbar:
/// one menu, so the toolbar keeps the timepoint, presets, 3-D and inspector
/// items in a window of ordinary width (ten buttons pushed them into the
/// overflow). Its icon is the editing tool in use, tinted; each item names
/// its key, and one that cannot be used now (a read-only document, nothing
/// suitable active) is disabled with the reason as its tooltip. The keys,
/// the Tools menu and the inspector's tabs reach the same tools.
struct EditingToolPicker: View {
    let workspace: Workspace

    var body: some View {
        let viewer = workspace.viewer
        let _ = workspace.editing.revision
        let active = ViewerTool.editingTools.contains(viewer.tool) ? viewer.tool : nil
        Menu {
            section("Measure", ViewerTool.measuringTools)
            section("Segment", ViewerTool.segmentationTools)
            section("Annotate", ViewerTool.annotationTools)
        } label: {
            Label(active?.title ?? "Editing Tools", systemImage: active?.symbol ?? "pencil.and.ruler")
                .foregroundStyle(active == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        }
        .help(active.map { "\($0.title) (\($0.keyLabel)) — the measuring, segmentation and annotation tools" }
              ?? "Measuring, segmentation and annotation tools")
    }

    private func section(_ title: String, _ tools: [ViewerTool]) -> some View {
        let session = workspace.editing
        let viewer = workspace.viewer
        return Section(title) {
            ForEach(tools) { tool in
                let availability = session.availability(tool)
                Toggle(isOn: Binding(get: { viewer.tool == tool }, set: { on in
                    session.select(on ? tool : .navigate)
                })) {
                    Label("\(tool.title)  (\(tool.keyLabel))", systemImage: tool.symbol)
                }
                .disabled(!availability.isAvailable)
                .help(availability.reason.map { "\(tool.title) — \($0)" } ?? tool.help)
            }
        }
    }
}
