#include <metal_stdlib>
using namespace metal;

/// One cycle per hour. Every motion below completes a whole number of cycles per
/// hour, so the caller can wrap time at 3600 seconds without the sky jumping.
constant float hourCycle = 6.2831853 / 3600.0;

static float softCircle(float2 point, float2 center, float radius, float feather) {
    return 1.0 - smoothstep(radius - feather, radius + feather, distance(point, center));
}

static float cloudShape(float2 point, float2 center, float scale) {
    float body = softCircle(point, center, 0.18 * scale, 0.07 * scale);
    float left = softCircle(point, center + float2(-0.17, 0.025) * scale, 0.135 * scale, 0.06 * scale);
    float crown = softCircle(point, center + float2(-0.025, -0.09) * scale, 0.15 * scale, 0.065 * scale);
    float right = softCircle(point, center + float2(0.17, 0.035) * scale, 0.12 * scale, 0.06 * scale);
    return smoothstep(0.02, 0.95, max(max(body, left), max(crown, right)));
}

static float hash(float2 point) {
    point = fract(point * float2(123.34, 456.21));
    point += dot(point, point + 45.32);
    return fract(point.x * point.y);
}

/// Sparse twinkling stars on a jittered grid, in points.
static float starField(float2 position, float time) {
    const float cellSize = 34.0;
    float2 cell = floor(position / cellSize);
    float present = step(0.62, hash(cell));
    float2 center = (cell + 0.2 + 0.6 * float2(hash(cell + 11.7), hash(cell + 3.1))) * cellSize;
    float radius = 0.6 + 0.9 * hash(cell + 7.3);
    float core = 1.0 - smoothstep(radius * 0.4, radius + 0.6, distance(position, center));
    // 90 to 240 cycles per hour: each star twinkles every 15 to 40 seconds.
    float speed = hourCycle * (90.0 + floor(hash(cell + 5.9) * 150.0));
    float twinkle = 0.55 + 0.45 * sin(time * speed + hash(cell + 9.4) * 6.2831853);
    return present * core * twinkle;
}

/// A disk with a soft halo; `bite` cuts a crescent out of it for the moon.
static float2 celestialBody(float2 position, float2 center, float radius, float bite) {
    float distanceToCenter = distance(position, center);
    float disk = softCircle(position, center, radius, 1.0);
    float2 biteCenter = center + float2(-0.63, -0.51) * radius;
    disk *= 1.0 - bite * softCircle(position, biteCenter, radius * 0.886, 1.0);
    float halo = exp(-max(distanceToCenter - radius, 0.0) / (radius * mix(1.1, 0.6, bite)));
    return float2(disk, halo * mix(0.38, 0.18, bite));
}

/// Palette-driven sky. Every color comes from the active `Palette` at the current
/// time of day, so a different child seed, mode or hour restyles the background
/// without shader changes. `cloudAmount` fades the clouds out, for night light.
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
    float cloudAmount,
    float starAmount,
    half4 celestial,
    float2 sunCenter,
    float sunAmount,
    float2 moonCenter,
    float moonAmount
) {
    float2 safeSize = max(size, float2(1.0));
    float2 uv = position / safeSize;
    float aspect = safeSize.x / safeSize.y;
    float2 field = float2(uv.x * aspect, uv.y);

    float3 sky = mix(float3(skyTop.rgb), float3(skyMiddle.rgb), smoothstep(0.0, 0.55, uv.y));
    sky = mix(sky, float3(skyBottom.rgb), smoothstep(0.45, 1.0, uv.y));

    float stars = starField(position, time) * starAmount * (1.0 - smoothstep(0.15, 0.6, uv.y));
    sky = mix(sky, float3(celestial.rgb), saturate(stars));

    float2 sun = celestialBody(position, sunCenter, 52.0, 0.0) * sunAmount;
    float2 moon = celestialBody(position, moonCenter, 35.0, 1.0) * moonAmount;
    sky = mix(sky, float3(celestial.rgb), saturate(sun.y + moon.y));
    sky = mix(sky, float3(celestial.rgb), saturate(sun.x + moon.x));

    float x1 = aspect * 0.62 + sin(time * hourCycle * 11.0) * 0.14;
    float x2 = aspect * 0.18 + sin(time * hourCycle * 7.0 + 2.1) * 0.12;
    float x3 = aspect * 0.70 + sin(time * hourCycle * 5.0 + 4.2) * 0.16;
    float x4 = aspect * 0.35 + sin(time * hourCycle * 17.0 + 1.3) * 0.20;
    float x5 = aspect * 0.95 + sin(time * hourCycle * 13.0 + 5.0) * 0.18;
    float y1 = 0.20 + 0.008 * sin(time * hourCycle * 63.0);
    float y2 = 0.50 + 0.007 * cos(time * hourCycle * 46.0);
    float y3 = 0.76 + 0.006 * sin(time * hourCycle * 40.0);

    float clouds = 0.0;
    clouds = max(clouds, cloudShape(field, float2(x4, 0.34), 0.22) * 0.45);
    clouds = max(clouds, cloudShape(field, float2(x5, 0.62), 0.26) * 0.50);
    clouds = max(clouds, cloudShape(field, float2(x1, y1), 0.44) * 0.95);
    clouds = max(clouds, cloudShape(field, float2(x2, y2), 0.38) * 0.85);
    clouds = max(clouds, cloudShape(field, float2(x3, y3), 0.34) * 0.70);

    float shadow = 0.0;
    shadow = max(shadow, cloudShape(field, float2(x1, y1 + 0.012), 0.45) * 0.30);
    shadow = max(shadow, cloudShape(field, float2(x2, y2 + 0.012), 0.39) * 0.22);

    float3 color = mix(sky, float3(shade.rgb), saturate(shadow * cloudAmount));
    color = mix(color, float3(cloud.rgb), saturate(clouds * cloudAmount));

    // Dither by under one 8-bit step so the long, soft gradients do not band.
    color += (hash(position) - 0.5) / 255.0;

    return half4(half3(saturate(color)), source.a);
}
