#include <metal_stdlib>
using namespace metal;

static float softCircle(float2 point, float2 center, float radius, float feather) {
    return 1.0 - smoothstep(radius - feather, radius + feather, distance(point, center));
}

static float cloudShape(float2 point, float2 center, float scale) {
    float body = softCircle(point, center, 0.18 * scale, 0.05 * scale);
    float left = softCircle(point, center + float2(-0.17, 0.025) * scale, 0.135 * scale, 0.045 * scale);
    float crown = softCircle(point, center + float2(-0.025, -0.09) * scale, 0.15 * scale, 0.05 * scale);
    float right = softCircle(point, center + float2(0.17, 0.035) * scale, 0.12 * scale, 0.045 * scale);
    return smoothstep(0.05, 0.92, max(max(body, left), max(crown, right)));
}

/// Palette-driven sky. Every color comes from the active `Palette`, so a different
/// child seed or the night palette restyles the background without shader changes.
/// `cloudAmount` fades the clouds out, for night light.
[[ stitchable ]] half4 sleepClouds(
    float2 position,
    half4 source,
    float time,
    float2 size,
    half4 skyTop,
    half4 skyMiddle,
    half4 skyBottom,
    half4 cloud,
    half4 shade,
    float cloudAmount
) {
    float2 safeSize = max(size, float2(1.0));
    float2 uv = position / safeSize;
    float aspect = safeSize.x / safeSize.y;
    float2 field = float2(uv.x * aspect, uv.y);

    float3 sky = mix(float3(skyTop.rgb), float3(skyMiddle.rgb), smoothstep(0.0, 0.52, uv.y));
    sky = mix(sky, float3(skyBottom.rgb), smoothstep(0.48, 1.0, uv.y));

    float x1 = aspect * 0.62 + sin(time * 0.020) * 0.14;
    float x2 = aspect * 0.18 + sin(time * 0.013 + 2.1) * 0.12;
    float x3 = aspect * 0.70 + sin(time * 0.009 + 4.2) * 0.16;

    float clouds = 0.0;
    clouds = max(clouds, cloudShape(field, float2(x1, 0.20 + 0.008 * sin(time * 0.11)), 0.44) * 0.95);
    clouds = max(clouds, cloudShape(field, float2(x2, 0.50 + 0.007 * cos(time * 0.08)), 0.38) * 0.85);
    clouds = max(clouds, cloudShape(field, float2(x3, 0.76 + 0.006 * sin(time * 0.07)), 0.34) * 0.70);

    float shadow = 0.0;
    shadow = max(shadow, cloudShape(field, float2(x1, 0.212), 0.45) * 0.30);
    shadow = max(shadow, cloudShape(field, float2(x2, 0.512), 0.39) * 0.22);

    float3 color = mix(sky, float3(shade.rgb), saturate(shadow * cloudAmount));
    color = mix(color, float3(cloud.rgb), saturate(clouds * cloudAmount));

    return half4(half3(saturate(color)), source.a);
}
