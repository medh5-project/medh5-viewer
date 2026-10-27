import AppKit
import SwiftUI
import Observation
import MedH5Kit

/// One class as the label set editor holds it: the class's JSON object,
/// members in order (members the editor does not show, such as
/// `properties`, are kept), and a row identity that survives id edits.
struct EditableLabelClass: Identifiable, Hashable {
    let id: UUID
    var object: JSONObject

    init(_ object: JSONObject, id: UUID = UUID()) {
        self.id = id
        self.object = object
    }

    var classID: Int? { object["id"]?.intValue }
    var key: String { object["key"]?.stringValue ?? "" }
    var name: String { object["name"]?.stringValue ?? "" }
    var category: String { object["category"]?.stringValue ?? "" }
    var laterality: String { object["laterality"]?.stringValue ?? "" }
    var parents: [Int] { object["parents"]?.arrayValue?.compactMap(\.intValue) ?? [] }

    var color: RGBA8? {
        guard let values = object["color"]?.arrayValue?.compactMap(\.intValue) else { return nil }
        return RGBA8(array: values)
    }

    var displayColor: RGBA8 { color ?? LabelPalette.color(forClassID: classID ?? 0) }

    /// `(system, code, name)` of each ontology code.
    var codes: [(system: String, code: String, name: String)] {
        (object["codes"]?.arrayValue ?? []).map {
            ($0["system"]?.stringValue ?? "", $0["code"]?.stringValue ?? "", $0["name"]?.stringValue ?? "")
        }
    }
}

/// The label set editor: id, key, name, colour, category, laterality,
/// parents and codes of every class; adding, removing (refused while
/// anything uses the class) and recolouring. Apply has the engine check the
/// label set and puts it into the pending edits as one undoable step.
@MainActor
@Observable
final class LabelSetEditorModel {
    static let categories = ["region", "organ", "vessel", "bone", "lesion", "tissue", "device", "landmark", "other"]
    static let lateralities = ["left", "right", "bilateral"]

    let workspace: Workspace
    /// The label set's members other than `classes`, in order.
    private(set) var header = JSONObject()
    private(set) var classes: [EditableLabelClass] = []
    /// Whether the document has a label set (or the draft makes one).
    private(set) var hasLabelSet = false
    /// The label set the draft started from.
    private(set) var base: JSONValue?
    var selection: UUID?
    private(set) var state: TaskState = .idle
    private(set) var refusal: [String] = []
    private(set) var notice: String?
    private(set) var loadError: String?

    init(workspace: Workspace) {
        self.workspace = workspace
        reload()
    }

    var isReadOnly: Bool { workspace.isReadOnly || workspace.amendableURL == nil }

    /// The order of the label set's members as loaded (`classes` among them).
    private var keyOrder: [String] = []

    /// The label set the draft describes, members in their order.
    var draft: JSONValue? {
        guard hasLabelSet else { return nil }
        let list = JSONValue.array(classes.map { .object($0.object) })
        var o = JSONObject()
        for key in keyOrder {
            if key == "classes" { o["classes"] = list } else if let v = header[key] { o[key] = v }
        }
        for (k, v) in header where o[k] == nil { o[k] = v }
        if o["classes"] == nil { o["classes"] = list }
        return .object(o)
    }

    var isDirty: Bool {
        let d = draft
        return d != base || d?.serialized() != base?.serialized()
    }

    func reload() {
        do {
            base = try workspace.effectiveLabelSet()
            loadError = nil
        } catch {
            base = nil
            loadError = VolumeStore.describe(error)
        }
        load(base)
        refusal = []
        notice = nil
    }

    private func load(_ labelSet: JSONValue?) {
        hasLabelSet = labelSet != nil
        var h = labelSet?.objectValue ?? JSONObject()
        keyOrder = h.keys
        let list = h["classes"]?.arrayValue ?? []
        h["classes"] = nil
        header = h
        let previous = Dictionary(classes.compactMap { c in c.classID.map { ($0, c.id) } }, uniquingKeysWith: { a, _ in a })
        classes = list.compactMap(\.objectValue).map { o in
            EditableLabelClass(o, id: o["id"]?.intValue.flatMap { previous[$0] } ?? UUID())
        }
        if let selection, !classes.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = classes.first?.id }
    }

    /// Follows the document's edits (an undo, a save) unless a draft is in
    /// progress.
    func sync() {
        guard !isDirty, !state.isRunning else { return }
        let current = try? workspace.effectiveLabelSet()
        if current != base || current?.serialized() != base?.serialized() { reload() }
    }

    func revert() {
        load(base)
        refusal = []
        notice = nil
    }

    /// Makes a new, empty label set (the document has none).
    func createLabelSet() {
        guard !hasLabelSet else { return }
        let sample = workspace.summary.identity.sampleID
        header = JSONObject([("id", .string(sample.isEmpty ? "labels" : "\(sample)-labels")), ("version", .string("1.0.0")),
                             ("form", .string("inline"))])
        keyOrder = ["id", "version", "form", "classes"]
        classes = []
        hasLabelSet = true
        notice = nil
    }

    // MARK: Classes

    func index(of row: UUID) -> Int? { classes.firstIndex { $0.id == row } }

    func row(_ id: UUID) -> EditableLabelClass? { classes.first { $0.id == id } }

    private func change(_ row: UUID, _ body: (inout JSONObject) -> Void) {
        guard let i = index(of: row) else { return }
        var o = classes[i].object
        body(&o)
        classes[i].object = o
        refusal = []
        notice = nil
    }

    func setText(_ row: UUID, _ key: String, _ text: String, required: Bool = false) {
        change(row) { $0[key] = text.isEmpty && !required ? nil : .string(text) }
    }

    func binding(_ row: UUID, _ key: String, required: Bool = false) -> Binding<String> {
        Binding(get: { self.row(row)?.object[key]?.stringValue ?? "" },
                set: { self.setText(row, key, $0, required: required) })
    }

    /// Changes a class id; refused while anything uses the old one.
    func setClassID(_ row: UUID, _ text: String) {
        guard let c = self.row(row), let new = Int(text.trimmingCharacters(in: .whitespaces)), new != c.classID else { return }
        if let old = c.classID {
            let users = users(ofClass: old)
            if !users.isEmpty {
                refusal = ["Class \(old) (\(c.key)) keeps its id: \(Format.list(users)) use\(users.count == 1 ? "s" : "") it."]
                return
            }
        }
        change(row) { $0["id"] = .int(Int64(new)) }
    }

    func setColor(_ row: UUID, _ color: RGBA8) {
        change(row) { $0["color"] = .ints(color.array) }
    }

    func colorBinding(_ row: UUID) -> Binding<Color> {
        Binding(get: { (self.row(row)?.displayColor ?? RGBA8(128, 128, 128)).color },
                set: { if let rgba = RGBA8(color: $0) { self.setColor(row, rgba) } })
    }

    func toggleParent(_ row: UUID, _ parent: Int) {
        change(row) { o in
            var parents = o["parents"]?.arrayValue?.compactMap(\.intValue) ?? []
            if let i = parents.firstIndex(of: parent) { parents.remove(at: i) } else { parents.append(parent) }
            o["parents"] = parents.isEmpty ? nil : .ints(parents)
        }
    }

    func addCode(_ row: UUID) {
        change(row) { o in
            var codes = o["codes"]?.arrayValue ?? []
            codes.append(.object(JSONObject([("system", .string("SCT")), ("code", .string("")), ("name", .string(""))])))
            o["codes"] = .array(codes)
        }
    }

    func removeCode(_ row: UUID, at i: Int) {
        change(row) { o in
            var codes = o["codes"]?.arrayValue ?? []
            guard codes.indices.contains(i) else { return }
            codes.remove(at: i)
            o["codes"] = codes.isEmpty ? nil : .array(codes)
        }
    }

    func codeBinding(_ row: UUID, _ i: Int, _ member: String) -> Binding<String> {
        Binding(get: { self.row(row)?.object["codes"]?[i]?[member]?.stringValue ?? "" },
                set: { text in
                    self.change(row) { o in
                        guard var codes = o["codes"]?.arrayValue, codes.indices.contains(i) else { return }
                        codes[i][member] = member == "name" && text.isEmpty ? nil : .string(text)
                        o["codes"] = .array(codes)
                    }
                })
    }

    /// Adds a class with the next free id, a key and name to edit, and the
    /// palette's colour for its id; returns its row.
    @discardableResult
    func addClass() -> UUID? {
        if !hasLabelSet { createLabelSet() }
        let ids = Set(classes.compactMap(\.classID))
        let next = (ids.max() ?? 0) + 1
        guard let id = next <= 65534 ? next : (1...65534).first(where: { !ids.contains($0) }) else { return nil }
        let keys = Set(classes.map(\.key))
        var key = "class_\(id)"
        var n = 2
        while keys.contains(key) {
            key = "class_\(id)_\(n)"
            n += 1
        }
        let color = LabelPalette.color(forClassID: id)
        let row = EditableLabelClass(JSONObject([("id", .int(Int64(id))), ("key", .string(key)), ("name", .string("Class \(id)")),
                                                 ("color", .ints(color.array))]))
        classes.append(row)
        selection = row.id
        refusal = []
        notice = nil
        return row.id
    }

    /// Removes a class nothing uses; returns why not.
    @discardableResult
    func removeClass(_ row: UUID) -> String? {
        guard let c = self.row(row) else { return nil }
        if let id = c.classID {
            let users = users(ofClass: id)
            if !users.isEmpty {
                let why = "\(c.name.isEmpty ? "Class \(id)" : c.name) (\(id)) cannot be removed: \(Format.list(users)) use\(users.count == 1 ? "s" : "") it."
                refusal = [why]
                return why
            }
        }
        classes.removeAll { $0.id == row }
        selection = classes.first?.id
        refusal = []
        notice = nil
        return nil
    }

    /// Everything that uses a class: stored annotations (what they can
    /// express or were examined for), pending imports and edits, other
    /// classes (as a parent), skeletons and relations.
    func users(ofClass id: Int) -> [String] {
        var users: [String] = []
        let s = workspace.summary
        let edits = workspace.pendingEdits
        for a in s.annotations where !edits.removedAnnotations.contains(a.id)
            && (a.classIDs.contains(id) || a.annotatedClassIDs.contains(id)) {
            users.append(a.id)
        }
        for (aid, seg) in edits.importedSegmentations where seg.options.classIDs?.contains(id) == true {
            users.append("\(aid) (imported)")
        }
        for aid in edits.editedSegmentations.union(edits.newSegmentations.keys).sorted() where !users.contains(aid) {
            if let model = workspace.store.ready(.segmentation(aid), as: SegmentationResource.self)?.model,
               model.classIDs.contains(where: { Int($0) == id }) {
                users.append("\(aid) (edited)")
            }
        }
        for (aid, edit) in edits.annotations where !users.contains(aid) && Self.classIDs(of: edit).contains(id) {
            users.append("\(aid) (edited)")
        }
        for other in classes where other.parents.contains(id) {
            users.append("class \(other.key) (as its parent)")
        }
        for skeleton in header["skeletons"]?.arrayValue ?? [] {
            let keypoints = skeleton["keypoints"]?.arrayValue?.compactMap(\.intValue) ?? []
            if keypoints.contains(id) { users.append("skeleton \(skeleton["id"]?.stringValue ?? "")") }
        }
        for relation in header["relations"]?.arrayValue ?? []
        where relation["subject"]?.intValue == id || relation["object"]?.intValue == id {
            users.append("a \(relation["predicate"]?.stringValue ?? "") relation")
        }
        return users
    }

    /// The class ids an annotation edit writes.
    static func classIDs(of edit: AnnotationEdit) -> Set<Int> {
        switch edit {
        case .geometric(_, _, let arrays):
            var ids = Set<Int>()
            for a in arrays where a.name.hasSuffix("class_ids") {
                for i in 0..<a.data.count { ids.insert(Int(a.data.value(at: i))) }
            }
            return ids
        case .classification(let assertions, _, _, _, _):
            return Set(assertions.map(\.classID))
        case .mask:
            return []
        }
    }

    /// What is wrong with the draft before the engine sees it.
    var problems: [UUID: String] {
        var out: [UUID: String] = [:]
        var ids: [Int: Int] = [:], keys: [String: Int] = [:]
        for c in classes {
            if let id = c.classID { ids[id, default: 0] += 1 }
            keys[c.key, default: 0] += 1
        }
        for c in classes {
            if let id = c.classID {
                if !(1...65534).contains(id) { out[c.id] = "id \(id) is outside 1–65534 (0 is background, 65535 ignore)" }
                else if ids[id, default: 0] > 1 { out[c.id] = "id \(id) is used twice" }
            } else {
                out[c.id] = "no id"
            }
            if c.key.isEmpty { out[c.id] = "no key" } else if keys[c.key, default: 0] > 1 { out[c.id] = "key \(c.key) is used twice" }
            if c.name.isEmpty { out[c.id] = "no name" }
        }
        return out
    }

    // MARK: Apply

    func apply() async {
        guard !isReadOnly, let source = workspace.amendableURL else {
            refusal = ["This document is read-only."]
            return
        }
        if let first = problems.first, let c = row(first.key) {
            refusal = ["\(c.name.isEmpty ? c.key : c.name): \(first.value)"]
            return
        }
        let candidate = draft
        state = .running("The engine is checking the label set…")
        refusal = []
        do {
            let stored = try await blocking { try EngineCheck.labelSet(candidate, source: source) }
            let underlying = (workspace.pendingEdits.document ?? (try? workspace.file.document()))?["label_set"]
                .flatMap { $0.isNull ? nil : $0 }
            workspace.applyEdit("Edit Label Set") { edits in
                if stored == underlying && stored?.serialized() == underlying?.serialized() {
                    edits.labelSet = nil
                } else {
                    edits.labelSet = stored.map(LabelSetChange.set) ?? .remove
                }
            }
            base = stored
            load(stored)
            state = .idle
            notice = "Applied. Save the document to write the label set (Edit ▸ Undo takes it back)."
        } catch let r as EngineCheck.Refusal {
            state = .idle
            refusal = r.messages
        } catch {
            state = .idle
            refusal = [VolumeStore.describe(error)]
        }
    }
}

extension RGBA8 {
    /// A SwiftUI colour in sRGB, 8 bits a channel.
    init?(color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), byte(c.alphaComponent))
    }
}

// MARK: - Views

struct LabelSetEditorView: View {
    @Bindable var model: LabelSetEditorModel

    var body: some View {
        VStack(spacing: 0) {
            banners
            if model.hasLabelSet {
                HSplitView {
                    classTable
                        .frame(minWidth: 480, idealWidth: 700, maxWidth: .infinity)
                    detail
                        .frame(minWidth: 320, idealWidth: 340, maxWidth: 520)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: Symbols.labelSet).font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                    Text("No label set").font(.title3.weight(.semibold))
                    Text("Annotations name classes by id; a label set says what each id means (§5).")
                        .foregroundStyle(.secondary)
                    Button("Create Label Set") { model.createLabelSet() }
                        .disabled(model.isReadOnly)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onChange(of: model.workspace.auxiliary.editsRevision) { _, _ in model.sync() }
        .onChange(of: model.workspace.summary.contentID) { _, _ in model.sync() }
    }

    @ViewBuilder
    private var banners: some View {
        if model.isReadOnly {
            NoticeBar(style: .info, text: "This document is read-only: the label set is shown, not edited.")
        }
        if let error = model.loadError { NoticeBar(style: .error, text: error) }
        if !model.refusal.isEmpty {
            NoticeBar(style: .error, text: model.refusal.joined(separator: "\n"))
        } else if let notice = model.notice {
            NoticeBar(style: .success, text: notice)
        }
    }

    private var classTable: some View {
        let problems = model.problems
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(model.header["id"]?.stringValue ?? "").font(.headline)
                Text("version \(model.header["version"]?.stringValue ?? "—") · \(model.classes.count) classes")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Table(model.classes, selection: Binding(get: { model.selection.map { Set([$0]) } ?? [] },
                                                    set: { model.selection = $0.first })) {
                TableColumn("") { c in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(c.displayColor.color)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                        .frame(width: 14, height: 14)
                        .accessibilityLabel("Colour")
                }
                .width(22)
                TableColumn("Id") { c in
                    Text(c.classID.map(String.init) ?? "—").monospacedDigit()
                        .foregroundStyle(problems[c.id] == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.red))
                }
                .width(min: 36, ideal: 44, max: 60)
                TableColumn("Key") { c in Text(c.key).font(.system(size: 11.5, design: .monospaced)) }
                    .width(min: 70, ideal: 100)
                TableColumn("Name") { c in
                    HStack(spacing: 4) {
                        Text(c.name)
                        if let p = problems[c.id] {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(p)
                        }
                    }
                }
                .width(min: 90, ideal: 120)
                TableColumn("Category") { c in Text(c.category).foregroundStyle(.secondary) }
                    .width(min: 56, ideal: 64)
                TableColumn("Side") { c in Text(c.laterality).foregroundStyle(.secondary) }
                    .width(min: 36, ideal: 44)
                TableColumn("Parents") { c in
                    Text(c.parents.map { p in model.classes.first { $0.classID == p }?.key ?? String(p) }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 90)
                TableColumn("Used by") { c in
                    let users = c.classID.map { model.users(ofClass: $0) } ?? []
                    Text(users.isEmpty ? "—" : "\(users.count)")
                        .foregroundStyle(.secondary)
                        .help(users.joined(separator: "\n"))
                }
                .width(min: 44, ideal: 54, max: 70)
            }
            Divider()
            HStack(spacing: 4) {
                Button { model.addClass() } label: { Image(systemName: "plus") }
                    .help("Add a class with the next free id")
                Button {
                    if let s = model.selection { model.removeClass(s) }
                } label: { Image(systemName: "minus") }
                    .disabled(model.selection == nil)
                    .help("Remove the class (refused while an annotation, another class, a skeleton or a relation uses it)")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
            .disabled(model.isReadOnly)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let row = model.selection, let c = model.row(row) {
            ClassDetail(model: model, row: row, labelClass: c)
        } else {
            Text("Select a class").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if case .running(let what) = model.state {
                ProgressView().controlSize(.small)
                Text(what).foregroundStyle(.secondary)
            } else {
                Text(model.isDirty ? "Edited — not applied"
                     : (model.workspace.pendingEdits.labelSet != nil ? "Applied — the document has unsaved changes" : "As saved"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { model.revert() }
                .disabled(!model.isDirty || model.state.isRunning)
            Button("Apply") { Task { await model.apply() } }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty || model.isReadOnly || model.state.isRunning || !model.problems.isEmpty)
                .help("Check the label set with the engine and make it the document's (⌘↩); Save writes it")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct ClassDetail: View {
    let model: LabelSetEditorModel
    let row: UUID
    let labelClass: EditableLabelClass

    var body: some View {
        Form {
            Section {
                LabeledContent("Id") {
                    TextField("Id", text: Binding(get: { labelClass.classID.map(String.init) ?? "" },
                                                  set: { model.setClassID(row, $0) }))
                        .labelsHidden()
                        .frame(maxWidth: 90)
                }
                TextField("Key", text: model.binding(row, "key", required: true))
                TextField("Name", text: model.binding(row, "name", required: true))
                ColorPicker("Colour", selection: model.colorBinding(row), supportsOpacity: true)
                Picker("Category", selection: model.binding(row, "category")) {
                    Text("—").tag("")
                    ForEach(LabelSetEditorModel.categories, id: \.self) { Text($0).tag($0) }
                    if !labelClass.category.isEmpty && !LabelSetEditorModel.categories.contains(labelClass.category) {
                        Text(labelClass.category).tag(labelClass.category)
                    }
                }
                Picker("Laterality", selection: model.binding(row, "laterality")) {
                    Text("—").tag("")
                    ForEach(LabelSetEditorModel.lateralities, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Parents") {
                    Menu {
                        ForEach(model.classes.filter { $0.id != row }) { other in
                            if let pid = other.classID {
                                Toggle(isOn: Binding(get: { labelClass.parents.contains(pid) }, set: { _ in model.toggleParent(row, pid) })) {
                                    Text("\(other.name) (\(pid))")
                                }
                            }
                        }
                    } label: {
                        Text(labelClass.parents.isEmpty ? "None"
                             : labelClass.parents.map { p in model.classes.first { $0.classID == p }?.name ?? String(p) }.joined(separator: ", "))
                    }
                    .fixedSize()
                }
                .help("is_a parents (§5.4): a DAG, not a tree")
            } header: {
                Text(labelClass.name.isEmpty ? "Class" : labelClass.name)
            } footer: {
                let users = labelClass.classID.map { model.users(ofClass: $0) } ?? []
                Text(users.isEmpty ? "Nothing uses this class yet." : "Used by \(Format.list(users)).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(labelClass.codes.enumerated()), id: \.offset) { i, _ in
                    HStack(spacing: 6) {
                        TextField("System", text: model.codeBinding(row, i, "system")).frame(width: 64)
                        TextField("Code", text: model.codeBinding(row, i, "code")).frame(width: 96)
                        TextField("Name", text: model.codeBinding(row, i, "name"))
                        Button { model.removeCode(row, at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove this code")
                    }
                    .labelsHidden()
                }
                Button("Add Code") { model.addCode(row) }
            } header: {
                Text("Codes")
            } footer: {
                Text("Bindings to external vocabularies: SNOMED CT (SCT), RadLex, FMA, UBERON…").font(.callout).foregroundStyle(.secondary)
            }
            if let properties = labelClass.object["properties"], !properties.isNull {
                Section("Properties") {
                    Text(properties.serialized(.editing))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isReadOnly)
    }
}
