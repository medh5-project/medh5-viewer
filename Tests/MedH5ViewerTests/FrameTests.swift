import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Render

/// Time axes, channels and colour images.
@MainActor
final class FrameTests: XCTestCase {
    /// A sample with a 3-frame time series (values = 100 × frame) and a 2-D
    /// RGB image.
    static func makeSample(in dir: TemporaryDirectory) throws -> URL {
        let url = dir.file("frames.medh5")
        let writer = try SampleWriter.create(url: url, options: WriterOptions(sampleID: "frames", subjectID: "p"))
        try writer.addTimepoint("tp0", fields: [:])
        let g4 = GridGeometry(id: "dyn_grid", shape: [3, 4, 5, 6], axisKinds: [.time, .spatial, .spatial, .spatial],
                              spacing: [2, 1, 1], timepoint: "tp0", frameUID: "f", timeValues: [0, 1.5, 3], timeUnits: "s")
        try writer.addGrid(g4)
        let n = 4 * 5 * 6
        let values = (0..<3).flatMap { t in (0..<n).map { Float(t * 100 + $0 % 7) } }
        try writer.addImage(id: "dyn", grid: "dyn_grid", data: VolumeData(shape: [3, 4, 5, 6], values: values),
                            options: ImageWriteOptions(modality: "MR"))
        let grgb = GridGeometry(id: "rgb_grid", shape: [3, 5, 6], axisKinds: [.channel, .spatial, .spatial],
                                spacing: [1, 1], timepoint: "tp0", frameUID: "f2")
        try writer.addGrid(grgb)
        let rgb = (0..<3).flatMap { c in (0..<30).map { UInt8(c * 80 + $0) } }
        try writer.addImage(id: "photo", grid: "rgb_grid", data: VolumeData(shape: [3, 5, 6], values: rgb),
                            options: ImageWriteOptions(modality: "XC", valueType: "rgb"))
        try writer.commit()
        // For looking at it in snapshot mode.
        if let copy = ProcessInfo.processInfo.environment["MEDH5_VIEWER_EXPORT_FRAMES"] {
            try? FileManager.default.removeItem(atPath: copy)
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: copy))
        }
        return url
    }

    func testTimeFramesAreSelectedAndRead() async throws {
        let dir = TemporaryDirectory("frames")
        let w = Workspace(file: try SampleFile.open(try Self.makeSample(in: dir)), displayName: "f", context: RenderContext.shared)
        w.showAsBase("dyn")
        let axes = ViewerControls.frameAxes(w)
        XCTAssertEqual(axes.time?.count, 3)
        XCTAssertEqual(axes.time?.values, [0, 1.5, 3])
        XCTAssertNil(axes.channel)
        let base = try XCTUnwrap(w.primary.base)
        base.timeIndex = 2
        let ref = try XCTUnwrap(w.referenceGrid(of: w.primary))
        XCTAssertEqual(base.frameIndex(for: ref), [2])
        XCTAssertTrue(w.neededResources().contains(.imageFrame("dyn", frame: [2])))
        try await w.loadNeeded()
        let info = try XCTUnwrap(w.hoverInfo(at: ref.world(fromIndex: SIMD3(0, 0, 0)), viewport: .slice(.axial)))
        XCTAssertEqual(info.rawValue, 200, "frame 2 holds 200 + i % 7")
        if RenderContext.shared != nil {
            let result = SliceSceneBuilder(workspace: w, viewport: .slice(.axial)).build(size: SIMD2(100, 100), scale: 1)
            XCTAssertTrue(result.presentation.topLeft.contains { $0.hasPrefix("Time 3/3") }, "\(result.presentation.topLeft)")
        }
    }

    func testRGBImagesRenderInColour() async throws {
        let dir = TemporaryDirectory("rgb")
        let w = Workspace(file: try SampleFile.open(try Self.makeSample(in: dir)), displayName: "f", context: RenderContext.shared)
        w.showAsBase("photo")
        let info = try XCTUnwrap(w.summary.image("photo"))
        let grid = try XCTUnwrap(w.summary.grid(info.grid))
        XCTAssertTrue(ImageFrames.isColorInfo(info, grid: grid))
        XCTAssertNil(ViewerControls.frameAxes(w).channel, "colour channels are not picked one by one")
        let keys = w.neededResources()
        XCTAssertFalse(keys.contains { if case .histogram = $0 { return true } else { return false } })
        guard RenderContext.shared != nil else { throw XCTSkip("no Metal device") }
        try await w.loadNeeded()
        let texture = try XCTUnwrap(w.store.ready(.imageFrame("photo", frame: [0]), as: TextureResource.self))
        XCTAssertEqual(texture.texture.content, .rgb)
    }
}
