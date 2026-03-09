// ConsoleNoiseGreyscale.hlsl
// Soft breathing monochrome background for Windows Terminal.

Texture2D shaderTexture;
SamplerState samplerState;

cbuffer PixelShaderSettings {
    float  Time;
    float  Scale;
    float2 Resolution;
    float4 Background;
};

#define TAU 6.28318530718

float4 main(float4 pos : SV_POSITION, float2 tex : TEXCOORD) : SV_TARGET
{
    float4 sample = shaderTexture.Sample(samplerState, tex);
    float4 shadowSample = shaderTexture.Sample(samplerState, tex + 2.0 * Scale * float2(-1.0, -1.0) / Resolution.y);

    float2 uv = tex * 2.0 - 1.0;
    uv.x *= Resolution.x / Resolution.y;

    float breath = 0.5 + 0.5 * cos((TAU / 18.0) * Time + uv.y * 0.8);
    float shimmer = 0.03 * sin(uv.x * 6.0 + Time * 0.03) * sin(uv.y * 4.0 - Time * 0.02);
    float vignette = 1.0 - smoothstep(0.45, 1.35, length(float2(uv.x * 0.85, uv.y * 1.10)));
    vignette = 0.45 + 0.55 * vignette;

    float light = (0.08 + 0.22 * breath + shimmer) * vignette;
    float3 backgroundColor = float3(light, light, light * 1.02);

    float shadow = saturate(shadowSample.w * 0.65);
    backgroundColor = lerp(backgroundColor, backgroundColor * 0.58, shadow);

    float3 finalColor = lerp(backgroundColor, sample.xyz, sample.w);
    return float4(saturate(finalColor), 1.0);
}
