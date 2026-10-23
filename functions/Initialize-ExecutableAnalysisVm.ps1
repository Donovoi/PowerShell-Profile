function Initialize-ExecutableAnalysisVm {
    <#
    .SYNOPSIS
        Creates a dedicated, disposable Ubuntu VM for executable analysis.
    .DESCRIPTION
        Downloads the official Ubuntu 24.04 LTS cloud disk and verifies its published
        SHA256. NAT is enabled only while Ubuntu installs its analysis tools. The
        resulting clean snapshot has all network adapters, shared folders, clipboard,
        drag and drop, USB, audio, serial ports, and remote display disabled.
        Requires an installed VirtualBox and PowerShell 7 on Windows. An existing VM
        without this command's ownership manifest is never modified.
    .PARAMETER VirtualMachineName
        Name of the dedicated VM. Existing unrelated VMs are refused.
    .PARAMETER StoragePath
        Directory for the VM disk, protected guest credential, and manifest.
    .PARAMETER ProvisioningTimeoutSeconds
        Maximum time to wait for guest package installation and readiness.
    .EXAMPLE
        Initialize-ExecutableAnalysisVm
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
        [string]$VirtualMachineName = 'Profile-Analysis-Linux',
        [string]$StoragePath,
        [ValidateRange(120, 3600)][int]$ProvisioningTimeoutSeconds = 1200
    )
    $ErrorActionPreference = 'Stop'
    # Native readiness probes intentionally return nonzero until the guest is ready.
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not $IsWindows) { throw 'VM provisioning currently requires PowerShell 7 on Windows with VirtualBox.' }
    $vbox = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
    if (-not (Test-Path -LiteralPath $vbox -PathType Leaf)) { throw 'Install Oracle VirtualBox before creating the analysis VM.' }
    $storageWasSpecified = -not [string]::IsNullOrWhiteSpace($StoragePath)
    if (-not $storageWasSpecified) { $StoragePath = Join-Path $env:LOCALAPPDATA "PowerShellProfile\AnalysisVm\$VirtualMachineName" }
    $storage = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StoragePath)
    $manifestPath = Join-Path $storage 'analysis-vm.json'
    function Invoke-VBoxSetup {
        param([string[]]$Arguments)
        $result = & $vbox @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "VirtualBox setup failed ($LASTEXITCODE): $($result -join "`n")" }
        $result -join "`n"
    }
    $registered = Invoke-VBoxSetup -Arguments @('list', 'vms')
    if ($registered -match ('(?m)^"' + [regex]::Escape($VirtualMachineName) + '" \{(?<id>[^}]+)\}$')) {
        $registeredId = $Matches.id
        $metadata = Invoke-VBoxSetup -Arguments @('getextradata', $VirtualMachineName, 'PowerShellProfile.AnalysisVm.Manifest')
        if ($metadata -notmatch '^Value: (.+)$') { throw "VM '$VirtualMachineName' already exists without an ownership marker; it will not be modified." }
        $registeredManifest = $Matches[1]
        if ($storageWasSpecified -and $registeredManifest -ne $manifestPath) { throw 'The existing VM is owned by a different storage directory. Its files will not be moved or overwritten.' }
        $manifestPath = $registeredManifest
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "VM '$VirtualMachineName' already exists without the expected ownership manifest; it will not be modified." }
        $existing = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($existing.Schema -ne 'PowerShellProfile.AnalysisVm.v1' -or $existing.VirtualMachineId -ne $registeredId -or $existing.Status -ne 'Ready') {
            throw 'The existing VM is not a completed, owned analysis VM. Inspect its manifest before any recovery.'
        }
        return $existing
    }
    if (-not $PSCmdlet.ShouldProcess($storage, "Create $VirtualMachineName with a verified Ubuntu disk; temporarily use NAT to install guest tools")) { return }
    if (Test-Path -LiteralPath $manifestPath) { throw "An existing manifest occupies '$manifestPath'; choose a new storage directory." }
    [IO.Directory]::CreateDirectory($storage) | Out-Null
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($storage))
    if ($drive.AvailableFreeSpace -lt 12GB) { throw 'At least 12 GiB of free disk space is required for provisioning and snapshots.' }
    $source = 'https://cloud-images.ubuntu.com/noble/current/'
    $diskName = 'noble-server-cloudimg-amd64.vmdk'
    $download = Join-Path $storage $diskName
    $checksums = Join-Path $storage 'SHA256SUMS'
    Invoke-WebRequest -Uri ($source + 'SHA256SUMS') -OutFile $checksums -TimeoutSec 120
    $hashLine = @(Get-Content -LiteralPath $checksums | Where-Object { $_ -match ('^[a-f0-9]{64}\s+\*?' + [regex]::Escape($diskName) + '$') })
    if ($hashLine.Count -ne 1) { throw 'The official checksum list did not uniquely identify the Ubuntu disk.' }
    $expectedHash = $hashLine[0].Substring(0, 64)
    if (-not (Test-Path -LiteralPath $download -PathType Leaf)) {
        Write-Verbose 'Downloading the official Ubuntu 24.04 LTS cloud disk.'
        Invoke-WebRequest -Uri ($source + $diskName) -OutFile $download -TimeoutSec 1800
    }
    $diskHash = (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash
    if ($diskHash -ne $expectedHash) { throw 'Ubuntu disk SHA256 does not match the official checksum. The disk will not be used.' }
    $credentialPath = Join-Path $storage 'guest-credential.clixml'
    $seedDirectory = Join-Path $storage 'seed'
    $seedIso = Join-Path $storage 'seed.iso'
    $passwordFile = Join-Path $storage 'bootstrap-password.tmp'
    foreach ($generatedPath in @($credentialPath, $seedIso, $passwordFile, (Join-Path $seedDirectory 'user-data'), (Join-Path $seedDirectory 'meta-data'))) {
        if (Test-Path -LiteralPath $generatedPath) { throw "Generated path '$generatedPath' already exists. Choose a fresh storage directory; existing files will not be overwritten." }
    }
    $created = $false
    $ready = $false
    $securePassword = $null
    try {
    $randomBytes = [byte[]]::new(24)
    $randomGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $randomGenerator.GetBytes($randomBytes) } finally { $randomGenerator.Dispose() }
    $guestPassword = ([BitConverter]::ToString($randomBytes)).Replace('-', '')
    $securePassword = [Security.SecureString]::new()
    foreach ($character in $guestPassword.ToCharArray()) { $securePassword.AppendChar($character) }
    $securePassword.MakeReadOnly()
    $credential = [pscredential]::new('analysis-admin', $securePassword)
    $credential | Export-Clixml -LiteralPath $credentialPath
    [IO.Directory]::CreateDirectory($seedDirectory) | Out-Null
    $runner = @'
#!/usr/bin/python3
import hashlib, json, os, pathlib, signal, stat, subprocess, sys, time
source = pathlib.Path('/home/analysis-admin/input.bin')
out = pathlib.Path('/home/analysis-admin/results')
out.mkdir(mode=0o755, exist_ok=False)
timeout = int(sys.argv[1])
if not 1 <= timeout <= 600: raise ValueError('invalid timeout')
data = source.read_bytes()
if data[:6] != b'\x7fELF\x02\x01' or int.from_bytes(data[18:20], 'little') != 62: raise ValueError('only little-endian x86-64 ELF is supported')
target = pathlib.Path('/opt/profile-analysis/target.bin')
target.write_bytes(data); target.chmod(0o555)
work = pathlib.Path('/var/tmp/profile-analysis-work')
work.mkdir(mode=0o700); os.chown(work, 65534, 65534)
before = {'sha256': hashlib.sha256(data).hexdigest(), 'network': subprocess.check_output(['/usr/sbin/ip', '-brief', 'address'], text=True), 'routes': subprocess.check_output(['/usr/sbin/ip', 'route'], text=True)}
if any(line.split()[0] != 'lo' for line in before['network'].splitlines()) or before['routes'].strip(): raise RuntimeError('guest network isolation check failed')
cmd = ['/usr/bin/strace', '-f', '-qq', '-s', '256', '-o', str(out / 'strace.log'), '/usr/bin/setpriv', '--reuid=65534', '--regid=65534', '--clear-groups', '--no-new-privs', '/usr/bin/prlimit', '--as=1073741824', '--nproc=64', '--fsize=1048576', '--cpu=' + str(timeout), '--', str(target)]
start = time.monotonic(); reason = 'Exited'
with (out / 'stdout.txt').open('wb') as stdout, (out / 'stderr.txt').open('wb') as stderr:
    child = subprocess.Popen(cmd, cwd=work, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True, env={'PATH':'/usr/bin:/bin','HOME':str(work),'LANG':'C.UTF-8'})
    while child.poll() is None:
        if time.monotonic() - start >= timeout: reason = 'Timeout'
        if sum(p.stat().st_size for p in out.iterdir() if p.is_file()) > 12 * 1024 * 1024: reason = 'OutputLimit'
        if reason != 'Exited':
            os.killpg(child.pid, signal.SIGTERM)
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired: os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=3)
            break
        time.sleep(.1)
    # Descendants may detach from the traced process group; VM power-off is the final boundary.
    exitcode = child.returncode
files = []
for directory, dirs, names in os.walk(work, followlinks=False):
    dirs[:] = dirs[:100]
    for name in names:
        p = pathlib.Path(directory) / name
        try:
            info = p.lstat()
            item = {'path':str(p.relative_to(work)), 'bytes':info.st_size, 'symlink':stat.S_ISLNK(info.st_mode)}
            if stat.S_ISREG(info.st_mode) and info.st_size <= 1048576: item['sha256'] = hashlib.sha256(p.read_bytes()).hexdigest()
            files.append(item)
        except OSError: pass
        if len(files) >= 1000: break
    if len(files) >= 1000: break
report = {'schema':1, 'target':before, 'exitCode':exitcode, 'termination':reason, 'elapsedSeconds':round(time.monotonic()-start,3), 'createdFiles':files, 'uid':65534, 'limitations':['Offline, unprivileged x86-64 Linux execution only.', 'No command-line arguments or GUI interaction.', 'Guest observations are evidence, not proof of complete behavior.']}
(out / 'runtime.json').write_text(json.dumps(report, indent=2))
for p in out.iterdir():
    if p.stat().st_size > 12 * 1024 * 1024:
        with p.open('r+b') as f: f.truncate(12 * 1024 * 1024)
    p.chmod(0o644)
print(json.dumps({'status':'Complete', 'sha256':before['sha256']}))
'@
    $runnerLines = ($runner -replace "`r`n", "`n") -split "`n" | ForEach-Object { '      ' + $_ }
    $cloudConfig = @"
#cloud-config
users:
  - name: analysis-admin
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
chpasswd:
  expire: false
  users:
    - name: analysis-admin
      password: $guestPassword
      type: text
ssh_pwauth: false
package_update: true
packages: [virtualbox-guest-utils, strace, file, binutils, gdb, python3, iproute2, util-linux]
write_files:
  - path: /opt/profile-analysis/run.py
    permissions: '0755'
    content: |
$($runnerLines -join "`n")
runcmd:
  - [systemctl, disable, --now, ssh.service]
  - [systemctl, disable, --now, ssh.socket]
  - [systemctl, disable, systemd-networkd-wait-online.service]
  - [systemctl, enable, --now, virtualbox-guest-utils.service]
  - [sh, -c, 'command -v strace && command -v file && command -v readelf && command -v gdb && command -v VBoxService && cat /proc/sys/kernel/random/boot_id > /opt/profile-analysis/bootstrap-boot-id && touch /opt/profile-analysis/ready && touch /etc/cloud/cloud-init.disabled']
power_state:
  mode: reboot
  delay: now
  timeout: 30
"@
    [IO.File]::WriteAllText((Join-Path $seedDirectory 'user-data'), ($cloudConfig -replace "`r`n", "`n"))
    [IO.File]::WriteAllText((Join-Path $seedDirectory 'meta-data'), "instance-id: profile-analysis-$([guid]::NewGuid().ToString('N'))`nlocal-hostname: profile-analysis`n")
    if (-not ('ProfileAnalysisIsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class ProfileAnalysisIsoWriter {
    public static void Write(object source, string path) {
        var stream = (IStream)source;
        var count = Marshal.AllocHGlobal(4);
        try {
            using (var output = new FileStream(path, FileMode.CreateNew)) {
                var buffer = new byte[1048576];
                while (true) { stream.Read(buffer, buffer.Length, count); int n = Marshal.ReadInt32(count); if (n == 0) break; output.Write(buffer, 0, n); }
            }
        } finally { Marshal.FreeHGlobal(count); }
    }
}
'@
    }
    $iso = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $iso.FileSystemsToCreate = 3
    $iso.VolumeName = 'cidata'
    $iso.Root.AddTree($seedDirectory, $false)
    [ProfileAnalysisIsoWriter]::Write($iso.CreateResultImage().ImageStream, $seedIso)
    [IO.File]::WriteAllText($passwordFile, $guestPassword)
        Invoke-VBoxSetup -Arguments @('createvm', '--name', $VirtualMachineName, '--ostype', 'Ubuntu_64', '--basefolder', $storage, '--register') | Write-Verbose
        $created = $true
        $info = Invoke-VBoxSetup -Arguments @('showvminfo', $VirtualMachineName, '--machinereadable')
        if ($info -notmatch '(?m)^UUID="([^"]+)"$') { throw 'VirtualBox did not report the new VM UUID.' }
        $vmId = $Matches[1]
        $manifest = [ordered]@{ Schema = 'PowerShellProfile.AnalysisVm.v1'; Status = 'Provisioning'; VirtualMachineName = $VirtualMachineName; VirtualMachineId = $vmId; StoragePath = $storage; GuestOS = 'Ubuntu 24.04 LTS x86-64'; GuestUser = 'analysis-admin'; CredentialPath = $credentialPath; SnapshotName = 'Profile-Analysis-Clean'; SnapshotId = $null; SourceUrl = $source + $diskName; SourceSHA256 = $diskHash; CreatedUtc = [datetime]::UtcNow.ToString('o') }
        $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8
        Invoke-VBoxSetup -Arguments @('setextradata', $vmId, 'PowerShellProfile.AnalysisVm.Manifest', $manifestPath) | Out-Null
        $virtualDisk = Join-Path $storage 'analysis.vdi'
        Invoke-VBoxSetup -Arguments @('clonemedium', 'disk', $download, $virtualDisk, '--format', 'VDI') | Write-Verbose
        Invoke-VBoxSetup -Arguments @('modifymedium', 'disk', $virtualDisk, '--resize', '16384') | Write-Verbose
        Invoke-VBoxSetup -Arguments @('modifyvm', $vmId, '--memory', '2048', '--cpus', '1', '--firmware', 'efi', '--ioapic', 'on', '--graphicscontroller', 'vmsvga', '--vram', '16', '--nic1', 'nat', '--nictype1', '82540EM', '--clipboard-mode', 'disabled', '--clipboard-file-transfers', 'disabled', '--drag-and-drop', 'disabled', '--usb-ohci', 'off', '--usb-ehci', 'off', '--usb-xhci', 'off', '--audio-enabled', 'off', '--vrde', 'off', '--nested-hw-virt', 'off', '--boot1', 'disk', '--boot2', 'none', '--boot3', 'none', '--boot4', 'none') | Out-Null
        Invoke-VBoxSetup -Arguments @('storagectl', $vmId, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci') | Out-Null
        Invoke-VBoxSetup -Arguments @('storageattach', $vmId, '--storagectl', 'SATA', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', $virtualDisk) | Out-Null
        Invoke-VBoxSetup -Arguments @('storageattach', $vmId, '--storagectl', 'SATA', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', $seedIso) | Out-Null
        # One vCPU avoids the observed VirtualBox 7.2/NEM multi-vCPU boot stall.
        # This host file connection exists only during provisioning, never in the snapshot.
        Invoke-VBoxSetup -Arguments @('modifyvm', $vmId, '--uart1', '0x3F8', '4', '--uartmode1', 'file', (Join-Path $storage 'provisioning-console.log')) | Out-Null
        Invoke-VBoxSetup -Arguments @('startvm', $vmId, '--type', 'headless') | Write-Verbose
        $deadline = [datetime]::UtcNow.AddSeconds($ProvisioningTimeoutSeconds)
        do {
            Start-Sleep -Seconds 5
            # A reboot clears the first-boot PAM/session state of Ubuntu's Guest Additions.
            $readyCheck = 'import pathlib; p=pathlib.Path; assert p("/opt/profile-analysis/ready").exists(); assert p("/proc/sys/kernel/random/boot_id").read_text()!=p("/opt/profile-analysis/bootstrap-boot-id").read_text()'
            $null = & $vbox guestcontrol $vmId run --exe /usr/bin/python3 --username analysis-admin --passwordfile $passwordFile --timeout 5000 -- -c $readyCheck 2>&1
            $ready = $LASTEXITCODE -eq 0
        } while (-not $ready -and [datetime]::UtcNow -lt $deadline)
        if (-not $ready) { throw "Guest provisioning did not become ready within $ProvisioningTimeoutSeconds seconds. The new VM and manifest were retained for diagnosis." }
        $versions = Invoke-VBoxSetup -Arguments @('guestcontrol', $vmId, 'run', '--exe', '/usr/bin/dpkg-query', '--username', 'analysis-admin', '--passwordfile', $passwordFile, '--timeout', '10000', '--wait-stdout', '--', '-W', 'virtualbox-guest-utils', 'strace', 'file', 'binutils', 'gdb', 'python3')
        [IO.File]::WriteAllText((Join-Path $storage 'guest-tool-versions.txt'), $versions)
        Invoke-VBoxSetup -Arguments @('guestcontrol', $vmId, 'run', '--exe', '/usr/bin/sudo', '--username', 'analysis-admin', '--passwordfile', $passwordFile, '--timeout', '10000', '--', '/usr/bin/sync') | Out-Null
        Invoke-VBoxSetup -Arguments @('controlvm', $vmId, 'acpipowerbutton') | Out-Null
        $stopDeadline = [datetime]::UtcNow.AddSeconds(60)
        do { Start-Sleep -Seconds 2; $info = Invoke-VBoxSetup -Arguments @('showvminfo', $vmId, '--machinereadable') } while ($info -notmatch '(?m)^VMState="poweroff"$' -and [datetime]::UtcNow -lt $stopDeadline)
        if ($info -notmatch '(?m)^VMState="poweroff"$') { Invoke-VBoxSetup -Arguments @('controlvm', $vmId, 'poweroff') | Out-Null }
        $isolationArgs = @('modifyvm', $vmId, '--clipboard-mode', 'disabled', '--clipboard-file-transfers', 'disabled', '--drag-and-drop', 'disabled', '--usb-ohci', 'off', '--usb-ehci', 'off', '--usb-xhci', 'off', '--audio-enabled', 'off', '--vrde', 'off')
        foreach ($i in 1..8) { $isolationArgs += @("--nic$i", 'none') }
        foreach ($i in 1..4) { $isolationArgs += @("--uart$i", 'off') }
        Invoke-VBoxSetup -Arguments $isolationArgs | Out-Null
        Invoke-VBoxSetup -Arguments @('storageattach', $vmId, '--storagectl', 'SATA', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', 'none') | Out-Null
        Invoke-VBoxSetup -Arguments @('snapshot', $vmId, 'take', $manifest.SnapshotName, '--description', 'Clean provisioned Ubuntu; all NICs and host integrations disabled; no targets executed.') | Write-Verbose
        $snapshots = Invoke-VBoxSetup -Arguments @('snapshot', $vmId, 'list', '--machinereadable')
        if ($snapshots -notmatch '(?m)^CurrentSnapshotUUID="([^"]+)"$') { throw 'Could not verify the clean snapshot UUID.' }
        $manifest.SnapshotId = $Matches[1]
        $manifest.Status = 'Ready'
        $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8
        [pscustomobject]$manifest
    }
    finally {
        if ($created) {
            $state = & $vbox showvminfo $VirtualMachineName --machinereadable 2>&1
            if ($state -match '^VMState="running"$') { $null = & $vbox controlvm $VirtualMachineName poweroff 2>&1 }
            # Provisioning failure also leaves this newly created VM disconnected.
            $null = & $vbox modifyvm $VirtualMachineName --nic1 none --uart1 off 2>&1
            $null = & $vbox storageattach $VirtualMachineName --storagectl SATA --port 1 --device 0 --type dvddrive --medium none 2>&1
            $null = & $vbox closemedium dvd $seedIso 2>&1
        }
        foreach ($sensitivePath in @($passwordFile, (Join-Path $seedDirectory 'user-data'))) {
            if (Test-Path -LiteralPath $sensitivePath -PathType Leaf) { Remove-Item -LiteralPath $sensitivePath -Force }
        }
        if (Test-Path -LiteralPath $seedIso -PathType Leaf) { Remove-Item -LiteralPath $seedIso -Force }
        if ($null -ne $securePassword) { $securePassword.Dispose() }
        $guestPassword = $null
    }
}
