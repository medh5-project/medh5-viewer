import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Render
import MedH5Editing

/// The Brush and Eraser through the slice tools: a stroke paints the
/// segmentation model the views draw, uploads only its dirty boxes, is one
/// undo step restoring voxels and pending edits, and stays interactive on
/// a 512³ volume.
@MainActor
final class BrushStrokeTests: XCTestCase {
    private func open(_ tag: String) async throws -> (MedH5Document, Workspace, SegmentationResource) {
        let dir = TemporaryDirectory(tag)
        let doc = try openDocument(Synthetic.copy(in: dir))
        addTeardownBlock { @MainActor in doc.close(); _ = dir }
        let w = try XCTUnwrap(doc.workspace)
        try await w.loadNeeded()
        w.viewer.activeViewport = .slice(.axial)
        // The axial slice through z index 3.
        w.setCursor(Synthetic.world(3, 6, 6), from: .slice(.axial))
        let res = try XCTUnwrap(w.editing.segmentationResource("seg"))
        return (doc, w, res)
    }

    private func layer(_ model: SegmentationModel) -> [UInt16] {
        Array(UnsafeBufferPointer(start: model.values(ofLayer: 0), count: model.voxelCount))
    }

    func testAStrokePaintsTheModelAndUploadsOnlyItsDirtyBoxes() async throws {
        let (doc, w, res) = try await open("stroke")
        let s = w.editing
        let model = res.model
        XCTAssertEqual(s.activeSegmentation, "seg", "the topmost segmentation shown")
        s.activeClasses["seg"] = 3
        s.brush.radius = 1.5
        s.select(.brush)
        XCTAssertEqual(w.viewer.tool, .brush)
        XCTAssertEqual(s.voxelCounts("seg")[1], 56, "the engine's counts at load")
        XCTAssertFalse(model.annotatedClassIDs.contains(3))
        res.syncTextures()
        let texture = res.textures.first
        let versionBefore = texture?.version ?? 0

        let driver = ToolDriver(workspace: w)
        XCTAssertTrue(driver.send(.mouseDown, Synthetic.world(3, 6, 2)), "the brush takes the plain click")
        // The first dab is in the model at once; it marks the views dirty.
        XCTAssertTrue(model.contains(3, at: SIMD3(3, 6, 2)))
        XCTAssertTrue(model.hasPendingRenderUpdate)
        // A scene build uploads the dab's box only (1.5 mm: a 3 × 3 block).
        _ = SliceSceneBuilder(workspace: w, viewport: .slice(.axial)).build(size: SIMD2(64, 64), scale: 1)
        XCTAssertFalse(model.hasPendingRenderUpdate)
        if let texture, let region = texture.changedRegion(since: versionBefore) {
            XCTAssertTrue(VoxelBox(lower: SIMD3(3, 5, 1), upper: SIMD3(4, 8, 4)).contains(region), "\(region)")
        }
        // A far drag: the dabs between the samples leave no gap.
        XCTAssertTrue(driver.send(.mouseDragged, Synthetic.world(3, 6, 10)))
        XCTAssertTrue(driver.send(.mouseUp, Synthetic.world(3, 6, 10)))
        for x in 2...10 { XCTAssertTrue(model.contains(3, at: SIMD3(3, 6, x)), "x \(x)") }
        // A 2-D disc: one slice.
        XCTAssertFalse(model.contains(3, at: SIMD3(2, 6, 5)))
        XCTAssertFalse(model.contains(3, at: SIMD3(4, 6, 5)))
        XCTAssertTrue(model.contains(3, at: SIMD3(3, 7, 5)))
        XCTAssertFalse(model.contains(3, at: SIMD3(3, 8, 5)), "√4 = 2 mm > 1.5 mm")
        // Painting marks the class examined; the counts follow.
        XCTAssertTrue(model.annotatedClassIDs.contains(3))
        XCTAssertEqual(s.voxelCounts("seg")[3], model.count(3))
        XCTAssertEqual(s.voxelCounts("seg")[1], model.count(1))
        // One undo step, the segmentation is pending.
        XCTAssertEqual(doc.pendingEdits.editedSegmentations, ["seg"])
        XCTAssertEqual(doc.undoManager?.undoActionName, "Paint")
        XCTAssertEqual(w.summary.annotation("seg")?.annotatedClassIDs, [1, 2, 3], "the sidebar's coverage follows")
    }

    func testUndoAndRedoRestoreTheVoxelsAndThePendingEdits() async throws {
        let (doc, w, res) = try await open("undo")
        let s = w.editing
        let model = res.model
        s.activeClasses["seg"] = 3
        s.brush.radius = 2
        s.select(.brush)
        let before = layer(model)
        let metadataBefore = model.annotatedClassIDs
        ToolDriver(workspace: w).drag([Synthetic.world(3, 5, 3), Synthetic.world(3, 6, 6), Synthetic.world(3, 7, 9)])
        let after = layer(model)
        XCTAssertNotEqual(before, after)
        await settle()
        XCTAssertTrue(doc.isDocumentEdited)

        doc.undoManager?.undo()
        await settle()
        XCTAssertEqual(layer(model), before)
        XCTAssertEqual(model.annotatedClassIDs, metadataBefore, "the coverage comes back too")
        XCTAssertTrue(doc.pendingEdits.isEmpty)
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertEqual(s.voxelCounts("seg")[3, default: 0], 0)
        XCTAssertEqual(doc.undoManager?.redoActionName, "Paint")

        doc.undoManager?.redo()
        await settle()
        XCTAssertEqual(layer(model), after)
        XCTAssertEqual(doc.pendingEdits.editedSegmentations, ["seg"])
        XCTAssertEqual(s.voxelCounts("seg")[3], model.count(3))
        XCTAssertTrue(doc.isDocumentEdited)
    }

    func testTwoStrokesAreTwoStepsAndLocksSurviveUndo() async throws {
        let (doc, w, res) = try await open("steps")
        let s = w.editing
        let model = res.model
        s.activeClasses["seg"] = 3
        s.brush.radius = 1
        s.select(.brush)
        let driver = ToolDriver(workspace: w)
        driver.drag([Synthetic.world(3, 6, 4), Synthetic.world(3, 6, 5)])
        await settle()
        let afterFirst = layer(model)
        driver.drag([Synthetic.world(3, 9, 4), Synthetic.world(3, 9, 5)])
        await settle()
        // A lock is a setting of the window: no step, kept through undo.
        s.setLocked(1, true, in: "seg")
        XCTAssertTrue(model.isLocked(1))
        doc.undoManager?.undo()
        await settle()
        XCTAssertEqual(layer(model), afterFirst)
        XCTAssertTrue(model.isLocked(1), "undo does not unlock")
        XCTAssertTrue(doc.undoManager?.canUndo ?? false)
        doc.undoManager?.undo()
        await settle()
        XCTAssertFalse(model.annotatedClassIDs.contains(3))
        XCTAssertTrue(model.isLocked(1))
    }

    func testTheEraserRemovesTheActiveClassAndLockedClassesStay() async throws {
        let (doc, w, res) = try await open("eraser")
        let s = w.editing
        let model = res.model
        w.setCursor(Synthetic.world(4, 6, 6), from: .slice(.axial))
        s.activeClasses["seg"] = 1
        s.brush.radius = 3
        s.select(.eraser)
        let driver = ToolDriver(workspace: w)
        driver.drag([Synthetic.world(4, 2, 2), Synthetic.world(4, 2, 9)])
        XCTAssertFalse(model.contains(1, at: SIMD3(4, 2, 5)))
        XCTAssertTrue(model.annotatedClassIDs.contains(1), "erasing leaves the class examined (an examined absence)")
        XCTAssertEqual(doc.undoManager?.undoActionName, "Erase")
        // A locked class is refused: nothing changes, the reason is shown.
        s.setLocked(1, true, in: "seg")
        XCTAssertFalse(s.availability(.eraser).isAvailable)
        let before = layer(model)
        driver.drag([Synthetic.world(4, 9, 2), Synthetic.world(4, 9, 9)])
        XCTAssertEqual(layer(model), before)
        XCTAssertNotNil(s.message?.text)
        // Painting another class over a locked one leaves it.
        s.activeClasses["seg"] = 3
        s.brush.radius = 3
        s.select(.brush)
        driver.drag([Synthetic.world(4, 9, 2), Synthetic.world(4, 9, 9)])
        XCTAssertTrue(model.contains(1, at: SIMD3(4, 9, 5)))
        XCTAssertTrue(model.contains(3, at: SIMD3(4, 8, 5)))
    }

    func testModifiedDragsAndScrollingStayWithNavigation() async throws {
        let (_, w, _) = try await open("navigation")
        let s = w.editing
        s.select(.brush)
        let driver = ToolDriver(workspace: w)
        XCTAssertFalse(driver.send(.mouseDown, Synthetic.world(3, 6, 6), modifiers: .option), "⌥-drag pans")
        XCTAssertFalse(driver.send(.scrollWheel, Synthetic.world(3, 6, 6)))
        XCTAssertFalse(driver.send(.mouseMoved, Synthetic.world(3, 6, 6)), "the status bar still follows the pointer")
        XCTAssertEqual(s.viewState(.slice(.axial)).pointer, Synthetic.world(3, 6, 6), "the brush cursor follows it too")
        // The cursor is drawn in the view, sized in millimetres.
        let scene = SliceSceneBuilder(workspace: w, viewport: .slice(.axial)).build(size: SIMD2(64, 64), scale: 1).scene
        let circles = scene?.overlays.filter {
            if case .circle(_, let r, _, _) = $0.shape { return r == s.brush.radius }
            return false
        } ?? []
        XCTAssertEqual(circles.count, 1)
    }

    /// The cost of a stroke on 512³: each mouse sample paints its dabs and
    /// the frame uploads only their box.
    func testAStrokeOnA512CubedVolumeStaysInteractive() throws {
        let grid = GridGeometry(id: "big", shape: [512, 512, 512], spacing: [1, 1, 1], origin: [0, 0, 0],
                                direction: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], timepoint: nil, frameUID: "f")
        let metadata = SegmentationMetadata(classes: [SegmentClass(id: 1, key: "a", name: "A")], classIDs: [1], layerCount: 1)
        let model = try SegmentationModel(geometry: grid, metadata: metadata)
        let context = RenderContext.shared
        let textures = try context.map { [try VolumeTexture(context: $0, labels: model.layers[0], geometry: model.geometry)] } ?? []
        let res = SegmentationResource(
            info: try ProvisionalInfo.segmentation(id: "big", grid: grid, task: "segmentation", timepoints: [], model: model),
            plan: try ProvisionalInfo.plan(id: "big", grid: grid, model: model), model: model, textures: textures,
            ignoreRegion: nil, ignoreTexture: nil, classStats: [:], context: context)
        let stroke = try BrushStroke(model: model, operation: .paint(1),
                                     brush: .disc(radius: 10, plane: PlaneAxes.standard(.axial)))
        var worst = 0.0
        for i in 0..<60 {
            let p = SIMD3<Double>(60 + Double(i) * 6, 256, 256)
            let versionBefore = res.textures.first?.version ?? 0
            let start = Date()
            try stroke.add(p)
            res.syncTextures()
            worst = max(worst, Date().timeIntervalSince(start))
            if let t = res.textures.first, let region = t.changedRegion(since: versionBefore) {
                XCTAssertLessThan(region.voxelCount, 24 * 32 * 32, "sample \(i) uploads \(region)")
            }
        }
        let edit = stroke.finish()
        XCTAssertGreaterThan(edit.voxelCount, 60 * 6 * 15)
        XCTAssertLessThan(worst, 0.1, "the slowest mouse sample took \(Int(worst * 1000)) ms")
    }
}
