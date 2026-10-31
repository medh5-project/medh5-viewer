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

    func testALoadReachesItsCallerOnlyAfterTheStoreRecordedIt() async throws {
        let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: nil)
        store.request(.image("CT_tp0"))
        store.request(.image("no_such_image"))
        // Both reads end while this test keeps the main actor, so the store,
        // which records a load there, has recorded neither yet.
        keepTheMainActorWhileReadsEnd()
        let image = try await store.resource(.image("CT_tp0"))
        XCTAssertTrue(store.isReady(.image("CT_tp0")))
        XCTAssertEqual(store.totalBytes, image.byteCount)
        do {
            _ = try await store.resource(.image("no_such_image"))
            XCTFail("expected a failure")
        } catch {}
        XCTAssertNotNil(store.failure(.image("no_such_image")))
        XCTAssertTrue(store.isIdle)
    }

    /// Far longer than a read of the demo sample takes. Were a read slower
    /// still, the test above would prove less, but it would not fail.
    private func keepTheMainActorWhileReadsEnd() {
        Thread.sleep(forTimeInterval: 0.25)
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

    func testAResourcePutOverALoadStays() async throws {
        let key = ResourceKey.image("CT_tp0")
        for readEnded in [false, true] {
            let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: nil)
            let own = UnsavedObjectResource()
            giveUpALoad(of: key, in: store, readEnded: readEnded) { store.put(key, own) }
            await Task.yield()
            XCTAssertTrue(store.ready(key, as: UnsavedObjectResource.self) === own)
            XCTAssertEqual(store.totalBytes, own.byteCount)
        }
    }

    func testALoadGivenUpRecordsNothing() async throws {
        let key = ResourceKey.image("CT_tp0")
        let ways: [@MainActor (VolumeStore) -> Void] = [{ $0.evict(key) }, { $0.cancelAll() }]
        for readEnded in [false, true] {
            for giveUp in ways {
                let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: nil)
                giveUpALoad(of: key, in: store, readEnded: readEnded) { giveUp(store) }
                await Task.yield()
                XCTAssertTrue(store.states.isEmpty)
                XCTAssertEqual(store.totalBytes, 0)
            }
        }
    }

    func testALoadGivenUpLeavesTheNextLoadOfItsKeyAlone() async throws {
        let key = ResourceKey.image("CT_tp0")
        for readEnded in [false, true] {
            let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: nil)
            giveUpALoad(of: key, in: store, readEnded: readEnded) { store.evict(key) }
            // Runs after what the first load queued, and before anything the
            // next one can queue, which only starts below.
            let seen = Task { (store.isLoading(key), store.progress[key]) }
            store.request(key)
            let (loading, progress) = await seen.value
            XCTAssertTrue(loading)
            XCTAssertEqual(progress, 0)
            let image = try await store.resource(key)
            XCTAssertTrue(store.isReady(key))
            XCTAssertEqual(store.totalBytes, image.byteCount)
        }
    }

    func testALoadOfAReplacedFileLeavesItsRestartAlone() async throws {
        let key = ResourceKey.image("CT_tp0")
        let store = VolumeStore(file: try SampleFile.open(Fixtures.demo), context: nil)
        store.request(key)
        keepTheMainActorWhileReadsEnd()
        let seen = Task { store.isLoading(key) }
        store.replaceFile(try SampleFile.open(Fixtures.demo))
        let loading = await seen.value
        XCTAssertTrue(loading)
        let image = try await store.resource(key)
        XCTAssertTrue(store.isReady(key))
        XCTAssertEqual(store.totalBytes, image.byteCount)
    }

    /// Starts a load and gives it up, before or after its read ends. By the
    /// time this returns, what the load does next is queued on the main actor.
    private func giveUpALoad(of key: ResourceKey, in store: VolumeStore, readEnded: Bool, _ giveUp: () -> Void) {
        store.request(key)
        if readEnded { keepTheMainActorWhileReadsEnd() }
        giveUp()
        if !readEnded { keepTheMainActorWhileReadsEnd() }
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
