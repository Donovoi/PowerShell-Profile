#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$TestRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new TestRoot.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$repo=Split-Path $PSScriptRoot -Parent
$assets=Join-Path $repo 'scripts/ExecutableAnalysis'
. (Join-Path $repo 'functions/Invoke-ExecutableAnalysis.ps1')
. (Join-Path $repo 'functions/Invoke-ExecutableAnalysisWindowsVm.ps1')
. (Join-Path $assets 'Get-AnalysisIdentity.ps1')
. (Join-Path $assets 'WindowsVm.Common.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function New-FixturePe([int]$Subsystem,[int]$Magic=0x20b,[int]$OptionalSize=240){
    $bytes=[byte[]]::new(512)
    $bytes[0]=0x4d;$bytes[1]=0x5a
    [BitConverter]::GetBytes([int]64).CopyTo($bytes,60)
    [BitConverter]::GetBytes([int]0x4550).CopyTo($bytes,64)
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes,68)
    [BitConverter]::GetBytes([uint16]$OptionalSize).CopyTo($bytes,84)
    [BitConverter]::GetBytes([uint16]2).CopyTo($bytes,86)
    [BitConverter]::GetBytes([uint16]$Magic).CopyTo($bytes,88)
    [BitConverter]::GetBytes([uint16]$Subsystem).CopyTo($bytes,156)
    return ,$bytes
}
$script:vmCalls=0
function Initialize-ExecutableAnalysisWindowsVm {$script:vmCalls++;throw 'Unexpected VM provisioning.'}
# The public runtime command is also exercised directly below. Orchestrator
# firmware/EFI cases must refuse before either provision or observation.
foreach($magic in 0x10b,0x20b){
    foreach($subsystem in 2,3,10,11,12,13){
        $path=Join-Path $TestRoot "pe-$magic-$subsystem.bin"
        [IO.File]::WriteAllBytes($path,(New-FixturePe $subsystem $magic))
        $identity=Get-AnalysisIdentity $path
        Assert-True ($identity.Header.Subsystem -eq $subsystem -and $identity.Header.IsEfi -eq ($subsystem -in 10,11,12,13)) 'PE subsystem identity is wrong.'
        Assert-True ((Test-AnalysisWindowsPe $path) -eq ($subsystem -in 2,3)) 'EFI image accepted as Windows application or ordinary PE rejected.'
        if($subsystem -in 10,11,12,13){
            $result=Invoke-ExecutableAnalysis $path -OutputDirectory $TestRoot -BasicOnly -SkipAI -NoInstall -Dynamic
            Assert-True (@($result.Stages|Where-Object {$_.Name -eq 'Runtime' -and $_.Status -eq 'Unsupported'}).Count -eq 1) 'EFI runtime routing was not refused.'
        }
    }
}
$short=Join-Path $TestRoot 'short-optional.bin'
[IO.File]::WriteAllBytes($short,(New-FixturePe 10 0x20b 69))
Assert-True ($null -eq (Get-AnalysisIdentity $short).Header.Subsystem) 'Read subsystem outside the declared optional header.'
$bytes=New-FixturePe 10;$truncated=Join-Path $TestRoot 'truncated.bin'
[IO.File]::WriteAllBytes($truncated,$bytes[0..155])
Assert-True ($null -eq (Get-AnalysisIdentity $truncated).Header.Subsystem) 'Truncated PE was assigned a subsystem.'
$wrapper=[Convert]::FromHexString('08000000AAEEAA761BECBB20F1E65100789C03000000000108000000EEAAEE8F491BE8AE14379000')
foreach($offset in 0,24){$xor=0;for($i=0;$i -lt 15;$i++){$xor=$xor -bxor $wrapper[$offset+$i]};$wrapper[$offset+15]=[byte]$xor}
$target=Join-Path $TestRoot 'firmware [literal].exe'
[IO.File]::WriteAllBytes($target,((New-FixturePe 2)+$wrapper))
$hash=(Get-FileHash -LiteralPath $target).Hash
$result=Invoke-ExecutableAnalysis $target -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic
Assert-True (@($result.Stages|Where-Object {$_.Name -eq 'Runtime' -and $_.Status -eq 'Unsupported'}).Count -eq 1 -and $script:vmCalls -eq 0) 'Firmware invoked a VM.'
Assert-True (@($result.Stages|Where-Object {$_.Name -eq 'FirmwareExtraction' -and $_.Status -eq 'Skipped'}).Count -eq 1) 'BasicOnly implied firmware extraction.'
$runtimeOutput=Join-Path $TestRoot 'runtime-must-not-exist'
$errorText=$null
try{Invoke-ExecutableAnalysisWindowsVm -InputPath $target -OutputPath $runtimeOutput -WhatIf}catch{$errorText=$_.Exception.Message}
Assert-True ($errorText -match 'Firmware updater candidates require static' -and -not(Test-Path -LiteralPath $runtimeOutput)) 'Direct Windows adapter did not reject firmware before VM inspection/output.'
Assert-True ((Get-FileHash -LiteralPath $target).Hash -eq $hash) 'Firmware routing changed source bytes.'
Write-Output 'PASS: PE32/PE32+ EFI subsystem classification, header boundaries and public static-only firmware routing; no VM or target execution.'

& {
    # Real orchestration and detection, mocked installation/provider boundaries.
    $script:firmwareFixtureAssets=$assets
    foreach($name in 'Get-AnalysisIdentity','Get-AnalysisFirmwareContext','Get-AnalysisApplicationContext','Invoke-AnalysisRound','Get-AnalysisReportText'){
        . (Join-Path $assets ($name+'.ps1'))
    }
    $source=[IO.File]::ReadAllText((Join-Path $repo 'functions/Invoke-ExecutableAnalysis.ps1'))
    $source=$source.Replace("`$assets=Join-Path (Split-Path `$PSScriptRoot -Parent) 'scripts/ExecutableAnalysis'",'$assets=$script:firmwareFixtureAssets').Replace('. $helperPath','# Helper imports replaced by explicit fixture boundaries.')
    . ([scriptblock]::Create($source))
    function Resolve-AnalysisFirmwareTool {param($LogDirectory,$NoInstall) Assert-True $NoInstall 'NoInstall was not forwarded.';[pscustomobject]@{Status='Completed';Python='python.exe';BIOSUtilities='bios';UEFIExtract='uefi.exe';IFRExtractor='ifr.exe';PythonDependencies='deps';Limitations=@()}}
    function Resolve-AnalysisTool {param($LogDirectory,$ReaScriptPath,$NoInstall,$Managed,$Native,$Wasm,$Java) [pscustomobject]@{Limitations=@('Mocked generic provider.')}}
    function Invoke-AnalysisFirmware {
        param($InputPath,$OutputDirectory,$Tools,$LogDirectory,$TimeoutSeconds,$MaxOutputBytes,$MaxFiles,$MaxIFRModules)
        Assert-True ($InputPath -like '*analysis-*\input\*' -and (Get-FileHash -LiteralPath $InputPath).Hash -eq $hash) 'Provider did not receive preserved input.'
        Assert-True ($MaxOutputBytes -eq 2MB -and $MaxFiles -eq 27 -and $MaxIFRModules -eq 3 -and $TimeoutSeconds -eq 123 -and $Tools.PythonDependencies -eq 'deps') 'Firmware budgets or dependencies were not forwarded.'
        [pscustomobject]@{Status='Partial';TargetExecuted=$false;InputUnchanged=$true;Manifest=@{Summary=@{FormPackages=2};Diagnostics=@('Fixture partial extraction');Limitations=@('Fixture extraction warning')}}
    }
    $run=Invoke-ExecutableAnalysis $target -OutputDirectory $TestRoot -SkipAI -NoInstall -TimeoutSeconds 123 -MaxFirmwareBytes 2MB -MaxFirmwareFiles 27 -MaxFirmwareModules 3
    Assert-True (@($run.Stages|Where-Object {$_.Name -eq 'FirmwareExtraction' -and $_.Status -eq 'Partial'}).Count -eq 1 -and $run.Status -eq 'Partial') 'Provider partial status was lost.'
    Assert-True (@($run.Stages|Where-Object Name -EQ 'Orchestration').Count -eq 0) 'Firmware orchestration failed.'
    $record=Get-Content -LiteralPath $run.JsonPath -Raw|ConvertFrom-Json
    Assert-True ($record.Firmware.Manifest.Summary.FormPackages -eq 2 -and 'Fixture extraction warning' -in $record.Limitations) 'Firmware evidence or warning missing from report.'
    Assert-True ((Get-Content -LiteralPath $run.ReportPath -Raw) -notmatch 'Bounded HII declarations:') 'Report advertised menu files that were not recovered.'
    $rounds=[Collections.Generic.List[string]]::new()
    function Resolve-AnalysisCodex {param($LogDirectory)[pscustomobject]@{Source='mock-codex.exe'}}
    function Invoke-AnalysisRound {
        param($Name,$Prompt,$OutputDirectory,$CodexPath,$TimeoutSeconds,[switch]$Research)
        $rounds.Add($Name)
        if($Research){Assert-True ($Prompt -match 'Dell compressed PFS' -and $Prompt -notmatch 'firmware \[literal\]') 'Research lacked format context or leaked the target filename.'}
        else{Assert-True ($Prompt -match 'Fixture extraction warning' -and $Prompt -match 'do not prove visibility' -and $Prompt -match 'all enclosing IFR conditions') 'AI review lost firmware evidence or overclaim boundaries.'}
        $output=Join-Path $OutputDirectory ($Name+'.md')
        'Fixture findings: no runtime or actual menu unlock was demonstrated.'|Set-Content -LiteralPath $output
        [pscustomobject]@{Name=$Name;Status='Completed';OutputPath=$output}
    }
    $review=Invoke-ExecutableAnalysis $target -OutputDirectory $TestRoot -NoInstall -TimeoutSeconds 123 -MaxFirmwareBytes 2MB -MaxFirmwareFiles 27 -MaxFirmwareModules 3
    Assert-True (($rounds -join ',') -eq 'research,analysis,detractor,reconciled-findings' -and @($review.Stages|Where-Object Name -EQ Orchestration).Count -eq 0) 'Firmware research/critique chain did not complete with explicit evidence limits.'
}
Write-Output 'PASS: retained-input provenance, NoInstall, firmware budgets, partial reporting, and research/analysis/detractor/reconciliation evidence boundaries.'
