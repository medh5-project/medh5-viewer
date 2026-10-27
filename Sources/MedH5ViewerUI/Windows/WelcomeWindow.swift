import AppKit
import SwiftUI
import MedH5Kit

/// The window shown when no document is open: Open…, recent documents,
/// Open Demo Sample, New Sample from NIfTI…, and documentation links.
@MainActor
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private init() {
        let hosting = NSHostingController(rootView: WelcomeView())
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Welcome to medh5 Viewer"
        window.setContentSize(NSSize(width: 760, height: 440))
        window.isRestorable = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    @State private var recents: [URL] = NSDocumentController.shared.recentDocumentURLs
    private let launcher = SampleLauncher.shared

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                Text("medh5 Viewer")
                    .font(.system(size: 30, weight: .semibold))
                    .padding(.top, 8)
                Text("Version \(AppInfo.version) · medh5 engine \(MedH5.engineVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    WelcomeAction(symbol: "folder", title: "Open…", subtitle: "A medh5 sample or collection") {
                        NSDocumentController.shared.openDocument(nil)
                    }
                    WelcomeAction(symbol: "sparkles.rectangle.stack", title: "Open Demo Sample",
                                  subtitle: "A two-visit phantom with every annotation") {
                        launcher.openDemoSample()
                    }
                    WelcomeAction(symbol: "square.and.arrow.down.on.square", title: "New Sample from NIfTI…",
                                  subtitle: "Convert an image with the medh5 engine") {
                        launcher.newSampleFromNIfTI()
                    }
                }
                .padding(.top, 26)
                .frame(width: 320)
                if let busy = launcher.busyMessage {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                }
                Spacer(minLength: 16)
                HStack(spacing: 16) {
                    Link("User Guide", destination: AppInfo.userGuideURL)
                    Link("medh5 Documentation", destination: AppInfo.documentationURL)
                }
                .font(.callout)
                .padding(.bottom, 18)
            }
            .frame(width: 440)
            Divider()
            RecentList(recents: recents)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background.opacity(0.5))
        }
        .frame(width: 760, height: 440)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            recents = NSDocumentController.shared.recentDocumentURLs
        }
    }
}

struct WelcomeAction: View {
    let symbol: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct RecentList: View {
    let recents: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .padding(.bottom, 6)
            if recents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text("No recent documents").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(recents, id: \.self) { url in
                    Button {
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                            if let error { NSApp.presentError(error) } else { WelcomeWindowController.shared.close() }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 12.5, weight: .medium))
                                Text(url.deletingLastPathComponent().path(percentEncoded: false)
                                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

/// Version and links.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
    static let documentationURL = URL(string: "https://medh5.readthedocs.io/")!
    static let userGuideURL = URL(string: "https://github.com/medh5-project/medh5-viewer/blob/main/docs/USER_GUIDE.md")!
    static let issuesURL = URL(string: "https://github.com/medh5-project/medh5-viewer/issues")!
}
