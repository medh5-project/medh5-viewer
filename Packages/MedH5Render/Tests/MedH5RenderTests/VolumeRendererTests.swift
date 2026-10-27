import XCTest
import simd
import MedH5Core
@testable import MedH5Render

final class VolumeRendererTests: XCTestCase {
    var context: RenderContext!
    var renderer: VolumeRenderer!

    override func setUpWithError() throws {
        context = try makeTestContext()
        renderer = try VolumeRenderer(context: context)
    }

    func testMIPOfOneBrightVoxelLightsTheRightPixel() throws {
        let grid = GridGeometry(id: "g", shape: [24, 28, 32], spacing: [1.5, 1.0, 0.8], origin: [-10, 5, 3],
                                direction: rotation(axis: SIMD3(1, -1, 2), degrees: 30))
        let k = SIMD3<Int>(9, 17, 22)
        let data = makeVolume(Int16.self, shape: [24, 28, 32]) { a, b, c in
            SIMD3(a, b, c) == k ? 1000 : 0
        }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        let world = grid.world(fromIndex: SIMD3<Double>(k))
        for projection in [VolumeCamera.Projection.perspective, .orthographic] {
            for view in [AnatomicalView.anterior, .left, .superior] {
                var camera = VolumeCamera.framing(bounds: grid.worldBounds, from: view, viewportSize: SIMD2(200, 160),
                                                  projection: projection)
                camera.orbit(byPixels: SIMD2(17, -9))
                var scene = VolumeScene(camera: camera, image: VolumeImage(volume: volume, windowCenter: 500,
                                                                            windowWidth: 1000), mode: .mip)
                scene.quality = .full
                let image = try renderer.render(scene: scene)
                let expected = try XCTUnwrap(camera.project(world)).pixel
                // A single voxel seen through trilinear interpolation peaks below its value.
                let p = image.pixel(x: Int(expected.x), y: Int(expected.y))
                XCTAssertGreaterThan(p.x, 110, "\(projection) \(view)")
                let c = try XCTUnwrap(centroid(image) { $0.x > 100 })
                XCTAssertEqual(simd_distance(c.0, expected), 0, accuracy: 1.5, "\(projection) \(view)")
                // Elsewhere the volume is dark.
                XCTAssertLessThan(image.pixel(x: 5, y: 5).x, 10)
            }
        }
    }

    func testDVRStopsAtAnOpaqueCubeAndMeshesOccludeDepthCorrectly() throws {
        let grid = GridGeometry(id: "g", shape: [40, 40, 40], spacing: [1, 1, 1], origin: [-20, -20, -20],
                                direction: axialDirection)
        // A dense cube in the middle.
        let data = makeVolume(Int16.self, shape: [40, 40, 40]) { a, b, c in
            (10..<30).contains(a) && (10..<30).contains(b) && (10..<30).contains(c) ? 1000 : -1000
        }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        let camera = VolumeCamera.framing(bounds: grid.worldBounds, from: .anterior, viewportSize: SIMD2(128, 128),
                                          projection: .orthographic)
        let tf = TransferFunction(colorPoints: [.init(-1000, SIMD3(1, 0.5, 0)), .init(1000, SIMD3(1, 0.5, 0))],
                                  opacityPoints: [.init(0, 0), .init(100, 1)])
        var scene = VolumeScene(camera: camera, image: VolumeImage(volume: volume, windowCenter: 0, windowWidth: 2000),
                                mode: .dvr, transferFunction: tf)
        scene.shading.enabled = false
        var image = try renderer.render(scene: scene)
        let centre = image.pixel(x: 64, y: 64)
        XCTAssertGreaterThan(centre.x, 200)
        XCTAssertEqual(Double(centre.y), Double(centre.x) / 2, accuracy: 8)
        XCTAssertLessThan(image.pixel(x: 3, y: 3).x, 5, "outside the cube is transparent")

        // A green sphere in front of the cube (towards the camera) hides it ...
        let front = camera.target - camera.forward * 15
        let sphere = try GPUMesh(context: context, mesh: .icosphere(center: front, radius: 3, subdivisions: 3))
        scene.meshes = [MeshInstance(mesh: sphere, color: SIMD4(0, 1, 0, 1))]
        image = try renderer.render(scene: scene)
        let sp = try XCTUnwrap(camera.project(front)).pixel
        let onSphere = image.pixel(x: Int(sp.x), y: Int(sp.y))
        XCTAssertGreaterThan(onSphere.y, 100)
        XCTAssertLessThan(onSphere.x, 60)
        // ... and one behind it is hidden by the cube.
        let back = camera.target + camera.forward * 15
        let hidden = try GPUMesh(context: context, mesh: .icosphere(center: back, radius: 3, subdivisions: 3))
        scene.meshes = [MeshInstance(mesh: hidden, color: SIMD4(0, 1, 0, 1))]
        image = try renderer.render(scene: scene)
        let bp = try XCTUnwrap(camera.project(back)).pixel
        let behind = image.pixel(x: Int(bp.x), y: Int(bp.y))
        XCTAssertGreaterThan(behind.x, 200)
        XCTAssertLessThan(Int(behind.y), Int(behind.x) / 2 + 10)
    }

    func testLabelSurfacesUseClassColoursAndVisibility() throws {
        let grid = GridGeometry(id: "g", shape: [32, 32, 32], spacing: [1, 1, 1], origin: [-16, -16, -16],
                                direction: axialDirection)
        // Class 2 on the patient's left half (+x), class 5 on the right (-x).
        let labels = makeVolume(UInt16.self, shape: [32, 32, 32]) { a, b, c in
            let w = grid.world(fromIndex: SIMD3(Double(a), Double(b), Double(c)))
            guard simd_length(w) < 12 else { return 0 }
            return w.x > 0 ? 2 : 5
        }
        let volume = try VolumeTexture(context: context, labels: labels, geometry: grid)
        let lut = try LabelLookupTable(context: context, colors: [2: RGBA8(255, 0, 0), 5: RGBA8(0, 0, 255)])
        let camera = VolumeCamera.framing(bounds: grid.worldBounds, from: .anterior, viewportSize: SIMD2(160, 160))
        var scene = VolumeScene(camera: camera)
        scene.labels = [VolumeLabelLayer(volume: volume, lookupTable: lut)]
        var image = try renderer.render(scene: scene)
        // Anterior view: patient left (+x, red) on screen right.
        let left = try XCTUnwrap(camera.project(SIMD3(6, -8, 0))).pixel
        let right = try XCTUnwrap(camera.project(SIMD3(-6, -8, 0))).pixel
        var p = image.pixel(x: Int(left.x), y: Int(left.y))
        XCTAssertGreaterThan(p.x, 80)
        XCTAssertLessThan(p.z, 30)
        p = image.pixel(x: Int(right.x), y: Int(right.y))
        XCTAssertGreaterThan(p.z, 80)
        XCTAssertLessThan(p.x, 30)
        XCTAssertGreaterThan(left.x, right.x)
        // Hiding class 2 removes it.
        lut.setVisible(false, forClass: 2)
        image = try renderer.render(scene: scene)
        p = image.pixel(x: Int(left.x), y: Int(left.y))
        XCTAssertLessThan(p.x, 10)
    }

    func testIsosurfaceAndClipPlane() throws {
        let grid = GridGeometry(id: "g", shape: [40, 40, 40], spacing: [1, 1, 1], origin: [-20, -20, -20],
                                direction: axialDirection)
        let data = makeVolume(Float.self, shape: [40, 40, 40]) { a, b, c in
            Float(15 - simd_length(grid.world(fromIndex: SIMD3(Double(a), Double(b), Double(c)))))
        }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        let camera = VolumeCamera.framing(bounds: grid.worldBounds, from: .anterior, viewportSize: SIMD2(128, 128))
        var scene = VolumeScene(camera: camera, image: VolumeImage(volume: volume, windowCenter: 0, windowWidth: 30),
                                mode: .isosurface)
        scene.isoValue = 0
        scene.isoColor = SIMD4(1, 1, 1, 1)
        var image = try renderer.render(scene: scene)
        XCTAssertGreaterThan(image.pixel(x: 64, y: 64).x, 150, "sphere centre facing the light")
        XCTAssertLessThan(image.pixel(x: 2, y: 64).x, 5)
        // Clipping away the half facing the camera (anterior, -y) shows the inside: still hits the far half.
        scene.clipPlane = Plane(point: .zero, normal: SIMD3(0, 1, 0))
        image = try renderer.render(scene: scene)
        XCTAssertGreaterThan(image.pixel(x: 64, y: 64).x, 30)
        // A clip box excluding the sphere leaves nothing.
        scene.clipPlane = nil
        scene.clipBox = .world(lower: SIMD3(-20, -20, 16), upper: SIMD3(20, 20, 20))
        image = try renderer.render(scene: scene)
        XCTAssertLessThan(image.pixel(x: 64, y: 64).x, 5)
    }

    func testCameraProjectionRoundTrip() {
        for projection in [VolumeCamera.Projection.perspective, .orthographic] {
            var camera = VolumeCamera.framing(bounds: (SIMD3(-50, -40, -30), SIMD3(60, 40, 30)), from: .left,
                                              viewportSize: SIMD2(400, 300), projection: projection)
            camera.orbit(byPixels: SIMD2(40, 25))
            camera.pan(byPixels: SIMD2(-12, 7))
            camera.zoom(by: 1.3)
            let x = SIMD3<Double>(10, -5, 12)
            let (pixel, _) = camera.project(x)!
            let ray = camera.ray(atPixel: pixel)
            // x lies on the ray through its pixel.
            let v = x - ray.origin
            let along = simd_dot(v, ray.direction)
            XCTAssertEqual(simd_distance(ray.origin + ray.direction * along, x), 0, accuracy: 1e-6, "\(projection)")
        }
    }
}

final class VolumeRendererCacheTests: XCTestCase {
    /// Skipping empty bricks changes nothing in the image.
    func testEmptySpaceSkippingIsExact() throws {
        let context = try makeTestContext()
        let renderer = try VolumeRenderer(context: context)
        let grid = GridGeometry(id: "g", shape: [48, 56, 64], spacing: [1.5, 1, 1], origin: [-30, -28, -24],
                                direction: rotation(axis: SIMD3(0, 1, 1), degrees: 15))
        let data = makeVolume(Int16.self, shape: [48, 56, 64]) { a, b, c in
            let w = grid.world(fromIndex: SIMD3(Double(a), Double(b), Double(c)))
            if simd_length(w - SIMD3(5, 0, 0)) < 12 { return 900 }
            if simd_length(w + SIMD3(10, 5, 0)) < 6 { return 300 }
            return Int16((a * 7 + b * 3 + c) % 40) - 20
        }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        let labels = makeVolume(UInt16.self, shape: [48, 56, 64]) { a, b, c in
            (20..<26).contains(a) && (5..<12).contains(b) && (40..<50).contains(c) ? 4 : 0
        }
        let labelTexture = try VolumeTexture(context: context, labels: labels, geometry: grid)
        let lut = try LabelLookupTable(context: context)
        var camera = VolumeCamera.framing(bounds: grid.worldBounds, from: .left, viewportSize: SIMD2(160, 120))
        camera.orbit(byPixels: SIMD2(23, -31))
        var scene = VolumeScene(camera: camera, image: VolumeImage(volume: volume, windowCenter: 0, windowWidth: 1000),
                                mode: .dvr, transferFunction: .preset(.ctBone))
        scene.labels = [VolumeLabelLayer(volume: labelTexture, lookupTable: lut)]
        for mode in [VolumeRenderMode.dvr, .isosurface] {
            scene.mode = mode
            renderer.skipsEmptySpace = true
            let fast = try renderer.render(scene: scene)
            renderer.skipsEmptySpace = false
            let slow = try renderer.render(scene: scene)
            var maxDiff = 0
            var lit = 0
            for i in 0..<fast.bytes.count {
                maxDiff = max(maxDiff, abs(Int(fast.bytes[i]) - Int(slow.bytes[i])))
                if fast.bytes[i] > 20 { lit += 1 }
            }
            XCTAssertLessThanOrEqual(maxDiff, 1, "\(mode)")
            XCTAssertGreaterThan(lit, 1000, "\(mode) draws something")
        }
        XCTAssertGreaterThan(renderer.cachedMemorySize, 0)
    }

    /// Painting labels reaches the 3-D view through an incremental update of
    /// its indicator; hiding a class rebuilds it.
    func testLabelEditsReachTheThreeDView() throws {
        let context = try makeTestContext()
        let renderer = try VolumeRenderer(context: context)
        let grid = GridGeometry(id: "g", shape: [40, 40, 40], spacing: [1, 1, 1], origin: [-20, -20, -20],
                                direction: axialDirection)
        let labels = VolumeData(scalarType: .uint16, shape: [40, 40, 40])
        let texture = try VolumeTexture(context: context, labels: labels, geometry: grid)
        let lut = try LabelLookupTable(context: context, colors: [7: RGBA8(0, 255, 0)])
        let camera = VolumeCamera.framing(bounds: grid.worldBounds, from: .anterior, viewportSize: SIMD2(128, 128),
                                          projection: .orthographic)
        var scene = VolumeScene(camera: camera)
        scene.labels = [VolumeLabelLayer(volume: texture, lookupTable: lut)]
        XCTAssertLessThan(try renderer.render(scene: scene).pixel(x: 64, y: 64).y, 5, "empty")
        // Paint a block in the middle and upload only it.
        let p = labels.pointer(as: UInt16.self)
        for a in 15..<25 { for b in 15..<25 { for c in 15..<25 { p[(a * 40 + b) * 40 + c] = 7 } } }
        try texture.update(region: VoxelBox(lower: SIMD3(15, 15, 15), upper: SIMD3(25, 25, 25)), from: labels)
        XCTAssertEqual(texture.changedRegion(since: 0), VoxelBox(lower: SIMD3(15, 15, 15), upper: SIMD3(25, 25, 25)))
        XCTAssertGreaterThan(try renderer.render(scene: scene).pixel(x: 64, y: 64).y, 60, "painted block appears")
        lut.setVisible(false, forClass: 7)
        XCTAssertLessThan(try renderer.render(scene: scene).pixel(x: 64, y: 64).y, 5, "hidden class disappears")
        lut.setVisible(true, forClass: 7)
        // Erase it again.
        for a in 15..<25 { for b in 15..<25 { for c in 15..<25 { p[(a * 40 + b) * 40 + c] = 0 } } }
        try texture.update(region: VoxelBox(lower: SIMD3(15, 15, 15), upper: SIMD3(25, 25, 25)), from: labels)
        XCTAssertLessThan(try renderer.render(scene: scene).pixel(x: 64, y: 64).y, 5, "erased")
    }
}
