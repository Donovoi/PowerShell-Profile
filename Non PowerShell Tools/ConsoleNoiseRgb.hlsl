// ConsoleNoiseRgb.hlsl
// Smooth RGB wave background for Windows Terminal.

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

    float phase = Time * 0.060 + uv.y * 1.20 + uv.x * 0.18;
    float wave = 0.65 + 0.35 * (0.5 + 0.5 * cos(uv.x * 1.3 - Time * 0.040));

    float red = 0.10 + 0.30 * (0.5 + 0.5 * sin(phase));
    float green = 0.10 + 0.30 * (0.5 + 0.5 * sin(phase + TAU / 3.0));
    float blue = 0.14 + 0.34 * (0.5 + 0.5 * sin(phase + (2.0 * TAU) / 3.0));

    float3 backgroundColor = float3(red, green, blue) * wave + float3(0.016, 0.018, 0.028);

    float shadow = saturate(shadowSample.w * 0.65);
    backgroundColor = lerp(backgroundColor, backgroundColor * 0.58, shadow);

    float3 finalColor = lerp(backgroundColor, sample.xyz, sample.w);
    return float4(saturate(finalColor), 1.0);
}
