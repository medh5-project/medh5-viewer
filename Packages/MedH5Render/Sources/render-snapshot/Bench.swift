import Foundation
import Metal
import simd
import MedH5Core
import MedH5Render

/// Upload and frame-time measurements on a 512³ int16 phantom.
struct Bench {
    let context: RenderContext

    func run() throws {
        var start = Date()
        let phantom = Phantom.make(shape: SIMD3(512, 512, 512), spacing: SIMD3(0.5, 0.45, 0.45), noise: true,
                                   partialVolume: false)
        log("phantom 512³ generated in \(ms(since: start))")

        // Upload: the int16 CT (zero-copy blit), two label layers.
        start = Date()
        let ct = try VolumeTexture(context: context, image: phantom.ct)
        ct.waitUntilUploaded()
        let ctUpload = Date().timeIntervalSince(start)
        log(String(format: "upload 512³ int16 (%.0f MB): %.1f ms wall, texture %.0f MB",
                   Double(phantom.ct.data.byteCount) / 1e6, ctUpload * 1000, Double(ct.allocatedSize) / 1e6))
        start = Date()
        let organs = try VolumeTexture(context: context, labels: phantom.organs, geometry: phantom.grid)
        let lesions = try VolumeTexture(context: context, labels: phantom.lesions, geometry: phantom.grid)
        lesions.waitUntilUploaded()
        organs.waitUntilUploaded()
        log(String(format: "upload 2 × 512³ uint16 labels: %.1f ms wall", Date().timeIntervalSince(start) * 1000))
        // The staging path: the same volume as float32 (converted on the CPU, chunked).
        let asFloat = phantom.ct.data.converted(to: .float64)
        start = Date()
        let f = try VolumeTexture(context: context, scalars: asFloat, geometry: phantom.grid)
        f.waitUntilUploaded()
        log(String(format: "upload 512³ float64 → r32Float via staging: %.1f ms wall", Date().timeIntervalSince(start) * 1000))
        let pet = try VolumeTexture(context: context, image: phantom.pet)
        let prob = try VolumeTexture(context: context, image: phantom.probability)
        pet.waitUntilUploaded()
        prob.waitUntilUploaded()

        // Partial label update (a brush dab of 21³ voxels).
        let ptr = phantom.lesions.pointer(as: UInt16.self)
        for k0 in 250..<271 { for k1 in 250..<271 { for k2 in 250..<271 { ptr[(k0 * 512 + k1) * 512 + k2] = 10 } } }
        for attempt in 0..<4 {
            start = Date()
            try lesions.update(region: VoxelBox(origin: SIMD3(250 + attempt, 250, 250), size: SIMD3(21, 21, 21)),
                               from: phantom.lesions)
            let submit = Date().timeIntervalSince(start)
            lesions.waitUntilUploaded()
            log(String(format: "label region update 21³ (#%d): %.3f ms to submit, %.3f ms until done on the GPU",
                       attempt + 1, submit * 1000, Date().timeIntervalSince(start) * 1000))
        }

        // Slice redraw: 3 image layers + 2 label layers + overlays at 2560×1600.
        let organTable = try LabelLookupTable(context: context)
        let lesionTable = try LabelLookupTable(context: context)
        let renderer = try SliceRenderer(context: context)
        for plane in ViewPlane.allCases {
            var cam = SliceCamera.standard(plane, grid: phantom.grid, viewportSize: SIMD2(2560, 1600), pixelsPerPoint: 2)
            cam.moveAlongNormal(by: simd_dot(phantom.lesionCenter - cam.center, cam.normal))
            var petLayer = ImageLayer(volume: pet, windowCenter: 5, windowWidth: 10, colormap: .hotIron, opacity: 0.6)
            petLayer.threshold = 1
            var scene = SliceScene(camera: cam, layers: [
                .image(ImageLayer(image: phantom.ct, volume: ct)),
                .image(petLayer),
                .image(ImageLayer(volume: prob, windowCenter: 0.5, windowWidth: 1, colormap: .viridis, opacity: 0.4)),
                .label(LabelLayer(volume: organs, lookupTable: organTable)),
                .label(LabelLayer(volume: lesions, lookupTable: lesionTable)),
            ])
            let mesh = SurfaceExtractor.surface(labels: phantom.organs, geometry: phantom.grid, classID: 1,
                                                options: SurfaceExtractionOptions(downsampleFactor: 2))
            scene.overlays = [
                .crosshair(at: phantom.lesionCenter, camera: cam),
                .meshContour(MeshSlicer(mesh: mesh), camera: cam, style: .stroke(SIMD4(0, 1, 0.5, 1))),
                Overlay(.markers((0..<50).map { phantom.lesionCenter + SIMD3(Double($0), 0, 0) }, shape: .circle,
                                 size: 8, filled: true), style: .stroke(SIMD4(1, 0, 1, 1)), depthPolicy: .always),
            ]
            let target = try makeTarget(SIMD2(2560, 1600))
            let (gpu, cpu) = try measure(frames: 60) { cb in try renderer.encode(scene: scene, to: target, commandBuffer: cb) }
            log(String(format: "slice %@ 2560×1600, 3 images + 2 labels + overlays: GPU %.2f ms median, encode %.2f ms",
                       plane.rawValue, gpu, cpu))
            if plane == .axial {
                scene.slab = SlabSettings(mode: .maximum, thickness: 20)
                let (g2, _) = try measure(frames: 30) { cb in try renderer.encode(scene: scene, to: target, commandBuffer: cb) }
                log(String(format: "slice axial with a 20 mm MIP slab on the image layers: GPU %.2f ms median", g2))
            }
        }

        // 3-D: DVR at 1000×800, interactive and full quality.
        let volume = try VolumeRenderer(context: context)
        let target = try makeTarget(SIMD2(1000, 800))
        var camera = VolumeCamera.framing(bounds: phantom.grid.worldBounds, from: .anterior, viewportSize: SIMD2(1000, 800))
        camera.orbit(byPixels: SIMD2(-60, -40))
        var scene = VolumeScene(camera: camera, image: VolumeImage(volume: ct, windowCenter: 300, windowWidth: 1200),
                                mode: .dvr, transferFunction: .preset(.ctBone))
        for (name, mode, tf) in [("DVR bone", VolumeRenderMode.dvr, TransferFunction.preset(.ctBone)),
                                 ("DVR soft tissue", .dvr, .preset(.ctSoftTissue)),
                                 ("DVR skin", .dvr, .preset(.ctSkin)),
                                 ("MIP", .mip, .preset(.ctBone)),
                                 ("isosurface", .isosurface, .preset(.ctBone))] {
            scene.mode = mode
            scene.transferFunction = tf
            scene.isoValue = 200
            for quality in [VolumeRenderQuality.interactive, .full] {
                scene.quality = quality
                let (gpu, _) = try measure(frames: 20) { cb in try volume.encode(scene: scene, to: target, commandBuffer: cb) }
                log(String(format: "3-D %@ 1000×800 %@: GPU %.2f ms median (%.0f fps)", name,
                           quality == .interactive ? "interactive" : "full", gpu, 1000 / gpu))
            }
        }
        scene.mode = .dvr
        scene.transferFunction = .preset(.ctBone)
        scene.labels = [VolumeLabelLayer(volume: lesions, lookupTable: lesionTable),
                        VolumeLabelLayer(volume: organs, lookupTable: organTable)]
        let liver = try GPUMesh(context: context, mesh: SurfaceExtractor.surface(labels: phantom.organs, geometry: phantom.grid,
                                                                                  classID: 1))
        scene.meshes = [MeshInstance(mesh: liver, color: SIMD4(0.8, 0.4, 0.3, 1))]
        for quality in [VolumeRenderQuality.interactive, .full] {
            scene.quality = quality
            let (gpu, _) = try measure(frames: 20) { cb in try volume.encode(scene: scene, to: target, commandBuffer: cb) }
            log(String(format: "3-D DVR + 2 label layers + mesh 1000×800 %@: GPU %.2f ms median (%.0f fps)",
                       quality == .interactive ? "interactive" : "full", gpu, 1000 / gpu))
        }

        // Marching cubes on the 512³ labels.
        start = Date()
        let surface = SurfaceExtractor.surface(labels: phantom.organs, geometry: phantom.grid, classID: 1)
        log(String(format: "marching cubes liver 512³ (+Taubin): %d triangles in %@", surface.triangleCount, ms(since: start)))
        start = Date()
        let coarse = SurfaceExtractor.surface(labels: phantom.organs, geometry: phantom.grid, classID: 1,
                                              options: SurfaceExtractionOptions(downsampleFactor: 2))
        log(String(format: "marching cubes liver 512³ downsampled ×2: %d triangles in %@", coarse.triangleCount,
                   ms(since: start)))
    }

    private func makeTarget(_ size: SIMD2<Int>) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.x, height: size.y,
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = context.device.makeTexture(descriptor: d) else { throw RenderError.allocationFailed("target") }
        return t
    }

    /// Median GPU time (ms) and mean encode time (ms) over `frames`.
    private func measure(frames: Int, _ encode: (any MTLCommandBuffer) throws -> Void) throws -> (Double, Double) {
        var gpu: [Double] = []
        var cpu = 0.0
        for i in 0..<(frames + 3) {
            let cb = try context.makeCommandBuffer()
            let t = Date()
            try encode(cb)
            let e = Date().timeIntervalSince(t)
            cb.commit()
            cb.waitUntilCompleted()
            if i >= 3 {
                gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
                cpu += e * 1000
            }
        }
        gpu.sort()
        return (gpu[gpu.count / 2], cpu / Double(frames))
    }
}
