import AppKit
import MedH5Kit

/// The entry point the executable calls: parses the command line, then
/// runs the app (or its snapshot mode).
///
///     medh5-viewer [file.medh5 …]
///     medh5-viewer --snapshot <file.medh5 | --demo> --out <dir> [options]
///     medh5-viewer --help | --version
public enum MedH5ViewerApplication {
    @MainActor private static var delegate: AppDelegate?

    public static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(SnapshotOptions.usage)
            exit(0)
        }
        if arguments.contains("--version") {
            print("medh5 Viewer \(AppInfo.version) · medh5 engine \(MedH5.engineVersion) · format \(MedH5.formatVersion)")
            exit(0)
        }
        var snapshot: SnapshotOptions?
        if arguments.contains("--snapshot") {
            do {
                snapshot = try SnapshotOptions.parse(arguments)
            } catch {
                FileHandle.standardError.write(Data("medh5-viewer: \(error)\n\n\(SnapshotOptions.usage)\n".utf8))
                exit(2)
            }
        }
        // Files named on the command line (not AppKit's own -Key value pairs).
        var files: [URL] = []
        var skip = false
        for a in arguments where snapshot == nil {
            if skip { skip = false; continue }
            if a.hasPrefix("-") { skip = !a.hasPrefix("--"); continue }
            let url = URL(fileURLWithPath: a)
            if FileManager.default.fileExists(atPath: url.path) { files.append(url) }
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            _ = DocumentController()
            let d = AppDelegate(snapshot: snapshot, filesToOpen: files)
            delegate = d
            app.delegate = d
            app.setActivationPolicy(snapshot == nil ? .regular : .accessory)
            app.run()
        }
    }
}
