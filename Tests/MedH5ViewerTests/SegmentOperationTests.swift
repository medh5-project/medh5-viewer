import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Editing

/// Each operation of the segment editor on the synthetic grid, counted by
/// hand (see `Synthetic`), each one undo step.
@MainActor
final class SegmentOperationTests: XCTestCase {
    private var doc: MedH5Document!
    private var workspace: Workspace!
    private var model: SegmentationModel!
    private var session: EditingSession { workspace.editing }

    override func setUp() async throws {
        let dir = TemporaryDirectory("operations")
        doc = try openDocument(Synthetic.copy(in: dir))
        addTeardownBlock { @MainActor [doc] in doc?.close(); _ = dir }
        workspace = try XCTUnwrap(doc.workspace)
        try await workspace.loadNeeded()
        workspace.viewer.activeViewport = .slice(.axial)
        model = try XCTUnwrap(session.segmentationResource("seg")?.model)
    }

    /// Runs an operation on a class and waits for it.
    private func run(_ kind: SegmentOperationKind, on cls: UInt16, file: StaticString = #filePath, line: UInt = #line) async {
        session.activeClasses["seg"] = cls
        session.operation.kind = kind
        let task = session.runOperation()
        XCTAssertNotNil(task, session.message?.text ?? "not started", file: file, line: line)
        await task?.value
        if let m = session.message, m.isError { XCTFail(m.text, file: file, line: line) }
    }

    private func assertCounts(_ expected: [UInt16: Int], file: StaticString = #filePath, line: UInt = #line) {
        for (c, n) in expected {
            XCTAssertEqual(model.count(c), n, "class \(c)", file: file, line: line)
            XCTAssertEqual(session.voxelCounts("seg")[c, default: 0], n, "kept counts of class \(c)", file: file, line: line)
        }
    }

    func testThresholdPaintsTheBrightVoxels() async {
        session.operation.low = 150
        session.operation.high = 250
        await run(.threshold, on: 3)
        assertCounts([3: 145, 1: 56, 2: 9])
        XCTAssertTrue(model.contains(3, at: Synthetic.island))
        XCTAssertTrue(model.annotatedClassIDs.contains(3), "thresholding a class examines it")
        XCTAssertEqual(doc.undoManager?.undoActionName, "Threshold")
        doc.undoManager?.undo()
        assertCounts([3: 0])
        XCTAssertFalse(model.annotatedClassIDs.contains(3))
    }

    func testThresholdOnTheSliceAtTheCrosshair() async {
        workspace.setCursor(Synthetic.world(3, 6, 6), from: .slice(.axial))
        session.operation.low = 150
        session.operation.high = 250
        session.operation.thresholdOnSlice = true
        await run(.threshold, on: 3)
        assertCounts([3: 36])
    }

    func testRegionGrowingFromTheCrosshairStaysConnected() async {
        workspace.setCursor(Synthetic.world(3, 5, 5), from: .slice(.axial))
        session.operation.growTolerance = 10
        session.operation.growIn3D = true
        await run(.regionGrowing, on: 3)
        assertCounts([3: 144])
        XCTAssertFalse(model.contains(3, at: Synthetic.island), "the bright voxel is not connected")
        doc.undoManager?.undo()
        session.operation.growIn3D = false
        await settle()
        await run(.regionGrowing, on: 3)
        assertCounts([3: 36])
    }

    func testMorphology() async {
        // Dilate the lesion by 1 mm: in-plane neighbours (1 mm), not across
        // slices (2 mm). The blob's slices grow 4 → 10, the corner voxel 1 → 3.
        session.operation.morphology = .dilate
        session.operation.morphologyRadius = 1
        await run(.morphology, on: 2)
        assertCounts([2: 23])
        doc.undoManager?.undo()
        assertCounts([2: 9])
        await settle()
        // Erode by 1 mm: every voxel of the thin blobs has background next to it.
        session.operation.morphology = .erode
        await run(.morphology, on: 2)
        assertCounts([2: 0])
        doc.undoManager?.undo()
        await settle()
        // Open removes what erosion removed; close keeps the ring.
        session.operation.morphology = .open
        await run(.morphology, on: 2)
        assertCounts([2: 0])
        doc.undoManager?.undo()
        await settle()
        session.operation.morphology = .close
        session.operation.morphologyRadius = 1
        await run(.morphology, on: 1)
        XCTAssertGreaterThanOrEqual(model.count(1), 56)
    }

    func testFillHolesInEachSliceFillsTheRings() async {
        session.operation.holesIn2D = false
        await run(.fillHoles, on: 1)
        assertCounts([1: 56])
        XCTAssertEqual(session.message?.text, "Fill Holes changed nothing.", "open along z: no cavity in 3-D")
        session.operation.holesIn2D = true
        await run(.fillHoles, on: 1)
        assertCounts([1: 128])
        XCTAssertTrue(model.contains(1, at: SIMD3(1, 5, 5)))
    }

    func testKeepLargestComponentAndRemoveIslands() async {
        await run(.keepLargest, on: 2)
        assertCounts([2: 8])
        XCTAssertFalse(model.contains(2, at: SIMD3(0, 11, 11)))
        doc.undoManager?.undo()
        assertCounts([2: 9])
        await settle()
        // Components under 4 mm³ (2 voxels of 2 mm³) go.
        session.operation.islandMinimumVolume = 4
        await run(.removeIslands, on: 2)
        assertCounts([2: 8])
    }

    func testInterpolationFillsTheSlicesBetween() async {
        workspace.setCursor(Synthetic.world(2, 6, 6), from: .slice(.axial))
        await run(.interpolate, on: 1)
        // The same ring on slices 2 and 3.
        assertCounts([1: 112])
        for z in 1...4 { XCTAssertTrue(model.contains(1, at: SIMD3(z, 2, 5)), "slice \(z)") }
        XCTAssertFalse(model.contains(1, at: SIMD3(2, 5, 5)))
    }

    func testLogicalOperations() async {
        // One layer (a label map): a voxel holds one class, so copying A
        // into B takes A's voxels.
        session.operation.logical = .copy
        session.operation.logicalOther = 3
        await run(.logical, on: 2)
        assertCounts([2: 0, 3: 9])
        await settle()
        session.operation.logical = .swap
        session.operation.logicalOther = 3
        await run(.logical, on: 1)
        assertCounts([1: 9, 3: 56])
        await settle()
        // Classes of one layer never share a voxel: A ∩ B is empty.
        session.operation.logical = .intersect
        session.operation.logicalOther = 3
        await run(.logical, on: 1)
        assertCounts([1: 0, 3: 56])
        await settle()
        session.operation.logical = .clear
        await run(.logical, on: 3)
        assertCounts([3: 0])
        XCTAssertTrue(model.annotatedClassIDs.contains(3), "a cleared class stays examined")
        // Each was a step.
        for _ in 0..<4 {
            doc.undoManager?.undo()
            await settle()
        }
        assertCounts([1: 56, 2: 9, 3: 0])
        XCTAssertTrue(doc.pendingEdits.isEmpty)
    }

    func testOperationsRespectLockedClasses() async {
        session.setLocked(2, true, in: "seg")
        session.activeClasses["seg"] = 2
        XCTAssertFalse(session.operationAvailability(.keepLargest).isAvailable)
        XCTAssertNil(session.runOperation(.keepLargest))
        assertCounts([2: 9])
        // Painting over a locked class leaves it.
        session.setLocked(2, false, in: "seg")
        session.setLocked(1, true, in: "seg")
        session.operation.logical = .copy
        session.operation.logicalOther = 1
        await session.runOperation(.logical)?.value
        XCTAssertEqual(session.message?.isError, true, "copying into a locked class is refused")
        assertCounts([1: 56, 2: 9])
        // A threshold over everything paints around the locked class.
        session.operation.low = -1000
        session.operation.high = 1000
        await run(.threshold, on: 3)
        assertCounts([1: 56, 2: 0, 3: 8 * 12 * 12 - 56])
    }

    func testTheFillToolFillsTheClickedRegion() async throws {
        workspace.setCursor(Synthetic.world(4, 6, 6), from: .slice(.axial))
        session.activeClasses["seg"] = 1
        session.fill.criterion = .sameLabels
        session.fill.is3D = false
        session.select(.fill)
        let driver = ToolDriver(workspace: workspace)
        // Inside the ring of slice 4: its empty inside.
        XCTAssertTrue(driver.send(.mouseDown, Synthetic.world(4, 5, 5)))
        driver.send(.mouseUp, Synthetic.world(4, 5, 5))
        await session.currentTask?.value
        XCTAssertNil(session.message.flatMap { $0.isError ? $0.text : nil })
        assertCounts([1: 56 + 36])
        XCTAssertEqual(doc.undoManager?.undoActionName, "Fill")
        // Outside the ring the fill would take the slice's whole background:
        // 144 − 64 voxels.
        session.activeClasses["seg"] = 3
        driver.send(.mouseDown, Synthetic.world(4, 0, 0))
        driver.send(.mouseUp, Synthetic.world(4, 0, 0))
        await session.currentTask?.value
        assertCounts([3: 144 - 64])
        // Region growing by value, in 3-D.
        doc.undoManager?.undo()
        await settle()
        session.fill.criterion = .tolerance
        session.fill.tolerance = 10
        session.fill.is3D = true
        driver.send(.mouseDown, Synthetic.world(3, 5, 5))
        driver.send(.mouseUp, Synthetic.world(3, 5, 5))
        await session.currentTask?.value
        assertCounts([3: 144])
    }
}
