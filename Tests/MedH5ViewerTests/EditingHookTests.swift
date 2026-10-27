import XCTest
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Render
import MedH5Editing

/// What the editing phase builds on: the segmentation model the store holds
/// is the one the views draw; an edit uploads only its dirty boxes.
@MainActor
final class EditingHookTests: XCTestCase {
    func testAVoxelEditReachesTheSharedTextureAsADirtyBox() async throws {
        guard let context = RenderContext.shared else { throw XCTSkip("no Metal device") }
        let w = try Workspace.demo(context: context)
        try await w.loadNeeded()
        let seg = try XCTUnwrap(w.store.ready(.segmentation("organs_tp0"), as: SegmentationResource.self))
        let model = seg.model
        // The textures are linked to the model's layers (no copy).
        XCTAssertEqual(seg.textures.count, model.layers.count)
        _ = model.takeRenderUpdate()
        let layer = try XCTUnwrap(model.layer(of: 3))
        let texture = seg.textures[layer]
        let versionBefore = texture.version

        let k = SIMD3(1, 1, 1)
        let edit = try model.makeEdit(.paint(3), over: VoxelMask(bounds: VoxelBox(voxel: k), bytes: [1]))
        model.apply(edit)
        let revisionBefore = w.editRevision
        w.noteVoxelsChanged()
        XCTAssertEqual(w.editRevision, revisionBefore + 1)

        // The next scene build uploads the dirty box.
        _ = SliceSceneBuilder(workspace: w, viewport: .slice(.axial)).build(size: SIMD2(64, 64), scale: 1)
        XCTAssertEqual(texture.version, versionBefore + 1)
        XCTAssertEqual(texture.changedRegion(since: versionBefore), VoxelBox(voxel: k))
        XCTAssertFalse(model.hasPendingRenderUpdate)
    }
}
