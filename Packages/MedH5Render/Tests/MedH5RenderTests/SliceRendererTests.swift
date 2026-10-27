import XCTest
import Metal
import simd
import MedH5Core
@testable import MedH5Render

final class SliceRendererTests: XCTestCase {
    var context: RenderContext!
    var renderer: SliceRenderer!

    override func setUpWithError() throws {
        context = try makeTestContext()
        renderer = try SliceRenderer(context: context)
    }

    private func axialCamera(_ grid: GridGeometry, size: Int = 64) -> SliceCamera {
        SliceCamera.standard(.axial, grid: grid, viewportSize: SIMD2(size, size))
    }

    // MARK: Values

    func testWindowLevelMapsValueToExpectedGrey() throws {
        let grid = GridGeometry(id: "g", shape: [4, 8, 8], spacing: [1, 1, 1])
        for (type, value): (ScalarType, Double) in [(.int16, 100), (.uint16, 100), (.uint8, 100), (.float32, 100),
                                                     (.int8, 100), (.float16, 100), (.int32, 100), (.float64, 100)] {
            let data = VolumeData(scalarType: type, shape: [4, 8, 8])
            for i in 0..<data.count { data.setValue(value, at: i) }
            let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
            // value 100 in a window [0, 200] -> grey 127.5; in [50, 150] -> 127.5; in [100, 300] -> 0; [-100, 100] -> 255
            for (center, width, expected) in [(100.0, 200.0, 127.5), (50.0, 100.0, 255.0), (200.0, 200.0, 0.0),
                                              (125.0, 100.0, 63.75)] {
                let layer = ImageLayer(volume: volume, windowCenter: center, windowWidth: width, interpolation: .nearest)
                let scene = SliceScene(camera: axialCamera(grid), layers: [.image(layer)])
                let image = try renderer.render(scene: scene)
                let p = image.pixel(x: 32, y: 32)
                XCTAssertEqual(Double(p.x), expected, accuracy: 1.01, "\(type) window \(center)/\(width)")
                XCTAssertEqual(p.x, p.y)
                XCTAssertEqual(p.y, p.z)
                XCTAssertEqual(p.w, 255)
            }
        }
    }

    func testRescaleIsApplied() throws {
        let grid = GridGeometry(id: "g", shape: [2, 8, 8], spacing: [1, 1, 1])
        let data = makeVolume(Int16.self, shape: [2, 8, 8]) { _, _, _ in 50 }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        // physical = 50 * 2 - 100 = 0 -> centre of window [-50, 50]
        let layer = ImageLayer(volume: volume, windowCenter: 0, windowWidth: 100, rescaleSlope: 2,
                               rescaleIntercept: -100, interpolation: .nearest)
        let image = try renderer.render(scene: SliceScene(camera: axialCamera(grid), layers: [.image(layer)]))
        XCTAssertEqual(Double(image.pixel(x: 32, y: 32).x), 127.5, accuracy: 1.01)
        // Without the rescale the raw 50 would be white.
        var raw = layer
        raw.rescaleSlope = 1
        raw.rescaleIntercept = 0
        let image2 = try renderer.render(scene: SliceScene(camera: axialCamera(grid), layers: [.image(raw)]))
        XCTAssertEqual(image2.pixel(x: 32, y: 32).x, 255)
    }

    func testOutsideTheVolumeIsBlackAndOverlaysAreTransparentThere() throws {
        let grid = GridGeometry(id: "g", shape: [4, 4, 4], spacing: [1, 1, 1])
        let data = makeVolume(UInt8.self, shape: [4, 4, 4]) { _, _, _ in 255 }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        var camera = axialCamera(grid)
        camera.millimetersPerPixel = 0.25   // 64 px = 16 mm; the volume spans 4 mm in the middle
        let layer = ImageLayer(volume: volume, windowCenter: 127.5, windowWidth: 255, interpolation: .nearest)
        let image = try renderer.render(scene: SliceScene(camera: camera, layers: [.image(layer)]))
        XCTAssertPixel(image.pixel(x: 32, y: 32), SIMD3(255, 255, 255))
        XCTAssertPixel(image.pixel(x: 2, y: 2), SIMD3(0, 0, 0))
        // The region is [-0.5, 3.5] mm around the centre 1.5: 16 px wide, pixels 24..<40.
        XCTAssertPixel(image.pixel(x: 24, y: 32), SIMD3(255, 255, 255))
        XCTAssertPixel(image.pixel(x: 23, y: 32), SIMD3(0, 0, 0))
        XCTAssertPixel(image.pixel(x: 39, y: 32), SIMD3(255, 255, 255))
        XCTAssertPixel(image.pixel(x: 40, y: 32), SIMD3(0, 0, 0))
    }

    // MARK: Geometry

    /// A voxel at a known index lands on the pixel the camera predicts, for
    /// the three standard planes, with anisotropic spacing and an oblique
    /// direction.
    func testVoxelAppearsAtExpectedPixelInEveryPlane() throws {
        let direction = rotation(axis: SIMD3(1, 2, 3), degrees: 25)
        let grid = GridGeometry(id: "g", shape: [20, 24, 28], spacing: [2.0, 0.7, 0.5], origin: [-10, 20, 5],
                                direction: direction)
        let k = SIMD3<Int>(7, 11, 16)
        let data = makeVolume(Int16.self, shape: [20, 24, 28]) { a, b, c in
            (a == k.x && b == k.y && c == k.z) ? 1000 : 0
        }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        let world = grid.world(fromIndex: SIMD3<Double>(k))
        for plane in ViewPlane.allCases {
            for mode in PlaneOrientationMode.allCases {
                var camera = SliceCamera.standard(plane, grid: grid, orientation: mode, viewportSize: SIMD2(160, 120))
                camera.millimetersPerPixel = 0.1
                // Put the plane through the voxel centre, the voxel off the viewport centre.
                camera.center = world + camera.axes.right * 2.3 - camera.axes.down * 1.7
                let layer = ImageLayer(volume: volume, windowCenter: 500, windowWidth: 1000, interpolation: .nearest)
                let image = try renderer.render(scene: SliceScene(camera: camera, layers: [.image(layer)]))
                let expected = camera.pixel(forWorld: world)
                guard let (c, count) = centroid(image, where: { $0.x > 128 }) else {
                    XCTFail("\(plane) \(mode): voxel not visible")
                    continue
                }
                XCTAssertEqual(c.x, expected.x, accuracy: 1.0, "\(plane) \(mode)")
                XCTAssertEqual(c.y, expected.y, accuracy: 1.0, "\(plane) \(mode)")
                XCTAssertGreaterThan(count, 10)
                // The pixel at the voxel centre is bright.
                XCTAssertEqual(image.pixel(x: Int(expected.x), y: Int(expected.y)).x, 255, "\(plane) \(mode)")
            }
        }
    }

    /// Axial, coronal and sagittal put the patient where the radiological
    /// convention says: left on screen right, anterior up, superior up.
    func testStandardPlanesFollowTheRadiologicalConvention() throws {
        let grid = GridGeometry(id: "g", shape: [9, 9, 9], spacing: [1, 1, 1], origin: [-4, -4, -4])
        // Bright voxels at patient left (+x), anterior (-y) and superior (+z) of the centre (LPS).
        let data = makeVolume(UInt8.self, shape: [9, 9, 9]) { z, y, x in
            // index (k0, k1, k2) = world (x=k0-4, y=k1-4, z=k2-4) for the identity direction
            let w = SIMD3(z - 4, y - 4, x - 4)
            if w == SIMD3(3, 0, 0) { return 255 }   // left
            if w == SIMD3(0, -3, 0) { return 160 }  // anterior
            if w == SIMD3(0, 0, 3) { return 80 }    // superior
            return 0
        }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        let layer = ImageLayer(volume: volume, windowCenter: 127.5, windowWidth: 255, interpolation: .nearest)
        func render(_ plane: ViewPlane) throws -> RenderedImage {
            var camera = SliceCamera.standard(plane, grid: grid, viewportSize: SIMD2(90, 90))
            camera.center = .zero
            camera.millimetersPerPixel = 0.1
            return try renderer.render(scene: SliceScene(camera: camera, layers: [.image(layer)]))
        }
        // Axial: left (+x) on the right, anterior up.
        let axial = try render(.axial)
        XCTAssertEqual(axial.pixel(x: 45 + 30, y: 45).x, 255)
        XCTAssertEqual(axial.pixel(x: 45, y: 45 - 30).x, 160)
        // Coronal: left on the right, superior up.
        let coronal = try render(.coronal)
        XCTAssertEqual(coronal.pixel(x: 45 + 30, y: 45).x, 255)
        XCTAssertEqual(coronal.pixel(x: 45, y: 45 - 30).x, 80)
        // Sagittal: anterior on the left, superior up.
        let sagittal = try render(.sagittal)
        XCTAssertEqual(sagittal.pixel(x: 45 - 30, y: 45).x, 160)
        XCTAssertEqual(sagittal.pixel(x: 45, y: 45 - 30).x, 80)
    }

    /// Two grids of one frame with different spacing, origin and direction:
    /// a mark at the same world point lands on the same pixels.
    func testSecondGridInTheSameFrameLinesUp() throws {
        let gridA = GridGeometry(id: "a", shape: [16, 16, 16], spacing: [1, 1, 1], origin: [0, 0, 0], frameUID: "f")
        let flip: [[Double]] = [[0, 0, -1], [0, 1, 0], [1, 0, 0]]
        let gridB = GridGeometry(id: "b", shape: [40, 30, 50], spacing: [0.5, 0.6, 0.4], origin: [14, -2, 3],
                                 direction: flip, frameUID: "f")
        XCTAssertTrue(gridA.sharesFrame(with: gridB))
        let p = SIMD3<Double>(7.1, 6, 9)   // a world point inside both, off voxel boundaries
        let ka = gridA.voxel(containingWorld: p)!
        let kb = gridB.voxel(containingWorld: p)!
        let a = makeVolume(UInt8.self, shape: [16, 16, 16]) { x, y, z in SIMD3(x, y, z) == ka ? 255 : 0 }
        let b = makeVolume(UInt8.self, shape: [40, 30, 50]) { x, y, z in SIMD3(x, y, z) == kb ? 255 : 0 }
        let va = try VolumeTexture(context: context, scalars: a, geometry: gridA)
        let vb = try VolumeTexture(context: context, scalars: b, geometry: gridB)
        var camera = SliceCamera.standard(.axial, grid: gridA, viewportSize: SIMD2(128, 128))
        camera.center = gridA.world(fromIndex: SIMD3<Double>(ka))
        camera.millimetersPerPixel = 0.05
        var la = ImageLayer(volume: va, windowCenter: 127.5, windowWidth: 255, colormap: .red, interpolation: .nearest)
        la.threshold = 100
        var lb = ImageLayer(volume: vb, windowCenter: 127.5, windowWidth: 255, colormap: .green, interpolation: .nearest)
        lb.threshold = 100
        let ia = try renderer.render(scene: SliceScene(camera: camera, layers: [.image(la)]))
        let ib = try renderer.render(scene: SliceScene(camera: camera, layers: [.image(lb)]))
        let ca = try XCTUnwrap(centroid(ia) { $0.x > 128 })
        let cb = try XCTUnwrap(centroid(ib) { $0.y > 128 })
        // Each mark is centred where its own voxel centre projects.
        let expectedA = camera.pixel(forWorld: gridA.world(fromIndex: SIMD3<Double>(ka)))
        let expectedB = camera.pixel(forWorld: gridB.world(fromIndex: SIMD3<Double>(kb)))
        XCTAssertEqual(simd_distance(ca.0, expectedA), 0, accuracy: 1)
        XCTAssertEqual(simd_distance(cb.0, expectedB), 0, accuracy: 1)
        // And both voxels cover the world point p.
        let pp = camera.pixel(forWorld: p)
        XCTAssertGreaterThan(ia.pixel(x: Int(pp.x), y: Int(pp.y)).x, 128)
        XCTAssertGreaterThan(ib.pixel(x: Int(pp.x), y: Int(pp.y)).y, 128)
        // The voxel sizes on screen follow the spacings: 1 mm vs 0.4 x 0.6 mm (B is rotated).
        XCTAssertEqual(Double(ca.1), 400, accuracy: 60)
        XCTAssertEqual(Double(cb.1), (0.4 / 0.05) * (0.6 / 0.05), accuracy: 30)
    }

    /// An affine registration x_moving = M x_fixed moves the layer's content
    /// by M⁻¹ on screen.
    func testAffineRegistrationMovesTheLayer() throws {
        let grid = GridGeometry(id: "g", shape: [16, 32, 32], spacing: [1, 1, 1])
        let mark = SIMD3<Int>(8, 10, 20)
        let data = makeVolume(UInt8.self, shape: [16, 32, 32]) { a, b, c in SIMD3(a, b, c) == mark ? 255 : 0 }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        var camera = SliceCamera.standard(.axial, grid: grid, viewportSize: SIMD2(160, 160))
        camera.millimetersPerPixel = 0.25
        let markWorld = grid.world(fromIndex: SIMD3<Double>(mark))
        camera.center = markWorld
        // Translation (here world x = k0, y = k1, z = k2): the plane must still pass
        // through the mark after the move, so translate in-plane only.
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(0, 3, -4, 1)   // x_moving = x_fixed + (0, 3, -4)
        let rotationZ = simd_double4x4(simd_quatd(angle: .pi / 12, axis: SIMD3(1, 0, 0)))
        let affine = m * rotationZ
        var layer = ImageLayer(volume: volume, windowCenter: 127.5, windowWidth: 255, interpolation: .nearest)
        layer.placement = LayerPlacement(registration: affine)
        // The plane through the fixed point the mark maps from.
        let fixed = affine.inverse.transformPoint(markWorld)
        camera.center = fixed
        let image = try renderer.render(scene: SliceScene(camera: camera, layers: [.image(layer)]))
        let c = try XCTUnwrap(centroid(image) { $0.x > 128 })
        let expected = camera.pixel(forWorld: fixed)
        XCTAssertEqual(c.0.x, expected.x, accuracy: 1)
        XCTAssertEqual(c.0.y, expected.y, accuracy: 1)
        // Without the registration the mark is somewhere else.
        layer.placement = .identity
        let plain = try renderer.render(scene: SliceScene(camera: camera, layers: [.image(layer)]))
        if let c2 = centroid(plain, where: { $0.x > 128 }) {
            XCTAssertGreaterThan(simd_distance(c2.0, expected), 8)
        }
    }

    /// A displacement field x_moving = x + d(x) moves the layer like the
    /// equivalent translation.
    func testDisplacementFieldMovesTheLayer() throws {
        let grid = GridGeometry(id: "g", shape: [16, 32, 32], spacing: [1, 1, 1])
        let mark = SIMD3<Int>(8, 10, 20)
        let data = makeVolume(UInt8.self, shape: [16, 32, 32]) { a, b, c in SIMD3(a, b, c) == mark ? 255 : 0 }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        // A constant field d = (0, 2, -3) mm on a coarse grid covering the volume.
        let fieldGrid = GridGeometry(id: "f", shape: [3, 8, 8, 8], axisKinds: [.channel, .spatial, .spatial, .spatial],
                                     spacing: [4, 6, 6], origin: [-2, -4, -4])
        let planes = [0.0, 2.0, -3.0].map { v -> VolumeData in
            let p = VolumeData(scalarType: .float32, shape: [8, 8, 8])
            for i in 0..<p.count { p.setValue(v, at: i) }
            return p
        }
        let field = try VolumeTexture(context: context, vectorPlanes: planes, geometry: fieldGrid)
        XCTAssertEqual(field.content, .vector)
        var layer = ImageLayer(volume: volume, windowCenter: 127.5, windowWidth: 255, interpolation: .nearest)
        layer.placement = LayerPlacement(displacement: field)
        let markWorld = grid.world(fromIndex: SIMD3<Double>(mark))
        let fixed = markWorld - SIMD3(0, 2, -3)
        var camera = SliceCamera.standard(.axial, grid: grid, viewportSize: SIMD2(160, 160))
        camera.millimetersPerPixel = 0.25
        camera.center = fixed
        let image = try renderer.render(scene: SliceScene(camera: camera, layers: [.image(layer)]))
        let c = try XCTUnwrap(centroid(image) { $0.x > 128 })
        let expected = camera.pixel(forWorld: fixed)
        XCTAssertEqual(simd_distance(c.0, expected), 0, accuracy: 1)
    }

    // MARK: Labels

    func testLabelColoursHiddenClassesAndOutlines() throws {
        let grid = GridGeometry(id: "g", shape: [3, 32, 32], spacing: [1, 1, 1], direction: axialDirection)
        // Class 1: k1, k2 in 4..<14; class 2: 18..<28; class 7 (hidden): 4..<14 x 18..<28; ignore elsewhere in a strip.
        let labels = makeVolume(UInt16.self, shape: [3, 32, 32]) { _, b, c in
            if (4..<14).contains(b) && (4..<14).contains(c) { return 1 }
            if (18..<28).contains(b) && (18..<28).contains(c) { return 2 }
            if (4..<14).contains(b) && (18..<28).contains(c) { return 7 }
            if b >= 30 { return ClassID.ignore }
            return 0
        }
        let volume = try VolumeTexture(context: context, labels: labels, geometry: grid)
        XCTAssertEqual(volume.texture.pixelFormat, .r16Uint)
        let lut = try LabelLookupTable(context: context)
        lut.setColor(RGBA8(255, 0, 0), forClass: 1)
        lut.setColor(RGBA8(0, 255, 0), forClass: 2)
        lut.setColor(RGBA8(0, 0, 255), forClass: 7)
        lut.setVisible(false, forClass: 7)
        var camera = SliceCamera.standard(.axial, grid: grid, viewportSize: SIMD2(128, 128))
        camera.millimetersPerPixel = 0.25   // 4 px per voxel
        camera.center = grid.world(fromIndex: SIMD3(1, 15.5, 15.5))
        func px(_ k1: Double, _ k2: Double) -> (Int, Int) {
            let p = camera.pixel(forWorld: grid.world(fromIndex: SIMD3(1, k1, k2)))
            return (Int(p.x), Int(p.y))
        }
        var layer = LabelLayer(volume: volume, lookupTable: lut, style: .fill, fillOpacity: 1)
        layer.showsIgnoreRegion = false
        let fill = try renderer.render(scene: SliceScene(camera: camera, layers: [.label(layer)]))
        var (x, y) = px(8, 8)
        XCTAssertPixel(fill.pixel(x: x, y: y), SIMD3(255, 0, 0))
        (x, y) = px(22, 22)
        XCTAssertPixel(fill.pixel(x: x, y: y), SIMD3(0, 255, 0))
        (x, y) = px(8, 22)
        XCTAssertPixel(fill.pixel(x: x, y: y), SIMD3(0, 0, 0), "hidden class")
        (x, y) = px(2, 2)
        XCTAssertPixel(fill.pixel(x: x, y: y), SIMD3(0, 0, 0), "background")
        (x, y) = px(31, 10)
        XCTAssertPixel(fill.pixel(x: x, y: y), SIMD3(0, 0, 0), "ignore region hidden")

        // Showing the class again takes effect on the next frame.
        lut.setVisible(true, forClass: 7)
        let again = try renderer.render(scene: SliceScene(camera: camera, layers: [.label(layer)]))
        (x, y) = px(8, 22)
        XCTAssertPixel(again.pixel(x: x, y: y), SIMD3(0, 0, 255))
        lut.setVisible(false, forClass: 7)

        // Outline only: the interior is empty, the boundary voxel's inner edge is coloured.
        layer.style = .outline
        layer.outlineWidth = 1.5
        let outline = try renderer.render(scene: SliceScene(camera: camera, layers: [.label(layer)]))
        (x, y) = px(8, 8)
        XCTAssertPixel(outline.pixel(x: x, y: y), SIMD3(0, 0, 0), "interior")
        // The boundary of class 1 at k2 = 3.5: the first pixel inside is red.
        let edge = camera.pixel(forWorld: grid.world(fromIndex: SIMD3(1, 8, 3.5)))
        XCTAssertPixel(outline.pixel(x: Int(edge.x.rounded()), y: Int(edge.y)), SIMD3(255, 0, 0), "outline")
        XCTAssertPixel(outline.pixel(x: Int(edge.x.rounded()) - 2, y: Int(edge.y)), SIMD3(0, 0, 0), "outside")
        XCTAssertPixel(outline.pixel(x: Int(edge.x.rounded()) + 4, y: Int(edge.y)), SIMD3(0, 0, 0), "inside")

        // The ignore region, when shown, is a grey hatch.
        layer.showsIgnoreRegion = true
        let ignore = try renderer.render(scene: SliceScene(camera: camera, layers: [.label(layer)]))
        var greys = 0
        for xx in 0..<128 {
            let p = ignore.pixel(x: xx, y: Int(camera.pixel(forWorld: grid.world(fromIndex: SIMD3(1, 31, 10))).y))
            if p.x > 10 && p.x == p.y && p.y == p.z { greys += 1 }
        }
        XCTAssertGreaterThan(greys, 64)
    }

    func testLabelUpdateRegionAppearsInNextFrame() throws {
        let grid = GridGeometry(id: "g", shape: [4, 16, 16], spacing: [1, 1, 1], direction: axialDirection)
        let labels = VolumeData(scalarType: .uint16, shape: [4, 16, 16])
        let volume = try VolumeTexture(context: context, labels: labels, geometry: grid)
        let lut = try LabelLookupTable(context: context, colors: [3: RGBA8(255, 255, 0)])
        var camera = SliceCamera.standard(.axial, grid: grid, viewportSize: SIMD2(64, 64))
        camera.center = grid.world(fromIndex: SIMD3(2, 7.5, 7.5))
        let layer = LabelLayer(volume: volume, lookupTable: lut, style: .fill, fillOpacity: 1)
        let scene = SliceScene(camera: camera, layers: [.label(layer)])
        let p = camera.pixel(forWorld: grid.world(fromIndex: SIMD3(2, 5, 9)))
        XCTAssertPixel(try renderer.render(scene: scene).pixel(x: Int(p.x), y: Int(p.y)), SIMD3(0, 0, 0))
        // Paint a 2x3x3 box on the CPU, upload only that region.
        let ptr = labels.pointer(as: UInt16.self)
        for a in 1..<3 { for b in 4..<7 { for c in 8..<11 { ptr[(a * 16 + b) * 16 + c] = 3 } } }
        try volume.update(region: VoxelRegion(lower: SIMD3(1, 4, 8), upper: SIMD3(3, 7, 11)), from: labels)
        let after = try renderer.render(scene: scene)
        XCTAssertPixel(after.pixel(x: Int(p.x), y: Int(p.y)), SIMD3(255, 255, 0))
        // An update from a different object of the same layout goes through staging.
        let copy = labels.copy()
        copy.pointer(as: UInt16.self)[(2 * 16 + 5) * 16 + 9] = 0
        try volume.update(region: VoxelRegion(origin: SIMD3(2, 5, 9), size: SIMD3(1, 1, 1)), from: copy)
        XCTAssertPixel(try renderer.render(scene: scene).pixel(x: Int(p.x), y: Int(p.y)), SIMD3(0, 0, 0))
    }

    // MARK: Slab

    func testSlabMIPPicksTheMaximum() throws {
        let grid = GridGeometry(id: "g", shape: [11, 16, 16], spacing: [1, 1, 1])
        // Background increases with k0 (10 per slice); one bright voxel at k0 = 7.
        let data = makeVolume(Int16.self, shape: [11, 16, 16]) { a, b, c in
            (a == 7 && b == 8 && c == 8) ? 1000 : Int16(a * 10)
        }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        var camera = SliceCamera.standard(.axial, grid: grid, viewportSize: SIMD2(64, 64))
        // Axial normal is world z = k2 here (identity direction: k0 -> x). Use a plane normal along k0 instead.
        camera = SliceCamera(center: grid.world(fromIndex: SIMD3(4, 8, 8)),
                             axes: PlaneAxes(right: SIMD3(0, 0, 1), down: SIMD3(0, 1, 0)),
                             millimetersPerPixel: 0.5, viewportSize: SIMD2(64, 64))
        XCTAssertEqual(camera.normal, SIMD3(-1, 0, 0))
        let layer = ImageLayer(volume: volume, windowCenter: 500, windowWidth: 1000, interpolation: .nearest)
        let mark = camera.pixel(forWorld: grid.world(fromIndex: SIMD3(4, 8, 8)))
        let background = camera.pixel(forWorld: grid.world(fromIndex: SIMD3(4, 3, 3)))
        var scene = SliceScene(camera: camera, layers: [.image(layer)])
        // Plain slice at k0 = 4: background 40, no mark.
        var image = try renderer.render(scene: scene)
        XCTAssertEqual(Double(image.pixel(x: Int(mark.x), y: Int(mark.y)).x), 40 * 255 / 1000, accuracy: 1.5)
        // A 6.6 mm slab (k0 = 0.7 … 7.3) holds the mark and slices 1 … 7.
        scene.slab = SlabSettings(mode: .maximum, thickness: 6.6)
        image = try renderer.render(scene: scene)
        XCTAssertEqual(image.pixel(x: Int(mark.x), y: Int(mark.y)).x, 255)
        XCTAssertEqual(Double(image.pixel(x: Int(background.x), y: Int(background.y)).x), 70 * 255 / 1000, accuracy: 1.5)
        // MinIP takes the smallest slice in the slab (k0 = 1).
        scene.slab.mode = .minimum
        image = try renderer.render(scene: scene)
        XCTAssertEqual(Double(image.pixel(x: Int(background.x), y: Int(background.y)).x), 10 * 255 / 1000, accuracy: 1.5)
        // Mean: slices 1…7 average 40 for the background.
        scene.slab.mode = .mean
        image = try renderer.render(scene: scene)
        XCTAssertEqual(Double(image.pixel(x: Int(background.x), y: Int(background.y)).x), 40 * 255 / 1000, accuracy: 2.5)
    }

    // MARK: Probability

    func testProbabilityThresholdAndContour() throws {
        let grid = GridGeometry(id: "g", shape: [3, 32, 32], spacing: [1, 1, 1], direction: axialDirection)
        // A radial ramp: p = 1 at the centre falling to 0 at radius 16.
        let data = makeVolume(Float.self, shape: [3, 32, 32]) { _, b, c in
            let r = (Double(b) - 15.5) * (Double(b) - 15.5) + (Double(c) - 15.5) * (Double(c) - 15.5)
            return Float(max(0, 1 - r.squareRoot() / 16))
        }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        var camera = SliceCamera.standard(.axial, grid: grid, viewportSize: SIMD2(128, 128))
        camera.millimetersPerPixel = 0.25
        camera.center = grid.world(fromIndex: SIMD3(1, 15.5, 15.5))
        var layer = ProbabilityLayer(volume: volume, colormap: .grayscale, threshold: 0.5, opacity: 1,
                                     showsContour: false)
        var image = try renderer.render(scene: SliceScene(camera: camera, layers: [.probability(layer)]))
        // Centre p = 1 -> white; radius 12 voxels p = 0.25 -> transparent (black).
        XCTAssertPixel(image.pixel(x: 64, y: 64), SIMD3(255, 255, 255), tolerance: 12)
        XCTAssertPixel(image.pixel(x: 64 + 48, y: 64), SIMD3(0, 0, 0))
        // The contour sits at radius 8 voxels (p = 0.5) = 32 px.
        layer.showsFill = false
        layer.showsContour = true
        layer.contourColor = SIMD4(1, 0, 0, 1)
        image = try renderer.render(scene: SliceScene(camera: camera, layers: [.probability(layer)]))
        var hits: [Int] = []
        for x in 64..<128 where image.pixel(x: x, y: 64).x > 128 { hits.append(x) }
        XCTAssertFalse(hits.isEmpty)
        let mid = Double(hits.reduce(0, +)) / Double(max(1, hits.count))
        XCTAssertEqual(mid, 64 + 32, accuracy: 2)
    }

    // MARK: Coordinates

    func testPixelWorldRoundTrip() {
        let grid = GridGeometry(id: "g", shape: [20, 30, 40], spacing: [2, 1, 0.5], direction: rotation(axis: SIMD3(0, 1, 1), degrees: 40))
        var camera = SliceCamera.standard(.coronal, grid: grid, orientation: .aligned, viewportSize: SIMD2(300, 200),
                                          pixelsPerPoint: 2)
        camera.zoom(by: 1.7, aboutPixel: SIMD2(40, 60))
        camera.pan(byPixels: SIMD2(13, -7))
        for p in [SIMD2<Double>(0, 0), SIMD2(150, 100), SIMD2(299.5, 0.5), SIMD2(12.25, 177.75)] {
            let w = camera.world(atPixel: p)
            XCTAssertEqual(simd_distance(camera.pixel(forWorld: w), p), 0, accuracy: 1e-9)
            XCTAssertEqual(camera.signedDistance(toPlane: w), 0, accuracy: 1e-9)
            let h = camera.pixelToWorld * SIMD4(p.x, p.y, 0, 1)
            XCTAssertEqual(simd_distance(SIMD3(h.x, h.y, h.z), w), 0, accuracy: 1e-9)
        }
        // Zoom keeps the anchor fixed.
        let anchor = SIMD2<Double>(80, 20)
        let before = camera.world(atPixel: anchor)
        camera.zoom(by: 0.6, aboutPixel: anchor)
        XCTAssertEqual(simd_distance(camera.world(atPixel: anchor), before), 0, accuracy: 1e-9)
    }
}
