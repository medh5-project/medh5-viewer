import XCTest
import Metal
import MedH5Core
@testable import MedH5Render

final class ShaderCompilationTests: XCTestCase {
    /// Every pipeline of every renderer builds, for every target format the
    /// views use.
    func testEveryPipelineBuilds() throws {
        let context = try makeTestContext()
        for format in [MTLPixelFormat.bgra8Unorm, .rgba8Unorm, .bgra8Unorm_srgb, .rgba16Float] {
            XCTAssertNoThrow(try SliceRenderer(context: context, colorPixelFormat: format).prepare(), "\(format)")
            XCTAssertNoThrow(try VolumeRenderer(context: context, colorPixelFormat: format).prepare(), "\(format)")
        }
        XCTAssertNoThrow(try context.computePipeline("layout_probe"))
        for name in context.library.functionNames {
            XCTAssertNotNil(context.library.makeFunction(name: name), name)
        }
    }

    /// The Swift mirrors of shader structs have the shaders' sizes.
    func testStructLayoutsMatchTheShaders() throws {
        let context = try makeTestContext()
        let pipeline = try context.computePipeline("layout_probe")
        let buffer = try XCTUnwrap(context.device.makeBuffer(length: 64 * 4, options: .storageModeShared))
        let cb = try context.makeCommandBuffer()
        let encoder = try XCTUnwrap(cb.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let sizes = buffer.contents().assumingMemoryBound(to: UInt32.self)
        let swift: [(String, Int)] = [
            ("SliceLayerUniforms", MemoryLayout<SliceLayerUniforms>.stride),
            ("OverlayVertex", MemoryLayout<OverlayVertex>.stride),
            ("OverlayUniforms", MemoryLayout<OverlayUniforms>.stride),
            ("VolumeUniforms", MemoryLayout<VolumeUniforms>.stride),
            ("VolumeLabelUniforms", MemoryLayout<VolumeLabelUniforms>.stride),
            ("CompositeUniforms", MemoryLayout<CompositeUniforms>.stride),
            ("MeshVertexIn", MemoryLayout<MeshVertexGPU>.stride),
            ("MeshUniforms", MemoryLayout<MeshUniforms>.stride),
            ("PlaneVertex", MemoryLayout<PlaneVertex>.stride),
            ("PlaneUniforms", MemoryLayout<PlaneUniforms>.stride),
        ]
        for (i, (name, size)) in swift.enumerated() {
            XCTAssertEqual(Int(sizes[i]), size, name)
        }
    }

    func testColormapsAreWellFormed() throws {
        for map in Colormap.allCases {
            let t = map.table()
            XCTAssertEqual(t.count, 256)
        }
        // Known end points.
        XCTAssertEqual(Colormap.grayscale.color(at: 0.5), SIMD3(repeating: 0.5))
        XCTAssertEqual(Colormap.inverted.color(at: 0), SIMD3(repeating: 1))
        let v0 = Colormap.viridis.color(at: 0), v1 = Colormap.viridis.color(at: 1)
        XCTAssertEqual(v0.x, 0.267, accuracy: 0.02)
        XCTAssertEqual(v0.z, 0.329, accuracy: 0.02)
        XCTAssertEqual(v1.x, 0.993, accuracy: 0.02)
        XCTAssertEqual(v1.y, 0.906, accuracy: 0.02)
        XCTAssertEqual(Colormap.hotIron.color(at: 1), SIMD3(1, 1, 1))
        XCTAssertEqual(Colormap.hotIron.color(at: 0), SIMD3(0, 0, 0))
        let context = try makeTestContext()
        XCTAssertEqual(context.colormaps.texture.height, Colormap.allCases.count)
    }

    func testVolumeTextureFormatsAndMemory() throws {
        let context = try makeTestContext()
        let grid = GridGeometry(id: "g", shape: [8, 16, 32], spacing: [1, 1, 1])
        let cases: [(ScalarType, MTLPixelFormat)] = [
            (.uint8, .r8Unorm), (.int8, .r8Snorm), (.uint16, .r16Unorm), (.int16, .r16Snorm),
            (.float16, .r16Float), (.float32, .r32Float), (.bool, .r8Unorm), (.float64, .r32Float), (.int32, .r32Float),
        ]
        for (type, format) in cases {
            let v = try VolumeTexture(context: context, scalars: VolumeData(scalarType: type, shape: [8, 16, 32]),
                                      geometry: grid)
            XCTAssertEqual(v.texture.pixelFormat, format, "\(type)")
            XCTAssertEqual(v.texture.width, 32)
            XCTAssertEqual(v.texture.height, 16)
            XCTAssertEqual(v.texture.depth, 8)
            XCTAssertGreaterThanOrEqual(v.allocatedSize, 8 * 16 * 32 * type.gpuCompatible.byteSize)
            v.waitUntilUploaded()
            XCTAssertTrue(v.isUploaded)
        }
        let labels = try VolumeTexture(context: context, labels: VolumeData(scalarType: .uint16, shape: [8, 16, 32]),
                                       geometry: grid)
        XCTAssertEqual(labels.texture.pixelFormat, .r16Uint)
        // RGB from an image with a channel axis.
        let rgbGrid = GridGeometry(id: "rgb", shape: [3, 16, 32], axisKinds: [.channel, .spatial, .spatial],
                                   spacing: [1, 1])
        let rgb = ImageVolume(id: "rgb", data: VolumeData(scalarType: .uint8, shape: [3, 16, 32]), geometry: rgbGrid,
                              valueType: "rgb")
        let rgbTexture = try VolumeTexture(context: context, image: rgb)
        XCTAssertEqual(rgbTexture.texture.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(rgbTexture.dimensions, SIMD3(1, 16, 32))
        XCTAssertThrowsError(try VolumeTexture(context: context, scalars: VolumeData(scalarType: .uint8, shape: [5]),
                                               geometry: grid))
    }
}
