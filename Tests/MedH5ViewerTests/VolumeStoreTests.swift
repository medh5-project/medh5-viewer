import XCTest
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Render

/// The volume store: loads once, reports failures, keeps to its memory
/// budget by evicting the least recently used resources no view uses.
@MainActor
final class VolumeStoreTests: XCTestCase {
    func testLoadsOnceAndSharesTheResult() async throws {
        let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: nil)
        let a = try await store.resource(.image("CT_tp0"), as: ImageResource.self)
        let b = try await store.resource(.image("CT_tp0"), as: ImageResource.self)
        XCTAssertTrue(a === b)
        XCTAssertEqual(a.volume.data.scalarType, .int16, "held raw, in the stored type")
        XCTAssertEqual(store.totalBytes, a.byteCount)
        XCTAssertTrue(store.isIdle)
    }

    func testFailuresAreReportedNotThrownAtTheViews() async throws {
        let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: nil)
        do {
            _ = try await store.resource(.image("no_such_image"))
            XCTFail("expected a failure")
        } catch {}
        XCTAssertNotNil(store.failure(.image("no_such_image")))
        // A failed resource is not retried by a request, only by retry.
        store.request(.image("no_such_image"))
        XCTAssertNotNil(store.failure(.image("no_such_image")))
    }

    func testTheBudgetEvictsLeastRecentlyUsedResourcesNoViewUses() async throws {
        let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: nil)
        var budget = Int.max
        store.budget = { budget }
        let ct0 = try await store.resource(.image("CT_tp0"))
        let ct1 = try await store.resource(.image("CT_tp1"))
        let mr = try await store.resource(.image("MR_tp0"))
        XCTAssertEqual(store.totalBytes, ct0.byteCount + ct1.byteCount + mr.byteCount)
        // Use CT_tp0 again: CT_tp1 is now the least recently used.
        _ = store.ready(.image("CT_tp0"), as: ImageResource.self)
        store.inUse = [.image("MR_tp0")]
        budget = ct0.byteCount + mr.byteCount
        let evicted = store.enforceBudget()
        XCTAssertEqual(evicted, [.image("CT_tp1")])
        XCTAssertTrue(store.isReady(.image("CT_tp0")))
        XCTAssertFalse(store.isReady(.image("CT_tp1")))
        XCTAssertEqual(store.totalBytes, ct0.byteCount + mr.byteCount)
        XCTAssertEqual(store.evictionCount, 1)
        // In use is never evicted, even over budget; pinned neither.
        store.pin(.image("CT_tp0"))
        budget = 0
        XCTAssertEqual(store.enforceBudget(), [])
        XCTAssertTrue(store.isReady(.image("MR_tp0")))
        XCTAssertTrue(store.isReady(.image("CT_tp0")))
        store.unpin(.image("CT_tp0"))
        XCTAssertEqual(store.enforceBudget(), [.image("CT_tp0")])
        // An evicted resource loads again when asked.
        let again = try await store.resource(.image("CT_tp1"), as: ImageResource.self)
        XCTAssertEqual(again.volume.id, "CT_tp1")
    }

    func testCancelAllForgetsEverything() async throws {
        let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: nil)
        _ = try await store.resource(.image("CT_tp0"))
        store.request(.image("CT_tp1"))
        store.cancelAll()
        XCTAssertTrue(store.states.isEmpty)
        XCTAssertEqual(store.totalBytes, 0)
    }

    func testTexturesAreMadeOnceAndShared() async throws {
        guard let context = RenderContext.shared else { throw XCTSkip("no Metal device") }
        let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: context)
        let t1 = try await store.resource(.imageFrame("CT_tp0", frame: []), as: TextureResource.self)
        let t2 = try await store.resource(.imageFrame("CT_tp0", frame: []), as: TextureResource.self)
        XCTAssertTrue(t1.texture === t2.texture)
        let seg = try await store.resource(.segmentation("organs_tp0"), as: SegmentationResource.self)
        XCTAssertEqual(seg.textures.count, seg.model.layers.count)
        XCTAssertEqual(seg.model.classIDs, [2, 3, 5, 6, 7, 8, 9])
        XCTAssertEqual(seg.model.annotatedClassIDs, [2, 3, 5, 6, 8, 9], "coverage kept apart in the editor's model")
        // A placement through the stored affine.
        let key = PlacementKey(from: "ct_tp0", to: "ct_tp1", fieldGrid: "ct_tp0")
        let placement = try await store.resource(.placement(key), as: PlacementResource.self)
        XCTAssertNotNil(placement.transform?.matrix)
        XCTAssertTrue(placement.summary.contains("tp0_to_tp1"))
    }
}
