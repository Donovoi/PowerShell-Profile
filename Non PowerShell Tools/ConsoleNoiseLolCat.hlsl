// ConsoleNoiseLolCat.hlsl
// GPU version of the lolcat gradient used by Invoke-ConsoleNoise.

Texture2D shaderTexture;
SamplerState samplerState;

cbuffer PixelShaderSettings {
    float  Time;
    float  Scale;
    float2 Resolution;
    float4 Background;
};

float Hue2Rgb(float p, float q, float t)
{
    if (t < 0.0) {
        t += 1.0;
    }

    if (t > 1.0) {
        t -= 1.0;
    }

    if (t < (1.0 / 6.0)) {
        return p + ((q - p) * 6.0 * t);
    }

    if (t < 0.5) {
        return q;
    }

    if (t < (2.0 / 3.0)) {
        return p + ((q - p) * (((2.0 / 3.0) - t) * 6.0));
    }

    return p;
}

float3 HslToRgb(float hue, float saturation, float lightness)
{
    hue = frac(hue);
    saturation = saturate(saturation);
    lightness = saturate(lightness);

    if (saturation <= 0.0001) {
        return float3(lightness, lightness, lightness);
    }

    float q = (lightness < 0.5)
        ? lightness * (1.0 + saturation)
        : lightness + saturation - (lightness * saturation);
    float p = (2.0 * lightness) - q;

    return float3(
        Hue2Rgb(p, q, hue + (1.0 / 3.0)),
        Hue2Rgb(p, q, hue),
        Hue2Rgb(p, q, hue - (1.0 / 3.0))
    );
}

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
    float hue = frac((frameNumber * 0.065) + (rowIndex * 0.115));
    float lightness = 0.55 + (WaveValue(rowPhase * 2.4) * 0.10);
    float3 glyphColor = HslToRgb(hue, 1.0, lightness);
    float mask = saturate(sample.w);
    float3 finalColor = ComposeConsoleNoise(glyphColor, mask);

    return float4(saturate(finalColor), 1.0);
}
