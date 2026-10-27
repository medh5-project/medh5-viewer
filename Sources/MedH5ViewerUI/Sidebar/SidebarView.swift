import SwiftUI
import AppKit
import MedH5Kit

/// The sample's contents as an outline: header, timepoints → grids → images
/// and annotations, annotations across timepoints, transforms, the label
/// set, curation records. Selecting a row shows it in the inspector's Info
/// tab; double-clicking an image makes it the base layer; the eye adds or
/// removes an overlay.
struct SidebarView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        List(selection: Binding(get: { workspace.selection }, set: { id in
            workspace.select(id)
            if id != nil { workspace.inspectorTab = .info }
        })) {
            SidebarHeader(workspace: workspace)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            ForEach(workspace.sections) { section in
                Section(section.title) {
                    ForEach(section.nodes) { node in
                        SidebarNodeView(node: node, workspace: workspace)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let node = workspace.findNode(id) {
                SidebarContextMenu(node: node, workspace: workspace)
            }
        } primaryAction: { ids in
            guard let id = ids.first, let node = workspace.findNode(id) else { return }
            switch node.kind {
            case .image(let image): workspace.showAsBase(image)
            case .annotation(let a) where node.isDisplayable: workspace.toggleOverlay(a)
            default:
                if node.children != nil {
                    if workspace.expanded.contains(node.id) { workspace.expanded.remove(node.id) } else { workspace.expanded.insert(node.id) }
                }
            }
        }
    }
}

/// One node and, expanded, its children.
struct SidebarNodeView: View {
    let node: SidebarNode
    let workspace: Workspace

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: Binding(
                get: { workspace.expanded.contains(node.id) },
                set: { if $0 { workspace.expanded.insert(node.id) } else { workspace.expanded.remove(node.id) } })) {
                ForEach(children) { child in
                    AnyView(SidebarNodeView(node: child, workspace: workspace))
                }
            } label: {
                SidebarRow(node: node, workspace: workspace)
            }
            .tag(node.id)
        } else {
            SidebarRow(node: node, workspace: workspace)
                .tag(node.id)
        }
    }
}

/// A row: icon (or colour swatch), title, subtitle, coverage badge, eye.
struct SidebarRow: View {
    let node: SidebarNode
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 7) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(node.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if let objectID = node.objectID, workspace.primary.base?.id == objectID {
                Text("BASE")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.6), lineWidth: 0.75))
                    .help("The base image of the main views")
            }
            if let badge = node.badge { coverageBadge(badge) }
            if node.isDisplayable, let objectID = node.objectID { eyeButton(objectID) }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if let color = node.color {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.color)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .frame(width: 13, height: 13)
                .frame(width: 18)
        } else {
            Image(systemName: node.symbol)
                .foregroundStyle(node.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .frame(width: 18)
        }
    }

    private func coverageBadge(_ text: String) -> some View {
        let parts = text.split(separator: "/")
        let complete = parts.count == 2 && parts[0] == parts[1]
        return Text(text)
            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(complete ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.quaternary))
            .help(complete ? "Every class it can express was examined"
                : "\(parts.first ?? "") of \(parts.last ?? "") classes examined; the others can be expressed but were not looked for")
    }

    private func eyeButton(_ id: String) -> some View {
        let inStack = workspace.activeStack.contains(id)
        let shown = workspace.isShown(id)
        return Button {
            workspace.toggleOverlay(id)
        } label: {
            Image(systemName: shown ? "eye.fill" : (inStack ? "eye.slash" : "eye"))
                .foregroundStyle(shown ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(shown ? "Remove from the view" : "Show in the view")
        .accessibilityLabel(shown ? "Hide \(id)" : "Show \(id)")
    }
}

/// Show, overlay, export (later), remove (later), reveal attributes.
struct SidebarContextMenu: View {
    let node: SidebarNode
    let workspace: Workspace

    var body: some View {
        switch node.kind {
        case .image(let id):
            Button("Show as Base Image") { workspace.showAsBase(id) }
            Button(workspace.activeStack.contains(id) ? "Remove Overlay" : "Add as Overlay") { workspace.toggleOverlay(id) }
                .disabled(workspace.activeStack.base?.id == id)
            Divider()
            Button("Export as NIfTI…") {}.disabled(true)
            Button("Remove Image…") {}.disabled(true)
        case .annotation(let id):
            if node.isDisplayable {
                Button(workspace.activeStack.contains(id) ? "Hide Overlay" : "Show as Overlay") { workspace.toggleOverlay(id) }
            }
            Divider()
            Button("Export as NIfTI…") {}.disabled(true)
            Button("Remove Annotation…") {}.disabled(true)
        default:
            EmptyView()
        }
        if workspace.objectPath(forNode: node.id) != nil {
            Divider()
            Button("Reveal Attributes") { workspace.revealAttributes(node.id) }
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.objectID ?? node.title, forType: .string)
        }
    }
}

/// Subject, sample, format version, profiles, content id, and warnings.
struct SidebarHeader: View {
    let workspace: Workspace

    var body: some View {
        let s = workspace.summary
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(s.identity.subjectID.isEmpty ? "No subject id" : s.identity.subjectID)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text("medh5 \(s.formatVersion)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(s.support == .projection ? Color.orange : Color.accentColor))
                    .help(s.support == .projection ? "A later format minor, read as a projection" : "Format version \(s.formatVersion)")
            }
            Text("Sample \(s.identity.sampleID)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !s.profiles.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(s.profiles, id: \.self) { profile in
                        Text(profile)
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let id = s.contentID {
                HStack(spacing: 4) {
                    Image(systemName: "number").imageScale(.small).foregroundStyle(.tertiary)
                    Text(Format.shortDigest(id))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help(id)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the content id")
                }
            }
            statusChips
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusChips: some View {
        let chips = chipList
        if !chips.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    Label(chip.text, systemImage: chip.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(chip.color.opacity(0.16)))
                        .foregroundStyle(chip.color)
                        .help(chip.help)
                }
            }
        }
    }

    private struct Chip {
        var text: String
        var symbol: String
        var color: Color
        var help: String
    }

    private var chipList: [Chip] {
        var chips: [Chip] = []
        let s = workspace.summary
        if s.support == .projection {
            chips.append(Chip(text: "Projection", symbol: "arrow.up.forward.square", color: .orange,
                              help: "A later format minor: what this engine knows is shown; the file opens read-only"))
        }
        switch workspace.verification {
        case .running:
            chips.append(Chip(text: "Verifying…", symbol: "hourglass", color: .secondary, help: "Checking every digest and the content id"))
        case .passed:
            chips.append(Chip(text: "Verified", symbol: "checkmark.shield.fill", color: .green, help: "Every digest and the content id match"))
        case .failed(let why):
            chips.append(Chip(text: "Integrity failed", symbol: "xmark.shield.fill", color: .red, help: why))
        case .error(let why):
            chips.append(Chip(text: "Not verified", symbol: "questionmark.diamond", color: .orange, help: why))
        case .notStarted:
            break
        }
        if s.deidentification == nil {
            chips.append(Chip(text: "Not de-identified", symbol: "eye.trianglebadge.exclamationmark", color: .orange,
                              help: "No de-identification record: treat the file as identifying"))
        }
        if !s.unreadable.isEmpty {
            chips.append(Chip(text: "\(s.unreadable.count) unreadable", symbol: Symbols.warning, color: .orange,
                              help: "Objects the engine could not read"))
        }
        if workspace.isReadOnly && s.support != .projection {
            chips.append(Chip(text: "Read-only", symbol: "lock.fill", color: .secondary, help: "This document cannot be edited"))
        }
        return chips
    }
}

/// Lays out views left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 260
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            line = max(line, s.height)
        }
        return CGSize(width: min(width, maxX), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
