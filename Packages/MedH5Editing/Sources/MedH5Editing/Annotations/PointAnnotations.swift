import Foundation
import simd
import MedH5Core

// MARK: - Points (spec §8.5)

/// A landmark or point of a point set, at a padded position of its set's space.
public struct LandmarkPoint: Sendable, Hashable {
    public var position: SIMD3<Double>
    public var classID: UInt16?
    /// Anatomical landmark name.
    public var name: String?
    public var instanceID: UInt64?
    /// Evaluation weight.
    public var weight: Float?

    public init(position: SIMD3<Double>, classID: UInt16? = nil, name: String? = nil, instanceID: UInt64? = nil,
                weight: Float? = nil) {
        self.position = position
        self.classID = classID
        self.name = name
        self.instanceID = instanceID
        self.weight = weight
    }
}

/// A `points` annotation.
public struct PointAnnotationSet: Sendable, Hashable {
    public var space: AnnotationSpace
    public var rank: Int
    public var points: [LandmarkPoint]
    /// The id of the paired `points` annotation (spec §10.6).
    public var correspondence: String?

    public init(space: AnnotationSpace = .world, rank: Int = 3, points: [LandmarkPoint] = [],
                correspondence: String? = nil) {
        self.space = space
        self.rank = rank
        self.points = points
        self.correspondence = correspondence
    }

    /// The point named `name`.
    public func point(named name: String) -> LandmarkPoint? { points.first { $0.name == name } }

    /// The datasets: `points (N, S) float32`; the optional columns
    /// `class_ids`, `instance_ids`, `weights` when every point has a value;
    /// the `names` string column when any point is named (`""` otherwise).
    public func arrays() -> GeometricArrays {
        let n = points.count, s = rank
        var flat = [Float]()
        flat.reserveCapacity(n * s)
        for p in points { flat.append(contentsOf: StoredCoordinates.stored(p.position, rank: s, space: space).map(Float.init)) }
        var arrays = [AnnotationArray(name: "points", shape: [n, s], values: .float32(flat))]
        if n > 0, points.allSatisfy({ $0.classID != nil }) {
            arrays.append(AnnotationArray(name: "class_ids", shape: [n], values: .uint16(points.map { $0.classID! })))
        }
        if n > 0, points.allSatisfy({ $0.instanceID != nil }) {
            arrays.append(AnnotationArray(name: "instance_ids", shape: [n], values: .uint64(points.map { $0.instanceID! })))
        }
        if n > 0, points.allSatisfy({ $0.weight != nil }) {
            arrays.append(AnnotationArray(name: "weights", shape: [n], values: .float32(points.map { $0.weight! })))
        }
        var strings: [String: [String]] = [:]
        if points.contains(where: { $0.name != nil }) { strings["names"] = points.map { $0.name ?? "" } }
        var attributes: [String: String] = [:]
        if let correspondence { attributes["correspondence"] = correspondence }
        return GeometricArrays(kind: "points", space: space, arrays: arrays, strings: strings, attributes: attributes)
    }

    public init(arrays g: GeometricArrays) throws {
        let pts = try g.require("points")
        guard pts.shape.count == 2, pts.shape[1] == 2 || pts.shape[1] == 3 else {
            throw GeometryArrayError("E405", "points has shape \(pts.shape); it must be (N, S) with S = 2 or 3")
        }
        let n = pts.shape[0], s = pts.shape[1]
        let v = pts.doubles
        let classes = try g.optionalIntegers("class_ids", count: n)
        let instances = try g.optionalIDs("instance_ids", count: n)
        let weights = try g.optionalDoubles("weights", count: n)
        let names = try g.optionalStrings("names", count: n)
        space = g.space
        rank = s
        correspondence = g.attributes["correspondence"]
        points = (0..<n).map { i in
            LandmarkPoint(position: StoredCoordinates.padded(v[(i * s)..<((i + 1) * s)], rank: s, space: g.space),
                          classID: classes.map { UInt16(clamping: $0[i]) },
                          name: names.map { $0[i] }.flatMap { $0.isEmpty ? nil : $0 },
                          instanceID: instances.map { $0[i] },
                          weight: weights.map { Float($0[i]) })
        }
    }

    /// The set in another space of `geometry` (positions converted through
    /// the grid's affine).
    public func converted(to target: AnnotationSpace, geometry: GridGeometry) -> PointAnnotationSet {
        var out = self
        out.space = target
        out.points = points.map { p in
            var q = p
            q.position = StoredCoordinates.convert(p.position, from: space, to: target, geometry: geometry)
            return q
        }
        return out
    }

    /// Finite coordinates (E406); class ids that can be classes (E402);
    /// optional columns set for all points or none (E405).
    public func validate() -> [GeometryIssue] {
        var issues: [GeometryIssue] = []
        for (i, p) in points.enumerated() {
            if !GeometryChecks.finite(p.position) {
                issues.append(GeometryIssue(code: "E406", message: "point \(i) is not finite", item: i))
            }
            if let c = p.classID, c == ClassID.background || c == ClassID.ignore {
                issues.append(GeometryIssue(code: "E402", message: "point \(i) has the reserved class id \(c)", item: i))
            }
        }
        func partial<T>(_ name: String, _ key: KeyPath<LandmarkPoint, T?>) {
            let set = points.filter { $0[keyPath: key] != nil }.count
            if set > 0 && set < points.count {
                issues.append(GeometryIssue(code: "E405", message: "\(name) is set for \(set) of \(points.count) points; a column holds every point"))
            }
        }
        partial("class_ids", \.classID)
        partial("instance_ids", \.instanceID)
        partial("weights", \.weight)
        return issues
    }
}

// MARK: - Keypoints (spec §8.4)

/// A keypoint's visibility.
public enum KeypointVisibility: UInt8, Sendable, Hashable, Codable, CaseIterable {
    case unlabelled = 0
    case occluded = 1
    case visible = 2
}

/// One object of a keypoint annotation: one position per keypoint slot.
public struct KeypointObject: Sendable, Hashable {
    public var classID: UInt16
    /// `K` positions (padded, the set's space); an unlabelled slot's position is not meaningful.
    public var points: [SIMD3<Double>]
    public var visibility: [KeypointVisibility]

    public init(classID: UInt16, points: [SIMD3<Double>], visibility: [KeypointVisibility]) {
        self.classID = classID
        self.points = points
        self.visibility = visibility
    }

    /// An object with every slot unlabelled.
    public init(classID: UInt16, slots: Int) {
        self.init(classID: classID, points: Array(repeating: .zero, count: slots),
                  visibility: Array(repeating: .unlabelled, count: slots))
    }

    /// Places keypoint `slot`.
    public mutating func set(slot: Int, to position: SIMD3<Double>, visibility v: KeypointVisibility = .visible) {
        points[slot] = position
        visibility[slot] = v
    }
}

/// A `keypoints` annotation: N objects × K slots.
public struct KeypointAnnotationSet: Sendable, Hashable {
    public var space: AnnotationSpace
    public var rank: Int
    /// The class of each of the K slots (`keypoint_class_ids`).
    public var slotClassIDs: [UInt16]
    /// Skeleton id from the label set (spec §5.5).
    public var skeleton: String?
    public var objects: [KeypointObject]

    public init(space: AnnotationSpace = .world, rank: Int = 3, slotClassIDs: [UInt16], skeleton: String? = nil,
                objects: [KeypointObject] = []) {
        self.space = space
        self.rank = rank
        self.slotClassIDs = slotClassIDs
        self.skeleton = skeleton
        self.objects = objects
    }

    public var slotCount: Int { slotClassIDs.count }

    /// Adds an object with every slot unlabelled; returns its index.
    @discardableResult
    public mutating func addObject(classID: UInt16) -> Int {
        objects.append(KeypointObject(classID: classID, slots: slotCount))
        return objects.count - 1
    }

    /// The datasets: `points (N, K, S) float32`, `visibility (N, K) uint8`,
    /// `keypoint_class_ids (K,) uint16`, `class_ids (N,) uint16`, attribute
    /// `skeleton`.
    public func arrays() -> GeometricArrays {
        let n = objects.count, k = slotCount, s = rank
        var flat = [Float]()
        flat.reserveCapacity(n * k * s)
        var vis = [UInt8]()
        vis.reserveCapacity(n * k)
        for o in objects {
            for j in 0..<k {
                let p = j < o.points.count ? o.points[j] : .zero
                flat.append(contentsOf: StoredCoordinates.stored(p, rank: s, space: space).map(Float.init))
                vis.append(j < o.visibility.count ? o.visibility[j].rawValue : 0)
            }
        }
        var attributes: [String: String] = [:]
        if let skeleton { attributes["skeleton"] = skeleton }
        return GeometricArrays(kind: "keypoints", space: space, arrays: [
            AnnotationArray(name: "points", shape: [n, k, s], values: .float32(flat)),
            AnnotationArray(name: "visibility", shape: [n, k], values: .uint8(vis)),
            AnnotationArray(name: "keypoint_class_ids", shape: [k], values: .uint16(slotClassIDs)),
            AnnotationArray(name: "class_ids", shape: [n], values: .uint16(objects.map(\.classID))),
        ], attributes: attributes)
    }

    public init(arrays g: GeometricArrays) throws {
        let pts = try g.require("points")
        guard pts.shape.count == 3, pts.shape[2] == 2 || pts.shape[2] == 3 else {
            throw GeometryArrayError("E405", "keypoints points has shape \(pts.shape); it must be (N, K, S)")
        }
        let n = pts.shape[0], k = pts.shape[1], s = pts.shape[2]
        let vis = try g.require("visibility")
        guard vis.shape == [n, k], let visValues = vis.integers else {
            throw GeometryArrayError("E405", "visibility has shape \(vis.shape); it must be (\(n), \(k))")
        }
        let slots = try g.requireIntegers("keypoint_class_ids")
        guard slots.count == k else { throw GeometryArrayError("E405", "keypoint_class_ids has \(slots.count) entries for \(k) slots") }
        let classes = try g.requireIntegers("class_ids")
        guard classes.count == n else { throw GeometryArrayError("E405", "class_ids has \(classes.count) entries for \(n) objects") }
        let v = pts.doubles
        var objects: [KeypointObject] = []
        for i in 0..<n {
            var points: [SIMD3<Double>] = []
            var visibility: [KeypointVisibility] = []
            for j in 0..<k {
                let o = (i * k + j) * s
                points.append(StoredCoordinates.padded(v[o..<(o + s)], rank: s, space: g.space))
                guard let flag = KeypointVisibility(rawValue: UInt8(clamping: visValues[i * k + j])) else {
                    throw GeometryArrayError("E411", "keypoint visibility \(visValues[i * k + j]) is not 0, 1 or 2", item: i)
                }
                visibility.append(flag)
            }
            objects.append(KeypointObject(classID: UInt16(clamping: classes[i]), points: points, visibility: visibility))
        }
        space = g.space
        rank = s
        slotClassIDs = slots.map { UInt16(clamping: $0) }
        skeleton = g.attributes["skeleton"]
        self.objects = objects
    }

    public func converted(to target: AnnotationSpace, geometry: GridGeometry) -> KeypointAnnotationSet {
        var out = self
        out.space = target
        out.objects = objects.map { o in
            var q = o
            q.points = o.points.map { StoredCoordinates.convert($0, from: space, to: target, geometry: geometry) }
            return q
        }
        return out
    }

    /// Every object with K points and K visibilities (E405); labelled points
    /// finite (E406); class ids that can be classes (E402).
    public func validate() -> [GeometryIssue] {
        var issues: [GeometryIssue] = []
        for (i, o) in objects.enumerated() {
            if o.points.count != slotCount || o.visibility.count != slotCount {
                issues.append(GeometryIssue(code: "E405", message: "object \(i) has \(o.points.count) points and \(o.visibility.count) visibilities for \(slotCount) slots", item: i))
            }
            for (j, p) in o.points.enumerated() where j < o.visibility.count && o.visibility[j] != .unlabelled && !GeometryChecks.finite(p) {
                issues.append(GeometryIssue(code: "E406", message: "object \(i) keypoint \(j) is not finite", item: i))
            }
            if o.classID == ClassID.background || o.classID == ClassID.ignore {
                issues.append(GeometryIssue(code: "E402", message: "object \(i) has the reserved class id \(o.classID)", item: i))
            }
        }
        return issues
    }
}
