import Foundation
import MedH5Bridge
import MedH5Core

// The plumbing between Swift and the C bridge: status checks, the strings
// the bridge allocates, progress callbacks, bundles and handle locking.

/// Throw the last error unless `status` is `M5_OK`.
@inline(__always)
func check(_ status: M5Status) throws {
    if status != M5_OK { throw MedH5Error.last(status) }
}

/// A string the bridge allocated, freed after it is copied.
func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { m5_string_free(pointer) }
    return String(cString: pointer)
}

/// Call a bridge function that returns a string in an out-pointer.
func callString(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> M5Status) throws -> String {
    var out: UnsafeMutablePointer<CChar>?
    try check(body(&out))
    return takeString(out) ?? ""
}

/// Call a bridge function that returns JSON in an out-pointer.
func callJSON(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> M5Status) throws -> JSONValue {
    try JSONValue.parse(callString(body))
}

/// Run `body` with an optional C string.
func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
    if let string { return try string.withCString { try body($0) } }
    return try body(nil)
}

/// A region of a stored array: `[start, stop)` per axis, in stored axis
/// order. A region naming fewer axes than the array names its trailing axes
/// (an image's spatial axes, say); the leading axes it leaves out are whole.
///
/// The reads take any rank. For the padded 3-D boxes the editor and the
/// renderer exchange, `init(_:spatialRank:)` converts a `VoxelBox`.
public struct ArrayRegion: Sendable, Hashable {
    public var start: [Int]
    public var stop: [Int]

    public init(start: [Int], stop: [Int]) {
        precondition(start.count == stop.count, "start and stop name the same axes")
        self.start = start
        self.stop = stop
    }

    /// The region at `origin` of `size` elements per axis.
    public init(origin: [Int], size: [Int]) {
        self.init(start: origin, stop: zip(origin, size).map { $0 + $1 })
    }

    /// The spatial region a `VoxelBox` covers on a grid of spatial rank
    /// `spatialRank` (`GridGeometry.spatialRank`). The box is in the padded
    /// index space, so for a 2-D grid this drops the padding axis 0, as
    /// `VoxelBox.edgeBounds(rank:)` does.
    public init(_ box: VoxelBox, spatialRank: Int = 3) {
        let axes = spatialRank >= 3 ? [0, 1, 2] : [1, 2]
        self.init(start: axes.map { box.lower[$0] }, stop: axes.map { box.upper[$0] })
    }

    public var shape: [Int] { zip(start, stop).map { max(0, $1 - $0) } }

    /// The output shape for an array of `shape`: the region's axes trail,
    /// any leading axes the region leaves out are whole.
    func outputShape(for shape: [Int]) -> [Int] {
        Array(shape.prefix(shape.count - start.count)) + self.shape
    }
}

/// Run `body` with the region as the bridge takes it.
func withRegion<R>(_ region: ArrayRegion?, _ body: (UnsafePointer<Int64>?, UnsafePointer<Int64>?, UInt32) throws -> R) rethrows -> R {
    guard let region else { return try body(nil, nil, 0) }
    let start = region.start.map(Int64.init)
    let stop = region.stop.map(Int64.init)
    return try start.withUnsafeBufferPointer { a in
        try stop.withUnsafeBufferPointer { b in
            try body(a.baseAddress, b.baseAddress, UInt32(start.count))
        }
    }
}

/// Reports progress and asks whether to go on: `completed` and `total` are
/// elements (or steps). Return `false` to cancel; the call then throws a
/// ``MedH5Error`` with status `.cancelled`.
public typealias ProgressHandler = @Sendable (_ completed: UInt64, _ total: UInt64) -> Bool

/// A flag a cancelled task sets and a running call reads.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// The context a C progress callback receives.
final class ProgressBox {
    let handler: ProgressHandler
    init(_ handler: @escaping ProgressHandler) { self.handler = handler }
}

private let progressTrampoline: M5ProgressFn = { context, done, total in
    guard let context else { return true }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    return box.handler(done, total)
}

/// Run `body` with the callback and context the bridge takes for `handler`.
func withProgress<R>(_ handler: ProgressHandler?, _ body: (M5ProgressFn?, UnsafeMutableRawPointer?) throws -> R) rethrows -> R {
    guard let handler else { return try body(nil, nil) }
    let box = ProgressBox(handler)
    return try withExtendedLifetime(box) {
        try body(progressTrampoline, Unmanaged.passUnretained(box).toOpaque())
    }
}

/// Run blocking bridge work off the cooperative thread pool, cancelling it
/// (through its progress callback) when the task is cancelled. A
/// cancellation surfaces as `CancellationError`.
func runBlocking<T>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping @Sendable (CancellationFlag) throws -> T
) async throws -> T {
    let flag = CancellationFlag()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: qos).async {
                if flag.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    continuation.resume(returning: try work(flag))
                } catch let error as MedH5Error where error.isCancellation && flag.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    } onCancel: {
        flag.cancel()
    }
}

/// A progress handler that also stops when `flag` is set, reporting the
/// fraction done to `report`.
func cancellable(_ flag: CancellationFlag, _ report: (@Sendable (Double) -> Void)?) -> ProgressHandler {
    { done, total in
        if let report { report(total == 0 ? 1 : Double(done) / Double(total)) }
        return !flag.isCancelled
    }
}

/// A reader-writer lock: calls through a handle hold it shared, closing it
/// holds it exclusively, so a handle is never freed under a running call.
final class HandleLock: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>

    init() {
        lock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func shared<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }

    func exclusive<R>(_ body: () throws -> R) rethrows -> R {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }
}

// MARK: - Bundles

/// One array of a bundle, copied out of the bridge's memory.
struct BundleArray {
    let name: String
    let type: ScalarType
    let shape: [Int]
    let data: VolumeData

    /// The elements as `Double`, in C order.
    var doubles: [Double] { (0..<data.count).map { data.value(at: $0) } }

    var ints: [Int] { (0..<data.count).map { Int(data.value(at: $0)) } }
}

/// A bundle read whole, then freed.
struct BundleContents {
    let header: JSONValue
    let arrays: [String: BundleArray]

    init(taking bundle: OpaquePointer?) throws {
        guard let bundle else { throw MedH5Error(status: .failed, kind: "runtime", message: "the bridge returned no bundle") }
        defer { m5_bundle_free(bundle) }
        header = try JSONValue.parse(String(cString: m5_bundle_header(bundle)))
        var arrays: [String: BundleArray] = [:]
        for index in 0..<m5_bundle_array_count(bundle) {
            var view = M5ArrayView()
            try check(m5_bundle_array_at(bundle, index, &view))
            let name = String(cString: view.name)
            guard let type = ScalarType(rawValue: view.dtype) else {
                throw MedH5Error(status: .failed, kind: "runtime", message: "array \(name) of unknown type \(view.dtype)")
            }
            let shape = (0..<Int(view.ndim)).map { Int(view.shape[$0]) }
            let raw = UnsafeRawBufferPointer(start: view.data, count: view.nbytes)
            arrays[name] = BundleArray(name: name, type: type, shape: shape,
                                       data: VolumeData(scalarType: type, shape: shape, bytes: raw))
        }
        self.arrays = arrays
    }

    func array(_ name: String) throws -> BundleArray {
        guard let found = arrays[name] else {
            throw MedH5Error(status: .notFound, kind: "not_found", message: "the bundle holds no array \(name)")
        }
        return found
    }
}

// MARK: - Arrays passed to the writer

/// An array handed to a writer call: a name and a volume of any type.
public struct NamedArray: @unchecked Sendable {
    public var name: String
    public var data: VolumeData

    public init(_ name: String, _ data: VolumeData) {
        self.name = name
        self.data = data
    }

    public init(_ name: String, shape: [Int], doubles: [Double]) {
        self.init(name, VolumeData(shape: shape, values: doubles))
    }

    public init(_ name: String, shape: [Int], ints: [Int64]) {
        self.init(name, VolumeData(shape: shape, values: ints))
    }

    public init(_ name: String, shape: [Int], unsigned: [UInt64]) {
        self.init(name, VolumeData(shape: shape, values: unsigned))
    }

    public init(_ name: String, shape: [Int], floats: [Float]) {
        self.init(name, VolumeData(shape: shape, values: floats))
    }
}

/// Run `body` with `M5ArrayView`s of `arrays`.
func withArrayViews<R>(_ arrays: [NamedArray], _ body: (UnsafePointer<M5ArrayView>?, Int) throws -> R) rethrows -> R {
    let names = arrays.map { strdup($0.name)! }
    let shapes = arrays.map { $0.data.shape.map(Int64.init) }
    defer { names.forEach { free($0) } }
    var views: [M5ArrayView] = []
    var shapePointers: [UnsafeMutablePointer<Int64>] = []
    defer { shapePointers.forEach { $0.deallocate() } }
    for (i, array) in arrays.enumerated() {
        let shape = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, shapes[i].count))
        shape.initialize(from: shapes[i], count: shapes[i].count)
        shapePointers.append(shape)
        views.append(M5ArrayView(
            name: UnsafePointer(names[i]),
            dtype: array.data.scalarType.rawValue,
            ndim: UInt32(shapes[i].count),
            shape: UnsafePointer(shape),
            data: UnsafeRawPointer(array.data.baseAddress),
            nbytes: array.data.byteCount
        ))
    }
    return try withExtendedLifetime(arrays) {
        try views.withUnsafeBufferPointer { try body($0.baseAddress, $0.count) }
    }
}
