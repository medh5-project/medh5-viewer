import Foundation

/// Errors the editing engine reports.
public enum EditingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The operation was cancelled through its `OperationControl`.
    case cancelled
    /// The class id is not in the model's class table.
    case unknownClass(UInt16)
    /// The class is locked: its voxels cannot be changed.
    case classLocked(UInt16)
    /// `0`, the ignore value or `65535` cannot be a class (spec §5.3).
    case reservedClassID(UInt16)
    /// The class table already holds this id.
    case duplicateClass(UInt16)
    /// A layer index outside the model's layers.
    case invalidLayer(Int)
    /// An edit does not fit this model (another grid, or voxels changed since
    /// it was computed).
    case editConflict(String)
    /// A volume of the wrong shape or type.
    case shapeMismatch(String)
    /// A voxel outside the grid.
    case outsideGrid(SIMD3<Int>)
    /// Any other invalid argument.
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .cancelled: return "the operation was cancelled"
        case .unknownClass(let id): return "class \(id) is not in the class table"
        case .classLocked(let id): return "class \(id) is locked"
        case .reservedClassID(let id): return "\(id) is reserved and cannot be a class (spec §5.3)"
        case .duplicateClass(let id): return "class \(id) already exists"
        case .invalidLayer(let l): return "layer \(l) does not exist"
        case .editConflict(let why): return "the edit does not apply: \(why)"
        case .shapeMismatch(let why): return why
        case .outsideGrid(let k): return "voxel \(k) is outside the grid"
        case .invalidArgument(let why): return why
        }
    }
}

/// Cooperative cancellation and progress for long operations.
///
/// Create one per operation, keep a reference to cancel it from any thread
/// (for example from `withTaskCancellationHandler`), and pass it to the
/// operation. Operations check `isCancelled` between slices or chunks and
/// throw `EditingError.cancelled`; they leave the model untouched, since they
/// only compute a `VoxelEdit`.
///
/// `progress` is called with a fraction in 0…1 from arbitrary worker
/// threads, increasing, at most every 1 % of the work; it must be
/// thread-safe (hop to the main actor to update UI). Operations made of
/// several stages divide the range into phases.
public final class OperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReported = -1.0
    private var phaseIndex = 0
    private var phaseCount = 1
    private let progress: (@Sendable (Double) -> Void)?

    public init(progress: (@Sendable (Double) -> Void)? = nil) {
        self.progress = progress
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Reports overall progress (0…1). Values below one already reported
    /// are ignored; reports are throttled to steps of 1 %.
    public func report(_ fraction: Double) {
        guard let progress else { return }
        let f = min(1, max(0, fraction))
        lock.lock()
        let send = f > lastReported && (f >= 1 || f - lastReported >= 0.01)
        if send { lastReported = f }
        lock.unlock()
        if send { progress(f) }
    }

    /// Throws `EditingError.cancelled` when cancelled.
    public func checkCancellation() throws {
        if isCancelled { throw EditingError.cancelled }
    }

    /// Starts phase `index` of `count`: phase-relative reports then map into
    /// `[index / count, (index + 1) / count]`.
    func beginPhase(_ index: Int, of count: Int) {
        lock.lock()
        phaseIndex = index
        phaseCount = max(1, count)
        lock.unlock()
        report(Double(index) / Double(max(1, count)))
    }

    /// Reports progress within the current phase.
    func reportPhase(_ fraction: Double) {
        lock.lock()
        let f = (Double(phaseIndex) + min(1, max(0, fraction))) / Double(phaseCount)
        lock.unlock()
        report(f)
    }
}

extension Optional where Wrapped == OperationControl {
    @inline(__always)
    func checkCancellation() throws {
        if let c = self, c.isCancelled { throw EditingError.cancelled }
    }

    @inline(__always)
    var isCancelled: Bool { self?.isCancelled ?? false }

    @inline(__always)
    func report(_ f: Double) { self?.report(f) }

    @inline(__always)
    func beginPhase(_ index: Int, of count: Int) { self?.beginPhase(index, of: count) }

    @inline(__always)
    func reportPhase(_ f: Double) { self?.reportPhase(f) }
}
