import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

/// Tools ▸ Build Sampling Index… and Recompress…: the files they make
/// verify; replacing the document's file has the document read the result.
@MainActor
final class StorageToolTests: XCTestCase {
    func testBuildingAnIndexMakesAFileThatVerifies() throws {
        let dir = TemporaryDirectory("index")
        let source = Fixtures.copy(Fixtures.demoWithoutIndex, in: dir, name: "noindex.medh5")
        XCTAssertTrue(try SampleFile.open(source).summary.index.isEmpty)
        let out = dir.file("indexed.medh5")
        let id = try StorageOperations.buildIndex(source: source, out: out, annotations: ["organs_tp0"], maxCoords: 64, seed: 7)
        let indexed = try SampleFile.open(out)
        defer { indexed.close() }
        XCTAssertEqual(indexed.summary.contentID, id)
        XCTAssertEqual(indexed.summary.index.map(\.annotation), ["organs_tp0"])
        XCTAssertEqual(indexed.summary.index.first?.fresh, true)
        XCTAssertTrue(try indexed.verify().ok)
        XCTAssertTrue(try Validator.validate(url: out, level: "integrity").ok)
    }

    func testRecompressingMakesAFileThatVerifiesWithTheSameContentID() throws {
        let dir = TemporaryDirectory("recompress")
        let out = dir.file("portable.medh5")
        let r = try StorageOperations.recompress(source: Fixtures.demo, out: out, profile: "portable", rechunk: false)
        XCTAssertEqual(r["ok"], true)
        let line = StorageOperations.describe(recompression: r)
        XCTAssertTrue(line.contains("the content id is unchanged"), line)
        XCTAssertTrue(line.contains("every digest verifies"), line)
        let file = try SampleFile.open(out)
        defer { file.close() }
        XCTAssertEqual(file.summary.contentID, try SampleFile.open(Fixtures.demo).summary.contentID)
        XCTAssertTrue(try file.verify().ok)
        XCTAssertTrue(file.summary.images.filter { $0.codec != "contiguous" }.allSatisfy { $0.codec?.contains("gzip") ?? false },
                      "\(file.summary.images.map(\.codec))")
        XCTAssertEqual(StorageOperations.profiles.map(\.name), ["archive", "balanced", "portable", "training"])
    }

    /// Replacing the document's file: the tool writes beside it, the result
    /// replaces it, and the document reads the new file.
    func testReplacingTheDocumentsFileReopensIt() async throws {
        let dir = TemporaryDirectory("replace")
        let url = Fixtures.copy(Fixtures.demoWithoutIndex, in: dir, name: "sample.medh5")
        let doc = try MedH5Document.openForTest(url)
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        let model = StorageToolModel(document: doc, workspace: workspace, tool: .index)
        XCTAssertEqual(model.destination, .replace, "a saved document's file can be replaced")
        XCTAssertTrue(model.canReplace)
        XCTAssertEqual(model.problems, [])
        model.selectedAnnotations = []
        XCTAssertFalse(model.problems.isEmpty, "an index of nothing")
        model.selectedAnnotations = Set(StorageToolModel.indexable(workspace.summary).map(\.id))
        let temp = try StorageOperations.replacementURL(for: url)
        model.perform(source: url, out: temp, replacing: url)
        let deadline = Date().addingTimeInterval(30)
        while (model.state.isRunning || model.result == nil) && model.state.failure == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertNil(model.state.failure)
        XCTAssertTrue(model.result?.contains("now reads the new file") ?? false, model.result ?? "")
        XCTAssertFalse(workspace.summary.index.isEmpty, "the document reads the indexed file")
        XCTAssertEqual(workspace.file.url.standardizedFileURL, url.standardizedFileURL)
        XCTAssertTrue(try workspace.file.verify().ok)
        XCTAssertFalse(doc.isDocumentEdited)

        // An untitled document has no file to replace; with unsaved changes
        // the replacement waits for a save.
        let untitled = StorageToolModel(document: nil, workspace: workspace, tool: .recompress)
        XCTAssertEqual(untitled.destination, .newFile)
        doc.apply("Remove") { $0.removedTransforms.insert("tp0_to_tp1") }
        model.destination = .replace
        XCTAssertTrue(model.problems.contains { $0.contains("Save or revert") })
    }

    func testCollectionMemberKeys() {
        let keys = CollectionMaker.memberKeys([URL(fileURLWithPath: "/a/case 1.medh5"), URL(fileURLWithPath: "/b/case 1.medh5"),
                                               URL(fileURLWithPath: "/c/meta.medh5")])
        XCTAssertEqual(keys, ["case_1", "case_1_2", "importedmeta"])
    }
}
