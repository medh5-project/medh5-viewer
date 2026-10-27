import AppKit
import SwiftUI
import Observation
import WebKit

/// The user guide the Help window shows.
enum HelpBook {
    static let guideName = "USER_GUIDE.md"
    /// Where links to the repository's other documents go.
    static let onlineDocs = URL(string: "https://github.com/medh5-project/medh5-viewer/blob/main/docs/")!

    /// The folder holding the guide and its images: the bundle's
    /// `Contents/Resources/Help` (scripts/build-app.sh copies docs/ there),
    /// else `MEDH5_VIEWER_HELP_DIR`, else — in a debug build — the
    /// repository's `docs/`.
    static var directory: URL? {
        let fm = FileManager.default
        func holdsGuide(_ dir: URL) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(guideName).path) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Help", isDirectory: true), holdsGuide(bundled) {
            return bundled
        }
        if let env = ProcessInfo.processInfo.environment["MEDH5_VIEWER_HELP_DIR"] {
            let dir = URL(fileURLWithPath: env, isDirectory: true)
            if holdsGuide(dir) { return dir }
        }
        #if DEBUG
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true)
        if holdsGuide(docs) { return docs }
        #endif
        return nil
    }

    /// The guide as a page: local images inlined (`data:` URLs), links to
    /// the repository's other documents made online ones.
    static func render(directory: URL) throws -> (html: String, headings: [MarkdownRenderer.Heading]) {
        let text = try String(contentsOf: directory.appendingPathComponent(guideName), encoding: .utf8)
        return renderer(directory: directory).page(text, title: "medh5 Viewer Help")
    }

    static func renderer(directory: URL) -> MarkdownRenderer {
        var r = MarkdownRenderer()
        r.resolveImage = { src in
            if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("data:") { return src }
            let path = src.removingPercentEncoding ?? src
            let file = directory.appendingPathComponent(path).standardizedFileURL
            guard file.path.hasPrefix(directory.standardizedFileURL.path), let data = try? Data(contentsOf: file) else { return nil }
            return "data:\(mimeType(file.pathExtension));base64,\(data.base64EncodedString())"
        }
        r.resolveLink = { href in
            if href.hasPrefix("#") || href.contains(":") { return href }
            return URL(string: href, relativeTo: onlineDocs)?.absoluteString ?? href
        }
        return r
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}

/// The Help window's state: the rendered guide, its contents, the web view.
@MainActor
@Observable
final class HelpModel {
    private(set) var headings: [MarkdownRenderer.Heading] = []
    private(set) var loadError: String?
    /// The page finished loading (the snapshot mode waits for it).
    private(set) var isLoaded = false
    var search = ""
    var selection: String?
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let navigation = HelpNavigation()
    @ObservationIgnored private var pendingAnchor: String?
    @ObservationIgnored private var loadedDirectory: URL?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isTextInteractionEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        navigation.model = self
        webView.navigationDelegate = navigation
        webView.allowsMagnification = true
    }

    /// Renders the guide in `directory` (once).
    func load(_ directory: URL) {
        guard loadedDirectory != directory else { return }
        loadedDirectory = directory
        do {
            let (html, headings) = try HelpBook.render(directory: directory)
            self.headings = headings
            isLoaded = false
            webView.loadHTMLString(html, baseURL: nil)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func didFinishLoading() {
        isLoaded = true
        if let anchor = pendingAnchor {
            pendingAnchor = nil
            scroll(to: anchor)
        }
    }

    /// Scrolls the page to a heading.
    func scroll(to anchor: String) {
        guard isLoaded else {
            pendingAnchor = anchor
            return
        }
        selection = anchor
        let behavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "auto" : "smooth"
        let id = JSONValueString.quoted(anchor)
        webView.evaluateJavaScript("var e = document.getElementById(\(id)); if (e) { e.scrollIntoView({behavior: '\(behavior)'}); }")
    }

    /// Finds text in the page.
    func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(text, configuration: configuration) { _ in }
    }
}

/// A JSON string literal for a script.
enum JSONValueString {
    static func quoted(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default:
                if c.value < 0x20 || c == "\u{2028}" || c == "\u{2029}" { out += String(format: "\\u%04x", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }
}

/// Keeps the guide in the window: anchors scroll the page, other links
/// open in the browser.
final class HelpNavigation: NSObject, WKNavigationDelegate {
    weak var model: HelpModel?

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "about" || (url.fragment != nil && url.absoluteString.hasPrefix("about:")) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { model?.didFinishLoading() }
    }
}

/// Help ▸ medh5 Viewer Help: the bundled user guide with its contents; the
/// online guide when none is bundled.
@MainActor
enum HelpWindow {
    static let model = HelpModel()

    /// Shows the guide (at a heading); returns false when no guide is
    /// bundled and the online one was opened instead.
    @discardableResult
    static func show(anchor: String? = nil) -> Bool {
        guard let directory = HelpBook.directory else {
            NSWorkspace.shared.open(AppInfo.userGuideURL)
            return false
        }
        model.load(directory)
        let controller = window()
        controller.show()
        if let anchor { model.scroll(to: anchor) }
        return true
    }

    static func window() -> AppWindowController {
        AppWindowController.shared("help", title: "medh5 Viewer Help", size: NSSize(width: 1040, height: 760),
                                   minSize: NSSize(width: 640, height: 420)) {
            let hosting = NSHostingController(rootView: HelpView(model: model))
            hosting.sizingOptions = []
            return hosting
        }
    }
}

struct HelpView: View {
    @Bindable var model: HelpModel

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Contents")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                List(selection: Binding(get: { model.selection }, set: { anchor in
                    if let anchor { model.scroll(to: anchor) }
                })) {
                    ForEach(model.headings.filter { $0.level <= 3 }, id: \.anchor) { h in
                        Text(h.text)
                            .font(h.level == 1 ? .body.weight(.semibold) : (h.level == 2 ? .body : .callout))
                            .foregroundStyle(h.level == 3 ? .secondary : .primary)
                            .padding(.leading, CGFloat(max(0, h.level - 1)) * 12)
                            .tag(h.anchor)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 180, idealWidth: 230, maxWidth: 320)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in the guide", text: $model.search)
                        .textFieldStyle(.plain)
                        .onSubmit { model.find(model.search) }
                    Button { model.find(model.search, backwards: true) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(model.search.isEmpty)
                        .help("Previous match")
                    Button { model.find(model.search) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(model.search.isEmpty)
                        .help("Next match")
                    Divider().frame(height: 14)
                    Link(destination: AppInfo.userGuideURL) {
                        Label("Online", systemImage: "safari")
                    }
                    .help("The guide on GitHub")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                Divider()
                if let error = model.loadError {
                    NoticeBar(style: .error, text: "The guide could not be read: \(error)")
                }
                HelpWebView(webView: model.webView)
            }
            .frame(minWidth: 420, maxWidth: .infinity)
        }
    }
}

/// The guide's web view.
struct HelpWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
