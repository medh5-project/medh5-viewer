import Foundation
import simd
import MedH5Kit
import MedH5Editing

/// A geometric annotation as the editing tools hold it: one of the editing
/// library's annotation sets, in the annotation's own space (padded
/// coordinates: index coordinates of its grid, or world).
///
/// It comes from the file (`init(_:rank:)`, from what the engine read) or
/// from the pending edits (`init(edit:)`), and goes back to them as the
/// stored datasets (`edit(options:)`), validated first.
enum AnnotationDraft: Sendable, Equatable {
    case boxes(BoxAnnotationSet)
    case points(PointAnnotationSet)
    case keypoints(KeypointAnnotationSet)
    case polylines(PolylineAnnotationSet)
    case contours(ContourAnnotationSet)

    /// The kinds the tools edit (oriented boxes and meshes are shown only).
    static let editableKinds: Set<String> = ["boxes", "points", "keypoints", "polylines", "contours"]

    var kind: String {
        switch self {
        case .boxes: return "boxes"
        case .points: return "points"
        case .keypoints: return "keypoints"
        case .polylines: return "polylines"
        case .contours: return "contours"
        }
    }

    var space: AnnotationSpace {
        switch self {
        case .boxes(let s): return s.space
        case .points(let s): return s.space
        case .keypoints(let s): return s.space
        case .polylines(let s): return s.space
        case .contours(let s): return s.space
        }
    }

    var rank: Int {
        switch self {
        case .boxes(let s): return s.rank
        case .points(let s): return s.rank
        case .keypoints(let s): return s.rank
        case .polylines(let s): return s.rank
        case .contours(let s): return s.rank
        }
    }

    var itemCount: Int {
        switch self {
        case .boxes(let s): return s.boxes.count
        case .points(let s): return s.points.count
        case .keypoints(let s): return s.objects.count
        case .polylines(let s): return s.polylines.count
        case .contours(let s): return s.contours.count
        }
    }

    /// The class of each item (`nil` for a point without one).
    var itemClasses: [Int?] {
        switch self {
        case .boxes(let s): return s.boxes.map { Int($0.classID) }
        case .points(let s): return s.points.map { $0.classID.map(Int.init) }
        case .keypoints(let s): return s.objects.map { Int($0.classID) }
        case .polylines(let s): return s.polylines.map { Int($0.classID) }
        case .contours(let s): return s.contours.map { Int($0.classID) }
        }
    }

    /// The instance ids the items carry.
    var instanceIDs: [UInt64] {
        switch self {
        case .boxes(let s): return s.boxes.compactMap(\.instanceID)
        case .points(let s): return s.points.compactMap(\.instanceID)
        case .polylines(let s): return s.polylines.compactMap(\.instanceID)
        case .keypoints, .contours: return []
        }
    }

    /// The distinct classes of the items (keypoint slots too), ascending.
    var classIDs: [Int] {
        var ids = Set(itemClasses.compactMap { $0 })
        if case .keypoints(let s) = self { ids.formUnion(s.slotClassIDs.map(Int.init)) }
        return ids.sorted()
    }

    /// An empty annotation of a kind.
    static func empty(kind: String, space: AnnotationSpace, rank: Int) -> AnnotationDraft? {
        switch kind {
        case "boxes": return .boxes(BoxAnnotationSet(space: space, rank: rank))
        case "points": return .points(PointAnnotationSet(space: space, rank: rank))
        case "polylines": return .polylines(PolylineAnnotationSet(space: space, rank: rank))
        case "contours": return .contours(ContourAnnotationSet(space: space, rank: rank))
        default: return nil
        }
    }

    // MARK: Datasets

    /// The datasets medh5 stores.
    func arrays() -> GeometricArrays {
        switch self {
        case .boxes(let s): return s.arrays()
        case .points(let s): return s.arrays()
        case .keypoints(let s): return s.arrays()
        case .polylines(let s): return s.arrays()
        case .contours(let s): return s.arrays()
        }
    }

    init(arrays g: GeometricArrays) throws {
        switch g.kind {
        case "boxes": self = .boxes(try BoxAnnotationSet(arrays: g))
        case "points": self = .points(try PointAnnotationSet(arrays: g))
        case "keypoints": self = .keypoints(try KeypointAnnotationSet(arrays: g))
        case "polylines": self = .polylines(try PolylineAnnotationSet(arrays: g))
        case "contours": self = .contours(try ContourAnnotationSet(arrays: g))
        default: throw EditingFailure("\(KindNames.annotation(g.kind)) annotations are not edited here")
        }
    }

    /// The problems a save would be refused for, or warned about.
    func validate(grid: GridGeometry?) -> [GeometryIssue] {
        switch self {
        case .boxes(let s): return s.validate(gridShape: s.space == .index ? grid?.paddedShape : nil)
        case .points(let s): return s.validate()
        case .keypoints(let s): return s.validate()
        case .polylines(let s): return s.validate()
        case .contours(let s): return s.validate(geometry: grid)
        }
    }

    // MARK: From the file

    /// The draft of an annotation as the engine read it (`nil` for the
    /// kinds the tools do not edit). `rank` is the spatial rank of its
    /// coordinates (its grid's, 3 without a grid).
    init?(_ g: GeometricAnnotation, rank: Int) throws {
        func space(_ h: GeometricAnnotation.Header) -> AnnotationSpace { AnnotationSpace(rawValue: h.space) ?? .index }
        switch g {
        case .boxes(let b):
            let s = b.boxes.first?.count ?? rank
            var flat: [Double] = []
            for box in b.boxes { for iv in box { flat += [iv.lo, iv.hi] } }
            var arrays = [AnnotationArray(name: "boxes", shape: [b.boxes.count, s, 2], values: .float64(flat)),
                          AnnotationArray(name: "class_ids", shape: [b.classIDs.count], values: .int64(b.classIDs.map(Int64.init)))]
            if let ids = b.instanceIDs { arrays.append(AnnotationArray(name: "instance_ids", shape: [ids.count], values: .uint64(ids))) }
            if let scores = b.scores { arrays.append(AnnotationArray(name: "scores", shape: [scores.count], values: .float32(scores))) }
            if let slices = b.sliceIndex {
                arrays.append(AnnotationArray(name: "slice_index", shape: [slices.count], values: .int64(slices.map(Int64.init))))
            }
            var strings: [String: [String]] = [:]
            if let attrs = b.header.attributes, attrs.count == b.boxes.count { strings["attributes"] = attrs.map { $0.serialized() } }
            try self.init(arrays: GeometricArrays(kind: "boxes", space: space(b.header), arrays: arrays, strings: strings))
        case .points(let p):
            let sp = space(p.header)
            let n = p.points.count
            var arrays = [AnnotationArray(name: "points", shape: [n, rank],
                                          values: .float64(p.points.flatMap { Self.stored($0, rank: rank, space: sp) }))]
            if let c = p.classIDs, c.count == n { arrays.append(AnnotationArray(name: "class_ids", shape: [n], values: .int64(c.map(Int64.init)))) }
            if let ids = p.instanceIDs, ids.count == n { arrays.append(AnnotationArray(name: "instance_ids", shape: [n], values: .uint64(ids))) }
            if let w = p.weights, w.count == n { arrays.append(AnnotationArray(name: "weights", shape: [n], values: .float64(w))) }
            var strings: [String: [String]] = [:]
            if let names = p.names, names.count == n { strings["names"] = names }
            var attributes: [String: String] = [:]
            if let c = p.correspondence { attributes["correspondence"] = c }
            try self.init(arrays: GeometricArrays(kind: "points", space: sp, arrays: arrays, strings: strings, attributes: attributes))
        case .keypoints(let k):
            let sp = space(k.header)
            let n = k.points.count, slots = k.keypointClassIDs.count
            var flat: [Double] = []
            var vis: [UInt8] = []
            for i in 0..<n {
                for j in 0..<slots {
                    flat += Self.stored(k.points[i][safe: j] ?? .zero, rank: rank, space: sp)
                    vis.append(k.visibility[safe: i]?[safe: j] ?? 2)
                }
            }
            var attributes: [String: String] = [:]
            if let s = k.skeleton { attributes["skeleton"] = s }
            try self.init(arrays: GeometricArrays(kind: "keypoints", space: sp, arrays: [
                AnnotationArray(name: "points", shape: [n, slots, rank], values: .float64(flat)),
                AnnotationArray(name: "visibility", shape: [n, slots], values: .uint8(vis)),
                AnnotationArray(name: "keypoint_class_ids", shape: [slots], values: .int64(k.keypointClassIDs.map(Int64.init))),
                AnnotationArray(name: "class_ids", shape: [k.classIDs.count], values: .int64(k.classIDs.map(Int64.init))),
            ], attributes: attributes))
        case .contours(let c):
            let sp = space(c.header)
            try self.init(arrays: Self.curveArrays(kind: "contours", prefix: "contour", space: sp, rank: rank,
                                                   vertices: c.polygons.map(\.vertices), classes: c.polygons.map(\.classID),
                                                   planes: c.polygons.map { [$0.plane.axis, $0.plane.index] },
                                                   roles: c.polygons.map { $0.isHole ? 1 : 0 }, instanceIDs: nil))
        case .polylines(let p):
            let sp = space(p.header)
            let ids = p.polylines.allSatisfy { $0.instanceID != nil } && !p.polylines.isEmpty ? p.polylines.map { $0.instanceID! } : nil
            try self.init(arrays: Self.curveArrays(kind: "polylines", prefix: "polyline", space: sp, rank: rank,
                                                   vertices: p.polylines.map(\.vertices), classes: p.polylines.map(\.classID),
                                                   planes: p.polylines.map { [$0.plane.axis, $0.plane.index] },
                                                   roles: nil, instanceIDs: ids))
        case .orientedBoxes, .mesh, .classification:
            return nil
        }
    }

    private static func curveArrays(kind: String, prefix: String, space: AnnotationSpace, rank: Int,
                                    vertices: [[SIMD3<Double>]], classes: [Int], planes: [[Int]], roles: [Int]?,
                                    instanceIDs: [UInt64]?) -> GeometricArrays {
        var offsets: [Int64] = [0]
        var flat: [Double] = []
        for v in vertices {
            for p in v { flat += stored(p, rank: rank, space: space) }
            offsets.append(offsets.last! + Int64(v.count))
        }
        let m = vertices.count
        var arrays = [
            AnnotationArray(name: "vertices", shape: [Int(offsets.last!), rank], values: .float64(flat)),
            AnnotationArray(name: "\(prefix)_offsets", shape: [m + 1], values: .int64(offsets)),
            AnnotationArray(name: "\(prefix)_class_ids", shape: [m], values: .int64(classes.map(Int64.init))),
            AnnotationArray(name: "\(prefix)_plane", shape: [m, 2], values: .int64(planes.flatMap { $0.map(Int64.init) })),
        ]
        if let roles { arrays.append(AnnotationArray(name: "contour_role", shape: [m], values: .int64(roles.map(Int64.init)))) }
        if let instanceIDs { arrays.append(AnnotationArray(name: "instance_ids", shape: [m], values: .uint64(instanceIDs))) }
        return GeometricArrays(kind: kind, space: space, arrays: arrays)
    }

    /// The stored components of a padded coordinate (as MedH5Kit and the
    /// editing library pad: an index `(i0, i1)` is `(0, i0, i1)`, a world
    /// `(x, y)` is `(x, y, 0)`).
    static func stored(_ p: SIMD3<Double>, rank: Int, space: AnnotationSpace) -> [Double] {
        if rank >= 3 { return [p.x, p.y, p.z] }
        return space == .index ? [p.y, p.z] : [p.x, p.y]
    }

    // MARK: To and from the pending edits

    /// The draft of a pending geometric edit.
    init(edit: AnnotationEdit) throws {
        guard case .geometric(let kind, let options, let named) = edit else {
            throw EditingFailure("Not a geometric annotation")
        }
        var strings: [String: [String]] = [:]
        if let names = options.extra["names"]?.arrayValue { strings["names"] = names.map { $0.stringValue ?? "" } }
        if let attrs = options.attributes { strings["attributes"] = attrs.map { JSONValue.object($0).serialized() } }
        var attributes: [String: String] = [:]
        if let s = options.extra["skeleton"]?.stringValue { attributes["skeleton"] = s }
        if let c = options.extra["correspondence"]?.stringValue { attributes["correspondence"] = c }
        try self.init(arrays: GeometricArrays(kind: kind, space: AnnotationSpace(rawValue: options.space ?? "index") ?? .index,
                                              arrays: named.map(AnnotationArray.init(named:)), strings: strings,
                                              attributes: attributes))
    }

    /// The pending edit writing this draft with `options` (the header);
    /// string columns and attributes go into the options.
    func edit(options base: GeometricWriteOptions) -> AnnotationEdit {
        let g = arrays()
        var options = base
        options.space = g.space.rawValue
        options.attributes = nil
        options.extra["names"] = nil
        options.extra["skeleton"] = nil
        options.extra["correspondence"] = nil
        if let names = g.strings["names"] { options.extra["names"] = .strings(names) }
        if let attrs = g.strings["attributes"] {
            options.attributes = attrs.map { (try? JSONValue.parse($0))?.objectValue ?? JSONObject() }
        }
        for (k, v) in g.attributes { options.extra[k] = .string(v) }
        return .geometric(kind: g.kind, options: options, arrays: g.arrays.map(\.named))
    }

    // MARK: Changing items

    mutating func remove(_ items: Set<Int>) {
        func keep<T>(_ a: [T]) -> [T] { a.enumerated().filter { !items.contains($0.offset) }.map(\.element) }
        switch self {
        case .boxes(var s): s.boxes = keep(s.boxes); self = .boxes(s)
        case .points(var s): s.points = keep(s.points); self = .points(s)
        case .keypoints(var s): s.objects = keep(s.objects); self = .keypoints(s)
        case .polylines(var s): s.polylines = keep(s.polylines); self = .polylines(s)
        case .contours(var s):
            s.contours = keep(s.contours)
            self = .contours(s)
        }
    }

    mutating func setClass(_ classID: UInt16, items: Set<Int>) {
        switch self {
        case .boxes(var s): for i in items where i < s.boxes.count { s.boxes[i].classID = classID }; self = .boxes(s)
        case .points(var s): for i in items where i < s.points.count { s.points[i].classID = classID }; self = .points(s)
        case .keypoints(var s): for i in items where i < s.objects.count { s.objects[i].classID = classID }; self = .keypoints(s)
        case .polylines(var s): for i in items where i < s.polylines.count { s.polylines[i].classID = classID }; self = .polylines(s)
        case .contours(var s): for i in items where i < s.contours.count { s.contours[i].classID = classID }; self = .contours(s)
        }
    }

    /// The items listed, as a draft of their own.
    func subset(_ items: Set<Int>) -> AnnotationDraft {
        var copy = self
        copy.remove(Set(0..<itemCount).subtracting(items))
        return copy
    }

    /// Contours: each polygon's role from its depth among its class's
    /// polygons in its plane (spec §8.6), as the engine reads them.
    mutating func normalizeRoles(grid: GridGeometry?) {
        guard case .contours(var s) = self else { return }
        let roles = s.rolesFromDepth(geometry: grid)
        for i in s.contours.indices where s.contours[i].plane != nil { s.contours[i].role = roles[i] }
        self = .contours(s)
    }

    // MARK: Reading items

    /// One item as the Annotations tab lists it.
    struct Item: Identifiable, Equatable {
        let id: Int
        var classID: Int?
        var score: Float?
        var title: String
        var detail: String
        /// Where the item is, in world coordinates of the annotation's frame.
        var center: SIMD3<Double>?
    }

    /// Item positions in world coordinates of the annotation's frame.
    func world(_ p: SIMD3<Double>, grid: GridGeometry?) -> SIMD3<Double> {
        space == .index ? (grid?.world(fromIndex: p) ?? p) : p
    }

    func items(grid: GridGeometry?, labelSet: LabelSetInfo?) -> [Item] {
        let units = grid?.units ?? "mm"
        func pt(_ p: SIMD3<Double>) -> String { "(\(Format.point(world(p, grid: grid)))) \(units)" }
        switch self {
        case .boxes(let s):
            return s.boxes.enumerated().map { i, b in
                let c = (b.lower + b.upper) / 2
                var size = b.upper - b.lower
                if s.space == .index, let g = grid { size *= g.paddedSpacing }
                let dims = (0..<3).filter { b.isOnSlice ? $0 != b.degenerateAxis : true }.map { Format.number(abs(size[$0]), digits: 1) }
                var detail = "centre \(pt(c)) · \(dims.joined(separator: " × ")) \(units)"
                if let k = b.sliceIndex, b.isOnSlice { detail += " · slice \(k + 1)" }
                return Item(id: i, classID: Int(b.classID), score: b.score, title: "Box \(i + 1)", detail: detail,
                            center: world(c, grid: grid))
            }
        case .points(let s):
            return s.points.enumerated().map { i, p in
                Item(id: i, classID: p.classID.map(Int.init), score: nil, title: p.name ?? "Point \(i + 1)",
                     detail: pt(p.position), center: world(p.position, grid: grid))
            }
        case .keypoints(let s):
            return s.objects.enumerated().map { i, o in
                let placed = o.points.indices.filter { $0 < o.visibility.count && o.visibility[$0] != .unlabelled }
                let mean = placed.isEmpty ? nil : placed.map { o.points[$0] }.reduce(SIMD3<Double>.zero, +) / Double(placed.count)
                return Item(id: i, classID: Int(o.classID), score: nil, title: "Object \(i + 1)",
                            detail: "\(placed.count) of \(s.slotCount) keypoints placed", center: mean.map { world($0, grid: grid) })
            }
        case .polylines(let s):
            return s.polylines.enumerated().map { i, p in
                let length = p.length(space: s.space, geometry: grid)
                let mid = p.vertices.isEmpty ? nil : p.vertices[p.vertices.count / 2]
                var detail = "\(p.vertices.count) vertices · \(Format.number(length, digits: 1)) \(units)"
                if let plane = p.plane { detail += " · slice \(plane.index + 1)" }
                return Item(id: i, classID: Int(p.classID), score: nil, title: "Polyline \(i + 1)", detail: detail,
                            center: mid.map { world($0, grid: grid) })
            }
        case .contours(let s):
            return s.contours.enumerated().map { i, c in
                let area = c.area(space: s.space, geometry: grid)
                let mean = c.vertices.isEmpty ? nil : c.vertices.reduce(SIMD3<Double>.zero, +) / Double(c.vertices.count)
                var detail = "\(c.vertices.count) vertices · \(Format.number(area, digits: 1)) \(units)²"
                if let plane = c.plane { detail += " · slice \(plane.index + 1)" }
                if c.role == .hole { detail += " · hole" }
                return Item(id: i, classID: Int(c.classID), score: nil, title: "Contour \(i + 1)", detail: detail,
                            center: mean.map { world($0, grid: grid) })
            }
        }
    }
}

extension AnnotationArray {
    /// A dataset of a pending edit, read back.
    init(named a: NamedArray) {
        let d = a.data
        let values: Values
        switch d.scalarType {
        case .float32: values = .float32(Array(d.buffer(as: Float.self)))
        case .float64: values = .float64(Array(d.buffer(as: Double.self)))
        case .int32: values = .int32(Array(d.buffer(as: Int32.self)))
        case .int64: values = .int64(Array(d.buffer(as: Int64.self)))
        case .uint8: values = .uint8(Array(d.buffer(as: UInt8.self)))
        case .uint16: values = .uint16(Array(d.buffer(as: UInt16.self)))
        case .uint32: values = .uint32(Array(d.buffer(as: UInt32.self)))
        case .uint64: values = .uint64(Array(d.buffer(as: UInt64.self)))
        case .float16:
            values = .float64((0..<d.count).map { d.value(at: $0) })
        case .bool, .int8, .int16:
            values = .int64((0..<d.count).map { Int64(d.value(at: $0)) })
        }
        self.init(name: a.name, shape: d.shape, values: values)
    }

    /// The dataset as the writer takes it.
    var named: NamedArray {
        let data: VolumeData
        switch values {
        case .float32(let v): data = VolumeData(shape: shape, values: v)
        case .float64(let v): data = VolumeData(shape: shape, values: v)
        case .int32(let v): data = VolumeData(shape: shape, values: v)
        case .int64(let v): data = VolumeData(shape: shape, values: v)
        case .uint8(let v): data = VolumeData(shape: shape, values: v)
        case .uint16(let v): data = VolumeData(shape: shape, values: v)
        case .uint32(let v): data = VolumeData(shape: shape, values: v)
        case .uint64(let v): data = VolumeData(shape: shape, values: v)
        }
        return NamedArray(name, data)
    }
}

/// A draft decoded once per source (a pending edit, or what the engine
/// read).
struct DraftCacheEntry {
    enum Source: Equatable {
        case pending(AnnotationEdit)
        case file(ObjectIdentifier)
    }

    var source: Source
    var draft: AnnotationDraft
}
