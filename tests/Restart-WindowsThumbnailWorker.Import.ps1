#requires -Version 7.0
<# Run in a fresh process: pwsh -NoProfile -File ./tests/Restart-WindowsThumbnailWorker.Import.ps1 #>
$ErrorActionPreference = 'Stop'
$functionPath = Join-Path $PSScriptRoot '../functions/Restart-WindowsThumbnailWorker.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($functionPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
if ($ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock -or $ast.CleanBlock -or
    $ast.EndBlock.Traps.Count -or $ast.EndBlock.Statements.Count -ne 1 -or
    $ast.EndBlock.Statements[0] -isnot [Management.Automation.Language.FunctionDefinitionAst] -or
    $ast.EndBlock.Statements[0].Name -ne 'Restart-WindowsThumbnailWorker') {
    throw 'Import must contain only the Restart-WindowsThumbnailWorker function definition.'
}

function Get-CimInstance { throw 'Import attempted process discovery.' }
function Invoke-CimMethod { throw 'Import attempted an owner lookup.' }
function Get-Process { throw 'Import attempted to inspect processes.' }
function Stop-Process { throw 'Import attempted to stop a process.' }
function Start-Process { throw 'Import attempted to start a process.' }
function Start-Sleep { throw 'Import attempted to wait.' }
function Add-Type { throw 'Import attempted native compilation.' }
function Get-ChildItem { throw 'Import attempted directory enumeration.' }
function Remove-Item { throw 'Import attempted file removal.' }
function Set-ItemProperty { throw 'Import attempted a settings change.' }

$output = @(. $functionPath *>&1; . $functionPath *>&1)
if ($output.Count) { throw "Import produced output: $($output | Out-String)" }
$command = Get-Command Restart-WindowsThumbnailWorker -CommandType Function -ErrorAction Stop
if (-not $command.CmdletBinding -or -not $command.Parameters.ContainsKey('WhatIf') -or
    -not $command.Parameters.ContainsKey('Confirm') -or $command.Parameters.ContainsKey('Force') -or
    $command.ScriptBlock.Ast.Body.ParamBlock.Parameters.Count -ne 0) {
    throw 'Expected a parameterless advanced function with standard WhatIf/Confirm and no Force switch.'
}
'PASS: two profile-style imports only defined the cmdlet; no output, process operations, compilation, or filesystem work.'
