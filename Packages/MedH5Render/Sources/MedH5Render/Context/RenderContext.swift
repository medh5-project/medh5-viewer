import Foundation
import Metal
import MedH5Core

/// The Metal state every renderer, texture and view shares: the device, one
/// command queue, the shader library compiled from the embedded source, a
/// cache of pipeline and depth-stencil states, samplers and the colormap
/// atlas.
///
/// Make one per process with ``shared`` (the app), or one per test with
/// ``init(device:)``. The compiled library is cached per device, so extra
/// contexts are cheap. All members are safe to use from any thread; the
/// pipeline caches are guarded by a lock.
///
/// Everything submitted through ``commandQueue`` executes in order, which is
/// what makes an asynchronous texture upload or a partial label update
/// visible to the next frame without waiting on the CPU.
public final class RenderContext: @unchecked Sendable {
    /// The GPU.
    public let device: any MTLDevice
    /// The one queue uploads and renders are submitted to (in order).
    public let commandQueue: any MTLCommandQueue
    /// The shader library compiled at run time from the embedded MSL source.
    public let library: any MTLLibrary
    /// Whether `r32Float` / `rgba32Float` textures can be filtered linearly.
    /// When not, float volumes are interpolated manually in the shaders.
    public let supportsFloat32Filtering: Bool
    /// Whether multisampled depth can be resolved (used by the 3-D view to
    /// stop rays at anti-aliased mesh depth).
    public let supportsDepthResolve: Bool
    /// The built-in colormaps as one texture, a row per map.
    public let colormaps: ColormapAtlas
    /// Linear filtering, clamp to edge.
    public let linearClampSampler: any MTLSamplerState
    /// Nearest filtering, clamp to edge.
    public let nearestClampSampler: any MTLSamplerState

    // Placeholders bound to texture slots a shader declares but a draw does
    // not use, so every argument is always bound.
    let dummy3DFloat: any MTLTexture
    let dummy3DUInt: any MTLTexture
    let dummy2DFloat: any MTLTexture
    let dummyDepth: any MTLTexture

    private let lock = NSLock()
    private var renderPipelines: [String: any MTLRenderPipelineState] = [:]
    private var computePipelines: [String: any MTLComputePipelineState] = [:]
    private var depthStencilStates: [String: any MTLDepthStencilState] = [:]

    /// The process-wide context on the system's default GPU, or `nil` when
    /// the machine has no Metal device.
    public static let shared: RenderContext? = { try? RenderContext() }()

    /// ``shared``, or ``RenderError/noMetalDevice``.
    public static func requireShared() throws -> RenderContext {
        guard let s = shared else { throw RenderError.noMetalDevice }
        return s
    }

    /// Makes a context on `device` (the system default when `nil`).
    public init(device: (any MTLDevice)? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noMetalDevice
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RenderError.allocationFailed("command queue")
        }
        queue.label = "MedH5Render.queue"
        commandQueue = queue
        library = try ShaderLibrary.library(for: device)
        supportsFloat32Filtering = device.supports32BitFloatFiltering
        supportsDepthResolve = device.supportsFamily(.apple3)

        let linear = MTLSamplerDescriptor()
        linear.minFilter = .linear
        linear.magFilter = .linear
        linear.sAddressMode = .clampToEdge
        linear.tAddressMode = .clampToEdge
        linear.rAddressMode = .clampToEdge
        linear.label = "linearClamp"
        let nearest = MTLSamplerDescriptor()
        nearest.minFilter = .nearest
        nearest.magFilter = .nearest
        nearest.sAddressMode = .clampToEdge
        nearest.tAddressMode = .clampToEdge
        nearest.rAddressMode = .clampToEdge
        nearest.label = "nearestClamp"
        guard let ls = device.makeSamplerState(descriptor: linear),
              let ns = device.makeSamplerState(descriptor: nearest) else {
            throw RenderError.allocationFailed("sampler states")
        }
        linearClampSampler = ls
        nearestClampSampler = ns

        dummy3DFloat = try RenderContext.makeDummy(device, type: .type3D, format: .r16Float)
        dummy3DUInt = try RenderContext.makeDummy(device, type: .type3D, format: .r16Uint)
        dummy2DFloat = try RenderContext.makeDummy(device, type: .type2D, format: .rgba8Unorm)
        dummyDepth = try RenderContext.makeDummy(device, type: .type2D, format: .depth32Float)
        colormaps = try ColormapAtlas(device: device)
    }

    private static func makeDummy(_ device: any MTLDevice, type: MTLTextureType,
                                  format: MTLPixelFormat) throws -> any MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = type
        d.pixelFormat = format
        d.width = 1
        d.height = 1
        d.depth = 1
        d.storageMode = .private
        d.usage = format == .depth32Float ? [.shaderRead, .renderTarget] : [.shaderRead]
        guard let t = device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("placeholder texture")
        }
        t.label = "placeholder \(format.rawValue)"
        return t
    }

    // MARK: Functions and pipelines

    /// A function from the compiled library.
    func function(_ name: String) throws -> any MTLFunction {
        guard let f = library.makeFunction(name: name) else {
            throw RenderError.pipelineCreation(name: name, message: "no function named \(name) in the library")
        }
        return f
    }

    /// A cached render pipeline: built once per `key` by `configure`.
    func renderPipeline(
        _ key: String,
        configure: (MTLRenderPipelineDescriptor) throws -> Void
    ) throws -> any MTLRenderPipelineState {
        lock.lock()
        if let p = renderPipelines[key] {
            lock.unlock()
            return p
        }
        lock.unlock()
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = key
        try configure(descriptor)
        let state: any MTLRenderPipelineState
        do {
            state = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RenderError.pipelineCreation(name: key, message: "\(error)")
        }
        lock.lock()
        renderPipelines[key] = state
        lock.unlock()
        return state
    }

    /// A cached compute pipeline for a kernel function.
    func computePipeline(_ functionName: String) throws -> any MTLComputePipelineState {
        lock.lock()
        if let p = computePipelines[functionName] {
            lock.unlock()
            return p
        }
        lock.unlock()
        let f = try function(functionName)
        let state: any MTLComputePipelineState
        do {
            state = try device.makeComputePipelineState(function: f)
        } catch {
            throw RenderError.pipelineCreation(name: functionName, message: "\(error)")
        }
        lock.lock()
        computePipelines[functionName] = state
        lock.unlock()
        return state
    }

    /// A cached depth-stencil state.
    func depthStencilState(_ key: String, configure: (MTLDepthStencilDescriptor) -> Void) -> any MTLDepthStencilState {
        lock.lock()
        defer { lock.unlock() }
        if let s = depthStencilStates[key] { return s }
        let d = MTLDepthStencilDescriptor()
        d.label = key
        configure(d)
        guard let s = device.makeDepthStencilState(descriptor: d) else {
            fatalError("MedH5Render: depth-stencil state \(key) could not be made")
        }
        depthStencilStates[key] = s
        return s
    }

    /// Blending for premultiplied colour composited "over" what is there.
    static func configurePremultipliedBlending(_ attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    // MARK: Command buffers

    /// A new command buffer on ``commandQueue``.
    public func makeCommandBuffer(label: String? = nil) throws -> any MTLCommandBuffer {
        guard let cb = commandQueue.makeCommandBuffer() else {
            throw RenderError.allocationFailed("command buffer")
        }
        if let label { cb.label = label }
        return cb
    }

    /// Blocks until everything submitted so far has executed (an empty
    /// command buffer committed and waited on; the queue runs in order).
    public func waitUntilIdle() {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        cb.label = "MedH5Render.idle"
        cb.commit()
        cb.waitUntilCompleted()
    }
}
