import AppKit
import SwiftUI
import MedH5Kit
import MedH5Editing

/// The Annotations tab: the geometric annotation the Box, Point, Polyline
/// and Contour tools add to (pick one, or a new one made with the next
/// item), the class and depth of new items, and the annotation's items —
/// select to jump the crosshair, delete, change class; Edit ▸ Cut, Copy,
/// Paste, Delete and Select All act on them.
struct AnnotationsInspector: View {
    let workspace: Workspace

    var body: some View {
        @Bindable var session = workspace.editing
        let _ = session.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let why = session.readOnlyReason {
                    ReadOnlyNote(text: why)
                }
                AnnotationPickerSection(workspace: workspace, session: session)
                Divider().padding(.horizontal, 14)
                NewItemsSection(workspace: workspace, session: session)
                Divider().padding(.horizontal, 14)
                AnnotationItemsSection(workspace: workspace, session: session)
                if let message = session.message {
                    EditMessageView(message: message) { session.message = nil }
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                }
            }
            .padding(.bottom, 16)
        }
        .sheet(item: $session.sheet) { sheet in
            switch sheet {
            case .newSegmentation: NewSegmentationSheet(workspace: workspace)
            case .addClass: AddClassSheet(workspace: workspace)
            case .newLabelClass: AddClassSheet(workspace: workspace, labelSetOnly: true)
            }
        }
    }
}

struct AnnotationPickerSection: View {
    let workspace: Workspace
    @Bindable var session: EditingSession

    var body: some View {
        let annotations = session.editableAnnotations
        let listed = session.listedAnnotation
        InspectorSection("Annotation") {
            Picker("Annotation", selection: Binding(get: { tag(session.annotationTarget) }, set: { choose($0) })) {
                Text("The topmost shown (automatic)").tag("auto")
                Text("A new annotation (with the next item)").tag("new")
                if !annotations.isEmpty { Divider() }
                ForEach(annotations) { a in
                    Text("\(a.id) — \(KindNames.annotation(a.kind).lowercased())").tag("id:" + a.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            Text(caption(listed))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let id = listed, let why = session.attestation(of: id) {
                Label(why, systemImage: "lock.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tag(_ t: AnnotationTarget) -> String {
        switch t {
        case .automatic: return "auto"
        case .new: return "new"
        case .existing(let id): return "id:" + id
        }
    }

    private func choose(_ tag: String) {
        switch tag {
        case "auto": session.annotationTarget = .automatic
        case "new": session.annotationTarget = .new
        default: session.choose(annotation: String(tag.dropFirst(3)))
        }
    }

    private func caption(_ id: String?) -> String {
        guard let id, let info = workspace.summary.annotation(id) else {
            return "Drawing with Box, Point, Polyline or Contour creates a new annotation on the base image’s grid."
        }
        var parts = ["\(KindNames.annotation(info.kind)) on \(info.grid ?? info.frameUID ?? "—")", "\(info.space ?? "index") space",
                     "\(info.items ?? 0) item\(info.items == 1 ? "" : "s")"]
        if workspace.file.summary.annotation(id) == nil {
            parts.append("new, not saved")
        } else if session.hasPendingDraft(id) {
            parts.append("edited, not saved")
        }
        if !workspace.activeStack.contains(id) { parts.append("not shown in the active view") }
        return parts.joined(separator: " · ")
    }
}

struct NewItemsSection: View {
    let workspace: Workspace
    @Bindable var session: EditingSession

    var body: some View {
        let viewer = workspace.viewer
        let labels = workspace.summary.labelSet
        let tool = ViewerTool.annotationTools.contains(viewer.tool) ? viewer.tool : nil
        InspectorSection("New Items", trailing: AnyView(newClassButton)) {
            HStack(spacing: 4) {
                ForEach(ViewerTool.annotationTools) { t in
                    let availability = session.availability(t)
                    Toggle(isOn: Binding(get: { viewer.tool == t }, set: { if $0 { session.select(t) } })) {
                        Image(systemName: t.symbol)
                    }
                    .toggleStyle(.button)
                    .disabled(!availability.isAvailable)
                    .help(availability.reason ?? t.help)
                    .accessibilityLabel(t.title)
                }
                Spacer()
            }
            .controlSize(.small)
            LabeledRow("Class") {
                Picker("Class", selection: Binding(get: { session.annotationClass(for: tool ?? .box) }, set: { session.annotationClassID = $0 })) {
                    Text("None").tag(Int?.none)
                    ForEach(labels?.classes ?? []) { c in
                        Text("\(c.name) (\(c.id))").tag(Int?.some(c.id))
                    }
                }
                .labelsHidden()
            }
            .controlSize(.small)
            if tool == .box || tool == nil {
                LabeledRow("Depth") {
                    Stepper(value: $session.boxDepth, in: 0...512) {
                        Text(session.boxDepth == 0 ? "2-D box on the slice" : "\(session.boxDepth) slice\(session.boxDepth == 1 ? "" : "s") deep (3-D)")
                            .monospacedDigit()
                    }
                }
                .controlSize(.small)
            }
            Text(hint(tool))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var newClassButton: some View {
        Button {
            session.sheet = .newLabelClass
        } label: {
            Label("New Class…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5))
        .disabled(session.readOnlyReason != nil)
        .help("Add a class to the label set")
    }

    private func hint(_ tool: ViewerTool?) -> String {
        switch tool {
        case .box?: return "Drag on a slice. Boxes are drawn at voxel edges on the base image’s grid."
        case .point?: return "Click to place a point; in a keypoint annotation, the next keypoint of the last object."
        case .polyline?: return "Click the vertices; Return or a double-click finishes, ⌫ removes the last vertex, Esc cancels."
        case .contour?: return "Click the vertices of a closed outline; click the first vertex, press Return or double-click to close it. Holes follow from nesting."
        default: return "Choose Box (⇧B), Point (⇧P), Polyline (⇧L) or Contour (⇧C) to draw."
        }
    }
}

struct AnnotationItemsSection: View {
    let workspace: Workspace
    @Bindable var session: EditingSession

    var body: some View {
        let id = session.listedAnnotation
        let items = id.map { session.items(of: $0) } ?? []
        let selection = session.currentSelection
        let labels = workspace.summary.labelSet
        InspectorSection("Items", trailing: AnyView(actions(id: id, selection: selection))) {
            if let id {
                if session.draft(id) == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading \(id)…").foregroundStyle(.secondary).font(.callout)
                    }
                    .onAppear { session.show(id) }
                } else if items.isEmpty {
                    Text("No items yet.").foregroundStyle(.secondary).font(.callout)
                } else {
                    VStack(spacing: 1) {
                        ForEach(items) { item in
                            AnnotationItemRow(item: item, labelSet: labels, isSelected: selection.contains(item.id))
                                .onTapGesture { tap(item.id, of: id, selection: selection) }
                        }
                    }
                }
                issues(id)
            } else {
                Text("No annotation yet.").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private func tap(_ item: Int, of id: String, selection: Set<Int>) {
        let flags = NSEvent.modifierFlags
        var s = selection
        if flags.contains(.command) {
            if s.contains(item) { s.remove(item) } else { s.insert(item) }
        } else if flags.contains(.shift), let anchor = s.min() {
            s = Set(min(anchor, item)...max(anchor, item))
        } else {
            s = [item]
        }
        session.select(items: s, of: id)
        if s.contains(item) { session.jump(toItem: item, of: id) }
    }

    @ViewBuilder
    private func issues(_ id: String) -> some View {
        if let d = session.draft(id) {
            let found = d.validate(grid: session.annotationGrid(id))
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(found.prefix(5).enumerated()), id: \.offset) { _, issue in
                        Label(issue.description, systemImage: issue.isError ? "xmark.octagon.fill" : "exclamationmark.triangle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(issue.isError ? Color.red : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func actions(id: String?, selection: Set<Int>) -> some View {
        let editable = session.canEditListedItems
        return HStack(spacing: 8) {
            Menu {
                ForEach(workspace.summary.labelSet?.classes ?? []) { c in
                    Button("\(c.name) (\(c.id))") { attempt { try session.setClassOfSelectedItems(c.id) } }
                }
            } label: {
                Text("Class")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!editable || selection.isEmpty)
            .help("Change the class of the selected items")
            Button {
                attempt { try session.deleteSelectedItems() }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!editable || selection.isEmpty)
            .help("Delete the selected items")
            .accessibilityLabel("Delete the selected items")
        }
        .font(.system(size: 10.5))
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { session.report(error) }
    }
}

struct AnnotationItemRow: View {
    let item: AnnotationDraft.Item
    let labelSet: LabelSetInfo?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(item.classID.map { classColor($0, labelSet: labelSet).withAlpha(255).color } ?? Color.secondary)
                .frame(width: 11, height: 11)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.title).fontWeight(.medium)
                    Text(item.classID.map { className($0, labelSet: labelSet) } ?? "no class").foregroundStyle(.secondary)
                    if let score = item.score {
                        Text("· score \(Format.number(Double(score), digits: 2))").foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Text(item.detail)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
