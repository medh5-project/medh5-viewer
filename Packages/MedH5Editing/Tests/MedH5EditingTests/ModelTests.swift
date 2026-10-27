import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

final class ModelTests: XCTestCase {
    // MARK: Creating

    func testImportRegistersLabelsFoundInLayers() throws {
        let g = makeGeometry(shape: [2, 4, 4], spacing: [1, 1, 1])
        let l0 = VolumeData(scalarType: .uint16, shape: [2, 4, 4])
        let l1 = VolumeData(scalarType: .uint16, shape: [2, 4, 4])
        l0.pointer(as: UInt16.self)[0] = 5
        l0.pointer(as: UInt16.self)[1] = 65535
        l1.pointer(as: UInt16.self)[3] = 9
        let meta = SegmentationMetadata(classes: [SegmentClass(id: 5, key: "liver", name: "Liver", layer: 0)],
                                        classIDs: [5, 7], annotatedClassIDs: [5])
            .with { $0.classes.append(SegmentClass(id: 7, key: "kidney", name: "Kidney", layer: 0)) }
        let m = try SegmentationModel(geometry: g, layers: [l0, l1], metadata: meta)
        XCTAssertEqual(m.layerCount, 2)
        XCTAssertEqual(m.classIDs, [5, 7, 9])
        XCTAssertEqual(m.annotatedClassIDs, [5])
        XCTAssertEqual(m.classInfo(9)?.layer, 1)
        XCTAssertEqual(m.classInfo(9)?.key, "class_9")
        XCTAssertTrue(m.isIgnored(at: SIMD3(0, 0, 1)))
        XCTAssertEqual(m.labels(at: SIMD3(0, 0, 0)), [5])
        XCTAssertEqual(m.labels(at: SIMD3(0, 0, 3)), [9])
    }

    func testImportRejectsAClassInTheWrongLayer() throws {
        let g = makeGeometry(shape: [1, 2, 2], spacing: [1, 1, 1])
        let l0 = VolumeData(scalarType: .uint16, shape: [1, 2, 2])
        let l1 = VolumeData(scalarType: .uint16, shape: [1, 2, 2])
        l1.pointer(as: UInt16.self)[0] = 5
        let meta = SegmentationMetadata(classes: [SegmentClass(id: 5, key: "a", name: "A", layer: 0)])
        XCTAssertThrowsError(try SegmentationModel(geometry: g, layers: [l0, l1], metadata: meta))
    }

    func testMetadataValidation() {
        var meta = SegmentationMetadata(classes: [SegmentClass(id: 1, key: "a", name: "A")], classIDs: [1],
                                        annotatedClassIDs: [1, 2])
        XCTAssertThrowsError(try meta.validate()) // annotated ⊄ class_ids
        meta.annotatedClassIDs = [1]
        XCTAssertNoThrow(try meta.validate())
        meta.classes.append(SegmentClass(id: 65535, key: "x", name: "X"))
        XCTAssertThrowsError(try meta.validate()) { XCTAssertEqual($0 as? EditingError, .reservedClassID(65535)) }
        meta.classes.removeLast()
        meta.classes.append(SegmentClass(id: 1, key: "dup", name: "Dup"))
        XCTAssertThrowsError(try meta.validate()) { XCTAssertEqual($0 as? EditingError, .duplicateClass(1)) }
    }

    func testTwoDimensionalGrid() throws {
        let g = makeGeometry(shape: [5, 7], spacing: [0.5, 0.25])
        let m = try SegmentationModel(geometry: g, metadata: SegmentationMetadata(classes: [SegmentClass(id: 1, key: "a", name: "A")]))
        XCTAssertEqual(m.shape, SIMD3(1, 5, 7))
        XCTAssertEqual(m.layers[0].shape, [5, 7])
        let e = try m.makeEdit(.paint(1), over: VoxelRegion(sortedSpans: [.init(k0: 0, k1: 2, start: 1, end: 4)]))
        m.apply(e)
        XCTAssertEqual(voxels(of: 1, in: m).count, 3)
        let stats = try SegmentationStatistics.classStatistics(m, classID: 1)
        XCTAssertEqual(stats.volume, 3 * 0.125, accuracy: 1e-12) // an area on a 2-D grid
        XCTAssertEqual(stats.edgeBox!, [[1.5, 2.5], [0.5, 3.5]])
    }

    // MARK: Queries

    func testLabelsContainsAndFlatten() throws {
        let m = try makeModel(shape: [1, 4, 4], classes: [(1, 0), (2, 0), (3, 1)], inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { $0.z < 2 }
        fillRaw(m, layer: 0, value: 2) { $0.z == 2 }
        fillRaw(m, layer: 1, value: 3) { $0.y < 2 }
        fillRaw(m, layer: 0, value: 65535) { $0.z == 3 && $0.y == 3 }
        XCTAssertEqual(m.labels(at: SIMD3(0, 0, 0)), [1, 3])
        XCTAssertTrue(m.contains(3, at: SIMD3(0, 1, 2)))
        XCTAssertFalse(m.contains(1, at: SIMD3(0, 1, 2)))
        let flat = m.flattened(priority: [3])
        let p = copyValues(flat.labels, as: UInt16.self)
        XCTAssertEqual(p[0], 3) // 1 and 3 overlap: 3 has priority
        XCTAssertEqual(p[2 * 4 + 0], 1)
        XCTAssertEqual(p[3 * 4 + 3], 65535)
        XCTAssertEqual(flat.overlappingVoxels, 2 * 3) // y < 2, z < 3
        let flatDefault = m.flattened()
        XCTAssertEqual(copyValues(flatDefault.labels, as: UInt16.self)[0], 1) // classIDs order
    }

    func testBoundsAndMaskOfClass() throws {
        let m = try makeModel(shape: [5, 6, 7])
        fillRaw(m, layer: 0, value: 2) { $0.x >= 1 && $0.x <= 3 && $0.y == 4 && $0.z >= 2 && $0.z < 6 }
        XCTAssertEqual(m.bounds(of: 2), VoxelBox(lower: SIMD3(1, 4, 2), upper: SIMD3(4, 5, 6)))
        XCTAssertEqual(m.bounds(of: 1), .empty)
        XCTAssertEqual(m.mask(of: 2).memberCount, 12)
        XCTAssertEqual(m.voxelCount(of: 2), 12)
    }

    // MARK: Paint policies

    private func policyModel() throws -> SegmentationModel {
        // Layer 0: classes 1, 2 (exclusive); layer 1: class 3.
        let m = try makeModel(shape: [1, 1, 8], classes: [(1, 0), (2, 0), (3, 1)], inAnnotation: true)
        fillRaw(m, layer: 0, value: 2) { $0.z < 4 }      // B = 2 on x 0..<4
        fillRaw(m, layer: 1, value: 3) { $0.z >= 2 && $0.z < 6 } // C = 3 on x 2..<6
        return m
    }

    private func row(_ m: SegmentationModel, _ layer: Int) -> [UInt16] {
        Array(UnsafeBufferPointer(start: m.layers[layer].pointer(as: UInt16.self), count: 8))
    }

    private let everywhere = VoxelRegion(sortedSpans: [.init(k0: 0, k1: 0, start: 0, end: 8)])

    func testOverwriteReplacesTheSameLayerAndKeepsOthers() throws {
        let m = try policyModel()
        m.apply(try m.makeEdit(.paint(1), over: everywhere, options: PaintOptions(policy: .overwrite)))
        XCTAssertEqual(row(m, 0), [1, 1, 1, 1, 1, 1, 1, 1])
        XCTAssertEqual(row(m, 1), [0, 0, 3, 3, 3, 3, 0, 0]) // another layer: both keep the voxel
    }

    func testOnlyEmpty() throws {
        let m = try policyModel()
        m.apply(try m.makeEdit(.paint(1), over: everywhere, options: PaintOptions(policy: .onlyEmpty)))
        XCTAssertEqual(row(m, 0), [2, 2, 2, 2, 1, 1, 1, 1])
    }

    func testOnlyInsideAnotherClass() throws {
        let m = try policyModel()
        m.apply(try m.makeEdit(.paint(1), over: everywhere, options: PaintOptions(policy: .onlyInside(3))))
        XCTAssertEqual(row(m, 0), [2, 2, 1, 1, 1, 1, 0, 0])
        let m2 = try policyModel()
        m2.apply(try m2.makeEdit(.paint(1), over: everywhere, options: PaintOptions(policy: .onlyInside(2))))
        XCTAssertEqual(row(m2, 0), [1, 1, 1, 1, 0, 0, 0, 0])
    }

    func testLockedClassesAreNeverOverwritten() throws {
        let m = try policyModel()
        m.apply(try m.updateClassEdit(2) { $0.isLocked = true })
        m.apply(try m.makeEdit(.paint(1), over: everywhere))
        XCTAssertEqual(row(m, 0), [2, 2, 2, 2, 1, 1, 1, 1])
        // A locked class cannot be the target either.
        XCTAssertThrowsError(try m.makeEdit(.paint(2), over: everywhere)) { XCTAssertEqual($0 as? EditingError, .classLocked(2)) }
        XCTAssertThrowsError(try m.makeEdit(.erase(2), over: everywhere))
        // Erase-all skips it.
        m.apply(try m.makeEdit(.eraseAll, over: everywhere))
        XCTAssertEqual(row(m, 0), [2, 2, 2, 2, 0, 0, 0, 0])
        XCTAssertEqual(row(m, 1), [0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testEraserOneClassOrAny() throws {
        let m = try policyModel()
        m.apply(try m.makeEdit(.erase(3), over: everywhere))
        XCTAssertEqual(row(m, 1), [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(row(m, 0), [2, 2, 2, 2, 0, 0, 0, 0])
        XCTAssertTrue(m.classIDs.contains(3) && m.annotatedClassIDs.contains(3), "an erased class stays covered")
        let m2 = try policyModel()
        m2.apply(try m2.makeEdit(.eraseAll, over: VoxelRegion(sortedSpans: [.init(k0: 0, k1: 0, start: 1, end: 3)])))
        XCTAssertEqual(row(m2, 0), [2, 0, 0, 2, 0, 0, 0, 0])
        XCTAssertEqual(row(m2, 1), [0, 0, 0, 3, 3, 3, 0, 0])
    }

    func testIgnoreRegion() throws {
        let m = try policyModel()
        // Ignore over x 3..<5: classes there are removed (in-band ignore holds no class).
        m.apply(try m.makeEdit(.paintIgnore, over: VoxelRegion(sortedSpans: [.init(k0: 0, k1: 0, start: 3, end: 5)])))
        XCTAssertEqual(row(m, 0), [2, 2, 2, 65535, 65535, 0, 0, 0])
        XCTAssertEqual(row(m, 1), [0, 0, 3, 0, 0, 3, 0, 0])
        XCTAssertTrue(m.isIgnored(at: SIMD3(0, 0, 4)))
        // onlyEmpty does not paint over ignore.
        m.apply(try m.makeEdit(.paint(3), over: everywhere, options: PaintOptions(policy: .onlyEmpty)))
        XCTAssertEqual(row(m, 1), [3, 3, 3, 0, 0, 3, 3, 3])
        // A locked ignore region is protected from overwrite too.
        m.apply(try m.setIgnoreLockedEdit(true))
        m.apply(try m.makeEdit(.paint(3), over: everywhere))
        XCTAssertEqual(row(m, 1), [3, 3, 3, 0, 0, 3, 3, 3])
        // Unlocked, overwrite replaces the ignore value in every layer.
        m.apply(try m.setIgnoreLockedEdit(false))
        m.apply(try m.makeEdit(.paint(3), over: everywhere))
        XCTAssertEqual(row(m, 1), [3, 3, 3, 3, 3, 3, 3, 3])
        XCTAssertEqual(row(m, 0), [2, 2, 2, 0, 0, 0, 0, 0])
        XCTAssertFalse(m.isIgnored(at: SIMD3(0, 0, 4)))
        m.apply(try m.makeEdit(.paintIgnore, over: everywhere, options: PaintOptions(policy: .onlyEmpty)))
        XCTAssertEqual(row(m, 0), [2, 2, 2, 0, 0, 0, 0, 0], "only empty: every voxel holds a class")
        let e = try m.makeEdit(.eraseIgnore, over: everywhere)
        XCTAssertTrue(e.isEmpty)
    }

    // MARK: Layers

    func testAddingAnOverlappingClassGetsANewLayer() throws {
        let m = try makeModel(shape: [2, 4, 4], classes: [(1, 0), (2, 0)], layerCount: 1, inAnnotation: true)
        let e = try m.addClassEdit(SegmentClass(id: 7, key: "lesion", name: "Lesion"), overlapping: [1])
        XCTAssertEqual(e.metadataChange?.after.layerCount, 2)
        m.apply(e)
        XCTAssertEqual(m.layerCount, 2)
        XCTAssertEqual(m.classInfo(7)?.layer, 1)
        // A class with no overlap constraint goes to the first layer.
        m.apply(try m.addClassEdit(SegmentClass(id: 8, key: "x", name: "X")))
        XCTAssertEqual(m.classInfo(8)?.layer, 0)
        // A class that must overlap 1 and 7 needs a third layer.
        m.apply(try m.addClassEdit(SegmentClass(id: 9, key: "y", name: "Y"), overlapping: [1, 7]))
        XCTAssertEqual(m.classInfo(9)?.layer, 2)
        XCTAssertEqual(m.layerCount, 3)
        // An explicit layer that holds a class to overlap is refused.
        XCTAssertThrowsError(try m.addClassEdit(SegmentClass(id: 10, key: "z", name: "Z"), layer: 0, overlapping: [1]))
    }

    func testEnsureLayerMovesAClassWithItsVoxels() throws {
        let m = try makeModel(shape: [2, 6, 6], classes: [(1, 0), (2, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { $0.y < 3 }
        fillRaw(m, layer: 0, value: 2) { $0.y >= 3 }
        let before = snapshot(m)
        let e = try m.ensureLayer(for: 2, overlapping: [1])
        m.apply(e)
        XCTAssertEqual(m.layerCount, 2)
        XCTAssertEqual(m.classInfo(2)?.layer, 1)
        XCTAssertEqual(voxels(of: 2, in: m).count, 2 * 3 * 6)
        XCTAssertEqual(m.labels(at: SIMD3(0, 4, 0)), [2])
        // Now 2 can be painted over 1 and both keep the voxel.
        m.apply(try m.makeEdit(.paint(2), over: makeMask(m.shape) { $0.y == 1 }))
        XCTAssertEqual(m.labels(at: SIMD3(0, 1, 0)), [1, 2])
        XCTAssertTrue(try m.ensureLayer(for: 2, overlapping: [1]).isEmpty, "already overlapping-capable")
        // Undo restores layers, bytes and table.
        let m2 = try makeModel(shape: [2, 6, 6], classes: [(1, 0), (2, 0)], layerCount: 1, inAnnotation: true)
        fillRaw(m2, layer: 0, value: 1) { $0.y < 3 }
        fillRaw(m2, layer: 0, value: 2) { $0.y >= 3 }
        let e2 = try m2.ensureLayer(for: 2, overlapping: [1])
        m2.apply(e2)
        m2.revert(e2)
        XCTAssertEqual(snapshot(m2), before)
        XCTAssertEqual(m2.layerCount, 1)
        XCTAssertEqual(m2.classInfo(2)?.layer, 0)
    }

    func testMoveClassRefusesAnOccupiedLayer() throws {
        let m = try makeModel(shape: [1, 4, 4], classes: [(1, 0), (3, 1)], layerCount: 2, inAnnotation: true)
        fillRaw(m, layer: 0, value: 1) { $0.y == 0 }
        fillRaw(m, layer: 1, value: 3) { $0.y == 0 && $0.z == 0 }
        XCTAssertThrowsError(try m.moveClassEdit(1, toLayer: 1)) {
            guard case .editConflict = $0 as? EditingError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(try m.ensureLayer(for: 1, overlapping: [3]).isEmpty, "1 does not share a layer with 3")
        // A move to a fresh layer always works.
        let e = try m.moveClassEdit(1, toLayer: 2)
        m.apply(e)
        XCTAssertEqual(m.layerCount, 3)
        XCTAssertEqual(m.labels(at: SIMD3(0, 0, 0)), [3, 1])
    }

    // MARK: Coverage

    func testCoverageInvariants() throws {
        let m = try makeModel(shape: [2, 5, 5])
        XCTAssertEqual(m.classIDs, [])
        // Painting adds to both.
        m.apply(try m.makeEdit(.paint(1), over: makeMask(m.shape) { $0.y == 0 }))
        XCTAssertEqual(m.classIDs, [1])
        XCTAssertEqual(m.annotatedClassIDs, [1])
        // Erasing every voxel keeps both (an examined absence).
        m.apply(try m.makeEdit(.erase(1), over: makeMask(m.shape) { _ in true }))
        XCTAssertEqual(m.classIDs, [1])
        XCTAssertEqual(m.annotatedClassIDs, [1])
        // Marking examined adds to class_ids too; unmarking keeps class_ids.
        m.apply(try m.setAnnotatedEdit(2, true))
        XCTAssertEqual(m.classIDs, [1, 2])
        XCTAssertEqual(m.annotatedClassIDs, [1, 2])
        m.apply(try m.setAnnotatedEdit(1, false))
        XCTAssertEqual(m.classIDs, [1, 2])
        XCTAssertEqual(m.annotatedClassIDs, [2])
        // Removing a class from the annotation erases its voxels and both entries.
        m.apply(try m.makeEdit(.paint(2), over: makeMask(m.shape) { $0.z == 0 }))
        let removal = try m.setInAnnotationEdit(2, false)
        m.apply(removal)
        XCTAssertEqual(m.classIDs, [1])
        XCTAssertEqual(m.annotatedClassIDs, [])
        XCTAssertTrue(voxels(of: 2, in: m).isEmpty)
        m.revert(removal)
        XCTAssertEqual(voxels(of: 2, in: m).count, 2 * 5)
        XCTAssertEqual(m.annotatedClassIDs, [2])
        // A painted class that is not annotated becomes annotated.
        m.apply(try m.makeEdit(.paint(1), over: makeMask(m.shape) { $0.z == 4 }))
        XCTAssertEqual(Set(m.annotatedClassIDs), [1, 2])
        // Invariant held throughout.
        XCTAssertNoThrow(try m.metadata.validate())
        // A painting edit that paints nothing changes no coverage.
        let nothing = try m.makeEdit(.paint(3), over: VoxelRegion.empty)
        XCTAssertTrue(nothing.isEmpty)
    }

    func testRemoveClassErasesAndUndoes() throws {
        let m = try makeModel(shape: [2, 4, 4], inAnnotation: true)
        fillRaw(m, layer: 1, value: 3) { $0.y == 1 }
        let before = snapshot(m), meta = m.metadata
        let e = try m.removeClassEdit(3)
        m.apply(e)
        XCTAssertNil(m.classInfo(3))
        XCTAssertFalse(m.classIDs.contains(3))
        XCTAssertTrue(voxels(of: 3, in: m).isEmpty)
        m.revert(e)
        XCTAssertEqual(snapshot(m), before)
        XCTAssertEqual(m.metadata, meta)
    }

    // MARK: Revisions, dirty regions, conflicts

    func testRevisionAndDirtyRegionsCoverEveryChange() throws {
        let m = try makeModel(shape: [12, 30, 30])
        var rng = SeededRandom(7)
        _ = m.takeRenderUpdate()
        var previous = snapshot(m)
        var revision = m.revision
        for step in 0..<25 {
            let c = SIMD3(Int.random(in: 0..<12, using: &rng), Int.random(in: 0..<30, using: &rng), Int.random(in: 0..<30, using: &rng))
            let r = Int.random(in: 1...6, using: &rng)
            let cls = UInt16.random(in: 1...3, using: &rng)
            let op: VoxelOperation = step % 4 == 3 ? .erase(cls) : .paint(cls)
            let mask = makeMask(m.shape) { worldDistance2(m.geometry, $0, c) <= Double(r * r) }
            let e = try m.makeEdit(op, over: mask)
            m.apply(e)
            if !e.isEmpty {
                XCTAssertGreaterThan(m.revision, revision)
            }
            revision = m.revision
            // Collect the dirty boxes every few steps, as a renderer would.
            if step % 3 == 2 || step == 24 {
                let update = m.takeRenderUpdate()
                let now = snapshot(m)
                for l in 0..<m.layerCount {
                    let boxes = update.regions[l] ?? []
                    XCTAssertLessThanOrEqual(boxes.count, DirtyTracker.maxBoxesPerLayer)
                    for i in 0..<now[l].count where now[l][i] != previous[l][i] {
                        let k = m.voxel(atLinearIndex: i)
                        XCTAssertTrue(boxes.contains { $0.contains(k) }, "voxel \(k) of layer \(l) changed outside the dirty boxes")
                    }
                }
                previous = now
                XCTAssertFalse(m.hasPendingRenderUpdate)
            }
        }
    }

    func testRenderUpdateFlagsLayerAndTableChanges() throws {
        let m = try makeModel(shape: [2, 2, 2], layerCount: 2)
        _ = m.takeRenderUpdate()
        m.apply(try m.addClassEdit(SegmentClass(id: 9, key: "n", name: "N"), layer: 2))
        let u = m.takeRenderUpdate()
        XCTAssertTrue(u.layersChanged)
        XCTAssertTrue(u.classTableChanged)
        m.apply(try m.updateClassEdit(9) { $0.color = RGBA8(1, 2, 3) })
        let u2 = m.takeRenderUpdate()
        XCTAssertFalse(u2.layersChanged)
        XCTAssertTrue(u2.classTableChanged)
        XCTAssertEqual(m.colorTable()[9], RGBA8(1, 2, 3))
        m.apply(try m.updateClassEdit(9) { $0.isVisible = false })
        XCTAssertEqual(m.colorTable()[9].a, 0)
    }

    func testCanApplyDetectsStaleEdits() throws {
        let m = try makeModel(shape: [2, 8, 8])
        let snapshotModel = m.copy()
        XCTAssertEqual(snapshotModel.revision, m.revision)
        let stale = try snapshotModel.makeEdit(.paint(1), over: makeMask(m.shape) { $0.y < 4 })
        XCTAssertTrue(m.canApply(stale))
        m.apply(try m.makeEdit(.paint(2), over: makeMask(m.shape) { $0.y == 2 }))
        XCTAssertFalse(m.canApply(stale), "voxels changed since the edit was computed")
        // The copy is independent.
        XCTAssertTrue(voxels(of: 2, in: snapshotModel).isEmpty)
    }

    func testOperationsOnUnknownClassesThrow() throws {
        let m = try makeModel(shape: [1, 2, 2])
        XCTAssertThrowsError(try m.makeEdit(.paint(42), over: VoxelRegion.empty)) {
            XCTAssertEqual($0 as? EditingError, .unknownClass(42))
        }
        XCTAssertThrowsError(try m.addClassEdit(SegmentClass(id: 0, key: "bg", name: "BG")))
        XCTAssertThrowsError(try m.addClassEdit(SegmentClass(id: 1, key: "dup", name: "Dup")))
    }
}

extension SegmentationMetadata {
    func with(_ body: (inout SegmentationMetadata) -> Void) -> SegmentationMetadata {
        var m = self
        body(&m)
        return m
    }
}
