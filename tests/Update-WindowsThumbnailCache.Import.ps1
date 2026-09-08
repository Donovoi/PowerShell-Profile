#requires -Version 7.0
<#
Run in a fresh process:
pwsh -NoProfile -File ./tests/Update-WindowsThumbnailCache.Import.ps1
Checks profile-style import without running thumbnail generation or the full profile.
#>
$ErrorActionPreference = 'Stop'
$functionPath = Join-Path $PSScriptRoot '../functions/Update-WindowsThumbnailCache.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $functionPath, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
if ($ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.CleanBlock -or
    $ast.EndBlock.Traps.Count -or $ast.EndBlock.Statements.Count -ne 1 -or
    $ast.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -or
    $ast.EndBlock.Statements[0].Name -ne 'Update-WindowsThumbnailCache') {
    throw 'Import must contain only the Update-WindowsThumbnailCache function definition.'
}
if ('WindowsThumbnailWarmupV1.Job' -as [type]) {
    throw 'Run this check in a fresh pwsh -NoProfile process: the native engine is already loaded.'
}

# Any attempt to do startup work must fail, rather than scan files or compile code.
function Add-Type { throw 'Import attempted native compilation.' }
function Get-Item { throw 'Import attempted source filesystem access.' }
function Get-ChildItem { throw 'Import attempted directory enumeration.' }
function Start-Sleep { throw 'Import attempted to wait for workers.' }
function Write-Progress { throw 'Import attempted thumbnail progress reporting.' }

# Dot-source twice: profile reloads must be harmless too.
$importOutput = @(. $functionPath *>&1; . $functionPath *>&1)
if ($importOutput.Count) { throw "Import produced output: $($importOutput | Out-String)" }
$command = Get-Command Update-WindowsThumbnailCache -CommandType Function -ErrorAction Stop
if (-not $command.CmdletBinding -or -not $command.Parameters.ContainsKey('Force')) {
    throw 'Expected the advanced function and its parameters to be available after import.'
}
if ('WindowsThumbnailWarmupV1.Job' -as [type]) {
    throw 'Import unexpectedly loaded the native thumbnail engine.'
}
'PASS: function is available; two imports produced no output, compilation, enumeration, or worker startup.'
