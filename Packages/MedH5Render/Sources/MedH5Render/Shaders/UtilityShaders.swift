/// MSL compute kernels: building label indicators for the 3-D view, and a
/// probe reporting the byte size of every struct shared with Swift, so a
/// test can prove both sides agree on the layouts.
enum UtilityShaders {
    static let source = #"""
// Builds a label layer's indicator (1 where a visible class is) over a
// region (texture order x, y, z).
kernel void label_indicator_kernel(texture3d<uint> labels [[texture(0)]],
                                   texture2d<float> lut [[texture(1)]],
                                   texture3d<float, access::write> indicator [[texture(2)]],
                                   constant uint4& origin [[buffer(0)]],
                                   constant uint4& size [[buffer(1)]],
                                   uint3 gid [[thread_position_in_grid]])
{
    if (any(gid >= size.xyz)) { return; }
    uint3 p = gid + origin.xyz;
    uint L = labels.read(p).r;
    float v = (L != 0u && label_color(lut, L).a > 0.0) ? 1.0 : 0.0;
    indicator.write(float4(v), p);
}

kernel void layout_probe(device uint* out [[buffer(0)]],
                         uint id [[thread_position_in_grid]])
{
    if (id != 0u) { return; }
    out[0] = sizeof(SliceLayerUniforms);
    out[1] = sizeof(OverlayVertex);
    out[2] = sizeof(OverlayUniforms);
    out[3] = sizeof(VolumeUniforms);
    out[4] = sizeof(VolumeLabelUniforms);
    out[5] = sizeof(CompositeUniforms);
    out[6] = sizeof(MeshVertexIn);
    out[7] = sizeof(MeshUniforms);
    out[8] = sizeof(PlaneVertex);
    out[9] = sizeof(PlaneUniforms);
}
"""#
}
