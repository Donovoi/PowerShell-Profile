// CalmAurora.hlsl
// A calming aurora-style Windows Terminal pixel shader.
// Designed for slow, soothing motion and good terminal text readability.

Texture2D<float4> shaderTexture : register(t0);
SamplerState samplerState : register(s0);

cbuffer PixelShaderSettings {
  float Time;
  float Scale;
  float2 Resolution;
  float4 Background;
};

#define TAU 6.28318530718

float Hash21(float2 p) {
  p = frac(p * float2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return frac(p.x * p.y);
}

float Noise(float2 p) {
  float2 i = floor(p);
  float2 f = frac(p);
  f = f * f * (3.0 - 2.0 * f);

  float a = Hash21(i);
  float b = Hash21(i + float2(1.0, 0.0));
  float c = Hash21(i + float2(0.0, 1.0));
  float d = Hash21(i + float2(1.0, 1.0));

  return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float Fbm(float2 p) {
  float value = 0.0;
  float amplitude = 0.5;

  [unroll] for (int i = 0; i < 5; i++) {
    value += amplitude * Noise(p);
    p = float2(0.80 * p.x - 0.60 * p.y, 0.60 * p.x + 0.80 * p.y) * 2.03 +
        float2(13.4, 7.9);
    amplitude *= 0.5;
  }

  return value;
}

float3 Palette(float t) {
  float3 deepNight = float3(0.018, 0.030, 0.060);
  float3 blueMist = float3(0.055, 0.110, 0.190);
  float3 tealGlow = float3(0.110, 0.340, 0.360);
  float3 violetHue = float3(0.240, 0.220, 0.430);

  float blendA = smoothstep(0.00, 0.45, t);
  float blendB = smoothstep(0.30, 0.80, t);
  float blendC = smoothstep(0.60, 1.00, t);

  float3 color = lerp(deepNight, blueMist, blendA);
  color = lerp(color, tealGlow, blendB * 0.80);
  color = lerp(color, violetHue, blendC * 0.45);

  return color;
}

float3 RenderAurora(float2 uv, float time) {
  float2 p = uv;
  p.x *= Resolution.x / Resolution.y;

  float slowTime = time * 0.035;
  float fieldA = Fbm(p * 1.05 + float2(slowTime * 0.65, -slowTime * 0.22));
  float fieldB = Fbm(p * 1.65 - float2(slowTime * 0.35, slowTime * 0.16));

  float ribbonA = sin(p.x * 1.7 + fieldA * 2.7 + slowTime * 0.55);
  float ribbonB = sin(p.x * 1.0 - fieldB * 3.4 - slowTime * 0.38 + 1.4);
  float ribbonC = sin(p.x * 0.7 + fieldA * 4.1 + slowTime * 0.27 + 3.0);

  float veil = ribbonA * 0.50 + ribbonB * 0.32 + ribbonC * 0.18;
  veil = smoothstep(-0.45, 0.90, veil - p.y * 1.15);

  float shimmer = 0.55 + 0.45 * Fbm(p * 2.0 + float2(0.0, slowTime * 0.08));
  float intensity = saturate(veil * shimmer);

  return Palette(intensity) * intensity;
}

float4 main(float4 pos : SV_POSITION, float2 tex : TEXCOORD) : SV_TARGET {
  float4 sample = shaderTexture.Sample(samplerState, tex);

  float2 uv = tex * 2.0 - 1.0;
  uv.y *= 0.9;

  float slowTime = Time * 0.04;
  float baseNoise = Fbm(uv * 0.75 + float2(0.0, slowTime * 0.12));
  float horizon = smoothstep(-1.0, 0.35, 1.0 - tex.y);

  float3 backgroundA = float3(0.010, 0.018, 0.035);
  float3 backgroundB = float3(0.026, 0.055, 0.095);
  float3 backgroundColor =
      lerp(backgroundA, backgroundB, horizon * (0.35 + 0.65 * baseNoise));

  float3 auroraColor = RenderAurora(uv, Time);

  float vignette =
      1.0 - smoothstep(0.45, 1.35, length(float2(uv.x * 0.85, uv.y * 1.10)));
  vignette = 0.45 + 0.55 * vignette;

  float4 shadowSample = shaderTexture.Sample(
      samplerState, tex + 2.0 * Scale * float2(-1.0, -1.0) / Resolution.y);
  float shadow = saturate(shadowSample.w * 0.65);

  float3 finalColor = (backgroundColor + auroraColor) * vignette;
  finalColor = lerp(finalColor, finalColor * 0.58, shadow);
  finalColor = lerp(finalColor, sample.xyz, sample.w);

  return float4(saturate(finalColor), 1.0);
}