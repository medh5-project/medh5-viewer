import Foundation

/// Data-parallel loops over `DispatchQueue.concurrentPerform`, with
/// cancellation and error propagation.
enum Parallel {
    static let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    /// Splits `range` into contiguous pieces of at least `grain` elements (at
    /// most a few per worker) and runs `body` on each, concurrently; returns
    /// the results in order. The first error thrown (or cancellation) is
    /// rethrown after every piece has finished. Completed pieces are reported
    /// as progress of the control's current phase.
    static func map<T>(
        _ range: Range<Int>,
        grain: Int = 1,
        control: OperationControl? = nil,
        _ body: (Range<Int>) throws -> T
    ) throws -> [T] {
        let n = range.count
        guard n > 0 else { return [] }
        let pieces = min(workerCount * 4, max(1, n / max(1, grain)))
        if pieces == 1 {
            try control.checkCancellation()
            let r = try body(range)
            control.reportPhase(1)
            return [r]
        }
        let failure = FailureBox()
        let done = Counter()
        var results = [T?](repeating: nil, count: pieces)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: pieces) { c in
                if failure.hasFailed { return }
                if control.isCancelled { failure.record(EditingError.cancelled); return }
                let a = range.lowerBound + n * c / pieces
                let b = range.lowerBound + n * (c + 1) / pieces
                do { out[c] = try body(a..<b) } catch { failure.record(error) }
                if let control { control.reportPhase(Double(done.increment()) / Double(pieces)) }
            }
        }
        if let error = failure.error { throw error }
        return results.map { $0! }
    }

    /// `map` without results.
    static func forEach(
        _ range: Range<Int>,
        grain: Int = 1,
        control: OperationControl? = nil,
        _ body: (Range<Int>) throws -> Void
    ) throws {
        _ = try map(range, grain: grain, control: control, body)
    }

    /// Runs `body(i)` for every `i` in `0 ..< count` concurrently (no
    /// cancellation, no errors): for short kernels.
    static func perform(_ count: Int, _ body: (Int) -> Void) {
        if count <= 0 { return }
        if count == 1 { body(0); return }
        DispatchQueue.concurrentPerform(iterations: count, execute: body)
    }
}

/// A thread-safe counter.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Increments and returns the new value.
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// The first error of a parallel loop.
final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    func record(_ error: Error) {
        lock.lock()
        if stored == nil { stored = error }
        lock.unlock()
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var hasFailed: Bool { error != nil }
}

/// A heap buffer of `count` elements, freed on deinit: scratch memory for
/// parallel kernels, which write disjoint parts through `pointer`.
final class ScratchBuffer<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>
    let count: Int

    init(count: Int, repeating value: T) {
        self.count = count
        pointer = .allocate(capacity: max(1, count))
        pointer.initialize(repeating: value, count: max(1, count))
    }

    deinit {
        pointer.deinitialize(count: max(1, count))
        pointer.deallocate()
    }

    subscript(_ i: Int) -> T {
        get { pointer[i] }
        set { pointer[i] = newValue }
    }
}
