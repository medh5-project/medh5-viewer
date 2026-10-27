import Foundation

/// Errors raised by the rendering engine.
public enum RenderError: Error, CustomStringConvertible, Sendable {
    /// No Metal device is available (a headless or virtualised machine).
    case noMetalDevice
    /// The embedded Metal source failed to compile; the compiler's message.
    case shaderCompilation(String)
    /// A render or compute pipeline could not be built.
    case pipelineCreation(name: String, message: String)
    /// A volume cannot be uploaded as a texture (shape, type or size).
    case unsupportedVolume(String)
    /// A region or argument is outside what the receiver holds.
    case invalidArgument(String)
    /// A GPU resource could not be allocated.
    case allocationFailed(String)
    /// A command buffer failed on the GPU.
    case commandBufferFailed(String)
    /// An image could not be encoded or written.
    case imageExport(String)

    public var description: String {
        switch self {
        case .noMetalDevice: return "no Metal device is available"
        case .shaderCompilation(let m): return "shader compilation failed: \(m)"
        case .pipelineCreation(let name, let m): return "pipeline \(name) could not be built: \(m)"
        case .unsupportedVolume(let m): return "unsupported volume: \(m)"
        case .invalidArgument(let m): return "invalid argument: \(m)"
        case .allocationFailed(let m): return "GPU allocation failed: \(m)"
        case .commandBufferFailed(let m): return "GPU command buffer failed: \(m)"
        case .imageExport(let m): return "image export failed: \(m)"
        }
    }
}
