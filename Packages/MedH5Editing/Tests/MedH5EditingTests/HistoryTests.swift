import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

final class HistoryTests: XCTestCase {
    private func randomEdit(_ m: SegmentationModel, _ rng: inout SeededRandom) throws -> VoxelEdit {
        let c = SIMD3(Int.random(in: 0..<m.shape.x, using: &rng), Int.random(in: 0..<m.shape.y, using: &rng),
                      Int.random(in: 0..<m.shape.z, using: &rng))
        let r = Double.random(in: 1...5, using: &rng)
        let op: VoxelOperation
        switch Int.random(in: 0..<5, using: &rng) {
        case 0: op = .erase(UInt16.random(in: 1...3, using: &rng))
        case 1: op = .eraseAll
        case 2: op = .paintIgnore
        default: op = .paint(UInt16.random(in: 1...3, using: &rng))
        }
        let policy: PaintPolicy = Bool.random(using: &rng) ? .overwrite : .onlyEmpty
        let region = Brush.sphere(radius: r).region(at: m.geometry.world(fromIndex: SIMD3<Double>(c)), in: m.geometry)
        return try m.makeEdit(op, over: region, options: PaintOptions(policy: policy))
    }

    func testUndoRedoRestoreBytesExactly() throws {
        let m = try makeModel(shape: [10, 24, 24], spacing: [1.5, 1, 1])
        let history = EditHistory()
        var rng = SeededRandom(11)
        var states = [snapshot(m)]
        var metas = [m.metadata]
        for i in 0..<30 {
            let e = try randomEdit(m, &rng)
            guard !e.isEmpty else { continue }
            m.apply(e)
            history.record(e, name: "edit \(i)")
            states.append(snapshot(m))
            metas.append(m.metadata)
        }
        XCTAssertGreaterThan(states.count, 20)
        // Undo everything, checking every intermediate state.
        for i in stride(from: states.count - 2, through: 0, by: -1) {
            XCTAssertNotNil(history.undo(on: m))
            XCTAssertEqual(snapshot(m), states[i], "after undo to state \(i)")
            XCTAssertEqual(m.metadata, metas[i])
        }
        XCTAssertFalse(history.canUndo)
        // Redo everything.
        for i in 1..<states.count {
            XCTAssertNotNil(history.redo(on: m))
            XCTAssertEqual(snapshot(m), states[i], "after redo to state \(i)")
        }
        XCTAssertFalse(history.canRedo)
    }

    func testRecordingClearsRedoAndUndoRefusesAStaleState() throws {
        let m = try makeModel(shape: [2, 8, 8])
        let history = EditHistory()
        let e1 = try m.makeEdit(.paint(1), over: makeMask(m.shape) { $0.y < 4 })
        m.apply(e1); history.record(e1, name: "A")
        history.undo(on: m)
        XCTAssertTrue(history.canRedo)
        let e2 = try m.makeEdit(.paint(2), over: makeMask(m.shape) { $0.y == 7 })
        m.apply(e2); history.record(e2, name: "B")
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undoActionName, "B")
        // The model changed behind the history's back: undo refuses rather than corrupt it.
        m.apply(try m.makeEdit(.eraseAll, over: makeMask(m.shape) { _ in true }))
        XCTAssertNil(history.undo(on: m))
    }

    func testGroupsComposeIntoOneStep() throws {
        let m = try makeModel(shape: [2, 10, 10])
        let before = snapshot(m)
        let history = EditHistory()
        var events: [String] = []
        history.onEvent = { e in
            switch e {
            case .recorded(let entry): events.append("recorded \(entry.name)")
            case .coalesced: events.append("coalesced")
            case .undone: events.append("undone")
            case .redone: events.append("redone")
            case .discarded(let d): events.append("discarded \(d.count)")
            case .cleared: events.append("cleared")
            }
        }
        history.beginGroup(name: "Stroke")
        for x in 0..<5 {
            let e = try m.makeEdit(.paint(1), over: makeMask(m.shape) { $0.z == x })
            m.apply(e)
            history.record(e, name: "dab")
        }
        history.beginGroup(name: "inner")
        let e = try m.makeEdit(.paint(2), over: makeMask(m.shape) { $0.y == 0 })
        m.apply(e); history.record(e, name: "dab")
        history.endGroup()
        XCTAssertTrue(history.isGrouping)
        history.endGroup()
        XCTAssertEqual(history.undoStack.count, 1)
        XCTAssertEqual(events, ["recorded Stroke"])
        history.undo(on: m)
        XCTAssertEqual(snapshot(m), before)
        XCTAssertEqual(events.last, "undone")
    }

    func testCoalescing() throws {
        let m = try makeModel(shape: [1, 4, 4])
        let history = EditHistory()
        let t0 = Date()
        for i in 0..<3 {
            let e = try m.makeEdit(.paint(1), over: makeMask(m.shape) { $0.z == i })
            m.apply(e)
            history.record(e, name: "nudge", coalescingKey: "k", date: t0.addingTimeInterval(Double(i) * 0.5))
        }
        XCTAssertEqual(history.undoStack.count, 1)
        let late = try m.makeEdit(.paint(1), over: makeMask(m.shape) { $0.z == 3 })
        m.apply(late)
        history.record(late, name: "nudge", coalescingKey: "k", date: t0.addingTimeInterval(10))
        XCTAssertEqual(history.undoStack.count, 2)
        history.undo(on: m)
        history.undo(on: m)
        XCTAssertTrue(voxels(of: 1, in: m).isEmpty)
    }

    func testMemoryStaysBounded() throws {
        let m = try makeModel(shape: [16, 64, 64])
        let history = EditHistory(memoryLimit: 64 << 10, stepLimit: 1000)
        var dropped = 0
        history.onEvent = { if case .discarded(let d) = $0 { dropped += d.count } }
        var rng = SeededRandom(2)
        for i in 0..<80 {
            // Noisy edits so each costs a few kilobytes.
            var mask = VoxelMask(bounds: VoxelBox(shape: m.shape))
            let z = i % 16
            mask.withUnsafeMutableBytes { p in
                for y in 0..<64 { for x in 0..<64 where Bool.random(using: &rng) { p[(z * 64 + y) * 64 + x] = 1 } }
            }
            let e = try m.makeEdit(.paint(UInt16(i % 3 + 1)), over: mask)
            m.apply(e)
            history.record(e, name: "e\(i)")
            XCTAssertLessThanOrEqual(history.totalBytes, max(64 << 10, history.undoStack.last!.byteSize))
        }
        XCTAssertGreaterThan(dropped, 0)
        XCTAssertGreaterThanOrEqual(history.undoStack.count, 1)
        let steps = EditHistory(stepLimit: 5)
        for i in 0..<12 {
            let e = try m.makeEdit(.paint(1), over: makeMask(m.shape) { $0.x == i })
            m.apply(e); steps.record(e, name: "s")
        }
        XCTAssertEqual(steps.undoStack.count, 5)
    }

    func testClassTableAndCoverageChangesUndo() throws {
        let m = try makeModel(shape: [2, 4, 4])
        let history = EditHistory()
        let meta0 = m.metadata
        let edits = [
            try m.addClassEdit(SegmentClass(id: 20, key: "new", name: "New"), overlapping: [1]),
        ]
        for e in edits { m.apply(e); history.record(e, name: "Add class") }
        let e2 = try m.setAnnotatedEdit(1, true)
        m.apply(e2); history.record(e2, name: "Mark examined")
        let e3 = try m.updateClassEdit(20) { $0.name = "Renamed" }
        m.apply(e3); history.record(e3, name: "Rename")
        XCTAssertEqual(m.classInfo(20)?.name, "Renamed")
        XCTAssertEqual(m.annotatedClassIDs, [1])
        history.undo(on: m)
        XCTAssertEqual(m.classInfo(20)?.name, "New")
        history.undo(on: m)
        XCTAssertEqual(m.annotatedClassIDs, [])
        history.undo(on: m)
        XCTAssertEqual(m.metadata, meta0)
        XCTAssertEqual(m.layerCount, 2)
    }
}
