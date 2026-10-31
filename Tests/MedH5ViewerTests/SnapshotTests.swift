import XCTest
import AppKit
@testable import MedH5ViewerUI
import MedH5Render

/// The snapshot mode: options, and the executable writing the PNGs.
final class SnapshotTests: XCTestCase {
    func testOptionsParse() throws {
        let o = try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "/tmp/x", "--layout", "2x2", "--size", "1200x800",
                                            "--appearance", "light", "--select", "organs_tp0", "--inspector", "info",
                                            "--overlays", "a,b", "--scale", "2"])
        XCTAssertEqual(o.source, .demo)
        XCTAssertEqual(o.outDirectory.path, "/tmp/x")
        XCTAssertEqual(o.layout, .twoByTwo)
        XCTAssertEqual(o.size, CGSize(width: 1200, height: 800))
        XCTAssertEqual(o.appearance, .aqua)
        XCTAssertEqual(o.select, "organs_tp0")
        XCTAssertEqual(o.inspector, .info)
        XCTAssertEqual(o.overlays, ["a", "b"])
        XCTAssertEqual(o.scale, 2)
        let f = try SnapshotOptions.parse(["--snapshot", "/data/s.medh5", "--out", "o"])
        XCTAssertEqual(f.source, .file(URL(fileURLWithPath: "/data/s.medh5")))
        XCTAssertThrowsError(try SnapshotOptions.parse(["--snapshot", "--demo"]), "needs --out")
        XCTAssertThrowsError(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--layout", "5x5"]))
        XCTAssertThrowsError(try SnapshotOptions.parse(["--snapshot", "--out", "o"]), "needs a source")
        let e = try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--inspector", "segment-editor", "--tool",
                                            "window-level", "--edit", "all"])
        XCTAssertEqual(e.inspector, .segmentEditor)
        XCTAssertEqual(e.tool, .windowLevel)
        XCTAssertEqual(e.editScript, "all")
        XCTAssertEqual(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--inspector", "annotations"]).inspector, .annotations)
        XCTAssertEqual(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--tool", "polyline"]).tool, .polyline)
        XCTAssertThrowsError(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--tool", "lasso"]))
        XCTAssertThrowsError(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--edit", "everything"]))
        XCTAssertEqual(try SnapshotOptions.parse(["--snapshot", "--window", "settings-editing", "--out", "o"]).auxiliaryWindow,
                       "settings-editing")
        let panel = try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--window", "clinical", "--cutoff", "36h",
                                               "--select", "report0_v2"])
        XCTAssertEqual(panel.auxiliaryWindow, "clinical")
        XCTAssertEqual(panel.clinicalCutoffHours, 36)
        XCTAssertEqual(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--slab", "mip:30"]).slab,
                       SlabSettings(mode: .maximum, thickness: 30))
        XCTAssertEqual(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--slab", "average"]).slab,
                       SlabSettings(mode: .mean, thickness: 10))
        XCTAssertThrowsError(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--slab", "mip:0"]))
        XCTAssertThrowsError(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--slab", "max"]))
        for name in ["validate", "verify", "document", "label-set", "help", "shortcuts", "acknowledgements", "import-nifti"] {
            XCTAssertEqual(try SnapshotOptions.parse(["--snapshot", "--out", "o", "--window", name]).auxiliaryWindow, name)
        }
        XCTAssertThrowsError(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--window", "nope"]))
        let plain = try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o"])
        XCTAssertFalse(plain.activate)
        XCTAssertFalse(plain.widestPanels)
        let window = try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--activate", "--widest-panels"])
        XCTAssertTrue(window.activate)
        XCTAssertTrue(window.widestPanels)
    }

    @MainActor
    func testSizeStopsAtTheWindowsMinimum() {
        var options = SnapshotOptions(source: .demo, outDirectory: URL(fileURLWithPath: "/tmp/x"))
        options.size = CGSize(width: 300, height: 900)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 200)
        XCTAssertEqual(options.contentSize(in: window), NSSize(width: 500, height: 900))
    }

    /// From macOS 26 the split views need twice the sidebar's width plus the
    /// inspector's: more than the window has, and AppKit ends the app.
    func testTheWidestPanelsFitTheNarrowestWindow() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("the panels take their own width before macOS 26") }
        XCTAssertLessThanOrEqual(2 * PanelLimits.sidebarMaximum + PanelLimits.inspectorMaximum, PanelLimits.minimumWindowWidth)
    }

    /// The window's way to its tightest, in the layouts with the most to fit.
    func testSnapshotModeWithTheWidestPanelsInTheNarrowestWindow() throws {
        for layout in ["single", "compare", "2x2"] {
            let out = TemporaryDirectory("snapshot-narrow")
            _ = try snapshot(["--layout", layout, "--size", "1000x560", "--widest-panels"], to: out)
            let window = try XCTUnwrap(NSImage(contentsOfFile: out.file("window.png").path))
            XCTAssertEqual(window.size.width, PanelLimits.minimumWindowWidth, accuracy: 1, layout)
        }
    }

    /// Every toolbar item fits a window of the size the app opens at.
    func testTheToolbarFitsTheDefaultWindow() throws {
        let out = TemporaryDirectory("snapshot-toolbar")
        let run = try snapshot(["--layout", "2x2", "--size", "1440x880"], to: out)
        let window = try XCTUnwrap(NSImage(contentsOfFile: out.file("window.png").path))
        XCTAssertEqual(window.size.width, 1440, accuracy: 1, "whatever the display's width")
        XCTAssertFalse(run.errors.contains("toolbar overflow"), run.errors)
    }

    /// The picture is the window server's, with the materials it composites:
    /// the window's rounded corners are transparent in it and nowhere else.
    func testSnapshotModeCapturesWhatTheWindowServerShows() throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("no capture of an app's own window before macOS 14.4") }
        let out = TemporaryDirectory("snapshot-capture")
        _ = try snapshot(["--layout", "single", "--size", "1000x700"], to: out)
        let data = try Data(contentsOf: out.file("window.png"))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 0, y: 0)).alphaComponent, 0)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: 0)).alphaComponent, 1)
    }

    /// The snapshot mode's scripted edits drive every editing tool.
    func testSnapshotModeWithScriptedEdits() throws {
        let run = try snapshot(["--layout", "single", "--inspector", "annotations", "--edit", "all", "--size", "1000x700"],
                               to: TemporaryDirectory("snapshot-edit"))
        XCTAssertEqual(run.printed.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent },
                       ["window.png", "view-1.png"])
    }

    /// Runs the built executable in snapshot mode on a small demo.
    func testSnapshotModeWritesTheWindowAndEveryViewport() throws {
        let out = TemporaryDirectory("snapshot")
        let run = try snapshot(["--layout", "2x2", "--size", "1000x700"], to: out)
        let paths = run.printed.split(separator: "\n").map(String.init)
        XCTAssertEqual(paths.map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["window.png", "view-1.png", "view-2.png", "view-3.png", "view-4.png"])
        for p in paths {
            let image = try XCTUnwrap(NSImage(contentsOfFile: p), p)
            XCTAssertGreaterThan(image.size.width, 100)
        }
        let window = try XCTUnwrap(NSImage(contentsOfFile: out.file("window.png").path))
        XCTAssertEqual(window.size.width, 1000, accuracy: 1)
    }

    /// The built executable in snapshot mode on a small demo: what it printed
    /// and what it complained of, when it ended well.
    private func snapshot(_ arguments: [String], to out: TemporaryDirectory) throws -> (printed: String, errors: String) {
        guard RenderContext.shared != nil else { throw XCTSkip("no Metal device") }
        let products = Bundle(for: SnapshotTests.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("medh5-viewer")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("the medh5-viewer executable is not built next to the tests")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--snapshot", "--demo", "--demo-size", "32", "--out", out.url.path, "--no-verify", "--timeout", "90"]
            + arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0, errors.contains("no window server") || errors.contains("WindowServer") {
            throw XCTSkip("no window server: \(errors)")
        }
        XCTAssertEqual(process.terminationStatus, 0, errors)
        return (printed, errors)
    }
}
