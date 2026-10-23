function Invoke-ExecutableAnalysisVm {
    <#
    .SYNOPSIS
        Observes an ELF executable inside a disposable, offline Linux VM.
    .DESCRIPTION
        Uses only a VM created by Initialize-ExecutableAnalysisVm. Restores its clean
        snapshot before execution and again in finally. Every NIC and host integration
        must be disabled. The target is never executed on the host. Runs an x86-64
        Linux executable as an unprivileged guest user with resource and time limits.
        Windows PE, Mach-O, other architectures, and relocatable objects are reported
        as unsupported. A VM is a containment measure, not a guarantee against escape.
    .PARAMETER InputPath
        Literal path of the executable. The SHA256 must match inside the guest.
    .PARAMETER OutputPath
        New or empty directory for bounded guest logs and validation evidence.
    .PARAMETER VirtualMachineName
        Dedicated VM created by Initialize-ExecutableAnalysisVm.
    .PARAMETER TimeoutSeconds
        Execution limit, excluding the bounded VM boot and cleanup stages.
    .EXAMPLE
        Invoke-ExecutableAnalysisVm -InputPath ./program -OutputPath ./runtime
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
        [string]$VirtualMachineName = 'Profile-Analysis-Linux',
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
    )
    $ErrorActionPreference = 'Stop'
    $inputFile = Get-Item -LiteralPath $InputPath -ErrorAction Stop
    if ($inputFile.PSIsContainer -or $inputFile.PSProvider.Name -ne 'FileSystem') { throw 'InputPath must identify a filesystem file.' }
    if ($inputFile.Length -gt 512MB) { throw 'Runtime analysis currently limits inputs to 512 MiB.' }
    $outputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $hash = (Get-FileHash -LiteralPath $inputFile.FullName -Algorithm SHA256).Hash
    $validation = [ordered]@{ RestoredBefore = $false; HostIsolation = $false; GuestIsolation = $false; TargetHashMatched = $false; RestoredAfter = $false; PoweredOffAfter = $false }
    $result = [ordered]@{ Status = 'Unsupported'; OutputPath = $outputDirectory; GuestOS = 'Ubuntu 24.04 LTS x86-64'; TargetSHA256 = $hash; Validation = $validation; Limitations = @('Only offline, unprivileged x86-64 Linux ELF execution is supported.', 'No arguments, GUI interaction, or network behavior are exercised.', 'A clean VM reduces exposure but does not guarantee containment or complete behavior coverage.') }
    $header = [byte[]]::new(20)
    $stream = [IO.File]::OpenRead($inputFile.FullName)
    try { $read = $stream.Read($header, 0, $header.Length) } finally { $stream.Dispose() }
    if ($read -lt 20 -or $header[0] -ne 0x7f -or $header[1] -ne 0x45 -or $header[2] -ne 0x4c -or $header[3] -ne 0x46 -or $header[4] -ne 2 -or $header[5] -ne 1 -or $header[18] -ne 62 -or $header[19] -ne 0 -or $header[16] -notin 2, 3 -or $header[17] -ne 0) {
        return [pscustomobject]$result
    }
    if (-not $IsWindows) { throw 'This VM adapter requires PowerShell 7 on Windows with VirtualBox.' }
    if (Test-Path -LiteralPath $outputDirectory) {
        if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container) -or @(Get-ChildItem -LiteralPath $outputDirectory -Force).Count) { throw 'OutputPath must be a new or empty directory; existing artifacts will not be overwritten.' }
    }
    $vbox = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
    if (-not (Test-Path -LiteralPath $vbox -PathType Leaf)) { throw 'VirtualBox is unavailable. Create the dedicated VM with Initialize-ExecutableAnalysisVm first.' }
    function Invoke-VBoxAnalysis {
        param([string[]]$Arguments, [int]$CommandTimeoutSeconds = 60)
        $startInfo = [Diagnostics.ProcessStartInfo]::new($vbox)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) { throw 'VirtualBox command could not start.' }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit($CommandTimeoutSeconds * 1000)) { $process.Kill($true); $process.WaitForExit(); throw "VirtualBox command exceeded $CommandTimeoutSeconds seconds." }
            $text = $stdout.GetAwaiter().GetResult()
            $errorText = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { throw "VirtualBox command failed ($($process.ExitCode)): $($errorText.Trim()) $($text.Trim())" }
            $text -replace "`r`n", "`n"
        } finally { $process.Dispose() }
    }
    function Get-AnalysisVmSetting {
        $raw = Invoke-VBoxAnalysis -Arguments @('showvminfo', $VirtualMachineName, '--machinereadable')
        $settings = @{}
        foreach ($line in ($raw -split "`n")) {
            if ($line -match '^([^=]+)="(.*)"$') { $settings[$Matches[1].Trim('"')] = $Matches[2] }
        }
        $settings
    }
    function Assert-AnalysisVmIsolation {
        param([hashtable]$Settings)
        foreach ($adapter in 1..8) { if ($Settings["nic$adapter"] -ne 'none') { throw "Isolation check failed: network adapter $adapter is enabled." } }
        foreach ($key in @('usb', 'ehci', 'xhci', 'vrde', 'audio_in', 'audio_out', 'nested-hw-virt', 'teleporterenabled')) { if ($Settings[$key] -ne 'off') { throw "Isolation check failed: $key is enabled or unknown." } }
        foreach ($key in @('clipboard', 'draganddrop')) { if ($Settings[$key] -ne 'disabled') { throw "Isolation check failed: $key is enabled or unknown." } }
        if ($Settings.clipboard_file_transfers -ne 'off') { throw 'Isolation check failed: clipboard file transfer is enabled or unknown.' }
        foreach ($port in 1..4) { if ($Settings["uart$port"] -ne 'off') { throw "Isolation check failed: serial port $port is enabled or unknown." } }
        if (@($Settings.Keys | Where-Object { $_ -like 'SharedFolder*' }).Count) { throw 'Isolation check failed: shared folders are configured.' }
        if ($Settings.UUID -ne $manifest.VirtualMachineId) { throw 'The VM identity does not match its ownership manifest.' }
        $ownedRoot = [IO.Path]::GetFullPath($manifest.StoragePath).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        foreach ($key in @($Settings.Keys | Where-Object { $_ -match '^.+-\d+-\d+$' -and $_ -notmatch '-(ImageUUID|hot-pluggable|nonrotational|discard|tempeject|IsEjected)-' })) {
            $medium = $Settings[$key].Replace('\\', '\')
            if ($medium -in @('none', 'emptydrive')) { continue }
            if (-not [IO.Path]::GetFullPath($medium).StartsWith($ownedRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($medium) -ne '.vdi') {
                throw "Isolation check failed: storage medium '$key' is not a project-owned VDI disk."
            }
        }
    }
    function Enter-AnalysisVmLock {
        param([Parameter(Mandatory)][string]$StoragePath)
        $lockPath = Join-Path $StoragePath 'analysis-runtime.lock'
        try { [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { throw 'The analysis VM is busy, or its exclusive runtime lock is unavailable. No VM changes were made.' }
    }
    $metadata = Invoke-VBoxAnalysis -Arguments @('getextradata', $VirtualMachineName, 'PowerShellProfile.AnalysisVm.Manifest')
    if ($metadata -notmatch '^Value: (.+)\n?$') { throw 'The selected VM has no analysis ownership manifest. Use Initialize-ExecutableAnalysisVm; unrelated VMs will not be modified.' }
    $manifestPath = $Matches[1].TrimEnd("`r", "`n")
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Schema -ne 'PowerShellProfile.AnalysisVm.v1' -or $manifest.Status -ne 'Ready' -or $manifest.VirtualMachineName -ne $VirtualMachineName -or $manifest.SnapshotId -notmatch '^[a-f0-9-]{36}$') { throw 'The selected VM has an invalid or incomplete ownership manifest.' }
    if (-not $PSCmdlet.ShouldProcess($inputFile.FullName, "Execute in offline disposable VM '$VirtualMachineName' and restore its clean snapshot before and after")) {
        $result.Status = 'WhatIf'
        return [pscustomobject]$result
    }
    $vmLock = Enter-AnalysisVmLock -StoragePath $manifest.StoragePath
    try {
    $settings = Get-AnalysisVmSetting
    if ($settings.VMState -ne 'poweroff') { throw 'The analysis VM must be powered off before a run. A running or saved VM will not be discarded.' }
    Assert-AnalysisVmIsolation -Settings $settings
    $snapshots = Invoke-VBoxAnalysis -Arguments @('snapshot', $VirtualMachineName, 'list', '--machinereadable')
    if ($snapshots -notmatch [regex]::Escape($manifest.SnapshotId)) { throw 'The recorded clean snapshot is missing.' }
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $credential = Import-Clixml -LiteralPath $manifest.CredentialPath
    if ($credential -isnot [pscredential] -or $credential.UserName -ne $manifest.GuestUser) { throw 'The protected guest credential does not match the analysis VM.' }
    $passwordFile = Join-Path $manifest.StoragePath ("runtime-credential-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
    $auth = @('--username', $manifest.GuestUser, '--passwordfile', $passwordFile)
    $cleanupNeeded = $false
    $runError = $null
    try {
        [IO.File]::WriteAllText($passwordFile, $credential.GetNetworkCredential().Password)
        $cleanupNeeded = $true
        Invoke-VBoxAnalysis -Arguments @('snapshot', $VirtualMachineName, 'restore', $manifest.SnapshotId) | Out-Null
        $settings = Get-AnalysisVmSetting
        Assert-AnalysisVmIsolation -Settings $settings
        if ($settings.VMState -ne 'poweroff' -or $settings.CurrentSnapshotUUID -ne $manifest.SnapshotId) { throw 'Pre-run snapshot or powered-off state could not be verified.' }
        $validation.RestoredBefore = $true
        $validation.HostIsolation = $true
        $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputDirectory 'vm-isolation-before.json') -Encoding utf8
        Invoke-VBoxAnalysis -Arguments @('startvm', $VirtualMachineName, '--type', 'headless') | Out-Null
        $deadline = [datetime]::UtcNow.AddSeconds(180)
        $guestReady = $false
        do {
            try {
                Invoke-VBoxAnalysis -Arguments (@('guestcontrol', $VirtualMachineName, 'run', '--exe', '/usr/bin/test') + $auth + @('--timeout', '5000', '--', '-f', '/opt/profile-analysis/ready')) -CommandTimeoutSeconds 10 | Out-Null
                $guestReady = $true
            } catch { if ([datetime]::UtcNow -ge $deadline) { throw "Analysis guest did not become ready: $($_.Exception.Message)" }; Start-Sleep -Seconds 2 }
        } while (-not $guestReady)
        Invoke-VBoxAnalysis -Arguments (@('guestcontrol', $VirtualMachineName, 'copyto') + $auth + @($inputFile.FullName, '/home/analysis-admin/input.bin')) | Out-Null
        $guestHashOutput = Invoke-VBoxAnalysis -Arguments (@('guestcontrol', $VirtualMachineName, 'run', '--exe', '/usr/bin/sha256sum') + $auth + @('--timeout', '10000', '--wait-stdout', '--', '/home/analysis-admin/input.bin'))
        if ($guestHashOutput -notmatch ('(?i)^' + $hash + '\s')) { throw 'The target SHA256 changed during guest transfer; execution was refused.' }
        $validation.TargetHashMatched = $true
        $guestResult = Invoke-VBoxAnalysis -Arguments (@('guestcontrol', $VirtualMachineName, 'run', '--exe', '/usr/bin/sudo') + $auth + @('--timeout', [string](($TimeoutSeconds + 15) * 1000), '--wait-stdout', '--wait-stderr', '--', '/usr/bin/python3', '/opt/profile-analysis/run.py', [string]$TimeoutSeconds)) -CommandTimeoutSeconds ($TimeoutSeconds + 25)
        [IO.File]::WriteAllText((Join-Path $outputDirectory 'guest-runner.txt'), $guestResult)
        foreach ($fileName in @('stdout.txt', 'stderr.txt', 'strace.log', 'runtime.json')) {
            Invoke-VBoxAnalysis -Arguments (@('guestcontrol', $VirtualMachineName, 'copyfrom') + $auth + @("/home/analysis-admin/results/$fileName", (Join-Path $outputDirectory $fileName))) | Out-Null
            if ((Get-Item -LiteralPath (Join-Path $outputDirectory $fileName)).Length -gt 12MB) { throw "Guest artifact '$fileName' exceeded its size limit." }
        }
        $runtime = Get-Content -LiteralPath (Join-Path $outputDirectory 'runtime.json') -Raw | ConvertFrom-Json
        if ($runtime.target.sha256 -ne $hash -or $runtime.target.routes.Trim() -or @($runtime.target.network -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '^lo\s' }).Count) { throw 'Guest runtime evidence failed hash or isolation verification.' }
        $validation.GuestIsolation = $true
        $result.Status = if ($runtime.termination -eq 'Exited' -and $runtime.exitCode -eq 0) { 'Complete' } else { 'Partial' }
        $result.Runtime = $runtime
    }
    catch { $runError = $_; $result.Status = 'Failed'; $result.Error = $_.Exception.Message }
    finally {
        if ($cleanupNeeded) {
            try {
                $settings = Get-AnalysisVmSetting
                if ($settings.VMState -ne 'poweroff') { Invoke-VBoxAnalysis -Arguments @('controlvm', $VirtualMachineName, 'poweroff') | Out-Null }
                Invoke-VBoxAnalysis -Arguments @('snapshot', $VirtualMachineName, 'restore', $manifest.SnapshotId) | Out-Null
                $settings = Get-AnalysisVmSetting
                Assert-AnalysisVmIsolation -Settings $settings
                if ($settings.VMState -ne 'poweroff' -or $settings.CurrentSnapshotUUID -ne $manifest.SnapshotId) { throw 'Post-run snapshot or powered-off state could not be verified.' }
                $validation.RestoredAfter = $true
                $validation.PoweredOffAfter = $true
                $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputDirectory 'vm-isolation-after.json') -Encoding utf8
            }
            catch { $result.Status = 'CleanupFailed'; $result.CleanupError = $_.Exception.Message; Write-Warning "Analysis VM cleanup failed: $($_.Exception.Message). Do not reuse it until isolation and the clean snapshot are verified." }
        }
        if (Test-Path -LiteralPath $passwordFile -PathType Leaf) { Remove-Item -LiteralPath $passwordFile -Force }
        $artifactHashes = @(Get-ChildItem -LiteralPath $outputDirectory -File | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Length = $_.Length; SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
        $artifactHashes | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $outputDirectory 'artifact-hashes.json') -Encoding utf8
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outputDirectory 'vm-validation.json') -Encoding utf8
    }
    if ($runError) { Write-Verbose $runError.Exception.Message }
    [pscustomobject]$result
    }
    finally { $vmLock.Dispose() }
}
