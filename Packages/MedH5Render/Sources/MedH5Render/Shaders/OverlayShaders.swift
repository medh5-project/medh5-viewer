/// MSL for vector overlays in the slice view. Geometry is tessellated on the
/// CPU into screen-space quads; each fragment evaluates a signed distance to
/// its primitive (a capsule for line segments, a ring, a disc or a marker
/// shape) for analytic anti-aliasing, and dashes from the arc length. Filled
/// polygons use the stencil buffer (even-odd: invert, then cover).
///
/// `OverlayVertex` mirrors the Swift struct of the same name.
enum OverlayShaders {
    static let source = #"""
struct OverlayVertex {
    float2 position;   // drawable pixels, top-left origin
    float2 local;      // primitive-local coordinates, pixels
    float4 color;      // straight RGBA
    float4 shape;      // kind-specific parameters
    float4 style;      // (dash on, dash off, dash phase, kind)
};

struct OverlayUniforms {
    float2 viewportSize;
    float2 pad;
};

struct OverlayOut {
    float4 position [[position]];
    float2 local;
    float4 color;
    float4 shape [[flat]];
    float4 style [[flat]];
};

vertex OverlayOut overlay_vertex(uint vid [[vertex_id]],
                                 const device OverlayVertex* vertices [[buffer(0)]],
                                 constant OverlayUniforms& u [[buffer(1)]])
{
    OverlayVertex v = vertices[vid];
    OverlayOut o;
    o.position = float4(v.position.x / u.viewportSize.x * 2.0 - 1.0,
                        1.0 - v.position.y / u.viewportSize.y * 2.0, 0.0, 1.0);
    o.local = v.local;
    o.color = v.color;
    o.shape = v.shape;
    o.style = v.style;
    return o;
}

inline float dash_coverage(float arc, float on, float off) {
    if (on <= 0.0 || off <= 0.0) { return 1.0; }
    float period = on + off;
    float m = arc - period * floor(arc / period);
    float sd = (m <= on) ? -min(m, on - m) : min(m - on, period - m);
    return clamp(0.5 - sd, 0.0, 1.0);
}

// Marker shapes: 0 circle, 1 square, 2 diamond, 3 triangle, 4 cross, 5 plus.
inline float marker_coverage(float2 p, float r, int shape, bool filled, float hw) {
    float d;
    if (shape == 4 || shape == 5) {
        float2 q = (shape == 4) ? float2(p.x + p.y, p.x - p.y) * 0.70710678 : p;
        float2 a = abs(q);
        float arm = (shape == 4) ? r * 1.15 : r;
        float dLine = min(max(a.x - hw, a.y - arm), max(a.y - hw, a.x - arm));
        return clamp(0.5 - dLine, 0.0, 1.0);
    }
    if (shape == 1) {
        float2 q = abs(p) - r * 0.8862;
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    } else if (shape == 2) {
        d = (abs(p.x) + abs(p.y) - r * 1.1) * 0.70710678;
    } else if (shape == 3) {
        // Equilateral triangle pointing up on screen (y grows downwards).
        const float k = 1.7320508;
        float rr = r * 1.05;
        float2 q = float2(abs(p.x) - rr, -p.y + rr / k);
        if (q.x + k * q.y > 0.0) { q = float2(q.x - k * q.y, -k * q.x - q.y) * 0.5; }
        q.x -= clamp(q.x, -2.0 * rr, 0.0);
        d = -length(q) * sign(q.y);
    } else {
        d = length(p) - r;
    }
    if (filled) { return clamp(0.5 - d, 0.0, 1.0); }
    return clamp(hw + 0.5 - abs(d), 0.0, 1.0);
}

// Kinds: 0 solid, 1 line segment (capsule), 2 ring, 3 disc, 4 marker.
fragment float4 overlay_fragment(OverlayOut in [[stage_in]]) {
    int kind = int(in.style.w + 0.5);
    float coverage = 1.0;
    if (kind == 1) {
        float s = in.local.x;
        float len = in.shape.x;
        float hw = in.shape.y;
        float dx = max(max(-s, s - len), 0.0);
        float d = length(float2(dx, in.local.y));
        coverage = clamp(hw + 0.5 - d, 0.0, 1.0);
        coverage *= dash_coverage(in.style.z + s, in.style.x, in.style.y);
    } else if (kind == 2) {
        float r = in.shape.x;
        float hw = in.shape.y;
        float len = length(in.local);
        coverage = clamp(hw + 0.5 - abs(len - r), 0.0, 1.0);
        if (in.style.x > 0.0) {
            float ang = atan2(in.local.y, in.local.x) + M_PI_F;
            coverage *= dash_coverage(ang * r, in.style.x, in.style.y);
        }
    } else if (kind == 3) {
        coverage = clamp(in.shape.x + 0.5 - length(in.local), 0.0, 1.0);
    } else if (kind == 4) {
        coverage = marker_coverage(in.local, in.shape.x, int(in.shape.y + 0.5), in.shape.z > 0.5, in.shape.w);
    }
    float a = in.color.a * coverage;
    return float4(in.color.rgb * a, a);
}
"""#
}
