import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Render
import MedH5Editing

/// Ruler, Angle and ROI: their values, how they are drawn, the CSV export,
/// and rulers and angles saved as polylines.
@MainActor
final class MeasurementToolTests: XCTestCase {
    private func open(_ url: URL) async throws -> (MedH5Document, Workspace) {
        let doc = try openDocument(url)
        addTeardownBlock { @MainActor in doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        try await w.loadNeeded()
        w.viewer.activeViewport = .slice(.axial)
        return (doc, w)
    }

    func testRulerAngleAndROIValues() async throws {
        let dir = TemporaryDirectory("measure")
        let (doc, w) = try await open(Synthetic.copy(in: dir))
        let s = w.editing
        w.setCursor(Synthetic.world(3, 6, 6), from: .slice(.axial))
        let driver = ToolDriver(workspace: w)

        s.select(.ruler)
        driver.drag([Synthetic.world(3, 2, 2), Synthetic.world(3, 4, 4), Synthetic.world(3, 5, 6)])
        // Click both ends.
        driver.click(Synthetic.world(3, 0, 0))
        XCTAssertNotNil(s.viewState(.slice(.axial)).preview)
        driver.click(Synthetic.world(3, 0, 8))
        s.select(.angle)
        for p in [Synthetic.world(3, 2, 2), Synthetic.world(3, 2, 6), Synthetic.world(3, 6, 6)] { driver.click(p) }
        s.select(.roi)
        s.roiShape = .ellipse
        driver.drag([Synthetic.world(3, 4, 4), Synthetic.world(3, 8, 8)])
        s.roiShape = .rectangle
        driver.drag([Synthetic.world(3, 0, 0), Synthetic.world(3, 4, 4)])

        XCTAssertEqual(s.measurements.count, 5)
        guard case .ruler(let r1) = s.measurements[0].shape, case .ruler(let r2) = s.measurements[1].shape,
              case .angle(let a) = s.measurements[2].shape, case .roi(let ellipse, .ellipse) = s.measurements[3].shape,
              case .roi(let rectangle, .rectangle) = s.measurements[4].shape else { return XCTFail("\(s.measurements)") }
        XCTAssertEqual(r1.length, 5, accuracy: 1e-9)
        XCTAssertEqual(s.measurements[0].valueText, "5 mm")
        XCTAssertEqual(r2.length, 8, accuracy: 1e-9)
        XCTAssertEqual(a.degrees, 90, accuracy: 1e-9)
        XCTAssertEqual(s.measurements[2].valueText, "90°")
        // The ellipse (radius 2 mm, inside the cuboid): 13 voxels of 200 HU.
        XCTAssertEqual(ellipse.area, .pi * 4, accuracy: 1e-9)
        let e = try XCTUnwrap(s.measurements[3].statistics)
        XCTAssertEqual(e.voxelCount, 13)
        XCTAssertEqual(e.intensity.mean, 200, accuracy: 1e-9)
        XCTAssertEqual(e.intensity.standardDeviation, 0, accuracy: 1e-9)
        XCTAssertEqual(e.units, "HU")
        // The rectangle: 5 × 5 voxels, 4 of them in the cuboid.
        XCTAssertEqual(rectangle.area, 16, accuracy: 1e-9)
        let q = try XCTUnwrap(s.measurements[4].statistics)
        XCTAssertEqual(q.voxelCount, 25)
        XCTAssertEqual(q.intensity.mean, 200 * 4 / 25, accuracy: 1e-9)
        XCTAssertEqual(q.intensity.minimum, 0)
        XCTAssertEqual(q.intensity.maximum, 200)
        XCTAssertEqual(s.measurements[4].detailText, "mean 32 ± 73.3 HU · min 0 · max 200 · 25 voxels")
        // The CSV carries the statistics.
        let csv = MeasurementCSV.make(s.measurements).split(separator: "\n").map(String.init)
        XCTAssertEqual(csv.count, 6)
        XCTAssertTrue(csv[4].hasPrefix("4,roi-ellipse,12.566,mm2,200.0000,0.0000,200.0000,200.0000,13,HU,CT,LPS,"), csv[4])
        XCTAssertTrue(csv[5].hasPrefix("5,roi-rectangle,16.000,mm2,32.0000,73.3212,0.0000,200.0000,25,HU,CT,LPS,"), csv[5])
        // Measurements are no edit.
        XCTAssertTrue(doc.pendingEdits.isEmpty)
        XCTAssertFalse(doc.undoManager?.canUndo ?? true)

        // Drawn on their slice, with their values; not on another slice.
        func scene() -> (overlays: [Overlay], labels: [ViewportLabel]) {
            let r = SliceSceneBuilder(workspace: w, viewport: .slice(.axial)).build(size: SIMD2(300, 300), scale: 1)
            return (r.scene?.overlays ?? [], r.presentation.labels)
        }
        XCTAssertTrue(scene().labels.contains { $0.text == "5 mm" })
        XCTAssertTrue(scene().labels.contains { $0.text.hasPrefix("ROI 4 · 12.6 mm²") })
        w.setCursor(Synthetic.world(5, 6, 6), from: .slice(.axial))
        XCTAssertFalse(scene().labels.contains { $0.text == "5 mm" })

        // Delete; copy as text.
        s.deleteMeasurements([s.measurements[1].id])
        XCTAssertEqual(s.measurements.map(\.id), [1, 3, 4, 5])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("medh5-viewer-tests-\(UUID().uuidString)"))
        XCTAssertTrue(s.copyMeasurements(Array(s.measurements.prefix(2)), to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "Ruler 1\t5 mm\nAngle 3\t90°")
    }

    func testMeasurementsCSV() {
        let plane = PlaneFrame(origin: SIMD3(0, 0, 10), axes: PlaneAxes(right: SIMD3(1, 0, 0), down: SIMD3(0, 1, 0)))
        let roi = PlanarROI(plane: plane, shape: .rectangle(SIMD2(-1, -2), SIMD2(3, 2)))
        let list = [
            ViewerMeasurement(id: 1, shape: .ruler(RulerMeasurement(start: SIMD3(0, 0, 0), end: SIMD3(3, 4, 0))), stackID: "primary",
                              imageID: "CT", units: "mm", coordinateSystem: "LPS", planeNormal: SIMD3(0, 0, 1)),
            ViewerMeasurement(id: 2, shape: .angle(AngleMeasurement(first: SIMD3(1, 0, 0), vertex: .zero, second: SIMD3(0, 1, 0))),
                              stackID: "primary", imageID: "CT, \"A\"", units: "mm", coordinateSystem: "LPS", planeNormal: SIMD3(0, 0, 1)),
            ViewerMeasurement(id: 3, shape: .roi(roi, kind: .rectangle), stackID: "primary", imageID: "CT", units: "mm",
                              coordinateSystem: "LPS", planeNormal: SIMD3(0, 0, 1)),
        ]
        XCTAssertEqual(MeasurementCSV.make(list), """
        number,kind,value,unit,mean,sd,min,max,voxels,value_unit,image,coordinate_system,x1,y1,z1,x2,y2,z2,x3,y3,z3
        1,ruler,5.000,mm,,,,,,,CT,LPS,0.000,0.000,0.000,3.000,4.000,0.000,,,
        2,angle,90.000,deg,,,,,,,"CT, ""A\""",LPS,1.000,0.000,0.000,0.000,0.000,0.000,0.000,1.000,0.000
        3,roi-rectangle,16.000,mm2,,,,,0,,CT,LPS,-1.000,-2.000,10.000,3.000,2.000,10.000,,,

        """)
        XCTAssertEqual(MeasurementCSV.number(-0.0001), "0.000", "no negative zero")
    }

    func testRulersAndAnglesSaveAsPolylines() async throws {
        let dir = TemporaryDirectory("polylines")
        let (doc, w) = try await open(Fixtures.demoCopy(in: dir))
        let s = w.editing
        w.setCursor(Demo.lesionCentre, from: .slice(.axial))
        let driver = ToolDriver(workspace: w)
        let c = Demo.lesionCentre
        s.select(.ruler)
        driver.drag([driver.offset(c, 0, 0), driver.offset(c, 40, 0)])
        s.select(.angle)
        for p in [driver.offset(c, 0, -30), driver.offset(c, 0, 0), driver.offset(c, 30, 0)] { driver.click(p) }
        s.annotationTarget = .new
        s.annotationClassID = 12
        try s.saveMeasurementsAsPolylines(Set(s.measurements.map(\.id)))
        let id = try XCTUnwrap(s.listedAnnotation)
        guard case .polylines(let set)? = s.draft(id) else { return XCTFail("polylines") }
        XCTAssertEqual(set.polylines.map(\.vertices.count), [2, 3])
        XCTAssertEqual(set.polylines.map(\.classID), [12, 12])
        XCTAssertEqual(set.polylines[0].length(space: set.space, geometry: s.annotationGrid(id)), 40, accuracy: 1e-3)
        XCTAssertEqual(doc.undoManager?.undoActionName, "Save as Polyline Annotation")
        await settle()
        let out = dir.file("saved.medh5")
        let error: Error? = await withCheckedContinuation { continuation in
            doc.save(to: out, ofType: MedH5Document.typeIdentifier, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        let saved = try SampleFile.open(out)
        defer { saved.close() }
        guard case .polylines(let pl) = try saved.geometry(id) else { return XCTFail("saved polylines") }
        XCTAssertEqual(pl.polylines.map(\.vertices.count), [2, 3])
        XCTAssertEqual(saved.summary.formatVersion, "1.2")
        XCTAssertTrue(try Validator.validate(url: out, level: "strict").ok)
    }
}

/// A read-only document: nothing is edited, measurements still work.
@MainActor
final class ReadOnlyEditingTests: XCTestCase {
    func testReadOnlyDocumentsRefuseTheEditingTools() async throws {
        let dir = TemporaryDirectory("readonly-tools")
        let source = Synthetic.copy(in: dir)
        let doc = try MedH5Document.untitled(from: source, name: "member", readOnly: [.collectionMember("m")])
        doc.makeWindowControllers()
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        try await w.loadNeeded()
        w.viewer.activeViewport = .slice(.axial)
        w.setCursor(Synthetic.world(3, 6, 6), from: .slice(.axial))
        let s = w.editing
        let model = try XCTUnwrap(s.segmentationResource("seg")?.model)
        for tool in ViewerTool.segmentationTools + ViewerTool.annotationTools {
            let a = s.availability(tool)
            XCTAssertFalse(a.isAvailable, tool.title)
            XCTAssertTrue(a.reason?.contains("read-only") ?? false, "\(tool.title): \(a.reason ?? "")")
        }
        for tool in ViewerTool.measuringTools { XCTAssertTrue(s.availability(tool).isAvailable, tool.title) }
        s.select(.brush)
        XCTAssertEqual(w.viewer.tool, .navigate, "an unavailable tool is not selected")
        // Even with the tool forced, a stroke changes nothing.
        w.viewer.tool = .brush
        let counts = (1...3).map { model.count(UInt16($0)) }
        ToolDriver(workspace: w).drag([Synthetic.world(3, 6, 2), Synthetic.world(3, 6, 9)])
        XCTAssertEqual((1...3).map { model.count(UInt16($0)) }, counts)
        XCTAssertEqual(s.message?.isError, true)
        XCTAssertThrowsError(try s.createSegmentation(s.defaultNewSegmentation()))
        XCTAssertThrowsError(try s.createClass(name: "X", color: RGBA8(1, 2, 3), segmentation: "seg"))
        XCTAssertThrowsError(try s.setExamined(3, true, in: "seg"))
        XCTAssertThrowsError(try s.addBox(from: Synthetic.world(3, 1, 1), to: Synthetic.world(3, 5, 5),
                                          planeNormal: SIMD3(0, 0, 1), viewport: .slice(.axial)))
        XCTAssertNil(s.runOperation(.fillHoles))
        XCTAssertTrue(doc.pendingEdits.isEmpty)
        XCTAssertFalse(doc.isDocumentEdited)
        // Measuring is no edit.
        w.viewer.tool = .ruler
        ToolDriver(workspace: w).drag([Synthetic.world(3, 1, 1), Synthetic.world(3, 1, 5)])
        XCTAssertEqual(s.measurements.count, 1)
        // The menus agree.
        let controller = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let item = NSMenuItem(title: "New Segmentation…", action: #selector(DocumentWindowController.newSegmentation(_:)),
                              keyEquivalent: "")
        XCTAssertEqual(controller.validateEditingMenuItem(item), false)
        let brush = NSMenuItem(title: "Brush", action: #selector(DocumentWindowController.selectTool(_:)), keyEquivalent: "b")
        brush.representedObject = ViewerTool.brush.rawValue
        XCTAssertEqual(controller.validateEditingMenuItem(brush), false)
        XCTAssertTrue(brush.toolTip?.contains("read-only") ?? false)
    }
}

/// The undo memory of Preferences bounds what the steps hold.
@MainActor
final class UndoMemoryTests: XCTestCase {
    func testTheOldestStepsAreDroppedBeyondTheUndoMemory() async throws {
        let dir = TemporaryDirectory("undo-memory")
        let doc = try openDocument(Synthetic.copy(in: dir))
        defer { doc.close() }
        let w = try XCTUnwrap(doc.workspace)
        try await w.loadNeeded()
        w.viewer.activeViewport = .slice(.axial)
        w.setCursor(Synthetic.world(3, 6, 6), from: .slice(.axial))
        let s = w.editing
        let model = try XCTUnwrap(s.segmentationResource("seg")?.model)
        s.activeClasses["seg"] = 3
        s.brush.radius = 1
        s.select(.brush)
        let driver = ToolDriver(workspace: w)
        var states: [Int] = [model.count(3)]
        for y in [2, 5, 8] {
            driver.drag([Synthetic.world(3, Double(y), 2), Synthetic.world(3, Double(y), 9)])
            await settle()
            states.append(model.count(3))
        }
        XCTAssertGreaterThan(s.undoMemoryInUse, 0)
        // A limit only the newest step fits under.
        s.enforceUndoMemory(limit: 1)
        await settle()
        while doc.undoManager?.canUndo == true {
            doc.undoManager?.undo()
            await settle()
        }
        XCTAssertEqual(model.count(3), states[2], "the newest step was undone, the older ones are kept")
        XCTAssertLessThan(s.undoMemoryInUse, 1 << 20)
        // Saving drops every step.
        let out = dir.file("saved.medh5")
        let error: Error? = await withCheckedContinuation { continuation in
            doc.save(to: out, ofType: MedH5Document.typeIdentifier, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        await settle()
        XCTAssertEqual(s.undoMemoryInUse, 0)
    }
}
