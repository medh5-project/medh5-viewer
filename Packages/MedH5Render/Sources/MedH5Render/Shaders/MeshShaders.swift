/// MSL for triangle meshes (Blinn-Phong, two-sided, premultiplied output)
/// and for the slice planes drawn in the 3-D view (filled, textured or
/// outlined polygons in world space).
///
/// `MeshUniforms`, `PlaneVertex` and `PlaneUniforms` mirror the Swift structs.
enum MeshShaders {
    static let source = #"""
struct MeshVertexIn {
    packed_float3 position;
    packed_float3 normal;
};

struct MeshUniforms {
    float4x4 viewProjection;
    float4x4 model;
    float4x4 normalMatrix;
    float4 color;          // straight RGBA
    float4 eye;            // xyz eye, w = 1 perspective / 0 orthographic
    float4 viewDirection;  // camera forward, world
    float4 lightDirection; // towards the light, world
    float4 material;       // (ambient, diffuse, specular, shininess)
};

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
};

vertex MeshOut mesh_vertex(uint vid [[vertex_id]],
                           const device MeshVertexIn* vertices [[buffer(0)]],
                           constant MeshUniforms& u [[buffer(1)]])
{
    MeshVertexIn v = vertices[vid];
    float4 w = u.model * float4(float3(v.position), 1.0);
    MeshOut o;
    o.position = u.viewProjection * w;
    o.world = w.xyz;
    o.normal = (u.normalMatrix * float4(float3(v.normal), 0.0)).xyz;
    return o;
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]],
                              constant MeshUniforms& u [[buffer(1)]])
{
    float3 view = (u.eye.w > 0.5) ? normalize(u.eye.xyz - in.world) : -u.viewDirection.xyz;
    float nl = length(in.normal);
    float3 n = (nl > 1e-12) ? in.normal / nl : view;
    if (dot(n, view) < 0.0) { n = -n; }
    float3 l = u.lightDirection.xyz;
    float diff = max(dot(n, l), 0.0);
    float3 h = normalize(l + view);
    float spec = pow(max(dot(n, h), 0.0), u.material.w);
    float3 rgb = u.color.rgb * (u.material.x + u.material.y * diff) + u.material.z * spec;
    float a = u.color.a;
    return float4(rgb * a, a);
}

struct PlaneVertex {
    float4 position;   // world xyz, 1
    float4 uv;         // texture coordinate (xy)
};

struct PlaneUniforms {
    float4x4 viewProjection;
    float4 color;      // straight RGBA (tint and opacity when textured)
    int textured;
    int pad0;
    int pad1;
    int pad2;
};

struct PlaneOut {
    float4 position [[position]];
    float2 uv;
};

vertex PlaneOut plane_vertex(uint vid [[vertex_id]],
                             const device PlaneVertex* vertices [[buffer(0)]],
                             constant PlaneUniforms& u [[buffer(1)]])
{
    PlaneOut o;
    o.position = u.viewProjection * float4(vertices[vid].position.xyz, 1.0);
    o.uv = vertices[vid].uv.xy;
    return o;
}

fragment float4 plane_fragment(PlaneOut in [[stage_in]],
                               constant PlaneUniforms& u [[buffer(1)]],
                               texture2d<float> image [[texture(0)]],
                               sampler linearSampler [[sampler(0)]])
{
    float4 c = u.color;
    if (u.textured != 0) {
        float4 t = image.sample(linearSampler, in.uv);
        // Slice renders are premultiplied over black; show them opaque.
        c = float4(t.rgb * u.color.rgb, u.color.a);
    }
    return float4(c.rgb * c.a, c.a);
}
"""#
}
