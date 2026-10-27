import XCTest
import simd
import MedH5Core
@testable import MedH5Editing

/// A deterministic random number generator (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func makeGeometry(shape: [Int], spacing: [Double], origin: [Double]? = nil, direction: [[Double]]? = nil,
                  frameUID: String? = "frame") -> GridGeometry {
    GridGeometry(id: "seg", shape: shape, spacing: spacing, origin: origin, direction: direction, frameUID: frameUID)
}

/// A model with classes `(id, layer)`, none of them in the coverage yet.
func makeModel(shape: [Int], spacing: [Double] = [1, 1, 1], origin: [Double]? = nil, direction: [[Double]]? = nil,
               classes: [(UInt16, Int)] = [(1, 0), (2, 0), (3, 1)], layerCount: Int = 2,
               inAnnotation: Bool = false) throws -> SegmentationModel {
    let meta = SegmentationMetadata(
        classes: classes.map { SegmentClass(id: $0.0, key: "c\($0.0)", name: "Class \($0.0)", layer: $0.1) },
        classIDs: inAnnotation ? classes.map(\.0) : [],
        annotatedClassIDs: inAnnotation ? classes.map(\.0) : [],
        layerCount: layerCount)
    return try SegmentationModel(geometry: makeGeometry(shape: shape, spacing: spacing, origin: origin, direction: direction),
                                 metadata: meta)
}

/// A copy of every layer's values.
func snapshot(_ m: SegmentationModel) -> [[UInt16]] {
    m.layers.map { Array(UnsafeBufferPointer(start: $0.pointer(as: UInt16.self), count: $0.count)) }
}

/// Writes `value` into a layer wherever `predicate` holds, bypassing edits
/// (test setup only).
func fillRaw(_ m: SegmentationModel, layer: Int, value: UInt16, where predicate: (SIMD3<Int>) -> Bool) {
    let p = m.layers[layer].pointer(as: UInt16.self)
    let n = m.shape
    for z in 0..<n.x { for y in 0..<n.y { for x in 0..<n.z where predicate(SIMD3(z, y, x)) {
        p[(z * n.y + y) * n.z + x] = value
    } } }
}

/// The voxels of a set, as a Swift set.
func voxels(of set: some VoxelSet) -> Set<SIMD3<Int>> {
    var out = Set<SIMD3<Int>>()
    set.forEachVoxel { out.insert($0) }
    return out
}

/// The voxels of a class in a model.
func voxels(of classID: UInt16, in m: SegmentationModel) -> Set<SIMD3<Int>> {
    guard let l = m.layer(of: classID) else { return [] }
    let p = m.layers[l].pointer(as: UInt16.self)
    var out = Set<SIMD3<Int>>()
    let n = m.shape
    for z in 0..<n.x { for y in 0..<n.y { for x in 0..<n.z where p[(z * n.y + y) * n.z + x] == classID {
        out.insert(SIMD3(z, y, x))
    } } }
    return out
}

/// Every voxel of a padded shape satisfying a predicate.
func allVoxels(_ n: SIMD3<Int>, where predicate: (SIMD3<Int>) -> Bool) -> Set<SIMD3<Int>> {
    var out = Set<SIMD3<Int>>()
    for z in 0..<n.x { for y in 0..<n.y { for x in 0..<n.z where predicate(SIMD3(z, y, x)) {
        out.insert(SIMD3(z, y, x))
    } } }
    return out
}

/// A mask over the whole volume from a predicate.
func makeMask(_ n: SIMD3<Int>, where predicate: (SIMD3<Int>) -> Bool) -> VoxelMask {
    var m = VoxelMask(bounds: VoxelBox(shape: n))
    for z in 0..<n.x { for y in 0..<n.y { for x in 0..<n.z where predicate(SIMD3(z, y, x)) {
        m[SIMD3(z, y, x)] = true
    } } }
    return m
}

/// An image whose values come from a closure.
func makeImage<T: VoxelScalar>(_ type: T.Type, geometry: GridGeometry, slope: Double = 1, intercept: Double = 0,
                               modality: String = "CT", value: (SIMD3<Int>) -> T) -> ImageVolume {
    let n = geometry.paddedShape
    var values = [T]()
    values.reserveCapacity(n.x * n.y * n.z)
    for z in 0..<n.x { for y in 0..<n.y { for x in 0..<n.z { values.append(value(SIMD3(z, y, x))) } } }
    let data = VolumeData(shape: geometry.shape, values: values)
    return ImageVolume(id: "img", data: data, geometry: geometry, rescaleSlope: slope, rescaleIntercept: intercept,
                       modality: modality)
}

/// Squared world distance between two voxel centres of a grid.
func worldDistance2(_ g: GridGeometry, _ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Double {
    simd_length_squared(g.worldPosition(ofVoxel: a) - g.worldPosition(ofVoxel: b))
}

extension SIMD3 where Scalar == Int {
    var description3: String { "(\(x), \(y), \(z))" }
}

/// Whether a voxel set is 6-connected (or 4-connected in a slice).
func isFaceConnected(_ set: Set<SIMD3<Int>>) -> Bool {
    guard let start = set.first else { return true }
    var seen: Set<SIMD3<Int>> = [start]
    var stack = [start]
    let steps = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
    while let v = stack.popLast() {
        for s in steps {
            let w = v &+ s
            if set.contains(w) && !seen.contains(w) {
                seen.insert(w)
                stack.append(w)
            }
        }
    }
    return seen.count == set.count
}

/// Whether the tests run an optimised build (performance assertions apply only then).
var isOptimizedBuild: Bool {
    #if DEBUG
    return false
    #else
    return true
    #endif
}

/// A copy of a volume's values (never hold a pointer into a temporary volume).
func copyValues<T: VoxelScalar>(_ volume: VolumeData, as type: T.Type) -> [T] {
    withExtendedLifetime(volume) { Array(UnsafeBufferPointer(start: volume.pointer(as: type), count: volume.count)) }
}
