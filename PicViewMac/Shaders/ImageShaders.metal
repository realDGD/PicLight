#include <metal_stdlib>
using namespace metal;

// The quad arrives already in clip space. The CPU computes its four corners from the
// same viewport math the Quartz fallback uses (ViewportState is the only viewport
// model), so the two renderers cannot drift: the shader never sees zoom, pan,
// rotation or mirroring as separate concepts.
struct ImageVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Two plain arrays rather than a struct: a Swift struct with `Array` fields holds
// heap pointers, not inline elements, so passing one to `setVertexBytes` would hand
// the GPU pointers to read as floats.
vertex ImageVertexOut imageVertex(uint vertexID [[vertex_id]],
                                  constant float2 *corners [[buffer(0)]],
                                  constant float2 *uvs [[buffer(1)]]) {
    ImageVertexOut out;
    out.position = float4(corners[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

// Premultiplied source-over: the texture is premultiplied (ImageIO hands back
// premultiplied-first for thumbnails, and the materializer normalizes to
// premultiplied-last), so the source factor is one.
fragment float4 imageFragment(ImageVertexOut in [[stage_in]],
                              texture2d<float> image [[texture(0)]],
                              sampler imageSampler [[sampler(0)]]) {
    return image.sample(imageSampler, in.uv);
}
