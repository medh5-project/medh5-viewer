import Foundation
import Observation
import simd
import MedH5Kit
import MedH5Render
import MedH5Editing

/// The state of one resource.
enum ResourceState {
    case loading
    case ready(any StoredResource)
    case failed(String)
}

/// Loads a document's voxels, textures, geometry and transforms on
/// background tasks and keeps them under a memory budget.
///
/// - **One copy.** A volume is read once and its GPU texture made once;
///   every view (and both sides of Compare) samples the same texture.
/// - **Background.** Every read runs off the main actor; `progress` reports
///   the fraction read, which the viewports show. Closing the document
///   cancels everything in flight (`cancelAll()`), which stops the engine's
///   reads through their progress callbacks.
/// - **Budget.** After each load the store evicts the least recently used
///   resources that no view uses (`inUse`, kept by the workspace) until the
///   total is under the Preferences budget. Resources holding unsaved edits
///   are pinned and never evicted.
@MainActor
@Observable
final class VolumeStore {
    /// Each resource requested, by key.
    private(set) var states: [ResourceKey: ResourceState] = [:]
    /// The fraction read of each resource still loading.
    private(set) var progress: [ResourceKey: Double] = [:]
    /// Bytes held by ready resources.
    private(set) var totalBytes = 0
    /// How many resources the budget has evicted (for the tests and the
    /// Info panel).
    private(set) var evictionCount = 0

    /// The keys the views use now: never evicted.
    @ObservationIgnored var inUse: Set<ResourceKey> = []
    /// Keys never evicted (unsaved edits).
    @ObservationIgnored private(set) var pinned: Set<ResourceKey> = []
    /// The budget in bytes; by default the Preferences value.
    @ObservationIgnored var budget: () -> Int = { Preferences.memoryBudgetBytes }

    @ObservationIgnored private(set) var file: SampleFile
    @ObservationIgnored let context: RenderContext?
    @ObservationIgnored private var tasks: [ResourceKey: Task<any StoredResource, Error>] = [:]
    @ObservationIgnored private var lastUsed: [ResourceKey: UInt64] = [:]
    @ObservationIgnored private var clock: UInt64 = 0
    @ObservationIgnored private var generation = 0

    init(file: SampleFile, context: RenderContext? = RenderContext.shared) {
        self.file = file
        self.context = context
    }

    // MARK: Reading state

    /// The resource, when ready (marks it used).
    func ready<T: StoredResource>(_ key: ResourceKey, as type: T.Type = T.self) -> T? {
        guard case .ready(let r)? = states[key] else { return nil }
        touch(key)
        return r as? T
    }

    /// Whether a resource is loaded, whatever its type.
    func isReady(_ key: ResourceKey) -> Bool {
        if case .ready? = states[key] { return true }
        return false
    }

    func isLoading(_ key: ResourceKey) -> Bool {
        if case .loading? = states[key] { return true }
        return false
    }

    /// Why the resource failed, if it did.
    func failure(_ key: ResourceKey) -> String? {
        if case .failed(let message)? = states[key] { return message }
        return nil
    }

    /// Keys still loading.
    var pendingKeys: [ResourceKey] {
        states.compactMap { key, state in
            if case .loading = state { return key }
            return nil
        }
    }

    /// Whether nothing is loading.
    var isIdle: Bool { pendingKeys.isEmpty }

    // MARK: Loading

    /// Starts loading `key` unless it is loaded, loading or failed (use
    /// `retry` for a failed one).
    func request(_ key: ResourceKey) {
        if states[key] != nil {
            touch(key)
            return
        }
        start(key)
    }

    /// Requests every key.
    func request<S: Sequence>(_ keys: S) where S.Element == ResourceKey {
        for k in keys { request(k) }
    }

    /// Loads a failed resource again.
    func retry(_ key: ResourceKey) {
        guard case .failed? = states[key] else { return }
        states[key] = nil
        start(key)
    }

    /// The resource, loading it first if needed; throws its failure.
    func resource(_ key: ResourceKey) async throws -> any StoredResource {
        switch states[key] {
        case .ready(let r)?:
            touch(key)
            return r
        case .failed(let message)?:
            throw StoreError.failed(key, message)
        case .loading?, nil:
            request(key)
            guard let task = tasks[key] else { throw StoreError.failed(key, "not loading") }
            return try await task.value
        }
    }

    /// The typed resource, loading it first if needed.
    func resource<T: StoredResource>(_ key: ResourceKey, as type: T.Type) async throws -> T {
        guard let r = try await resource(key) as? T else { throw StoreError.failed(key, "unexpected resource type") }
        return r
    }

    private func start(_ key: ResourceKey) {
        states[key] = .loading
        if key.readsVoxels { progress[key] = 0 }
        let loader = ResourceLoader(file: file, context: context)
        let generation = self.generation
        let owner = WeakStore(self)
        let reporter = ProgressThrottle { fraction in
            Task { @MainActor in owner.store?.setProgress(key, fraction, generation: generation) }
        }
        // The task ends only once the store has recorded the outcome: whoever
        // awaits it (`resource`) finds the resource ready and counted.
        tasks[key] = Task.detached(priority: .userInitiated) { () async throws -> any StoredResource in
            do {
                let value = try await loader.load(key, store: owner.store, progress: reporter.report)
                await owner.store?.finish(key, value, generation: generation)
                return value
            } catch {
                await owner.store?.fail(key, error, generation: generation)
                throw error
            }
        }
    }

    private func setProgress(_ key: ResourceKey, _ fraction: Double, generation: Int) {
        guard generation == self.generation, case .loading? = states[key] else { return }
        progress[key] = fraction
    }

    private func finish(_ key: ResourceKey, _ value: any StoredResource, generation: Int) {
        guard generation == self.generation else { return }
        tasks[key] = nil
        progress[key] = nil
        if case .ready(let old)? = states[key] { totalBytes -= old.byteCount }
        states[key] = .ready(value)
        totalBytes += value.byteCount
        touch(key)
        enforceBudget()
    }

    private func fail(_ key: ResourceKey, _ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        tasks[key] = nil
        progress[key] = nil
        if error is CancellationError || (error as? MedH5Error)?.isCancellation == true {
            states[key] = nil
            return
        }
        states[key] = .failed(Self.describe(error))
        Log.error("\(key): \(Self.describe(error))")
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? MedH5Error { return e.errorDescription ?? e.message }
        if let e = error as? StoreError { return e.description }
        if let e = error as? RenderError { return e.description }
        return error.localizedDescription
    }

    private func touch(_ key: ResourceKey) {
        clock &+= 1
        lastUsed[key] = clock
    }

    // MARK: Memory

    /// Never evicts `key` (it holds unsaved edits).
    func pin(_ key: ResourceKey) { pinned.insert(key) }
    func unpin(_ key: ResourceKey) { pinned.remove(key) }

    /// Evicts least recently used, unused resources until the total is
    /// under the budget. Returns the keys evicted.
    @discardableResult
    func enforceBudget() -> [ResourceKey] {
        let limit = budget()
        guard totalBytes > limit else { return [] }
        let candidates = states.compactMap { key, state -> (ResourceKey, UInt64)? in
            guard case .ready = state, !inUse.contains(key), !pinned.contains(key) else { return nil }
            return (key, lastUsed[key] ?? 0)
        }.sorted { $0.1 < $1.1 }
        var evicted: [ResourceKey] = []
        for (key, _) in candidates where totalBytes > limit {
            evict(key)
            evicted.append(key)
        }
        if !evicted.isEmpty {
            Log.info("memory budget \(Format.bytes(limit)): evicted \(evicted.map(\.description).joined(separator: ", "))")
        }
        return evicted
    }

    /// Holds a resource made in memory as if it had been loaded (a
    /// segmentation created in the window, not in the file yet).
    func put(_ key: ResourceKey, _ resource: any StoredResource) {
        tasks[key]?.cancel()
        tasks[key] = nil
        progress[key] = nil
        if case .ready(let old)? = states[key] { totalBytes -= old.byteCount }
        states[key] = .ready(resource)
        totalBytes += resource.byteCount
        touch(key)
    }

    /// Drops one resource (it is loaded again when next requested).
    func evict(_ key: ResourceKey) {
        guard !pinned.contains(key) else { return }
        if case .ready(let r)? = states[key] {
            totalBytes -= r.byteCount
            evictionCount += 1
        }
        tasks[key]?.cancel()
        tasks[key] = nil
        states[key] = nil
        progress[key] = nil
        lastUsed[key] = nil
    }

    /// Drops every resource derived from an object (after a save replaced it).
    func invalidate(objectID: String) {
        for key in states.keys where key.objectID == objectID && !pinned.contains(key) { evict(key) }
    }

    /// Cancels every load and forgets every resource (the document closes).
    func cancelAll() {
        generation += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        states.removeAll()
        progress.removeAll()
        lastUsed.removeAll()
        totalBytes = 0
    }

    /// Reads from another handle on the same content (after a save reopened
    /// the file). Loaded resources stay valid: the objects they came from
    /// are unchanged, or replaced by what the editor holds.
    func replaceFile(_ newFile: SampleFile) {
        file = newFile
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        let loading = states.filter { if case .loading = $0.value { return true } else { return false } }.map(\.key)
        for key in loading {
            states[key] = nil
            progress[key] = nil
        }
        generation += 1
        for key in loading { start(key) }
    }
}

enum StoreError: Error, CustomStringConvertible {
    case failed(ResourceKey, String)
    case noMetal
    case notFound(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .failed(_, let m): return m
        case .noMetal: return "Metal is not available on this Mac"
        case .notFound(let what): return "\(what) is not in the sample"
        case .unsupported(let m): return m
        }
    }
}

/// A weak reference to the store that crosses into background tasks.
private final class WeakStore: @unchecked Sendable {
    weak var store: VolumeStore?
    init(_ store: VolumeStore) { self.store = store }
}

/// Coalesces progress reports to steps of at least 2 %.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let sink: @Sendable (Double) -> Void

    init(_ sink: @escaping @Sendable (Double) -> Void) { self.sink = sink }

    var report: @Sendable (Double) -> Void {
        { [self] fraction in
            lock.lock()
            let send = fraction - last >= 0.02 || fraction >= 1
            if send { last = fraction }
            lock.unlock()
            if send { sink(fraction) }
        }
    }
}

/// Runs a blocking engine call on a GCD thread, off the cooperative pool.
func blocking<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try body() })
        }
    }
}

/// How each resource is made.
struct ResourceLoader: @unchecked Sendable {
    let file: SampleFile
    let context: RenderContext?

    func load(_ key: ResourceKey, store: VolumeStore?, progress: @escaping @Sendable (Double) -> Void) async throws
        -> any StoredResource {
        try Task.checkCancellation()
        let file = self.file
        let context = self.context
        switch key {
        case .image(let id):
            let volume = try await file.loadImage(id, progress: progress)
            return ImageResource(volume: volume)

        case .imageFrame(let id, let frame):
            guard let store else { throw CancellationError() }
            guard let context else { throw StoreError.noMetal }
            let image = try await store.resource(.image(id), as: ImageResource.self).volume
            return try await blocking {
                TextureResource(texture: try ImageFrames.texture(context: context, image: image, frame: frame))
            }

        case .histogram(let id, let frame):
            guard let store else { throw CancellationError() }
            let image = try await store.resource(.image(id), as: ImageResource.self).volume
            return try await blocking { ImageFrames.histogram(image: image, frame: frame) }

        case .segmentation(let id):
            guard let info = file.summary.annotation(id) else { throw StoreError.notFound("annotation \(id)") }
            let data = try await file.loadSegmentation(id, progress: progress)
            return try await blocking {
                let model = try SegmentationFactory.model(from: data)
                var textures: [VolumeTexture] = []
                var ignoreTexture: VolumeTexture?
                if let context {
                    textures = try model.layers.map { try VolumeTexture(context: context, labels: $0, geometry: model.geometry) }
                    if let ignore = data.ignoreRegion {
                        ignoreTexture = try VolumeTexture(context: context, labels: ignore, geometry: model.geometry)
                    }
                }
                let stats = (try? file.classStats(id)) ?? [:]
                return SegmentationResource(info: info, plan: data.plan, model: model, textures: textures,
                                            ignoreRegion: data.ignoreRegion, ignoreTexture: ignoreTexture,
                                            classStats: stats, context: context)
            }

        case .instanceMap(let id):
            let grid = try spatialGrid(of: id)
            return try await blocking {
                let map = try file.readInstanceMap(id)
                let instances = try file.instances(id)
                let texture = try context.map { try VolumeTexture(context: $0, labels: map, geometry: grid) }
                return VoxelResource(data: map, texture: texture, instances: instances)
            }

        case .probability(let id, let classID):
            let grid = try spatialGrid(of: id)
            return try await blocking {
                let p = try file.readProbability(id, classID: classID)
                let texture = try context.map { try VolumeTexture(context: $0, scalars: p, geometry: grid) }
                return VoxelResource(data: p, texture: texture)
            }

        case .mask(let id):
            let grid = try spatialGrid(of: id)
            return try await blocking {
                let m = try file.readMask(id)
                let texture = try context.map { try VolumeTexture(context: $0, labels: m, geometry: grid) }
                return VoxelResource(data: m, texture: texture)
            }

        case .geometry(let id):
            return try await blocking {
                let annotation = try file.geometry(id)
                var parts: [MeshPart] = []
                if case .mesh(let mesh) = annotation, mesh.worldVertices.count == mesh.vertices.count {
                    parts = MeshParts.make(mesh, context: context)
                }
                return GeometryResource(annotation: annotation, meshes: parts)
            }

        case .placement(let p):
            return try await blocking {
                let step = PlacementResolver.fieldStep(for: p.fieldGrid.flatMap { file.summary.grid($0) })
                let resolved = try file.resolveTransform(from: p.from, to: p.to, fieldGrid: p.fieldGrid, step: step)
                var texture: VolumeTexture?
                if let resolved, case .field(let displacement, let grid) = resolved.mapping, let context {
                    texture = try PlacementResolver.fieldTexture(context: context, displacement: displacement, grid: grid)
                }
                return PlacementResource(transform: resolved, fieldTexture: texture)
            }

        case .surfaces(let id):
            guard let store else { throw CancellationError() }
            guard let context else { throw StoreError.noMetal }
            let segmentation = try await store.resource(.segmentation(id), as: SegmentationResource.self)
            let model = segmentation.model
            return try await blocking {
                var surfaces: [SurfaceResource.Surface] = []
                let factor = SurfaceExtractionOptions.suggestedDownsampleFactor(for: model.shape, maxVoxels: 8_000_000)
                var options = SurfaceExtractionOptions.display
                options.downsampleFactor = factor
                for c in model.classes {
                    try Task.checkCancellation()
                    guard let layer = model.layer(of: c.id) else { continue }
                    let mesh = SurfaceExtractor.surface(labels: model.layers[layer], geometry: model.geometry,
                                                        classID: c.id, options: options)
                    guard !mesh.isEmpty else { continue }
                    surfaces.append(.init(classID: Int(c.id), mesh: try GPUMesh(context: context, mesh: mesh),
                                          triangles: mesh.triangleCount))
                }
                return SurfaceResource(surfaces: surfaces)
            }
        }
    }

    private func spatialGrid(of annotation: String) throws -> GridGeometry {
        guard let info = file.summary.annotation(annotation), let gid = info.grid, let grid = file.summary.grid(gid) else {
            throw StoreError.notFound("the grid of \(annotation)")
        }
        return grid.spatialOnly
    }
}

/// Turning a mesh annotation into renderable parts.
enum MeshParts {
    static func make(_ mesh: GeometricAnnotation.Mesh, context: RenderContext?) -> [MeshPart] {
        let positions = mesh.worldVertices.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        let submeshes: [(faces: Range<Int>, classID: Int?)] = mesh.submeshes.isEmpty
            ? [(0..<mesh.faces.count, nil)] : mesh.submeshes.map { ($0.faces, $0.classID) }
        var parts: [MeshPart] = []
        for sub in submeshes {
            let faces = sub.faces.clamped(to: 0..<mesh.faces.count)
            guard !faces.isEmpty else { continue }
            var indices: [UInt32] = []
            indices.reserveCapacity(faces.count * 3)
            var ok = true
            for f in faces {
                let t = mesh.faces[f]
                for v in [t.x, t.y, t.z] {
                    guard v >= 0, Int(v) < positions.count else { ok = false; break }
                    indices.append(UInt32(v))
                }
                if !ok { break }
            }
            guard ok else { continue }
            var tri = TriangleMesh(positions: positions, indices: indices)
            tri.computeNormals()
            let gpu = context.flatMap { try? GPUMesh(context: $0, mesh: tri) }
            parts.append(MeshPart(classID: sub.classID, mesh: tri, slicer: MeshSlicer(mesh: tri), gpu: gpu))
        }
        return parts
    }
}

/// Textures and statistics of image frames.
enum ImageFrames {
    /// The leading index of the frame to show: time and other axes from
    /// `selection`, the channel from `channel` (ignored for RGB).
    static func leadingIndex(for geometry: GridGeometry, time: Int, channel: Int) -> [Int] {
        geometry.leadingShape.indices.map { axis in
            let n = geometry.leadingShape[axis]
            switch geometry.axisKinds[axis] {
            case .time: return min(max(0, time), n - 1)
            case .channel: return min(max(0, channel), n - 1)
            default: return 0
            }
        }
    }

    /// Whether the image renders as colour (an `rgb` image with a channel
    /// axis of 3 or 4 `uint8`).
    static func isColor(_ image: ImageVolume) -> Bool {
        guard image.isRGB, let c = image.geometry.channelAxis else { return false }
        let n = image.geometry.shape[c]
        return (n == 3 || n == 4) && image.data.scalarType == .uint8
    }

    static func texture(context: RenderContext, image: ImageVolume, frame: [Int]) throws -> VolumeTexture {
        let g = image.geometry
        if isColor(image), let c = g.channelAxis {
            let others = frame.enumerated().filter { $0.offset != c }.map(\.element)
            return try VolumeTexture(context: context, image: image, frame: others)
        }
        let index = frame.count == g.leadingShape.count ? frame : Array(repeating: 0, count: g.leadingShape.count)
        return try VolumeTexture(context: context, scalars: image.spatialFrame(index), geometry: g)
    }

    static func histogram(image: ImageVolume, frame: [Int]) -> HistogramResource {
        let g = image.geometry
        let index = frame.count == g.leadingShape.count ? frame : Array(repeating: 0, count: g.leadingShape.count)
        let data = image.spatialFrame(index)
        let stats = data.statistics()
        let lo = stats.minimum, hi = max(stats.maximum, stats.minimum + 1e-9)
        let bins = data.histogram(bins: 256, range: lo...hi)
        let levels = HistogramResource.percentileLevels
        let values = data.percentiles(levels, stats: stats)
        var pct: [Double: Double] = [:]
        for (p, v) in zip(levels, values) { pct[p] = image.physical(fromRaw: v) }
        let a = image.physical(fromRaw: stats.minimum), b = image.physical(fromRaw: stats.maximum)
        let flipped = image.rescaleSlope < 0
        return HistogramResource(
            minimum: min(a, b), maximum: max(a, b), mean: image.physical(fromRaw: stats.mean),
            standardDeviation: abs(image.rescaleSlope) * stats.standardDeviation,
            bins: flipped ? bins.reversed() : bins, percentiles: pct)
    }
}
