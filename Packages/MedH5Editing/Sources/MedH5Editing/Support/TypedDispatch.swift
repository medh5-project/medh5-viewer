import Foundation
import MedH5Core

/// A kernel over a volume's elements as their Swift type. Unlike
/// `VoxelVisitor` (whose generic method is called through MedH5Core's
/// witness tables), `dispatch` switches on the type here, so each kernel is
/// specialised per element type in this module.
protocol TypedKernel {
    associatedtype Output
    func run<T: VoxelScalar>(_ values: UnsafePointer<T>) throws -> Output
}

extension VolumeData {
    func dispatch<K: TypedKernel>(_ kernel: K) throws -> K.Output {
        switch scalarType {
        case .bool, .uint8: return try kernel.run(UnsafePointer(pointer(as: UInt8.self)))
        case .int8: return try kernel.run(UnsafePointer(pointer(as: Int8.self)))
        case .uint16: return try kernel.run(UnsafePointer(pointer(as: UInt16.self)))
        case .int16: return try kernel.run(UnsafePointer(pointer(as: Int16.self)))
        case .uint32: return try kernel.run(UnsafePointer(pointer(as: UInt32.self)))
        case .int32: return try kernel.run(UnsafePointer(pointer(as: Int32.self)))
        case .uint64: return try kernel.run(UnsafePointer(pointer(as: UInt64.self)))
        case .int64: return try kernel.run(UnsafePointer(pointer(as: Int64.self)))
        case .float16: return try kernel.run(UnsafePointer(pointer(as: Float16.self)))
        case .float32: return try kernel.run(UnsafePointer(pointer(as: Float.self)))
        case .float64: return try kernel.run(UnsafePointer(pointer(as: Double.self)))
        }
    }
}
