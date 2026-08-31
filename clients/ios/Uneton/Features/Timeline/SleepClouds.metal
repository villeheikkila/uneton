#include <metal_stdlib>
using namespace metal;

static float softCircle(float2 point, float2 center, float radius, float feather) {
    return 1.0 - smoothstep(radius - feather, radius + feather, distance(point, center));
}

static float cloudShape(float2 point, float2 center, float scale) {
    float body = softCircle(point, center, 0.18 * scale, 0.09 * scale);
    float left = softCircle(point, center + float2(-0.17, 0.025) * scale, 0.135 * scale, 0.08 * scale);
    float crown = softCircle(point, center + float2(-0.025, -0.09) * scale, 0.15 * scale, 0.085 * scale);
    float right = softCircle(point, center + float2(0.17, 0.035) * scale, 0.12 * scale, 0.075 * scale);
    return smoothstep(0.05, 0.92, max(max(body, left), max(crown, right)));
}

[[ stitchable ]] half4 sleepClouds(
    float2 position,
    half4 source,
    float time,
    float2 size
) {
    float2 safeSize = max(size, float2(1.0));
    float2 uv = position / safeSize;
    float aspect = safeSize.x / safeSize.y;
    float2 field = float2(uv.x * aspect, uv.y);

    float3 skyTop = float3(0.82, 0.90, 0.90);
    float3 skyMiddle = float3(0.85, 0.90, 0.92);
    float3 skyBottom = float3(0.89, 0.89, 0.93);
    float3 sky = mix(skyTop, skyMiddle, smoothstep(0.0, 0.52, uv.y));
    sky = mix(sky, skyBottom, smoothstep(0.48, 1.0, uv.y));

    float x1 = aspect * 0.58 + sin(time * 0.020) * 0.16;
    float x2 = aspect * 0.22 + sin(time * 0.013 + 2.1) * 0.13;
    float x3 = aspect * 0.52 + sin(time * 0.009 + 4.2) * 0.18;

    float clouds = 0.0;
    clouds += cloudShape(field, float2(x1, 0.17 + 0.008 * sin(time * 0.11)), 0.64) * 0.18;
    clouds += cloudShape(field, float2(x2, 0.48 + 0.007 * cos(time * 0.08)), 0.54) * 0.13;
    clouds += cloudShape(field, float2(x3, 0.78 + 0.006 * sin(time * 0.07)), 0.72) * 0.10;

    float shadow = 0.0;
    shadow += cloudShape(field, float2(x1, 0.185), 0.66) * 0.035;
    shadow += cloudShape(field, float2(x2, 0.495), 0.56) * 0.025;

    float3 color = mix(sky, float3(0.76, 0.83, 0.86), saturate(shadow));
    color = mix(color, float3(0.96, 0.98, 0.98), saturate(clouds));

    return half4(half3(saturate(color)), source.a);
}
