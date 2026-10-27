import XCTest
import Metal
import simd
import MedH5Core
@testable import MedH5Render

/// A fresh context per test, or a skip when the machine has no Metal device.
func makeTestContext() throws -> RenderContext {
    guard MTLCreateSystemDefaultDevice() != nil else {
        throw XCTSkip("no Metal device")
    }
    return try RenderContext()
}

/// A volume of `shape` filled by `value(k0, k1, k2)`.
func makeVolume<T: VoxelScalar>(_ type: T.Type, shape: [Int], value: (Int, Int, Int) -> T) -> VolumeData {
    let data = VolumeData(scalarType: T.scalarType, shape: shape)
    let p = data.pointer(as: T.self)
    var i = 0
    for a in 0..<shape[0] {
        for b in 0..<shape[1] {
            for c in 0..<shape[2] {
                p[i] = value(a, b, c)
                i += 1
            }
        }
    }
    return data
}

/// A rotation matrix (columns are the rotated axes) about `axis` by `degrees`.
func rotation(axis: SIMD3<Double>, degrees: Double) -> [[Double]] {
    let q = simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis))
    let m = simd_double3x3(q)
    // direction[r][c] = component r of column c
    return (0..<3).map { r in (0..<3).map { c in m[c][r] } }
}

/// Centroid (in pixel-centre coordinates) of the pixels whose RGB passes `test`.
func centroid(_ image: RenderedImage, where test: (SIMD4<UInt8>) -> Bool) -> (SIMD2<Double>, Int)? {
    var sum = SIMD2<Double>(0, 0)
    var n = 0
    for y in 0..<image.height {
        for x in 0..<image.width where test(image.pixel(x: x, y: y)) {
            sum += SIMD2(Double(x) + 0.5, Double(y) + 0.5)
            n += 1
        }
    }
    return n > 0 ? (sum / Double(n), n) : nil
}

extension SIMD4 where Scalar == UInt8 {
    var rgb: SIMD3<Int> { SIMD3(Int(x), Int(y), Int(z)) }
}

func XCTAssertPixel(_ p: SIMD4<UInt8>, _ expected: SIMD3<Int>, tolerance: Int = 1,
                    _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let d = p.rgb &- expected
    let ok = abs(d.x) <= tolerance && abs(d.y) <= tolerance && abs(d.z) <= tolerance
    XCTAssertTrue(ok, "pixel \(p.rgb) != expected \(expected) ± \(tolerance) \(message)", file: file, line: line)
}

/// The direction of a typical axial acquisition stored (z, y, x): index axis
/// 0 → world z, 1 → world y, 2 → world x (so world = (k2, k1, k0) with unit spacing).
let axialDirection: [[Double]] = [[0, 0, 1], [0, 1, 0], [1, 0, 0]]
