import simd

// Swift mirrors of the structs the shaders read. Field order, types and
// therefore layout match the MSL declarations exactly (simd types have the
// same size and alignment in Swift and Metal); `ShaderLayoutTests` compares
// every `MemoryLayout<…>.stride` with `sizeof` on the GPU.

/// Mirror of MSL `SliceLayerUniforms` (SliceShaders.swift).
struct SliceLayerUniforms {
    var pixelToTexture = matrix_identity_float4x4
    var pixelToWorld = matrix_identity_float4x4
    var worldToTexture = matrix_identity_float4x4
    var worldToField = matrix_identity_float4x4
    var textureSize = SIMD4<Float>(1, 1, 1, 0)
    var slabStep = SIMD4<Float>(0, 0, 0, 0)
    var color = SIMD4<Float>(0, 0, 0, 0)
    var valueMap = SIMD4<Float>(1, 0, 0, 0)
    var window = SIMD4<Float>(0, 1, 0, 1)
    var extra = SIMD4<Float>(0, 0, 0, 0)
    var lutRow: Float = 0
    var interpolation: Int32 = 1
    var flags: Int32 = 0
    var slabMode: Int32 = 0
    var slabSamples: Int32 = 0
    var ignoreID: Int32 = 65535
    var pixelsPerPoint: Float = 1
    var pad0: Float = 0
}

/// Flags of `SliceLayerUniforms.flags` (CommonShaders.swift).
struct SliceLayerFlags: OptionSet {
    let rawValue: Int32
    static let invert = SliceLayerFlags(rawValue: 1)
    static let threshold = SliceLayerFlags(rawValue: 2)
    static let rgb = SliceLayerFlags(rawValue: 4)
    static let field = SliceLayerFlags(rawValue: 8)
    static let fill = SliceLayerFlags(rawValue: 16)
    static let outline = SliceLayerFlags(rawValue: 32)
    static let showIgnore = SliceLayerFlags(rawValue: 64)
    static let contour = SliceLayerFlags(rawValue: 128)
}

/// Mirror of MSL `OverlayVertex` (OverlayShaders.swift).
struct OverlayVertex {
    var position: SIMD2<Float>
    var local: SIMD2<Float>
    var color: SIMD4<Float>
    var shape: SIMD4<Float>
    var style: SIMD4<Float>
}

/// Mirror of MSL `OverlayUniforms`.
struct OverlayUniforms {
    var viewportSize: SIMD2<Float>
    var pad = SIMD2<Float>(0, 0)
}

/// Mirror of MSL `VolumeUniforms` (VolumeShaders.swift).
struct VolumeUniforms {
    var inverseViewProjection = matrix_identity_float4x4
    var viewProjection = matrix_identity_float4x4
    var worldToTexture = matrix_identity_float4x4
    var gradientToWorld = matrix_identity_float4x4
    var eye = SIMD4<Float>(0, 0, 0, 1)
    var lightDirection = SIMD4<Float>(0, 0, 1, 0)
    var clipTexMin = SIMD4<Float>(0, 0, 0, 0)
    var clipTexMax = SIMD4<Float>(1, 1, 1, 0)
    var clipWorldMin = SIMD4<Float>(0, 0, 0, 0)
    var clipWorldMax = SIMD4<Float>(0, 0, 0, 0)
    var clipPlane = SIMD4<Float>(0, 0, 0, 0)
    var isoColor = SIMD4<Float>(1, 1, 1, 1)
    var textureSize = SIMD4<Float>(1, 1, 1, 0)
    var valueMap = SIMD4<Float>(1, 0, 0, 1)
    var tfMap = SIMD4<Float>(0, 1, 1, 0)
    var shading = SIMD4<Float>(0.25, 0.75, 0.3, 32)
    var viewport = SIMD4<Float>(1, 1, 1, 1)
    var visibleRange = SIMD4<Float>(-3e38, 3e38, 0, 0)
    var stepSize: Float = 1
    var lutRow: Float = 0
    var gradientScale: Float = 0
    var mode: Int32 = 0
    var maxSteps: Int32 = 0
    var flags: Int32 = 0
    var labelCount: Int32 = 0
    var interpolation: Int32 = 1
}

/// Flags of `VolumeUniforms.flags`.
struct VolumeFlags: OptionSet {
    let rawValue: Int32
    static let shading = VolumeFlags(rawValue: 1)
    static let clipPlane = VolumeFlags(rawValue: 2)
    static let clipWorld = VolumeFlags(rawValue: 4)
    static let meshDepth = VolumeFlags(rawValue: 8)
    static let image = VolumeFlags(rawValue: 16)
    static let jitter = VolumeFlags(rawValue: 32)
    static let invert = VolumeFlags(rawValue: 64)
    static let fast = VolumeFlags(rawValue: 128)
    static let skipEmptySpace = VolumeFlags(rawValue: 256)
}

/// Mirror of MSL `VolumeLabelUniforms`.
struct VolumeLabelUniforms {
    var worldToTexture = matrix_identity_float4x4
    var gradientToWorld = matrix_identity_float4x4
    var textureSize = SIMD4<Float>(1, 1, 1, 0)
    var params = SIMD4<Float>(1, 0, 0, 0)
}

/// Mirror of MSL `CompositeUniforms`.
struct CompositeUniforms {
    var background = SIMD4<Float>(0, 0, 0, 1)
    var hasMesh: Int32 = 0
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}

/// Mirror of MSL `MeshVertexIn` (packed: 24 bytes).
struct MeshVertexGPU {
    var px: Float, py: Float, pz: Float
    var nx: Float, ny: Float, nz: Float
}

/// Mirror of MSL `MeshUniforms` (MeshShaders.swift).
struct MeshUniforms {
    var viewProjection = matrix_identity_float4x4
    var model = matrix_identity_float4x4
    var normalMatrix = matrix_identity_float4x4
    var color = SIMD4<Float>(1, 1, 1, 1)
    var eye = SIMD4<Float>(0, 0, 0, 1)
    var viewDirection = SIMD4<Float>(0, 0, -1, 0)
    var lightDirection = SIMD4<Float>(0, 0, 1, 0)
    var material = SIMD4<Float>(0.25, 0.75, 0.3, 32)
}

/// Mirror of MSL `PlaneVertex`.
struct PlaneVertex {
    var position: SIMD4<Float>
    var uv: SIMD4<Float>
}

/// Mirror of MSL `PlaneUniforms`.
struct PlaneUniforms {
    var viewProjection = matrix_identity_float4x4
    var color = SIMD4<Float>(1, 1, 1, 1)
    var textured: Int32 = 0
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}

extension simd_double4x4 {
    /// The linear part's transpose as a homogeneous matrix: maps a gradient
    /// in this map's output space to a gradient in its input space.
    var gradientPullback: simd_double4x4 {
        let m = self
        var out = matrix_identity_double4x4
        for r in 0..<3 {
            for c in 0..<3 {
                out[c][r] = m[r][c]
            }
        }
        return out
    }
}
