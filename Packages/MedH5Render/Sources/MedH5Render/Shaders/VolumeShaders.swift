/// MSL for the 3-D view: GPU ray casting through one image volume in world
/// space (MIP, MinIP, average, DVR, isosurface), label volumes as shaded
/// first-hit surfaces, and the final composite with meshes.
///
/// Rays come from the inverse view-projection, are clipped by the volume's
/// region (texture space), an optional world box and plane, and stop at the
/// resolved mesh depth, so volumes and meshes composite depth-correctly.
/// Empty space is skipped brick by brick (8³ voxels): an image brick whose
/// value range the transfer function makes transparent, or a label brick
/// with no visible class, is jumped over in one step.
/// `VolumeUniforms` and `VolumeLabelUniforms` mirror the Swift structs.
enum VolumeShaders {
    static let source = #"""
constant int VOLUME_MIP = 0;
constant int VOLUME_MINIP = 1;
constant int VOLUME_AVERAGE = 2;
constant int VOLUME_DVR = 3;
constant int VOLUME_ISO = 4;

constant int VFLAG_SHADING = 1;
constant int VFLAG_CLIP_PLANE = 2;
constant int VFLAG_CLIP_WORLD = 4;
constant int VFLAG_MESH_DEPTH = 8;
constant int VFLAG_IMAGE = 16;
constant int VFLAG_JITTER = 32;
constant int VFLAG_INVERT = 64;
constant int VFLAG_FAST = 128;
constant int VFLAG_SKIP = 256;

constant float BRICK = 8.0;

struct VolumeUniforms {
    float4x4 inverseViewProjection;
    float4x4 viewProjection;
    float4x4 worldToTexture;     // image: world -> texture coordinate
    float4x4 gradientToWorld;    // transpose of worldToTexture's linear part
    float4 eye;                  // xyz eye, w = 1 perspective / 0 orthographic
    float4 lightDirection;       // world, towards the light
    float4 clipTexMin;           // clip box in the reference volume's texture space
    float4 clipTexMax;
    float4 clipWorldMin;         // clip box in world space (VFLAG_CLIP_WORLD)
    float4 clipWorldMax;
    float4 clipPlane;            // keep n.x + d >= 0 (VFLAG_CLIP_PLANE)
    float4 isoColor;             // straight RGBA
    float4 textureSize;          // (n2, n1, n0, 0)
    float4 valueMap;             // (texel scale, texel offset, window low, 1 / window width)
    float4 tfMap;                // (tf low, 1 / tf width, opacity unit distance mm, iso value)
    float4 shading;              // (ambient, diffuse, specular, shininess)
    float4 viewport;             // (width, height, 1 / width, 1 / height) of the ray target
    float4 visibleRange;         // texel values that can contribute: (low, high, 0, 0)
    float stepSize;              // mm
    float lutRow;
    float gradientScale;         // 1 / gradient magnitude at which shading is full
    int mode;
    int maxSteps;
    int flags;
    int labelCount;
    int interpolation;
};

struct VolumeLabelUniforms {
    float4x4 worldToTexture;
    float4x4 gradientToWorld;
    float4 textureSize;
    float4 params;               // (opacity, colour probe step in mm, 0, 0)
};

inline float4 shade_surface(float3 base, float alpha, float3 normal, float3 viewDir, float4 light, float4 k) {
    float3 n = normal;
    if (dot(n, viewDir) > 0.0) { n = -n; }
    float3 l = light.xyz;
    float diff = max(dot(n, l), 0.0);
    float3 h = normalize(l - viewDir);
    float spec = pow(max(dot(n, h), 0.0), k.w);
    float3 rgb = base * (k.x + k.y * diff) + k.z * spec;
    return float4(rgb * alpha, alpha);
}

// Gradient of the texel value per unit texture coordinate.
inline float3 volume_gradient(texture3d<float> t, sampler s, float3 tc, float3 size, int interp) {
    float3 h = 1.0 / size;
    float gx = sample_scalar(t, s, tc + float3(h.x, 0.0, 0.0), size, interp)
             - sample_scalar(t, s, tc - float3(h.x, 0.0, 0.0), size, interp);
    float gy = sample_scalar(t, s, tc + float3(0.0, h.y, 0.0), size, interp)
             - sample_scalar(t, s, tc - float3(0.0, h.y, 0.0), size, interp);
    float gz = sample_scalar(t, s, tc + float3(0.0, 0.0, h.z), size, interp)
             - sample_scalar(t, s, tc - float3(0.0, 0.0, h.z), size, interp);
    return float3(gx, gy, gz) * 0.5 * size;
}

// The label indicator (1 where a visible class is) at a texture
// coordinate, hardware-interpolated; 0 outside the volume.
inline float indicator_at(texture3d<float> t, sampler s, float3 tc) {
    return inside_unit(tc) ? t.sample(s, tc).r : 0.0;
}

// A wide gradient of the indicator per unit texture coordinate: eight
// trilinear samples at the corners of a cube `spread` voxels from the
// point (each itself a 2x2x2 average), so the stair steps of a binary
// segmentation shade smoothly.
inline float3 indicator_gradient(texture3d<float> t, sampler s, float3 tc, float3 size, float spread) {
    float3 h = spread / size;
    float3 g = float3(0.0);
    for (int c = 0; c < 8; c++) {
        float3 d = float3((c & 1) ? 1.0 : -1.0, (c & 2) ? 1.0 : -1.0, (c & 4) ? 1.0 : -1.0);
        g += d * t.sample(s, tc + d * h).r;
    }
    return g * size / (8.0 * spread);
}

// The brick holding a texture coordinate, and where the ray leaves it.
inline int3 brick_index(float3 tc, float3 size) {
    return int3(floor(tc * size / BRICK));
}

inline float brick_exit(float3 o, float3 d, int3 b, float3 size) {
    float3 lo = float3(b) * BRICK / size;
    float3 hi = float3(b + 1) * BRICK / size;
    return ray_box(o, d, lo, hi).y;
}

inline float brick_value(texture3d<float> bricks, int3 b, float defaultValue) {
    int3 dims = int3(bricks.get_width(), bricks.get_height(), bricks.get_depth());
    if (any(b < int3(0)) || any(b >= dims)) { return defaultValue; }
    return bricks.read(uint3(b)).r;
}

fragment float4 volume_raycast_fragment(FullscreenOut in [[stage_in]],
                                        constant VolumeUniforms& u [[buffer(0)]],
                                        constant VolumeLabelUniforms* labelU [[buffer(1)]],
                                        texture3d<float> volume [[texture(0)]],
                                        texture2d<float> transfer [[texture(1)]],
                                        texture2d<float> colormap [[texture(2)]],
                                        depth2d<float> meshDepth [[texture(3)]],
                                        array<texture3d<uint>, 4> labelTextures [[texture(4)]],
                                        array<texture2d<float>, 4> labelLUTs [[texture(8)]],
                                        array<texture3d<float>, 4> labelIndicators [[texture(12)]],
                                        texture3d<float> imageBricks [[texture(16)]],
                                        array<texture3d<float>, 4> labelBricks [[texture(17)]],
                                        sampler linearSampler [[sampler(0)]],
                                        sampler nearestSampler [[sampler(1)]])
{
    float2 px = in.position.xy;
    float2 ndc = float2(px.x * u.viewport.z * 2.0 - 1.0, 1.0 - px.y * u.viewport.w * 2.0);
    float4 nearH = u.inverseViewProjection * float4(ndc, 0.0, 1.0);
    float4 farH = u.inverseViewProjection * float4(ndc, 1.0, 1.0);
    float3 nearP = nearH.xyz / nearH.w;
    float3 farP = farH.xyz / farH.w;
    float3 seg = farP - nearP;
    float tEnd = length(seg);
    float3 dir = seg / tEnd;
    float3 origin = nearP;

    if ((u.flags & VFLAG_MESH_DEPTH) != 0) {
        float depth = meshDepth.sample(nearestSampler, in.uv);
        if (depth < 1.0) {
            float4 h = u.inverseViewProjection * float4(ndc, depth, 1.0);
            tEnd = min(tEnd, dot(h.xyz / h.w - origin, dir));
        }
    }

    float3 to = (u.worldToTexture * float4(origin, 1.0)).xyz;
    float3 td = (u.worldToTexture * float4(dir, 0.0)).xyz;
    float2 range = ray_box(to, td, u.clipTexMin.xyz, u.clipTexMax.xyz);
    float t0 = max(range.x, 0.0);
    float t1 = min(range.y, tEnd);
    if ((u.flags & VFLAG_CLIP_WORLD) != 0) {
        float2 wr = ray_box(origin, dir, u.clipWorldMin.xyz, u.clipWorldMax.xyz);
        t0 = max(t0, wr.x);
        t1 = min(t1, wr.y);
    }
    if ((u.flags & VFLAG_CLIP_PLANE) != 0) {
        float nd = dot(u.clipPlane.xyz, dir);
        float no = dot(u.clipPlane.xyz, origin) + u.clipPlane.w;
        if (abs(nd) < 1e-9) {
            if (no < 0.0) { t1 = -1.0; }
        } else {
            float tp = -no / nd;
            if (nd > 0.0) { t0 = max(t0, tp); } else { t1 = min(t1, tp); }
        }
    }
    if (t1 <= t0) { return float4(0.0); }

    float step = u.stepSize;
    float3 size = u.textureSize.xyz;
    bool hasImage = (u.flags & VFLAG_IMAGE) != 0;
    bool shading = (u.flags & VFLAG_SHADING) != 0;
    bool fast = (u.flags & VFLAG_FAST) != 0;
    float jitter = ((u.flags & VFLAG_JITTER) != 0) ? interleaved_gradient_noise(px) : 0.5;
    float4 acc = float4(0.0);
    float extreme = (u.mode == VOLUME_MINIP) ? BIG : -BIG;
    float sum = 0.0;
    int count = 0;
    int labelCount = min(u.labelCount, 4);
    bool labelDone[4] = { false, false, false, false };
    // Label rays in each layer's texture space, and where they cross its volume.
    float3 lto[4];
    float3 ltd[4];
    float2 lrange[4];
    for (int l = 0; l < labelCount; l++) {
        lto[l] = (labelU[l].worldToTexture * float4(origin, 1.0)).xyz;
        ltd[l] = (labelU[l].worldToTexture * float4(dir, 0.0)).xyz;
        lrange[l] = ray_box(lto[l], ltd[l], float3(0.0), float3(1.0));
        if (lrange[l].y <= lrange[l].x) { labelDone[l] = true; }
    }
    // Skipping is off for images every sample of which counts (MIP and friends).
    bool canSkip = (u.flags & VFLAG_SKIP) != 0;
    int3 imageBrickDims = int3(imageBricks.get_width(), imageBricks.get_height(), imageBricks.get_depth());
    bool havePrevious = false;
    float base = t0 + jitter * step;
    float t = base;
    int i = 0;
    while (i < u.maxSteps && t <= t1) {
        i++;
        // Empty-space skipping.
        if (canSkip) {
            bool empty = true;
            float tExit = BIG;
            if (hasImage) {
                int3 b = brick_index(to + td * t, size);
                if (all(b >= int3(0)) && all(b < imageBrickDims)) {
                    float2 mm = imageBricks.read(uint3(b)).rg;
                    if (mm.y >= u.visibleRange.x && mm.x <= u.visibleRange.y) {
                        empty = false;
                    } else {
                        tExit = min(tExit, brick_exit(to, td, b, size));
                    }
                }
            }
            for (int l = 0; l < labelCount && empty; l++) {
                if (labelDone[l] || t < lrange[l].x - step || t > lrange[l].y + step) { continue; }
                float3 lsize = labelU[l].textureSize.xyz;
                int3 b = brick_index(lto[l] + ltd[l] * t, lsize);
                if (brick_value(labelBricks[l], b, 0.0) > 0.0) {
                    empty = false;
                } else {
                    tExit = min(tExit, brick_exit(lto[l], ltd[l], b, lsize));
                }
            }
            if (empty) {
                float target = max(tExit, t + 0.5 * step);
                t = base + ceil((target - base) / step) * step;
                continue;
            }
        }

        // Segmentation surfaces: first hit on a visible class per layer.
        for (int l = 0; l < labelCount; l++) {
            if (labelDone[l]) { continue; }
            float3 ltc = lto[l] + ltd[l] * t;
            if (indicator_at(labelIndicators[l], linearSampler, ltc) < 0.5) { continue; }
            labelDone[l] = true;
            float3 lsize = labelU[l].textureSize.xyz;
            // Refine the crossing between the previous sample and this one.
            float a = max(t - step, t0);
            float b = t;
            if (indicator_at(labelIndicators[l], linearSampler, lto[l] + ltd[l] * a) >= 0.5) {
                b = a;
            } else {
                for (int k = 0; k < (fast ? 3 : 6); k++) {
                    float m = 0.5 * (a + b);
                    if (indicator_at(labelIndicators[l], linearSampler, lto[l] + ltd[l] * m) >= 0.5) { b = m; } else { a = m; }
                }
            }
            float3 htc = lto[l] + ltd[l] * b;
            // The class: the nearest visible label at the hit or just beyond it.
            float4 c = float4(0.0);
            float probe = labelU[l].params.y;
            for (int k = 0; k < 4 && c.a <= 0.0; k++) {
                uint L = label_at(labelTextures[l], lto[l] + ltd[l] * (b + float(k) * probe), lsize);
                if (L != 0u) { c = label_color(labelLUTs[l], L); }
            }
            if (c.a <= 0.0) { continue; }
            float3 g = indicator_gradient(labelIndicators[l], linearSampler, htc, lsize, 1.0);
            if (!fast) { g += indicator_gradient(labelIndicators[l], linearSampler, htc, lsize, 2.0); }
            float3 gw = (labelU[l].gradientToWorld * float4(g, 0.0)).xyz;
            float gl = length(gw);
            float3 n = (gl > 1e-6) ? -gw / gl : -dir;
            float alpha = c.a * labelU[l].params.x;
            float4 s = shade_surface(c.rgb, alpha, n, dir, u.lightDirection, u.shading);
            acc += (1.0 - acc.a) * s;
        }
        if (acc.a >= 0.995) { break; }
        if (!hasImage) { t += step; continue; }

        float3 tc = to + td * t;
        if (!inside_unit(tc)) { t += step; continue; }
        float v = sample_scalar(volume, linearSampler, tc, size, u.interpolation) * u.valueMap.x + u.valueMap.y;
        if (is_nan_bits(v)) { t += step; continue; }

        if (u.mode == VOLUME_DVR) {
            float tf = clamp((v - u.tfMap.x) * u.tfMap.y, 0.0, 1.0);
            float4 c = transfer.sample(linearSampler, float2(tf * (1023.0 / 1024.0) + 0.5 / 1024.0, 0.5));
            if (c.a > 0.0005) {
                float alpha = 1.0 - pow(max(1.0 - c.a, 0.0), step / u.tfMap.z);
                float3 rgb = c.rgb;
                if (shading) {
                    float3 g = volume_gradient(volume, linearSampler, tc, size, u.interpolation) * u.valueMap.x;
                    float3 gw = (u.gradientToWorld * float4(g, 0.0)).xyz;
                    float gl = length(gw);
                    if (gl > 1e-6) {
                        float4 sh = shade_surface(rgb, 1.0, -gw / gl, dir, u.lightDirection, u.shading);
                        rgb = mix(rgb * (u.shading.x + u.shading.y * 0.6), sh.rgb, clamp(gl * u.gradientScale, 0.0, 1.0));
                    }
                }
                acc += (1.0 - acc.a) * float4(rgb * alpha, alpha);
                if (acc.a >= 0.995) { break; }
            }
        } else if (u.mode == VOLUME_ISO) {
            if (v >= u.tfMap.w) {
                float lo = havePrevious ? max(t - step, t0) : t;
                float hi = t;
                for (int k = 0; k < 6 && havePrevious; k++) {
                    float m = 0.5 * (lo + hi);
                    float vm = sample_scalar(volume, linearSampler, to + td * m, size, u.interpolation) * u.valueMap.x + u.valueMap.y;
                    if (vm >= u.tfMap.w) { hi = m; } else { lo = m; }
                }
                float3 htc = to + td * hi;
                float3 g = volume_gradient(volume, linearSampler, htc, size, u.interpolation) * u.valueMap.x;
                float3 gw = (u.gradientToWorld * float4(g, 0.0)).xyz;
                float gl = length(gw);
                float3 n = (gl > 1e-6) ? -gw / gl : -dir;
                float4 sh = shade_surface(u.isoColor.rgb, u.isoColor.a, n, dir, u.lightDirection, u.shading);
                acc += (1.0 - acc.a) * sh;
                break;
            }
            havePrevious = true;
        } else if (u.mode == VOLUME_MIP) {
            extreme = max(extreme, v);
            count++;
        } else if (u.mode == VOLUME_MINIP) {
            extreme = min(extreme, v);
            count++;
        } else {
            sum += v;
            count++;
        }
        t += step;
    }

    if ((u.mode == VOLUME_MIP || u.mode == VOLUME_MINIP || u.mode == VOLUME_AVERAGE) && count > 0) {
        float v = (u.mode == VOLUME_AVERAGE) ? sum / float(count) : extreme;
        float tt = (v - u.valueMap.z) * u.valueMap.w;
        if ((u.flags & VFLAG_INVERT) != 0) { tt = 1.0 - tt; }
        float4 c = lut_color(colormap, linearSampler, tt, u.lutRow);
        acc += (1.0 - acc.a) * float4(c.rgb, 1.0);
    }
    return acc;
}

struct CompositeUniforms {
    float4 background;   // premultiplied
    int hasMesh;
    int pad0;
    int pad1;
    int pad2;
};

fragment float4 volume_composite_fragment(FullscreenOut in [[stage_in]],
                                          constant CompositeUniforms& u [[buffer(0)]],
                                          texture2d<float> rayTexture [[texture(0)]],
                                          texture2d<float> meshTexture [[texture(1)]],
                                          sampler linearSampler [[sampler(0)]],
                                          sampler nearestSampler [[sampler(1)]])
{
    float4 r = rayTexture.sample(linearSampler, in.uv);
    float4 under = u.background;
    if (u.hasMesh != 0) {
        float4 m = meshTexture.sample(nearestSampler, in.uv);
        under = m + (1.0 - m.a) * under;
    }
    return r + (1.0 - r.a) * under;
}

// Brick maps for empty-space skipping: per brick of 8³ voxels plus a
// one-voxel apron (what trilinear samples inside the brick can reach), the
// minimum and maximum texel (images) or the maximum indicator (labels).
kernel void brick_minmax_kernel(texture3d<float> volume [[texture(0)]],
                                texture3d<float, access::write> bricks [[texture(1)]],
                                constant uint4& origin [[buffer(0)]],
                                constant uint4& count [[buffer(1)]],
                                uint3 gid [[thread_position_in_grid]])
{
    if (any(gid >= count.xyz)) { return; }
    uint3 b = gid + origin.xyz;
    int3 dims = int3(volume.get_width(), volume.get_height(), volume.get_depth());
    int3 lo = max(int3(b) * 8 - 1, int3(0));
    int3 hi = min(int3(b) * 8 + 8, dims - 1);
    float mn = BIG;
    float mx = -BIG;
    for (int z = lo.z; z <= hi.z; z++) {
        for (int y = lo.y; y <= hi.y; y++) {
            for (int x = lo.x; x <= hi.x; x++) {
                float v = volume.read(uint3(x, y, z)).r;
                if (is_nan_bits(v)) { continue; }
                mn = min(mn, v);
                mx = max(mx, v);
            }
        }
    }
    bricks.write(float4(mn, mx, 0.0, 0.0), b);
}

kernel void brick_occupancy_kernel(texture3d<float> indicator [[texture(0)]],
                                   texture3d<float, access::write> bricks [[texture(1)]],
                                   constant uint4& origin [[buffer(0)]],
                                   constant uint4& count [[buffer(1)]],
                                   uint3 gid [[thread_position_in_grid]])
{
    if (any(gid >= count.xyz)) { return; }
    uint3 b = gid + origin.xyz;
    int3 dims = int3(indicator.get_width(), indicator.get_height(), indicator.get_depth());
    int3 lo = max(int3(b) * 8 - 1, int3(0));
    int3 hi = min(int3(b) * 8 + 8, dims - 1);
    float mx = 0.0;
    for (int z = lo.z; z <= hi.z && mx == 0.0; z++) {
        for (int y = lo.y; y <= hi.y; y++) {
            for (int x = lo.x; x <= hi.x; x++) {
                mx = max(mx, indicator.read(uint3(x, y, z)).r);
            }
        }
    }
    bricks.write(float4(mx), b);
}
"""#
}
