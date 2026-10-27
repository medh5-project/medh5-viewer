import Foundation
import simd
import MedH5Core

/// An axis-aligned box (spec §8.2), held in padded coordinates of its set's
/// space and measured at voxel **edges**: in index space a box covering
/// voxels `a ..< b` on an axis has `lower = a − 0.5`, `upper = b − 0.5`.
///
/// A **2-D box on a slice** — the common radiology annotation — has one
/// degenerate axis (`lower == upper`) and a `sliceIndex`: the plane of that
/// axis it was drawn on (it then covers that one slice). Create one with
/// `fromDrag(from:to:planeNormal:geometry:classID:)`.
public struct BoxAnnotation: Sendable, Hashable {
    public var lower: SIMD3<Double>
    public var upper: SIMD3<Double>
    public var classID: UInt16
    public var instanceID: UInt64?
    public var score: Float?
    /// Free-form attributes, a JSON object.
    public var attributes: String?
    /// The slice of the degenerate axis a 2-D box lies on.
    public var sliceIndex: Int?

    public init(lower: SIMD3<Double>, upper: SIMD3<Double>, classID: UInt16, instanceID: UInt64? = nil,
                score: Float? = nil, attributes: String? = nil, sliceIndex: Int? = nil) {
        self.lower = lower
        self.upper = upper
        self.classID = classID
        self.instanceID = instanceID
        self.score = score
        self.attributes = attributes
        self.sliceIndex = sliceIndex
    }

    /// The box covering a set of voxels (index space).
    public static func covering(_ box: VoxelBox, classID: UInt16) -> BoxAnnotation {
        BoxAnnotation(lower: box.edgeLower, upper: box.edgeUpper, classID: classID)
    }

    /// The single axis with no extent, or nil.
    public var degenerateAxis: Int? {
        let flat = (0..<3).filter { lower[$0] == upper[$0] }
        return flat.count == 1 ? flat[0] : nil
    }

    /// Whether this is a 2-D box on a slice.
    public var isOnSlice: Bool { sliceIndex != nil && degenerateAxis != nil }

    public var center: SIMD3<Double> { (lower + upper) / 2 }
    public var size: SIMD3<Double> { upper - lower }

    /// The voxels the box covers (index space, spec §8.1:
    /// `floor(lo + 0.5) ..< floor(hi + 0.5)`); a box on a slice covers its
    /// slice, one voxel thick.
    public var voxelBox: VoxelBox {
        var b = VoxelBox(edgeLower: lower, edgeUpper: upper)
        if let k = sliceIndex, let a = degenerateAxis {
            b.lower[a] = k
            b.upper[a] = k + 1
        }
        return b
    }

    /// Lower and upper swapped where they crossed.
    public func normalized() -> BoxAnnotation {
        var b = self
        b.lower = simd_min(lower, upper)
        b.upper = simd_max(lower, upper)
        return b
    }

    /// The box translated. A box on a slice moving across its slice axis
    /// follows to the slice its new position rounds to.
    public func moved(by delta: SIMD3<Double>) -> BoxAnnotation {
        var b = self
        b.lower += delta
        b.upper += delta
        if sliceIndex != nil, let a = degenerateAxis {
            b.sliceIndex = Int((b.lower[a] + 0.5).rounded(.down))
        }
        return b
    }

    /// The box with its edges rounded to the nearest voxel edges (index
    /// space). A degenerate axis is left alone.
    public func snappedToVoxelEdges() -> BoxAnnotation {
        var b = self
        for a in 0..<3 where lower[a] != upper[a] {
            b.lower[a] = (lower[a] + 0.5).rounded() - 0.5
            b.upper[a] = (upper[a] + 0.5).rounded() - 0.5
        }
        return b
    }

    // MARK: Handles

    /// The 8 in-plane handles of the box seen across padded `axis` (4
    /// corners, 4 edge midpoints), at the box's position on that axis.
    public func handles(acrossAxis axis: Int) -> [(handle: BoxHandle, position: SIMD3<Double>)] {
        let others = [0, 1, 2].filter { $0 != axis }
        let p = others[0], q = others[1]
        var out: [(BoxHandle, SIMD3<Double>)] = []
        for sp in [-1, 0, 1] {
            for sq in [-1, 0, 1] where !(sp == 0 && sq == 0) {
                var sides = SIMD3<Int>.zero
                sides[p] = sp
                sides[q] = sq
                var pos = center
                pos[axis] = lower[axis]
                if sp != 0 { pos[p] = sp < 0 ? lower[p] : upper[p] }
                if sq != 0 { pos[q] = sq < 0 ? lower[q] : upper[q] }
                out.append((BoxHandle(sides: sides), pos))
            }
        }
        return out
    }

    /// The box with a handle dragged to `point` (same space): each edge the
    /// handle holds moves to the point's coordinate on that axis; edges that
    /// cross are swapped.
    public func dragging(_ handle: BoxHandle, to point: SIMD3<Double>) -> BoxAnnotation {
        var b = self
        for a in 0..<3 {
            if handle.sides[a] < 0 { b.lower[a] = point[a] }
            if handle.sides[a] > 0 { b.upper[a] = point[a] }
        }
        return b.normalized()
    }

    // MARK: Creating from a drag

    /// A box from a rectangle dragged on a slice view, in the index space of
    /// `geometry`.
    ///
    /// The slice axis is the grid axis nearest to the view's normal, and the
    /// slice the one holding `start`. Without `depth`, the result is a 2-D
    /// box on that slice (degenerate slice axis, `sliceIndex` set); with
    /// `depth` (a range of slices), a 3-D box through them. With
    /// `snapToVoxels`, the in-plane edges enclose the voxels holding both
    /// corners; otherwise they are the corners themselves. The box is clipped
    /// to the volume.
    public static func fromDrag(from start: SIMD3<Double>, to end: SIMD3<Double>, planeNormal: SIMD3<Double>,
                                geometry: GridGeometry, classID: UInt16, depth: ClosedRange<Int>? = nil,
                                snapToVoxels: Bool = true) -> BoxAnnotation {
        let axis = geometry.nearestAxis(to: planeNormal)
        let n = geometry.paddedShape
        let a = geometry.index(fromWorld: start), b = geometry.index(fromWorld: end)
        var lower = SIMD3<Double>.zero, upper = SIMD3<Double>.zero
        for ax in 0..<3 where ax != axis {
            var lo = min(a[ax], b[ax]), hi = max(a[ax], b[ax])
            if snapToVoxels {
                lo = (lo + 0.5).rounded(.down) - 0.5
                hi = (hi + 0.5).rounded(.down) + 0.5
            }
            lower[ax] = max(-0.5, min(Double(n[ax]) - 0.5, lo))
            upper[ax] = max(-0.5, min(Double(n[ax]) - 0.5, hi))
        }
        let slice = max(0, min(n[axis] - 1, Int((a[axis] + 0.5).rounded(.down))))
        if let depth {
            let lo = max(0, depth.lowerBound), hi = min(n[axis] - 1, depth.upperBound)
            lower[axis] = Double(lo) - 0.5
            upper[axis] = Double(hi) + 0.5
            return BoxAnnotation(lower: lower, upper: upper, classID: classID)
        }
        lower[axis] = Double(slice)
        upper[axis] = Double(slice)
        return BoxAnnotation(lower: lower, upper: upper, classID: classID, sliceIndex: slice)
    }
}

/// Which edges of a box a handle moves: per padded axis, −1 the lower edge,
/// +1 the upper edge, 0 neither.
public struct BoxHandle: Sendable, Hashable {
    public var sides: SIMD3<Int>

    public init(sides: SIMD3<Int>) { self.sides = sides }

    public var isCorner: Bool { (0..<3).filter { sides[$0] != 0 }.count >= 2 }
}

/// A `boxes` annotation: boxes in one space, of spatial rank `rank`.
public struct BoxAnnotationSet: Sendable, Hashable {
    public var space: AnnotationSpace
    /// `S`, the number of spatial axes stored per box (2 or 3).
    public var rank: Int
    public var boxes: [BoxAnnotation]

    public init(space: AnnotationSpace = .index, rank: Int = 3, boxes: [BoxAnnotation] = []) {
        self.space = space
        self.rank = rank
        self.boxes = boxes
    }

    /// The distinct classes of the boxes, ascending.
    public var classIDs: [UInt16] { Array(Set(boxes.map(\.classID))).sorted() }

    /// The datasets medh5 stores (spec §8.2): `boxes (N, S, 2) float32`,
    /// `class_ids (N,) uint16`, and, when every box has one, `instance_ids
    /// (N,) uint64` and `scores (N,) float32`; `slice_index (N,) int32` when
    /// any box lies on a slice (−1 for the others); the `attributes` string
    /// column when any box has attributes (`{}` for the others).
    public func arrays() -> GeometricArrays {
        let n = boxes.count, s = rank
        var flat = [Float]()
        flat.reserveCapacity(n * s * 2)
        for b in boxes {
            let lo = StoredCoordinates.stored(b.lower, rank: s, space: space)
            let hi = StoredCoordinates.stored(b.upper, rank: s, space: space)
            for a in 0..<s {
                flat.append(Float(lo[a]))
                flat.append(Float(hi[a]))
            }
        }
        var arrays = [
            AnnotationArray(name: "boxes", shape: [n, s, 2], values: .float32(flat)),
            AnnotationArray(name: "class_ids", shape: [n], values: .uint16(boxes.map(\.classID))),
        ]
        if n > 0, boxes.allSatisfy({ $0.instanceID != nil }) {
            arrays.append(AnnotationArray(name: "instance_ids", shape: [n], values: .uint64(boxes.map { $0.instanceID! })))
        }
        if n > 0, boxes.allSatisfy({ $0.score != nil }) {
            arrays.append(AnnotationArray(name: "scores", shape: [n], values: .float32(boxes.map { $0.score! })))
        }
        if boxes.contains(where: { $0.sliceIndex != nil }) {
            arrays.append(AnnotationArray(name: "slice_index", shape: [n],
                                          values: .int32(boxes.map { Int32($0.sliceIndex ?? -1) })))
        }
        var strings: [String: [String]] = [:]
        if boxes.contains(where: { $0.attributes != nil }) {
            strings["attributes"] = boxes.map { $0.attributes ?? "{}" }
        }
        return GeometricArrays(kind: "boxes", space: space, arrays: arrays, strings: strings)
    }

    /// Reads boxes from their datasets.
    /// - Throws: `GeometryArrayError` when a dataset is missing or shapes disagree.
    public init(arrays g: GeometricArrays) throws {
        let boxes = try g.require("boxes")
        guard boxes.shape.count == 3, boxes.shape[2] == 2, boxes.shape[1] == 2 || boxes.shape[1] == 3 else {
            throw GeometryArrayError("E405", "boxes has shape \(boxes.shape); it must be (N, S, 2) with S = 2 or 3")
        }
        let n = boxes.shape[0], s = boxes.shape[1]
        let v = boxes.doubles
        let classes = try g.requireIntegers("class_ids")
        guard classes.count == n else { throw GeometryArrayError("E405", "class_ids has \(classes.count) entries for \(n) boxes") }
        let instances = try g.optionalIDs("instance_ids", count: n)
        let scores = try g.optionalDoubles("scores", count: n)
        let planes = try g.optionalIntegers("slice_index", count: n)
        let attributes = try g.optionalStrings("attributes", count: n)
        space = g.space
        rank = s
        var out: [BoxAnnotation] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let lo = stride(from: i * s * 2, to: (i + 1) * s * 2, by: 2).map { v[$0] }
            let hi = stride(from: i * s * 2 + 1, to: (i + 1) * s * 2, by: 2).map { v[$0] }
            var lower = StoredCoordinates.padded(lo[...], rank: s, space: g.space)
            var upper = StoredCoordinates.padded(hi[...], rank: s, space: g.space)
            if s == 2 && g.space == .index {
                // The padding axis of a 2-D grid: its one slice.
                lower.x = -0.5
                upper.x = 0.5
            }
            var box = BoxAnnotation(lower: lower, upper: upper, classID: UInt16(clamping: classes[i]))
            box.instanceID = instances.map { $0[i] }
            box.score = scores.map { Float($0[i]) }
            box.attributes = attributes.map { $0[i] }
            if let planes, box.degenerateAxis != nil { box.sliceIndex = Int(planes[i]) }
            out.append(box)
        }
        self.boxes = out
    }

    /// Checks the boxes as the spec does: finite bounds with `lo ≤ hi`
    /// (E406), class ids that can be classes (E402), and, given the grid's
    /// padded shape (index space), slice indices inside the grid (E405).
    public func validate(gridShape: SIMD3<Int>? = nil) -> [GeometryIssue] {
        var issues: [GeometryIssue] = []
        for (i, b) in boxes.enumerated() {
            if !GeometryChecks.finite(b.lower) || !GeometryChecks.finite(b.upper) {
                issues.append(GeometryIssue(code: "E406", message: "box \(i) has a bound that is not finite", item: i))
            } else if any(b.lower .> b.upper) {
                issues.append(GeometryIssue(code: "E406", message: "box \(i) has lo > hi", item: i))
            }
            if b.classID == ClassID.background || b.classID == ClassID.ignore {
                issues.append(GeometryIssue(code: "E402", message: "box \(i) has the reserved class id \(b.classID)", item: i))
            }
            if let k = b.sliceIndex, let a = b.degenerateAxis, let n = gridShape, space == .index {
                if k < 0 || k >= n[a] {
                    issues.append(GeometryIssue(code: "E405", message: "box \(i) names slice \(k) on an axis \(n[a]) voxels deep", item: i))
                }
            }
        }
        return issues
    }
}
