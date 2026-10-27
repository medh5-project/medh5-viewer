import XCTest
@testable import MedH5ViewerUI
import MedH5Kit

/// NIfTI import (onto an existing grid, onto a new grid at a new timepoint,
/// a segmentation) through the pending edits and the save; NIfTI export.
@MainActor
final class NIfTIImportTests: XCTestCase {
    /// A NIfTI file the engine exports from the demo.
    private func export(_ object: String, from sample: URL = Fixtures.demo, to dir: TemporaryDirectory, name: String,
                        physical: Bool = true, classID: Int? = nil) throws -> URL {
        let url = dir.file(name)
        _ = try NIfTIExport.write(sample: sample, object: object, to: url, physical: physical, classID: classID)
        return url
    }

    func testIdentifiersAndFit() throws {
        XCTAssertEqual(NIfTIImport.baseName(URL(fileURLWithPath: "/a/CT scan.nii.gz")), "CT scan")
        XCTAssertEqual(NIfTIImport.identifier(from: "CT scan (2)"), "CT_scan__2_")
        XCTAssertEqual(NIfTIImport.identifier(from: "meta"), "importedmeta")
        XCTAssertEqual(NIfTIImport.unique("CT", taken: ["CT", "CT_2"]), "CT_3")
        XCTAssertTrue(NIfTIImport.isValidIdentifier("ct_tp0.v-2"))
        XCTAssertFalse(NIfTIImport.isValidIdentifier("bad id"))

        let dir = TemporaryDirectory("nifti-fit")
        let ct = try NIfTIImport.read(try export("images/CT_tp0", to: dir, name: "ct.nii.gz"))
        let summary = try SampleFile.open(Fixtures.demo).summary
        XCTAssertEqual(NIfTIImport.fit(ct.volume, on: try XCTUnwrap(summary.grid("ct_tp0"))), .fits)
        guard case .geometry = NIfTIImport.fit(ct.volume, on: try XCTUnwrap(summary.grid("ct_tp1"))) else {
            return XCTFail("the follow-up grid is in another place")
        }
        guard case .shape = NIfTIImport.fit(ct.volume, on: try XCTUnwrap(summary.grid("mr_tp0"))) else {
            return XCTFail("the MR grid has another shape")
        }

        let labels = VolumeData(shape: [2, 2], values: [0, 3, 3, 7] as [Float])
        let (layer, classes) = try NIfTIImport.labelLayer(labels)
        XCTAssertEqual(classes, [3, 7])
        XCTAssertEqual(layer.scalarType, .uint16)
        XCTAssertEqual(layer.value(at: 3), 7)
        XCTAssertThrowsError(try NIfTIImport.labelLayer(VolumeData(shape: [2], values: [0, 2.5] as [Float])), "not class ids")
        XCTAssertThrowsError(try NIfTIImport.labelLayer(VolumeData(shape: [1], values: [65535] as [Float])), "the ignore value is no class")
    }

    /// An image onto the grid it fits: pending until the save, then in the
    /// file on that grid with the same values; the file validates.
    func testAnImageOntoAnExistingGridSavesAndReopens() async throws {
        let dir = TemporaryDirectory("nifti-image")
        let nifti = try export("images/CT_tp0", to: dir, name: "ct.nii.gz", physical: false)
        let doc = try MedH5Document.openForTest(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        let model = NIfTIImportModel(workspace: workspace, kind: .image)
        await model.read(nifti)
        XCTAssertNotNil(model.input)
        XCTAssertEqual(model.identifier, "ct")
        XCTAssertEqual(model.placement, .grid("ct_tp0"), "the grid the file fits is chosen")
        XCTAssertEqual(model.problems, [])
        model.identifier = "CT_tp0"
        XCTAssertTrue(model.problems.contains { $0.contains("already") }, "an id the sample has")
        model.identifier = "CT_reimported"
        model.modality = "CT"
        model.valueUnits = "HU"
        let message = try XCTUnwrap(model.commit())
        XCTAssertTrue(message.contains("CT_reimported"))
        let pending = try XCTUnwrap(workspace.pendingEdits.newImages["CT_reimported"])
        XCTAssertEqual(pending.grid, "ct_tp0")
        XCTAssertEqual(pending.source, "ct.nii.gz")
        XCTAssertTrue(workspace.pendingEdits.newGrids.isEmpty)
        XCTAssertEqual(PendingChangeList.items(workspace.pendingEdits, summary: workspace.summary).map(\.title), ["CT_reimported"])
        try await endEvent()
        XCTAssertEqual(doc.undoManager?.undoActionName, "Import NIfTI Image")

        let out = dir.file("imported.medh5")
        let error = await doc.saveForTest(to: out)
        XCTAssertNil(error)
        try await doc.waitForReopen(out)
        XCTAssertTrue(workspace.pendingEdits.newImages.isEmpty, "saved, no longer pending")
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        let image = try XCTUnwrap(saved.summary.image("CT_reimported"))
        XCTAssertEqual(image.grid, "ct_tp0")
        XCTAssertEqual(image.modality, "CT")
        XCTAssertEqual(image.valueUnits, "HU")
        let original = try saved.readImage("CT_tp0", physical: true)
        let back = try saved.readImage("CT_reimported", physical: true)
        XCTAssertEqual(back.shape, original.shape)
        for i in stride(from: 0, to: original.count, by: 97) {
            XCTAssertEqual(back.value(at: i), original.value(at: i), accuracy: 1e-3)
        }
        let report = try Validator.validate(url: out, level: "integrity")
        XCTAssertTrue(report.ok, "\(report.diagnostics.map(\.message))")
    }

    /// An image that fits no grid goes onto a grid of its own, at a new
    /// timepoint, in a frame of its own; the document gets the timepoint.
    func testAnImageOntoANewGridAtANewTimepoint() async throws {
        let dir = TemporaryDirectory("nifti-newgrid")
        let nifti = try export("images/MR_tp0", to: dir, name: "mr.nii.gz")
        let source = Fixtures.copy(Fixtures.demoWithoutClinical, in: dir, name: "plain.medh5")
        let doc = try MedH5Document.openForTest(source)
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        let model = NIfTIImportModel(workspace: workspace, kind: .image)
        await model.read(nifti)
        model.placement = .newGrid
        XCTAssertTrue(model.problems.isEmpty, "\(model.problems)")
        model.modality = "MR"
        model.timepoint = .new
        model.newTimepointID = "tp2"
        model.newTimepointLabel = "research"
        model.newTimepointDays = "120"
        model.frame = .new
        XCTAssertEqual(model.newGridID, "mr_grid")
        XCTAssertEqual(model.newFrameUID, "nifti:mr")
        XCTAssertNotNil(model.commit())
        let edits = workspace.pendingEdits
        XCTAssertEqual(edits.newGrids["mr_grid"]?.timepoint, "tp2")
        XCTAssertEqual(edits.newGrids["mr_grid"]?.frameUID, "nifti:mr")
        let tps = edits.document?["timepoints"]?.arrayValue ?? []
        XCTAssertEqual(tps.last?["id"], "tp2")
        XCTAssertEqual(tps.last?["index"], .int(2))
        XCTAssertEqual(tps.last?["days_from_baseline"], .int(120))

        let out = dir.file("newgrid.medh5")
        let error = await doc.saveForTest(to: out)
        XCTAssertNil(error)
        try await doc.waitForReopen(out)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        let grid = try XCTUnwrap(saved.summary.grid("mr_grid"))
        XCTAssertEqual(grid.timepoint, "tp2")
        XCTAssertEqual(grid.frameUID, "nifti:mr")
        XCTAssertTrue(grid.isCongruent(with: try XCTUnwrap(saved.summary.grid("mr_tp0"))), "the file's own geometry")
        XCTAssertEqual(saved.summary.image("mr")?.timepoint, "tp2")
        XCTAssertEqual(saved.summary.timepoint("tp2")?.label, "research")
        XCTAssertEqual(workspace.timepointIDs, ["tp0", "tp1", "tp2"], "the window reads the saved file")
        let report = try Validator.validate(url: out, level: "integrity")
        XCTAssertTrue(report.ok, "\(report.diagnostics.map(\.message))")
    }

    /// A label map onto the grid it fits: a new segmentation whose classes
    /// are those present (and what was looked for), voxels as in the file.
    func testASegmentationOntoAGrid() async throws {
        let dir = TemporaryDirectory("nifti-seg")
        let nifti = try export("annotations/organs_tp1", to: dir, name: "organs.nii.gz")
        let doc = try MedH5Document.openForTest(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        let model = NIfTIImportModel(workspace: workspace, kind: .segmentation)
        await model.read(nifti)
        XCTAssertEqual(model.placement, .grid("ct_tp1"))
        let stored = try XCTUnwrap(workspace.summary.annotation("organs_tp1"))
        let present = try workspace.file.classStats("organs_tp1").filter { $0.value.voxels > 0 }.keys.sorted()
        XCTAssertEqual(model.labels, present)
        XCTAssertTrue(model.missingClasses.isEmpty, "the label set has them all")
        model.identifier = "organs_reimported"
        XCTAssertNotNil(model.commit())
        let seg = try XCTUnwrap(workspace.pendingEdits.importedSegmentations["organs_reimported"])
        XCTAssertEqual(seg.options.classIDs, present)

        let out = dir.file("seg.medh5")
        let error = await doc.saveForTest(to: out)
        XCTAssertNil(error)
        try await doc.waitForReopen(out)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        let info = try XCTUnwrap(saved.summary.annotation("organs_reimported"))
        XCTAssertEqual(info.grid, "ct_tp1")
        XCTAssertEqual(info.classIDs, present)
        XCTAssertEqual(info.annotatedClassIDs, present)
        XCTAssertEqual(info.task, "segmentation")
        let a = try saved.readLayer("organs_reimported", layer: 0)
        let b = try saved.readLayer("organs_tp1", layer: 0)
        for i in 0..<a.count where a.value(at: i) != b.value(at: i) && b.value(at: i) != Double(stored.ignoreID) {
            return XCTFail("voxel \(i) differs")
        }
        let report = try Validator.validate(url: out, level: "integrity")
        XCTAssertTrue(report.ok, "\(report.diagnostics.map(\.message))")
    }

    /// A label map whose classes the label set lacks: refused unless they
    /// are added to the label set with the import.
    func testMissingClassesAreAddedToTheLabelSet() async throws {
        let dir = TemporaryDirectory("nifti-missing")
        let doc = try MedH5Document.openForTest(Fixtures.demoCopy(in: dir))
        defer { doc.close() }
        let workspace = try XCTUnwrap(doc.workspace)
        // A label map of class 40 on the follow-up grid, written by the engine.
        let grid = try XCTUnwrap(workspace.summary.grid("ct_tp1"))
        let labels = VolumeData(scalarType: .uint16, shape: grid.spatialShape)
        labels.setValue(40, at: 5)
        let sample = dir.file("forty.medh5")
        let writer = try SampleWriter.create(url: sample, options: WriterOptions(sampleID: "x", subjectID: "y"))
        var g = grid
        g.timepoint = "tp0"
        try writer.addGrid(g)
        try writer.addImage(id: "img", grid: g.id, data: VolumeData(scalarType: .int16, shape: grid.shape))
        try writer.addSegmentation(id: "seg", grid: g.id, layers: [labels])
        try writer.commit()
        let nifti = try export("annotations/seg", from: sample, to: dir, name: "forty.nii.gz")

        let model = NIfTIImportModel(workspace: workspace, kind: .segmentation)
        await model.read(nifti)
        XCTAssertEqual(model.labels, [40])
        XCTAssertEqual(model.missingClasses, [40])
        model.addsMissingClasses = false
        XCTAssertTrue(model.problems.contains { $0.contains("does not define 40") })
        model.addsMissingClasses = true
        XCTAssertTrue(model.problems.isEmpty, "\(model.problems)")
        XCTAssertNotNil(model.commit())
        guard case .set(let ls)? = workspace.pendingEdits.labelSet else { return XCTFail("the label set grows") }
        XCTAssertEqual(ls["classes"]?.arrayValue?.last?["key"], "label_40")

        let out = dir.file("forty-imported.medh5")
        let error = await doc.saveForTest(to: out)
        XCTAssertNil(error)
        try await doc.waitForReopen(out)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        XCTAssertEqual(saved.summary.labelSet?.labelClass(id: 40)?.name, "Label 40")
        XCTAssertEqual(saved.summary.annotation("forty")?.classIDs, [40])
        XCTAssertTrue(try Validator.validate(url: out, level: "semantic").ok)
    }

    /// Export: the saved image or voxel annotation, or a refusal saying why.
    func testExport() throws {
        let dir = TemporaryDirectory("nifti-export")
        let summary = try SampleFile.open(Fixtures.demo).summary
        var edits = PendingEdits()
        XCTAssertEqual(try NIfTIExport.object("CT_tp0", in: summary, edits: edits).get(), "images/CT_tp0")
        XCTAssertEqual(try NIfTIExport.object("organs_tp0", in: summary, edits: edits).get(), "annotations/organs_tp0")
        guard case .failure(.kind) = NIfTIExport.object("lesion_boxes_tp0", in: summary, edits: edits) else {
            return XCTFail("boxes are not voxels")
        }
        guard case .failure(.missing) = NIfTIExport.object("nothing", in: summary, edits: edits) else { return XCTFail("missing") }
        edits.newImages["new"] = NewImage(grid: "ct_tp0", data: VolumeData(scalarType: .int16, shape: [1]), options: .init())
        guard case .failure(.unsaved) = NIfTIExport.object("new", in: summary, edits: edits) else { return XCTFail("unsaved") }

        let image = try export("images/CT_tp0", to: dir, name: "ct.nii.gz")
        let read = try NIfTI.read(image)
        XCTAssertTrue(read.geometry.isCongruent(with: try XCTUnwrap(summary.grid("ct_tp0"))))
        let liver = try export("annotations/organs_tp1", to: dir, name: "liver.nii.gz", classID: 2)
        let mask = try NIfTI.read(liver)
        XCTAssertEqual(Set((0..<mask.data.count).map { mask.data.value(at: $0) }), [0, 1], "one class as a 0/1 mask")
    }
}
