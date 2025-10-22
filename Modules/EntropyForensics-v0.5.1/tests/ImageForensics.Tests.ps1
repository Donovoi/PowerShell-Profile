
Import-Module "$PSScriptRoot\..\ImageForensics.psd1" -Force

Describe 'ImageForensics v0.5.1' {
  It 'Exports Invoke-ImageDeepfakeScan' {
    (Get-Command Invoke-ImageDeepfakeScan -ErrorAction Stop).Name | Should -Be 'Invoke-ImageDeepfakeScan'
  }
  It 'Supports pipeline input of strings' {
    $cmd = Get-Command Invoke-ImageDeepfakeScan
    ($cmd.Parameters['Path'].Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }).ValueFromPipeline | Should -BeTrue
  }
}
