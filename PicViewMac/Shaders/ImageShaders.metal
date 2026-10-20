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

#include <metal_stdlib>
using namespace metal;
struct AnimationPixelParameters {uint rowBytes; uint width; uint height; uint flags; uint4 offsets;};
kernel void animationNormalize32(device const uchar* bytes [[buffer(0)]],
  constant AnimationPixelParameters& p [[buffer(1)]], texture2d<float,access::write> out [[texture(0)]],
  uint2 xy [[thread_position_in_grid]]) {
  if (xy.x>=p.width || xy.y>=p.height) return;
  uint base=xy.y*p.rowBytes+xy.x*4;
  uint4 c=uint4(bytes[base+p.offsets.x],bytes[base+p.offsets.y],bytes[base+p.offsets.z],bytes[base+p.offsets.w]);
  if (p.flags & 1) c.w=255;
  if (!(p.flags & 2)) c.xyz=(c.xyz*c.w+127)/255;
  out.write(float4(c)/255.0,xy);
}
