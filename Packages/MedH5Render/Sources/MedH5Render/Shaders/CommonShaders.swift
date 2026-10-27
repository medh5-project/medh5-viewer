/// Shared MSL: the full-screen triangle, texture-space helpers and the
/// interpolation functions every volume sampler uses.
///
/// Texture conventions (ARCHITECTURE.md): a volume of padded shape
/// `(n0, n1, n2)` is a 3-D texture of width `n2`, height `n1`, depth `n0`; a
/// normalised texture coordinate `tc` has voxel centres at
/// `(k + 0.5) / n` and the volume's region is `[0, 1]³`.
enum CommonShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// Layer flags (SliceLayerUniforms.flags).
constant int FLAG_INVERT      = 1;
constant int FLAG_THRESHOLD   = 2;
constant int FLAG_RGB         = 4;
constant int FLAG_FIELD       = 8;
constant int FLAG_FILL        = 16;
constant int FLAG_OUTLINE     = 32;
constant int FLAG_SHOW_IGNORE = 64;
constant int FLAG_CONTOUR     = 128;

constant float BIG = 3.0e38;

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

// One triangle covering the viewport; uv is (0,0) at the top-left corner.
vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    FullscreenOut o;
    o.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// NaN test that survives fast math.
inline bool is_nan_bits(float v) {
    return (as_type<uint>(v) & 0x7fffffffu) > 0x7f800000u;
}

inline bool inside_unit(float3 tc) {
    return all(tc >= float3(0.0)) && all(tc <= float3(1.0));
}

// The voxel whose cell holds tc (rounding half up, as the box convention).
inline uint3 texel_index(float3 tc, float3 size) {
    return uint3(clamp(floor(tc * size), float3(0.0), size - 1.0));
}

inline float fetch_nearest(texture3d<float> t, float3 tc, float3 size) {
    return t.read(texel_index(tc, size)).r;
}

// Trilinear interpolation from eight reads, for formats the hardware cannot
// filter (r32Float without float filtering).
inline float fetch_trilinear(texture3d<float> t, float3 tc, float3 size) {
    float3 p = tc * size - 0.5;
    float3 base = floor(p);
    float3 f = p - base;
    float3 hi = size - 1.0;
    uint3 a = uint3(clamp(base, float3(0.0), hi));
    uint3 b = uint3(clamp(base + 1.0, float3(0.0), hi));
    float c000 = t.read(uint3(a.x, a.y, a.z)).r;
    float c100 = t.read(uint3(b.x, a.y, a.z)).r;
    float c010 = t.read(uint3(a.x, b.y, a.z)).r;
    float c110 = t.read(uint3(b.x, b.y, a.z)).r;
    float c001 = t.read(uint3(a.x, a.y, b.z)).r;
    float c101 = t.read(uint3(b.x, a.y, b.z)).r;
    float c011 = t.read(uint3(a.x, b.y, b.z)).r;
    float c111 = t.read(uint3(b.x, b.y, b.z)).r;
    float c00 = mix(c000, c100, f.x);
    float c10 = mix(c010, c110, f.x);
    float c01 = mix(c001, c101, f.x);
    float c11 = mix(c011, c111, f.x);
    return mix(mix(c00, c10, f.y), mix(c01, c11, f.y), f.z);
}

// Interpolating cubic (Catmull-Rom) from 27 hardware-filtered fetches: the
// two positive middle weights of each axis are merged into one linear fetch.
inline float fetch_catmull_rom(texture3d<float> t, sampler s, float3 tc, float3 size) {
    float3 p = tc * size - 0.5;
    float3 i = floor(p);
    float3 f = p - i;
    float3 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float3 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float3 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float3 w3 = f * f * (-0.5 + 0.5 * f);
    float3 w12 = w1 + w2;
    float3 o12 = w2 / w12;
    float3 inv = 1.0 / size;
    float3 c0 = (i - 0.5) * inv;
    float3 c12 = (i + 0.5 + o12) * inv;
    float3 c3 = (i + 2.5) * inv;
    float wx[3] = { w0.x, w12.x, w3.x };
    float wy[3] = { w0.y, w12.y, w3.y };
    float wz[3] = { w0.z, w12.z, w3.z };
    float cx[3] = { c0.x, c12.x, c3.x };
    float cy[3] = { c0.y, c12.y, c3.y };
    float cz[3] = { c0.z, c12.z, c3.z };
    float result = 0.0;
    for (int z = 0; z < 3; z++) {
        for (int y = 0; y < 3; y++) {
            float wyz = wy[y] * wz[z];
            for (int x = 0; x < 3; x++) {
                result += wx[x] * wyz * t.sample(s, float3(cx[x], cy[y], cz[z])).r;
            }
        }
    }
    return result;
}

// interpolation: 0 nearest, 1 hardware linear, 2 manual linear, 3 cubic.
inline float sample_scalar(texture3d<float> t, sampler s, float3 tc, float3 size, int interpolation) {
    switch (interpolation) {
        case 0: return fetch_nearest(t, tc, size);
        case 1: return t.sample(s, tc).r;
        case 2: return fetch_trilinear(t, tc, size);
        default: return fetch_catmull_rom(t, s, tc, size);
    }
}

// A colormap row of a LUT texture 256 texels wide; t in [0, 1].
inline float4 lut_color(texture2d<float> lut, sampler s, float t, float row) {
    return lut.sample(s, float2((clamp(t, 0.0, 1.0) * 255.0 + 0.5) / 256.0, row));
}

// Label LUT: 65536 entries as a 256 x 256 texture, class id = y * 256 + x.
inline float4 label_color(texture2d<float> lut, uint label) {
    return lut.read(uint2(label & 255u, (label >> 8u) & 255u));
}

inline uint label_read(texture3d<uint> t, int3 ijk, int3 dims) {
    if (any(ijk < int3(0)) || any(ijk >= dims)) { return 0u; }
    return t.read(uint3(ijk)).r;
}

inline uint label_at(texture3d<uint> t, float3 tc, float3 size) {
    if (!inside_unit(tc)) { return 0u; }
    return t.read(texel_index(tc, size)).r;
}

inline float interleaved_gradient_noise(float2 p) {
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

// Ray / axis-aligned box: (t entry, t exit).
inline float2 ray_box(float3 o, float3 d, float3 lo, float3 hi) {
    float3 dd = select(d, float3(1e-12), abs(d) < 1e-12);
    float3 inv = 1.0 / dd;
    float3 t0 = (lo - o) * inv;
    float3 t1 = (hi - o) * inv;
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);
    return float2(max(max(tmin.x, tmin.y), tmin.z), min(min(tmax.x, tmax.y), tmax.z));
}
"""#
}
