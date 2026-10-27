import Foundation
import Metal
import CoreGraphics
import simd
import MedH5Core

/// Renders a ``VolumeScene``: GPU ray casting of the image volume (MIP,
/// MinIP, average, DVR, isosurface) and of segmentation surfaces, composited
/// depth-correctly with meshes and slice planes.
///
/// Three passes per frame:
/// 1. meshes and planes, 4× MSAA, resolving colour and (nearest) depth;
/// 2. rays from the camera through every pixel of a target at
///    `quality.resolutionScale`, clipped by the volume, the clip box and
///    plane, stopping at the mesh depth; front-to-back compositing with
///    early termination;
/// 3. a composite of rays over meshes over the background into the
///    drawable (upsampling the rays bilinearly).
///
/// Not thread-safe; one per view.
public final class VolumeRenderer {
    /// The context the renderer draws with.
    public let context: RenderContext
    /// The format of the targets it draws into.
    public let colorPixelFormat: MTLPixelFormat
    /// Jump over bricks (8³ voxels) that cannot contribute (on by default;
    /// the image is the same either way, only faster).
    public var skipsEmptySpace = true

    private let sampleCount: Int
    private static let meshColorFormat: MTLPixelFormat = .rgba8Unorm
    private static let rayFormat: MTLPixelFormat = .rgba16Float

    private var rayTexture: (any MTLTexture)?
    private var meshColor: (any MTLTexture)?
    private var meshDepth: (any MTLTexture)?
    private var msaaColor: (any MTLTexture)?
    private var msaaDepth: (any MTLTexture)?
    private var transferCache: (function: TransferFunction, texture: any MTLTexture)?
    private let indicators: LabelIndicatorCache
    private let imageBricks: ImageBrickCache

    /// A renderer for targets of `colorPixelFormat`; builds its pipelines.
    public init(context: RenderContext, colorPixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.context = context
        self.colorPixelFormat = colorPixelFormat
        sampleCount = context.supportsDepthResolve && context.device.supportsTextureSampleCount(4) ? 4 : 1
        indicators = LabelIndicatorCache(context: context)
        imageBricks = ImageBrickCache(context: context)
        try prepare()
    }

    // MARK: Pipelines

    private func rayPipeline() throws -> any MTLRenderPipelineState {
        try context.renderPipeline("volume.raycast") { d in
            d.vertexFunction = try context.function("fullscreen_vertex")
            d.fragmentFunction = try context.function("volume_raycast_fragment")
            d.colorAttachments[0].pixelFormat = Self.rayFormat
        }
    }

    private func compositePipeline() throws -> any MTLRenderPipelineState {
        try context.renderPipeline("volume.composite.\(colorPixelFormat.rawValue)") { d in
            d.vertexFunction = try context.function("fullscreen_vertex")
            d.fragmentFunction = try context.function("volume_composite_fragment")
            d.colorAttachments[0].pixelFormat = colorPixelFormat
        }
    }

    private func meshPipeline() throws -> any MTLRenderPipelineState {
        try context.renderPipeline("mesh.\(sampleCount)") { d in
            d.vertexFunction = try context.function("mesh_vertex")
            d.fragmentFunction = try context.function("mesh_fragment")
            d.colorAttachments[0].pixelFormat = Self.meshColorFormat
            RenderContext.configurePremultipliedBlending(d.colorAttachments[0])
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = sampleCount
        }
    }

    private func planePipeline() throws -> any MTLRenderPipelineState {
        try context.renderPipeline("plane.\(sampleCount)") { d in
            d.vertexFunction = try context.function("plane_vertex")
            d.fragmentFunction = try context.function("plane_fragment")
            d.colorAttachments[0].pixelFormat = Self.meshColorFormat
            RenderContext.configurePremultipliedBlending(d.colorAttachments[0])
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = sampleCount
        }
    }

    private var depthWrite: any MTLDepthStencilState {
        context.depthStencilState("mesh.depthWrite") { d in
            d.depthCompareFunction = .lessEqual
            d.isDepthWriteEnabled = true
        }
    }

    private var depthTestOnly: any MTLDepthStencilState {
        context.depthStencilState("mesh.depthTest") { d in
            d.depthCompareFunction = .lessEqual
            d.isDepthWriteEnabled = false
        }
    }

    /// Builds every pipeline this renderer uses.
    public func prepare() throws {
        _ = try rayPipeline()
        _ = try compositePipeline()
        _ = try meshPipeline()
        _ = try planePipeline()
        _ = depthWrite
        _ = depthTestOnly
        _ = try context.computePipeline("label_indicator_kernel")
        _ = try context.computePipeline("brick_minmax_kernel")
        _ = try context.computePipeline("brick_occupancy_kernel")
    }

    /// GPU memory held by the renderer's caches (label indicators and
    /// empty-space brick maps), in bytes.
    public var cachedMemorySize: Int { indicators.allocatedSize + imageBricks.allocatedSize }

    /// The physical values that can make a sample visible (DVR: where the
    /// transfer function's opacity is not zero, with a margin of two table
    /// entries; isosurface: at or above the level), or `nil` when no value
    /// can be skipped.
    static func visiblePhysicalRange(_ scene: VolumeScene) -> (lower: Double, upper: Double)? {
        switch scene.mode {
        case .isosurface:
            return (scene.isoValue - 1e-6 * max(1, abs(scene.isoValue)), .infinity)
        case .dvr:
            let points = scene.transferFunction.opacityPoints.sorted { $0.value < $1.value }
            guard let first = points.firstIndex(where: { $0.opacity > 0 }),
                  let last = points.lastIndex(where: { $0.opacity > 0 }) else {
                return (.infinity, -.infinity)   // fully transparent: skip everything
            }
            let r = scene.transferFunction.valueRange
            let margin = 2 * (r.upperBound - r.lowerBound) / 1023
            let lower = first == 0 ? -Double.infinity : points[first - 1].value - margin
            let upper = last == points.count - 1 ? Double.infinity : points[last + 1].value + margin
            return (lower, upper)
        default:
            return nil
        }
    }

    // MARK: Targets

    private func texture(_ existing: (any MTLTexture)?, format: MTLPixelFormat, size: SIMD2<Int>, samples: Int = 1,
                         usage: MTLTextureUsage, storage: MTLStorageMode, label: String) throws -> any MTLTexture {
        if let t = existing, t.width == size.x, t.height == size.y, t.sampleCount == samples,
           t.pixelFormat == format { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, size.x),
                                                         height: max(1, size.y), mipmapped: false)
        if samples > 1 {
            d.textureType = .type2DMultisample
            d.sampleCount = samples
        }
        d.usage = usage
        d.storageMode = storage
        guard let t = context.device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("\(label) \(size)")
        }
        t.label = label
        return t
    }

    private func transferTexture(_ tf: TransferFunction) throws -> any MTLTexture {
        if let cache = transferCache, cache.function == tf { return cache.texture }
        let table = tf.table(entries: 1024)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1024, height: 1,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = context.device.makeTexture(descriptor: d) else {
            throw RenderError.allocationFailed("transfer function")
        }
        table.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, 1024, 1), mipmapLevel: 0, withBytes: raw.baseAddress!,
                      bytesPerRow: 1024 * 16)
        }
        t.label = "transfer function"
        transferCache = (tf, t)
        return t
    }

    // MARK: Rendering

    /// Encodes the scene into `target`. The viewport is the target's size;
    /// the caller commits `commandBuffer`.
    public func encode(scene: VolumeScene, to target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        var camera = scene.camera
        let full = SIMD2(target.width, target.height)
        camera.viewportSize = full
        let scale = min(1, max(0.1, scene.quality.resolutionScale))
        let raySize = SIMD2(max(1, Int((Double(full.x) * scale).rounded())), max(1, Int((Double(full.y) * scale).rounded())))

        rayTexture = try texture(rayTexture, format: Self.rayFormat, size: raySize, usage: [.renderTarget, .shaderRead],
                                 storage: .private, label: "volume rays")
        let meshes = scene.meshes.filter { $0.isVisible && $0.mesh.indexCount > 0 }
        let planes = scene.planes.filter { $0.polygon.count >= 3 }
        let hasMeshPass = !meshes.isEmpty || !planes.isEmpty
        if hasMeshPass {
            try encodeMeshPass(meshes: meshes, planes: planes, camera: camera, size: full, commandBuffer: commandBuffer)
        }
        try encodeRayPass(scene: scene, camera: camera, useMeshDepth: hasMeshPass, commandBuffer: commandBuffer)

        // Composite.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.allocationFailed("composite encoder")
        }
        encoder.label = "volume composite"
        encoder.setRenderPipelineState(try compositePipeline())
        let bg = scene.backgroundColor
        var cu = CompositeUniforms(background: SIMD4(Float(bg.x * bg.w), Float(bg.y * bg.w), Float(bg.z * bg.w), Float(bg.w)),
                                   hasMesh: hasMeshPass ? 1 : 0)
        encoder.setFragmentBytes(&cu, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        encoder.setFragmentTexture(rayTexture, index: 0)
        encoder.setFragmentTexture(hasMeshPass ? meshColor : context.dummy2DFloat, index: 1)
        encoder.setFragmentSamplerState(context.linearClampSampler, index: 0)
        encoder.setFragmentSamplerState(context.nearestClampSampler, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func encodeMeshPass(meshes: [MeshInstance], planes: [VolumePlane], camera: VolumeCamera, size: SIMD2<Int>,
                                commandBuffer: any MTLCommandBuffer) throws {
        meshColor = try texture(meshColor, format: Self.meshColorFormat, size: size, usage: [.renderTarget, .shaderRead],
                                storage: .private, label: "mesh colour")
        meshDepth = try texture(meshDepth, format: .depth32Float, size: size, usage: [.renderTarget, .shaderRead],
                                storage: .private, label: "mesh depth")
        let pass = MTLRenderPassDescriptor()
        if sampleCount > 1 {
            msaaColor = try texture(msaaColor, format: Self.meshColorFormat, size: size, samples: sampleCount,
                                    usage: .renderTarget, storage: .memoryless, label: "mesh colour MSAA")
            msaaDepth = try texture(msaaDepth, format: .depth32Float, size: size, samples: sampleCount,
                                    usage: .renderTarget, storage: .memoryless, label: "mesh depth MSAA")
            pass.colorAttachments[0].texture = msaaColor
            pass.colorAttachments[0].resolveTexture = meshColor
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.depthAttachment.texture = msaaDepth
            pass.depthAttachment.resolveTexture = meshDepth
            pass.depthAttachment.depthResolveFilter = .min
            pass.depthAttachment.storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = meshColor
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = meshDepth
            pass.depthAttachment.storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.allocationFailed("mesh encoder")
        }
        encoder.label = "meshes"
        let viewProjection = camera.viewProjection.float4x4
        let light = lightDirection(camera)
        let eye = camera.projection == .perspective ? SIMD4<Float>(SIMD3<Float>(camera.eye), 1) : SIMD4<Float>(SIMD3<Float>(camera.eye), 0)
        let forward = SIMD4<Float>(SIMD3<Float>(camera.forward), 0)
        encoder.setFrontFacing(.counterClockwise)

        func draw(_ m: MeshInstance, cull: MTLCullMode) {
            var u = MeshUniforms()
            u.viewProjection = viewProjection
            u.model = m.transform.float4x4
            u.normalMatrix = m.transform.inverse.transpose.float4x4
            u.color = SIMD4<Float>(m.color)
            u.eye = eye
            u.viewDirection = forward
            u.lightDirection = light
            u.material = m.material.vector
            encoder.setCullMode(cull)
            encoder.setVertexBuffer(m.mesh.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<MeshUniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: m.mesh.indexCount, indexType: .uint32,
                                          indexBuffer: m.mesh.indexBuffer, indexBufferOffset: 0)
        }

        // Opaque meshes write depth.
        encoder.setRenderPipelineState(try meshPipeline())
        encoder.setDepthStencilState(depthWrite)
        let opaque = meshes.filter { $0.color.w >= 0.999 }
        for m in opaque { draw(m, cull: m.cullsBackFaces ? .back : .none) }

        // Plane outlines write depth (so rays stop at them); fills and textures are blended.
        if !planes.isEmpty {
            encoder.setRenderPipelineState(try planePipeline())
            encoder.setCullMode(.none)
            for plane in planes {
                var verts = plane.polygon.map { p -> PlaneVertex in
                    var uv = SIMD2<Float>(0, 0)
                    if let cam = plane.textureCamera {
                        let px = cam.pixel(forWorld: p)
                        uv = SIMD2(Float(px.x / Double(cam.viewportSize.x)), Float(px.y / Double(cam.viewportSize.y)))
                    }
                    return PlaneVertex(position: SIMD4<Float>(SIMD3<Float>(p), 1), uv: SIMD4(uv.x, uv.y, 0, 0))
                }
                if plane.fillColor.w > 0 || plane.texture != nil {
                    var fan: [PlaneVertex] = []
                    for i in 1..<(verts.count - 1) { fan += [verts[0], verts[i], verts[i + 1]] }
                    var pu = PlaneUniforms(viewProjection: viewProjection, color: SIMD4<Float>(plane.fillColor),
                                           textured: plane.texture != nil ? 1 : 0)
                    if plane.texture != nil && plane.fillColor.w <= 0 { pu.color = SIMD4(1, 1, 1, 1) }
                    encoder.setDepthStencilState(pu.color.w >= 0.999 ? depthWrite : depthTestOnly)
                    encoder.setVertexBytes(&fan, length: fan.count * MemoryLayout<PlaneVertex>.stride, index: 0)
                    encoder.setVertexBytes(&pu, length: MemoryLayout<PlaneUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&pu, length: MemoryLayout<PlaneUniforms>.stride, index: 1)
                    encoder.setFragmentTexture(plane.texture ?? context.dummy2DFloat, index: 0)
                    encoder.setFragmentSamplerState(context.linearClampSampler, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fan.count)
                }
                if plane.outlineColor.w > 0 {
                    verts.append(verts[0])
                    var pu = PlaneUniforms(viewProjection: viewProjection, color: SIMD4<Float>(plane.outlineColor),
                                           textured: 0)
                    encoder.setDepthStencilState(depthWrite)
                    encoder.setVertexBytes(&verts, length: verts.count * MemoryLayout<PlaneVertex>.stride, index: 0)
                    encoder.setVertexBytes(&pu, length: MemoryLayout<PlaneUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&pu, length: MemoryLayout<PlaneUniforms>.stride, index: 1)
                    encoder.setFragmentTexture(context.dummy2DFloat, index: 0)
                    encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: verts.count)
                }
            }
        }

        // Translucent meshes, far to near, back faces before front faces.
        let translucent = meshes.filter { $0.color.w < 0.999 }.sorted { a, b in
            let ca = (a.mesh.bounds.min + a.mesh.bounds.max) / 2, cb = (b.mesh.bounds.min + b.mesh.bounds.max) / 2
            return simd_distance(a.transform.transformPoint(ca), camera.eye)
                > simd_distance(b.transform.transformPoint(cb), camera.eye)
        }
        if !translucent.isEmpty {
            encoder.setRenderPipelineState(try meshPipeline())
            encoder.setDepthStencilState(depthTestOnly)
            for m in translucent {
                draw(m, cull: .front)
                draw(m, cull: .back)
            }
        }
        encoder.endEncoding()
    }

    private func lightDirection(_ camera: VolumeCamera) -> SIMD4<Float> {
        let l = camera.orientation.act(simd_normalize(SIMD3<Double>(-0.35, 0.5, 1)))
        return SIMD4(Float(l.x), Float(l.y), Float(l.z), 0)
    }

    private func encodeRayPass(scene: VolumeScene, camera: VolumeCamera, useMeshDepth: Bool,
                               commandBuffer: any MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = rayTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        let labels = scene.labels.filter(\.isVisible).prefix(4)
        guard let reference = scene.image?.volume ?? labels.first?.volume else {
            // Nothing to cast: just clear the ray target.
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw RenderError.allocationFailed("ray encoder")
            }
            encoder.label = "volume rays (empty)"
            encoder.endEncoding()
            return
        }

        var u = VolumeUniforms()
        let vp = camera.viewProjection
        u.inverseViewProjection = vp.inverse.float4x4
        u.viewProjection = vp.float4x4
        let registration = scene.image?.registration ?? (scene.image == nil ? labels.first?.registration : nil)
            ?? matrix_identity_double4x4
        let worldToTexture = reference.geometry.worldToTexture * registration
        u.worldToTexture = worldToTexture.float4x4
        u.gradientToWorld = worldToTexture.gradientPullback.float4x4
        let n = reference.dimensions
        u.textureSize = SIMD4(Float(n.z), Float(n.y), Float(n.x), 0)
        let eye = camera.eye
        u.eye = SIMD4(Float(eye.x), Float(eye.y), Float(eye.z), camera.projection == .perspective ? 1 : 0)
        u.lightDirection = lightDirection(camera)
        let rs = rayTexture!
        u.viewport = SIMD4(Float(rs.width), Float(rs.height), 1 / Float(rs.width), 1 / Float(rs.height))

        var flags: VolumeFlags = [.jitter]
        if scene.shading.enabled { flags.insert(.shading) }
        if useMeshDepth { flags.insert(.meshDepth) }
        if scene.quality.samplesPerVoxel < 1.5 { flags.insert(.fast) }
        u.shading = SIMD4(Float(scene.shading.ambient), Float(scene.shading.diffuse), Float(scene.shading.specular),
                          Float(scene.shading.shininess))

        // Clipping.
        switch scene.clipBox {
        case .index(let lower, let upper):
            let toTex = reference.geometry.indexToTexture
            let a = toTex * SIMD4(lower, 1), b = toTex * SIMD4(upper, 1)
            let lo = simd_clamp(simd_min(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)), SIMD3(repeating: 0), SIMD3(repeating: 1))
            let hi = simd_clamp(simd_max(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)), SIMD3(repeating: 0), SIMD3(repeating: 1))
            u.clipTexMin = SIMD4(SIMD3<Float>(lo), 0)
            u.clipTexMax = SIMD4(SIMD3<Float>(hi), 0)
        case .world(let lower, let upper):
            flags.insert(.clipWorld)
            u.clipWorldMin = SIMD4(SIMD3<Float>(simd_min(lower, upper)), 0)
            u.clipWorldMax = SIMD4(SIMD3<Float>(simd_max(lower, upper)), 0)
        case nil:
            break
        }
        if let plane = scene.clipPlane {
            flags.insert(.clipPlane)
            u.clipPlane = SIMD4(Float(plane.normal.x), Float(plane.normal.y), Float(plane.normal.z),
                                Float(-simd_dot(plane.normal, plane.point)))
        }

        // Sampling.
        let spacings = [reference.geometry.paddedSpacing.min()] + labels.map { $0.volume.geometry.paddedSpacing.min() }
        let minSpacing = max(1e-6, spacings.min() ?? 1)
        let step = scene.stepSize ?? (minSpacing / max(0.25, scene.quality.samplesPerVoxel))
        u.stepSize = Float(step)
        let b = reference.geometry.worldBounds
        let diagonal = simd_length(b.max - b.min)
        u.maxSteps = Int32(min(16384, Int(diagonal / step) + 16))

        // Image.
        var imageBrickTexture: (any MTLTexture)?
        if let image = scene.image {
            flags.insert(.image)
            let v = image.volume
            u.valueMap = SIMD4(Float(v.texelScale * image.rescaleSlope),
                               Float(v.texelOffset * image.rescaleSlope + image.rescaleIntercept),
                               Float(image.windowCenter - image.windowWidth / 2),
                               Float(1 / max(1e-9, image.windowWidth)))
            if image.invert { flags.insert(.invert) }
            u.interpolation = v.isFilterable ? 1 : 2
            u.lutRow = context.colormaps.textureRow(of: image.colormap)
            let tfRange = scene.transferFunction.valueRange
            let tfWidth = max(1e-9, tfRange.upperBound - tfRange.lowerBound)
            u.tfMap = SIMD4(Float(tfRange.lowerBound), Float(1 / tfWidth),
                            Float(max(1e-6, scene.transferFunction.opacityUnitDistance)), Float(scene.isoValue))
            u.gradientScale = Float(1 / max(1e-9, 0.025 * tfWidth))
            if scene.mode == .isosurface { u.gradientScale = 1e9 }
            if let visible = Self.visiblePhysicalRange(scene) {
                // Physical → texel; the skip test compares brick texel ranges.
                let scale = v.texelScale * image.rescaleSlope
                let offset = v.texelOffset * image.rescaleSlope + image.rescaleIntercept
                func texel(_ p: Double) -> Float {
                    if p == .infinity { return scale >= 0 ? 3e38 : -3e38 }
                    if p == -.infinity { return scale >= 0 ? -3e38 : 3e38 }
                    return Float((p - offset) / (scale == 0 ? 1 : scale))
                }
                let a = texel(visible.lower), b = texel(visible.upper)
                u.visibleRange = SIMD4(scale >= 0 ? a : b, scale >= 0 ? b : a, 0, 0)
                if skipsEmptySpace {
                    imageBrickTexture = try imageBricks.bricks(for: v, commandBuffer: commandBuffer)
                    flags.insert(.skipEmptySpace)
                }
            }
        } else {
            u.tfMap = SIMD4(0, 1, 1, Float(scene.isoValue))
            if skipsEmptySpace { flags.insert(.skipEmptySpace) }
        }
        u.isoColor = SIMD4<Float>(scene.isoColor)
        switch scene.mode {
        case .mip: u.mode = 0
        case .minip: u.mode = 1
        case .average: u.mode = 2
        case .dvr: u.mode = 3
        case .isosurface: u.mode = 4
        }
        u.labelCount = Int32(labels.count)
        u.flags = flags.rawValue

        var lus = [VolumeLabelUniforms](repeating: VolumeLabelUniforms(), count: 4)
        var indicatorTextures: [(indicator: any MTLTexture, bricks: any MTLTexture)] = []
        for (i, l) in labels.enumerated() {
            l.lookupTable.synchronize()
            indicatorTextures.append(try indicators.indicator(volume: l.volume, table: l.lookupTable,
                                                              commandBuffer: commandBuffer))
            let w2t = l.volume.geometry.worldToTexture * (l.registration ?? matrix_identity_double4x4)
            lus[i].worldToTexture = w2t.float4x4
            lus[i].gradientToWorld = w2t.gradientPullback.float4x4
            let ln = l.volume.dimensions
            lus[i].textureSize = SIMD4(Float(ln.z), Float(ln.y), Float(ln.x), 0)
            lus[i].params = SIMD4(Float(min(1, max(0, l.opacity))), Float(0.4 * l.volume.geometry.paddedSpacing.min()), 0, 0)
        }

        // Compute passes (label indicators) are encoded above; now the rays.
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.allocationFailed("ray encoder")
        }
        encoder.label = "volume rays"
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(try rayPipeline())
        encoder.setFragmentBytes(&u, length: MemoryLayout<VolumeUniforms>.stride, index: 0)
        lus.withUnsafeBytes { raw in
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.setFragmentTexture(scene.image?.volume.texture ?? context.dummy3DFloat, index: 0)
        encoder.setFragmentTexture(try transferTexture(scene.transferFunction), index: 1)
        encoder.setFragmentTexture(context.colormaps.texture, index: 2)
        encoder.setFragmentTexture(useMeshDepth ? meshDepth : context.dummyDepth, index: 3)
        for i in 0..<4 {
            if i < labels.count {
                encoder.setFragmentTexture(labels[labels.startIndex + i].volume.texture, index: 4 + i)
                encoder.setFragmentTexture(labels[labels.startIndex + i].lookupTable.texture, index: 8 + i)
                encoder.setFragmentTexture(indicatorTextures[i].indicator, index: 12 + i)
                encoder.setFragmentTexture(indicatorTextures[i].bricks, index: 17 + i)
            } else {
                encoder.setFragmentTexture(context.dummy3DUInt, index: 4 + i)
                encoder.setFragmentTexture(context.dummy2DFloat, index: 8 + i)
                encoder.setFragmentTexture(context.dummy3DFloat, index: 12 + i)
                encoder.setFragmentTexture(context.dummy3DFloat, index: 17 + i)
            }
        }
        encoder.setFragmentTexture(imageBrickTexture ?? context.dummy3DFloat, index: 16)
        encoder.setFragmentSamplerState(context.linearClampSampler, index: 0)
        encoder.setFragmentSamplerState(context.nearestClampSampler, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Renders offscreen at the camera's viewport size and reads the pixels
    /// back (waits for the GPU).
    public func render(scene: VolumeScene) throws -> RenderedImage {
        let target = try RenderedImage.makeTarget(context: context, size: scene.camera.viewportSize,
                                                  format: colorPixelFormat)
        let cb = try context.makeCommandBuffer(label: "volume offscreen")
        try encode(scene: scene, to: target, commandBuffer: cb)
        return try RenderedImage.readback(texture: target, commandBuffer: cb, context: context)
    }

    /// Renders offscreen into a Core Graphics image.
    public func makeImage(scene: VolumeScene) throws -> CGImage {
        guard let image = try render(scene: scene).cgImage() else {
            throw RenderError.imageExport("could not make a CGImage")
        }
        return image
    }
}
