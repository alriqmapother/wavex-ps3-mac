import Foundation
import simd

// Uniform layouts. float3/float4 members come first so Swift and MSL agree on padding.

struct BgUniforms {
    var colorStart: SIMD4<Float>
    var colorEnd: SIMD4<Float>
    var dir: SIMD2<Float>
    var tMin: Float
    var tSpan: Float
}

struct WaveUniforms {
    var ffdScale1: SIMD4<Float>
    var ffdScale2: SIMD4<Float>
    var ffdOffset: SIMD4<Float>
    var waveColor: SIMD4<Float>

    var phaseFlow: Float        // uTime * flowSpeed                   (mod 2pi)
    var phaseBase: Float        // uTime * 0.5 * timeStep              (mod 2pi)
    var phaseTension: Float     // uTime * flowSpeed * timeStep * 0.25 (mod 2pi)
    var phaseStruct1: Float     // uTime * flowSpeed * timeStep * 0.7  (mod 2pi)
    var phaseStruct2: Float     // uTime * flowSpeed * timeStep * 0.35 (mod 2pi)
    var uvShift: Float          // uTime * flowSpeed * 0.04 * timeStep (mod 1)

    var tension: Float
    var damping: Float
    var length: Float
    var spacing: Float
    var perturbation: Float
    var perturbationScale: Float
    var waveCosAmp: Float
    var waveBias: Float
    var waveHeightScale: Float
    var waveSoftClip: Float
    var ffdYAmp: Float
    var ffdZAmp: Float
    var zDetailScale: Float
    var opacity: Float
    var brightness: Float
    var fresnelPower: Float
    var fresnelScale: Float
}

struct ParticleUniforms {
    var time: Float
    var flowSpeed: Float
    var ratio: Float
    var sizeBase: Float
    var sizeVar: Float
    var opacity: Float
    var pointScale: Float
}

/// Metal port of the three GLSL programs in `spline.js` / `particles.js`. Compiled at runtime
/// so the package builds with the Command Line Tools alone (no `metal` compiler needed).
let waveShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct BgUniforms {
    float4 colorStart;
    float4 colorEnd;
    float2 dir;
    float tMin;
    float tSpan;
};

struct WaveUniforms {
    float4 ffdScale1;
    float4 ffdScale2;
    float4 ffdOffset;
    float4 waveColor;
    float phaseFlow, phaseBase, phaseTension, phaseStruct1, phaseStruct2, uvShift;
    float tension, damping, length, spacing, perturbation, perturbationScale;
    float waveCosAmp, waveBias, waveHeightScale, waveSoftClip, ffdYAmp, ffdZAmp, zDetailScale;
    float opacity, brightness, fresnelPower, fresnelScale;
};

struct ParticleUniforms {
    float time, flowSpeed, ratio, sizeBase, sizeVar, opacity, pointScale;
};

// ---------------------------------------------------------------- background

struct BgVOut {
    float4 position [[position]];
    float2 uvYDown;
};

vertex BgVOut bgVert(uint vid [[vertex_id]]) {
    const float2 quad[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 aPos = quad[vid];
    BgVOut o;
    o.uvYDown = float2(aPos.x * 0.5 + 0.5, 1.0 - (aPos.y * 0.5 + 0.5));
    o.position = float4(aPos, 0.0, 1.0);
    return o;
}

fragment float4 bgFrag(BgVOut in [[stage_in]], constant BgUniforms& u [[buffer(0)]]) {
    float t = dot(in.uvYDown, u.dir);
    float v = clamp((t - u.tMin) / max(u.tSpan, 1e-6), 0.0, 1.0);
    float g = v * v * (3.0 - 2.0 * v);
    return float4(mix(u.colorStart.rgb, u.colorEnd.rgb, g), 1.0);
}

// ---------------------------------------------------------------- wave mesh

struct WaveVOut {
    float4 position [[position]];
    float3 vPos;
};

vertex WaveVOut waveVert(uint vid [[vertex_id]],
                         const device float2* verts [[buffer(0)]],
                         constant WaveUniforms& u [[buffer(1)]],
                         texture2d<float> splineTex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 aPos = verts[vid];
    float3 p = float3(aPos.x, 0.0, aPos.y);
    float2 uv = (aPos + 1.0) * 0.5;
    p.y = splineTex.sample(s, uv).r;

    float3 ffd1 = p * u.ffdScale1.xyz + u.ffdOffset.xyz;
    float3 ffd2 = p * u.ffdScale2.xyz + u.ffdOffset.xyz;
    p.y += sin(ffd1.x + u.phaseFlow) * u.ffdYAmp;
    p.z += cos(ffd2.z + u.phaseFlow) * u.ffdZAmp;

    float baseWave = cos(p.x * 2.0 - u.phaseBase) * u.waveCosAmp + u.waveBias;
    baseWave *= (1.0 - u.damping);
    baseWave += u.tension * sin(p.x * u.length + u.phaseTension);

    float structured = u.perturbation * u.perturbationScale * (
        sin((p.x * u.length * 6.0 + p.z * 0.5) * u.spacing * 0.01 + u.phaseStruct1) * 0.5 +
        sin((p.x * u.length * 10.0 - p.z * 0.8) * u.spacing * 0.005 - u.phaseStruct2) * 0.25
    );

    float totalWave = (baseWave + structured) * u.waveHeightScale;
    totalWave = u.waveSoftClip * tanh(totalWave / max(u.waveSoftClip, 1e-4));
    p.y -= totalWave;

    float2 uv2 = uv;
    uv2.x = fract(uv2.x - u.uvShift);
    p.z -= splineTex.sample(s, uv2).r * u.zDetailScale;

    WaveVOut o;
    // GL clips z to [-w, w]; Metal to [0, w]. Remap so the same edge rows get clipped.
    o.position = float4(p.x, p.y, p.z * 0.5 + 0.5, 1.0);
    o.vPos = p;
    return o;
}

fragment float4 waveFrag(WaveVOut in [[stage_in]], constant WaveUniforms& u [[buffer(0)]]) {
    float3 dx = dfdx(in.vPos);
    float3 dy = dfdy(in.vPos);
    // Metal's dfdy runs top-down (GL's runs bottom-up), so negate to keep the GL normal.
    float3 c = -cross(dx, dy);
    float len = length(c);
    float3 N = len > 1e-12 ? c / len : float3(0.0, 0.0, -1.0);
    float f = max(0.0, 1.0 + dot(float3(0.0, 0.0, -1.0), N));
    float F = u.fresnelScale * pow(f, u.fresnelPower);
    return float4(u.waveColor.rgb, F * u.opacity * u.brightness);
}

// ---------------------------------------------------------------- particles

struct PtVOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float alpha;
};

vertex PtVOut ptVert(uint vid [[vertex_id]],
                     const device float3* seeds [[buffer(0)]],
                     constant ParticleUniforms& u [[buffer(1)]]) {
    float3 aSeed = seeds[vid];
    PtVOut o;
    o.pointSize = (aSeed.z * u.sizeVar + u.sizeBase) * u.pointScale;
    float time = u.time * u.flowSpeed;
    float x = fract(time * (aSeed.x - 0.5) / 15.0 + aSeed.y * 50.0) * 2.0 - 1.0;
    float y = sin(sign(aSeed.y) * time * (aSeed.y + 1.5) / 4.0 + aSeed.x * 100.0)
            / ((6.0 - aSeed.x * 4.0 * aSeed.y) / u.ratio);
    float opVar = mix(
        sin(time * (aSeed.x + 0.5) * 12.0 + aSeed.y * 10.0),
        sin(time * (aSeed.y + 1.5) * 6.0 + aSeed.x * 4.0),
        y * 0.5 + 0.5) * aSeed.x + aSeed.y;
    o.alpha = opVar * opVar * (1.0 - fract(aSeed.x + time * 0.00285));
    o.position = float4(x, y, 0.0, 1.0);
    return o;
}

fragment float4 ptFrag(PtVOut in [[stage_in]], float2 pc [[point_coord]], constant ParticleUniforms& u [[buffer(0)]]) {
    float2 c = pc * 2.0 - 1.0;
    float d = dot(c, c);
    if (d > 1.0) discard_fragment();
    float sparkle = (1.0 - d) * (1.0 - d);
    float a = in.alpha * u.opacity * sparkle;
    return float4(float3(a), 1.0);
}
"""
