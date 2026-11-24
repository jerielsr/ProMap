#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex VertexOutput fullscreenVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    float2 position = positions[vertexID];
    VertexOutput output;
    output.position = float4(position, 0.0, 1.0);
    output.textureCoordinate = float2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
    return output;
}

fragment float4 texturedFragment(
    VertexOutput input [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    constant float &opacity [[buffer(0)]]
) {
    constexpr sampler sourceSampler(address::clamp_to_edge, filter::linear);
    float4 color = sourceTexture.sample(sourceSampler, input.textureCoordinate);
    color.a *= opacity;
    return color;
}
