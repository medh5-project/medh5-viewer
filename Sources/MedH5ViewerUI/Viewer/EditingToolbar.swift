import SwiftUI

/// The measuring, segmentation and annotation tools in the window's
/// toolbar: each disabled, with the reason as its tooltip, when it cannot
/// be used now (a read-only document, nothing suitable active).
struct EditingToolPicker: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 6) {
            group(ViewerTool.measuringTools)
            group(ViewerTool.segmentationTools)
            group(ViewerTool.annotationTools)
        }
    }

    private func group(_ tools: [ViewerTool]) -> some View {
        let session = workspace.editing
        let viewer = workspace.viewer
        let _ = session.revision
        return ControlGroup {
            ForEach(tools) { tool in
                let availability = session.availability(tool)
                Toggle(isOn: Binding(get: { viewer.tool == tool }, set: { on in
                    if on {
                        session.select(tool)
                    } else if viewer.tool == tool {
                        session.select(.navigate)
                    }
                })) {
                    Label(tool.title, systemImage: tool.symbol)
                }
                .disabled(!availability.isAvailable)
                .help(availability.reason.map { "\(tool.title) (\(tool.keyLabel)) — \($0)" } ?? tool.help)
                .accessibilityLabel(tool.title)
            }
        }
        .labelStyle(.iconOnly)
    }
}
