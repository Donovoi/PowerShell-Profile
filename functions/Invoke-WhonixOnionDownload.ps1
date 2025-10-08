function Invoke-WhonixOnionDownload {
    <#
.SYNOPSIS
  Provision Whonix (Gateway + Workstation), then download a target URL *from inside the Workstation over Tor* and copy it back to the host.

.DESCRIPTION
  - Finds the latest Whonix OVA & .sha512sums on whonix.org, caches them, verifies SHA-512.
  - Imports the unified OVA:
      * VirtualBox: dual-VSYS import with per-VSYS EULA, unique basefolders, explicit disk names,
        and enforced NIC topology (GW: NAT + intnet; WS: intnet) so WS routes via GW → Tor.
      * VMware: ovftool OVA→VMX (argument array, --lax). Requires open-vm-tools in the Workstation for guest exec/copy.
  - Boots Gateway then Workstation, waits for guest tools on WS.
  - Runs a Tor-aware fetch inside WS (prefers scurl → torsocks curl → curl).
  - Copies the downloaded file back to OutputDir.
  - Powers off VMs unless -KeepRunning is set.

.PARAMETER Url
  The URL to fetch *inside* Whonix-Workstation (supports .onion or clearnet).

.PARAMETER OutputDir
  Local directory (host) for result file and default VM folders.

.PARAMETER Backend
  'VirtualBox' or 'VMware'. Default: 'VMware'.

.PARAMETER CacheDir
  Cache directory for OVA and artifacts. Default: C:\ProgramData\WhonixCache

.PARAMETER GuestCredential
  Linux credentials for guest operations (e.g., 'user' / your password).

.PARAMETER KeepRunning
  Leave VMs running after completion.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Url,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDir,
        [ValidateSet('VMware', 'VirtualBox')][string]$Backend = 'VMware',
        [string]$CacheDir = 'C:\ProgramData\WhonixCache',
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$GuestCredential,
        [switch]$KeepRunning
    )

    begin {
        $ErrorActionPreference = 'Stop'
        if (-not (Test-Path $OutputDir)) {
            New-Item -ItemType Directory -Path $OutputDir | Out-Null 
        }
        if (-not (Test-Path $CacheDir)) {
            New-Item -ItemType Directory -Path $CacheDir | Out-Null 
        }
        function V([string]$m) {
            Write-Verbose $m 
        }

        function Get-Tool {
            param([ValidateSet('VBoxManage', 'Ovftool', 'Vmrun')]$Name)
            switch ($Name) {
                'VBoxManage' {
                    $Candidate = @(
                        Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe',
                        "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
                        "$env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe"
                    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
                    if (-not $Candidate) {
                        throw 'VBoxManage.exe not found (install VirtualBox).' 
                    }
                    $Candidate
                }
                'Ovftool' {
                    $Candidate = @(
                        "$env:ProgramFiles(x86)\VMware\VMware Workstation\OVFTool\ovftool.exe",
                        "$env:ProgramFiles\VMware\VMware Workstation\OVFTool\ovftool.exe"
                    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
                    if (-not $Candidate) {
                        throw 'ovftool.exe not found (install VMware Workstation / OVF Tool).' 
                    }
                    $Candidate
                }
                'Vmrun' {
                    $Candidate = @(
                        "$env:ProgramFiles(x86)\VMware\VMware Workstation\vmrun.exe",
                        "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe"
                    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
                    if (-not $Candidate) {
                        throw 'vmrun.exe not found (install VMware Workstation).' 
                    }
                    $Candidate
                }
            }
        }

        function Invoke-Download {
            param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutFile)
            V "[*] Downloading: $Uri"
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -MaximumRedirection 10 | Out-Null
            if (-not (Test-Path $OutFile)) {
                throw "Download failed: $Uri" 
            }
            $OutFile
        }

        function Resolve-WhonixOva {
            $Pages = @('https://www.whonix.org/wiki/VirtualBox/OVA', 'https://www.whonix.org/wiki/Downloads')
            $OvaUrl = $null; $ShaUrl = $null
            foreach ($p in $Pages) {
                try {
                    $Tmp = Join-Path $CacheDir ('index_' + [IO.Path]::GetFileNameWithoutExtension([Uri]$p) + '.html')
                    Invoke-Download -Uri $p -OutFile $Tmp | Out-Null
                    $Html = Get-Content -LiteralPath $Tmp -Raw
                    if (-not $OvaUrl) {
                        $OvaUrl = [regex]::Match($Html, 'https?://\S+?Whonix-(?:Xfce|CLI)-\d[\w\.\-]*\.ova').Value 
                    }
                    if (-not $ShaUrl) {
                        $ShaUrl = [regex]::Match($Html, 'https?://\S+?Whonix-(?:Xfce|CLI)-\d[\w\.\-]*\.ova\.sha512sums').Value 
                    }
                    if ($OvaUrl -and $ShaUrl) {
                        break 
                    }
                }
                catch {
                }
            }
            if (-not $OvaUrl -or -not $ShaUrl) {
                throw 'Failed to locate Whonix OVA + .sha512sums.' 
            }
            [pscustomobject]@{ OvaUrl = $OvaUrl; ShaUrl = $ShaUrl }
        }

        function Test-FileSha512 {
            param([string]$File, [string]$ShaFile)
            V '[*] Verifying SHA-512…'
            $Have = (Get-FileHash -Algorithm SHA512 -LiteralPath $File).Hash.ToLowerInvariant()
            $Name = Split-Path -Leaf $File
            $Expected = $null
            foreach ($ln in (Get-Content -LiteralPath $ShaFile)) {
                if ($ln -match '^[0-9a-fA-F]{128}\s+(\*|\s)?(.+)$') {
                    $h = $ln.Split()[0]
                    $f = ($ln -replace '^[0-9a-fA-F]{128}\s+(\*|\s)?', '').Trim()
                    if ($f -eq $Name) {
                        $Expected = $h; break 
                    }
                }
                elseif ($ln -match '^SHA512\s*\((.+)\)\s*=\s*([0-9a-fA-F]{128})') {
                    if ($matches[1] -eq $Name) {
                        $Expected = $matches[2]; break 
                    }
                }
            }
            if (-not $Expected) {
                throw "No matching SHA512 line for $Name" 
            }
            if ($Have -ne $Expected.ToLowerInvariant()) {
                throw "SHA-512 mismatch for $Name" 
            }
            V '[OK] Checksum verified.'
        }

        function New-UniqueName([string]$Base) {
            $Existing = @()
            try {
                $VBox = Get-Tool 'VBoxManage'; $Existing = (& $VBox list vms 2>$null) -replace '^"(.+?)".*$', '$1' 
            }
            catch {
            }
            $n = $Base; $i = 1; while ($Existing -contains $n) {
                $n = "$Base-$i"; $i++ 
            }; $n
        }

        function Import-VBoxWhonix {
            param([string]$Ova, [string]$DestinationRoot)
            $VBox = Get-Tool 'VBoxManage'
            $GwName = New-UniqueName 'Whonix-Gateway'
            $WsName = New-UniqueName 'Whonix-Workstation'
            $GwBase = Join-Path $DestinationRoot ('GW-' + [guid]::NewGuid().ToString('N'))
            $WsBase = Join-Path $DestinationRoot ('WS-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $GwBase, $WsBase | Out-Null
            $GwDisk = Join-Path $GwBase 'gateway-disk1.vmdk'
            $WsDisk = Join-Path $WsBase 'workstation-disk1.vmdk'
            V '[*] Importing Whonix into VirtualBox…'
            & $VBox import "$Ova" `
                --vsys 0 --eula accept --vmname "$GwName" --basefolder "$GwBase" --unit 18 --disk "$GwDisk" `
                --vsys 1 --eula accept --vmname "$WsName" --basefolder "$WsBase" --unit 16 --disk "$WsDisk"
            # Enforce Whonix NIC topology
            & $VBox modifyvm "$GwName" --nic1 nat --cableconnected1 on
            & $VBox modifyvm "$GwName" --nic2 intnet --intnet2 'Whonix' --cableconnected2 on
            & $VBox modifyvm "$WsName" --nic1 intnet --intnet1 'Whonix' --cableconnected1 on
            [pscustomobject]@{ Gateway = $GwName; Workstation = $WsName }
        }

        function Start-VBoxVM([string]$Name) {
            (& (Get-Tool 'VBoxManage') startvm "$Name" --type headless) | Out-Null 
        }
        function Wait-VBoxGuestAdditions([string]$Name, [int]$TimeoutSec = 900) {
            & (Get-Tool 'VBoxManage') guestproperty wait "$Name" '/VirtualBox/GuestAdd/Version' --timeout ($TimeoutSec * 1000) | Out-Null
        }
        function Invoke-VBoxGuest {
            param(
                [string]$Name,
                [System.Management.Automation.PSCredential]$Credential,
                [string]$CommandLine,
                [int]$TimeoutSec = 3600
            )
            $VBox = Get-Tool 'VBoxManage'
            $User = $Credential.UserName
            $Plain = $Credential.GetNetworkCredential().Password
            & $VBox guestcontrol "$Name" run --exe '/bin/bash' `
                --username "$User" --password "$Plain" --timeout ($TimeoutSec * 1000) --wait-exit --wait-stdout --wait-stderr -- -lc "$CommandLine"
        }
        function Copy-VBoxGuestItemFrom {
            param(
                [string]$Name,
                [System.Management.Automation.PSCredential]$Credential,
                [string]$GuestPath,
                [string]$HostPath
            )
            $VBox = Get-Tool 'VBoxManage'
            $User = $Credential.UserName
            $Plain = $Credential.GetNetworkCredential().Password
            $HostDir = Split-Path -Parent $HostPath
            if (-not (Test-Path $HostDir)) {
                New-Item -ItemType Directory -Path $HostDir | Out-Null 
            }
            & $VBox guestcontrol "$Name" copyfrom --username "$User" --password "$Plain" -- "$GuestPath" "$HostPath"
        }
        function Stop-VBoxVM([string]$Name) {
            (& (Get-Tool 'VBoxManage') controlvm "$Name" acpipowerbutton) | Out-Null 
        }

        function Import-VMwareWhonix([string]$Ova, [string]$DestinationDir) {
            $Ovftool = Get-Tool 'Ovftool'
            if (-not (Test-Path $DestinationDir)) {
                New-Item -ItemType Directory -Path $DestinationDir | Out-Null 
            }
            $Arguments = @('--acceptAllEulas', '--lax', '--skipManifestCheck', '--allowAllExtraConfig', $Ova, $DestinationDir)
            V '[*] ovftool: OVA → VMX (relaxed)…'
            $Proc = Start-Process -FilePath $Ovftool -ArgumentList $Arguments -NoNewWindow -PassThru -Wait
            if ($Proc.ExitCode -ne 0) {
                throw "ovftool failed with exit code $($Proc.ExitCode)" 
            }
            # Identify Gateway/Workstation VMX paths
            $VmxItems = Get-ChildItem -LiteralPath $DestinationDir -Recurse -Filter *.vmx
            $WsVmx = ($VmxItems | Where-Object { $_.Name -match 'Workstation' } | Select-Object -First 1).FullName
            $GwVmx = ($VmxItems | Where-Object { $_.Name -match 'Gateway' } | Select-Object -First 1).FullName
            if (-not $WsVmx -or -not $GwVmx) {
                $Dirs = $VmxItems | ForEach-Object { [pscustomobject]@{ Vmx = $_.FullName; Size = (Get-ChildItem $_.Directory -Recurse -File | Measure-Object Length -Sum).Sum } }
                $Top2 = $Dirs | Sort-Object Size -Descending | Select-Object -First 2
                if ($Top2.Count -lt 2) {
                    throw 'Could not identify both Gateway and Workstation VMX files.' 
                }
                $WsVmx = $Top2[0].Vmx; $GwVmx = $Top2[1].Vmx
            }
            [pscustomobject]@{ Gateway = $GwVmx; Workstation = $WsVmx }
        }
        function Start-VMwareVM([string]$Vmx) {
            (& (Get-Tool 'Vmrun') -T ws start "$Vmx" nogui) | Out-Null 
        }
        function Test-VMwareGuestReady {
            param(
                [string]$Vmx,
                [System.Management.Automation.PSCredential]$Credential,
                [int]$TimeoutSec = 900
            )
            $Vmrun = Get-Tool 'Vmrun'
            $User = $Credential.UserName
            $Plain = $Credential.GetNetworkCredential().Password
            $Sw = [Diagnostics.Stopwatch]::StartNew()
            do {
                try {
                    $Proc = Start-Process -FilePath $Vmrun -ArgumentList @('-T', 'ws', '-gu', $User, '-gp', $Plain, 'runProgramInGuest', "$Vmx", '/bin/true') -NoNewWindow -PassThru -Wait
                    if ($Proc.ExitCode -eq 0) {
                        return $true 
                    }
                }
                catch {
                }
                Start-Sleep 5
            }while ($Sw.Elapsed.TotalSeconds -lt $TimeoutSec)
            return $false
        }
        function Invoke-VMwareGuest {
            param(
                [string]$Vmx,
                [System.Management.Automation.PSCredential]$Credential,
                [string]$Bash,
                [int]$TimeoutSec = 3600
            )
            $Vmrun = Get-Tool 'Vmrun'
            $User = $Credential.UserName
            $Plain = $Credential.GetNetworkCredential().Password
            $Arguments = @('-T', 'ws', '-gu', $User, '-gp', $Plain, 'runProgramInGuest', "$Vmx", '/bin/bash', '-lc', $Bash)
            $Proc = Start-Process -FilePath $Vmrun -ArgumentList $Arguments -NoNewWindow -PassThru -Wait
            if ($Proc.ExitCode -ne 0) {
                throw "vmrun runProgramInGuest failed with exit $($Proc.ExitCode)" 
            }
        }
        function Copy-VMwareGuestItemFrom {
            param(
                [string]$Vmx,
                [System.Management.Automation.PSCredential]$Credential,
                [string]$GuestPath,
                [string]$HostPath
            )
            $Vmrun = Get-Tool 'Vmrun'
            $User = $Credential.UserName
            $Plain = $Credential.GetNetworkCredential().Password
            $HostDir = Split-Path -Parent $HostPath
            if (-not (Test-Path $HostDir)) {
                New-Item -ItemType Directory -Path $HostDir | Out-Null 
            }
            $Arguments = @('-T', 'ws', '-gu', $User, '-gp', $Plain, 'CopyFileFromGuestToHost', "$Vmx", $GuestPath, $HostPath)
            $Proc = Start-Process -FilePath $Vmrun -ArgumentList $Arguments -NoNewWindow -PassThru -Wait
            if ($Proc.ExitCode -ne 0) {
                throw "vmrun CopyFileFromGuestToHost failed with exit $($Proc.ExitCode)" 
            }
        }
        function Stop-VMwareVM([string]$Vmx) {
            (& (Get-Tool 'Vmrun') -T ws stop "$Vmx" soft) | Out-Null 
        }

        function New-GuestFetchScript([string]$Target, [string]$OutDir, [string]$OutFile) {
            @"
set -euo pipefail
mkdir -p '$OutDir'
if command -v scurl >/dev/null 2>&1; then
  scurl -fsSL '$Target' -o '$OutFile'
elif command -v torsocks >/dev/null 2>&1; then
  torsocks curl -fsSL '$Target' -o '$OutFile'
else
  curl -fsSL '$Target' -o '$OutFile'
fi
"@
        }
    }

    process {
        # 1) Resolve/cached OVA and verify
        V '[*] Locating latest Whonix OVA…'
        $Links = Resolve-WhonixOva
        $OvaPath = Join-Path $CacheDir (Split-Path -Leaf $Links.OvaUrl)
        $ShaPath = Join-Path $CacheDir (Split-Path -Leaf $Links.ShaUrl)
        if (-not (Test-Path $OvaPath)) {
            Invoke-Download -Uri $Links.OvaUrl -OutFile $OvaPath | Out-Null 
        }
        else {
            V "[OK] Using cached OVA: $OvaPath" 
        }
        Invoke-Download -Uri $Links.ShaUrl -OutFile $ShaPath | Out-Null
        Test-FileSha512 -File $OvaPath -ShaFile $ShaPath

        $User = $GuestCredential.UserName
        $GuestHome = "/home/$User"
        $GuestOutDir = "$GuestHome/Downloads/whonix-fetch"
        $FileName = try {
            [IO.Path]::GetFileName([Uri]$Url) 
        }
        catch {
            '' 
        }
        if ([string]::IsNullOrWhiteSpace($FileName)) {
            $FileName = 'download.bin' 
        }
        $GuestFile = "$GuestOutDir/$FileName"
        $HostOutPath = Join-Path $OutputDir $FileName

        if ($Backend -eq 'VirtualBox') {
            $VBoxDest = Join-Path $OutputDir 'VirtualBox-Whonix'
            $VmInfo = Import-VBoxWhonix -Ova $OvaPath -DestinationRoot $VBoxDest
            Start-VBoxVM $VmInfo.Gateway
            Start-VBoxVM $VmInfo.Workstation
            V '[*] Waiting for Guest Additions on Workstation…'
            Wait-VBoxGuestAdditions $VmInfo.Workstation 900
            $FetchScript = New-GuestFetchScript $Url $GuestOutDir $GuestFile
            $Command = @"
cat >/tmp/fetch.sh <<'EOF'
$FetchScript
EOF
chmod +x /tmp/fetch.sh
bash -lc '/tmp/fetch.sh'
"@
            Invoke-VBoxGuest -Name $VmInfo.Workstation -Credential $GuestCredential -CommandLine $Command -TimeoutSec 3600
            Copy-VBoxGuestItemFrom -Name $VmInfo.Workstation -Credential $GuestCredential -GuestPath $GuestFile -HostPath $HostOutPath
            if (-not $KeepRunning) {
                Stop-VBoxVM $VmInfo.Workstation; Stop-VBoxVM $VmInfo.Gateway 
            }
            [pscustomobject]@{ Backend = 'VirtualBox'; Gateway = $VmInfo.Gateway; Workstation = $VmInfo.Workstation; Output = $HostOutPath } | Write-Output
            return
        }

        # VMware path
        $VMwareDest = Join-Path $OutputDir 'VMware-Whonix'
        $VmPaths = Import-VMwareWhonix -Ova $OvaPath -DestinationDir $VMwareDest
        Start-VMwareVM $VmPaths.Gateway
        Start-VMwareVM $VmPaths.Workstation
        V '[*] Checking for VMware Tools in Workstation…'
        if (-not (Test-VMwareGuestReady -Vmx $VmPaths.Workstation -Credential $GuestCredential -TimeoutSec 900)) {
            if (-not $KeepRunning) {
                Stop-VMwareVM $VmPaths.Workstation; Stop-VMwareVM $VmPaths.Gateway 
            }
            throw 'Workstation does not have VMware Tools (open-vm-tools). Install tools or use -Backend VirtualBox.'
        }
        $FetchScript = New-GuestFetchScript $Url $GuestOutDir $GuestFile
        $Bash = @"
set -euo pipefail
cat >/tmp/fetch.sh <<'EOF'
$FetchScript
EOF
chmod +x /tmp/fetch.sh
bash -lc '/tmp/fetch.sh'
"@
        Invoke-VMwareGuest -Vmx $VmPaths.Workstation -Credential $GuestCredential -Bash $Bash -TimeoutSec 3600
        Copy-VMwareGuestItemFrom -Vmx $VmPaths.Workstation -Credential $GuestCredential -GuestPath $GuestFile -HostPath $HostOutPath
        if (-not $KeepRunning) {
            Stop-VMwareVM $VmPaths.Workstation; Stop-VMwareVM $VmPaths.Gateway 
        }
        [pscustomobject]@{ Backend = 'VMware'; Gateway = $VmPaths.Gateway; Workstation = $VmPaths.Workstation; Output = $HostOutPath } | Write-Output
    }
}
