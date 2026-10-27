import Foundation
import Metal
import simd
import MedH5Core
import MedH5Render

/// Renders the phantom through every view type and writes PNGs.
struct Snapshots {
    let context: RenderContext
    let output: URL
    let phantom: Phantom
    let ct: VolumeTexture
    let organs: VolumeTexture
    let lesions: VolumeTexture
    let pet: VolumeTexture
    let probability: VolumeTexture
    let organTable: LabelLookupTable
    let lesionTable: LabelLookupTable
    let liverMesh: TriangleMesh
    let slice: SliceRenderer
    let volume: VolumeRenderer
    let pixelsPerPoint = 2.0

    init(context: RenderContext, output: URL) throws {
        self.context = context
        self.output = output
        let start = Date()
        phantom = Phantom.make()
        log("phantom \(phantom.grid.spatialShape) in \(ms(since: start))")
        ct = try VolumeTexture(context: context, image: phantom.ct)
        organs = try VolumeTexture(context: context, labels: phantom.organs, geometry: phantom.grid)
        lesions = try VolumeTexture(context: context, labels: phantom.lesions, geometry: phantom.grid)
        pet = try VolumeTexture(context: context, image: phantom.pet)
        probability = try VolumeTexture(context: context, image: phantom.probability)
        organTable = try LabelLookupTable(context: context)
        lesionTable = try LabelLookupTable(context: context, colors: [
            Phantom.lesionClass: RGBA8(255, 225, 25), Phantom.rimClass: RGBA8(255, 120, 30),
        ])
        let t = Date()
        liverMesh = SurfaceExtractor.surface(labels: phantom.organs, geometry: phantom.grid,
                                             classID: Phantom.Organ.liver.rawValue,
                                             options: .display)
        log("liver surface: \(liverMesh.vertexCount) vertices, \(liverMesh.triangleCount) triangles in \(ms(since: t))")
        slice = try SliceRenderer(context: context)
        volume = try VolumeRenderer(context: context)
    }

    func write(_ image: RenderedImage, _ name: String) throws {
        let url = output.appendingPathComponent(name)
        try image.writePNG(to: url)
        log("wrote \(url.path)")
    }

    // MARK: Slices

    func camera(_ plane: ViewPlane, size: SIMD2<Int> = SIMD2(900, 900)) -> SliceCamera {
        SliceCamera.standard(plane, grid: phantom.grid, viewportSize: size, pixelsPerPoint: pixelsPerPoint)
    }

    func ctLayer(window: WindowPreset = WindowPreset(name: "Soft", center: 40, width: 400)) -> ImageLayer {
        ImageLayer(image: phantom.ct, volume: ct, window: window)
    }

    func organLayer(style: LabelDisplayStyle = .fillAndOutline) -> LabelLayer {
        LabelLayer(volume: organs, lookupTable: organTable, style: style, fillOpacity: 0.28)
    }

    func lesionLayer(style: LabelDisplayStyle = .fillAndOutline) -> LabelLayer {
        LabelLayer(volume: lesions, lookupTable: lesionTable, style: style, fillOpacity: 0.45, outlineWidth: 1.25)
    }

    func overlays(for camera: SliceCamera) -> [Overlay] {
        let c = phantom.lesionCenter
        var list: [Overlay] = []
        // Liver surface mesh as a contour.
        let slicer = MeshSlicer(mesh: liverMesh)
        list.append(.meshContour(slicer, camera: camera, style: .stroke(SIMD4(0.2, 1, 0.6, 0.9), width: 1)))
        // A box around the lesion (index box on the CT grid at voxel edges).
        let k = phantom.grid.index(fromWorld: c)
        let half = SIMD3(phantom.lesionRadius / 2.0, phantom.lesionRadius / 0.9, phantom.lesionRadius / 0.9) + 2
        list.append(Overlay(.box(OrientedBox(indexLower: (k - half).rounded(.down) - 0.5,
                                             indexUpper: (k + half).rounded(.up) + 0.5, grid: phantom.grid)),
                            style: OverlayStyle(color: SIMD4(1, 0.85, 0.2, 1), lineWidth: 1.5, dash: .short)))
        // A ruler across the liver with end ticks.
        let a = camera.projectOntoPlane(SIMD3(-95, -10, c.z)), b = camera.projectOntoPlane(SIMD3(-15, 25, c.z))
        list.append(Overlay(.segments([a, b]), style: .stroke(SIMD4(1, 1, 1, 0.95), width: 1.5), depthPolicy: .always))
        list.append(Overlay(.markers([a, b], shape: .plus, size: 9, filled: false),
                            style: .stroke(SIMD4(1, 1, 1, 1), width: 1.5), depthPolicy: .always))
        // A polygon with a hole, in the plane.
        let center = camera.world(atPixel: SIMD2(Double(camera.viewportSize.x) * 0.78, Double(camera.viewportSize.y) * 0.8))
        let r = camera.axes.right, d = camera.axes.down
        let outer = (0..<6).map { i -> SIMD3<Double> in
            let t = Double(i) / 6 * 2 * .pi
            return center + r * (cos(t) * 30) + d * (sin(t) * 22)
        }
        let inner = (0..<4).map { i -> SIMD3<Double> in
            let t = Double(i) / 4 * 2 * .pi + .pi / 4
            return center + r * (cos(t) * 10) + d * (sin(t) * 10)
        }
        list.append(Overlay(.polygon([outer, inner]),
                            style: OverlayStyle(color: SIMD4(0.4, 0.8, 1, 1), lineWidth: 1.5,
                                                fillColor: SIMD4(0.3, 0.6, 1, 0.35))))
        // Markers of every shape in a row.
        let row = camera.world(atPixel: SIMD2(Double(camera.viewportSize.x) * 0.12, Double(camera.viewportSize.y) * 0.08))
        for (i, shape) in MarkerShape.allCases.enumerated() {
            let p = row + r * (Double(i) * 14 * camera.millimetersPerPixel * pixelsPerPoint)
            list.append(Overlay(.markers([p], shape: shape, size: 10, filled: i % 2 == 0),
                                style: OverlayStyle(color: SIMD4(1, 0.4, 0.7, 1), lineWidth: 1.25,
                                                    fillColor: i % 2 == 0 ? SIMD4(1, 0.4, 0.7, 0.6) : nil)))
        }
        // A brush cursor (3-D sphere cross-section) and a dashed polyline.
        list.append(Overlay(.circle(center: c + SIMD3(30, 30, 0), radius: 9, sphere: true, filled: false),
                            style: OverlayStyle(color: SIMD4(1, 1, 0, 0.9), lineWidth: 1.25, dash: DashPattern(on: 5, off: 3)),
                            depthPolicy: .always))
        let path = (0..<20).map { i -> SIMD3<Double> in
            let t = Double(i) / 19
            return camera.projectOntoPlane(SIMD3(30 + 40 * t, -60 + 20 * sin(t * 6), c.z))
        }
        list.append(Overlay(.polyline(path, closed: false),
                            style: OverlayStyle(color: SIMD4(0.6, 1, 0.3, 1), lineWidth: 2, dash: .long)))
        // The crosshair through the lesion.
        list.append(.crosshair(at: c, camera: camera))
        return list
    }

    func slices() throws {
        for plane in ViewPlane.allCases {
            var cam = camera(plane)
            // Through the lesion.
            cam.center = cam.projectOntoPlane(cam.center) + cam.normal * simd_dot(phantom.lesionCenter - cam.center, cam.normal)
            cam.snapToVoxelCenters(of: phantom.grid)
            var scene = SliceScene(camera: cam, layers: [.image(ctLayer()), .label(organLayer()), .label(lesionLayer())])
            scene.overlays = overlays(for: cam)
            try write(slice.render(scene: scene), "slice_\(plane.rawValue).png")
        }
    }

    func fusion() throws {
        var cam = camera(.axial)
        cam.moveAlongNormal(by: simd_dot(phantom.lesionCenter - cam.center, cam.normal))
        cam.snapToVoxelCenters(of: phantom.grid)
        var petLayer = ImageLayer(volume: pet, windowCenter: 5, windowWidth: 10, colormap: .hotIron, opacity: 0.65)
        petLayer.threshold = 1.2
        let scene = SliceScene(camera: cam, layers: [.image(ctLayer()), .image(petLayer)])
        try write(slice.render(scene: scene), "slice_fusion_pet.png")
        // The same with a registration: the PET moved 12 mm left and rotated 5°.
        var moved = petLayer
        let t = simd_double4x4(simd_quatd(angle: 5 * .pi / 180, axis: SIMD3(0, 0, 1)))
        var shift = matrix_identity_double4x4
        shift.columns.3 = SIMD4(-12, 0, 0, 1)
        moved.placement = LayerPlacement(registration: shift * t)
        try write(slice.render(scene: SliceScene(camera: cam, layers: [.image(ctLayer()), .image(moved)])),
                  "slice_fusion_pet_registered.png")
    }

    func probabilityMap() throws {
        var cam = camera(.coronal)
        cam.moveAlongNormal(by: simd_dot(phantom.lesionCenter - cam.center, cam.normal))
        cam.center = cam.projectOntoPlane(phantom.lesionCenter)
        cam.millimetersPerPixel = 0.12
        cam.snapToVoxelCenters(of: phantom.grid)
        let prob = ProbabilityLayer(volume: probability, colormap: .plasma, range: 0.3...1, threshold: 0.5,
                                    opacity: 0.45, contourColor: SIMD4(0.2, 1, 1, 1), contourWidth: 1.5)
        let scene = SliceScene(camera: cam, layers: [.image(ctLayer()), .label(lesionLayer(style: .outline)),
                                                     .probability(prob)])
        try write(slice.render(scene: scene), "slice_probability.png")
    }

    func slab() throws {
        var cam = camera(.coronal)
        cam.moveAlongNormal(by: -10)
        var scene = SliceScene(camera: cam, layers: [.image(ctLayer(window: WindowPreset(name: "Lung", center: -500, width: 1400)))])
        scene.slab = SlabSettings(mode: .maximum, thickness: 30)
        try write(slice.render(scene: scene), "slice_slab_mip.png")
        scene.slab = SlabSettings(mode: .minimum, thickness: 30)
        try write(slice.render(scene: scene), "slice_slab_minip.png")
    }

    func oblique() throws {
        let q = simd_quatd(angle: 30 * .pi / 180, axis: SIMD3(1, 0.3, 0))
        let base = PlaneAxes.standard(.axial)
        var cam = SliceCamera(center: phantom.lesionCenter, axes: PlaneAxes(right: q.act(base.right), down: q.act(base.down)),
                              millimetersPerPixel: 0.3, viewportSize: SIMD2(900, 900), pixelsPerPoint: pixelsPerPoint)
        cam.center = phantom.lesionCenter + SIMD3(25, 15, 0)
        var scene = SliceScene(camera: cam, layers: [.image(ctLayer()), .label(organLayer()), .label(lesionLayer())])
        scene.overlays = overlays(for: cam)
        try write(slice.render(scene: scene), "slice_oblique.png")
    }

    func zoomedOutlines() throws {
        var cam = camera(.axial)
        cam.moveAlongNormal(by: simd_dot(phantom.lesionCenter - cam.center, cam.normal))
        cam.center = cam.projectOntoPlane(phantom.lesionCenter + SIMD3(9, -6, 0))
        cam.millimetersPerPixel = 0.04
        cam.snapToVoxelCenters(of: phantom.grid)
        var nearest = ctLayer()
        nearest.interpolation = .nearest
        let scene = SliceScene(camera: cam, layers: [.image(nearest), .label(organLayer(style: .outline)),
                                                     .label(lesionLayer(style: .fillAndOutline))])
        try write(slice.render(scene: scene), "slice_zoom_outline.png")
        // Rotated in-plane by 20°: outlines stay anti-aliased on voxel edges.
        var rotated = cam
        let q = simd_quatd(angle: 20 * .pi / 180, axis: cam.normal)
        rotated.axes = PlaneAxes(right: q.act(cam.axes.right), down: q.act(cam.axes.down))
        try write(slice.render(scene: SliceScene(camera: rotated, layers: scene.layers)), "slice_zoom_outline_rotated.png")
        var cubic = scene
        var smooth = ctLayer()
        smooth.interpolation = .cubic
        cubic.layers[0] = .image(smooth)
        try write(slice.render(scene: cubic), "slice_zoom_cubic.png")
    }

    func ignoreRegion() throws {
        // Mark a slab of the lesion layer as "ignore" and show it.
        let copy = phantom.lesions.copy()
        let p = copy.pointer(as: UInt16.self)
        let n = phantom.grid.paddedShape
        for k0 in 0..<n.x {
            for k1 in 0..<n.y {
                for k2 in 0..<n.z where k1 < 70 && k2 > 150 && p[(k0 * n.y + k1) * n.z + k2] == 0 {
                    p[(k0 * n.y + k1) * n.z + k2] = ClassID.ignore
                }
            }
        }
        let texture = try VolumeTexture(context: context, labels: copy, geometry: phantom.grid)
        let cam = camera(.axial)
        let layer = LabelLayer(volume: texture, lookupTable: lesionTable, style: .fillAndOutline, fillOpacity: 0.45)
        let scene = SliceScene(camera: cam, layers: [.image(ctLayer()), .label(organLayer(style: .outline)), .label(layer)])
        try write(slice.render(scene: scene), "slice_ignore_region.png")
    }

    func colormaps() throws {
        // A horizontal ramp rendered through every colormap, stacked.
        let grid = GridGeometry(id: "ramp", shape: [1, 8, 512], spacing: [1, 1, 1],
                                direction: [[0, 0, 1], [0, 1, 0], [1, 0, 0]])
        let data = VolumeData(scalarType: .float32, shape: [1, 8, 512])
        let ptr = data.pointer(as: Float.self)
        for y in 0..<8 { for x in 0..<512 { ptr[y * 512 + x] = Float(x) / 511 } }
        let ramp = try VolumeTexture(context: context, scalars: data, geometry: grid)
        var images: [RenderedImage] = []
        for map in Colormap.allCases {
            let cam = SliceCamera(center: grid.worldCenter, axes: PlaneAxes.standard(.axial),
                                  millimetersPerPixel: 512.0 / 512.0, viewportSize: SIMD2(512, 8))
            let layer = ImageLayer(volume: ramp, windowCenter: 0.5, windowWidth: 1, colormap: map)
            images.append(try slice.render(scene: SliceScene(camera: cam, layers: [.image(layer)])))
        }
        try write(stack(images, gap: 2), "colormaps.png")
    }

    // MARK: 3-D

    func volumeCamera(_ view: AnatomicalView = .anterior, size: SIMD2<Int> = SIMD2(900, 900)) -> VolumeCamera {
        var c = VolumeCamera.framing(bounds: phantom.grid.worldBounds, from: view, viewportSize: size)
        c.orbit(byPixels: SIMD2(-70, -45))
        return c
    }

    func ctImage() -> VolumeImage {
        VolumeImage(volume: ct, windowCenter: 300, windowWidth: 1200)
    }

    func volumes() throws {
        var scene = VolumeScene(camera: volumeCamera(), image: ctImage(), mode: .mip)
        try timed("volume_mip.png") { try volume.render(scene: scene) }
        scene.mode = .dvr
        scene.transferFunction = .preset(.ctBone)
        try timed("volume_dvr_bone.png") { try volume.render(scene: scene) }
        scene.transferFunction = .preset(.ctSoftTissue)
        try timed("volume_dvr_soft.png") { try volume.render(scene: scene) }
        scene.transferFunction = .preset(.ctLung)
        try timed("volume_dvr_lung.png") { try volume.render(scene: scene) }
        scene.transferFunction = .preset(.ctAngiography)
        try timed("volume_dvr_angio.png") { try volume.render(scene: scene) }
        scene.transferFunction = .preset(.ctSkin)
        scene.clipPlane = Plane(point: SIMD3(0, -10, 0), normal: SIMD3(0, 1, 0))
        try timed("volume_dvr_skin_clipped.png") { try volume.render(scene: scene) }
        scene.clipPlane = nil
        scene.quality = .interactive
        scene.transferFunction = .preset(.ctBone)
        try timed("volume_dvr_bone_interactive.png") { try volume.render(scene: scene) }
        scene.quality = .full
        scene.mode = .isosurface
        scene.isoValue = 200
        try timed("volume_isosurface.png") { try volume.render(scene: scene) }

        // Segmentation surfaces over a faint DVR, with the slice planes.
        var labels = VolumeScene(camera: volumeCamera(), image: ctImage(), mode: .dvr,
                                 transferFunction: .preset(.ctBone))
        labels.labels = [VolumeLabelLayer(volume: lesions, lookupTable: lesionTable),
                         VolumeLabelLayer(volume: organs, lookupTable: organTable)]
        organTable.setVisible(false, forClass: Phantom.Organ.spine.rawValue)
        try timed("volume_labels.png") { try volume.render(scene: labels) }
        // Translucent organs show the lesion inside the liver.
        labels.labels[1].opacity = 0.35
        try timed("volume_labels_translucent.png") { try volume.render(scene: labels) }
        organTable.setVisible(true, forClass: Phantom.Organ.spine.rawValue)

        // Meshes, depth-composited with DVR, and the three MPR planes.
        let gpuLiver = try GPUMesh(context: context, mesh: liverMesh)
        let sphere = try GPUMesh(context: context, mesh: .icosphere(center: phantom.lesionCenter + SIMD3(0, -40, 30),
                                                                     radius: 12, subdivisions: 4))
        var meshes = VolumeScene(camera: volumeCamera(), image: ctImage(), mode: .dvr, transferFunction: .preset(.ctBone))
        meshes.meshes = [MeshInstance(mesh: gpuLiver, color: SIMD4(0.75, 0.35, 0.3, 1)),
                         MeshInstance(mesh: sphere, color: SIMD4(0.3, 0.7, 1, 0.5))]
        for (plane, color) in [(ViewPlane.axial, SIMD4<Double>(1, 0.3, 0.3, 1)), (.coronal, SIMD4(0.3, 1, 0.3, 1)),
                               (.sagittal, SIMD4(0.4, 0.6, 1, 1))] {
            var cam = camera(plane)
            cam.moveAlongNormal(by: simd_dot(phantom.lesionCenter - cam.center, cam.normal))
            meshes.planes.append(.slice(cam, in: phantom.grid, color: color))
        }
        try timed("volume_meshes_planes.png") { try volume.render(scene: meshes) }

        // A textured slice plane in 3-D (the axial slice image on its plane).
        var axialCam = camera(.axial, size: SIMD2(512, 512))
        axialCam.moveAlongNormal(by: simd_dot(phantom.lesionCenter - axialCam.center, axialCam.normal))
        let sliceTexture = try makeSliceTexture(axialCam)
        var textured = VolumeScene(camera: volumeCamera(), image: ctImage(), mode: .dvr, transferFunction: .preset(.ctBone))
        var plane = VolumePlane.slice(axialCam, in: phantom.grid, color: SIMD4(1, 0.3, 0.3, 1))
        plane.texture = sliceTexture
        plane.textureCamera = axialCam
        textured.planes = [plane]
        textured.clipPlane = Plane(point: axialCam.center, normal: -axialCam.normal)
        try timed("volume_textured_plane.png") { try volume.render(scene: textured) }

        // Meshes alone, orthographic, framed on the meshes.
        let lb = gpuLiver.bounds, sb = sphere.bounds
        var alone = VolumeScene(camera: VolumeCamera.framing(bounds: (simd_min(lb.min, sb.min), simd_max(lb.max, sb.max)),
                                                             from: .anterior, viewportSize: SIMD2(900, 900),
                                                             projection: .orthographic))
        alone.camera.orbit(byPixels: SIMD2(-90, -60))
        alone.meshes = [MeshInstance(mesh: gpuLiver, color: SIMD4(0.8, 0.45, 0.35, 1)),
                        MeshInstance(mesh: sphere, color: SIMD4(0.3, 0.7, 1, 1))]
        alone.backgroundColor = SIMD4(0.12, 0.13, 0.16, 1)
        try timed("mesh_orthographic.png") { try volume.render(scene: alone) }
    }

    private func makeSliceTexture(_ cam: SliceCamera) throws -> any MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: cam.viewportSize.x,
                                                         height: cam.viewportSize.y, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        let t = context.device.makeTexture(descriptor: d)!
        let cb = try context.makeCommandBuffer()
        try slice.encode(scene: SliceScene(camera: cam, layers: [.image(ctLayer()), .label(organLayer())]), to: t,
                         commandBuffer: cb)
        cb.commit()
        return t
    }

    private func timed(_ name: String, _ body: () throws -> RenderedImage) throws {
        let start = Date()
        let image = try body()
        log(String(format: "%@ rendered in %.1f ms (incl. readback)", name, Date().timeIntervalSince(start) * 1000))
        try write(image, name)
    }

    /// Stacks images vertically (same width) with a black gap.
    private func stack(_ images: [RenderedImage], gap: Int) -> RenderedImage {
        let width = images.map(\.width).max() ?? 1
        let height = images.reduce(0) { $0 + $1.height } + gap * max(0, images.count - 1)
        let bpr = width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * height)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        var y0 = 0
        for img in images {
            for y in 0..<img.height {
                for x in 0..<img.width {
                    let s = y * img.bytesPerRow + x * 4, d = (y0 + y) * bpr + x * 4
                    bytes[d] = img.bytes[s]
                    bytes[d + 1] = img.bytes[s + 1]
                    bytes[d + 2] = img.bytes[s + 2]
                    bytes[d + 3] = img.bytes[s + 3]
                }
            }
            y0 += img.height + gap
        }
        return RenderedImage(width: width, height: height, bytesPerRow: bpr, bytes: bytes)
    }
}

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func ms(since start: Date) -> String {
    String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
}
