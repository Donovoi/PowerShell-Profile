#requires -Version 7.0
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($TestRoot)
if (Test-Path -LiteralPath $root) { throw 'Use a new disposable TestRoot.' }
$null=[IO.Directory]::CreateDirectory($root)
$checks=[Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$installer=Join-Path $PSScriptRoot '../functions/Install-Profile.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($installer,[ref]$null,[ref]$null)
foreach ($name in @('Write-InstallStatus','Read-InstallStatus','Write-InstallFailureStatus')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$request=[pscustomobject]@{RunPath=$root;ProfilePath='fixture';StagePath='stage';BackupPath='backup'}
$statusPath=Join-Path $root 'status.json'
Write-InstallStatus 'Staging' 'Original record.'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public static class ProfileStatusTestReader {
    public static Task ReleaseAfter(FileStream stream, int milliseconds) {
        return Task.Run(() => { Thread.Sleep(milliseconds); stream.Dispose(); });
    }
}
'@
# A real Windows reader permitting reads but denying rename/delete.
$stream=[IO.FileStream]::new($statusPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$release=[ProfileStatusTestReader]::ReleaseAfter($stream,300)
$watch=[Diagnostics.Stopwatch]::StartNew()
Write-InstallStatus 'WaitingForParent' 'Updated after reader release.'
$release.GetAwaiter().GetResult()
Assert-True ($watch.ElapsedMilliseconds -ge 200) 'The held reader did not exercise the retry.'
$status=Read-InstallStatus $statusPath
Assert-True ($status.Status -eq 'WaitingForParent') 'Retry did not publish complete JSON.'
$checks.Add('A real reader denying delete sharing is retried until release')

# A correctly shared reader keeps its old complete snapshot across replacement.
$shared=[IO.FileStream]::new($statusPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
$reader=[IO.StreamReader]::new($shared)
try {
    Write-InstallStatus 'Installed' 'New record.' $true $true
    $old=$reader.ReadToEnd() | ConvertFrom-Json
    Assert-True ($old.Status -eq 'WaitingForParent' -and (Read-InstallStatus $statusPath).Status -eq 'Installed') 'Atomic snapshots were corrupted.'
}
finally { $reader.Dispose() }
$checks.Add('Readers with delete sharing see consistent old or new snapshots')

# Opening a new reader can race an atomic replacement or an exclusive file holder.
$exclusive=[IO.FileStream]::new($statusPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
$release=[ProfileStatusTestReader]::ReleaseAfter($exclusive,300)
$watch.Restart()
$status=Read-InstallStatus $statusPath
$null=$release.GetAwaiter().GetResult()
Assert-True ($watch.ElapsedMilliseconds -ge 200 -and $status.Status -eq 'Installed') 'Status read did not retry a real sharing violation.'
$checks.Add('A new status reader retries a real exclusive lock and returns complete JSON after release')

$exclusive=[IO.FileStream]::new($statusPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
try {
    $watch.Restart(); $caught=$false
    try { Read-InstallStatus $statusPath | Out-Null } catch { $caught=$true }
    Assert-True ($caught -and $watch.Elapsed.TotalSeconds -lt 5) 'A persistent read blocker did not fail within the retry budget.'
} finally { $exclusive.Dispose() }
$invalidPath=Join-Path $root 'invalid-status.json'
[IO.File]::WriteAllText($invalidPath,'{invalid')
$caught=$false
try { Read-InstallStatus $invalidPath | Out-Null } catch { $caught=$true }
Assert-True $caught 'Malformed status JSON was accepted or suppressed.'
$checks.Add('Persistent read locks are bounded and malformed JSON still fails')

$stream=[IO.FileStream]::new($statusPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $watch.Restart()
    $caught=$false
    try { Write-InstallStatus 'Failed' 'Blocked record.' }
    catch { $caught=$true }
    Assert-True ($caught -and $watch.Elapsed.TotalSeconds -lt 5) 'A persistent blocker did not fail within the retry budget.'
    Assert-True ((Read-InstallStatus $statusPath).Status -eq 'Installed') 'A failed publication damaged the old JSON.'
    $checks.Add('Persistent blockers fail within a bounded retry budget and preserve the old record')
    $message=$null
    try {
        try { throw 'Original promotion failure fixture' }
        catch { Write-InstallFailureStatus 'Failed' $_.Exception.Message; throw }
    }
    catch { $message=$_.Exception.Message }
    Assert-True ($message -eq 'Original promotion failure fixture') 'Status reporting replaced the original failure.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'install.log')) -match 'Original promotion failure fixture.*Status publication failed') 'Fallback diagnostics were not retained.'
    $checks.Add('Failure reporting preserves the original exception and logs publication failure')
}
finally { $stream.Dispose() }
[pscustomobject]@{Passed=$checks.Count;Checks=$checks;TestRoot=$root} | ConvertTo-Json -Depth 4
