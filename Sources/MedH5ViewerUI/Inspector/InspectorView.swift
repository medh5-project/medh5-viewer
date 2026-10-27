import SwiftUI
import MedH5Kit

/// The inspector: Layers, Segment editor, Annotations, Measurements, Info.
struct InspectorView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabBar(selection: $workspace.inspectorTab)
            Divider()
            Group {
                switch workspace.inspectorTab {
                case .layers: LayersInspector(workspace: workspace)
                case .info: InfoInspector(workspace: workspace)
                case .segmentEditor, .annotations, .measurements: LaterPhasePlaceholder(tab: workspace.inspectorTab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The tab icons across the top of the inspector.
struct InspectorTabBar: View {
    @Binding var selection: InspectorTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// The tabs of the editing phase.
struct LaterPhasePlaceholder: View {
    let tab: InspectorTab

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: tab.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(tab.title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 230)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    private var message: String {
        switch tab {
        case .segmentEditor: return "Painting, filling and refining segmentations comes with the editing tools in a later version."
        case .annotations: return "Drawing and editing boxes, points, polylines and contours comes in a later version."
        case .measurements: return "Rulers, angles and ROI statistics come in a later version."
        default: return ""
        }
    }
}

/// A titled group in an inspector tab.
struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Key–value rows, labels right-aligned in one column.
struct KeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .frame(minWidth: 70, alignment: .trailing)
                    Text(row.1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 11.5))
    }
}
