// ConsoleNoiseGreyscale.hlsl
// GPU version of the row-based greyscale gradient used by Invoke-ConsoleNoise.

Texture2D shaderTexture;
SamplerState samplerState;

cbuffer PixelShaderSettings {
    float  Time;
    float  Scale;
    float2 Resolution;
    float4 Background;
};

float WaveValue(float phase)
{
    return (sin(phase) + 1.0) * 0.5;
}

float EstimateRowIndex(float2 tex)
{
    float scaleFactor = max(1.0, Scale);
    float estimatedRowCount = max(1.0, floor(Resolution.y / (18.0 * scaleFactor)));
    return tex.y * max(0.0, estimatedRowCount - 1.0);
}

float3 ComposeConsoleNoise(float3 glyphColor, float mask)
{
    float3 backgroundColor = glyphColor * 0.10;
    return lerp(backgroundColor, glyphColor, mask);
}

float4 main(float4 pos : SV_POSITION, float2 tex : TEXCOORD) : SV_TARGET
{
    float4 sample = shaderTexture.Sample(samplerState, tex);
    float frameNumber = Time * 30.0;
    float rowIndex = EstimateRowIndex(tex);
    float rowPhase = (frameNumber * 0.045) + (rowIndex * 0.06);
    float lightness = 0.18 + (WaveValue(rowPhase * 3.6) * 0.62);
    float3 glyphColor = float3(lightness, lightness, lightness);
    float mask = saturate(sample.w);
    float3 finalColor = ComposeConsoleNoise(glyphColor, mask);

    return float4(saturate(finalColor), 1.0);
}
