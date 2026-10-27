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
        for name in ["validate", "verify", "document", "label-set", "help", "shortcuts", "acknowledgements", "import-nifti"] {
            XCTAssertEqual(try SnapshotOptions.parse(["--snapshot", "--out", "o", "--window", name]).auxiliaryWindow, name)
        }
        XCTAssertThrowsError(try SnapshotOptions.parse(["--snapshot", "--demo", "--out", "o", "--window", "nope"]))
    }

    /// The snapshot mode's scripted edits drive every editing tool.
    func testSnapshotModeWithScriptedEdits() throws {
        guard RenderContext.shared != nil else { throw XCTSkip("no Metal device") }
        let products = Bundle(for: SnapshotTests.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("medh5-viewer")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("the medh5-viewer executable is not built next to the tests")
        }
        let out = TemporaryDirectory("snapshot-edit")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--snapshot", "--demo", "--demo-size", "32", "--out", out.url.path, "--layout", "single",
                             "--inspector", "annotations", "--edit", "all", "--size", "1000x700", "--no-verify", "--timeout", "90"]
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
        XCTAssertEqual(printed.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent },
                       ["window.png", "view-1.png"])
    }

    /// Runs the built executable in snapshot mode on a small demo.
    func testSnapshotModeWritesTheWindowAndEveryViewport() throws {
        guard RenderContext.shared != nil else { throw XCTSkip("no Metal device") }
        let products = Bundle(for: SnapshotTests.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("medh5-viewer")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("the medh5-viewer executable is not built next to the tests")
        }
        let out = TemporaryDirectory("snapshot")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--snapshot", "--demo", "--demo-size", "32", "--out", out.url.path, "--layout", "2x2",
                             "--size", "1000x700", "--no-verify", "--timeout", "90"]
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
        let paths = printed.split(separator: "\n").map(String.init)
        XCTAssertEqual(paths.map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["window.png", "view-1.png", "view-2.png", "view-3.png", "view-4.png"])
        for p in paths {
            let image = try XCTUnwrap(NSImage(contentsOfFile: p), p)
            XCTAssertGreaterThan(image.size.width, 100)
        }
        let window = try XCTUnwrap(NSImage(contentsOfFile: out.file("window.png").path))
        XCTAssertEqual(window.size.width, 1000, accuracy: 1)
    }
}
