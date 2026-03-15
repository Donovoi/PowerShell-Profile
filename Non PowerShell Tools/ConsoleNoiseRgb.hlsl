// ConsoleNoiseRgb.hlsl
// GPU version of the RGB wave used by Invoke-ConsoleNoise.

Texture2D shaderTexture;
SamplerState samplerState;

cbuffer PixelShaderSettings {
    float  Time;
    float  Scale;
    float2 Resolution;
    float4 Background;
};

#define TAU 6.28318530718

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
    float phase = (frameNumber * 0.0016) + (rowIndex * 0.045);

    float red = (160.0 + (70.0 * sin(phase))) / 255.0;
    float green = (160.0 + (70.0 * sin(phase + (TAU / 3.0)))) / 255.0;
    float blue = (160.0 + (70.0 * sin(phase + ((2.0 * TAU) / 3.0)))) / 255.0;

    float3 glyphColor = float3(red, green, blue);
    float mask = saturate(sample.w);
    float3 finalColor = ComposeConsoleNoise(glyphColor, mask);

    return float4(saturate(finalColor), 1.0);
}
