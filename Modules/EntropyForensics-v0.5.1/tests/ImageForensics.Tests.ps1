Import-Module "$PSScriptRoot\..\ImageForensics.psd1" -Force

Describe 'ImageForensics module' {
  BeforeAll {
    $command = Get-Command Invoke-DeepfakeScan -ErrorAction Stop
    $moduleText = Get-Content "$PSScriptRoot\..\ImageForensics.psm1" -Raw
  }

  It 'exports Invoke-DeepfakeScan' {
    $command.Name | Should Be 'Invoke-DeepfakeScan'
  }

  It 'supports pipeline input and FullName property binding' {
    $pathParameter = $command.Parameters['Path']
    $parameterAttributes = $pathParameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }

    ($parameterAttributes | Where-Object { $_.ValueFromPipeline }).Count | Should BeGreaterThan 0
    ($parameterAttributes | Where-Object { $_.ValueFromPipelineByPropertyName }).Count | Should BeGreaterThan 0
    (@($pathParameter.Aliases) -contains 'FullName') | Should Be $true
  }

  It 'supports WhatIf' {
    (@($command.Parameters.Keys) -contains 'WhatIf') | Should Be $true
  }

  It 'uses a boolean Legend parameter' {
    $command.Parameters['Legend'].ParameterType | Should Be ([bool])
  }

  It 'does not create the output directory when WhatIf is used' {
    $inputPath = Join-Path $TestDrive 'missing.jpg'
    $outputDir = Join-Path $TestDrive 'out'

    { Invoke-DeepfakeScan -Path $inputPath -OutputDir $outputDir -WhatIf -ErrorAction Stop } | Should Not Throw
    (Test-Path -LiteralPath $outputDir) | Should Be $false
  }

  It 'writes an error for a missing input path when WhatIf is not used' {
    $inputPath = Join-Path $TestDrive 'missing.jpg'
    $scanErrors = @()

    Invoke-DeepfakeScan -Path $inputPath -ErrorAction Continue -ErrorVariable +scanErrors | Out-Null
    $scanErrors.Count | Should BeGreaterThan 0
  }

  It 'embeds valid Python syntax for detector handoff in video scans' {
    $moduleText | Should Match 'if detector_tag is None and detector_tag_frame:'
    $moduleText | Should Not Match 'if detector_tag is None -and detector_tag_frame:'
  }

  It 'uses uv commands to manage Python dependencies' {
    $moduleText | Should Match "'-m', 'uv', 'venv'"
    $moduleText | Should Match "'-m', 'uv', 'pip', 'install'"
  }
}
