import XCTest
import simd
import MedH5Core
@testable import MedH5Render

final class OverlayTests: XCTestCase {
    var context: RenderContext!
    var renderer: SliceRenderer!
    // 1 mm per pixel, the plane z = 0, pixel (64, 64) at the world origin.
    let camera = SliceCamera(center: .zero, axes: PlaneAxes(right: SIMD3(1, 0, 0), down: SIMD3(0, 1, 0)),
                             millimetersPerPixel: 1, viewportSize: SIMD2(128, 128))

    override func setUpWithError() throws {
        context = try makeTestContext()
        renderer = try SliceRenderer(context: context)
    }

    private func render(_ overlays: [Overlay], tolerance: Double? = nil) throws -> RenderedImage {
        var scene = SliceScene(camera: camera, overlays: overlays)
        scene.overlayDepthTolerance = tolerance
        return try renderer.render(scene: scene)
    }

    private func world(_ x: Double, _ y: Double, _ z: Double = 0) -> SIMD3<Double> {
        camera.world(atPixel: SIMD2(x, y)) + SIMD3(0, 0, z)
    }

    func testPolygonFillUsesTheEvenOddRule() throws {
        let outer = [world(20, 20), world(100, 20), world(100, 100), world(20, 100)]
        let hole = [world(50, 50), world(70, 50), world(70, 70), world(50, 70)]
        let style = OverlayStyle(color: SIMD4(0, 0, 0, 0), lineWidth: 1, fillColor: SIMD4(1, 0, 0, 1))
        let image = try render([Overlay(.polygon([outer, hole]), style: style)])
        XCTAssertPixel(image.pixel(x: 30, y: 30), SIMD3(255, 0, 0), "inside the outer ring")
        XCTAssertPixel(image.pixel(x: 60, y: 60), SIMD3(0, 0, 0), "inside the hole")
        XCTAssertPixel(image.pixel(x: 10, y: 10), SIMD3(0, 0, 0), "outside")
        // The stencil is cleared after each polygon: a second polygon over the hole fills it.
        let patch = Overlay(.polygon([hole]), style: OverlayStyle(color: SIMD4(0, 0, 0, 0), fillColor: SIMD4(0, 0, 1, 1)))
        let both = try render([Overlay(.polygon([outer, hole]), style: style), patch])
        XCTAssertPixel(both.pixel(x: 60, y: 60), SIMD3(0, 0, 255))
        XCTAssertPixel(both.pixel(x: 30, y: 30), SIMD3(255, 0, 0))
    }

    func testDepthPolicies() throws {
        let style = OverlayStyle.stroke(SIMD4(0, 1, 0, 1), width: 3)
        let line = [world(10, 64, 5), world(118, 64, 5)]   // 5 mm in front of the plane
        // Automatic: hidden beyond the tolerance.
        var image = try render([Overlay(.polyline(line, closed: false), style: style)], tolerance: 0.5)
        XCTAssertLessThan(image.pixel(x: 64, y: 64).y, 10)
        // Always: projected onto the plane.
        image = try render([Overlay(.polyline(line, closed: false), style: style, depthPolicy: .always)])
        XCTAssertPixel(image.pixel(x: 64, y: 64), SIMD3(0, 255, 0))
        // Fade: full within 2 mm, gone at 8 mm; at 5 mm half.
        image = try render([Overlay(.polyline(line, closed: false), style: style,
                                    depthPolicy: .fade(beyond: 2, over: 6))])
        XCTAssertEqual(Double(image.pixel(x: 64, y: 64).y), 127.5, accuracy: 3)
        // A line crossing the plane is clipped to the visible slab around it.
        let crossing = [world(10, 64, -10), world(118, 64, 10)]   // z = 0 at x = 64
        image = try render([Overlay(.polyline(crossing, closed: false), style: style,
                                    depthPolicy: .hide(beyond: 2))])
        XCTAssertPixel(image.pixel(x: 64, y: 64), SIMD3(0, 255, 0))
        XCTAssertLessThan(image.pixel(x: 20, y: 64).y, 10)
        XCTAssertLessThan(image.pixel(x: 110, y: 64).y, 10)
    }

    func testMarkersDashesAndCircles() throws {
        let markers = Overlay(.markers([world(30, 30), world(90, 30)], shape: .circle, size: 12, filled: true),
                              style: .stroke(SIMD4(1, 1, 0, 1)), depthPolicy: .always)
        let dashed = Overlay(.segments([world(10, 100), world(118, 100)]),
                             style: OverlayStyle(color: SIMD4(1, 1, 1, 1), lineWidth: 2, dash: DashPattern(on: 6, off: 6)),
                             depthPolicy: .always)
        let ring = Overlay(.screenCircle(center: world(64, 64), radius: 20, filled: false),
                           style: .stroke(SIMD4(0, 1, 1, 1), width: 2), depthPolicy: .always)
        let image = try render([markers, dashed, ring])
        XCTAssertPixel(image.pixel(x: 30, y: 30), SIMD3(255, 255, 0))
        XCTAssertPixel(image.pixel(x: 90, y: 30), SIMD3(255, 255, 0))
        XCTAssertPixel(image.pixel(x: 60, y: 30), SIMD3(0, 0, 0))
        // Dashes: runs of lit and unlit pixels along the line.
        var transitions = 0
        var last = image.pixel(x: 12, y: 100).x > 128
        for x in 13..<116 {
            let lit = image.pixel(x: x, y: 100).x > 128
            if lit != last { transitions += 1 }
            last = lit
        }
        XCTAssertGreaterThan(transitions, 12)
        // The ring passes 20 px from the centre, the centre stays empty.
        XCTAssertGreaterThan(image.pixel(x: 84, y: 64).y, 200)
        XCTAssertLessThan(image.pixel(x: 64, y: 64).y, 10)
    }

    func testBoxIntersectionOutline() throws {
        // A box 40 mm wide crossing the plane: its outline is the 40 × 20 rectangle.
        let box = OrientedBox(lower: SIMD3(-20, -10, -5), upper: SIMD3(20, 10, 5))
        let image = try render([Overlay(.box(box), style: .stroke(SIMD4(1, 0, 1, 1), width: 2))])
        XCTAssertGreaterThan(image.pixel(x: 64 - 20, y: 64).x, 150, "left edge")
        XCTAssertGreaterThan(image.pixel(x: 64 + 20, y: 64).x, 150, "right edge")
        XCTAssertGreaterThan(image.pixel(x: 64, y: 64 - 10).x, 150, "top edge")
        XCTAssertLessThan(image.pixel(x: 64, y: 64).x, 10, "inside")
        // A box away from the plane is not drawn, unless a slab reaches it.
        let far = OrientedBox(lower: SIMD3(-20, -10, 6), upper: SIMD3(20, 10, 12))
        var scene = SliceScene(camera: camera, overlays: [Overlay(.box(far), style: .stroke(SIMD4(1, 0, 1, 1), width: 2))])
        XCTAssertLessThan(try renderer.render(scene: scene).pixel(x: 44, y: 64).x, 10)
        scene.slab = SlabSettings(mode: .maximum, thickness: 14)
        XCTAssertGreaterThan(try renderer.render(scene: scene).pixel(x: 44, y: 64).x, 150, "projection within the slab")
    }
}
