import SwiftUI
import AppKit
import MedH5Kit

/// The sample's contents as an outline: header, unsaved changes,
/// timepoints → grids → images and annotations, annotations across
/// timepoints, transforms, the label set, curation records. Selecting a row
/// shows it in the inspector's Info tab; double-clicking an image makes it
/// the base layer, the label set opens its editor, the clinical history its
/// window, a curation record the document editor; the eye adds or removes
/// an overlay.
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
            PendingChangesSection(workspace: workspace)
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
            case .labelSet, .labelClass: workspace.document?.showPanel(.labelSet)
            case .clinical: workspace.document?.showPanel(.clinical)
            case .quality: workspace.document?.showDocumentEditor(page: .quality)
            case .deidentification: workspace.document?.showDocumentEditor(page: .deidentification)
            case .provenance: workspace.document?.showDocumentEditor(page: .outline)
            default:
                if node.children != nil {
                    if workspace.expanded.contains(node.id) { workspace.expanded.remove(node.id) } else { workspace.expanded.insert(node.id) }
                }
            }
        }
        .onAppear { workspace.auxiliary.observe(workspace.document?.undoManager) }
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
        let removed = isRemoved
        HStack(spacing: 7) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .strikethrough(removed)
                    .foregroundStyle(removed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if removed {
                    Text("removed when you save")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                } else if let subtitle = node.subtitle {
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

    /// The object is removed in the pending edits.
    private var isRemoved: Bool {
        let edits = workspace.pendingEdits
        switch node.kind {
        case .image(let id): return edits.removedImages.contains(id)
        case .annotation(let id): return edits.removedAnnotations.contains(id)
        case .transform(let id): return edits.removedTransforms.contains(id)
        default: return false
        }
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

/// Show, overlay, export as NIfTI, remove (a pending edit, undoable;
/// refused when the format forbids it, confirmed when it reaches further),
/// open an editor, reveal attributes.
struct SidebarContextMenu: View {
    let node: SidebarNode
    let workspace: Workspace

    var body: some View {
        let edits = workspace.pendingEdits
        let editable = !workspace.isReadOnly && workspace.amendableURL != nil
        switch node.kind {
        case .image(let id):
            Button("Show as Base Image") { workspace.showAsBase(id) }
            Button(workspace.activeStack.contains(id) ? "Remove Overlay" : "Add as Overlay") { workspace.toggleOverlay(id) }
                .disabled(workspace.activeStack.base?.id == id)
            Divider()
            Button("Export as NIfTI…") { workspace.document?.exportNIfTI(objectID: id) }
                .disabled(!exportable(id))
            Button("Remove Image…") { workspace.document?.requestRemoval(.image, id) }
                .disabled(!editable || edits.removedImages.contains(id))
        case .annotation(let id):
            if node.isDisplayable {
                Button(workspace.activeStack.contains(id) ? "Hide Overlay" : "Show as Overlay") { workspace.toggleOverlay(id) }
            }
            Divider()
            Button("Export as NIfTI…") { workspace.document?.exportNIfTI(objectID: id) }
                .disabled(!exportable(id))
            Button("Remove Annotation…") { workspace.document?.requestRemoval(.annotation, id) }
                .disabled(!editable || edits.removedAnnotations.contains(id))
        case .transform(let id):
            Button("Remove Transform…") { workspace.document?.requestRemoval(.transform, id) }
                .disabled(!editable || edits.removedTransforms.contains(id))
        case .labelSet, .labelClass:
            Button("Open Label Set Editor") { workspace.document?.showPanel(.labelSet) }
        case .clinical:
            Button("Open Clinical History") { workspace.document?.showPanel(.clinical) }
        case .quality:
            Button("Edit Quality Records…") { workspace.document?.showDocumentEditor(page: .quality) }
        case .deidentification:
            Button("Edit De-identification…") { workspace.document?.showDocumentEditor(page: .deidentification) }
        case .timepoint:
            Button("Edit Timepoints…") { workspace.document?.showDocumentEditor(page: .timepoints) }
        case .provenance:
            Button("Show in the Document Outline") { workspace.document?.showDocumentEditor(page: .outline) }
        case .index:
            Button("Build Sampling Index…") { workspace.document?.beginStorageTool(.index) }
                .disabled(!editable)
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

    private func exportable(_ id: String) -> Bool {
        if case .success = NIfTIExport.object(id, in: workspace.summary, edits: workspace.pendingEdits) { return true }
        return false
    }
}

/// What the pending edits hold, as sidebar rows.
enum PendingChangeList {
    struct Item: Identifiable, Hashable {
        enum Kind: Hashable {
            case addedImage(String), addedGrid(String), addedSegmentation(String)
            case removedImage(String), removedAnnotation(String), removedTransform(String)
            case editedSegmentation(String), newSegmentation(String), annotation(String), imageAttributes(String)
            case document, labelSet
        }

        var kind: Kind
        var title: String
        var subtitle: String
        var symbol: String
        var id: String { "pending:\(kind)" }

        var isAddition: Bool {
            switch kind {
            case .addedImage, .addedSegmentation: return true
            default: return false
            }
        }
    }

    /// A workspace's rows, against the saved file (its summary also lists
    /// what the editing tools made and has not been saved).
    @MainActor
    static func items(of workspace: Workspace) -> [Item] {
        items(workspace.pendingEdits, summary: workspace.file.summary)
    }

    static func items(_ e: PendingEdits, summary: SampleSummary) -> [Item] {
        var out: [Item] = []
        if e.document != nil {
            out.append(Item(kind: .document, title: "Document", subtitle: "edited", symbol: "doc.text"))
        }
        switch e.labelSet {
        case .set?: out.append(Item(kind: .labelSet, title: "Label set", subtitle: "edited", symbol: Symbols.labelSet))
        case .remove?: out.append(Item(kind: .labelSet, title: "Label set", subtitle: "removed", symbol: Symbols.labelSet))
        case nil: break
        }
        for (id, g) in e.newGrids.sorted(by: { $0.key < $1.key }) {
            out.append(Item(kind: .addedGrid(id), title: id, subtitle: "new grid · \(Format.shape(g.spatialShape))\(g.timepoint.map { " · \($0)" } ?? "")",
                            symbol: Symbols.grid))
        }
        for (id, image) in e.newImages.sorted(by: { $0.key < $1.key }) {
            out.append(Item(kind: .addedImage(id), title: id,
                            subtitle: "new \(image.options.modality) image on \(image.grid)\(image.source.map { " · from \($0)" } ?? "")",
                            symbol: "plus.square.on.square"))
        }
        for (id, seg) in e.importedSegmentations.sorted(by: { $0.key < $1.key }) {
            out.append(Item(kind: .addedSegmentation(id), title: id,
                            subtitle: "new segmentation on \(seg.grid) · \(seg.options.classIDs?.count ?? 0) classes",
                            symbol: "plus.square.on.square"))
        }
        for id in e.newSegmentations.keys.sorted() where !e.removedAnnotations.contains(id) {
            out.append(Item(kind: .newSegmentation(id), title: id, subtitle: "new segmentation", symbol: Symbols.annotation(kind: "layers")))
        }
        for id in e.editedSegmentations.subtracting(e.newSegmentations.keys).sorted() where !e.removedAnnotations.contains(id) {
            out.append(Item(kind: .editedSegmentation(id), title: id, subtitle: "voxels edited", symbol: Symbols.annotation(kind: "layers")))
        }
        for id in e.annotations.keys.sorted() where !e.removedAnnotations.contains(id) {
            out.append(Item(kind: .annotation(id), title: id, subtitle: summary.annotation(id) == nil ? "new annotation" : "edited",
                            symbol: "square.dashed"))
        }
        for id in e.imageAttributes.keys.sorted() where !e.removedImages.contains(id) {
            out.append(Item(kind: .imageAttributes(id), title: id, subtitle: "attributes edited", symbol: "slider.horizontal.3"))
        }
        for id in e.removedImages.sorted() {
            out.append(Item(kind: .removedImage(id), title: id, subtitle: "image removed", symbol: "minus.square"))
        }
        for id in e.removedAnnotations.sorted() where summary.annotation(id) != nil {
            out.append(Item(kind: .removedAnnotation(id), title: id, subtitle: "annotation removed", symbol: "minus.square"))
        }
        for id in e.removedTransforms.sorted() {
            out.append(Item(kind: .removedTransform(id), title: id, subtitle: "transform removed", symbol: "minus.square"))
        }
        return out
    }
}

/// The document's unsaved changes, at the top of the sidebar: what the next
/// save writes. Added objects are shown once saved; until then a context
/// menu takes an import back.
struct PendingChangesSection: View {
    let workspace: Workspace

    var body: some View {
        let items = PendingChangeList.items(of: workspace)
        if !items.isEmpty {
            Section("Unsaved Changes") {
                ForEach(items) { item in
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1).truncationMode(.middle)
                            Text(item.subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 1)
                    .selectionDisabled()
                    .help(item.isAddition ? "Written to the file when you save; shown in the views once saved" : "Written to the file when you save")
                    .contextMenu { menu(for: item) }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for item: PendingChangeList.Item) -> some View {
        switch item.kind {
        case .addedImage(let id):
            Button("Remove the Imported Image") { workspace.document?.requestRemoval(.image, id) }
        case .addedSegmentation(let id):
            Button("Remove the Imported Segmentation") { workspace.document?.requestRemoval(.annotation, id) }
        case .document:
            Button("Open the Document Editor") { workspace.document?.showPanel(.document) }
        case .labelSet:
            Button("Open the Label Set Editor") { workspace.document?.showPanel(.labelSet) }
        default:
            EmptyView()
        }
        if let undo = workspace.document?.undoManager, undo.canUndo {
            Button("Undo \(undo.undoActionName)") { undo.undo() }
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
