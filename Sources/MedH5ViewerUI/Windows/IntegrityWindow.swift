import AppKit
import SwiftUI
import Observation
import MedH5Kit

/// One object `verify` checked, with the digest it stores.
struct IntegrityRow: Identifiable, Hashable {
    var path: String
    /// `ok`, `mismatched`, `malformed`, `undigested`, `unverifiable`, …
    var state: String
    var ok: Bool
    var digest: String?
    var id: String { path }
}

/// How the Integrity window arranges a verification report.
enum IntegrityPresentation {
    static func rows(_ report: VerifyReport, digests: [String: String], filter: String = "",
                     onlyProblems: Bool = false) -> [IntegrityRow] {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace)
        return report.objects.compactMap { o in
            if onlyProblems && o.ok { return nil }
            let row = IntegrityRow(path: o.path, state: o.state, ok: o.ok, digest: digests[o.path])
            let haystack = "\(o.path) \(o.state) \(row.digest ?? "")".lowercased()
            return words.allSatisfy { haystack.contains($0) } ? row : nil
        }
    }

    /// The report's problem lists that are not empty.
    static func problems(_ report: VerifyReport) -> [(title: String, help: String, paths: [String])] {
        [
            ("Do not match their digest", "The stored bytes changed since the digest was written.", report.mismatched),
            ("Malformed digests", "A digest attribute that cannot be read.", report.malformed),
            ("Without a digest", "Objects that carry no digest.", report.undigested),
            ("Not attested", "Objects the content id does not cover.", report.unattested),
            ("Not verifiable", "Objects whose digests this engine cannot check.", report.unverifiable),
            ("Stale sampling index", "Index entries that no longer match their annotation.", report.staleIndex),
        ].filter { !$0.2.isEmpty }
    }

    static func headline(_ report: VerifyReport) -> String {
        if report.ok { return "Every digest and the content id verify" }
        let failed = report.objects.filter { !$0.ok }.count
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed) object\(failed == 1 ? "" : "s") do\(failed == 1 ? "es" : "") not verify") }
        if report.contentID.ok == false { parts.append("the content id does not match") }
        return parts.isEmpty ? "The file does not verify" : parts.joined(separator: "; ").capitalizedFirst
    }

    /// The report with each object's stored digest, as JSON.
    static func json(_ report: VerifyReport, digests: [String: String]) -> JSONValue {
        func optional(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
        let objects: [JSONValue] = report.objects.map { o in
            .object(JSONObject([("path", .string(o.path)), ("ok", .bool(o.ok)), ("state", .string(o.state)),
                                ("digest", optional(digests[o.path]))]))
        }
        return .object(JSONObject([
            ("ok", .bool(report.ok)),
            ("content_id", .object(JSONObject([("stored", optional(report.contentID.stored)),
                                               ("computed", optional(report.contentID.computed)),
                                               ("ok", report.contentID.ok.map(JSONValue.bool) ?? .null)]))),
            ("objects", .array(objects)),
            ("mismatched", .strings(report.mismatched)), ("malformed", .strings(report.malformed)),
            ("undigested", .strings(report.undigested)), ("unattested", .strings(report.unattested)),
            ("unverifiable", .strings(report.unverifiable)), ("stale_index", .strings(report.staleIndex)),
        ]))
    }

    static func text(_ rows: [IntegrityRow]) -> String {
        rows.map { "\($0.path)\t\($0.state)\t\($0.digest ?? "—")" }.joined(separator: "\n")
    }
}

/// Tools ▸ Verify Integrity: every digest and the `content_id` (spec §13),
/// checked by the engine in the background.
@MainActor
@Observable
final class IntegrityModel {
    let workspace: Workspace
    private(set) var report: VerifyReport?
    /// The digest each object stores, by path (read after the check).
    private(set) var digests: [String: String] = [:]
    private(set) var state: TaskState = .idle
    private(set) var verifiedAt: Date?
    private(set) var unsavedWhenRun = false
    var filter = ""
    var onlyProblems = false
    var selection = Set<String>()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func run() {
        task?.cancel()
        let file = workspace.file
        state = .running("Checking every digest…")
        unsavedWhenRun = workspace.hasPendingEdits
        task = Task { [weak self] in
            do {
                let report = try await blocking { try file.verify() }
                guard let self, !Task.isCancelled else { return }
                self.report = report
                self.verifiedAt = Date()
                self.state = .idle
                let paths = report.objects.map(\.path)
                let digests: [String: String] = (try? await blocking { () -> [String: String] in
                    var out: [String: String] = [:]
                    for p in paths {
                        if let d = (try? file.attributes(of: p))?["digest"]?.stringValue { out[p] = d }
                    }
                    return out
                }) ?? [:]
                guard !Task.isCancelled else { return }
                self.digests = digests
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(VolumeStore.describe(error))
            }
        }
    }

    func wait() async { await task?.value }

    var rows: [IntegrityRow] {
        guard let report else { return [] }
        return IntegrityPresentation.rows(report, digests: digests, filter: filter, onlyProblems: onlyProblems)
    }

    func copy() {
        let rows = self.rows
        let selected = rows.filter { selection.contains($0.id) }
        copyToPasteboard(IntegrityPresentation.text(selected.isEmpty ? rows : selected))
    }

    func exportJSON(from window: NSWindow?) {
        guard let report else { return }
        let base = workspace.displayName.replacingOccurrences(of: ".medh5", with: "")
        saveText(IntegrityPresentation.json(report, digests: digests).serialized(.pretty) + "\n",
                 suggestedName: "\(base) integrity.json", in: window)
    }
}

struct IntegrityView: View {
    @Bindable var model: IntegrityModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.unsavedWhenRun {
                NoticeBar(style: .warning, text: "The document has unsaved changes. Verification reads the saved file; the digests of unsaved changes are written when you save.")
            }
            Divider()
            if let failure = model.state.failure {
                NoticeBar(style: .error, text: failure)
                Spacer()
            } else if let report = model.report {
                contentIDBox(report)
                let problems = IntegrityPresentation.problems(report)
                if !problems.isEmpty { problemList(problems) }
                Divider()
                controls
                Divider()
                table
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Hashing every object…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 400)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if model.state.isRunning {
                    ProgressView()
                } else if let report = model.report {
                    Image(systemName: report.ok ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .foregroundStyle(report.ok ? .green : .red)
                } else {
                    Image(systemName: "shield").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 30))
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.report.map(IntegrityPresentation.headline) ?? "Verifying…")
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                model.run()
            } label: {
                Label("Verify Again", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.state.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let report = model.report { parts.append("\(report.objects.count) objects") }
        if let algo = model.workspace.summary.digestAlgorithm { parts.append(algo) }
        if let at = model.verifiedAt { parts.append("verified \(at.formatted(date: .omitted, time: .standard))") }
        parts.append(model.workspace.savedURL.lastPathComponent)
        return parts.joined(separator: " · ")
    }

    private func contentIDBox(_ report: VerifyReport) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: report.contentID.ok == false ? "number.square.fill" : "number.square")
                .font(.system(size: 22))
                .foregroundStyle(report.contentID.ok == false ? .red : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Content id").font(.headline)
                    if let ok = report.contentID.ok {
                        Label(ok ? "matches" : "does not match", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(ok ? .green : .red)
                    }
                }
                digestLine("Stored", report.contentID.stored)
                digestLine("Computed", report.contentID.computed)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func digestLine(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Text(value ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if let value {
                Button {
                    copyToPasteboard(value)
                } label: {
                    Image(systemName: "doc.on.doc").imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help("Copy the \(label.lowercased()) content id")
            }
        }
        .font(.callout)
    }

    private func problemList(_ problems: [(title: String, help: String, paths: [String])]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(problems.enumerated()), id: \.offset) { _, p in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(p.title) (\(p.paths.count)):").fontWeight(.medium).help(p.help)
                    Text(p.paths.joined(separator: ", "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("Filter objects", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Toggle("Only problems", isOn: $model.onlyProblems)
                .toggleStyle(.checkbox)
            Spacer()
            Button {
                model.copy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the selected objects (or all shown) with their digests")
            Button {
                model.exportJSON(from: NSApp.keyWindow)
            } label: {
                Label("Export JSON…", systemImage: "square.and.arrow.up")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var table: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("Object") { row in
                Text(row.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.path)
            }
            .width(min: 220, ideal: 340)
            TableColumn("State") { row in
                Label(row.state, systemImage: row.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(row.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    .labelStyle(.titleAndIcon)
            }
            .width(min: 80, ideal: 100, max: 140)
            TableColumn("Stored digest") { row in
                Text(row.digest ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.digest ?? "")
            }
            .width(min: 200, ideal: 360)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Copy Digest") {
                copyToPasteboard(model.rows.filter { ids.contains($0.id) }.compactMap(\.digest).joined(separator: "\n"))
            }
            Button("Copy Path") { copyToPasteboard(ids.sorted().joined(separator: "\n")) }
        }
        .onCopyCommand {
            let rows = model.rows.filter { model.selection.contains($0.id) }
            return [NSItemProvider(object: IntegrityPresentation.text(rows.isEmpty ? model.rows : rows) as NSString)]
        }
    }
}
