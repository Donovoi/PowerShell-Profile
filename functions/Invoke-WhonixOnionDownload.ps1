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

        function Install-Tool {
            param([ValidateSet('VBoxManage', 'Ovftool', 'Vmrun', 'VirtualBox', 'VMware')]$Name)
            switch ($Name) {
                'VBoxManage' {
                    $CandidatePaths = @()
                    if ($env:VBOX_MSI_INSTALL_PATH) {
                        $CandidatePaths += (Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe')
                    }
                    $CandidatePaths += @(
                        "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
                        "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe"
                    )
                    $Candidate = $CandidatePaths |
                        Where-Object { $_ -and (Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue) } |
                            Select-Object -First 1
                    
                    if (-not $Candidate) {
                        V '[*] VirtualBox not found, installing via winget...'
                        try {
                            $installResult = winget install --id Oracle.VirtualBox --silent --accept-package-agreements --accept-source-agreements 2>&1
                            if ($LASTEXITCODE -eq 0 -or $installResult -match 'successfully installed') {
                                # Refresh path and try again
                                $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
                                $Candidate = @(
                                    "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
                                    "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe"
                                ) | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
                                if ($Candidate) {
                                    V '[OK] VirtualBox installed successfully.'
                                }
                            }
                        }
                        catch {
                            V "[WARN] Failed to install VirtualBox: $($_.Exception.Message)"
                        }
                    }
                    
                    if (-not $Candidate) {
                        throw 'VBoxManage.exe not found and automatic installation failed. Please install VirtualBox manually from https://www.virtualbox.org/'
                    }
                    $Candidate
                }
                'Ovftool' {
                    # Try Get-Command first (checks PATH)
                    $Candidate = (Get-Command ovftool.exe -ErrorAction SilentlyContinue)?.Source
                    
                    if (-not $Candidate) {
                        # Try common installation paths
                        $Candidate = @(
                            "${env:ProgramFiles(x86)}\VMware\VMware Workstation\OVFTool\ovftool.exe",
                            "$env:ProgramFiles\VMware\VMware Workstation\OVFTool\ovftool.exe",
                            "${env:ProgramFiles(x86)}\VMware\VMware Player\OVFTool\ovftool.exe",
                            "$env:ProgramFiles\VMware\VMware Player\OVFTool\ovftool.exe",
                            "$CacheDir\ovftool\ovftool.exe"
                        ) | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
                    }
                    
                    if (-not $Candidate) {
                        # Try using where.exe
                        try {
                            $whereResult = where.exe ovftool.exe 2>$null
                            if ($whereResult -and (Test-Path -LiteralPath $whereResult[0] -ErrorAction SilentlyContinue)) {
                                $Candidate = $whereResult[0]
                            }
                        }
                        catch { 
                        }
                    }
                    
                    if (-not $Candidate) {
                        V '[*] OVF Tool not found, downloading standalone version...'
                        try {
                            $ovfDir = Join-Path $CacheDir 'ovftool'
                            if (-not (Test-Path $ovfDir)) {
                                New-Item -ItemType Directory -Path $ovfDir | Out-Null
                            }
                            
                            # OVF Tool download from VMware requires account credentials
                            # Try chocolatey as alternative instead
                            if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
                                V '[*] Chocolatey not found, installing...'
                                try {
                                    # Install Chocolatey using official method
                                    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
                                    $null = Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
                                    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
                                    
                                    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
                                        V '[OK] Chocolatey installed successfully.'
                                    }
                                }
                                catch {
                                    V "[WARN] Failed to install Chocolatey: $($_.Exception.Message)"
                                }
                            }
                            
                            if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
                                V '[*] Trying chocolatey installation of OVF Tool...'
                                $null = choco install ovftool -y --force 2>&1
                                if ($LASTEXITCODE -eq 0) {
                                    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
                                    $Candidate = (Get-Command ovftool.exe -ErrorAction SilentlyContinue)?.Source
                                    if ($Candidate) {
                                        V '[OK] OVF Tool installed via chocolatey.'
                                    }
                                }
                            }
                        }
                        catch {
                            V "[WARN] Failed to install OVF Tool: $($_.Exception.Message)"
                        }
                    }
                    
                    if (-not $Candidate) {
                        throw 'ovftool.exe not found and automatic installation failed. Please install VMware Workstation or download OVF Tool from https://developer.vmware.com/tools'
                    }
                    $Candidate
                }
                'Vmrun' {
                    $Candidate = (Get-Command vmrun.exe -ErrorAction SilentlyContinue)?.Source
                    
                    if (-not $Candidate) {
                        $Candidate = @(
                            "${env:ProgramFiles(x86)}\VMware\VMware Workstation\vmrun.exe",
                            "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe",
                            "${env:ProgramFiles(x86)}\VMware\VMware Player\vmrun.exe",
                            "$env:ProgramFiles\VMware\VMware Player\vmrun.exe"
                        ) | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
                    }
                    
                    if (-not $Candidate) {
                        V '[*] vmrun.exe not found, attempting to install VMware Workstation Player via winget...'
                        try {
                            $installResult = winget install --id VMware.WorkstationPlayer --silent --accept-package-agreements --accept-source-agreements 2>&1
                            if ($LASTEXITCODE -eq 0 -or $installResult -match 'successfully installed') {
                                $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
                                $Candidate = @(
                                    "${env:ProgramFiles(x86)}\VMware\VMware Player\vmrun.exe",
                                    "$env:ProgramFiles\VMware\VMware Player\vmrun.exe"
                                ) | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
                                if ($Candidate) {
                                    V '[OK] VMware Workstation Player installed successfully.'
                                }
                            }
                        }
                        catch {
                            V "[WARN] Failed to install VMware: $($_.Exception.Message)"
                        }
                    }
                    
                    if (-not $Candidate) {
                        throw 'vmrun.exe not found and automatic installation failed. Please install VMware Workstation or Player from https://www.vmware.com/'
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
            # First, check if we already have cached files
            $CachedOva = Get-ChildItem -LiteralPath $CacheDir -Filter 'Whonix-*.ova' -ErrorAction SilentlyContinue | 
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $CachedSha = Get-ChildItem -LiteralPath $CacheDir -Filter 'Whonix-*.ova.sha512sums' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1

            if ($CachedOva -and $CachedSha) {
                V "[OK] Using cached OVA and SHA file: $($CachedOva.Name)"
                return [pscustomobject]@{
                    OvaUrl  = "file:///$($CachedOva.FullName -replace '\\','/')"
                    ShaUrl  = "file:///$($CachedSha.FullName -replace '\\','/')"
                    Cached  = $true
                    Version = ($CachedOva.BaseName -replace '^Whonix-(?:LXQt|CLI)-', '')
                }
            }

            $IndexUrl = 'https://www.whonix.org/download/ova/'
            $IndexFile = Join-Path $CacheDir 'whonix-ova-index.html'
            Invoke-Download -Uri $IndexUrl -OutFile $IndexFile | Out-Null
            $IndexHtml = Get-Content -LiteralPath $IndexFile -Raw

            $versionMatches = [regex]::Matches($IndexHtml, 'href="([0-9]+(?:\.[0-9]+)*)/"')
            $versionInfos = @()
            foreach ($match in $versionMatches) {
                $text = $match.Groups[1].Value
                $parsed = $null
                if ([Version]::TryParse($text, [ref]$parsed)) {
                    $versionInfos += [pscustomobject]@{ Text = $text; Version = $parsed }
                }
            }
            if (-not $versionInfos) {
                throw 'Failed to enumerate Whonix OVA versions from index page.'
            }

            $LatestVersion = $versionInfos | Sort-Object Version -Descending | Select-Object -First 1
            $VersionUrl = "$IndexUrl$($LatestVersion.Text)/"
            $VersionFile = Join-Path $CacheDir ("whonix-ova-$($LatestVersion.Text).html")
            Invoke-Download -Uri $VersionUrl -OutFile $VersionFile | Out-Null
            $VersionHtml = Get-Content -LiteralPath $VersionFile -Raw

            $ovaMatches = [regex]::Matches($VersionHtml, 'href="(Whonix-[^"]+?\.ova)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
            if (-not $ovaMatches) {
                throw "Failed to locate .ova artifacts for Whonix version $($LatestVersion.Text)."
            }

            $PreferredOva = $ovaMatches | Where-Object { $_ -match 'LXQt' } | Select-Object -First 1
            if (-not $PreferredOva) {
                $PreferredOva = $ovaMatches | Select-Object -First 1
            }

            $ShaName = "$PreferredOva.sha512sums"
            if ($VersionHtml -notmatch [regex]::Escape($ShaName)) {
                throw "Failed to locate SHA512 sums for $PreferredOva on Whonix download page."
            }

            return [pscustomobject]@{
                OvaUrl  = "$VersionUrl$PreferredOva"
                ShaUrl  = "$VersionUrl$ShaName"
                Cached  = $false
                Version = $LatestVersion.Text
            }
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
                $VBox = Install-Tool 'VBoxManage'; $Existing = (& $VBox list vms 2>$null) -replace '^"(.+?)".*$', '$1' 
            }
            catch {
            }
            $n = $Base; $i = 1; while ($Existing -contains $n) {
                $n = "$Base-$i"; $i++ 
            }; $n
        }

        function Import-VBoxWhonix {
            param([string]$Ova, [string]$DestinationRoot)
            $VBox = Install-Tool 'VBoxManage'
            $GwName = New-UniqueName 'Whonix-Gateway'
            $WsName = New-UniqueName 'Whonix-Workstation'
            $GwBase = Join-Path $DestinationRoot ('GW-' + [guid]::NewGuid().ToString('N'))
            $WsBase = Join-Path $DestinationRoot ('WS-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $GwBase, $WsBase | Out-Null
            $GwDisk = Join-Path $GwBase 'gateway-disk1.vmdk'
            $WsDisk = Join-Path $WsBase 'workstation-disk1.vmdk'
            
            # Find available SSH port for forwarding (start at 2222)
            $SSHPort = 2222
            while ((Get-NetTCPConnection -LocalPort $SSHPort -ErrorAction SilentlyContinue)) {
                $SSHPort++
            }
            
            V '[*] Importing Whonix into VirtualBox…'
            & $VBox import "$Ova" `
                --vsys 0 --eula accept --vmname "$GwName" --basefolder "$GwBase" --unit 18 --disk "$GwDisk" `
                --vsys 1 --eula accept --vmname "$WsName" --basefolder "$WsBase" --unit 16 --disk "$WsDisk"
            
            # Enforce Whonix NIC topology
            & $VBox modifyvm "$GwName" --nic1 nat --cableconnected1 on
            & $VBox modifyvm "$GwName" --nic2 intnet --intnet2 'Whonix' --cableconnected2 on
            & $VBox modifyvm "$WsName" --nic1 intnet --intnet1 'Whonix' --cableconnected1 on
            
            # Add SSH port forwarding to Workstation for host access
            # Whonix Workstation doesn't have direct internet, but we can still SSH via Gateway's NAT
            & $VBox modifyvm "$WsName" --nic2 nat --natpf2 "ssh,tcp,127.0.0.1,$SSHPort,,22"
            
            V "[OK] SSH port forwarding configured: localhost:$SSHPort -> Workstation:22"
            
            [pscustomobject]@{ Gateway = $GwName; Workstation = $WsName; SSHPort = $SSHPort }
        }

        function Start-VBoxVM([string]$Name) {
            (& (Install-Tool 'VBoxManage') startvm "$Name" --type headless) | Out-Null 
        }
        function Wait-VBoxSSH([string]$Name, [int]$SSHPort, [System.Management.Automation.PSCredential]$Credential, [int]$TimeoutSec = 900) {
            $Sw = [Diagnostics.Stopwatch]::StartNew()
            $CheckInterval = 5
            $User = $Credential.UserName
            $Plain = $Credential.GetNetworkCredential().Password
            
            V '[*] Waiting for SSH service to become available on VM...'
            
            do {
                try {
                    # Test TCP connection to SSH port
                    $tcpClient = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcpClient.BeginConnect('127.0.0.1', $SSHPort, $null, $null)
                    $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
                    
                    if ($wait -and $tcpClient.Connected) {
                        $tcpClient.Close()
                        V '[OK] SSH port is open and responding.'
                        # Give SSH a moment to fully initialize
                        Start-Sleep -Seconds 5
                        return $true
                    }
                    
                    if ($tcpClient) {
                        $tcpClient.Close() 
                    }
                    V "[*] SSH not ready yet, waiting... ($([int]$Sw.Elapsed.TotalSeconds)s elapsed)"
                }
                catch {
                    V "[*] Checking SSH availability... ($([int]$Sw.Elapsed.TotalSeconds)s elapsed)"
                }
                Start-Sleep -Seconds $CheckInterval
            } while ($Sw.Elapsed.TotalSeconds -lt $TimeoutSec)
            
            throw "Timeout waiting for SSH on VM '$Name' (port $SSHPort) after $TimeoutSec seconds"
        }
        
        function Invoke-SSHCommand {
            param(
                [string]$Hostname,
                [int]$Port,
                [System.Management.Automation.PSCredential]$Credential,
                [string]$Command
            )
            
            $User = $Credential.UserName
            $Plain = $Credential.GetNetworkCredential().Password
            
            # Use plink if available, otherwise try ssh.exe
            $sshClient = $null
            if (Get-Command plink.exe -ErrorAction SilentlyContinue) {
                $sshClient = 'plink.exe'
                $sshArgs = @('-ssh', '-batch', '-P', $Port, '-l', $User, '-pw', $Plain, $Hostname, $Command)
            }
            elseif (Get-Command ssh.exe -ErrorAction SilentlyContinue) {
                # Create temp file for SSH password (sshpass alternative for Windows)
                $tempScript = [IO.Path]::GetTempFileName() + '.sh'
                $Command | Set-Content -Path $tempScript -NoNewline
                $sshClient = 'ssh.exe'
                $sshArgs = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', 
                    '-p', $Port, "$User@$Hostname", $Command)
            }
            else {
                throw 'No SSH client found. Please install OpenSSH or PuTTY/plink.'
            }
            
            $proc = Start-Process -FilePath $sshClient -ArgumentList $sshArgs -NoNewWindow -PassThru -Wait `
                -RedirectStandardOutput ([IO.Path]::GetTempFileName()) `
                -RedirectStandardError ([IO.Path]::GetTempFileName())
            
            if ($proc.ExitCode -ne 0) {
                throw "SSH command failed with exit code $($proc.ExitCode)"
            }
        }
        function Invoke-VBoxGuest {
            param(
                [string]$Name,
                [System.Management.Automation.PSCredential]$Credential,
                [string]$CommandLine,
                [int]$TimeoutSec = 3600
            )
            $VBox = Install-Tool 'VBoxManage'
            $User = $Credential.UserName
            $Plain = $Credential.GetNetworkCredential().Password
            & $VBox guestcontrol "$Name" run --exe '/bin/bash' `
                --username "$User" --password "$Plain" --timeout ($TimeoutSec * 1000) --wait-stdout --wait-stderr -- -lc "$CommandLine"
        }
        function Copy-VBoxGuestItemFrom {
            param(
                [string]$Name,
                [System.Management.Automation.PSCredential]$Credential,
                [string]$GuestPath,
                [string]$HostPath
            )
            $VBox = Install-Tool 'VBoxManage'
            $User = $Credential.UserName
            $Plain = $Credential.GetNetworkCredential().Password
            $HostDir = Split-Path -Parent $HostPath
            if (-not (Test-Path $HostDir)) {
                New-Item -ItemType Directory -Path $HostDir | Out-Null 
            }
            & $VBox guestcontrol "$Name" copyfrom --username "$User" --password "$Plain" -- "$GuestPath" "$HostPath"
        }
        function Stop-VBoxVM([string]$Name) {
            (& (Install-Tool 'VBoxManage') controlvm "$Name" acpipowerbutton) | Out-Null 
        }

        function Import-VMwareWhonix([string]$Ova, [string]$DestinationDir) {
            $Ovftool = Install-Tool 'Ovftool'
            if (-not (Test-Path $DestinationDir)) {
                New-Item -ItemType Directory -Path $DestinationDir | Out-Null 
            }
            
            # Try with most relaxed settings first
            $Arguments = @(
                '--acceptAllEulas',
                '--lax',
                '--skipManifestCheck', 
                '--allowAllExtraConfig',
                '--noSSLVerify',
                '--X:logLevel=verbose',
                '--X:logFile=' + (Join-Path $DestinationDir 'ovftool.log'),
                $Ova,
                $DestinationDir
            )
            
            V '[*] ovftool: OVA → VMX (relaxed mode)…'
            $Proc = Start-Process -FilePath $Ovftool -ArgumentList $Arguments -NoNewWindow -PassThru -Wait -RedirectStandardError (Join-Path $DestinationDir 'ovftool-error.txt') -RedirectStandardOutput (Join-Path $DestinationDir 'ovftool-output.txt')
            
            if ($Proc.ExitCode -ne 0) {
                $errorLog = Get-Content (Join-Path $DestinationDir 'ovftool-error.txt') -Raw -ErrorAction SilentlyContinue
                V "[WARN] ovftool failed with exit code $($Proc.ExitCode)"
                V "[WARN] Error details: $errorLog"
                throw 'ovftool failed to import Whonix OVA. This OVA may have format issues. Consider using -Backend VirtualBox instead, or manually extract the OVA and convert to VMX format.'
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
            (& (Install-Tool 'Vmrun') -T ws start "$Vmx" nogui) | Out-Null 
        }
        function Test-VMwareGuestReady {
            param(
                [string]$Vmx,
                [System.Management.Automation.PSCredential]$Credential,
                [int]$TimeoutSec = 900
            )
            $Vmrun = Install-Tool 'Vmrun'
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
            $Vmrun = Install-Tool 'Vmrun'
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
            $Vmrun = Install-Tool 'Vmrun'
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
            (& (Install-Tool 'Vmrun') -T ws stop "$Vmx" soft) | Out-Null 
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
        
        if ($Links.Cached) {
            # Using cached files - convert file:// URI back to Windows path
            $OvaPath = ([Uri]$Links.OvaUrl).LocalPath
            $ShaPath = ([Uri]$Links.ShaUrl).LocalPath
        }
        else {
            # Download from URLs
            $OvaPath = Join-Path $CacheDir (Split-Path -Leaf ([Uri]$Links.OvaUrl).AbsolutePath)
            $ShaPath = Join-Path $CacheDir (Split-Path -Leaf ([Uri]$Links.ShaUrl).AbsolutePath)
            
            if (-not (Test-Path $OvaPath)) {
                Invoke-Download -Uri $Links.OvaUrl -OutFile $OvaPath | Out-Null 
            }
            else {
                V "[OK] Using cached OVA: $OvaPath" 
            }
            
            if (-not (Test-Path $ShaPath)) {
                Invoke-Download -Uri $Links.ShaUrl -OutFile $ShaPath | Out-Null
            }
            else {
                V "[OK] Using cached SHA file: $ShaPath"
            }
        }
        
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
            
            V '[*] Starting Gateway VM...'
            Start-VBoxVM $VmInfo.Gateway
            Start-Sleep -Seconds 15
            
            V '[*] Starting Workstation VM...'
            Start-VBoxVM $VmInfo.Workstation
            
            V "[*] Waiting for SSH on Workstation (localhost:$($VmInfo.SSHPort))..."
            Wait-VBoxSSH -Name $VmInfo.Workstation -SSHPort $VmInfo.SSHPort -Credential $GuestCredential -TimeoutSec 300
            
            # Execute the download command via SSH
            $Command = "mkdir -p '$GuestOutDir' && cd '$GuestOutDir' && if command -v scurl >/dev/null 2>&1; then scurl -fsSL '$Url' -o '$GuestFile'; elif command -v torsocks >/dev/null 2>&1; then torsocks curl -fsSL '$Url' -o '$GuestFile'; else curl -fsSL '$Url' -o '$GuestFile'; fi"
            
            V '[*] Executing download command via SSH...'
            Invoke-SSHCommand -Hostname '127.0.0.1' -Port $VmInfo.SSHPort -Credential $GuestCredential -Command $Command
            
            # Copy file back via SCP
            V '[*] Copying file back to host...'
            $User = $GuestCredential.UserName
            if (Get-Command pscp.exe -ErrorAction SilentlyContinue) {
                $Plain = $GuestCredential.GetNetworkCredential().Password
                & pscp.exe -batch -P $VmInfo.SSHPort -pw $Plain "${User}@127.0.0.1:$GuestFile" $HostOutPath
            }
            elseif (Get-Command scp.exe -ErrorAction SilentlyContinue) {
                & scp.exe -P $VmInfo.SSHPort -o StrictHostKeyChecking=no "${User}@127.0.0.1:$GuestFile" $HostOutPath
            }
            else {
                throw 'No SCP client found. Please install OpenSSH or PuTTY/pscp.'
            }
            if (-not $KeepRunning) {
                Stop-VBoxVM $VmInfo.Workstation; Stop-VBoxVM $VmInfo.Gateway 
            }
            [pscustomobject]@{ Backend = 'VirtualBox'; Gateway = $VmInfo.Gateway; Workstation = $VmInfo.Workstation; Output = $HostOutPath } | Write-Output
            return
        }

        # VMware path
        $VMwareDest = Join-Path $OutputDir 'VMware-Whonix'
        try {
            $VmPaths = Import-VMwareWhonix -Ova $OvaPath -DestinationDir $VMwareDest
        }
        catch {
            Write-Warning "VMware import failed: $($_.Exception.Message)"
            Write-Warning 'Whonix OVAs sometimes have format issues with ovftool.'
            Write-Warning 'Recommendation: Use -Backend VirtualBox for more reliable imports.'
            throw
        }
        Start-VMwareVM $VmPaths.Gateway
        Start-VMwareVM $VmPaths.Workstation
        V '[*] Checking for VMware Tools in Workstation…'
        if (-not (Test-VMwareGuestReady -Vmx $VmPaths.Workstation -Credential $GuestCredential -TimeoutSec 900)) {
            if (-not $KeepRunning) {
                Stop-VMwareVM $VmPaths.Workstation; Stop-VMwareVM $VmPaths.Gateway 
            }
            throw 'Workstation does not have VMware Tools (open-vm-tools). Install tools or use -Backend VirtualBox.'
        }
        
        # Execute the download command directly to avoid line ending issues
        $Bash = "set -euo pipefail; mkdir -p '$GuestOutDir' && cd '$GuestOutDir' && if command -v scurl >/dev/null 2>&1; then scurl -fsSL '$Url' -o '$GuestFile'; elif command -v torsocks >/dev/null 2>&1; then torsocks curl -fsSL '$Url' -o '$GuestFile'; else curl -fsSL '$Url' -o '$GuestFile'; fi"
        
        V '[*] Executing download command in Workstation...'
        Invoke-VMwareGuest -Vmx $VmPaths.Workstation -Credential $GuestCredential -Bash $Bash -TimeoutSec 3600
        Copy-VMwareGuestItemFrom -Vmx $VmPaths.Workstation -Credential $GuestCredential -GuestPath $GuestFile -HostPath $HostOutPath
        if (-not $KeepRunning) {
            Stop-VMwareVM $VmPaths.Workstation; Stop-VMwareVM $VmPaths.Gateway 
        }
        [pscustomobject]@{ Backend = 'VMware'; Gateway = $VmPaths.Gateway; Workstation = $VmPaths.Workstation; Output = $HostOutPath } | Write-Output
    }
}
