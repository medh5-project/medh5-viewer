import XCTest
import AppKit
import simd
import MedH5Core
@testable import MedH5Render

@MainActor
final class ViewTests: XCTestCase {
    private func makeSliceView() throws -> (SliceView, GridGeometry) {
        let context = try makeTestContext()
        let grid = GridGeometry(id: "g", shape: [20, 32, 32], spacing: [2, 1, 1], direction: axialDirection)
        let data = makeVolume(Int16.self, shape: [20, 32, 32]) { a, _, _ in Int16(a * 10) }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        let camera = SliceCamera.standard(.axial, grid: grid, viewportSize: SIMD2(400, 200), pixelsPerPoint: 2)
        let scene = SliceScene(camera: camera, layers: [.image(ImageLayer(volume: volume, windowCenter: 100,
                                                                         windowWidth: 200))])
        let view = try SliceView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), context: context, scene: scene)
        view.drawableSize = CGSize(width: 400, height: 200)
        return (view, grid)
    }

    func testSliceViewCoordinates() throws {
        let (view, _) = try makeSliceView()
        view.syncViewport()
        // Bottom-left view point (0, 0) is the drawable's bottom-left pixel corner.
        XCTAssertEqual(view.pixel(fromViewPoint: .zero), SIMD2(0, 200))
        XCTAssertEqual(view.pixel(fromViewPoint: CGPoint(x: 200, y: 100)), SIMD2(400, 0))
        let p = CGPoint(x: 37.5, y: 61.25)
        let q = view.viewPoint(fromPixel: view.pixel(fromViewPoint: p))
        XCTAssertEqual(q.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(q.y, p.y, accuracy: 1e-9)
        let w = view.worldPoint(atViewPoint: p)
        let back = view.viewPoint(forWorld: w)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
        XCTAssertEqual(view.distance(fromViewPoint: p, toWorld: w), 0, accuracy: 1e-6)
        let image = try view.snapshot()
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 200)
        let big = try view.snapshot(scale: 2)
        XCTAssertEqual(big.width, 800)
    }

    func testDefaultSliceNavigation() throws {
        let (view, grid) = try makeSliceView()
        view.syncViewport()
        var changes = 0
        view.sceneChangedByInteraction = { _ in changes += 1 }
        let start = view.scene.camera.sliceIndex(in: grid)
        // ↑ moves one slice, Page Up ten, End to the last slice, Home to the first.
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                             keyCode: code)!
        }
        view.keyDown(with: key(KeyCode.upArrow))
        XCTAssertEqual(view.scene.camera.sliceIndex(in: grid).index, start.index + 1, accuracy: 1e-6)
        view.keyDown(with: key(KeyCode.pageDown))
        XCTAssertEqual(view.scene.camera.sliceIndex(in: grid).index, max(0, start.index - 9), accuracy: 1e-6)
        view.keyDown(with: key(KeyCode.end))
        XCTAssertEqual(view.scene.camera.sliceIndex(in: grid).index, Double(start.count - 1), accuracy: 1e-6)
        view.keyDown(with: key(KeyCode.home))
        XCTAssertEqual(view.scene.camera.sliceIndex(in: grid).index, 0, accuracy: 1e-6)
        XCTAssertEqual(changes, 4)

        // A scroll notch moves one slice (the slice step is 2 mm here).
        let before = view.scene.camera.center
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        view.scrollWheel(with: NSEvent(cgEvent: cg)!)
        XCTAssertEqual(simd_distance(view.scene.camera.center, before), 2, accuracy: 1e-6)

        // A shift-drag changes the base layer's window.
        let width = view.scene.baseImageLayer!.windowWidth
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50), .shift))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 90, y: 50), .shift))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 90, y: 50), .shift))
        XCTAssertGreaterThan(view.scene.baseImageLayer!.windowWidth, width)

        // An option-drag pans: the world point under the pointer follows it.
        let anchor = view.worldPoint(atViewPoint: CGPoint(x: 50, y: 50))
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50), .option))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 70, y: 40), .option))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 70, y: 40), .option))
        XCTAssertEqual(simd_distance(view.worldPoint(atViewPoint: CGPoint(x: 70, y: 40)), anchor), 0, accuracy: 1e-6)

        // A handler that takes the event stops navigation.
        final class Eater: SliceViewInteraction {
            var seen = 0
            func sliceView(_ view: SliceView, handle event: SliceViewEvent) -> Bool {
                seen += 1
                return true
            }
        }
        let eater = Eater()
        view.interactionHandler = eater
        let center = view.scene.camera.center
        view.keyDown(with: key(KeyCode.upArrow))
        XCTAssertEqual(eater.seen, 1)
        XCTAssertEqual(view.scene.camera.center, center)
    }

    func testVolumeViewNavigationAndSnapshot() throws {
        let context = try makeTestContext()
        let grid = GridGeometry(id: "g", shape: [16, 16, 16], spacing: [1, 1, 1], origin: [-8, -8, -8])
        let data = makeVolume(UInt8.self, shape: [16, 16, 16]) { a, b, c in (a + b + c) % 7 == 0 ? 255 : 0 }
        let volume = try VolumeTexture(context: context, scalars: data, geometry: grid)
        let camera = VolumeCamera.framing(bounds: grid.worldBounds, viewportSize: SIMD2(300, 200))
        let scene = VolumeScene(camera: camera, image: VolumeImage(volume: volume, windowCenter: 128, windowWidth: 256),
                                mode: .mip)
        let view = try VolumeView(frame: CGRect(x: 0, y: 0, width: 150, height: 100), context: context, scene: scene)
        view.drawableSize = CGSize(width: 300, height: 200)
        view.syncViewport()
        let orientation = view.scene.camera.orientation
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 80, y: 50)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 80, y: 50)))
        XCTAssertNotEqual(view.scene.camera.orientation, orientation, "drag orbits")
        // The target stays put while orbiting.
        XCTAssertEqual(simd_distance(view.scene.camera.target, camera.target), 0, accuracy: 1e-9)
        let distance = view.scene.camera.distance
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
        view.scrollWheel(with: NSEvent(cgEvent: cg)!)
        XCTAssertLessThan(view.scene.camera.distance, distance, "scrolling up zooms in")
        // Double-click resets.
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50), clicks: 2))
        XCTAssertEqual(view.scene.camera.distance, VolumeCamera.framing(bounds: grid.worldBounds,
                                                                        viewportSize: SIMD2(300, 200)).distance,
                       accuracy: 1e-6)
        // Rays through view points hit what the camera projects there.
        let x = SIMD3<Double>(2, -3, 1)
        let p = try XCTUnwrap(view.viewPoint(forWorld: x))
        let ray = view.ray(atViewPoint: p)
        let v = x - ray.origin
        XCTAssertEqual(simd_length(v - ray.direction * simd_dot(v, ray.direction)), 0, accuracy: 1e-6)
        let image = try view.snapshot()
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 200)
    }
}
