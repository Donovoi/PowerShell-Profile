
# Pester tests for EntropyForensics
# These tests avoid heavy media processing and focus on module surface and basic behaviors.

Import-Module "$PSScriptRoot\..\EntropyForensics.psd1" -Force

Describe 'EntropyForensics module' {
  It 'Exports Invoke-EntropyDeepfakeScan' {
    (Get-Command Invoke-EntropyDeepfakeScan -ErrorAction Stop).Name | Should -Be 'Invoke-EntropyDeepfakeScan'
  }

  It 'Supports pipeline input of strings' {
    $cmd = Get-Command Invoke-EntropyDeepfakeScan
    ($cmd.Parameters['Path'].Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }).ValueFromPipeline | Should -BeTrue
  }

  It 'Returns objects (EntropyScanResult) when PassThru is set' -Skip:(-not (Get-Command python -ErrorAction SilentlyContinue)) {
    # create a tiny black png to avoid python decode issues
    $png = Join-Path $env:TEMP ('ef_test_' + [guid]::NewGuid().ToString() + '.png')
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap 64,64
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    $res = Invoke-EntropyDeepfakeScan -Path $png -PassThru -Verbose -ErrorAction Stop
    $res | Should -Not -BeNullOrEmpty
    $res.Score | Should -BeGreaterOrEqual 0
    Test-Path $res.Overlay | Should -BeTrue
    Test-Path $res.FeatureJsonPath | Should -BeTrue
  }
}
