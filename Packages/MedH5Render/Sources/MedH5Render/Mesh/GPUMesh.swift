import Foundation
import Metal
import simd

/// A triangle mesh uploaded to the GPU: interleaved positions and normals
/// (normals computed when the mesh has none) and 32-bit indices.
public final class GPUMesh: @unchecked Sendable {
    /// Interleaved positions and normals (6 floats per vertex).
    public let vertexBuffer: any MTLBuffer
    /// 32-bit triangle indices.
    public let indexBuffer: any MTLBuffer
    public let vertexCount: Int
    public let indexCount: Int
    /// World bounds of the vertices.
    public let bounds: (min: SIMD3<Double>, max: SIMD3<Double>)

    /// Uploads a mesh (its normals are computed first when it has none).
    public init(context: RenderContext, mesh: TriangleMesh) throws {
        let m = mesh.withNormals()
        var vertices = [MeshVertexGPU]()
        vertices.reserveCapacity(m.positions.count)
        for (p, n) in zip(m.positions, m.normals) {
            vertices.append(MeshVertexGPU(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z))
        }
        let vbytes = max(24, vertices.count * MemoryLayout<MeshVertexGPU>.stride)
        let ibytes = max(4, m.indices.count * 4)
        guard let vb = context.device.makeBuffer(length: vbytes, options: .storageModeShared),
              let ib = context.device.makeBuffer(length: ibytes, options: .storageModeShared) else {
            throw RenderError.allocationFailed("mesh buffers")
        }
        vertices.withUnsafeBytes { raw in
            if let base = raw.baseAddress { vb.contents().copyMemory(from: base, byteCount: raw.count) }
        }
        m.indices.withUnsafeBytes { raw in
            if let base = raw.baseAddress { ib.contents().copyMemory(from: base, byteCount: raw.count) }
        }
        vb.label = "mesh vertices"
        ib.label = "mesh indices"
        vertexBuffer = vb
        indexBuffer = ib
        vertexCount = vertices.count
        indexCount = m.indices.count
        if let b = m.bounds {
            bounds = (SIMD3<Double>(b.min), SIMD3<Double>(b.max))
        } else {
            bounds = (.zero, .zero)
        }
    }

    /// GPU memory the buffers occupy, in bytes.
    public var allocatedSize: Int { vertexBuffer.allocatedSize + indexBuffer.allocatedSize }
}

/// Blinn-Phong material parameters.
public struct MeshMaterial: Sendable, Hashable {
    public var ambient: Double
    public var diffuse: Double
    public var specular: Double
    public var shininess: Double

    public init(ambient: Double = 0.22, diffuse: Double = 0.78, specular: Double = 0.25, shininess: Double = 40) {
        self.ambient = ambient
        self.diffuse = diffuse
        self.specular = specular
        self.shininess = shininess
    }

    public static let `default` = MeshMaterial()

    var vector: SIMD4<Float> { SIMD4(Float(ambient), Float(diffuse), Float(specular), Float(shininess)) }
}

/// A mesh placed in a 3-D scene with a colour (straight RGBA; alpha is the
/// opacity).
public struct MeshInstance: Sendable {
    public var mesh: GPUMesh
    /// Straight RGBA; alpha below 1 draws the mesh translucent (sorted, both faces).
    public var color: SIMD4<Double>
    /// Model → world.
    public var transform: simd_double4x4
    public var material: MeshMaterial
    /// Culls back faces (closed opaque meshes); otherwise both sides are lit.
    public var cullsBackFaces: Bool
    public var isVisible: Bool

    public init(mesh: GPUMesh, color: SIMD4<Double>, transform: simd_double4x4 = matrix_identity_double4x4,
                material: MeshMaterial = .default, cullsBackFaces: Bool = false) {
        self.mesh = mesh
        self.color = color
        self.transform = transform
        self.material = material
        self.cullsBackFaces = cullsBackFaces
        self.isVisible = true
    }
}
