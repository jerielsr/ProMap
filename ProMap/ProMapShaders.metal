#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float2 sourceUV;
};

vertex VertexOutput surfaceVertex(
    uint vertexID [[vertex_id]],
    constant float4 *vertices [[buffer(0)]]
) {
    VertexOutput output;
    float4 meshVertex = vertices[vertexID];
    float2 coordinate = meshVertex.xy;
    output.position = float4(coordinate.x * 2.0 - 1.0, 1.0 - coordinate.y * 2.0, 0.0, 1.0);
    output.sourceUV = meshVertex.zw;
    return output;
}

bool pointInPolygon(float2 point, constant float2 *polygon, uint count) {
    if (count < 3) return true;
    bool inside = false;
    uint previous = count - 1;
    for (uint current = 0; current < count; current++) {
        float2 a = polygon[current];
        float2 b = polygon[previous];
        bool crosses = ((a.y > point.y) != (b.y > point.y))
            && (point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x);
        if (crosses) inside = !inside;
        previous = current;
    }
    return inside;
}

float distanceToSegment(float2 point, float2 start, float2 end) {
    float2 segment = end - start;
    float lengthSquared = dot(segment, segment);
    if (lengthSquared < 0.000001) return distance(point, start);
    float amount = clamp(dot(point - start, segment) / lengthSquared, 0.0, 1.0);
    return distance(point, start + segment * amount);
}

float3 calibrationColor(
    float2 uv,
    float pattern,
    constant float2 *maskPoints,
    constant uint *maskPathPointCounts,
    uint maskPathCount
) {
    if (pattern < 1.5) {
        float2 grid = abs(fract(uv * 10.0) - 0.5);
        bool line = min(grid.x, grid.y) > 0.465;
        bool center = abs(uv.x - 0.5) < 0.004 || abs(uv.y - 0.5) < 0.004;
        return center ? float3(1.0, 0.35, 0.15) : (line ? float3(0.72) : float3(0.10));
    }
    if (pattern < 2.5) {
        bool light = ((uint(floor(uv.x * 8.0)) + uint(floor(uv.y * 8.0))) % 2) == 0;
        return light ? float3(0.78) : float3(0.16);
    }
    if (pattern < 3.5) {
        uint bar = min(uint(floor(uv.x * 7.0)), 6u);
        const float3 bars[7] = {
            float3(1.0), float3(1.0, 1.0, 0.0), float3(0.0, 1.0, 1.0),
            float3(0.0, 1.0, 0.0), float3(1.0, 0.0, 1.0),
            float3(1.0, 0.0, 0.0), float3(0.0, 0.0, 1.0)
        };
        return bars[bar];
    }
    float nearestEdge = 1.0;
    uint pointOffset = 0;
    for (uint pathIndex = 0; pathIndex < maskPathCount; pathIndex++) {
        uint pointCount = maskPathPointCounts[pathIndex];
        for (uint index = 0; index < pointCount; index++) {
            uint next = (index + 1) % pointCount;
            nearestEdge = min(nearestEdge, distanceToSegment(
                uv,
                maskPoints[pointOffset + index],
                maskPoints[pointOffset + next]
            ));
        }
        pointOffset += pointCount;
    }
    return nearestEdge < 0.012 ? float3(0.2, 1.0, 0.55) : float3(0.025);
}

float3 srgbToLinear(float3 color) {
    float3 low = color / 12.92;
    float3 high = pow(max((color + 0.055) / 1.055, float3(0.0)), 2.4);
    return select(high, low, color <= 0.04045);
}

float3 linearToSRGB(float3 color) {
    float3 low = color * 12.92;
    float3 high = 1.055 * pow(max(color, float3(0.0)), 1.0 / 2.4) - 0.055;
    return select(high, low, color <= 0.0031308);
}

float3 correctedColor(float3 color, constant float4 &adjustments, constant float3 &rgbGain, uint looks) {
    if (all(abs(adjustments - float4(1.0, 1.0, 0.0, 1.0)) < 0.0001)
        && all(abs(rgbGain - float3(1.0)) < 0.0001)
        && looks == 0u) {
        return color;
    }
    color = srgbToLinear(color);
    color *= exp2(adjustments.z);
    color = (color - 0.5) * adjustments.x + 0.5;
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luminance), color, adjustments.y);
    color = pow(max(color, float3(0.0)), float3(1.0 / max(adjustments.w, 0.001)));
    color *= rgbGain;

    if ((looks & 1u) != 0u) {
        luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = float3(luminance);
    }
    if ((looks & 2u) != 0u) {
        color = float3(
            dot(color, float3(0.393, 0.769, 0.189)),
            dot(color, float3(0.349, 0.686, 0.168)),
            dot(color, float3(0.272, 0.534, 0.131))
        );
    }
    if ((looks & 4u) != 0u) {
        color = 1.0 - color;
    }
    return linearToSRGB(clamp(color, 0.0, 1.0));
}

float hash21(float2 point) {
    float3 p3 = fract(float3(point.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float valueNoise(float2 point) {
    float2 cell = floor(point);
    float2 local = fract(point);
    local = local * local * (3.0 - 2.0 * local);
    float lower = mix(hash21(cell), hash21(cell + float2(1.0, 0.0)), local.x);
    float upper = mix(hash21(cell + float2(0.0, 1.0)), hash21(cell + float2(1.0, 1.0)), local.x);
    return mix(lower, upper, local.y);
}

float cloudNoise(float2 point) {
    float total = 0.0;
    float amplitude = 0.5;
    float normalization = 0.0;
    for (uint octave = 0; octave < 4; octave++) {
        total += valueNoise(point) * amplitude;
        normalization += amplitude;
        point = point * 2.03 + float2(17.1, 9.2);
        amplitude *= 0.5;
    }
    return total / max(normalization, 0.001);
}

float3 generatedSourceColor(
    float2 uv,
    constant float4 &parameters,
    constant float4 &primaryColor,
    constant float4 &secondaryColor
) {
    float kind = parameters.x;
    float speed = max(parameters.y, 0.0);
    float scale = max(parameters.z, 0.1);
    float time = parameters.w * speed;
    if (kind < 1.5) return primaryColor.rgb;

    if (kind < 2.5) {
        float angle = primaryColor.a + time * 0.12;
        float2 direction = float2(cos(angle), sin(angle));
        float projection = dot(uv - 0.5, direction) * scale + 0.5;
        float drift = sin(time * 0.2 + (uv.x + uv.y) * 3.14159265) * 0.12;
        return mix(primaryColor.rgb, secondaryColor.rgb, smoothstep(0.0, 1.0, clamp(projection + drift, 0.0, 1.0)));
    }

    if (kind < 3.5) {
        float2 direction = float2(cos(primaryColor.a), sin(primaryColor.a));
        float2 starSpace = uv * (42.0 * scale) + direction * time * 0.08;
        float2 cell = floor(starSpace);
        float2 local = fract(starSpace) - 0.5;
        float seed = hash21(cell);
        float radius = mix(0.018, 0.09, hash21(cell + 14.7));
        float shape = 1.0 - smoothstep(radius * 0.25, radius, length(local));
        float twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(time * (0.8 + seed * 2.8) + seed * 50.0));
        float star = shape * twinkle * step(0.84, seed);
        return mix(primaryColor.rgb, secondaryColor.rgb, star);
    }

    float2 direction = float2(cos(primaryColor.a), sin(primaryColor.a));
    float2 cloudSpace = uv * (3.2 * scale) + direction * time * 0.018;
    float cloud = cloudNoise(cloudSpace);
    float coverage = smoothstep(0.34, 0.76, cloud);
    return mix(primaryColor.rgb, secondaryColor.rgb, coverage);
}

fragment float4 texturedFragment(
    VertexOutput input [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    constant float *homography [[buffer(0)]],
    constant float2 &outputSize [[buffer(1)]],
    constant float2 *maskPoints [[buffer(2)]],
    constant uint &maskPathCount [[buffer(3)]],
    constant float4 &settings [[buffer(4)]],
    constant float4 &colorAdjustments [[buffer(5)]],
    constant float3 &rgbGain [[buffer(6)]],
    constant uint &colorLooks [[buffer(7)]],
    constant float4 *effectParameters [[buffer(8)]],
    constant float4 *effectColors [[buffer(9)]],
    constant uint &effectCount [[buffer(10)]],
    constant float &maskFeather [[buffer(11)]],
    constant uint &useMeshWarp [[buffer(12)]],
    constant float4 &edgeBlendWidths [[buffer(13)]],
    constant uint *maskPathPointCounts [[buffer(14)]],
    constant uint *maskPathOperations [[buffer(15)]],
    constant float4 &contentTransform [[buffer(16)]],
    constant float &contentRotation [[buffer(17)]],
    constant uint &contentFlips [[buffer(18)]],
    constant float2 *outputMaskPoints [[buffer(19)]],
    constant uint *outputMaskPointCounts [[buffer(20)]],
    constant uint &outputMaskCount [[buffer(21)]],
    constant float &outputMaskFeather [[buffer(22)]],
    constant float4 &generatorParameters [[buffer(23)]],
    constant float4 &generatorPrimaryColor [[buffer(24)]],
    constant float4 &generatorSecondaryColor [[buffer(25)]],
    constant float4 &layerContentTransform [[buffer(26)]],
    constant float &layerContentRotation [[buffer(27)]],
    constant uint &layerContentFlips [[buffer(28)]]
) {
    constexpr sampler sourceSampler(address::clamp_to_edge, filter::linear);
    float2 outputUV = input.position.xy / outputSize;
    float outputMaskCoverage = 0.0;
    uint outputPointOffset = 0;
    for (uint pathIndex = 0; pathIndex < outputMaskCount; pathIndex++) {
        uint pointCount = outputMaskPointCounts[pathIndex];
        bool insidePath = pointInPolygon(outputUV, outputMaskPoints + outputPointOffset, pointCount);
        float edgeDistance = 1.0;
        for (uint index = 0; index < pointCount; index++) {
            uint next = (index + 1) % pointCount;
            edgeDistance = min(edgeDistance, distanceToSegment(
                outputUV,
                outputMaskPoints[outputPointOffset + index],
                outputMaskPoints[outputPointOffset + next]
            ));
        }
        float pathCoverage = outputMaskFeather > 0.000001
            ? (insidePath ? smoothstep(0.0, outputMaskFeather, edgeDistance) : 0.0)
            : (insidePath ? 1.0 : 0.0);
        outputMaskCoverage = max(outputMaskCoverage, pathCoverage);
        outputPointOffset += pointCount;
    }
    float denominator = homography[6] * outputUV.x + homography[7] * outputUV.y + homography[8];
    if (abs(denominator) < 0.000001) return float4(0.0);
    float2 sourceUV = input.sourceUV;
    if (useMeshWarp == 0u) {
        sourceUV = float2(
            (homography[0] * outputUV.x + homography[1] * outputUV.y + homography[2]) / denominator,
            (homography[3] * outputUV.x + homography[4] * outputUV.y + homography[5]) / denominator
        );
    }
    if (any(sourceUV < 0.0) || any(sourceUV > 1.0)) return float4(0.0);

    float includeCoverage = 0.0;
    float exclusionCoverage = 0.0;
    uint pointOffset = 0;
    for (uint pathIndex = 0; pathIndex < maskPathCount; pathIndex++) {
        uint pointCount = maskPathPointCounts[pathIndex];
        bool insidePath = pointInPolygon(sourceUV, maskPoints + pointOffset, pointCount);
        float pathEdgeDistance = 1.0;
        for (uint index = 0; index < pointCount; index++) {
            uint next = (index + 1) % pointCount;
            pathEdgeDistance = min(pathEdgeDistance, distanceToSegment(
                sourceUV,
                maskPoints[pointOffset + index],
                maskPoints[pointOffset + next]
            ));
        }
        float pathCoverage = maskFeather > 0.000001
            ? (insidePath ? smoothstep(0.0, maskFeather, pathEdgeDistance) : 0.0)
            : (insidePath ? 1.0 : 0.0);
        if (maskPathOperations[pathIndex] == 0u) {
            includeCoverage = max(includeCoverage, pathCoverage);
        } else {
            exclusionCoverage = max(exclusionCoverage, pathCoverage);
        }
        pointOffset += pointCount;
    }
    float maskCoverage = min(includeCoverage, 1.0 - exclusionCoverage);
    if (settings.w > 0.5) maskCoverage = 1.0 - maskCoverage;
    if (maskCoverage <= 0.0) return float4(0.0);

    float4 color;
    if (settings.z > 0.0) {
        color = float4(calibrationColor(
            sourceUV,
            settings.z,
            maskPoints,
            maskPathPointCounts,
            maskPathCount
        ), 1.0);
    } else {
        float2 contentCenter = sourceUV - 0.5;
        if ((contentFlips & 1u) != 0u) contentCenter.x = -contentCenter.x;
        if ((contentFlips & 2u) != 0u) contentCenter.y = -contentCenter.y;
        float rotationCosine = cos(contentRotation);
        float rotationSine = sin(contentRotation);
        float2 rotatedContent = float2(
            rotationCosine * contentCenter.x - rotationSine * contentCenter.y,
            rotationSine * contentCenter.x + rotationCosine * contentCenter.y
        );
        float2 sampleUV = rotatedContent / max(contentTransform.xy, float2(0.1)) + 0.5 + contentTransform.zw;
        float2 layerCenter = sampleUV - 0.5;
        if ((layerContentFlips & 1u) != 0u) layerCenter.x = -layerCenter.x;
        if ((layerContentFlips & 2u) != 0u) layerCenter.y = -layerCenter.y;
        float layerRotationCosine = cos(layerContentRotation);
        float layerRotationSine = sin(layerContentRotation);
        float2 rotatedLayer = float2(
            layerRotationCosine * layerCenter.x - layerRotationSine * layerCenter.y,
            layerRotationSine * layerCenter.x + layerRotationCosine * layerCenter.y
        );
        sampleUV = rotatedLayer / max(layerContentTransform.xy, float2(0.1)) + 0.5 + layerContentTransform.zw;
        if (any(sampleUV < 0.0) || any(sampleUV > 1.0)) return float4(0.0);
        if (generatorParameters.x > 0.5) {
            color = float4(generatedSourceColor(
                sampleUV,
                generatorParameters,
                generatorPrimaryColor,
                generatorSecondaryColor
            ), 1.0);
        } else {
            color = sourceTexture.sample(sourceSampler, sampleUV);
        }
        for (uint effectIndex = 0; effectIndex < effectCount; effectIndex++) {
            float4 parameters = effectParameters[effectIndex];
            if (parameters.x < 1.5) {
                float2 textureSize = generatorParameters.x > 0.5
                    ? max(outputSize, float2(1.0))
                    : float2(sourceTexture.get_width(), sourceTexture.get_height());
                float2 texel = parameters.y / textureSize;
                if (generatorParameters.x > 0.5) {
                    float3 softened = generatedSourceColor(sampleUV, generatorParameters, generatorPrimaryColor, generatorSecondaryColor);
                    softened += generatedSourceColor(sampleUV + float2(texel.x, 0.0), generatorParameters, generatorPrimaryColor, generatorSecondaryColor);
                    softened += generatedSourceColor(sampleUV - float2(texel.x, 0.0), generatorParameters, generatorPrimaryColor, generatorSecondaryColor);
                    softened += generatedSourceColor(sampleUV + float2(0.0, texel.y), generatorParameters, generatorPrimaryColor, generatorSecondaryColor);
                    softened += generatedSourceColor(sampleUV - float2(0.0, texel.y), generatorParameters, generatorPrimaryColor, generatorSecondaryColor);
                    color.rgb = softened * 0.2;
                } else {
                    float4 softened = color;
                    softened += sourceTexture.sample(sourceSampler, sampleUV + float2(texel.x, 0.0));
                    softened += sourceTexture.sample(sourceSampler, sampleUV - float2(texel.x, 0.0));
                    softened += sourceTexture.sample(sourceSampler, sampleUV + float2(0.0, texel.y));
                    softened += sourceTexture.sample(sourceSampler, sampleUV - float2(0.0, texel.y));
                    color = softened * 0.2;
                }
            } else if (parameters.x < 2.5) {
                float separation = distance(color.rgb, effectColors[effectIndex].rgb);
                color.a *= smoothstep(parameters.y, parameters.y + parameters.z, separation);
            } else if (parameters.x < 3.5) {
                color.rgb *= parameters.y;
            } else if (parameters.x < 4.5) {
                float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
                color.rgb = mix(float3(luminance), color.rgb, parameters.y);
            } else if (parameters.x < 5.5) {
                float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
                color.rgb = float3(luminance);
            } else if (parameters.x < 6.5) {
                color.rgb = float3(
                    dot(color.rgb, float3(0.393, 0.769, 0.189)),
                    dot(color.rgb, float3(0.349, 0.686, 0.168)),
                    dot(color.rgb, float3(0.272, 0.534, 0.131))
                );
            } else if (parameters.x < 7.5) {
                color.rgb = 1.0 - color.rgb;
            } else if (parameters.x < 8.5) {
                float2 textureSize = generatorParameters.x > 0.5
                    ? max(outputSize, float2(1.0))
                    : float2(sourceTexture.get_width(), sourceTexture.get_height());
                float blockSize = max(parameters.y, 1.0);
                float2 pixelatedUV = (floor(sampleUV * textureSize / blockSize) + 0.5) * blockSize / textureSize;
                if (generatorParameters.x > 0.5) {
                    color.rgb = generatedSourceColor(pixelatedUV, generatorParameters, generatorPrimaryColor, generatorSecondaryColor);
                } else {
                    color = sourceTexture.sample(sourceSampler, pixelatedUV);
                }
            } else if (parameters.x < 9.5) {
                float angle = parameters.y * 0.01745329252;
                float cosine = cos(angle);
                float sine = sin(angle);
                float3 original = color.rgb;
                color.rgb = float3(
                    (0.213 + cosine * 0.787 - sine * 0.213) * original.r
                        + (0.715 - cosine * 0.715 - sine * 0.715) * original.g
                        + (0.072 - cosine * 0.072 + sine * 0.928) * original.b,
                    (0.213 - cosine * 0.213 + sine * 0.143) * original.r
                        + (0.715 + cosine * 0.285 + sine * 0.140) * original.g
                        + (0.072 - cosine * 0.072 - sine * 0.283) * original.b,
                    (0.213 - cosine * 0.213 - sine * 0.787) * original.r
                        + (0.715 - cosine * 0.715 + sine * 0.715) * original.g
                        + (0.072 + cosine * 0.928 + sine * 0.072) * original.b
                );
            } else if (parameters.x < 10.5) {
                color.rgb = mix(color.rgb, effectColors[effectIndex].rgb, clamp(parameters.y, 0.0, 1.0));
            } else if (parameters.x < 11.5) {
                float2 texel = max(parameters.y, 0.0) / float2(sourceTexture.get_width(), sourceTexture.get_height());
                float3 surrounding = sourceTexture.sample(sourceSampler, sampleUV + float2(texel.x, 0.0)).rgb
                    + sourceTexture.sample(sourceSampler, sampleUV - float2(texel.x, 0.0)).rgb
                    + sourceTexture.sample(sourceSampler, sampleUV + float2(0.0, texel.y)).rgb
                    + sourceTexture.sample(sourceSampler, sampleUV - float2(0.0, texel.y)).rgb;
                color.rgb = clamp(color.rgb * 5.0 - surrounding, 0.0, 1.0);
            } else if (parameters.x < 12.5) {
                float2 centered = (sampleUV - 0.5) * 1.41421356;
                float vignette = smoothstep(0.25, 0.95, length(centered));
                color.rgb *= 1.0 - clamp(parameters.y, 0.0, 1.0) * vignette;
            } else if (parameters.x < 13.5) {
                float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
                color.a *= smoothstep(parameters.y, parameters.y + parameters.z, luminance);
            } else {
                float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
                color.rgb = float3(step(parameters.y, luminance));
            }
        }
        color.rgb = correctedColor(color.rgb, colorAdjustments, rgbGain, colorLooks);
    }
    color.rgb *= settings.y;
    float outputEdgeCoverage = 1.0;
    if (edgeBlendWidths.x > 0.000001) outputEdgeCoverage *= smoothstep(0.0, edgeBlendWidths.x, outputUV.x);
    if (edgeBlendWidths.y > 0.000001) outputEdgeCoverage *= smoothstep(0.0, edgeBlendWidths.y, 1.0 - outputUV.x);
    if (edgeBlendWidths.z > 0.000001) outputEdgeCoverage *= smoothstep(0.0, edgeBlendWidths.z, outputUV.y);
    if (edgeBlendWidths.w > 0.000001) outputEdgeCoverage *= smoothstep(0.0, edgeBlendWidths.w, 1.0 - outputUV.y);
    color.a *= settings.x * maskCoverage * outputEdgeCoverage * (1.0 - outputMaskCoverage);
    return color;
}
