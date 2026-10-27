/// MSL for the slice (MPR) view: one full-screen pass per layer, composited
/// "over" in order with premultiplied alpha. Every fragment computes its own
/// texture coordinate from the drawable pixel through the layer's matrix, so
/// layers on different grids, spacings, directions and registrations line up
/// exactly.
///
/// `SliceLayerUniforms` mirrors the Swift struct of the same name field by
/// field (`SliceUniforms.swift`).
enum SliceShaders {
    static let source = #"""
struct SliceLayerUniforms {
    float4x4 pixelToTexture;   // drawable pixel (x, y, 0, 1) -> layer texture coordinate
    float4x4 pixelToWorld;     // drawable pixel -> reference world
    float4x4 worldToTexture;   // reference world (after displacement) -> layer texture coordinate
    float4x4 worldToField;     // reference world -> displacement field texture coordinate
    float4 textureSize;        // (width n2, height n1, depth n0, 0)
    float4 slabStep;           // texture-space step between slab samples
    float4 color;              // labels: ignore colour; probability: contour colour (straight)
    float4 valueMap;           // physical = texel * x + y
    float4 window;             // (low, 1 / width, threshold, opacity)
    float4 extra;              // labels: (fill opacity, outline opacity, outline px, hatch px)
                               // probability: (contour px, contour opacity, 0, 0)
    float lutRow;
    int interpolation;
    int flags;
    int slabMode;              // 0 none, 1 maximum, 2 minimum, 3 mean
    int slabSamples;
    int ignoreID;
    float pixelsPerPoint;
    float pad0;
};

inline float3 slice_texcoord(constant SliceLayerUniforms& u, float2 px, texture3d<float> field, sampler s) {
    float4 p = float4(px, 0.0, 1.0);
    if ((u.flags & FLAG_FIELD) == 0) {
        return (u.pixelToTexture * p).xyz;
    }
    float3 x = (u.pixelToWorld * p).xyz;
    float3 ftc = (u.worldToField * float4(x, 1.0)).xyz;
    float3 d = inside_unit(ftc) ? field.sample(s, ftc).xyz : float3(0.0);
    return (u.worldToTexture * float4(x + d, 1.0)).xyz;
}

fragment float4 slice_image_fragment(FullscreenOut in [[stage_in]],
                                     constant SliceLayerUniforms& u [[buffer(0)]],
                                     texture3d<float> volume [[texture(0)]],
                                     texture2d<float> lut [[texture(1)]],
                                     texture3d<float> field [[texture(2)]],
                                     sampler linearSampler [[sampler(0)]])
{
    float3 tc = slice_texcoord(u, in.position.xy, field, linearSampler);
    float3 size = u.textureSize.xyz;
    float opacity = u.window.w;
    if ((u.flags & FLAG_RGB) != 0) {
        if (!inside_unit(tc)) { return float4(0.0); }
        float4 c = (u.interpolation == 0) ? volume.read(texel_index(tc, size)) : volume.sample(linearSampler, tc);
        float3 v = clamp((c.rgb * u.valueMap.x + u.valueMap.y - u.window.x) * u.window.y, 0.0, 1.0);
        if ((u.flags & FLAG_INVERT) != 0) { v = 1.0 - v; }
        float a = c.a * opacity;
        return float4(v * a, a);
    }
    float value;
    if (u.slabMode == 0 || u.slabSamples < 2) {
        if (!inside_unit(tc)) { return float4(0.0); }
        value = sample_scalar(volume, linearSampler, tc, size, u.interpolation) * u.valueMap.x + u.valueMap.y;
    } else {
        int n = u.slabSamples;
        float3 stepTC = u.slabStep.xyz;
        float3 start = tc - stepTC * (0.5 * float(n - 1));
        float acc = (u.slabMode == 1) ? -BIG : ((u.slabMode == 2) ? BIG : 0.0);
        int count = 0;
        for (int i = 0; i < n; i++) {
            float3 p = start + stepTC * float(i);
            if (!inside_unit(p)) { continue; }
            float v = sample_scalar(volume, linearSampler, p, size, u.interpolation) * u.valueMap.x + u.valueMap.y;
            if (is_nan_bits(v)) { continue; }
            if (u.slabMode == 1) { acc = max(acc, v); }
            else if (u.slabMode == 2) { acc = min(acc, v); }
            else { acc += v; }
            count++;
        }
        if (count == 0) { return float4(0.0); }
        value = (u.slabMode == 3) ? acc / float(count) : acc;
    }
    if (is_nan_bits(value)) { return float4(0.0); }
    if ((u.flags & FLAG_THRESHOLD) != 0 && value < u.window.z) { return float4(0.0); }
    float t = (value - u.window.x) * u.window.y;
    if ((u.flags & FLAG_INVERT) != 0) { t = 1.0 - t; }
    float4 c = lut_color(lut, linearSampler, t, u.lutRow);
    float a = c.a * opacity;
    return float4(c.rgb * a, a);
}

constant float2 kOutlineDirections[8] = {
    float2(1.0, 0.0), float2(-1.0, 0.0), float2(0.0, 1.0), float2(0.0, -1.0),
    float2(0.70710678, 0.70710678), float2(-0.70710678, 0.70710678),
    float2(0.70710678, -0.70710678), float2(-0.70710678, -0.70710678)
};

// Coverage of an outline `width` pixels wide drawn inside the region of
// label L. When voxels are large on screen the outline is the band along the
// faces of this voxel whose neighbour differs (exact, anti-aliased, for any
// plane orientation); when they are small, any different label within
// `width` pixels on screen marks the pixel.
inline float label_outline_coverage(texture3d<uint> labels, float3 tc, float3 size, uint L,
                                    float3 dtdx, float3 dtdy, float width)
{
    float3 gx = dtdx * size;
    float3 gy = dtdy * size;
    float3 gmag = sqrt(gx * gx + gy * gy);
    float maxg = max(gmag.x, max(gmag.y, gmag.z));
    if (maxg * (2.0 * width + 1.0) > 1.0) {
        for (int i = 0; i < 8; i++) {
            float3 q = tc + (kOutlineDirections[i].x * dtdx + kOutlineDirections[i].y * dtdy) * width;
            if (label_at(labels, q, size) != L) { return 1.0; }
        }
        return 0.0;
    }
    int3 dims = int3(size);
    float3 p = tc * size;
    float3 v = floor(p);
    float3 f = p - v - 0.5;
    int3 vi = int3(v);
    int3 s = int3(select(float3(-1.0), float3(1.0), f >= 0.0));
    float cov = 0.0;
    bool differs[3] = { false, false, false };
    for (int a = 0; a < 3; a++) {
        if (gmag[a] < 1e-7) { continue; }
        int3 n = vi;
        n[a] += s[a];
        if (label_read(labels, n, dims) != L) {
            differs[a] = true;
            float d = (0.5 - abs(f[a])) / gmag[a];
            cov = max(cov, clamp(width + 0.5 - d, 0.0, 1.0));
        }
    }
    for (int a = 0; a < 2; a++) {
        for (int b = a + 1; b < 3; b++) {
            if (gmag[a] < 1e-7 || gmag[b] < 1e-7 || differs[a] || differs[b]) { continue; }
            int3 n = vi;
            n[a] += s[a];
            n[b] += s[b];
            if (label_read(labels, n, dims) == L) { continue; }
            float2 ga = float2(gx[a], gy[a]);
            float2 gb = float2(gx[b], gy[b]);
            float det = ga.x * gb.y - ga.y * gb.x;
            if (abs(det) < 1e-12) { continue; }
            float ca = float(s[a]) * 0.5 - f[a];
            float cb = float(s[b]) * 0.5 - f[b];
            float2 dp = float2(gb.y * ca - ga.y * cb, ga.x * cb - gb.x * ca) / det;
            cov = max(cov, clamp(width + 0.5 - length(dp), 0.0, 1.0));
        }
    }
    return cov;
}

fragment float4 slice_label_fragment(FullscreenOut in [[stage_in]],
                                     constant SliceLayerUniforms& u [[buffer(0)]],
                                     texture3d<uint> labels [[texture(0)]],
                                     texture2d<float> lut [[texture(1)]],
                                     texture3d<float> field [[texture(2)]],
                                     sampler linearSampler [[sampler(0)]])
{
    float2 px = in.position.xy;
    float3 tc = slice_texcoord(u, px, field, linearSampler);
    float3 size = u.textureSize.xyz;
    uint L = label_at(labels, tc, size);
    if (L == 0u) { return float4(0.0); }
    if (L == uint(u.ignoreID)) {
        if ((u.flags & FLAG_SHOW_IGNORE) == 0) { return float4(0.0); }
        // Diagonal hatching in screen space over a faint tint.
        float spacing = max(u.extra.w, 2.0);
        float m = fmod(px.x + px.y, spacing);
        float dist = min(m, spacing - m) * 0.70710678;
        float line = clamp(0.5 * u.pixelsPerPoint + 0.5 - dist, 0.0, 1.0);
        float a = u.color.a * (0.25 + 0.75 * line);
        return float4(u.color.rgb * a, a);
    }
    float4 c = label_color(lut, L);
    if (c.a <= 0.0) { return float4(0.0); }
    float fill = ((u.flags & FLAG_FILL) != 0) ? u.extra.x : 0.0;
    float outline = 0.0;
    if ((u.flags & FLAG_OUTLINE) != 0) {
        float3 dtdx = u.pixelToTexture[0].xyz;
        float3 dtdy = u.pixelToTexture[1].xyz;
        outline = label_outline_coverage(labels, tc, size, L, dtdx, dtdy, u.extra.z) * u.extra.y;
    }
    float a = c.a * (outline + fill * (1.0 - outline));
    return float4(c.rgb * a, a);
}

fragment float4 slice_probability_fragment(FullscreenOut in [[stage_in]],
                                           constant SliceLayerUniforms& u [[buffer(0)]],
                                           texture3d<float> volume [[texture(0)]],
                                           texture2d<float> lut [[texture(1)]],
                                           texture3d<float> field [[texture(2)]],
                                           sampler linearSampler [[sampler(0)]])
{
    float2 px = in.position.xy;
    float3 tc = slice_texcoord(u, px, field, linearSampler);
    if (!inside_unit(tc)) { return float4(0.0); }
    float3 size = u.textureSize.xyz;
    float p = sample_scalar(volume, linearSampler, tc, size, u.interpolation) * u.valueMap.x + u.valueMap.y;
    if (is_nan_bits(p)) { return float4(0.0); }
    float threshold = u.window.z;
    float4 result = float4(0.0);
    if ((u.flags & FLAG_FILL) != 0 && p >= threshold) {
        float t = (p - u.window.x) * u.window.y;
        float4 c = lut_color(lut, linearSampler, t, u.lutRow);
        float a = c.a * u.window.w;
        result = float4(c.rgb * a, a);
    }
    if ((u.flags & FLAG_CONTOUR) != 0) {
        // Anti-aliased iso-line: distance to the threshold crossing from the
        // value and its screen-space gradient.
        float3 dx = u.pixelToTexture[0].xyz;
        float3 dy = u.pixelToTexture[1].xyz;
        float sx1 = sample_scalar(volume, linearSampler, tc + dx, size, u.interpolation);
        float sx0 = sample_scalar(volume, linearSampler, tc - dx, size, u.interpolation);
        float sy1 = sample_scalar(volume, linearSampler, tc + dy, size, u.interpolation);
        float sy0 = sample_scalar(volume, linearSampler, tc - dy, size, u.interpolation);
        float2 g = float2(sx1 - sx0, sy1 - sy0) * (0.5 * u.valueMap.x);
        float gl = max(length(g), 1e-6);
        float d = abs(p - threshold) / gl;
        float a = clamp(0.5 * u.extra.x + 0.5 - d, 0.0, 1.0) * u.extra.y * u.color.a;
        result = float4(u.color.rgb * a, a) + result * (1.0 - a);
    }
    return result;
}
"""#
}
