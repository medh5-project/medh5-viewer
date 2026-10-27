import AppKit
import SwiftUI
import Observation
import MedH5Kit

/// The third-party notices the app ships (THIRD_PARTY_NOTICES.txt in the
/// bundle; scripts/third_party_notices.py writes them from the bridge's
/// dependency graph).
enum Acknowledgements {
    static let onlineURL = URL(string: "https://github.com/medh5-project/medh5-viewer/blob/main/THIRD_PARTY_NOTICES")!

    /// The bundled notices, else `MEDH5_VIEWER_NOTICES`, else — in a debug
    /// build — the repository's.
    static var noticesURL: URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") { return bundled }
        if let env = ProcessInfo.processInfo.environment["MEDH5_VIEWER_NOTICES"], fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("THIRD_PARTY_NOTICES")
        if fm.fileExists(atPath: repo.path) { return repo }
        #endif
        return nil
    }

    struct Package: Identifiable, Hashable {
        var name: String
        var version: String
        var license: String
        var url: String?
        var id: String { "\(name) \(version)" }
    }

    /// The PACKAGES list: `  name version — licence (url)`.
    static func packages(_ text: String) -> [Package] {
        var out: [Package] = []
        var inList = false
        for line in text.components(separatedBy: "\n") {
            if line == "PACKAGES" { inList = true; continue }
            guard inList else { continue }
            if line.hasPrefix("====") { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let dash = t.range(of: " — ") else { continue }
            let head = t[..<dash.lowerBound].split(separator: " ")
            guard head.count >= 2 else { continue }
            var rest = String(t[dash.upperBound...])
            var url: String?
            if rest.hasSuffix(")"), let open = rest.range(of: " (", options: .backwards) {
                url = String(rest[open.upperBound..<rest.index(before: rest.endIndex)])
                rest = String(rest[..<open.lowerBound])
            }
            out.append(Package(name: head.dropLast().joined(separator: " "), version: String(head.last!), license: rest, url: url))
        }
        return out
    }

    /// Where a package's first licence text begins (its line in a section
    /// header after the list).
    static func licenceRange(of package: Package, in text: String) -> NSRange? {
        let ns = text as NSString
        guard let start = text.range(of: "\n====")?.lowerBound else { return nil }
        let from = NSRange(start..<text.endIndex, in: text)
        let r = ns.range(of: "\n\(package.name) \(package.version) (", options: [], range: from)
        guard r.location != NSNotFound else { return nil }
        let line = ns.lineRange(for: NSRange(location: r.location + 1, length: 0))
        return NSRange(location: line.location, length: max(0, line.length - 1))
    }
}

@MainActor
@Observable
final class AcknowledgementsModel {
    private(set) var text = ""
    private(set) var packages: [Acknowledgements.Package] = []
    private(set) var loadError: String?
    var filter = ""
    var selection: String?

    func load() {
        guard text.isEmpty else { return }
        guard let url = Acknowledgements.noticesURL else {
            loadError = "The notices are not bundled with this build. They are online at \(Acknowledgements.onlineURL.absoluteString)."
            return
        }
        do {
            text = try String(contentsOf: url, encoding: .utf8)
            packages = Acknowledgements.packages(text)
        } catch {
            loadError = error.localizedDescription
        }
    }

    var shown: [Acknowledgements.Package] {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return packages }
        return packages.filter { p in
            let t = "\(p.name) \(p.version) \(p.license)".lowercased()
            return words.allSatisfy { t.contains($0) }
        }
    }

    var reveal: NSRange? {
        guard let id = selection, let p = packages.first(where: { $0.id == id }) else { return nil }
        return Acknowledgements.licenceRange(of: p, in: text)
    }
}

/// Help ▸ Acknowledgements (also from the About panel's credits).
@MainActor
enum AcknowledgementsWindow {
    static let model = AcknowledgementsModel()

    static func show() {
        model.load()
        window().show()
    }

    static func window() -> AppWindowController {
        AppWindowController.shared("acknowledgements", title: "Acknowledgements", size: NSSize(width: 980, height: 700),
                                   minSize: NSSize(width: 620, height: 400)) {
            let hosting = NSHostingController(rootView: AcknowledgementsView(model: model))
            hosting.sizingOptions = []
            return hosting
        }
    }
}

struct AcknowledgementsView: View {
    @Bindable var model: AcknowledgementsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Acknowledgements").font(.system(size: 17, weight: .semibold))
                    Text("medh5 Viewer is built on the medh5 engine \(MedH5.engineVersion) and links the \(model.packages.count) packages listed here, with HDF5, C-Blosc2, LZ4, Zstandard and zlib. Each is distributed under its licence; every licence text follows.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Link("Online", destination: Acknowledgements.onlineURL).font(.callout)
            }
            .padding(14)
            Divider()
            if let error = model.loadError {
                NoticeBar(style: .warning, text: error)
                Spacer()
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        TextField("Filter packages", text: $model.filter)
                            .textFieldStyle(.roundedBorder)
                            .padding(8)
                        List(model.shown, selection: $model.selection) { p in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(p.name) \(p.version)")
                                Text(p.license).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(p.id)
                        }
                    }
                    .frame(minWidth: 220, idealWidth: 270, maxWidth: 360)
                    PlainTextView(text: .constant(model.text), isEditable: false,
                                  font: .monospacedSystemFont(ofSize: 11, weight: .regular), reveal: model.reveal)
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .onAppear { model.load() }
    }
}
