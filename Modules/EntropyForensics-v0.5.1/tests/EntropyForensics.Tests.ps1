
Import-Module "$PSScriptRoot\..\EntropyForensics.psd1" -Force

Describe 'EntropyForensics v0.5.1' {
  It 'Exports Invoke-EntropyDeepfakeScan' {
    (Get-Command Invoke-EntropyDeepfakeScan -ErrorAction Stop).Name | Should -Be 'Invoke-EntropyDeepfakeScan'
  }
  It 'Supports pipeline input of strings' {
    $cmd = Get-Command Invoke-EntropyDeepfakeScan
    ($cmd.Parameters['Path'].Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }).ValueFromPipeline | Should -BeTrue
  }
}
