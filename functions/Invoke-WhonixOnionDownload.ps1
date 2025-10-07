function Invoke-WhonixOnionDownload {
    <#
.SYNOPSIS
Safely downloads a file from a .onion URL via Whonix (Gateway + Workstation) in VirtualBox.

.DESCRIPTION
Idempotently:
1) Ensures VirtualBox is installed (via winget).
2) Locates the latest Whonix VirtualBox OVA and its checksum; verifies SHA-512.
3) Imports Whonix VMs if not already present (unified OVA creates Gateway + Workstation).
4) Starts Gateway, then Workstation (optionally headless) and waits for Guest Additions to be ready.
5) Runs Tor-isolated `curl` **inside Whonix-Workstation** to download the .onion URL.
6) Copies the file to a host quarantine folder and writes a Mark-of-the-Web ADS.
7) Optionally hardens the Workstation VM (no clipboard, no drag-and-drop).

.PARAMETER Url
The .onion URL to download. Only v3 onions (56-char host) are accepted.

.PARAMETER OutputDir
Host directory for quarantined output. Created if missing.

.PARAMETER WhonixOvaUrl
Optional: override the Whonix OVA URL. If omitted, the cmdlet discovers it from the official VirtualBox page.

.PARAMETER Headless
Start VMs headless.

.PARAMETER HardenVM
Disable clipboard, drag-and-drop, VRDE, and audio on the Workstation.

.PARAMETER ForceReimport
Force re-import of Whonix (even if VMs already exist).

.PARAMETER GuestUsername
Guest username for `guestcontrol`. Defaults to 'user' (Whonix).

.PARAMETER GuestPassword
Optional guest password. If omitted, the cmdlet authenticates with an empty password
(which Whonix currently permits for the default 'user' account).

.EXAMPLE
Invoke-WhonixOnionDownload -Url 'http://<56char>.onion/file.bin' -OutputDir 'D:\OnionQuarantine' -Headless -HardenVM

.EXAMPLE
Invoke-WhonixOnionDownload -Url 'http://<56char>.onion/tools.tgz' -OutputDir 'C:\Quarantine' -WhonixOvaUrl 'https://…/Whonix-Xfce-*.ova'

.INPUTS
None.

.OUTPUTS
Writes the downloaded file to OutputDir and a simple log with SHA-256.

.NOTES
- Requires Windows with winget, internet access, and enough disk/RAM for two VMs.
- Do not open the file on the host; analyze offline in a separate VM.
- VirtualBox Guest Additions are present in Whonix VB images by default (needed for guestcontrol).
- Default Whonix user is 'user' with passwordless login; you can provide -GuestPassword if you have changed it.

.LINK
Whonix for VirtualBox: https://www.whonix.org/wiki/VirtualBox
VirtualBox CLI: https://www.virtualbox.org/manual/ch08.html
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [string]$WhonixOvaUrl,
        [switch]$Headless,
        [switch]$HardenVM,
        [switch]$ForceReimport,
        [string]$GuestUsername = 'user',
        [string]$GuestPassword
    )

    # region: safety & helpers
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    function Write-Step($m) {
        Write-Host "[*] $m" -ForegroundColor Cyan 
    }
    function Write-Ok($m) {
        Write-Host "[OK] $m" -ForegroundColor Green 
    }
    function Write-Warn($m) {
        Write-Warning $m 
    }

    # v3 onion host validator
    function Test-OnionUrl {
        param([string]$u)
        try {
            $uri = [Uri]$u
            if ($uri.Scheme -notin @('http', 'https')) {
                return $false 
            }
            if ($uri.Host -notmatch '\.onion$') {
                return $false 
            }
            # Allow subdomains but require a 56-char v3 label immediately before .onion
            # e.g., abc.<56>.onion is allowed; enforce presence of a v3 label anywhere.
            if ($uri.Host -notmatch '(?:^|\.)([a-z2-7]{56})\.onion$') {
                return $false 
            }
            return $true
        }
        catch {
            return $false 
        }
    }

    if (-not (Test-OnionUrl $Url)) {
        throw 'Url must be a valid v3 .onion URL (56-char base32 host).'
    }

    # Shell out to VBoxManage with a *real* argument array (avoids quoting bugs)
    $script:VBoxManage = $null
    function VB {
        param([Parameter(Mandatory = $true)][string[]]$Args)
        $out = & $script:VBoxManage @Args 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            throw "VBoxManage failed ($code): $($Args -join ' ')`n$out" 
        }
        return $out
    }

    function Get-VBoxManagePath {
        foreach ($p in @(
                "$Env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
                "$Env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe"
            )) {
            if (Test-Path $p) {
                return $p 
            }
        }
        $cmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source 
        }
        throw 'VBoxManage.exe not found.'
    }

    function Ensure-VirtualBox {
        Write-Step 'Ensuring VirtualBox is installed…'
        if (-not (Get-Command VBoxManage.exe -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess('VirtualBox', 'Install via winget')) {
                & winget install --id Oracle.VirtualBox --accept-package-agreements --accept-source-agreements --silent | Out-Null
            }
        }
        else {
            Write-Ok 'VirtualBox already installed.'
        }
    }

    function Get-WhonixLatest {
        param([string]$OverrideUrl)
        if ($OverrideUrl) {
            return @{ Ova = $OverrideUrl; ShaUrl = $null } 
        }
        Write-Step 'Discovering latest Whonix OVA from official VirtualBox page…'
        $page = Invoke-WebRequest -UseBasicParsing -Uri 'https://www.whonix.org/wiki/VirtualBox'
        # Heuristic: first Whonix-Xfce *.ova link on the page (unified OVA contains GW+WS)
        $ova = ($page.Links | Where-Object { $_.href -match '\.ova$' -and $_.href -match 'Whonix-.*Xfce' } | Select-Object -First 1).href
        if (-not $ova) {
            throw 'Could not find OVA link on the Whonix VirtualBox page.' 
        }
        $sha = ($page.Links | Where-Object { $_.innerText -match 'SHA-512 checksum file' } | Select-Object -First 1).href
        if ($ova -notmatch '^https?://') {
            $ova = [Uri]::new($page.BaseResponse.ResponseUri, $ova).AbsoluteUri 
        }
        if ($sha -and $sha -notmatch '^https?://') {
            $sha = [Uri]::new($page.BaseResponse.ResponseUri, $sha).AbsoluteUri 
        }
        return @{ Ova = $ova; ShaUrl = $sha }
    }

    function Download-And-Verify-Whonix {
        param([string]$OvaUrl, [string]$ShaUrl, [string]$CacheDir)
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        $ovaName = Split-Path $OvaUrl -Leaf
        $ovaPath = Join-Path $CacheDir $ovaName
        $shaPath = if ($ShaUrl) {
            Join-Path $CacheDir (Split-Path $ShaUrl -Leaf) 
        }

        if (-not (Test-Path $ovaPath)) {
            Write-Step "Downloading OVA: $ovaName"
            Invoke-WebRequest -UseBasicParsing -Uri $OvaUrl -OutFile $ovaPath
        }
        else {
            Write-Ok 'OVA already cached.' 
        }

        if ($ShaUrl) {
            if (-not (Test-Path $shaPath)) {
                Write-Step 'Downloading SHA-512 checksum file…'
                Invoke-WebRequest -UseBasicParsing -Uri $ShaUrl -OutFile $shaPath
            }
            Write-Step 'Verifying SHA-512…'
            $line = (Select-String -Path $shaPath -Pattern ([regex]::Escape($ovaName))).Line
            if (-not $line) {
                throw "Checksum line for $ovaName not found in $shaPath" 
            }
            $expected = ($line -split '\s+')[0]
            $actual = (Get-FileHash -Path $ovaPath -Algorithm SHA512).Hash.ToLower()
            if ($actual -ne $expected.ToLower()) {
                throw "Checksum mismatch! expected=$expected actual=$actual" 
            }
            Write-Ok 'Checksum verified.'
        }
        else {
            Write-Warn 'No checksum file link found; continuing without verification.'
        }
        return $ovaPath
    }

    function Import-Whonix {
        param([string]$OvaPath, [switch]$Force)
        Write-Step 'Checking for existing Whonix VMs…'
        $vms = VB @('list', 'vms')
        $gwExists = $vms -match 'Whonix-.*Gateway'
        $wsExists = $vms -match 'Whonix-.*Workstation'
        if (($gwExists -and $wsExists) -and -not $Force) {
            Write-Ok 'Whonix VMs already present.'
            return
        }
        Write-Step 'Importing Whonix OVA (this creates Gateway + Workstation)…'
        if ($PSCmdlet.ShouldProcess('Import OVA', "$OvaPath")) {
            VB @('import', $OvaPath) | Out-Null
        }
        Write-Ok 'Import complete.'
    }

    function Find-VMName {
        param([string]$Pattern)
        $list = VB @('list', 'vms')
        $name = ($list | Select-String -Pattern $Pattern | ForEach-Object { ($_ -split '"')[1] } | Select-Object -First 1)
        if (-not $name) {
            throw "Could not find VM matching pattern: $Pattern" 
        }
        return $name
    }

    function Harden-Workstation {
        param([string]$VMName)
        Write-Step "Hardening '$VMName'…"
        foreach ($a in @('--clipboard-mode', 'disabled', '--clipboard', 'disabled')) {
            try {
                VB @('modifyvm', $VMName, $a) 
            }
            catch {
            } 
        }
        foreach ($a in @('--drag-and-drop', 'disabled', '--draganddrop', 'disabled')) {
            try {
                VB @('modifyvm', $VMName, $a) 
            }
            catch {
            } 
        }
        try {
            VB @('modifyvm', $VMName, '--vrde', 'off', '--audio', 'none') 
        }
        catch {
        }
        Write-Ok 'Hardened (best-effort).'
    }

    function Start-Whonix {
        param([string]$Gateway, [string]$Workstation, [switch]$Headless)
        $typeArgs = $Headless ? @('--type', 'headless') : @()
        Write-Step "Starting Gateway '$Gateway'…"
        VB @('startvm', $Gateway) + $typeArgs | Out-Null
        Write-Step "Starting Workstation '$Workstation'…"
        VB @('startvm', $Workstation) + $typeArgs | Out-Null

        Write-Step 'Waiting for Guest Additions in Workstation…'
        # Wait up to 10 minutes for a GA-provided property to appear
        VB @('guestproperty', 'wait', $Workstation, '/VirtualBox/GuestInfo/OS/Product', '--timeout', '600000') | Out-Null
        Write-Ok 'Guest properties available.'
    }

    function Run-InGuest {
        param([string]$VM, [string]$User, [string]$Pass, [string]$Exe, [string[]]$Args)
        $cmd = @('guestcontrol', $VM, 'run', '--username', $User, '--exe', $Exe, '--wait-stdout', '--wait-exit', '--')
        if ($PSBoundParameters.ContainsKey('Pass') -and $null -ne $Pass) {
            $cmd = @('guestcontrol', $VM, 'run', '--username', $User, '--password', $Pass, '--exe', $Exe, '--wait-stdout', '--wait-exit', '--')
        }
        VB ($cmd + $Args) | Out-Null
    }

    function CopyFrom-Guest {
        param([string]$VM, [string]$User, [string]$Pass, [string]$GuestPath, [string]$HostPath)
        $cmd = @('guestcontrol', $VM, 'copyfrom', '--username', $User, $GuestPath, $HostPath)
        if ($PSBoundParameters.ContainsKey('Pass') -and $null -ne $Pass) {
            $cmd = @('guestcontrol', $VM, 'copyfrom', '--username', $User, '--password', $Pass, $GuestPath, $HostPath)
        }
        VB $cmd | Out-Null
    }

    function Add-MOTW {
        param([string]$Path, [string]$RefUrl)
        Set-Content -Path $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3`nReferrerUrl=$RefUrl`nHostUrl=$RefUrl"
    }

    function Stop-Whonix {
        param([string]$Gateway, [string]$Workstation)
        foreach ($vm in @($Workstation, $Gateway)) {
            Write-Step "Powering off $vm…"
            try {
                VB @('controlvm', $vm, 'poweroff') | Out-Null 
            }
            catch {
            }
        }
    }
    # endregion

    # region: main flow
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $cache = Join-Path $env:ProgramData 'WhonixCache'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null

    Ensure-VirtualBox
    $script:VBoxManage = Get-VBoxManagePath

    $links = Get-WhonixLatest -OverrideUrl:$WhonixOvaUrl
    $ovaPath = Download-And-Verify-Whonix -OvaUrl $links.Ova -ShaUrl $links.ShaUrl -CacheDir $cache

    Import-Whonix -OvaPath $ovaPath -Force:$ForceReimport

    $gwName = Find-VMName -Pattern 'Whonix-.*Gateway'
    $wsName = Find-VMName -Pattern 'Whonix-.*Workstation'

    if ($HardenVM) {
        Harden-Workstation -VMName $wsName 
    }

    Start-Whonix -Gateway $gwName -Workstation $wsName -Headless:$Headless

    # Prepare target paths
    $guestUser = $GuestUsername
    $guestPass = $GuestPassword  # may be $null (empty password)
    $guestDir = "/home/$guestUser/whonix_downloads"
    $leaf = [System.IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = ('download_' + [Guid]::NewGuid().ToString('N')) 
    }
    $guestOut = "$guestDir/$leaf"

    Write-Step 'Creating guest directory and fetching over Tor inside Workstation…'
    Run-InGuest -VM $wsName -User $guestUser -Pass $guestPass -Exe '/bin/mkdir' -Args @('-p', $guestDir)

    # Use uwt-wrapped curl (Whonix wraps curl for stream isolation)
    Run-InGuest -VM $wsName -User $guestUser -Pass $guestPass -Exe '/usr/bin/curl' -Args @(
        '--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused',
        '--output', $guestOut, $Url
    )

    $hostOut = Join-Path $OutputDir (Split-Path $guestOut -Leaf)
    Write-Step "Copying file from guest to host quarantine: $hostOut"
    CopyFrom-Guest -VM $wsName -User $guestUser -Pass $guestPass -GuestPath $guestOut -HostPath $hostOut

    Add-MOTW -Path $hostOut -RefUrl $Url
    $sha256 = (Get-FileHash -Path $hostOut -Algorithm SHA256).Hash
    Write-Ok "Downloaded file SHA256: $sha256"
    "Saved: $hostOut`nSHA256: $sha256`n" | Out-File -Append -FilePath (Join-Path $OutputDir 'download.log')

    # Optional: power off (idempotent)
    Stop-Whonix -Gateway $gwName -Workstation $wsName
    Write-Ok "Done. File quarantined at: $hostOut"
    # endregion
}
