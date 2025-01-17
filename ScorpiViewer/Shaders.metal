//
//  Shaders.metal
//  ScorpiViewer
//
//  Created by alex fishman on 16/01/2025.
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
    float4 positions[] = {
        {-1.0, -1.0, 0.0, 1.0},
        { 1.0, -1.0, 0.0, 1.0},
        {-1.0,  1.0, 0.0, 1.0},
        { 1.0,  1.0, 0.0, 1.0}
    };

    float2 texCoords[] = {
        {0.0, 1.0},
        {1.0, 1.0},
        {0.0, 0.0},
        {1.0, 0.0}
    };

    VertexOut out;
    out.position = positions[vertexID];
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 fragment_main(float2 texCoord [[stage_in]], texture2d<float> texture [[texture(0)]]) {
    constexpr sampler textureSampler (mag_filter::linear, min_filter::linear);
    return texture.sample(textureSampler, texCoord);
}
