function Invoke-WhonixOnionDownload {
    <#
.SYNOPSIS
    Fetch Whonix OVA (including via an .onion landing page), verify SHA-512, and import for VMware or VirtualBox.

.DESCRIPTION
    - If -Url points to a landing page (HTML), the function scrapes the first .ova and matching .sha512sums link.
    - Downloads to a shared cache (defaults to C:\ProgramData\WhonixCache).
    - Verifies the OVA against the published SHA-512.
    - Backend 'VMware': tries ovftool (direct OVA→VMX). On failure, falls back to a *VBox extract → VMX synthesize* path.
    - Backend 'VirtualBox': imports both VSYS with explicit basefolders and disk filenames (idempotent / collision-proof).

.PARAMETER Url
    Either the direct OVA URL or a landing page that contains links to the .ova and .sha512sums.

.PARAMETER OutputDir
    Destination folder for created VMs / artifacts (VMware .vmx folders or VirtualBox basefolders). Created if needed.

.PARAMETER Backend
    'VMware' or 'VirtualBox'. Defaults to 'VMware'.

.PARAMETER Proxy
    Optional HTTP proxy (e.g., http://127.0.0.1:8118) for .onion access via Privoxy/Tor or other proxies.

.PARAMETER CacheDir
    Download/cache directory. Defaults to C:\ProgramData\WhonixCache.

.PARAMETER GuestCredential
    Reserved for future automation steps inside the guest(s). Not used by this importer.

.EXAMPLE
    Invoke-WhonixOnionDownload -Url 'http://example.onion/' -OutputDir 'C:\VMs' -Verbose -Backend VMware

.NOTES
    Requires: PowerShell 5.1+ or 7+, VirtualBox (if using VBox path), VMware Workstation (if using VMware path).
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDir,

        [ValidateSet('VMware', 'VirtualBox')]
        [string]$Backend = 'VMware',

        [string]$Proxy,

        [string]$CacheDir = 'C:\ProgramData\WhonixCache',

        [System.Management.Automation.PSCredential]$GuestCredential
    )

    begin {
        $ErrorActionPreference = 'Stop'
        if (-not (Test-Path $OutputDir)) {
            New-Item -ItemType Directory -Path $OutputDir | Out-Null 
        }
        if (-not (Test-Path $CacheDir)) {
            New-Item -ItemType Directory -Path $CacheDir | Out-Null 
        }

        function Write-Log([string]$msg) {
            Write-Verbose $msg 
        }

        function Get-ToolPath {
            param([Parameter(Mandatory)][ValidateSet('VBoxManage', 'Ovftool', 'Vmrun')]$Name)
            switch ($Name) {
                'VBoxManage' {
                    # VirtualBox sets VBOX_MSI_INSTALL_PATH
                    $p = Join-Path $env:VBOX_MSI_INSTALL_PATH 'VBoxManage.exe'
                    if (-not $p -or -not (Test-Path $p)) {
                        # Fall back to standard Program Files locations
                        $cands = @(
                            "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
                            "$env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe"
                        )
                        $p = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
                    }
                    if (-not $p) {
                        throw 'VBoxManage.exe not found. Please install VirtualBox.' 
                    }
                    return $p
                }
                'Ovftool' {
                    $cands = @(
                        "$env:ProgramFiles(x86)\VMware\VMware Workstation\OVFTool\ovftool.exe",
                        "$env:ProgramFiles\VMware\VMware Workstation\OVFTool\ovftool.exe"
                    )
                    $p = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
                    if (-not $p) {
                        throw 'ovftool.exe not found. Install VMware Workstation (OVF Tool).' 
                    }
                    return $p
                }
                'Vmrun' {
                    $cands = @(
                        "$env:ProgramFiles(x86)\VMware\VMware Workstation\vmrun.exe",
                        "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe"
                    )
                    $p = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
                    if (-not $p) {
                        throw 'vmrun.exe not found. Install VMware Workstation.' 
                    }
                    return $p
                }
            }
        }

        function Invoke-Download {
            param(
                [Parameter(Mandatory)][string]$Uri,
                [Parameter(Mandatory)][string]$OutFile
            )
            Write-Log "[*] Downloading: $Uri"
            $params = @{
                Uri                = $Uri
                OutFile            = $OutFile
                UseBasicParsing    = $true
                MaximumRedirection = 5
            }
            if ($Proxy) {
                $params['Proxy'] = $Proxy 
            }
            Invoke-WebRequest @params | Out-Null
            if (-not (Test-Path $OutFile)) {
                throw "Download failed: $Uri" 
            }
            return $OutFile
        }

        function Get-LinksFromPage {
            param([Parameter(Mandatory)][string]$PageUrl)
            $tmp = Join-Path $CacheDir 'index.html'
            Invoke-Download -Uri $PageUrl -OutFile $tmp | Out-Null
            $html = Get-Content -LiteralPath $tmp -Raw -ErrorAction Stop
            # Very lightweight scrape for first .ova and .sha512sums
            $ova = [regex]::Match($html, '(https?://\S+?\.ova)').Value
            if (-not $ova) {
                $ova = [regex]::Match($html, '(http://\S+?\.ova)').Value 
            } # allow http for onion proxies
            $sha = [regex]::Match($html, '(https?://\S+?\.sha512sums)').Value
            if (-not $sha) {
                $sha = [regex]::Match($html, '(http://\S+?\.sha512sums)').Value 
            }
            if (-not $ova -or -not $sha) {
                throw "Could not locate .ova and .sha512sums links on page: $PageUrl" 
            }
            [pscustomobject]@{ OvaUrl = $ova; ShaUrl = $sha }
        }

        function Resolve-OvaAndSha {
            param([Parameter(Mandatory)][string]$InputUrl)
            if ($InputUrl -match '\.ova($|\?)') {
                # Direct OVA link; try to guess sha512sums by same directory listing
                $base = Split-Path -Path $InputUrl -Parent
                [pscustomobject]@{
                    OvaUrl = $InputUrl
                    ShaUrl = "$base/$(Split-Path -Leaf $InputUrl).sha512sums"
                }
            }
            else {
                Get-LinksFromPage -PageUrl $InputUrl
            }
        }

        function Test-Sha512 {
            param(
                [Parameter(Mandatory)][string]$File,
                [Parameter(Mandatory)][string]$ShaFile
            )
            Write-Log '[*] Verifying SHA-512…'
            $have = (Get-FileHash -Algorithm SHA512 -LiteralPath $File).Hash.ToLowerInvariant()
            $lines = Get-Content -LiteralPath $ShaFile -ErrorAction Stop
            # Accept common formats: "<hash>  filename" or "SHA512 (filename) = hash"
            $expected = $null
            $name = Split-Path -Leaf $File
            foreach ($ln in $lines) {
                if ($ln -match '^[0-9a-fA-F]{128}\s+(\*|\s)?(.+)$') {
                    $h = $matches[0].Split()[0]
                    $f = ($matches[0] -replace '^[0-9a-fA-F]{128}\s+(\*|\s)?', '').Trim()
                    if ($f -eq $name) {
                        $expected = $h; break 
                    }
                }
                elseif ($ln -match '^SHA512\s*\((.+)\)\s*=\s*([0-9a-fA-F]{128})') {
                    if ($matches[1] -eq $name) {
                        $expected = $matches[2]; break 
                    }
                }
            }
            if (-not $expected) {
                throw "No matching entry for $name in $ShaFile" 
            }
            if ($have.ToLowerInvariant() -ne $expected.ToLowerInvariant()) {
                throw "SHA-512 mismatch for $name"
            }
            Write-Log '[OK] Checksum verified.'
        }

        function New-UniqueName {
            param([Parameter(Mandatory)][string]$Base)
            # Avoid VirtualBox name collisions
            $name = $Base
            $i = 1
            $existing = @()
            try {
                $vb = Get-ToolPath -Name VBoxManage
                $existing = (& $vb list vms 2>$null) -replace '".*"$', '' | ForEach-Object {
                    ($_ -replace '^"', '') -replace '"{.*}$', ''
                }
            }
            catch {
            }
            while ($existing -contains $name) {
                $name = "$Base-$i"; $i++ 
            }
            return $name
        }

        function Import-With-VBox {
            param(
                [Parameter(Mandatory)][string]$OvaPath,
                [Parameter(Mandatory)][string]$DestRoot
            )
            # Map from the Whonix unified OVA:
            #   VSYS 0 (Gateway) uses unit 18 for the disk
            #   VSYS 1 (Workstation) uses unit 16 for the disk
            # See VBoxManage import docs. :contentReference[oaicite:1]{index=1}
            $vb = Get-ToolPath -Name VBoxManage

            $gwName = New-UniqueName -Base 'Whonix-Gateway'
            $wsName = New-UniqueName -Base 'Whonix-Workstation'
            $gwBase = Join-Path $DestRoot ('GW-' + ([guid]::NewGuid().ToString('N')))
            $wsBase = Join-Path $DestRoot ('WS-' + ([guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $gwBase, $wsBase | Out-Null

            $gwDisk = Join-Path $gwBase 'gateway-disk1.vmdk'
            $wsDisk = Join-Path $wsBase 'workstation-disk1.vmdk'

            Write-Log '[*] VBox import (Gateway)…'
            & $vb import "$OvaPath" `
                --vsys 0 --eula accept `
                --vmname "$gwName" `
                --basefolder "$gwBase" `
                --unit 18 --disk "$gwDisk"

            Write-Log '[*] VBox import (Workstation)…'
            & $vb import "$OvaPath" `
                --vsys 1 --eula accept `
                --vmname "$wsName" `
                --basefolder "$wsBase" `
                --unit 16 --disk "$wsDisk"

            return [pscustomobject]@{
                Gateway     = [pscustomobject]@{
                    Name = $gwName; Base = $gwBase; Disk = $gwDisk
                }
                Workstation = [pscustomobject]@{
                    Name = $wsName; Base = $wsBase; Disk = $wsDisk
                }
            }
        }

        function New-MinimalVmx {
            param(
                [Parameter(Mandatory)][string]$Dir,
                [Parameter(Mandatory)][string]$VmName,
                [Parameter(Mandatory)][string]$VmdkName,   # file name only
                [int]$MemMB = 2048,
                [int]$Cpu = 2
            )
            if (-not (Test-Path $Dir)) {
                New-Item -ItemType Directory -Path $Dir | Out-Null 
            }
            $vmxPath = Join-Path $Dir "$VmName.vmx"
            $vmx = @"
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "16"
displayName = "$VmName"
guestOS = "debian12-64"
memsize = "$MemMB"
numvcpus = "$Cpu"

scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$VmdkName"

ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "e1000e"

usb.present = "TRUE"
sound.present = "FALSE"
firmware = "bios"
"@
            Set-Content -LiteralPath $vmxPath -Value $vmx -Encoding ASCII
            return $vmxPath
        }

        function Invoke-OvfToolDirect {
            param(
                [Parameter(Mandatory)][string]$OvaPath,
                [Parameter(Mandatory)][string]$DestDir
            )
            $ovf = Get-ToolPath -Name Ovftool
            if (-not (Test-Path $DestDir)) {
                New-Item -ItemType Directory -Path $DestDir | Out-Null 
            }
            # Use an **argument array**; DO NOT concatenate strings that include 'and' etc.
            # Examples: OVA→VMX and --lax in VMware docs. :contentReference[oaicite:2]{index=2}
            $Arguments = @(
                '--acceptAllEulas',
                '--lax',
                '--skipManifestCheck',
                '--allowAllExtraConfig',
                $OvaPath,
                $DestDir  # Let ovftool decide naming; it will create VMX/VMDK(s) under this directory
            )
            Write-Log '[*] ovftool: converting OVA → VMX (relaxed)…'
            $p = Start-Process -FilePath $ovf -ArgumentList $Arguments -NoNewWindow -PassThru -Wait
            return $p.ExitCode
        }

        function Invoke-ConvertVBoxToVMware {
            param(
                [Parameter(Mandatory)][pscustomobject]$VBoxResult,
                [Parameter(Mandatory)][string]$DestRoot
            )
            # Copy disks to VMware folders and create minimal .vmx files. VMware KB confirms
            # you can create a VM from existing VMDKs. :contentReference[oaicite:3]{index=3}
            $gwDst = Join-Path $DestRoot 'Whonix-Gateway'
            $wsDst = Join-Path $DestRoot 'Whonix-Workstation'
            New-Item -ItemType Directory -Path $gwDst, $wsDst -ErrorAction SilentlyContinue | Out-Null

            $gwDiskName = Split-Path -Leaf $VBoxResult.Gateway.Disk
            $wsDiskName = Split-Path -Leaf $VBoxResult.Workstation.Disk

            Copy-Item -LiteralPath $VBoxResult.Gateway.Disk -Destination (Join-Path $gwDst $gwDiskName) -Force
            Copy-Item -LiteralPath $VBoxResult.Workstation.Disk -Destination (Join-Path $wsDst $wsDiskName) -Force

            $gwVmx = New-MinimalVmx -Dir $gwDst -VmName 'Whonix-Gateway' -VmdkName $gwDiskName -MemMB 1280 -Cpu 3
            $wsVmx = New-MinimalVmx -Dir $wsDst -VmName 'Whonix-Workstation' -VmdkName $wsDiskName -MemMB 2048 -Cpu 3

            [pscustomobject]@{ GatewayVmx = $gwVmx; WorkstationVmx = $wsVmx }
        }
    }

    process {
        Write-Log '[*] Resolving OVA + SHA512 links…'
        $links = Resolve-OvaAndSha -InputUrl $Url

        $ovaName = Split-Path -Leaf $links.OvaUrl
        $shaName = Split-Path -Leaf $links.ShaUrl
        $ovaPath = Join-Path $CacheDir $ovaName
        $shaPath = Join-Path $CacheDir $shaName

        if (-not (Test-Path $ovaPath)) {
            Invoke-Download -Uri $links.OvaUrl -OutFile $ovaPath | Out-Null
        }
        else {
            Write-Log "[OK] OVA already cached: $ovaPath"
        }

        Invoke-Download -Uri $links.ShaUrl -OutFile $shaPath | Out-Null
        Test-Sha512 -File $ovaPath -ShaFile $shaPath

        switch ($Backend) {
            'VirtualBox' {
                if ($PSCmdlet.ShouldProcess('VirtualBox', 'Import Whonix OVA')) {
                    $vboxRoot = Join-Path $OutputDir 'VirtualBox-Whonix'
                    $vx = Import-With-VBox -OvaPath $ovaPath -DestRoot $vboxRoot
                    Write-Log '[OK] VirtualBox import complete.'
                    Write-Output ([pscustomobject]@{
                            Backend         = 'VirtualBox'
                            GatewayPath     = $vx.Gateway.Base
                            WorkstationPath = $vx.Workstation.Base
                        })
                }
            }
            'VMware' {
                if ($PSCmdlet.ShouldProcess('VMware', 'Convert/Import Whonix OVA')) {
                    $vmwRoot = Join-Path $OutputDir 'VMware-Whonix'
                    New-Item -ItemType Directory -Path $vmwRoot -ErrorAction SilentlyContinue | Out-Null

                    $exit = Invoke-OvfToolDirect -OvaPath $ovaPath -DestDir $vmwRoot
                    if ($exit -eq 0) {
                        Write-Log "[OK] ovftool conversion succeeded → $vmwRoot"
                        # Heads-up: Whonix notes VMware imports may require relaxed checks; we used --lax. :contentReference[oaicite:4]{index=4}
                        Write-Output ([pscustomobject]@{
                                Backend = 'VMware'
                                Path    = $vmwRoot
                                Note    = 'OVF Tool created one or more VMX folders under this directory.'
                            })
                    }
                    else {
                        Write-Warning "ovftool failed (exit $exit). Falling back: VBox extract → synthesize VMX."
                        $vboxExtractRoot = Join-Path $CacheDir 'vbox-extract'
                        $vx = Import-With-VBox -OvaPath $ovaPath -DestRoot $vboxExtractRoot
                        $vmx = Invoke-ConvertVBoxToVMware -VBoxResult $vx -DestRoot $vmwRoot
                        Write-Log '[OK] VMware VMX synthesized from VBox disks.'
                        Write-Output ([pscustomobject]@{
                                Backend        = 'VMware'
                                GatewayVmx     = $vmx.GatewayVmx
                                WorkstationVmx = $vmx.WorkstationVmx
                                Note           = 'Networks are basic (NAT). Adjust vmx to match your Whonix internal link model.'
                            })
                    }
                }
            }
        }
    }
}
