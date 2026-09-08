function Install-Profile {
    <#
    .SYNOPSIS
    Replaces the PowerShell profile from a validated Git checkout.
    .DESCRIPTION
    Stages the replacement beside the destination, starts a hidden -NoProfile helper,
    and exits the invoking PowerShell session to release its loaded DLLs. The helper
    waits for that exact process to exit before changing the destination.
    Only other PowerShell processes in the same Windows session that Restart Manager
    identifies as using files in this profile are stopped. Other blockers are reported.
    The old directory is renamed aside, the new checkout is promoted, and then the old
    directory is deleted. Failed promotion restores the old directory. Staging and logs
    are retained on failure. No profile or module is imported during installation.
    .PARAMETER ProfilePath
    A directory named PowerShell beneath Documents. Reparse-point ancestry is rejected.
    .PARAMETER StateRoot
    Persistent logs and status; defaults to LocalAppData/PowerShell-Profile/Install.
    .NOTES
    Calling this command intentionally closes the invoking PowerShell session after
    the helper acknowledges startup. Reopen PowerShell after status is Installed.
    Importing this file only defines the function and never starts an installation.
    .EXAMPLE
    Install-Profile
    .LINK
    https://learn.microsoft.com/en-us/windows/win32/api/restartmanager/nf-restartmanager-rmgetlist
    #>
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [uri] $ProfileUrl = 'https://github.com/Donovoi/PowerShell-Profile.git',
        [ValidateNotNullOrEmpty()]
        [string] $ProfilePath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell'),
        [ValidateNotNullOrEmpty()]
        [string] $StateRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PowerShell-Profile/Install'),
        [Parameter(DontShow)] [string] $WorkerRequestPath
    )
    $ErrorActionPreference = 'Stop'
    if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $IsWindows) {
        throw 'Install-Profile requires PowerShell 7 on Windows.'
    }

    function Assert-ProfileTarget {
        param([string] $Path)
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $docs = [IO.Path]::GetFullPath([Environment]::GetFolderPath('MyDocuments')).TrimEnd('\')
        if (-not $full.StartsWith($docs + '\', [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($full) -ine 'PowerShell') {
            throw "Refusing profile target '$full': it must be named PowerShell beneath Documents."
        }
        for ($cursor = $full; $cursor.Length -ge $docs.Length; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force
                if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "Refusing non-directory or reparse-point ancestry at '$cursor'."
                }
            }
            if ($cursor -ieq $docs) { break }
        }
        return $full
    }

    function Assert-SiblingPath {
        param([string] $Candidate, [string] $Target, [string] $ExpectedName)
        $full = [IO.Path]::GetFullPath($Candidate)
        $expected = Join-Path ([IO.Path]::GetDirectoryName($Target)) $ExpectedName
        if ($full -ine $expected) { throw "Invalid installer sibling path '$full'." }
        if ((Test-Path -LiteralPath $full) -and
            ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing installer reparse point '$full'."
        }
        return $full
    }

    function Assert-StagedProfile {
        param([string] $Path)
        $profileFile = Join-Path $Path 'Microsoft.PowerShell_profile.ps1'
        if (-not (Test-Path -LiteralPath $profileFile -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $Path 'functions') -PathType Container) -or
            -not (Test-Path -LiteralPath (Join-Path $Path '.git') -PathType Container)) {
            throw "Staged checkout '$Path' is missing its profile, functions, or Git metadata."
        }
        $parseTokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($profileFile, [ref]$parseTokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Staged profile does not parse: $($parseErrors -join '; ')" }
    }

    function Write-InstallStatus {
        param([string] $Status, [string] $Message, [bool] $Installed = $false, [bool] $CleanupComplete = $false)
        $record = [ordered]@{
            Status = $Status; Message = $Message; Installed = $Installed; CleanupComplete = $CleanupComplete
            UpdatedUtc = [DateTime]::UtcNow.ToString('o'); WorkerProcessId = $PID
            ProfilePath = $request.ProfilePath; StagePath = $request.StagePath; BackupPath = $request.BackupPath
            LogPath = (Join-Path $request.RunPath 'install.log'); RunPath = $request.RunPath
        }
        $statusPath = Join-Path $request.RunPath 'status.json'
        [IO.File]::WriteAllText($statusPath + '.tmp', ($record | ConvertTo-Json -Depth 4))
        [IO.File]::Move($statusPath + '.tmp', $statusPath, $true)
        [IO.File]::AppendAllText($record.LogPath, "[$($record.UpdatedUtc)] $Status $Message`r`n")
    }

    function Get-ProfileLockOwners {
        param([string] $Path)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force | ForEach-Object FullName)
        if (-not $files.Count) { return }
        if (-not ('ProfileInstallerLocksV1.RestartManager' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace ProfileInstallerLocksV1 {
    [StructLayout(LayoutKind.Sequential)]
    public struct UniqueProcess { public uint Id; public System.Runtime.InteropServices.ComTypes.FILETIME Start; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct Owner {
        public UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string Service;
        public uint ApplicationType, Status, Session;
        [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
        public long StartFileTime { get { return ((long)(uint)Process.Start.dwHighDateTime << 32) | (uint)Process.Start.dwLowDateTime; } }
    }
    public static class RestartManager {
        [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
        static extern int RmStartSession(out uint session, uint flags, StringBuilder key);
        [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
        static extern int RmRegisterResources(uint session, uint count, string[] files, uint applications, IntPtr apps, uint services, IntPtr names);
        [DllImport("rstrtmgr.dll")]
        static extern int RmGetList(uint session, out uint needed, ref uint count, [In,Out] Owner[] owners, out uint reasons);
        [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint session);
        public static Owner[] Find(string[] files) {
            uint session;
            int result = RmStartSession(out session, 0, new StringBuilder(33));
            if (result != 0) throw new Win32Exception(result);
            try {
                result = RmRegisterResources(session, (uint)files.Length, files, 0, IntPtr.Zero, 0, IntPtr.Zero);
                if (result != 0) throw new Win32Exception(result);
                uint needed, count=0, reasons;
                Owner[] owners=null;
                for (int attempt=0; attempt<5; attempt++) {
                    result = RmGetList(session, out needed, ref count, owners, out reasons);
                    if (result == 0) {
                        if (count == 0) return new Owner[0];
                        Array.Resize(ref owners, (int)count);
                        return owners;
                    }
                    if (result != 234) throw new Win32Exception(result);
                    count=needed;
                    owners=new Owner[count];
                }
                throw new InvalidOperationException("The profile lock-owner list kept changing.");
            } finally { RmEndSession(session); }
        }
    }
}
'@
        }
        [ProfileInstallerLocksV1.RestartManager]::Find([string[]]$files)
    }

    function Stop-ProfilePowerShellHolders {
        param([string] $Path)
        $blocked = [Collections.Generic.List[string]]::new()
        foreach ($owner in @(Get-ProfileLockOwners -Path $Path)) {
            $process = Get-Process -Id $owner.Process.Id -ErrorAction SilentlyContinue
            if (-not $process -or $process.HasExited) { continue }
            if ($process.StartTime.ToFileTimeUtc() -ne $owner.StartFileTime) { continue }
            if ($process.Id -eq $PID -or $process.ProcessName -notin @('pwsh', 'powershell') -or
                $process.SessionId -ne $request.ParentSessionId) {
                $blocked.Add("$($process.ProcessName) (PID $($process.Id))")
                continue
            }
            Write-InstallStatus 'ReleasingLocks' "Stopping profile file holder $($process.ProcessName) (PID $($process.Id))."
            Stop-Process -InputObject $process -Force -Confirm:$false
            if (-not $process.WaitForExit(10000)) { throw "Profile holder PID $($process.Id) did not exit." }
        }
        if ($blocked.Count) { throw "Close these applications using the profile, then retry: $($blocked -join ', ')." }
    }

    if ($WorkerRequestPath) {
        $request = Get-Content -LiteralPath $WorkerRequestPath -Raw | ConvertFrom-Json
        $lockStream = $null
        $movedOld = $false
        $installed = $false
        try {
            if ($request.Version -ne 1 -or $request.RunId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid installer request.' }
            $request.ProfilePath = Assert-ProfileTarget $request.ProfilePath
            $request.StagePath = Assert-SiblingPath $request.StagePath $request.ProfilePath ".PowerShell.stage-$($request.RunId)"
            $request.BackupPath = Assert-SiblingPath $request.BackupPath $request.ProfilePath ".PowerShell.previous-$($request.RunId)"
            if (Test-Path -LiteralPath $request.BackupPath) { throw 'Installer backup path already exists.' }
            if (-not [IO.Directory]::Exists($request.RunPath) -or
                $request.RunPath -ieq $request.ProfilePath -or
                $request.RunPath.StartsWith($request.ProfilePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Installer state must exist outside the profile being replaced.'
            }
            Assert-StagedProfile $request.StagePath
            Set-Location -LiteralPath $request.RunPath
            Write-InstallStatus 'WaitingForParent' "Waiting for invoking PowerShell PID $($request.ParentProcessId) to exit."
            $parent = Get-Process -Id $request.ParentProcessId -ErrorAction SilentlyContinue
            if ($parent -and -not $parent.HasExited -and
                $parent.StartTime.ToFileTimeUtc() -eq $request.ParentStartFileTime) {
                if (-not $parent.WaitForExit(120000)) { throw 'Invoking PowerShell did not exit within two minutes. Profile was not changed.' }
            }
            if (Test-Path -LiteralPath (Join-Path $request.RunPath 'cancel')) { throw 'Installer handoff was cancelled.' }
            $request.ProfilePath = Assert-ProfileTarget $request.ProfilePath
            $lockPath = Join-Path ([IO.Path]::GetDirectoryName($request.ProfilePath)) '.PowerShell.install.lock'
            if ((Test-Path -LiteralPath $lockPath) -and
                ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Refusing a reparse-point installer lock.'
            }
            $lockStream = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
            Write-InstallStatus 'CheckingLocks' 'Checking processes that use files in this profile.'
            Stop-ProfilePowerShellHolders $request.ProfilePath
            Write-InstallStatus 'Replacing' 'Promoting the validated replacement checkout.'
            if (Test-Path -LiteralPath $request.ProfilePath) {
                # Both paths were resolved and validated as same-parent directories.
                [IO.Directory]::Move($request.ProfilePath, $request.BackupPath)
                $movedOld = $true
            }
            try {
                [IO.Directory]::Move($request.StagePath, $request.ProfilePath)
                $installed = $true
            }
            catch {
                if ($movedOld -and -not (Test-Path -LiteralPath $request.ProfilePath)) {
                    [IO.Directory]::Move($request.BackupPath, $request.ProfilePath)
                    $movedOld = $false
                }
                throw
            }
            if ($movedOld) {
                Write-InstallStatus 'CleaningUp' 'Replacement installed; deleting the old directory.' $true
                $null = Assert-ProfileTarget $request.ProfilePath
                $null = Assert-SiblingPath $request.BackupPath $request.ProfilePath ".PowerShell.previous-$($request.RunId)"
                Remove-Item -LiteralPath $request.BackupPath -Recurse -Force -Confirm:$false
            }
            Write-InstallStatus 'Installed' 'Installation and old-directory deletion completed. Open a new PowerShell session.' $true $true
        }
        catch {
            $state = if ($installed) { 'InstalledWithCleanupPending' } else { 'Failed' }
            Write-InstallStatus $state "$($_.Exception.Message) Replacement and diagnostics have been retained." $installed
            throw
        }
        finally { if ($lockStream) { $lockStream.Dispose() } }
        return
    }

    $target = Assert-ProfileTarget ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath))
    $stateDirectory = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StateRoot))
    if ($stateDirectory -ieq $target -or $stateDirectory.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'StateRoot must be outside the profile being replaced.'
    }
    $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $pwsh = (Get-Process -Id $PID).Path
    $runId = [guid]::NewGuid().ToString('N')
    $parentDirectory = [IO.Path]::GetDirectoryName($target)
    $stage = Join-Path $parentDirectory ".PowerShell.stage-$runId"
    $backup = Join-Path $parentDirectory ".PowerShell.previous-$runId"
    $runPath = Join-Path $stateDirectory $runId
    $null = Assert-SiblingPath $stage $target ".PowerShell.stage-$runId"
    $null = Assert-SiblingPath $backup $target ".PowerShell.previous-$runId"
    [void][IO.Directory]::CreateDirectory($parentDirectory)
    [void][IO.Directory]::CreateDirectory($runPath)
    $parentProcess = Get-Process -Id $PID
    $request = [pscustomobject]@{
        Version = 1; RunId = $runId; RunPath = $runPath
        ProfilePath = $target; StagePath = $stage; BackupPath = $backup
        ParentProcessId = $PID; ParentStartFileTime = $parentProcess.StartTime.ToFileTimeUtc()
        ParentSessionId = $parentProcess.SessionId
    }
    $worker = $null
    try {
        Write-InstallStatus 'Staging' 'Cloning the replacement; the existing profile has not been changed.'
        & $git.Source clone --recurse-submodules -- $ProfileUrl.AbsoluteUri $stage
        if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE." }
        Assert-StagedProfile $stage
        $requestPath = Join-Path $runPath 'request.json'
        $request | ConvertTo-Json | Set-Content -LiteralPath $requestPath -Encoding utf8
        $helperPath = Join-Path $runPath 'worker.ps1'
        # Capture this exact function version, without another download in the helper.
        $helper = "param([string]`$RequestPath)`r`nfunction Install-Profile {`r`n" +
            $MyInvocation.MyCommand.Definition + "`r`n}`r`nInstall-Profile -WorkerRequestPath `$RequestPath`r`n"
        [IO.File]::WriteAllText($helperPath, $helper)
        $command = "& '" + $helperPath.Replace("'", "''") + "' -RequestPath '" + $requestPath.Replace("'", "''") + "'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $worker = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) `
            -WorkingDirectory $runPath -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $runPath 'worker.stdout.log') `
            -RedirectStandardError (Join-Path $runPath 'worker.stderr.log')
        $ready = $false
        for ($attempt = 0; $attempt -lt 150; $attempt++) {
            $state = Get-Content -LiteralPath (Join-Path $runPath 'status.json') -Raw | ConvertFrom-Json
            if ($state.Status -eq 'WaitingForParent') { $ready = $true; break }
            if ($worker.HasExited -or $state.Status -eq 'Failed') { break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $ready) { throw "The installer helper did not become ready. Inspect '$runPath'. This session and the profile have not been replaced." }
        [pscustomobject]@{ RunPath = $runPath; StatusPath = (Join-Path $runPath 'status.json') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDirectory 'latest.json') -Encoding utf8
        Write-Information "Replacement staged. Closing this PowerShell session to release its DLLs. Status: $(Join-Path $runPath 'status.json')" -InformationAction Continue
        exit 0
    }
    catch {
        if ($worker) { [IO.File]::WriteAllText((Join-Path $runPath 'cancel'), 'Handoff failed before caller exit.') }
        Write-InstallStatus 'Failed' "$($_.Exception.Message) Staging retained at '$stage'."
        throw
    }
}
