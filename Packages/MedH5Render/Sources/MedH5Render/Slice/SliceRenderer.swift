import Foundation
import Metal
import CoreGraphics
import simd
import MedH5Core

/// Renders a ``SliceScene`` into a texture: an MTKView drawable or an
/// offscreen target.
///
/// One render pass: each visible layer is a full-screen triangle whose
/// fragment shader maps the drawable pixel to the layer's texture through
/// its own matrix and composites "over" what is below (premultiplied
/// alpha, in tile memory); then the overlays (stencil-filled polygons and
/// signed-distance strokes and markers). Uniforms and overlay vertices live
/// in a ring of three buffers reused frame after frame, so drawing
/// allocates nothing in steady state.
///
/// A renderer is not thread-safe; use one per view, on one thread (the
/// main thread for views).
public final class SliceRenderer {
    /// The context the renderer draws with.
    public let context: RenderContext
    /// The format of the targets this renderer draws into.
    public let colorPixelFormat: MTLPixelFormat

    static let framesInFlight = 3
    private let inFlight = DispatchSemaphore(value: SliceRenderer.framesInFlight)
    private var frameIndex = 0
    private var uniformBuffers: [any MTLBuffer] = []
    private var overlayBuffers: [(any MTLBuffer)?] = []
    private var stencilTexture: (any MTLTexture)?
    private var tessellator = OverlayTessellator()
    private var draws: [(kind: LayerKind, offset: Int, volume: any MTLTexture, lut: any MTLTexture,
                         field: (any MTLTexture)?)] = []

    private static let uniformStride = (MemoryLayout<SliceLayerUniforms>.stride + 255) / 256 * 256

    /// A renderer for targets of `colorPixelFormat` (the view's drawable
    /// format); builds its pipelines.
    public init(context: RenderContext, colorPixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.context = context
        self.colorPixelFormat = colorPixelFormat
        for _ in 0..<Self.framesInFlight {
            guard let b = context.device.makeBuffer(length: Self.uniformStride * 16, options: .storageModeShared) else {
                throw RenderError.allocationFailed("slice uniforms")
            }
            b.label = "slice uniforms"
            uniformBuffers.append(b)
            overlayBuffers.append(nil)
        }
        try prepare()
    }

    // MARK: Pipelines

    private enum LayerKind: String {
        case image = "slice_image_fragment"
        case label = "slice_label_fragment"
        case probability = "slice_probability_fragment"
    }

    private func layerPipeline(_ kind: LayerKind) throws -> any MTLRenderPipelineState {
        try context.renderPipeline("slice.\(kind.rawValue).\(colorPixelFormat.rawValue)") { d in
            d.vertexFunction = try context.function("fullscreen_vertex")
            d.fragmentFunction = try context.function(kind.rawValue)
            d.colorAttachments[0].pixelFormat = colorPixelFormat
            RenderContext.configurePremultipliedBlending(d.colorAttachments[0])
            d.stencilAttachmentPixelFormat = .stencil8
        }
    }

    private func overlayPipeline(stencilOnly: Bool) throws -> any MTLRenderPipelineState {
        try context.renderPipeline("overlay.\(stencilOnly ? "stencil" : "color").\(colorPixelFormat.rawValue)") { d in
            d.vertexFunction = try context.function("overlay_vertex")
            d.fragmentFunction = try context.function("overlay_fragment")
            d.colorAttachments[0].pixelFormat = colorPixelFormat
            if stencilOnly {
                d.colorAttachments[0].writeMask = []
            } else {
                RenderContext.configurePremultipliedBlending(d.colorAttachments[0])
            }
            d.stencilAttachmentPixelFormat = .stencil8
        }
    }

    private var noStencil: any MTLDepthStencilState {
        context.depthStencilState("slice.noStencil") { _ in }
    }

    private var stencilInvert: any MTLDepthStencilState {
        context.depthStencilState("slice.stencilInvert") { d in
            let s = MTLStencilDescriptor()
            s.stencilCompareFunction = .always
            s.depthStencilPassOperation = .invert
            s.readMask = 0xFF
            s.writeMask = 0xFF
            d.frontFaceStencil = s
            d.backFaceStencil = s
        }
    }

    private var stencilCover: any MTLDepthStencilState {
        context.depthStencilState("slice.stencilCover") { d in
            let s = MTLStencilDescriptor()
            s.stencilCompareFunction = .notEqual
            s.stencilFailureOperation = .keep
            s.depthStencilPassOperation = .zero
            s.readMask = 0xFF
            s.writeMask = 0xFF
            d.frontFaceStencil = s
            d.backFaceStencil = s
        }
    }

    /// Builds every pipeline this renderer uses (done on creation; calling
    /// it again is free).
    public func prepare() throws {
        _ = try layerPipeline(.image)
        _ = try layerPipeline(.label)
        _ = try layerPipeline(.probability)
        _ = try overlayPipeline(stencilOnly: false)
        _ = try overlayPipeline(stencilOnly: true)
        _ = noStencil
        _ = stencilInvert
        _ = stencilCover
    }

    // MARK: Rendering

    /// Encodes the scene into `target` (a `colorPixelFormat` texture, e.g. a
    /// drawable's). The viewport is the target's size; the camera's centre
    /// and zoom are kept. The caller commits `commandBuffer` (and presents).
    public func encode(scene: SliceScene, to target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        inFlight.wait()
        var signalled = false
        let semaphore = inFlight
        defer { if !signalled { semaphore.signal() } }

        var camera = scene.camera
        camera.viewportSize = SIMD2(target.width, target.height)
        let slot = frameIndex % Self.framesInFlight
        frameIndex += 1

        // Uniforms (into this frame's ring slot; grown only when layers are added).
        var visibleCount = 0
        for layer in scene.layers where layer.isVisible { visibleCount += 1 }
        let needed = max(1, visibleCount) * Self.uniformStride
        if uniformBuffers[slot].length < needed {
            guard let b = context.device.makeBuffer(length: needed * 2, options: .storageModeShared) else {
                throw RenderError.allocationFailed("slice uniforms")
            }
            b.label = "slice uniforms"
            uniformBuffers[slot] = b
        }
        let uniforms = uniformBuffers[slot]
        draws.removeAll(keepingCapacity: true)
        for layer in scene.layers where layer.isVisible {
            let (kind, u, lut, field) = layerUniforms(layer, scene: scene, camera: camera)
            let offset = draws.count * Self.uniformStride
            uniforms.contents().advanced(by: offset).storeBytes(of: u, as: SliceLayerUniforms.self)
            draws.append((kind, offset, layer.volume.texture, lut, field))
        }

        // Overlays (the tessellator's storage is reused frame to frame).
        tessellator.begin(camera: camera, tolerance: scene.effectiveOverlayTolerance, slab: scene.slab)
        for overlay in scene.overlays { tessellator.add(overlay) }
        tessellator.finish()
        var overlayBuffer: (any MTLBuffer)?
        let vertexCount = tessellator.batch.vertices.count
        if vertexCount > 0 {
            let bytes = vertexCount * MemoryLayout<OverlayVertex>.stride
            if (overlayBuffers[slot]?.length ?? 0) < bytes {
                var size = 1 << 16
                while size < bytes { size <<= 1 }
                overlayBuffers[slot] = context.device.makeBuffer(length: size, options: .storageModeShared)
                overlayBuffers[slot]?.label = "overlay vertices"
            }
            if let b = overlayBuffers[slot] {
                tessellator.batch.vertices.withUnsafeBytes { raw in
                    b.contents().copyMemory(from: raw.baseAddress!, byteCount: bytes)
                }
                overlayBuffer = b
            }
        }

        // Pass.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = scene.backgroundColor
        pass.colorAttachments[0].clearColor = MTLClearColor(red: bg.x * bg.w, green: bg.y * bg.w,
                                                            blue: bg.z * bg.w, alpha: bg.w)
        pass.stencilAttachment.texture = try stencil(width: target.width, height: target.height)
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        pass.stencilAttachment.clearStencil = 0
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.allocationFailed("render encoder")
        }
        encoder.label = "slice"
        encoder.setDepthStencilState(noStencil)
        encoder.setFragmentSamplerState(context.linearClampSampler, index: 0)
        for (kind, offset, volume, lut, field) in draws {
            encoder.setRenderPipelineState(try layerPipeline(kind))
            encoder.setFragmentBuffer(uniforms, offset: offset, index: 0)
            encoder.setFragmentTexture(volume, index: 0)
            encoder.setFragmentTexture(lut, index: 1)
            encoder.setFragmentTexture(field ?? context.dummy3DFloat, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if let overlayBuffer {
            var ou = OverlayUniforms(viewportSize: SIMD2(Float(target.width), Float(target.height)))
            encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&ou, length: MemoryLayout<OverlayUniforms>.stride, index: 1)
            let color = try overlayPipeline(stencilOnly: false)
            let stencilOnly = try overlayPipeline(stencilOnly: true)
            encoder.setStencilReferenceValue(0)
            for command in tessellator.batch.commands {
                switch command {
                case .primitives(let range):
                    encoder.setRenderPipelineState(color)
                    encoder.setDepthStencilState(noStencil)
                    encoder.drawPrimitives(type: .triangle, vertexStart: range.lowerBound, vertexCount: range.count)
                case .fill(let stencilRange, let coverRange):
                    encoder.setRenderPipelineState(stencilOnly)
                    encoder.setDepthStencilState(stencilInvert)
                    encoder.drawPrimitives(type: .triangle, vertexStart: stencilRange.lowerBound,
                                           vertexCount: stencilRange.count)
                    encoder.setRenderPipelineState(color)
                    encoder.setDepthStencilState(stencilCover)
                    encoder.drawPrimitives(type: .triangle, vertexStart: coverRange.lowerBound,
                                           vertexCount: coverRange.count)
                }
            }
        }
        encoder.endEncoding()

        signalled = true
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
    }

    /// Renders offscreen at the camera's viewport size and reads the pixels
    /// back (waits for the GPU).
    public func render(scene: SliceScene) throws -> RenderedImage {
        let target = try RenderedImage.makeTarget(context: context, size: scene.camera.viewportSize,
                                                  format: colorPixelFormat)
        let cb = try context.makeCommandBuffer(label: "slice offscreen")
        try encode(scene: scene, to: target, commandBuffer: cb)
        return try RenderedImage.readback(texture: target, commandBuffer: cb, context: context)
    }

    /// Renders offscreen into a Core Graphics image (screenshots, exports).
    public func makeImage(scene: SliceScene) throws -> CGImage {
        guard let image = try render(scene: scene).cgImage() else {
            throw RenderError.imageExport("could not make a CGImage")
        }
        return image
    }

    private func stencil(width: Int, height: Int) throws -> any MTLTexture {
        if let s = stencilTexture, s.width == width, s.height == height { return s }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: width, height: height,
                                                         mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .memoryless
        guard let t = context.device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("stencil \(width)×\(height)")
        }
        stencilTexture = t
        return t
    }

    // MARK: Layer uniforms

    private func layerUniforms(_ layer: SliceLayer, scene: SliceScene, camera: SliceCamera)
        -> (LayerKind, SliceLayerUniforms, any MTLTexture, (any MTLTexture)?) {
        let volume = layer.volume
        let placement = layer.placement
        let registration = placement.registration ?? matrix_identity_double4x4
        let worldToTexture = volume.geometry.worldToTexture * registration
        let pixelToWorld = camera.pixelToWorld
        var u = SliceLayerUniforms()
        u.pixelToTexture = (worldToTexture * pixelToWorld).float4x4
        u.pixelToWorld = pixelToWorld.float4x4
        u.worldToTexture = worldToTexture.float4x4
        let n = volume.dimensions
        u.textureSize = SIMD4(Float(n.z), Float(n.y), Float(n.x), 0)
        u.pixelsPerPoint = Float(camera.pixelsPerPoint)
        var flags: SliceLayerFlags = []
        var field: (any MTLTexture)?
        if let d = placement.displacement {
            flags.insert(.field)
            u.worldToField = d.geometry.worldToTexture.float4x4
            field = d.texture
        }
        func interpolationCode(_ i: Interpolation) -> Int32 {
            switch i {
            case .nearest: return 0
            case .linear: return volume.isFilterable ? 1 : 2
            case .cubic: return volume.isFilterable ? 3 : 2
            }
        }
        func valueMap(slope: Double, intercept: Double) -> SIMD4<Float> {
            SIMD4(Float(volume.texelScale * slope), Float(volume.texelOffset * slope + intercept), 0, 0)
        }
        let atlas = context.colormaps

        switch layer {
        case .image(let l):
            let width = max(abs(l.windowWidth), 1e-9)
            let low = l.windowCenter - width / 2
            u.window = SIMD4(Float(low), Float(1 / width), Float(l.threshold ?? 0), Float(min(1, max(0, l.opacity))))
            if l.threshold != nil { flags.insert(.threshold) }
            if l.invert { flags.insert(.invert) }
            u.interpolation = interpolationCode(l.interpolation)
            let lut: any MTLTexture
            if volume.content == .rgb {
                flags.insert(.rgb)
                u.valueMap = SIMD4(Float(volume.texelScale), Float(volume.texelOffset), 0, 0)
                lut = atlas.texture
            } else {
                u.valueMap = valueMap(slope: l.rescaleSlope, intercept: l.rescaleIntercept)
                if let custom = l.lookupTable {
                    lut = custom.texture
                    u.lutRow = custom.textureRow
                } else {
                    lut = atlas.texture
                    u.lutRow = atlas.textureRow(of: l.colormap)
                }
            }
            if scene.slab.isActive && l.usesSlab && volume.content != .rgb {
                // One sample per voxel layer along the normal (every layer of an
                // aligned grid is visited once), at most 256.
                let spacing = camera.voxelStep(of: volume.geometry)
                let samples = min(256, max(2, Int((scene.slab.thickness / max(1e-6, spacing)).rounded(.up)) + 1))
                let stepWorld = camera.normal * (scene.slab.thickness / Double(samples - 1))
                let stepTex = worldToTexture * SIMD4(stepWorld, 0)
                u.slabStep = SIMD4(Float(stepTex.x), Float(stepTex.y), Float(stepTex.z), 0)
                u.slabSamples = Int32(samples)
                switch scene.slab.mode {
                case .none: u.slabMode = 0
                case .maximum: u.slabMode = 1
                case .minimum: u.slabMode = 2
                case .mean: u.slabMode = 3
                }
            }
            u.flags = flags.rawValue
            return (.image, u, lut, field)

        case .label(let l):
            l.lookupTable.synchronize()
            switch l.style {
            case .fill: flags.insert(.fill)
            case .outline: flags.insert(.outline)
            case .fillAndOutline: flags.formUnion([.fill, .outline])
            }
            if l.showsIgnoreRegion { flags.insert(.showIgnore) }
            u.extra = SIMD4(Float(l.fillOpacity), Float(l.outlineOpacity),
                            Float(max(0.5, l.outlineWidth * camera.pixelsPerPoint)),
                            Float(l.ignoreHatchSpacing * camera.pixelsPerPoint))
            u.color = SIMD4<Float>(l.ignoreColor)
            u.ignoreID = Int32(l.ignoreID)
            u.interpolation = 0
            u.flags = flags.rawValue
            return (.label, u, l.lookupTable.texture, field)

        case .probability(let l):
            let width = max(l.range.upperBound - l.range.lowerBound, 1e-9)
            u.window = SIMD4(Float(l.range.lowerBound), Float(1 / width), Float(l.threshold),
                             Float(min(1, max(0, l.opacity))))
            u.valueMap = valueMap(slope: l.rescaleSlope, intercept: l.rescaleIntercept)
            u.interpolation = interpolationCode(l.interpolation)
            if l.showsFill { flags.insert(.fill) }
            if l.showsContour { flags.insert(.contour) }
            u.color = SIMD4<Float>(l.contourColor)
            u.extra = SIMD4(Float(max(0.5, l.contourWidth * camera.pixelsPerPoint)), 1, 0, 0)
            let lut: any MTLTexture
            if let custom = l.lookupTable {
                lut = custom.texture
                u.lutRow = custom.textureRow
            } else {
                lut = atlas.texture
                u.lutRow = atlas.textureRow(of: l.colormap)
            }
            u.flags = flags.rawValue
            return (.probability, u, lut, field)
        }
    }
}
