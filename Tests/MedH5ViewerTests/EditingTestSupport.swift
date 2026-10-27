import AppKit
import Foundation
import XCTest
import simd
@testable import MedH5ViewerUI
import MedH5Kit
import MedH5Render
import MedH5Editing

/// A small synthetic sample whose voxels the editing tests can count by
/// hand: an 8 × 12 × 12 grid (z, y, x; 2 × 1 × 1 mm; axis 0 along S, so
/// axial slices are slices of axis 0), a CT with a bright cuboid and a
/// bright single voxel, and a label map:
///
/// - class 1: a square ring (border of y, x ∈ 2…9: 28 voxels) on slices
///   z = 1 and z = 4, its inside (36 voxels per slice) empty;
/// - class 2: a 2 × 2 × 2 blob (z 6…7, y 9…10, x 0…1) and one voxel at
///   (0, 11, 11);
/// - class 3: no voxel (it can be expressed, it was not examined).
enum Synthetic {
    static let shape = [8, 12, 12]
    static let spacing = [2.0, 1.0, 1.0]
    /// The bright cuboid: z 2…5, y 3…8, x 3…8 (144 voxels) at 200 HU.
    static let cuboid = (z: 2..<6, y: 3..<9, x: 3..<9)
    static let island = SIMD3(7, 0, 0)
    static let ringSlices = [1, 4]
    static let ring = 2...9

    static func linear(_ z: Int, _ y: Int, _ x: Int) -> Int { (z * 12 + y) * 12 + x }

    /// World point of an index (axis 0 → z, axis 1 → y, axis 2 → x).
    static func world(_ z: Double, _ y: Double, _ x: Double) -> SIMD3<Double> { SIMD3(x, y, z * 2) }

    static let url: URL = {
        let url = Fixtures.directory.file("synthetic.medh5")
        try! write(to: url)
        return url
    }()

    static func copy(in directory: TemporaryDirectory) -> URL {
        let url = directory.file("synthetic.medh5")
        try! FileManager.default.copyItem(at: Synthetic.url, to: url)
        return url
    }

    static func write(to url: URL) throws {
        let n = shape.reduce(1, *)
        var ct = [Int16](repeating: 0, count: n)
        for z in cuboid.z { for y in cuboid.y { for x in cuboid.x { ct[linear(z, y, x)] = 200 } } }
        ct[linear(island.x, island.y, island.z)] = 200
        var seg = [UInt16](repeating: 0, count: n)
        for z in ringSlices {
            for y in ring { for x in ring where y == ring.lowerBound || y == ring.upperBound || x == ring.lowerBound || x == ring.upperBound {
                seg[linear(z, y, x)] = 1
            } }
        }
        for z in 6..<8 { for y in 9..<11 { for x in 0..<2 { seg[linear(z, y, x)] = 2 } } }
        seg[linear(0, 11, 11)] = 2
        let writer = try SampleWriter.create(url: url, options: WriterOptions(sampleID: "synthetic", subjectID: "S-1", codec: "portable"))
        try writer.addTimepoint("tp0", fields: ["label": "baseline"])
        try writer.setLabelSet([
            "id": "editing-tests", "version": "1.0.0",
            "classes": [
                ["id": 1, "key": "organ", "name": "Organ", "color": [200, 120, 60, 255]],
                ["id": 2, "key": "lesion", "name": "Lesion", "color": [240, 220, 40, 255]],
                ["id": 3, "key": "bright", "name": "Bright", "color": [60, 160, 240, 255]],
            ],
        ])
        try writer.setDeidentification(["method": "synthetic"])
        try writer.addGrid(GridGeometry(id: "g", shape: shape, spacing: spacing, origin: [0, 0, 0],
                                        direction: [[0, 0, 1], [0, 1, 0], [1, 0, 0]], timepoint: "tp0", frameUID: "f"))
        try writer.addImage(id: "CT", grid: "g", data: VolumeData(shape: shape, values: ct),
                            options: ImageWriteOptions(modality: "CT", valueType: "quantitative", valueUnits: "HU",
                                                       windowCenter: [100], windowWidth: [400]))
        try writer.addSegmentation(id: "seg", grid: "g", layers: [VolumeData(shape: shape, values: seg)],
                                   options: SegmentationWriteOptions(classIDs: [1, 2, 3],
                                                                     common: AnnotationWriteOptions(annotatedClasses: .classes([1, 2]))))
        try writer.commit()
    }
}

/// A document opened as the app opens one (window and workspace made).
@MainActor
func openDocument(_ url: URL) throws -> MedH5Document {
    let doc = try MedH5Document(contentsOf: url, ofType: MedH5Document.typeIdentifier)
    doc.makeWindowControllers()
    return doc
}

/// Lets the run loop turn: the undo manager closes the event's undo group.
@MainActor
func settle() async {
    try? await Task.sleep(nanoseconds: 30_000_000)
}

/// Drives the editing tools in a slice view with synthetic events, as the
/// view would.
@MainActor
struct ToolDriver {
    let workspace: Workspace
    var viewport: ViewportID = .slice(.axial)

    var camera: SliceCamera {
        SliceSceneBuilder(workspace: workspace, viewport: viewport).build(size: SIMD2(600, 600), scale: 1).camera!
    }

    @discardableResult
    func send(_ kind: ViewEventKind, _ p: SIMD3<Double>, clicks: Int = 1, key: UInt16? = nil,
              modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let cam = camera
        return workspace.editing.handle(ToolEvent(kind: kind, world: p, pixel: cam.pixel(forWorld: p), modifiers: modifiers,
                                                  clickCount: clicks, keyCode: key), viewport: viewport, camera: cam)
    }

    func drag(_ points: [SIMD3<Double>]) {
        guard let first = points.first, let last = points.last else { return }
        send(.mouseDown, first)
        for p in points.dropFirst() { send(.mouseDragged, p) }
        send(.mouseUp, last)
    }

    func click(_ p: SIMD3<Double>, clicks: Int = 1) {
        send(.mouseDown, p, clicks: clicks)
        send(.mouseUp, p, clicks: clicks)
    }

    /// A point `du` mm right and `dv` mm down of `p` on the view's plane.
    func offset(_ p: SIMD3<Double>, _ du: Double, _ dv: Double) -> SIMD3<Double> {
        let cam = camera
        return cam.projectOntoPlane(p) + cam.axes.right * du + cam.axes.down * dv
    }
}

extension SegmentationModel {
    /// Voxels holding a class, counted directly.
    func count(_ classID: UInt16) -> Int { voxelCount(of: classID) }
}
