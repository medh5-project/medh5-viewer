import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Render

/// Layer stacks on the demo sample: defaults, every annotation kind as a
/// layer, the resources each needs, and the scenes they render as.
@MainActor
final class LayerStackTests: XCTestCase {
    func testTheDefaultStackIsTheBaselineCTWithItsSegmentation() throws {
        let w = try Workspace.demo(context: nil)
        XCTAssertEqual(w.primary.base?.id, "CT_tp0")
        XCTAssertEqual(w.primary.layers.map(\.id), ["CT_tp0", "organs_tp0"])
        XCTAssertEqual(w.referenceGrid(of: w.primary)?.id, "ct_tp0")
        XCTAssertEqual(w.timepoint(of: w.primary), "tp0")
        // The CT takes its stored window first.
        let ct = try XCTUnwrap(w.primary.base)
        XCTAssertEqual(ct.windowCenter, 50)
        XCTAssertEqual(ct.windowWidth, 400)
        XCTAssertFalse(ct.needsAutoWindow)
        // The cursor starts at a voxel centre of the reference grid.
        let grid = try XCTUnwrap(w.referenceGrid(of: w.primary))
        let k = grid.index(fromWorld: w.viewer.cursor)
        for a in 0..<3 { XCTAssertEqual(k[a], k[a].rounded(), accuracy: 1e-9) }
    }

    func testEveryAnnotationKindBecomesALayerOfTheRightKind() throws {
        let w = try Workspace.demo(context: nil)
        let expected: [String: LayerKind] = [
            "organs_tp0": .segmentation, "organs_tp1": .segmentation, "lesions_tp0": .instances,
            "lesion_prob_tp1": .probability, "mr_fov": .mask, "lesion_boxes_tp0": .geometric("boxes"),
            "kidney_obb_tp0": .geometric("obb"), "landmarks_tp0": .geometric("keypoints"),
            "fiducials_tp0": .geometric("points"), "fiducials_tp1": .geometric("points"),
            "liver_contours_tp0": .geometric("contours"),
            "centrelines_tp0": .geometric("polylines"), "surfaces_tp0": .geometric("mesh"),
            "response": .classification,
        ]
        for a in w.summary.annotations {
            let layer = try XCTUnwrap(w.makeLayer(a.id), a.id)
            XCTAssertEqual(layer.kind, expected[a.id], a.id)
        }
        let mr = try XCTUnwrap(w.makeLayer("MR_tp0"))
        XCTAssertEqual(mr.windowPreset, "Stored", "the MR's stored window")
        XCTAssertEqual(mr.colormap, .grayscale)
        XCTAssertEqual(w.makeLayer("lesion_prob_tp1")?.probabilityThreshold, w.summary.annotation("lesion_prob_tp1")?.threshold ?? 0.5)
    }

    func testOverlaysAddRemoveAndReorder() throws {
        let w = try Workspace.demo(context: nil)
        w.toggleOverlay("lesion_boxes_tp0")
        w.toggleOverlay("MR_tp0")
        XCTAssertEqual(w.primary.layers.map(\.id), ["CT_tp0", "organs_tp0", "lesion_boxes_tp0", "MR_tp0"])
        XCTAssertEqual(w.primary.layer("MR_tp0")?.colormap, .hotIron, "an image overlay is a fusion")
        w.primary.move("MR_tp0", by: -2)
        XCTAssertEqual(w.primary.layers.map(\.id), ["CT_tp0", "MR_tp0", "organs_tp0", "lesion_boxes_tp0"])
        w.primary.move("MR_tp0", by: -5)
        XCTAssertEqual(w.primary.layers.first?.id, "CT_tp0", "the base stays at the bottom")
        w.toggleOverlay("organs_tp0")
        XCTAssertFalse(w.primary.contains("organs_tp0"))
        // The eye on the base hides it rather than removing it.
        w.toggleOverlay("CT_tp0")
        XCTAssertEqual(w.primary.base?.isVisible, false)
        XCTAssertTrue(w.primary.contains("CT_tp0"))
        // Making another image the base keeps the overlays.
        w.showAsBase("MR_tp0")
        XCTAssertEqual(w.primary.base?.id, "MR_tp0")
        XCTAssertTrue(w.primary.contains("lesion_boxes_tp0"))
        // Reorder as a list does (top first).
        w.showAsBase("CT_tp0")
        w.toggleOverlay("organs_tp0")
        w.toggleOverlay("mr_fov")
        let topFirst = w.primary.overlays.reversed().map(\.id)
        XCTAssertEqual(topFirst, ["mr_fov", "organs_tp0", "lesion_boxes_tp0"])
        w.primary.moveOverlays(fromTopFirst: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(w.primary.overlays.reversed().map(\.id), ["organs_tp0", "lesion_boxes_tp0", "mr_fov"])
    }

    func testResourceKeysFollowTheLayerAndItsFrame() throws {
        let w = try Workspace.demo(context: nil)
        let ref = try XCTUnwrap(w.referenceGrid(of: w.primary))
        func keys(_ id: String) -> [ResourceKey] { w.resourceKeys(for: try! XCTUnwrap(w.makeLayer(id)), reference: ref) }
        XCTAssertEqual(keys("CT_tp0"), [.image("CT_tp0"), .imageFrame("CT_tp0", frame: []), .histogram("CT_tp0", frame: [])])
        XCTAssertEqual(keys("organs_tp0"), [.segmentation("organs_tp0")])
        XCTAssertEqual(keys("lesions_tp0"), [.instanceMap("lesions_tp0")])
        XCTAssertEqual(keys("mr_fov"), [.mask("mr_fov")], "the MR grid shares the baseline frame")
        XCTAssertEqual(keys("surfaces_tp0"), [.geometry("surfaces_tp0")])
        // The follow-up is in another frame: placed through a resolved transform.
        let sampling = PlacementKey(from: "ct_tp0", to: "ct_tp1", fieldGrid: "ct_tp0")
        XCTAssertEqual(keys("organs_tp1"), [.segmentation("organs_tp1"), .placement(sampling)])
        XCTAssertEqual(keys("lesion_prob_tp1"), [.probability("lesion_prob_tp1", classID: 2),
                                                 .probability("lesion_prob_tp1", classID: 9), .placement(sampling)])
        let points = PlacementKey(from: "ct_tp1", to: "ct_tp0", fieldGrid: "ct_tp1")
        XCTAssertEqual(keys("fiducials_tp1"), [.geometry("fiducials_tp1"), .placement(points)])
        // Hidden classes of a probability map are not read.
        let prob = try XCTUnwrap(w.makeLayer("lesion_prob_tp1"))
        prob.setClass(2, visible: false)
        XCTAssertEqual(w.resourceKeys(for: prob, reference: ref).first, .probability("lesion_prob_tp1", classID: 9))
    }

    /// The whole pipeline: every annotation of the baseline, and the
    /// follow-up placed through the stored affine, render as the expected
    /// renderer layers and overlays.
    func testEveryKindRendersOnTheDemo() async throws {
        guard let context = RenderContext.shared else { throw XCTSkip("no Metal device") }
        let w = try Workspace.demo(context: context)
        w.showAllAnnotations()
        w.toggleOverlay("organs_tp1")
        w.toggleOverlay("CT_tp1")
        w.toggleOverlay("fiducials_tp1")
        try await w.loadNeeded()

        let builder = SliceSceneBuilder(workspace: w, viewport: .slice(.axial))
        // Through the lesion (where boxes, keypoints and the mesh are).
        w.viewer.cursor = w.snapToVoxel(Demo.lesionCentre, grid: try XCTUnwrap(w.referenceGrid(of: w.primary)))
        let result = builder.build(size: SIMD2(512, 512), scale: 1)
        let scene = try XCTUnwrap(result.scene)
        XCTAssertTrue(result.presentation.notes.isEmpty, "\(result.presentation.notes)")
        XCTAssertTrue(result.presentation.loading.isEmpty)

        var images = 0, labels = 0, probabilities = 0
        for layer in scene.layers {
            switch layer {
            case .image: images += 1
            case .label: labels += 1
            case .probability: probabilities += 1
            }
        }
        XCTAssertEqual(images, 2, "the base and the follow-up fusion")
        // organs_tp0 (2 layers) + organs_tp1 (1) + lesions (instance map) + mr_fov mask.
        XCTAssertEqual(labels, 5)
        XCTAssertEqual(probabilities, 0, "lesion_prob_tp1 is not a baseline annotation")
        // The follow-up layers are placed through the affine.
        let followUp = scene.layers.filter { $0.volume.geometry.id == "ct_tp1" }
        XCTAssertFalse(followUp.isEmpty)
        for l in followUp { XCTAssertNotNil(l.placement.registration) }
        // Vector overlays: at least boxes, keypoints, the mesh cut and the crosshair.
        XCTAssertGreaterThan(scene.overlays.count, 5)
        XCTAssertEqual(result.presentation.badges.count, 1, "the change-label classification as a badge")
        XCTAssertTrue(result.presentation.badges[0].hasPrefix("response:"))
        // It renders.
        let image = try SliceRenderer(context: context).render(scene: scene)
        XCTAssertEqual(image.width, 512)
    }

    func testAFrameWithoutATransformIsRefused() async throws {
        guard let context = RenderContext.shared else { throw XCTSkip("no Metal device") }
        // A sample with two frames and no transform between them.
        let dir = TemporaryDirectory("refused")
        let url = dir.file("two-frames.medh5")
        let writer = try SampleWriter.create(url: url, options: WriterOptions(sampleID: "s", subjectID: "p"))
        try writer.addTimepoint("tp0", fields: [:])
        for (g, f) in [("ga", "frame-a"), ("gb", "frame-b")] {
            try writer.addGrid(GridGeometry(id: g, shape: [8, 8, 8], spacing: [1, 1, 1], timepoint: "tp0", frameUID: f))
            try writer.addImage(id: "img_\(g)", grid: g, data: VolumeData(scalarType: .int16, shape: [8, 8, 8]),
                                options: ImageWriteOptions(modality: "CT"))
        }
        try writer.commit()
        let w = Workspace(file: try SampleFile.open(url), displayName: "t", context: context)
        w.showAsBase("img_ga")
        w.toggleOverlay("img_gb")
        try await w.loadNeeded()
        let result = SliceSceneBuilder(workspace: w, viewport: .slice(.axial)).build(size: SIMD2(64, 64), scale: 1)
        XCTAssertEqual(result.scene?.layers.count, 1, "the other frame is never assumed aligned")
        XCTAssertTrue(result.presentation.notes.contains { $0.contains("img_gb") && $0.contains("no transform") },
                      "\(result.presentation.notes)")
        let layer = try XCTUnwrap(w.primary.layer("img_gb"))
        guard case .refused = LayerPlacementInfo.state(workspace: w, stack: w.primary, layer: layer) else {
            return XCTFail("expected a refused placement")
        }
    }

    func testSidebarOutlineFollowsTheSummary() throws {
        let w = try Workspace.demo(context: nil)
        XCTAssertEqual(w.sections.map(\.title), ["Timepoints", "Across Timepoints", "Transforms", "Label Set", "Curation"])
        let nodes = SidebarBuilder.flatten(w.sections)
        let organs = try XCTUnwrap(nodes.first { $0.id == "ann:organs_tp0" })
        XCTAssertEqual(organs.badge, "6/7", "coverage: six of seven classes examined")
        XCTAssertTrue(organs.isDisplayable)
        XCTAssertEqual(nodes.first { $0.id == "ann:response" }?.isDisplayable, false)
        XCTAssertNotNil(nodes.first { $0.id == "tf:tp0_to_tp1" })
        XCTAssertEqual(nodes.filter { if case .labelClass = $0.kind { return true } else { return false } }.count, 12)
        // Every image and annotation is listed exactly once.
        let objects = nodes.compactMap(\.objectID)
        XCTAssertEqual(Set(objects), Set(w.summary.images.map(\.id) + w.summary.annotations.map(\.id)))
        XCTAssertEqual(objects.count, Set(objects).count)
        XCTAssertEqual(w.findNode("organs_tp0")?.id, "ann:organs_tp0")
        XCTAssertEqual(w.findNode("Follow-up")?.id, "tp:tp1")
        XCTAssertEqual(w.objectPath(forNode: "ann:organs_tp0"), "annotations/organs_tp0")
    }
}
