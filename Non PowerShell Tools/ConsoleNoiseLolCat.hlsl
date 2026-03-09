// ConsoleNoiseLolCat.hlsl
// A vivid but still smooth lolcat-inspired Windows Terminal shader.

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

    float hue = frac(tex.y * 0.46 + tex.x * 0.16 + Time * 0.028 + 0.045 * sin(uv.x * 2.2 + Time * 0.090));
    float sparkle = 0.62 + 0.38 * pow(0.5 + 0.5 * cos(uv.y * 3.0 - Time * 0.070), 1.5);

    float3 backgroundColor = float3(0.025, 0.018, 0.040) + HueToRgb(hue) * sparkle * 0.55;

    float shadow = saturate(shadowSample.w * 0.65);
    backgroundColor = lerp(backgroundColor, backgroundColor * 0.58, shadow);

    float3 finalColor = lerp(backgroundColor, sample.xyz, sample.w);
    return float4(saturate(finalColor), 1.0);
}
