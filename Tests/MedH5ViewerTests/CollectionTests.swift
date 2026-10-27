import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

/// `.medh5c` collections: the member list, and members opening read-only.
@MainActor
final class CollectionTests: XCTestCase {
    func testACollectionListsItsMembersAndOpensThemReadOnly() throws {
        let dir = TemporaryDirectory("collection")
        let a = Fixtures.demoCopy(in: dir, name: "a.medh5")
        let b = Fixtures.demoCopy(in: dir, name: "b.medh5")
        let url = dir.file("cohort.medh5c")
        let names = try Collections.pack([a, b], keys: ["case_a", "case_b"], to: url)
        XCTAssertEqual(names, ["case_a", "case_b"])
        if let copy = ProcessInfo.processInfo.environment["MEDH5_VIEWER_EXPORT_COLLECTION"] {
            try? FileManager.default.removeItem(atPath: copy)
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: copy))
        }

        let collection = try MedH5CollectionDocument(contentsOf: url, ofType: MedH5CollectionDocument.typeIdentifier)
        XCTAssertEqual(collection.members.map(\.name), ["case_a", "case_b"])
        XCTAssertEqual(collection.members.first?.sampleID, "demo-abdomen-01")

        let member = try MedH5Document.untitled(from: url, name: "cohort › case_b", readOnly: [.collectionMember("case_b")],
                                                member: "case_b")
        member.makeWindowControllers()
        defer { member.close() }
        XCTAssertTrue(member.isReadOnly)
        XCTAssertEqual(member.displayName, "cohort › case_b")
        XCTAssertEqual(member.workspace?.summary.identity.sampleID, "demo-abdomen-01")
        XCTAssertEqual(member.workspace?.primary.base?.id, "CT_tp0")
    }
}
