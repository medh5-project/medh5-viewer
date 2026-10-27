import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Render

/// Planes, cameras, the shared crosshair, Compare's link, window presets.
@MainActor
final class ViewerMathTests: XCTestCase {
    func testEachViewSlicesThroughTheCursorAndKeepsItsFraming() throws {
        let w = try Workspace.demo(context: nil)
        let grid = try XCTUnwrap(w.referenceGrid(of: w.primary))
        w.setCursor(SIMD3(-60.3, -20.2, 40.4), from: .slice(.axial))
        let k = grid.index(fromWorld: w.viewer.cursor)
        for a in 0..<3 { XCTAssertEqual(k[a], k[a].rounded(), accuracy: 1e-9, "the cursor snaps to a voxel centre") }
        XCTAssertLessThan(simd_distance(w.viewer.cursor, SIMD3(-60.3, -20.2, 40.4)), simd_length(grid.paddedSpacing) / 2 + 1e-9)
        for plane in ViewPlane.allCases {
            let b = SliceSceneBuilder(workspace: w, viewport: .slice(plane))
            let fit = b.fitCamera(reference: grid, size: SIMD2(400, 300), scale: 2)
            let cam = b.camera(fit: fit, cursor: w.viewer.cursor)
            XCTAssertEqual(cam.signedDistance(toPlane: w.viewer.cursor), 0, accuracy: 1e-9, plane.rawValue)
            XCTAssertEqual(cam.millimetersPerPixel, fit.millimetersPerPixel, accuracy: 1e-12)
        }
        // Zoom and pan are kept relative to the fitted view.
        w.viewer.views[.slice(.axial)] = SliceViewState(zoom: 2, pan: SIMD2(10, -5))
        let b = SliceSceneBuilder(workspace: w, viewport: .slice(.axial))
        let fit = b.fitCamera(reference: grid, size: SIMD2(400, 300), scale: 1)
        let cam = b.camera(fit: fit, cursor: w.viewer.cursor)
        XCTAssertEqual(cam.millimetersPerPixel, fit.millimetersPerPixel / 2, accuracy: 1e-12)
        let d = cam.center - fit.center
        XCTAssertEqual(simd_dot(d, fit.axes.right), 10, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(d, fit.axes.down), -5, accuracy: 1e-9)
    }

    func testTheActiveViewIsAlwaysAVisibleOne() throws {
        let w = try Workspace.demo(context: nil)
        w.setLayout(.oneByThree)
        w.viewer.activeViewport = .slice(.sagittal)
        w.setLayout(.single)
        w.viewer.singlePlane = .coronal
        XCTAssertEqual(w.viewer.activeViewport, .slice(.coronal))
        w.setLayout(.twoByTwo)
        XCTAssertEqual(w.viewer.activeViewport, .slice(.coronal), "still visible, still active")
        w.viewer.activeViewport = .volume
        w.setLayout(.compare)
        XCTAssertEqual(w.viewer.activeViewport, .compareLeft)
        XCTAssertTrue(w.activeStack === w.primary)
        w.viewer.activeViewport = .compareRight
        XCTAssertTrue(w.activeStack === w.compare)
    }

    func testRadiologicalAndNeurologicalOrientationLetters() throws {
        let w = try Workspace.demo(context: nil)
        func letters() -> OrientationLetters? {
            SliceSceneBuilder(workspace: w, viewport: .slice(.axial)).build(size: SIMD2(200, 200), scale: 1).presentation.orientation
        }
        // No scene without a render context, but the presentation is built.
        w.viewer.convention = .radiological
        XCTAssertEqual(letters(), OrientationLetters(left: "R", right: "L", top: "A", bottom: "P"))
        w.viewer.convention = .neurological
        XCTAssertEqual(letters(), OrientationLetters(left: "L", right: "R", top: "A", bottom: "P"))
        w.viewer.convention = .radiological
        let sagittal = SliceSceneBuilder(workspace: w, viewport: .slice(.sagittal)).build(size: SIMD2(200, 200), scale: 1)
        XCTAssertEqual(sagittal.presentation.orientation, OrientationLetters(left: "A", right: "P", top: "S", bottom: "I"))
        let coronal = SliceSceneBuilder(workspace: w, viewport: .slice(.coronal)).build(size: SIMD2(200, 200), scale: 1)
        XCTAssertEqual(coronal.presentation.orientation, OrientationLetters(left: "R", right: "L", top: "S", bottom: "I"))
    }

    func testCompareLinksThroughTheResolvedTransformOrByIndex() async throws {
        let w = try Workspace.demo(context: nil)
        w.setLayout(.compare)
        XCTAssertEqual(w.compare?.base?.id, "CT_tp1")
        XCTAssertEqual(w.timepoint(of: try XCTUnwrap(w.compare)), "tp1")
        // Before the transform is resolved: by index, pending.
        guard case .pending? = w.compareMapping()?.link else { return XCTFail("expected pending") }
        try await w.loadNeeded()
        let mapping = try XCTUnwrap(w.compareMapping())
        guard case .registered(let summary) = mapping.link else { return XCTFail("expected registered") }
        XCTAssertTrue(summary.contains("tp0_to_tp1"), summary)
        // The lesion centre maps by the demo's motion.
        let p = Demo.lesionCentre
        let q = mapping.forward(p)
        XCTAssertLessThan(simd_distance(q, Demo.motion.transformPoint(p)), 1e-6)
        XCTAssertLessThan(simd_distance(mapping.inverse(q), p), 1e-6)
        // Clicking in the right view moves the primary cursor back through the inverse.
        let ref = try XCTUnwrap(w.referenceGrid(of: try XCTUnwrap(w.compare)))
        w.setCursor(q, from: .compareRight)
        XCTAssertLessThan(simd_distance(try XCTUnwrap(w.compareCursor), w.snapToVoxel(q, grid: ref)), 1e-6)
    }

    func testWindowPresetsAndAutomaticWindow() throws {
        let w = try Workspace.demo(context: nil)
        let ct = try XCTUnwrap(w.summary.image("CT_tp0"))
        let presets = WindowLevel.presets(for: ct)
        XCTAssertEqual(presets.prefix(2).map(\.center), [50, 400], "stored presets first")
        XCTAssertTrue(presets.contains { $0.name == "Lung" }, "then the CT presets")
        XCTAssertEqual(WindowLevel.units(of: ct), "HU")
        let mr = try XCTUnwrap(w.summary.image("MR_tp0"))
        XCTAssertEqual(WindowLevel.presets(for: mr), mr.windowPresets, "an MR takes no CT presets")
        XCTAssertNil(WindowLevel.units(of: mr))

        // Auto: 1st–99th percentile of a ramp of 0…999, in physical values.
        let data = VolumeData(shape: [10, 10, 10], values: (0..<1000).map { Int16($0) })
        let image = ImageVolume(id: "ramp", data: data, geometry: GridGeometry(id: "g", shape: [10, 10, 10], spacing: [1, 1, 1]),
                                rescaleSlope: 2, rescaleIntercept: -100)
        let h = ImageFrames.histogram(image: image, frame: [])
        XCTAssertEqual(h.minimum, -100)
        XCTAssertEqual(h.maximum, 1898)
        let auto = WindowLevel.automatic(h)
        XCTAssertEqual(auto.lower, -100 + 2 * 10, accuracy: 2.5)
        XCTAssertEqual(auto.upper, -100 + 2 * 990, accuracy: 2.5)
        let full = WindowLevel.fullRange(h)
        XCTAssertEqual(full.lower, -100, accuracy: 1e-9)
        XCTAssertEqual(full.upper, 1898, accuracy: 1e-9)
        XCTAssertEqual(h.bins.reduce(0, +), 1000)
    }

    func testAutomaticWindowIsAppliedWhenTheHistogramArrives() async throws {
        let w = try Workspace.demo(context: nil)
        w.showAsBase("MR_tp0")
        let base = try XCTUnwrap(w.primary.base)
        // As for an image without stored presets.
        base.needsAutoWindow = true
        w.start(verify: false)
        let deadline = Date().addingTimeInterval(30)
        while base.needsAutoWindow && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(base.needsAutoWindow)
        XCTAssertGreaterThan(base.windowWidth, 0)
        XCTAssertEqual(base.windowPreset, "Auto")
        w.shutDown()
    }

    func testHoverReadsValuesAndClasses() async throws {
        let w = try Workspace.demo(context: nil)
        try await w.loadNeeded()
        // The lesion centre: inside the liver lesion of organs_tp0.
        let info = try XCTUnwrap(w.hoverInfo(at: Demo.lesionCentre, viewport: .slice(.axial)))
        XCTAssertEqual(info.coordinateSystem, "LPS")
        XCTAssertNotNil(info.voxel)
        let raw = try XCTUnwrap(info.rawValue)
        XCTAssertEqual(try XCTUnwrap(info.physicalValue), raw - 1024, accuracy: 1e-9, "HU = raw − 1024")
        XCTAssertEqual(info.valueUnits, "HU")
        let hit = try XCTUnwrap(info.labels.first { $0.annotation == "organs_tp0" })
        XCTAssertTrue(hit.classes.contains("Liver lesion"), "\(hit.classes)")
        // Outside the grid: no voxel, no value.
        let outside = try XCTUnwrap(w.hoverInfo(at: SIMD3(0, 0, 5000), viewport: .slice(.axial)))
        XCTAssertNil(outside.voxel)
        XCTAssertNil(outside.rawValue)
    }
}
