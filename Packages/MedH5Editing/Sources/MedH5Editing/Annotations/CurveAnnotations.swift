import Foundation
import simd
import MedH5Core

// MARK: - Polylines (medh5 1.2 §3)

/// An open curve: ordered vertices, each joined to the next.
public struct Polyline: Sendable, Hashable {
    /// Padded positions in the set's space.
    public var vertices: [SIMD3<Double>]
    public var classID: UInt16
    /// The grid plane a planar polyline lies in, or nil.
    public var plane: GridPlane?
    public var instanceID: UInt64?

    public init(vertices: [SIMD3<Double>], classID: UInt16, plane: GridPlane? = nil, instanceID: UInt64? = nil) {
        self.vertices = vertices
        self.classID = classID
        self.plane = plane
        self.instanceID = instanceID
    }

    /// Length in world units; `geometry` converts index-space vertices.
    public func length(space: AnnotationSpace, geometry: GridGeometry? = nil) -> Double {
        let w = worldVertices(vertices, space: space, geometry: geometry)
        return zip(w, w.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }
}

/// A `polylines` annotation (format 1.2).
public struct PolylineAnnotationSet: Sendable, Hashable {
    public var space: AnnotationSpace
    public var rank: Int
    public var polylines: [Polyline]

    public init(space: AnnotationSpace = .world, rank: Int = 3, polylines: [Polyline] = []) {
        self.space = space
        self.rank = rank
        self.polylines = polylines
    }

    /// The datasets: `vertices (V, S) float32`, `polyline_offsets (M+1,)
    /// int64`, `polyline_class_ids (M,) uint16`; `polyline_plane (M, 2)
    /// int32` when any polyline is planar (`(−1, 0)` for the others);
    /// `instance_ids (M,) uint64` when every polyline has one.
    public func arrays() -> GeometricArrays {
        let (vertices, offsets) = flatten(polylines.map(\.vertices), rank: rank, space: space)
        let m = polylines.count
        var arrays = [
            AnnotationArray(name: "vertices", shape: [offsets.last.map(Int.init) ?? 0, rank], values: .float32(vertices)),
            AnnotationArray(name: "polyline_offsets", shape: [m + 1], values: .int64(offsets)),
            AnnotationArray(name: "polyline_class_ids", shape: [m], values: .uint16(polylines.map(\.classID))),
        ]
        if polylines.contains(where: { $0.plane != nil }) {
            arrays.append(AnnotationArray(name: "polyline_plane", shape: [m, 2],
                                          values: .int32(StoredCoordinates.encodePlanes(polylines.map(\.plane), rank: rank))))
        }
        if m > 0, polylines.allSatisfy({ $0.instanceID != nil }) {
            arrays.append(AnnotationArray(name: "instance_ids", shape: [m], values: .uint64(polylines.map { $0.instanceID! })))
        }
        return GeometricArrays(kind: "polylines", space: space, arrays: arrays)
    }

    public init(arrays g: GeometricArrays) throws {
        let (s, groups) = try unflatten(g, offsetsName: "polyline_offsets")
        let m = groups.count
        let classes = try g.requireIntegers("polyline_class_ids")
        guard classes.count == m else { throw GeometryArrayError("E405", "polyline_class_ids has \(classes.count) entries for \(m) polylines") }
        var planes: [GridPlane?] = Array(repeating: nil, count: m)
        if let p = g["polyline_plane"] {
            guard p.shape == [m, 2], let flat = p.integers else {
                throw GeometryArrayError("E405", "polyline_plane has shape \(p.shape); it must be (\(m), 2)")
            }
            planes = StoredCoordinates.decodePlanes(flat, count: m, rank: s)
        }
        let ids = try g.optionalIDs("instance_ids", count: m)
        space = g.space
        rank = s
        polylines = (0..<m).map { i in
            Polyline(vertices: groups[i], classID: UInt16(clamping: classes[i]), plane: planes[i],
                     instanceID: ids.map { $0[i] })
        }
    }

    public func converted(to target: AnnotationSpace, geometry: GridGeometry) -> PolylineAnnotationSet {
        var out = self
        out.space = target
        out.polylines = polylines.map { p in
            var q = p
            q.vertices = p.vertices.map { StoredCoordinates.convert($0, from: space, to: target, geometry: geometry) }
            return q
        }
        return out
    }

    /// At least two vertices each (E404), finite vertices (E406), class ids
    /// that can be classes (E402).
    public func validate() -> [GeometryIssue] {
        var issues: [GeometryIssue] = []
        for (i, p) in polylines.enumerated() {
            if p.vertices.count < 2 {
                issues.append(GeometryIssue(code: "E404", message: "polyline \(i) has \(p.vertices.count) vertex(es); a polyline has at least 2", item: i))
            }
            if !p.vertices.allSatisfy(GeometryChecks.finite) {
                issues.append(GeometryIssue(code: "E406", message: "polyline \(i) has a vertex that is not finite", item: i))
            }
            if p.classID == ClassID.background || p.classID == ClassID.ignore {
                issues.append(GeometryIssue(code: "E402", message: "polyline \(i) has the reserved class id \(p.classID)", item: i))
            }
        }
        return issues
    }

    /// Checks stored arrays before decoding: offsets (E408), column lengths
    /// (E405), required datasets (E410).
    public static func validate(arrays g: GeometricArrays) -> [GeometryIssue] {
        validateCurveArrays(g, offsetsName: "polyline_offsets", classesName: "polyline_class_ids",
                            planeName: "polyline_plane", roleName: nil, minimumVertices: 2, noun: "polyline")
    }
}

// MARK: - Contours (spec §8.6)

/// Whether a contour bounds its region from outside or is a hole in it.
public enum ContourRole: UInt8, Sendable, Hashable, Codable {
    case outer = 0
    case hole = 1
}

/// A closed planar polygon of one class.
public struct Contour: Sendable, Hashable {
    /// Padded positions in the set's space; the last vertex joins the first.
    public var vertices: [SIMD3<Double>]
    public var classID: UInt16
    /// The grid plane the polygon lies in; nil for an out-of-plane polygon
    /// (stored as axis −1), which takes part in no combination.
    public var plane: GridPlane?
    public var role: ContourRole

    public init(vertices: [SIMD3<Double>], classID: UInt16, plane: GridPlane?, role: ContourRole = .outer) {
        self.vertices = vertices
        self.classID = classID
        self.plane = plane
        self.role = role
    }

    /// Enclosed area in world units² (the polygon's vector area).
    public func area(space: AnnotationSpace, geometry: GridGeometry? = nil) -> Double {
        let w = worldVertices(vertices, space: space, geometry: geometry)
        guard w.count >= 3 else { return 0 }
        var cross = SIMD3<Double>.zero
        for i in 0..<w.count { cross += simd_cross(w[i], w[(i + 1) % w.count]) }
        return simd_length(cross) / 2
    }

    /// Perimeter in world units.
    public func perimeter(space: AnnotationSpace, geometry: GridGeometry? = nil) -> Double {
        let w = worldVertices(vertices, space: space, geometry: geometry)
        guard w.count >= 2 else { return 0 }
        return (0..<w.count).reduce(0) { $0 + simd_distance(w[$1], w[($1 + 1) % w.count]) }
    }
}

/// A `contours` annotation.
public struct ContourAnnotationSet: Sendable, Hashable {
    public var space: AnnotationSpace
    public var rank: Int
    public var contours: [Contour]

    public init(space: AnnotationSpace = .index, rank: Int = 3, contours: [Contour] = []) {
        self.space = space
        self.rank = rank
        self.contours = contours
    }

    /// The datasets: `vertices (V, S) float32`, `contour_offsets (M+1,)
    /// int64`, `contour_class_ids (M,) uint16`, `contour_plane (M, 2) int32`
    /// (`(−1, 0)` out of plane), `contour_role (M,) uint8`.
    public func arrays() -> GeometricArrays {
        let (vertices, offsets) = flatten(contours.map(\.vertices), rank: rank, space: space)
        let m = contours.count
        return GeometricArrays(kind: "contours", space: space, arrays: [
            AnnotationArray(name: "vertices", shape: [offsets.last.map(Int.init) ?? 0, rank], values: .float32(vertices)),
            AnnotationArray(name: "contour_offsets", shape: [m + 1], values: .int64(offsets)),
            AnnotationArray(name: "contour_class_ids", shape: [m], values: .uint16(contours.map(\.classID))),
            AnnotationArray(name: "contour_plane", shape: [m, 2],
                            values: .int32(StoredCoordinates.encodePlanes(contours.map(\.plane), rank: rank))),
            AnnotationArray(name: "contour_role", shape: [m], values: .uint8(contours.map(\.role.rawValue))),
        ])
    }

    public init(arrays g: GeometricArrays) throws {
        let (s, groups) = try unflatten(g, offsetsName: "contour_offsets")
        let m = groups.count
        let classes = try g.requireIntegers("contour_class_ids")
        guard classes.count == m else { throw GeometryArrayError("E405", "contour_class_ids has \(classes.count) entries for \(m) contours") }
        var planes: [GridPlane?] = Array(repeating: nil, count: m)
        if let p = g["contour_plane"] {
            guard p.shape == [m, 2], let flat = p.integers else {
                throw GeometryArrayError("E405", "contour_plane has shape \(p.shape); it must be (\(m), 2)")
            }
            planes = StoredCoordinates.decodePlanes(flat, count: m, rank: s)
        }
        var roles = [ContourRole](repeating: .outer, count: m)
        if let r = try g.optionalIntegers("contour_role", count: m) {
            for i in 0..<m {
                guard let role = ContourRole(rawValue: UInt8(clamping: r[i])), r[i] >= 0 else {
                    throw GeometryArrayError("E404", "contour_role \(r[i]) is not 0 (outer) or 1 (hole)", item: i)
                }
                roles[i] = role
            }
        }
        space = g.space
        rank = s
        contours = (0..<m).map { i in
            Contour(vertices: groups[i], classID: UInt16(clamping: classes[i]), plane: planes[i], role: roles[i])
        }
    }

    public func converted(to target: AnnotationSpace, geometry: GridGeometry) -> ContourAnnotationSet {
        var out = self
        out.space = target
        out.contours = contours.map { c in
            var q = c
            q.vertices = c.vertices.map { StoredCoordinates.convert($0, from: space, to: target, geometry: geometry) }
            return q
        }
        return out
    }

    /// Each contour's role as spec §8.6 defines it: the parity of its depth,
    /// the number of the class's other polygons in its plane that enclose it
    /// (every vertex inside). Out-of-plane contours keep their stored role.
    /// World-space contours need `geometry` (their planes are grid planes).
    public func rolesFromDepth(geometry: GridGeometry? = nil) -> [ContourRole] {
        let idx: [[SIMD3<Double>]] = contours.map { c in
            space == .index ? c.vertices : (geometry.map { g in c.vertices.map { g.index(fromWorld: $0) } } ?? c.vertices)
        }
        return contours.indices.map { i in
            let c = contours[i]
            guard let plane = c.plane, space == .index || geometry != nil else { return c.role }
            let axes = [0, 1, 2].filter { $0 != plane.axis }
            func flat(_ p: SIMD3<Double>) -> SIMD2<Double> { SIMD2(p[axes[0]], p[axes[1]]) }
            var depth = 0
            for j in contours.indices where j != i && contours[j].classID == c.classID && contours[j].plane == plane {
                let poly = idx[j].map(flat)
                if idx[i].allSatisfy({ pointInPolygon(flat($0), poly) }) { depth += 1 }
            }
            return depth % 2 == 0 ? .outer : .hole
        }
    }

    /// At least three vertices each (E404), finite vertices (E406), class ids
    /// that can be classes (E402), roles that agree with depth (W919).
    public func validate(geometry: GridGeometry? = nil) -> [GeometryIssue] {
        var issues: [GeometryIssue] = []
        for (i, c) in contours.enumerated() {
            if c.vertices.count < 3 {
                issues.append(GeometryIssue(code: "E404", message: "contour \(i) has \(c.vertices.count) vertices; a polygon has at least 3", item: i))
            }
            if !c.vertices.allSatisfy(GeometryChecks.finite) {
                issues.append(GeometryIssue(code: "E406", message: "contour \(i) has a vertex that is not finite", item: i))
            }
            if c.classID == ClassID.background || c.classID == ClassID.ignore {
                issues.append(GeometryIssue(code: "E402", message: "contour \(i) has the reserved class id \(c.classID)", item: i))
            }
        }
        for (i, r) in rolesFromDepth(geometry: geometry).enumerated() where contours[i].plane != nil && r != contours[i].role {
            issues.append(GeometryIssue(code: "W919", message: "contour \(i) is stored as \(contours[i].role) but its depth makes it \(r)", item: i))
        }
        return issues
    }

    public static func validate(arrays g: GeometricArrays) -> [GeometryIssue] {
        validateCurveArrays(g, offsetsName: "contour_offsets", classesName: "contour_class_ids",
                            planeName: "contour_plane", roleName: "contour_role", minimumVertices: 3, noun: "contour")
    }
}

// MARK: - Shared

/// Even–odd point-in-polygon test.
func pointInPolygon(_ p: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
    guard poly.count >= 3 else { return false }
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if (a.y > p.y) != (b.y > p.y) {
            let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
            if p.x < x { inside.toggle() }
        }
        j = i
    }
    return inside
}

func worldVertices(_ v: [SIMD3<Double>], space: AnnotationSpace, geometry: GridGeometry?) -> [SIMD3<Double>] {
    guard space == .index, let g = geometry else { return v }
    return v.map { g.world(fromIndex: $0) }
}

/// Concatenated vertices and `M + 1` offsets.
func flatten(_ groups: [[SIMD3<Double>]], rank: Int, space: AnnotationSpace) -> ([Float], [Int64]) {
    var vertices: [Float] = []
    var offsets: [Int64] = [0]
    for g in groups {
        for p in g { vertices.append(contentsOf: StoredCoordinates.stored(p, rank: rank, space: space).map(Float.init)) }
        offsets.append(offsets.last! + Int64(g.count))
    }
    return (vertices, offsets)
}

/// Splits `vertices` by the offsets dataset (checked: E408, E405).
func unflatten(_ g: GeometricArrays, offsetsName: String) throws -> (rank: Int, groups: [[SIMD3<Double>]]) {
    let v = try g.require("vertices")
    guard v.shape.count == 2, v.shape[1] == 2 || v.shape[1] == 3 else {
        throw GeometryArrayError("E405", "vertices has shape \(v.shape); it must be (V, S) with S = 2 or 3")
    }
    let count = v.shape[0], s = v.shape[1]
    let offsets = try g.requireIntegers(offsetsName)
    if let issue = GeometryChecks.offsets(offsets, vertexCount: count, kind: offsetsName).first {
        throw GeometryArrayError(issue)
    }
    let flat = v.doubles
    var groups: [[SIMD3<Double>]] = []
    for i in 0..<(offsets.count - 1) {
        let a = Int(offsets[i]), b = Int(offsets[i + 1])
        groups.append((a..<b).map { StoredCoordinates.padded(flat[($0 * s)..<(($0 + 1) * s)], rank: s, space: g.space) })
    }
    return (s, groups)
}

func validateCurveArrays(_ g: GeometricArrays, offsetsName: String, classesName: String, planeName: String,
                         roleName: String?, minimumVertices: Int, noun: String) -> [GeometryIssue] {
    var issues: [GeometryIssue] = []
    guard let v = g["vertices"] else { return [GeometryIssue(code: "E410", message: "the vertices dataset is missing")] }
    guard let o = g[offsetsName]?.integers else { return [GeometryIssue(code: "E410", message: "the \(offsetsName) dataset is missing")] }
    let vertexCount = v.shape.first ?? 0
    issues += GeometryChecks.offsets(o, vertexCount: vertexCount, kind: offsetsName)
    let m = max(0, o.count - 1)
    if let c = g[classesName] {
        if c.count != m { issues.append(GeometryIssue(code: "E405", message: "\(classesName) has \(c.count) entries for \(m) \(noun)s")) }
    } else {
        issues.append(GeometryIssue(code: "E410", message: "the \(classesName) dataset is missing"))
    }
    if let p = g[planeName], p.shape != [m, 2] {
        issues.append(GeometryIssue(code: "E405", message: "\(planeName) has shape \(p.shape); it must be (\(m), 2)"))
    }
    if let roleName, let r = g[roleName] {
        if r.count != m { issues.append(GeometryIssue(code: "E405", message: "\(roleName) has \(r.count) entries for \(m) \(noun)s")) }
        for (i, value) in (r.integers ?? []).enumerated() where value != 0 && value != 1 {
            issues.append(GeometryIssue(code: "E404", message: "\(roleName) \(value) is not 0 or 1", item: i))
        }
    }
    if issues.isEmpty {
        for i in 0..<m where o[i + 1] - o[i] < Int64(minimumVertices) {
            issues.append(GeometryIssue(code: "E404", message: "\(noun) \(i) has \(o[i + 1] - o[i]) vertices; at least \(minimumVertices) are required", item: i))
        }
        if !v.doubles.allSatisfy(\.isFinite) {
            issues.append(GeometryIssue(code: "E406", message: "a vertex is not finite"))
        }
    }
    return issues
}

extension GeometryArrayError {
    init(_ issue: GeometryIssue) { self.issue = issue }
}
