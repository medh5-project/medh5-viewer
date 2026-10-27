import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

/// Every file of the engine's conformance corpus (valid, invalid, later
/// minors, robustness fixtures) opens into a workspace without crashing,
/// and builds its sidebar and default scenes.
@MainActor
final class CorpusTests: XCTestCase {
    func testEveryCorpusFileOpensOrIsRefusedCleanly() throws {
        let dir = TemporaryDirectory("corpus")
        let manifest = try Conformance.write(to: dir.url)
        if let copy = ProcessInfo.processInfo.environment["MEDH5_VIEWER_EXPORT_CORPUS"] {
            try? FileManager.default.removeItem(atPath: copy)
            try? FileManager.default.copyItem(at: dir.url, to: URL(fileURLWithPath: copy))
        }
        var opened = 0, refused = 0, projections = 0
        let files = manifest.cases.map(\.file) + manifest.robustness
        for file in files where file.hasSuffix(".medh5") {
            let url = dir.url.appendingPathComponent(file)
            guard let sample = try? SampleFile.open(url) else { refused += 1; continue }
            if ProcessInfo.processInfo.environment["MEDH5_VIEWER_CORPUS_TRACE"] == "1" { print("corpus file \(file)"); fflush(stdout) }
            opened += 1
            let w = Workspace(file: sample, displayName: file, context: nil)
            if w.summary.support == .projection {
                projections += 1
                XCTAssertTrue(w.isReadOnly, file)
            }
            _ = SidebarBuilder.flatten(w.sections)
            for id in ViewPlane.allCases.map(ViewportID.slice) {
                _ = SliceSceneBuilder(workspace: w, viewport: id).build(size: SIMD2(64, 64), scale: 1)
            }
            _ = InfoBuilder(workspace: w).sections(for: "sample")
            w.shutDown()
            sample.close()
        }
        XCTAssertGreaterThan(opened, 0)
        print("corpus: \(opened) opened, \(refused) refused, \(projections) projections")
    }
}
