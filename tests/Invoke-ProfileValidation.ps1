#requires -Version 7.0
<#
.SYNOPSIS
Runs profile regression checks in isolated PowerShell processes.
.DESCRIPTION
Requires Windows and Git. TestRoot must be a new directory beneath Documents.
The installer integration test replaces only its disposable fixture profiles
and stops only fixture processes. No installed profile or real tool is modified.
Logs and fixtures are retained for inspection. No Pester dependency is needed.
.EXAMPLE
.\tests\Invoke-ProfileValidation.ps1 -TestRoot "$([Environment]::GetFolderPath('MyDocuments'))\ProfileValidation-$(Get-Date -Format yyyyMMdd-HHmmss)"
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if (-not $IsWindows) { throw 'Validation requires PowerShell 7 on Windows.' }
$root=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
$documents=[Environment]::GetFolderPath('MyDocuments').TrimEnd('\')
if (-not $root.StartsWith($documents+'\',[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $root)) {
    throw 'Choose a new disposable TestRoot beneath Documents.'
}
$null=[IO.Directory]::CreateDirectory($root)
$repo=Split-Path $PSScriptRoot -Parent
$parseFailures=@()
$sourceFiles=@(Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object Extension -In '.ps1','.psm1','.psd1')
foreach($file in $sourceFiles) {
    $parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$parseErrors)
    if($parseErrors.Count) { $parseFailures += "$($file.FullName): $($parseErrors -join '; ')" }
}
if($parseFailures.Count) { throw ($parseFailures -join [Environment]::NewLine) }
$testNames=@(
    'ProfileStartup.Behavior',
    'ProfileAppearance.Behavior',
    'ProfileCore.Behavior',
    'ProfileDependencies.Behavior',
    'ProfileArchive.Behavior',
    'ProfileDownloads.Behavior',
    'ProfileSecrets.Behavior',
    'ProfileGit.Behavior',
    'ProfileSearch.Behavior',
    'ProfileRawCopy.Behavior',
    'ProfileForensicCopy.Behavior',
    'ProfilePublicCommands.Behavior',
    'Install-Profile.Status',
    'Install-Profile.Integration',
    'Restart-WindowsThumbnailWorker.Import',
    'Restart-WindowsThumbnailWorker.Behavior',
    'Update-WindowsThumbnailCache.Import'
)
$results=foreach($name in $testNames) {
    $parameters=@()
    if($name -notin @('Restart-WindowsThumbnailWorker.Import','Restart-WindowsThumbnailWorker.Behavior','Update-WindowsThumbnailCache.Import')) { $parameters=@('-TestRoot',(Join-Path $root $name)) }
    $logPath=Join-Path $root ($name+'.log')
    $timer=[Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot ($name+'.ps1')) @parameters *> $logPath
    $exitCode=$LASTEXITCODE
    Write-Host "$name : $(if($exitCode -eq 0){'PASS'}else{'FAIL'})"
    [pscustomobject]@{Test=$name;ExitCode=$exitCode;Seconds=[Math]::Round($timer.Elapsed.TotalSeconds,2);Log=$logPath}
}
$record=[pscustomobject]@{
    PowerShellVersion=$PSVersionTable.PSVersion.ToString()
    OS=[Environment]::OSVersion.VersionString
    ParsedFiles=$sourceFiles.Count
    ParseErrors=$parseFailures.Count
    Passed=@($results | Where-Object ExitCode -EQ 0).Count
    Failed=@($results | Where-Object ExitCode -NE 0).Count
    Results=$results
}
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'validation.json') -Encoding utf8
$record | ConvertTo-Json -Depth 5
if($record.Failed) { throw "Validation failed; inspect logs in '$root'." }
