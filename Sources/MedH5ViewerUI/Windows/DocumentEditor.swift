import AppKit
import SwiftUI
import Observation
import MedH5Kit

/// Window ▸ Document (⌘⌥D): `/meta` as an outline, forms for identity,
/// cohort, timepoints, quality and de-identification, and a JSON editor for
/// everything.
///
/// The editor works on a draft of the document as the next save writes it
/// (the pending document, or the stored one, with a pending label set).
/// Apply has the engine check the draft (`EngineCheck`: amend a temporary
/// copy, commit, validate) and, when it accepts, puts the document the
/// engine would store into the pending edits as one undoable step. Members
/// keep their order and numbers their kind: forms change values in place,
/// and `JSONValue` never turns `92` into `92.0`.
@MainActor
@Observable
final class DocumentEditorModel {
    enum Page: String, CaseIterable, Identifiable {
        case identity, cohort, timepoints, quality, deidentification, outline, json

        var id: String { rawValue }

        var title: String {
            switch self {
            case .identity: return "Identity"
            case .cohort: return "Cohort"
            case .timepoints: return "Timepoints"
            case .quality: return "Quality"
            case .deidentification: return "De-identification"
            case .outline: return "Outline"
            case .json: return "JSON"
            }
        }

        var symbol: String {
            switch self {
            case .identity: return "person.text.rectangle"
            case .cohort: return "building.2"
            case .timepoints: return Symbols.timepoint
            case .quality: return Symbols.quality
            case .deidentification: return Symbols.deidentification
            case .outline: return "list.bullet.indent"
            case .json: return "curlybraces"
            }
        }

        static let forms: [Page] = [.identity, .cohort, .timepoints, .quality, .deidentification]
    }

    static let sexValues = ["F", "M", "O", "unknown"]
    static let lateralityValues = ["left", "right", "bilateral"]
    static let qualityStatuses = ["draft", "submitted", "reviewed", "approved", "rejected", "deprecated"]

    let workspace: Workspace
    var page: Page = .identity
    /// The document being edited.
    private(set) var draft: JSONValue = .object(JSONObject())
    /// What the draft started from.
    private(set) var base: JSONValue = .object(JSONObject())
    private(set) var jsonText = ""
    private(set) var jsonError: String?
    private(set) var state: TaskState = .idle
    /// The engine's refusal of the last Apply, or a removal refused.
    private(set) var refusal: [String] = []
    private(set) var notice: String?
    private(set) var loadError: String?
    var selectedTimepoint: Int?
    var selectedQuality: String?
    var outlineSelection: String?
    /// Timepoints added in this draft (their ids can still change).
    private(set) var addedTimepoints: Set<String> = []

    init(workspace: Workspace) {
        self.workspace = workspace
        reload()
    }

    var isDirty: Bool { draft != base }
    var isReadOnly: Bool { workspace.isReadOnly || workspace.amendableURL == nil }

    /// The draft becomes the document as the next save writes it.
    func reload() {
        do {
            base = try workspace.effectiveDocument()
            loadError = nil
        } catch {
            loadError = VolumeStore.describe(error)
        }
        draft = base
        jsonText = draft.serialized(.editing)
        jsonError = nil
        refusal = []
        addedTimepoints = []
        if selectedTimepoint == nil, !timepoints.isEmpty { selectedTimepoint = 0 }
        if selectedQuality == nil { selectedQuality = qualityKeys.first }
    }

    /// Follows the document's edits (an undo, a save) unless a draft is in
    /// progress.
    func sync() {
        guard !isDirty, !state.isRunning else { return }
        let current = (try? workspace.effectiveDocument()) ?? base
        if current != base || current.serialized() != base.serialized() { reload() }
    }

    func revert() {
        draft = base
        jsonText = draft.serialized(.editing)
        jsonError = nil
        refusal = []
        notice = nil
        addedTimepoints = []
    }

    // MARK: Fields

    func value(_ path: [JSONPathComponent]) -> JSONValue? { draft.value(at: path) }

    func string(_ path: [JSONPathComponent]) -> String { value(path)?.stringValue ?? "" }

    /// Sets a string member; empty text removes an optional one.
    func setString(_ path: [JSONPathComponent], _ text: String, required: Bool = false) {
        edit { $0.set(text.isEmpty && !required ? nil : .string(text), at: path) }
    }

    func setValue(_ value: JSONValue?, at path: [JSONPathComponent]) {
        edit { $0.set(value, at: path) }
    }

    /// A binding to a string member.
    func binding(_ path: [JSONPathComponent], required: Bool = false) -> Binding<String> {
        Binding(get: { self.string(path) }, set: { self.setString(path, $0, required: required) })
    }

    private func edit(_ change: (inout JSONValue) -> Void) {
        var d = draft
        change(&d)
        // An emptied cohort is no cohort.
        if let cohort = d["cohort"]?.objectValue, cohort.isEmpty { d["cohort"] = nil }
        draft = d
        jsonText = d.serialized(.editing)
        jsonError = nil
        refusal = []
        notice = nil
    }

    /// Members of an object the form does not show (edited as JSON).
    func otherMembers(of key: String, known: [String]) -> [(key: String, value: JSONValue)] {
        (draft[key]?.objectValue?.entries ?? []).filter { !known.contains($0.key) }
    }

    // MARK: JSON

    func setJSONText(_ text: String) {
        jsonText = text
        refusal = []
        notice = nil
        do {
            let parsed = try JSONValue.parse(text)
            guard parsed.objectValue != nil else {
                jsonError = "The document is one JSON object."
                return
            }
            draft = parsed
            jsonError = nil
        } catch let e as JSONParseError {
            jsonError = e.describe(in: text)
        } catch {
            jsonError = error.localizedDescription
        }
    }

    func formatJSON() {
        guard jsonError == nil else { return }
        jsonText = draft.serialized(.editing)
    }

    // MARK: Timepoints

    var timepoints: [JSONValue] { draft["timepoints"]?.arrayValue ?? [] }

    func timepoint(at i: Int) -> JSONValue? {
        let items = timepoints
        return items.indices.contains(i) ? items[i] : nil
    }

    func isNewTimepoint(_ i: Int) -> Bool {
        guard let id = timepoint(at: i)?["id"]?.stringValue else { return false }
        return addedTimepoints.contains(id)
    }

    func addTimepoint() {
        let items = timepoints
        let ids = Set(items.compactMap { $0["id"]?.stringValue })
        let index = (items.compactMap { $0["index"]?.intValue }.max() ?? -1) + 1
        var n = index
        while ids.contains("tp\(n)") { n += 1 }
        let id = "tp\(n)"
        let tp = JSONValue.object(JSONObject([("id", .string(id)), ("index", .int(Int64(index)))]))
        edit { $0.set(.array(items + [tp]), at: [.key("timepoints")]) }
        addedTimepoints.insert(id)
        selectedTimepoint = items.count
    }

    /// Renames a timepoint added in this draft.
    func renameTimepoint(_ i: Int, to id: String) {
        guard let old = timepoint(at: i)?["id"]?.stringValue, addedTimepoints.contains(old), !id.isEmpty else { return }
        addedTimepoints.remove(old)
        addedTimepoints.insert(id)
        setValue(.string(id), at: [.key("timepoints"), .index(i), .key("id")])
    }

    /// What still names a timepoint: grids, annotations, pending grids.
    func users(ofTimepoint id: String) -> [String] {
        let s = workspace.summary
        var users = s.grids.filter { $0.timepoint == id }.map { "grid \($0.id)" }
        users += workspace.pendingEdits.newGrids.filter { $0.value.timepoint == id }.map { "new grid \($0.key)" }
        users += s.annotations.filter { $0.declaredTimepoints?.contains(id) == true }.map { "annotation \($0.id)" }
        return users
    }

    /// Removes a timepoint nothing names; the others keep their order with
    /// dense indices (§3.7).
    func removeTimepoint(_ i: Int) {
        guard let id = timepoint(at: i)?["id"]?.stringValue else { return }
        let users = self.users(ofTimepoint: id)
        guard users.isEmpty else {
            refusal = ["Timepoint \(id) cannot be removed: \(Format.list(users)) belong\(users.count == 1 ? "s" : "") to it."]
            return
        }
        var items = timepoints
        items.remove(at: i)
        let order = items.indices.sorted { (items[$0]["index"]?.intValue ?? 0) < (items[$1]["index"]?.intValue ?? 0) }
        for (rank, j) in order.enumerated() where items[j]["index"]?.intValue != rank {
            items[j]["index"] = .int(Int64(rank))
        }
        edit { $0.set(.array(items), at: [.key("timepoints")]) }
        addedTimepoints.remove(id)
        selectedTimepoint = items.isEmpty ? nil : min(i, items.count - 1)
    }

    // MARK: Quality

    var qualityKeys: [String] { draft["quality"]?.objectValue?.keys ?? [] }

    func users(ofQuality key: String) -> [String] {
        workspace.summary.annotations.filter { $0.quality == key }.map(\.id)
    }

    /// Adds a quality record (status `draft`); returns why not.
    @discardableResult
    func addQuality(_ key: String) -> String? {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return "A quality record needs a key." }
        guard !qualityKeys.contains(k) else { return "There is a quality record \(k) already." }
        setValue(.object(JSONObject([("status", .string("draft"))])), at: [.key("quality"), .key(k)])
        selectedQuality = k
        return nil
    }

    func removeQuality(_ key: String) {
        let users = self.users(ofQuality: key)
        guard users.isEmpty else {
            refusal = ["Quality record \(key) cannot be removed: \(Format.list(users)) name\(users.count == 1 ? "s" : "") it."]
            return
        }
        edit { d in
            d.set(nil, at: [.key("quality"), .key(key)])
            if d["quality"]?.objectValue?.isEmpty == true { d["quality"] = nil }
        }
        selectedQuality = qualityKeys.first
    }

    /// `reviewed_by` as comma-separated text.
    func reviewers(_ key: String) -> String {
        (value([.key("quality"), .key(key), .key("reviewed_by")])?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
    }

    func setReviewers(_ key: String, _ text: String) {
        let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        setValue(names.isEmpty ? nil : .strings(names), at: [.key("quality"), .key(key), .key("reviewed_by")])
    }

    // MARK: De-identification

    var hasDeidentification: Bool { draft["deidentification"].map { !$0.isNull } ?? false }

    func setHasDeidentification(_ on: Bool) {
        if on {
            if !hasDeidentification { setValue(.object(JSONObject([("method", .string(""))])), at: [.key("deidentification")]) }
        } else {
            setValue(nil, at: [.key("deidentification")])
        }
    }

    // MARK: Outline

    var outline: [JSONOutlineNode] { JSONOutlineNode.nodes(draft) }

    // MARK: Apply

    /// Has the engine check the draft and, when it accepts, makes it the
    /// pending document (one undoable step).
    func apply() async {
        guard !isReadOnly, let source = workspace.amendableURL else {
            refusal = ["This document is read-only."]
            return
        }
        if let jsonError {
            refusal = [jsonError]
            return
        }
        let candidate = draft
        state = .running("The engine is checking the document…")
        refusal = []
        do {
            let stored = try await blocking { try EngineCheck.document(candidate, source: source) }
            let saved = try? workspace.file.document()
            workspace.applyEdit("Edit Document") { edits in
                edits.labelSet = nil
                edits.document = stored == saved && stored.serialized() == saved?.serialized() ? nil : stored
            }
            base = stored
            draft = stored
            jsonText = stored.serialized(.editing)
            addedTimepoints = []
            state = .idle
            notice = "Applied. Save the document to write it to the file (Edit ▸ Undo takes it back)."
        } catch let r as EngineCheck.Refusal {
            state = .idle
            refusal = r.messages
        } catch {
            state = .idle
            refusal = [VolumeStore.describe(error)]
        }
    }
}

/// A node of the document outline.
struct JSONOutlineNode: Identifiable, Hashable {
    let id: String
    let key: String
    let path: [JSONPathComponent]
    let value: JSONValue
    var children: [JSONOutlineNode]?

    static func nodes(_ value: JSONValue, path: [JSONPathComponent] = []) -> [JSONOutlineNode] {
        switch value {
        case .object(let o):
            return o.entries.map { node(key: $0.key, value: $0.value, path: path + [.key($0.key)]) }
        case .array(let a):
            return a.enumerated().map { node(key: "[\($0.offset)]", value: $0.element, path: path + [.index($0.offset)]) }
        default:
            return []
        }
    }

    private static func node(key: String, value: JSONValue, path: [JSONPathComponent]) -> JSONOutlineNode {
        var label = key
        // An array item that is an object names itself by its id or key.
        if case .index = path.last, let name = value["id"]?.stringValue ?? value["key"]?.stringValue {
            label += "  " + name
        }
        let kids = nodes(value, path: path)
        return JSONOutlineNode(id: JSONValue.pointer(path), key: label, path: path, value: value,
                               children: kids.isEmpty ? nil : kids)
    }
}

// MARK: - Views

struct DocumentEditorView: View {
    @Bindable var model: DocumentEditorModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.page }, set: { if let p = $0 { model.page = p } })) {
                Section("Forms") {
                    ForEach(DocumentEditorModel.Page.forms) { page in
                        Label(page.title, systemImage: page.symbol).tag(page)
                    }
                }
                Section("Everything") {
                    Label(DocumentEditorModel.Page.outline.title, systemImage: DocumentEditorModel.Page.outline.symbol)
                        .tag(DocumentEditorModel.Page.outline)
                    Label(DocumentEditorModel.Page.json.title, systemImage: DocumentEditorModel.Page.json.symbol)
                        .tag(DocumentEditorModel.Page.json)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                banners
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
        }
        .onChange(of: model.workspace.auxiliary.editsRevision) { _, _ in model.sync() }
        .onChange(of: model.workspace.summary.contentID) { _, _ in model.sync() }
    }

    @ViewBuilder
    private var banners: some View {
        if model.workspace.isReadOnly {
            NoticeBar(style: .info, text: "This document is read-only: the document is shown, not edited.")
        } else if model.workspace.amendableURL == nil {
            NoticeBar(style: .info, text: "A member of a collection is never amended: the document is shown, not edited.")
        }
        if let error = model.loadError { NoticeBar(style: .error, text: error) }
        if !model.refusal.isEmpty {
            NoticeBar(style: .error, text: model.refusal.joined(separator: "\n"))
        } else if let notice = model.notice {
            NoticeBar(style: .success, text: notice)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .identity: IdentityForm(model: model)
        case .cohort: CohortForm(model: model)
        case .timepoints: TimepointsForm(model: model)
        case .quality: QualityForm(model: model)
        case .deidentification: DeidentificationForm(model: model)
        case .outline: DocumentOutlineView(model: model)
        case .json: DocumentJSONView(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if case .running(let what) = model.state {
                ProgressView().controlSize(.small)
                Text(what).foregroundStyle(.secondary)
            } else {
                Image(systemName: statusSymbol).foregroundStyle(.secondary)
                Text(status).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { model.revert() }
                .disabled(!model.isDirty || model.state.isRunning)
                .help("Discard the changes not applied yet")
            Button("Apply") { Task { await model.apply() } }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty || model.isReadOnly || model.jsonError != nil || model.state.isRunning)
                .help("Check the document with the engine and make it the document's (⌘↩); Save writes it")
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var status: String {
        if model.isDirty { return "Edited — not applied" }
        if model.workspace.pendingEdits.document != nil || model.workspace.pendingEdits.labelSet != nil {
            return "Applied — the document has unsaved changes"
        }
        return "As saved"
    }

    private var statusSymbol: String {
        model.isDirty ? "pencil.circle" : "checkmark.circle"
    }
}

/// Members of an object the form does not cover.
private struct OtherMembers: View {
    let members: [(key: String, value: JSONValue)]

    var body: some View {
        if !members.isEmpty {
            Section {
                ForEach(members, id: \.key) { m in
                    LabeledContent(m.key) {
                        Text(m.value.preview).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    }
                }
            } header: {
                Text("Other members")
            } footer: {
                Text("Edit these in JSON.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A picker over an enumeration, with "—" for absent.
private struct OptionalPicker: View {
    let title: String
    let values: [String]
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text("—").tag("")
            ForEach(values, id: \.self) { Text($0).tag($0) }
            if !selection.isEmpty && !values.contains(selection) {
                Text("\(selection) (not a defined value)").tag(selection)
            }
        }
    }
}

private struct IdentityForm: View {
    let model: DocumentEditorModel
    private let known = ["sample_id", "subject_id", "sex", "laterality", "bodypart"]

    var body: some View {
        Form {
            Section {
                TextField("Sample id", text: model.binding([.key("identity"), .key("sample_id")], required: true))
                TextField("Subject id", text: model.binding([.key("identity"), .key("subject_id")], required: true))
                OptionalPicker(title: "Sex", values: DocumentEditorModel.sexValues,
                               selection: model.binding([.key("identity"), .key("sex")]))
                OptionalPicker(title: "Laterality", values: DocumentEditorModel.lateralityValues,
                               selection: model.binding([.key("identity"), .key("laterality")]))
                TextField("Body part", text: model.binding([.key("identity"), .key("bodypart")]), prompt: Text("e.g. ABDOMEN"))
            } header: {
                Text("Identity")
            } footer: {
                Text("Who and what the sample is about (§12.1). The two ids are required; sex and laterality take the values the format defines.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            OtherMembers(members: model.otherMembers(of: "identity", known: known))
        }
        .formStyle(.grouped)
        .disabled(model.isReadOnly)
    }
}

private struct CohortForm: View {
    let model: DocumentEditorModel
    private let fields = [("dataset_id", "Dataset"), ("site_id", "Site"), ("scanner_id", "Scanner"),
                          ("group_id", "Group"), ("acquisition_protocol", "Acquisition protocol")]

    var body: some View {
        Form {
            Section {
                ForEach(fields, id: \.0) { key, title in
                    TextField(title, text: model.binding([.key("cohort"), .key(key)]))
                }
            } header: {
                Text("Cohort")
            } footer: {
                Text("Where the sample comes from (§12.2). Splits group samples by the group id, or the subject id when there is none.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            OtherMembers(members: model.otherMembers(of: "cohort", known: fields.map(\.0)))
        }
        .formStyle(.grouped)
        .disabled(model.isReadOnly)
    }
}

private struct TimepointsForm: View {
    @Bindable var model: DocumentEditorModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedTimepoint) {
                    ForEach(Array(model.timepoints.enumerated()), id: \.offset) { i, tp in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tp["label"]?.stringValue?.capitalizedFirst ?? tp["id"]?.stringValue ?? "—")
                            Text([tp["id"]?.stringValue, tp["index"].map { "index \($0.numberText)" },
                                  tp["days_from_baseline"].map { "day \($0.numberText)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(i)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Button { model.addTimepoint() } label: { Image(systemName: "plus") }
                        .help("Add a timepoint")
                    Button {
                        if let i = model.selectedTimepoint { model.removeTimepoint(i) }
                    } label: { Image(systemName: "minus") }
                        .disabled(model.selectedTimepoint == nil)
                        .help("Remove the timepoint (refused while a grid or an annotation belongs to it)")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
                .disabled(model.isReadOnly)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            Group {
                if let i = model.selectedTimepoint, i < model.timepoints.count {
                    TimepointDetail(model: model, index: i)
                } else {
                    Text("Select a timepoint").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TimepointDetail: View {
    let model: DocumentEditorModel
    let index: Int

    private func path(_ key: String) -> [JSONPathComponent] { [.key("timepoints"), .index(index), .key(key)] }

    var body: some View {
        let tp = model.timepoints[index]
        Form {
            Section {
                if model.isNewTimepoint(index) {
                    TextField("Id", text: Binding(get: { tp["id"]?.stringValue ?? "" },
                                                  set: { model.renameTimepoint(index, to: $0) }))
                } else {
                    LabeledContent("Id") { Text(tp["id"]?.stringValue ?? "—").textSelection(.enabled) }
                }
                LabeledContent("Index") { Text(tp["index"]?.numberText ?? "—") }
                TextField("Label", text: model.binding(path("label")), prompt: Text("e.g. baseline"))
                TextField("Date", text: model.binding(path("date")), prompt: Text("YYYY-MM-DD"))
                NumberField(title: "Days from baseline", value: tp["days_from_baseline"]) {
                    model.setValue($0, at: path("days_from_baseline"))
                }
                NumberField(title: "Subject age (years)", value: tp["subject_age_years"]) {
                    model.setValue($0, at: path("subject_age_years"))
                }
                TextField("Study UID", text: model.binding(path("study_uid")))
                TextField("Description", text: model.binding(path("description")), axis: .vertical)
            } header: {
                Text("Timepoint")
            } footer: {
                Text("A visit (§3.7). Ids are referenced by grids and annotations and do not change once saved; indices stay dense in acquisition order.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let series = tp["series_uids"]?.objectValue, !series.isEmpty {
                Section("Series UIDs") {
                    ForEach(series.entries, id: \.key) { e in
                        LabeledContent(e.key) { Text(e.value.stringValue ?? e.value.preview).textSelection(.enabled) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isReadOnly)
    }
}

private struct QualityForm: View {
    @Bindable var model: DocumentEditorModel
    @State private var newKey = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedQuality) {
                    ForEach(model.qualityKeys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key)
                            Text(model.value([.key("quality"), .key(key), .key("status")])?.stringValue ?? "—")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(key)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    TextField("New record", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(action: add) { Image(systemName: "plus") }
                        .disabled(newKey.isEmpty)
                        .help("Add a quality record with this key")
                    Button {
                        if let k = model.selectedQuality { model.removeQuality(k) }
                    } label: { Image(systemName: "minus") }
                        .disabled(model.selectedQuality == nil)
                        .help("Remove the record (refused while an annotation names it)")
                }
                .buttonStyle(.borderless)
                .padding(6)
                .disabled(model.isReadOnly)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            Group {
                if let key = model.selectedQuality, model.qualityKeys.contains(key) {
                    QualityDetail(model: model, key: key)
                } else {
                    Text(model.qualityKeys.isEmpty ? "No quality records" : "Select a record").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func add() {
        if let why = model.addQuality(newKey) { NSSound.beep(); Log.info(why) } else { newKey = "" }
    }
}

private struct QualityDetail: View {
    let model: DocumentEditorModel
    let key: String

    private func path(_ member: String) -> [JSONPathComponent] { [.key("quality"), .key(key), .key(member)] }

    var body: some View {
        Form {
            Section {
                OptionalPicker(title: "Status", values: DocumentEditorModel.qualityStatuses,
                               selection: model.binding(path("status"), required: true))
                NumberField(title: "Confidence", value: model.value(path("confidence")), prompt: "0–1") {
                    model.setValue($0, at: path("confidence"))
                }
                TextField("Reviewed by", text: Binding(get: { model.reviewers(key) }, set: { model.setReviewers(key, $0) }),
                          prompt: Text("agent ids, comma-separated"))
                NumberField(title: "Edit effort (s)", value: model.value(path("edit_effort_s"))) {
                    model.setValue($0, at: path("edit_effort_s"))
                }
            } header: {
                Text(key)
            } footer: {
                let users = model.users(ofQuality: key)
                Text(users.isEmpty ? "How good an annotation is, and who said so (§11.6). No annotation names this record."
                     : "Named by \(Format.list(users)).")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            OtherMembers(members: (model.value([.key("quality"), .key(key)])?.objectValue?.entries ?? [])
                .filter { !["status", "confidence", "reviewed_by", "edit_effort_s"].contains($0.key) })
        }
        .formStyle(.grouped)
        .disabled(model.isReadOnly)
    }
}

private struct DeidentificationForm: View {
    let model: DocumentEditorModel
    private let known = ["method", "profile", "date_shift_days", "id_mapping", "performed_by", "date", "burned_in_annotation_checked"]

    private func path(_ member: String) -> [JSONPathComponent] { [.key("deidentification"), .key(member)] }

    var body: some View {
        Form {
            Section {
                Toggle("The sample records its de-identification",
                       isOn: Binding(get: { model.hasDeidentification }, set: { model.setHasDeidentification($0) }))
            } footer: {
                Text(model.hasDeidentification
                     ? "What was done to remove identifiers (§11.4)."
                     : "No record: a reader must treat the file as potentially identifying.")
                    .font(.callout).foregroundStyle(model.hasDeidentification ? .secondary : Color.orange)
            }
            if model.hasDeidentification {
                Section("Record") {
                    TextField("Method", text: model.binding(path("method"), required: true), prompt: Text("required"))
                    TextField("Profile", text: model.binding(path("profile")))
                    NumberField(title: "Date shift (days)", value: model.value(path("date_shift_days"))) {
                        model.setValue($0, at: path("date_shift_days"))
                    }
                    TextField("Id mapping", text: model.binding(path("id_mapping")))
                    TextField("Performed by", text: model.binding(path("performed_by")))
                    TextField("Date", text: model.binding(path("date")), prompt: Text("ISO 8601, e.g. 2026-01-31T12:00:00Z"))
                    Picker("Burned-in annotation checked", selection: Binding(
                        get: { model.value(path("burned_in_annotation_checked"))?.boolValue.map { $0 ? "yes" : "no" } ?? "" },
                        set: { model.setValue($0.isEmpty ? nil : .bool($0 == "yes"), at: path("burned_in_annotation_checked")) })) {
                        Text("—").tag("")
                        Text("Yes").tag("yes")
                        Text("No").tag("no")
                    }
                }
                OtherMembers(members: model.otherMembers(of: "deidentification", known: known))
            }
        }
        .formStyle(.grouped)
        .disabled(model.isReadOnly)
    }
}

private struct DocumentOutlineView: View {
    @Bindable var model: DocumentEditorModel

    var body: some View {
        let nodes = model.outline
        VSplitView {
            List(nodes, children: \.children, selection: $model.outlineSelection) { node in
                HStack(spacing: 8) {
                    Text(node.key).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(node.value.preview).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Text(node.value.kindName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 52, alignment: .trailing)
                }
                .tag(node.id)
            }
            .frame(minHeight: 200)
            detail(nodes)
                .frame(minHeight: 110, idealHeight: 160)
        }
    }

    @ViewBuilder
    private func detail(_ nodes: [JSONOutlineNode]) -> some View {
        if let id = model.outlineSelection, let node = find(id, in: nodes) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(node.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Edit in JSON") { model.page = .json }
                        .disabled(model.isReadOnly)
                }
                ScrollView {
                    Text(node.value.serialized(.editing))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        } else {
            Text("Select a member to see its value").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func find(_ id: String, in nodes: [JSONOutlineNode]) -> JSONOutlineNode? {
        for n in nodes {
            if n.id == id { return n }
            if let c = n.children, let found = find(id, in: c) { return found }
        }
        return nil
    }
}

private struct DocumentJSONView: View {
    let model: DocumentEditorModel

    var body: some View {
        VStack(spacing: 0) {
            PlainTextView(text: Binding(get: { model.jsonText }, set: { model.setJSONText($0) }),
                          isEditable: !model.isReadOnly)
            Divider()
            HStack(spacing: 8) {
                if let error = model.jsonError {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(error).foregroundStyle(.red).lineLimit(2)
                } else {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    Text("Valid JSON. Members keep their order; integers and floats stay apart.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Format") { model.formatJSON() }
                    .disabled(model.jsonError != nil || model.isReadOnly)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
