import AppKit
import SwiftUI
import Observation
import MedH5Kit

/// One finding of a validation report, as a row (its index in the report).
struct DiagnosticRow: Identifiable, Hashable {
    var id: Int
    var diagnostic: Diagnostic

    /// Reported as a warning by the code table, an error at this level
    /// (`strict` promotes warnings).
    var isPromoted: Bool { diagnostic.severity != diagnostic.effectiveSeverity }
}

/// The findings of one severity.
struct DiagnosticGroup: Identifiable, Equatable {
    var severity: String
    var rows: [DiagnosticRow]
    var id: String { severity }

    var title: String {
        switch severity {
        case "error": return "Errors"
        case "warning": return "Warnings"
        default: return severity.capitalizedFirst
        }
    }
}

/// How the Validation window arranges a report: grouped by the severity a
/// finding has at the level validated (errors first), filtered by text,
/// copied as lines, exported as JSON in the engine's member order.
enum ValidationPresentation {
    static func order(_ severity: String) -> Int {
        switch severity {
        case "error": return 0
        case "warning": return 1
        default: return 2
        }
    }

    /// Whether a finding matches every word of `filter` (in its code,
    /// location, message or summary; case-insensitive).
    static func matches(_ d: Diagnostic, filter: String) -> Bool {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [d.code, d.location, d.message, d.summary, d.effectiveSeverity].joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// The groups of a report: severities in order (errors, warnings, then
    /// any other), findings in report order, `hidden` severities left out.
    static func groups(_ report: ValidationReport, filter: String = "", hidden: Set<String> = []) -> [DiagnosticGroup] {
        var bySeverity: [String: [DiagnosticRow]] = [:]
        for (i, d) in report.diagnostics.enumerated() where matches(d, filter: filter) {
            bySeverity[d.effectiveSeverity, default: []].append(DiagnosticRow(id: i, diagnostic: d))
        }
        return bySeverity.keys
            .filter { !hidden.contains($0) }
            .sorted { (order($0), $0) < (order($1), $1) }
            .map { DiagnosticGroup(severity: $0, rows: bySeverity[$0]!) }
    }

    /// Counts by effective severity.
    static func counts(_ report: ValidationReport) -> [String: Int] {
        report.diagnostics.reduce(into: [:]) { $0[$1.effectiveSeverity, default: 0] += 1 }
    }

    /// The findings as text, one per line: `E701 error /images/CT: message`.
    static func text(_ rows: [DiagnosticRow]) -> String {
        rows.map { r in
            let d = r.diagnostic
            var line = "\(d.code) \(d.effectiveSeverity)"
            if r.isPromoted { line += " (promoted from \(d.severity))" }
            line += " \(d.location.isEmpty ? "/" : d.location): \(d.message)"
            return line
        }.joined(separator: "\n")
    }

    /// The report as JSON, members in the engine's order.
    static func json(_ report: ValidationReport) -> JSONValue {
        let diagnostics: [JSONValue] = report.diagnostics.map { d in
            .object(JSONObject([
                ("code", .string(d.code)), ("severity", .string(d.severity)),
                ("effective_severity", .string(d.effectiveSeverity)), ("location", .string(d.location)),
                ("message", .string(d.message)), ("level", .string(d.level)), ("summary", .string(d.summary)),
            ]))
        }
        return .object(JSONObject([
            ("path", .string(report.path)), ("level", .string(report.level)), ("profiles", .strings(report.profiles)),
            ("ok", .bool(report.ok)), ("errors", .int(Int64(report.errors))), ("warnings", .int(Int64(report.warnings))),
            ("promoted", .int(Int64(report.promoted))), ("codes", .strings(report.codes)),
            ("diagnostics", .array(diagnostics)), ("checked", report.checked ?? .null),
        ]))
    }

    /// "Valid", or "2 errors, 1 warning".
    static func headline(_ report: ValidationReport) -> String {
        let counts = counts(report)
        let errors = counts["error"] ?? 0, warnings = counts["warning"] ?? 0
        if errors == 0 && warnings == 0 { return report.ok ? "No problems found" : "Not valid" }
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    /// What each level checks.
    static func describe(level: String) -> String {
        switch level {
        case "structural": return "The file's layout: groups, datasets, attributes and their types."
        case "semantic": return "Structure, plus the document, references between objects and every object's rules."
        case "integrity": return "Everything semantic checks, plus every digest and the content id (reads all the data)."
        case "strict": return "Everything integrity checks, with warnings counted as errors."
        default: return level
        }
    }
}

/// Validate… (⌘⇧V): runs the engine's validator at a chosen level on the
/// saved file, in the background.
@MainActor
@Observable
final class ValidationModel {
    let workspace: Workspace
    /// The levels the engine offers, lowest first.
    let levels: [String]
    private(set) var level = "integrity"
    var filter = ""
    var hiddenSeverities: Set<String> = []
    var selection = Set<Int>()
    private(set) var report: ValidationReport?
    private(set) var state: TaskState = .idle
    private(set) var validatedAt: Date?
    /// The document had unsaved changes when the run began.
    private(set) var unsavedWhenRun = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
        levels = (try? MedH5.validationLevels()) ?? ["structural", "semantic", "integrity", "strict"]
        if !levels.contains(level), let last = levels.last { level = last }
    }

    func setLevel(_ new: String) {
        guard new != level, levels.contains(new) else { return }
        level = new
        run()
    }

    /// Validates the saved file at `level`.
    func run() {
        task?.cancel()
        let url = workspace.savedURL, level = self.level
        state = .running("Validating at the \(level) level…")
        unsavedWhenRun = workspace.hasPendingEdits
        task = Task { [weak self] in
            do {
                let report = try await Validator.validateInBackground(url: url, level: level)
                guard let self, !Task.isCancelled else { return }
                self.report = report
                self.selection = []
                self.validatedAt = Date()
                self.state = .idle
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(VolumeStore.describe(error))
            }
        }
    }

    /// Waits for the run in flight (tests, the snapshot mode).
    func wait() async { await task?.value }

    var groups: [DiagnosticGroup] {
        guard let report else { return [] }
        return ValidationPresentation.groups(report, filter: filter, hidden: hiddenSeverities)
    }

    /// The selected rows, or every visible one.
    var rowsToCopy: [DiagnosticRow] {
        let visible = groups.flatMap(\.rows)
        let selected = visible.filter { selection.contains($0.id) }
        return selected.isEmpty ? visible : selected
    }

    func copy() { copyToPasteboard(ValidationPresentation.text(rowsToCopy)) }

    func exportJSON(from window: NSWindow?) {
        guard let report else { return }
        let base = workspace.displayName.replacingOccurrences(of: ".medh5", with: "")
        saveText(ValidationPresentation.json(report).serialized(.pretty) + "\n",
                 suggestedName: "\(base) validation (\(report.level)).json", in: window)
    }
}

struct ValidationView: View {
    @Bindable var model: ValidationModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.unsavedWhenRun {
                NoticeBar(style: .warning, text: "The document has unsaved changes. Validation reads the saved file: save, then validate again, to check them.")
            }
            if model.workspace.file.member != nil {
                NoticeBar(style: .info, text: "This sample is a member of a collection: the validator checks the whole collection file.")
            }
            Divider()
            controls
            Divider()
            content
        }
        .frame(minWidth: 600, minHeight: 380)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon.font(.system(size: 30))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(model.workspace.savedURL.path)
                if let report = model.report, !report.profiles.isEmpty {
                    Text("Profiles: " + report.profiles.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Picker("Level", selection: Binding(get: { model.level }, set: { model.setLevel($0) })) {
                ForEach(model.levels, id: \.self) { level in
                    Text(level.capitalizedFirst).tag(level).help(ValidationPresentation.describe(level: level))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(ValidationPresentation.describe(level: model.level))
            Button {
                model.run()
            } label: {
                Label("Validate Again", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.state.isRunning)
            .help("Validate the saved file again (⌘R)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if model.state.isRunning {
            ProgressView().controlSize(.regular)
        } else if model.state.failure != nil {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        } else if let report = model.report {
            let counts = ValidationPresentation.counts(report)
            if (counts["error"] ?? 0) > 0 || !report.ok {
                Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
            } else if (counts["warning"] ?? 0) > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        } else {
            Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        if case .running(let what) = model.state { return what }
        if model.state.failure != nil { return "The validator could not run" }
        return model.report.map(ValidationPresentation.headline) ?? "Not validated yet"
    }

    private var subtitle: String {
        var parts = ["\(model.level.capitalizedFirst) level"]
        if let at = model.validatedAt { parts.append("validated \(at.formatted(date: .omitted, time: .shortened))") }
        parts.append(model.workspace.savedURL.lastPathComponent)
        return parts.joined(separator: " · ")
    }

    private var controls: some View {
        let counts = model.report.map(ValidationPresentation.counts) ?? [:]
        return HStack(spacing: 10) {
            TextField("Filter by code, path or message", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            ForEach(["error", "warning"], id: \.self) { severity in
                Toggle(isOn: Binding(get: { !model.hiddenSeverities.contains(severity) }, set: { shown in
                    if shown { model.hiddenSeverities.remove(severity) } else { model.hiddenSeverities.insert(severity) }
                })) {
                    Text("\(severity == "error" ? "Errors" : "Warnings") \(counts[severity] ?? 0)")
                }
                .toggleStyle(.button)
                .help("Show or hide the \(severity)s")
            }
            Spacer()
            Button {
                model.copy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(model.groups.isEmpty)
            .help("Copy the selected findings (or all shown) as text")
            Button {
                model.exportJSON(from: NSApp.keyWindow)
            } label: {
                Label("Export JSON…", systemImage: "square.and.arrow.up")
            }
            .disabled(model.report == nil)
            .help("Save the whole report as JSON")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.state.failure {
            VStack {
                NoticeBar(style: .error, text: failure)
                Spacer()
            }
        } else if let report = model.report, report.diagnostics.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("No problems found").font(.title3.weight(.semibold))
                Text(ValidationPresentation.describe(level: report.level))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.report != nil {
            let groups = model.groups
            if groups.isEmpty {
                Text("No finding matches the filter.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.rows) { row in
                                DiagnosticRowView(row: row).tag(row.id)
                            }
                        } header: {
                            Text("\(group.title) (\(group.rows.count))")
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: Int.self) { ids in
                    Button("Copy") {
                        let rows = model.groups.flatMap(\.rows).filter { ids.contains($0.id) }
                        copyToPasteboard(ValidationPresentation.text(rows))
                    }
                    Button("Copy Location") {
                        let rows = model.groups.flatMap(\.rows).filter { ids.contains($0.id) }
                        copyToPasteboard(rows.map(\.diagnostic.location).joined(separator: "\n"))
                    }
                }
                .onCopyCommand {
                    [NSItemProvider(object: ValidationPresentation.text(model.rowsToCopy) as NSString)]
                }
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Reading the file…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One finding: code, message, location and the code table's summary.
struct DiagnosticRowView: View {
    let row: DiagnosticRow

    var body: some View {
        let d = row.diagnostic
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(d.code)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint))
                .help(d.summary)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.message)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(d.location.isEmpty ? "/" : d.location)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isPromoted {
                        Text("promoted from \(d.severity)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                if !d.summary.isEmpty && d.summary != d.message {
                    Text(d.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(d.effectiveSeverity) \(d.code) at \(d.location): \(d.message)")
    }

    private var tint: Color {
        switch row.diagnostic.effectiveSeverity {
        case "error": return .red
        case "warning": return .orange
        default: return .gray
        }
    }
}
