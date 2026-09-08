#requires -Version 7.0
param([Parameter(Mandatory)][string] $TestRoot)
$ErrorActionPreference = 'Stop'
$installer = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../functions/Install-Profile.ps1'))
$testRootFull = [IO.Path]::GetFullPath($TestRoot)
$docs = [IO.Path]::GetFullPath([Environment]::GetFolderPath('MyDocuments')).TrimEnd('\')
if (-not $testRootFull.StartsWith($docs + '\', [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $testRootFull)) { throw 'Use a new disposable TestRoot beneath Documents.' }
[void][IO.Directory]::CreateDirectory($testRootFull)
$pwsh = (Get-Process -Id $PID).Path
$children = [Collections.Generic.List[Diagnostics.Process]]::new()
$checks = [Collections.Generic.List[string]]::new()

function Assert-Test([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Quote-Literal([string] $Value) { "'" + $Value.Replace("'", "''") + "'" }
function Start-TestProcess([string] $Code, [string] $Name) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    $process = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) `
        -WindowStyle Hidden -WorkingDirectory $testRootFull -PassThru `
        -RedirectStandardOutput (Join-Path $testRootFull "$Name.stdout.log") `
        -RedirectStandardError (Join-Path $testRootFull "$Name.stderr.log")
    $children.Add($process)
    return $process
}
function Wait-File([string] $Path) {
    for ($i=0; $i -lt 200; $i++) {
        if (Test-Path -LiteralPath $Path) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for '$Path'."
}
function Wait-Status([string] $StateRoot) {
    Wait-File (Join-Path $StateRoot 'latest.json')
    $latest = Get-Content -LiteralPath (Join-Path $StateRoot 'latest.json') -Raw | ConvertFrom-Json
    for ($i=0; $i -lt 300; $i++) {
        $status = Get-Content -LiteralPath $latest.StatusPath -Raw | ConvertFrom-Json
        if ($status.Status -in @('Installed','Failed','InstalledWithCleanupPending')) { return $status }
        Start-Sleep -Milliseconds 100
    }
    throw "Installer timed out. See '$($latest.RunPath)'."
}
function New-Fixture([string] $Name) {
    $base = Join-Path $testRootFull $Name
    $target = Join-Path $base 'PowerShell'
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'legacy.txt'), 'original profile sentinel')
    [pscustomobject]@{ Base=$base; Target=$target; State=(Join-Path $base 'state') }
}
function Start-Installer($Fixture, [string] $Before='', [string] $Source=$script:source) {
    $uri = [uri]::new($Source).AbsoluteUri
    # Match the gist's IEX -> dot-sourced downloaded scriptblock -> function call.
    $launchBody = '. ([scriptblock]::Create([IO.File]::ReadAllText(' + (Quote-Literal $installer) +
        '))); Install-Profile -ProfileUrl ' + (Quote-Literal $uri) + ' -ProfilePath ' +
        (Quote-Literal $Fixture.Target) + ' -StateRoot ' + (Quote-Literal $Fixture.State)
    $code = '$ErrorActionPreference="Stop"; ' + $Before + '; Invoke-Expression ' +
        (Quote-Literal $launchBody) + '; throw "Installer returned instead of exiting its caller."'
    Start-TestProcess $code ([IO.Path]::GetFileName($Fixture.Base) + '-installer')
}

try {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors)
    Assert-Test ($errors.Count -eq 0) 'Installer must parse.'
    Assert-Test ($ast.EndBlock.Statements.Count -eq 1 -and
        $ast.EndBlock.Statements[0] -is [Management.Automation.Language.FunctionDefinitionAst]) 'Import must only define a function.'
    $import=@(. $installer *>&1; . $installer *>&1)
    Assert-Test ($import.Count -eq 0 -and -not ('ProfileInstallerLocksV1.RestartManager' -as [type])) 'Import started work.'
    $checks.Add('Import twice: definition only, no native compilation or installation')

    $source=Join-Path $testRootFull 'source repo'
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'functions'))
    [IO.File]::WriteAllText((Join-Path $source 'Microsoft.PowerShell_profile.ps1'), 'throw "Staged profile must never be executed during installation."')
    [IO.File]::WriteAllText((Join-Path $source 'functions/Example.ps1'), 'function Example { "new profile" }')
    & git init --quiet $source
    & git -C $source add .
    & git -C $source -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'Disposable fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Could not create fixture repository.' }

    $unrelated=Start-TestProcess 'Start-Sleep -Seconds 180' 'unrelated'
    $self=New-Fixture "self lock and quote ' path"
    $assemblyPath=Join-Path $self.Target 'Locked.dll'
    Add-Type -TypeDefinition 'public class ProfileInstallFixtureAssembly { public static int Value = 7; }' -OutputAssembly $assemblyPath
    $before='[void][Reflection.Assembly]::LoadFile('+(Quote-Literal $assemblyPath)+'); $held=[IO.File]::Open('+
        (Quote-Literal (Join-Path $self.Target 'legacy.txt'))+',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)'
    $parent=Start-Installer $self $before
    Assert-Test ($parent.WaitForExit(30000)) 'Invoking process did not exit.'
    $status=Wait-Status $self.State
    Assert-Test ($parent.ExitCode -eq 0 -and $status.Status -eq 'Installed' -and $status.CleanupComplete) ($status | ConvertTo-Json)
    Assert-Test ((Test-Path -LiteralPath (Join-Path $self.Target '.git')) -and
        (Test-Path -LiteralPath (Join-Path $self.Target 'functions/Example.ps1')) -and
        -not (Test-Path -LiteralPath (Join-Path $self.Target 'legacy.txt')) -and
        -not (Test-Path -LiteralPath $status.BackupPath) -and -not (Test-Path -LiteralPath $status.StagePath)) 'Full replacement/cleanup failed.'
    Assert-Test (-not $unrelated.HasExited) 'An unrelated PowerShell process was stopped.'
    $checks.Add('Loaded DLL and open file in invoking process; detached helper survives exit; complete replacement and old-tree deletion; spaces/apostrophes')

    $other=New-Fixture 'second holder'
    $ready=Join-Path $other.Base 'holder.ready'
    $holderCode='$held=[IO.File]::Open('+(Quote-Literal (Join-Path $other.Target 'legacy.txt'))+
        ',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); [IO.File]::WriteAllText('+
        (Quote-Literal $ready)+',"ready"); Start-Sleep -Seconds 90'
    $holder=Start-TestProcess $holderCode 'holder'
    Wait-File $ready
    $parent=Start-Installer $other
    Assert-Test ($parent.WaitForExit(30000)) 'Second installer caller did not exit.'
    $status=Wait-Status $other.State
    Assert-Test ($status.Status -eq 'Installed' -and $holder.HasExited -and -not $unrelated.HasExited) ($status | ConvertTo-Json)
    $log=Get-Content -LiteralPath $status.LogPath -Raw
    Assert-Test ($log -match "Stopping profile file holder pwsh \(PID $($holder.Id)\)") 'Exact locking process was not identified in the log.'
    $checks.Add('Restart Manager identifies and stops only the exact other PowerShell file holder')

    $badSource=Join-Path $testRootFull 'invalid source'
    & git clone --quiet -- $source $badSource
    [IO.File]::WriteAllText((Join-Path $badSource 'Microsoft.PowerShell_profile.ps1'), 'function Broken {')
    & git -C $badSource add .
    & git -C $badSource -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'Invalid fixture'
    $invalid=New-Fixture 'invalid replacement'
    $parent=Start-Installer $invalid '' $badSource
    Assert-Test ($parent.WaitForExit(30000) -and $parent.ExitCode -ne 0) 'Invalid profile was not rejected.'
    Assert-Test ((Get-Content -LiteralPath (Join-Path $invalid.Target 'legacy.txt') -Raw) -eq 'original profile sentinel') 'Invalid staging changed the destination.'
    $failedRun=Get-ChildItem -LiteralPath $invalid.State -Directory | Select-Object -First 1
    $failedStatus=Get-Content -LiteralPath (Join-Path $failedRun.FullName 'status.json') -Raw | ConvertFrom-Json
    Assert-Test ($failedStatus.Status -eq 'Failed' -and (Test-Path -LiteralPath $failedStatus.StagePath)) 'Failed staging was discarded.'
    $checks.Add('Invalid staged profile rejected before caller exit; old profile and staging retained')

    # Test the read-only target validator directly: never invoke deletion for unsafe targets.
    $guardAst=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ProfileTarget'},$true)
    . ([scriptblock]::Create($guardAst.Extent.Text))
    foreach ($bad in @($docs,[IO.Path]::GetPathRoot($docs),(Join-Path $docs 'OtherFolder'))) {
        $rejected=$false
        try { Assert-ProfileTarget $bad | Out-Null } catch { $rejected=$true }
        Assert-Test $rejected "Unsafe path was accepted: $bad"
    }
    $junction=Join-Path $testRootFull 'junction'
    [void](New-Item -ItemType Junction -Path $junction -Target $self.Base)
    $rejected=$false
    try { Assert-ProfileTarget (Join-Path $junction 'PowerShell') | Out-Null } catch { $rejected=$true }
    Assert-Test $rejected 'Reparse-point ancestry was accepted.'
    $checks.Add('Root, Documents, unrelated folder, and junction ancestry rejected by read-only validation')

    # Hold the STAGED directory, not the old profile, to force promotion failure.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class ProfileFixtureDirectoryLock {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
}
'@
    $rollback=New-Fixture 'rollback'
    $id=[guid]::NewGuid().ToString('N')
    $stage=Join-Path $rollback.Base ".PowerShell.stage-$id"
    $backup=Join-Path $rollback.Base ".PowerShell.previous-$id"
    & git clone --quiet -- $source $stage
    [void][IO.Directory]::CreateDirectory($rollback.State)
    $requestPath=Join-Path $rollback.State 'request.json'
    [pscustomobject]@{Version=1;RunId=$id;RunPath=$rollback.State;ProfilePath=$rollback.Target;StagePath=$stage;BackupPath=$backup;
        ParentProcessId=$parent.Id;ParentStartFileTime=0;ParentSessionId=(Get-Process -Id $PID).SessionId} |
        ConvertTo-Json | Set-Content -LiteralPath $requestPath
    $directoryHandle=[ProfileFixtureDirectoryLock]::CreateFile($stage,[uint32]2147483648,3,[IntPtr]::Zero,3,0x02000000,[IntPtr]::Zero)
    Assert-Test (-not $directoryHandle.IsInvalid) 'Could not create staged-directory lock.'
    try {
        $worker=Start-TestProcess ('. '+(Quote-Literal $installer)+'; Install-Profile -WorkerRequestPath '+(Quote-Literal $requestPath)) 'rollback-worker'
        Assert-Test ($worker.WaitForExit(30000) -and $worker.ExitCode -ne 0) 'Promotion failure was not reported.'
    } finally { $directoryHandle.Dispose() }
    $status=Get-Content -LiteralPath (Join-Path $rollback.State 'status.json') -Raw | ConvertFrom-Json
    Assert-Test ($status.Status -eq 'Failed' -and -not $status.Installed -and
        (Test-Path -LiteralPath (Join-Path $rollback.Target 'legacy.txt')) -and
        (Test-Path -LiteralPath (Join-Path $stage 'functions/Example.ps1')) -and
        -not (Test-Path -LiteralPath $backup)) 'Failed promotion did not restore the old directory and retain staging.'
    $checks.Add('Real directory-lock failure during promotion restores the original directory and retains the replacement')
    Assert-Test (-not $unrelated.HasExited) 'Unrelated PowerShell process did not survive the tests.'
    [pscustomobject]@{Result='PASS';Checks=$checks.ToArray();TestRoot=$testRootFull} | ConvertTo-Json -Depth 4
}
finally {
    # Only processes created by this test are eligible for teardown.
    foreach ($child in $children) {
        if (-not $child.HasExited) { Stop-Process -InputObject $child -Force -ErrorAction SilentlyContinue }
    }
}
