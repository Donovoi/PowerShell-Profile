// ConsoleNoiseRainbow.hlsl
// Slow, calming rainbow bands for Windows Terminal.

Texture2D shaderTexture;
SamplerState samplerState;

cbuffer PixelShaderSettings {
    float  Time;
    float  Scale;
    float2 Resolution;
    float4 Background;
};

float3 HueToRgb(float hue)
{
    float3 rgb = abs(frac(hue + float3(0.0, 0.6666667, 0.3333333)) * 6.0 - 3.0) - 1.0;
    return saturate(rgb);
}

float4 main(float4 pos : SV_POSITION, float2 tex : TEXCOORD) : SV_TARGET
{
    float4 sample = shaderTexture.Sample(samplerState, tex);
    float4 shadowSample = shaderTexture.Sample(samplerState, tex + 2.0 * Scale * float2(-1.0, -1.0) / Resolution.y);

    float2 uv = tex * 2.0 - 1.0;
    uv.x *= Resolution.x / Resolution.y;

    float hue = frac(0.62 + tex.y * 0.58 + 0.035 * sin(uv.x * 1.4 + Time * 0.05) + Time * 0.010);
    float glow = 0.55 + 0.45 * pow(saturate(1.0 - abs(uv.y) * 0.8), 1.4);
    float ripple = 0.90 + 0.10 * sin((uv.x * 1.8) + (uv.y * 0.8) + Time * 0.08);

    float3 baseColor = float3(0.020, 0.028, 0.055);
    float3 rainbow = HueToRgb(hue);
    float3 backgroundColor = baseColor + rainbow * glow * ripple * 0.42;

    float shadow = saturate(shadowSample.w * 0.65);
    backgroundColor = lerp(backgroundColor, backgroundColor * 0.58, shadow);

    float3 finalColor = lerp(backgroundColor, sample.xyz, sample.w);
    return float4(saturate(finalColor), 1.0);
}
