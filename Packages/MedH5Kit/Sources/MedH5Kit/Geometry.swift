import Foundation
import MedH5Core
import simd

/// A geometric or classification annotation (spec §8, §9; polylines 1.2 §3)
/// with its arrays, in its own coordinates and in world.
///
/// Coordinates are padded to three axes the way `GridGeometry` pads a grid:
/// an index point `(i0, i1)` of a 2-D grid is `(0, i0, i1)`, a world point
/// `(x, y)` is `(x, y, 0)`. Own coordinates are in the annotation's `space`:
/// index coordinates of its grid (integers at voxel centres), or world.
public enum GeometricAnnotation: Sendable {
    case boxes(Boxes)
    case orientedBoxes(OrientedBoxes)
    case keypoints(Keypoints)
    case points(PointSet)
    case contours(Contours)
    case polylines(Polylines)
    case mesh(Mesh)
    case classification(Classification)

    /// What every geometric annotation states.
    public struct Header: Sendable, Hashable {
        public var annotation: String
        public var kind: String
        public var grid: String?
        public var frameUID: String?
        /// `index` or `world`.
        public var space: String
        public var classIDs: [Int]
        public var annotatedClassIDs: [Int]
        /// Objects: boxes, polygons, curves, faces…
        public var items: Int
        /// Per-object free-form attributes, when stored.
        public var attributes: [JSONValue]?
        /// Why world coordinates could not be given (an index annotation
        /// without a grid), when they could not.
        public var worldError: String?

        public var isWorld: Bool { space == "world" }
    }

    /// Axis-aligned boxes at voxel edges (§8.1, §8.2).
    public struct Boxes: Sendable {
        public var header: Header
        /// `[lo, hi]` per spatial axis, per box, in the annotation's space.
        public var boxes: [[AxisInterval]]
        public var classIDs: [Int]
        public var instanceIDs: [UInt64]?
        public var scores: [Float]?
        /// The plane a 2-D box was drawn on.
        public var sliceIndex: [Int]?
        /// Every corner of each box in world (`2^S` per box, the first axis
        /// varying slowest: corner 0 holds every lower bound).
        public var worldCorners: [[SIMD3<Double>]]
    }

    /// Oriented boxes: centre, full edge lengths, rotation (§8.3).
    public struct OrientedBoxes: Sendable {
        public var header: Header
        public var centers: [[Double]]
        public var sizes: [[Double]]
        /// `S × S` rotation per box, row-major; column `k` is local axis `k`.
        public var rotations: [[[Double]]]
        public var classIDs: [Int]
        public var instanceIDs: [UInt64]?
        public var scores: [Float]?
        public var corners: [[SIMD3<Double>]]
        public var worldCorners: [[SIMD3<Double>]]
    }

    /// Structured keypoint sets (§8.4).
    public struct Keypoints: Sendable {
        public var header: Header
        /// `N` sets of `K` points, in the annotation's space.
        public var points: [[SIMD3<Double>]]
        public var worldPoints: [[SIMD3<Double>]]
        /// The class of each of the `K` slots.
        public var keypointClassIDs: [Int]
        /// `0` unlabelled, `1` occluded, `2` visible, per set and slot.
        public var visibility: [[UInt8]]
        /// The class of each set.
        public var classIDs: [Int]
        public var instanceIDs: [UInt64]?
        public var scores: [Float]?
        public var skeleton: String?
        /// Edges between keypoint class ids.
        public var skeletonEdges: [[Int]]
    }

    /// A point set: landmarks, seeds, half a correspondence (§8.5).
    public struct PointSet: Sendable {
        public var header: Header
        public var points: [SIMD3<Double>]
        public var worldPoints: [SIMD3<Double>]
        public var classIDs: [Int]?
        public var instanceIDs: [UInt64]?
        public var weights: [Double]?
        public var names: [String]?
        /// The point set holding the same landmarks in another frame.
        public var correspondence: String?
    }

    /// One planar polygon of a contours annotation.
    public struct Polygon: Sendable {
        public var classID: Int
        /// `(axis, index)` of the plane it lies in; axis `-1` for none.
        public var plane: (axis: Int, index: Int)
        /// `true` for a hole: its depth among its class's polygons in its
        /// plane is odd (§8.6).
        public var isHole: Bool
        public var vertices: [SIMD3<Double>]
        public var worldVertices: [SIMD3<Double>]
    }

    /// Planar polygons (§8.6).
    public struct Contours: Sendable {
        public var header: Header
        public var polygons: [Polygon]
    }

    /// One open curve (1.2 §3).
    public struct Polyline: Sendable {
        public var classID: Int
        public var plane: (axis: Int, index: Int)
        public var instanceID: UInt64?
        public var vertices: [SIMD3<Double>]
        public var worldVertices: [SIMD3<Double>]
    }

    /// Open curves: centrelines, catheter paths, needle tracks (1.2 §3).
    public struct Polylines: Sendable {
        public var header: Header
        public var polylines: [Polyline]
    }

    /// A triangle surface (§8.7).
    public struct Mesh: Sendable {
        public struct Submesh: Sendable, Hashable {
            /// The faces it holds.
            public var faces: Range<Int>
            public var classID: Int?
        }

        public var header: Header
        public var vertices: [SIMD3<Double>]
        public var worldVertices: [SIMD3<Double>]
        public var faces: [SIMD3<Int32>]
        public var normals: [SIMD3<Double>]?
        public var worldNormals: [SIMD3<Double>]?
        public var vertexClassIDs: [Int]?
        public var submeshes: [Submesh]
    }

    /// Label assertions about the sample, a visit, a grid, a region, an
    /// instance or a slice (§9).
    public struct Classification: Sendable {
        public struct Assertion: Sendable, Hashable {
            public var classID: Int
            public var key: String
            /// In `[0, 1]`: `1` a hard positive, `0` an explicit negative.
            public var value: Double
            public var scopeID: Int?
            public var scheme: String?
            public var schemeValue: String?
        }

        public var annotation: String
        public var classIDs: [Int]
        public var annotatedClassIDs: [Int]
        public var scope: String
        public var multilabel: Bool
        public var scopeIDs: [Int]?
        /// Whether it describes a change between the visits it names.
        public var isChangeLabel: Bool
        public var comparedTimepoints: [String]
        public var assertions: [Assertion]
        /// Class key → value.
        public var labels: [String: Double]
        public var positives: [String]
    }

    /// The annotation's id.
    public var annotation: String {
        switch self {
        case .boxes(let a): return a.header.annotation
        case .orientedBoxes(let a): return a.header.annotation
        case .keypoints(let a): return a.header.annotation
        case .points(let a): return a.header.annotation
        case .contours(let a): return a.header.annotation
        case .polylines(let a): return a.header.annotation
        case .mesh(let a): return a.header.annotation
        case .classification(let a): return a.annotation
        }
    }
}

// MARK: - Reading a bundle

/// `S`-coordinate rows padded to three axes: an index point the way a 2-D
/// grid pads (`(0, i0, i1)`), a world point with `z = 0`.
func points3(_ values: [Double], rank: Int, index: Bool) -> [SIMD3<Double>] {
    guard rank > 0 else { return [] }
    return stride(from: 0, to: values.count - rank + 1, by: rank).map { start in
        let row = Array(values[start..<start + rank])
        switch rank {
        case 1: return index ? SIMD3(0, 0, row[0]) : SIMD3(row[0], 0, 0)
        case 2: return index ? SIMD3(0, row[0], row[1]) : SIMD3(row[0], row[1], 0)
        default: return SIMD3(row[0], row[1], row[2])
        }
    }
}

extension GeometricAnnotation {
    init(bundle: BundleContents) throws {
        let h = bundle.header
        let kind = h["kind"]?.stringValue ?? ""
        let ids = { (v: JSONValue?) -> [Int] in v?.arrayValue?.compactMap(\.intValue) ?? [] }
        if kind == "classification" {
            let assertions: [Classification.Assertion] = (h["assertions"]?.arrayValue ?? []).map {
                Classification.Assertion(
                    classID: $0["class_id"]?.intValue ?? 0, key: $0["key"]?.stringValue ?? "",
                    value: $0["value"]?.doubleValue ?? 0, scopeID: $0["scope_id"]?.intValue,
                    scheme: $0["scheme"]?.stringValue, schemeValue: $0["scheme_value"]?.stringValue)
            }
            var labels: [String: Double] = [:]
            for (k, v) in h["labels"]?.objectValue ?? JSONObject() { labels[k] = v.doubleValue }
            self = .classification(Classification(
                annotation: h["annotation"]?.stringValue ?? "", classIDs: ids(h["class_ids"]),
                annotatedClassIDs: ids(h["annotated_class_ids"]), scope: h["scope"]?.stringValue ?? "",
                multilabel: h["multilabel"]?.boolValue ?? false,
                scopeIDs: h["scope_ids"]?.arrayValue?.compactMap(\.intValue),
                isChangeLabel: h["change_label"]?.boolValue ?? false,
                comparedTimepoints: h["compared_timepoints"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                assertions: assertions, labels: labels,
                positives: h["positives"]?.arrayValue?.compactMap(\.stringValue) ?? []))
            return
        }
        let header = Header(
            annotation: h["annotation"]?.stringValue ?? "", kind: kind, grid: h["grid"]?.stringValue,
            frameUID: h["frame_uid"]?.stringValue, space: h["space"]?.stringValue ?? "index",
            classIDs: ids(h["class_ids"]), annotatedClassIDs: ids(h["annotated_class_ids"]),
            items: h["items"]?.intValue ?? 0, attributes: h["attributes"]?.arrayValue,
            worldError: h["world_error"]?.stringValue)
        let index = !header.isWorld
        func optional(_ name: String) -> BundleArray? { bundle.arrays[name] }
        func rows3(_ name: String, own: Bool) throws -> [SIMD3<Double>] {
            let a = try bundle.array(name)
            return points3(a.doubles, rank: a.shape.last ?? 3, index: own && index)
        }
        func world3(_ name: String) -> [SIMD3<Double>] {
            guard let a = bundle.arrays[name] else { return [] }
            return points3(a.doubles, rank: a.shape.last ?? 3, index: false)
        }
        func grouped(_ flat: [SIMD3<Double>], _ size: Int) -> [[SIMD3<Double>]] {
            guard size > 0 else { return [] }
            return stride(from: 0, to: flat.count, by: size).map { Array(flat[$0..<min(flat.count, $0 + size)]) }
        }
        let classIDs = optional("class_ids")?.ints
        let instanceIDs = optional("instance_ids").map { a in (0..<a.data.count).map { UInt64(a.data.value(at: $0)) } }
        let scores = optional("scores").map { a in a.doubles.map(Float.init) }
        switch kind {
        case "boxes":
            let a = try bundle.array("boxes")
            let s = a.shape.count == 3 ? a.shape[1] : 0
            let flat = a.doubles
            let boxes: [[AxisInterval]] = (0..<(a.shape.first ?? 0)).map { i in
                (0..<s).map { k in AxisInterval(flat[(i * s + k) * 2], flat[(i * s + k) * 2 + 1]) }
            }
            self = .boxes(Boxes(
                header: header, boxes: boxes, classIDs: classIDs ?? [], instanceIDs: instanceIDs, scores: scores,
                sliceIndex: optional("slice_index")?.ints, worldCorners: grouped(world3("world_corners"), 1 << s)))
        case "obb":
            let centers = try bundle.array("centers")
            let s = centers.shape.last ?? 3
            let n = centers.shape.first ?? 0
            let rows = { (a: BundleArray) in stride(from: 0, to: a.doubles.count, by: max(1, s)).map { Array(a.doubles[$0..<$0 + s]) } }
            let r = try bundle.array("rotations").doubles
            let rotations: [[[Double]]] = (0..<n).map { i in (0..<s).map { row in Array(r[(i * s + row) * s..<(i * s + row) * s + s]) } }
            self = .orientedBoxes(OrientedBoxes(
                header: header, centers: rows(centers), sizes: rows(try bundle.array("sizes")), rotations: rotations,
                classIDs: classIDs ?? [], instanceIDs: instanceIDs, scores: scores,
                corners: grouped(try rows3("corners", own: true), 1 << s),
                worldCorners: grouped(world3("world_corners"), 1 << s)))
        case "keypoints":
            let p = try bundle.array("points")
            let k = p.shape.count >= 2 ? p.shape[1] : 0
            let visibility = try bundle.array("visibility")
            let vis = (0..<visibility.data.count).map { UInt8(visibility.data.value(at: $0)) }
            self = .keypoints(Keypoints(
                header: header, points: grouped(try rows3("points", own: true), k),
                worldPoints: grouped(world3("world_points"), k),
                keypointClassIDs: optional("keypoint_class_ids")?.ints ?? [],
                visibility: k == 0 ? [] : stride(from: 0, to: vis.count, by: k).map { Array(vis[$0..<$0 + k]) },
                classIDs: classIDs ?? [], instanceIDs: instanceIDs, scores: scores,
                skeleton: h["skeleton"]?.stringValue,
                skeletonEdges: h["skeleton_edges"]?.arrayValue?.map { $0.arrayValue?.compactMap(\.intValue) ?? [] } ?? []))
        case "points":
            self = .points(PointSet(
                header: header, points: try rows3("points", own: true), worldPoints: world3("world_points"),
                classIDs: classIDs, instanceIDs: instanceIDs, weights: optional("weights")?.doubles,
                names: h["names"]?.arrayValue?.compactMap(\.stringValue),
                correspondence: h["correspondence"]?.stringValue))
        case "contours", "polylines":
            let prefix = kind == "contours" ? "contour" : "polyline"
            let vertices = try rows3("vertices", own: true)
            let world = world3("world_vertices")
            let offsets = try bundle.array("\(prefix)_offsets").ints
            let classes = try bundle.array("\(prefix)_class_ids").ints
            let planes = optional("\(prefix)_plane")?.ints ?? []
            let roles = optional("contour_role")?.ints ?? []
            var polygons: [Polygon] = []
            var lines: [Polyline] = []
            for i in 0..<max(0, offsets.count - 1) {
                let range = offsets[i]..<min(offsets[i + 1], vertices.count)
                let plane = planes.count >= 2 * (i + 1) ? (planes[2 * i], planes[2 * i + 1]) : (-1, 0)
                let w = world.count == vertices.count ? Array(world[range]) : []
                if kind == "contours" {
                    polygons.append(Polygon(classID: classes[i], plane: plane, isHole: roles.count > i && roles[i] == 1,
                                            vertices: Array(vertices[range]), worldVertices: w))
                } else {
                    lines.append(Polyline(classID: classes[i], plane: plane, instanceID: instanceIDs?[i],
                                          vertices: Array(vertices[range]), worldVertices: w))
                }
            }
            self = kind == "contours" ? .contours(Contours(header: header, polygons: polygons))
                : .polylines(Polylines(header: header, polylines: lines))
        case "mesh":
            let faces = try bundle.array("faces").ints
            let triangles = stride(from: 0, to: faces.count - 2, by: 3).map {
                SIMD3<Int32>(Int32(faces[$0]), Int32(faces[$0 + 1]), Int32(faces[$0 + 2]))
            }
            let offsets = optional("mesh_offsets")?.ints ?? [0, triangles.count]
            let meshClasses = optional("mesh_class_ids")?.ints
            let submeshes = (0..<max(0, offsets.count - 1)).map {
                Mesh.Submesh(faces: offsets[$0]..<offsets[$0 + 1], classID: meshClasses?[$0])
            }
            self = .mesh(Mesh(
                header: header, vertices: try rows3("vertices", own: true), worldVertices: world3("world_vertices"),
                faces: triangles, normals: optional("normals").map { points3($0.doubles, rank: 3, index: false) },
                worldNormals: optional("world_normals").map { points3($0.doubles, rank: 3, index: false) },
                vertexClassIDs: optional("vertex_class_ids")?.ints, submeshes: submeshes))
        default:
            throw MedH5Error(status: .failed, kind: "unsupported", message: "no geometry for annotation kind \(kind)")
        }
    }
}

// MARK: - Transforms

/// A stored transform and its parameters (§10).
public struct StoredTransform: @unchecked Sendable {
    public var info: TransformInfo
    /// An affine's homogeneous matrix (a 2-D affine embedded in 3-D).
    public var matrix: simd_double4x4?
    /// The `(S+1) × (S+1)` matrix as stored, row-major.
    public var storedMatrix: [[Double]]?
    /// A displacement field, `(S, *spatial)` on its field grid, as stored.
    public var field: VolumeData?
    /// A B-spline's control points, `(S, *cp_shape)`.
    public var controlPoints: VolumeData?
}

/// The transform the engine resolves between two keys (`x_to = T(x_from)`,
/// spec §10.2).
public struct ResolvedTransform: @unchecked Sendable {
    /// How a point of the `from` side maps to the `to` side.
    public enum Mapping {
        /// World → world.
        case matrix(simd_double4x4)
        /// `T(x) - x`, in world units, `(n0, n1, n2, 3)` `float32` at the
        /// voxel centres of `grid` (spatial only, subsampled as asked).
        case field(displacement: VolumeData, grid: GridGeometry)
        /// Not linear, and no field grid was given to sample it on.
        case unsampled
    }

    /// Whether the two keys share a frame: the mapping is the identity.
    public var isIdentity: Bool
    public var kind: String?
    public var fromFrame: String?
    public var toFrame: String?
    public var units: String?
    /// The stored transforms applied, in order, and whether each is inverted.
    public var path: [String]
    public var inverted: [Bool]
    public var mapping: Mapping

    /// The matrix, when the mapping is linear.
    public var matrix: simd_double4x4? {
        if case .matrix(let m) = mapping { return m }
        return nil
    }
}
