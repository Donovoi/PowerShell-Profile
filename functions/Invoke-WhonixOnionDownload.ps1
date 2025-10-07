function Invoke-WhonixOnionDownload {
    <#
.SYNOPSIS
Safely downloads a file from a v3 .onion URL via Whonix (Gateway + Workstation) in VirtualBox.

.DESCRIPTION
Idempotently:
 1) Ensures VirtualBox is installed (winget) and available on PATH.
 2) Discovers the latest Whonix VirtualBox OVA and derives its checksum URL (<ova>.sha512sums); verifies SHA-512.
 3) Imports Whonix if not already present (unified OVA creates Gateway + Workstation), explicitly accepts EULAs, and sets stable VM names.
 4) Starts Gateway then Workstation (optionally headless) and waits for Guest Additions readiness.
 5) Runs Tor-isolated curl INSIDE Whonix-Workstation to fetch the .onion URL.
 6) Copies the file to a host quarantine folder, sets Mark-of-the-Web (ZoneId=3), logs SHA-256.
 7) Optionally hardens Workstation (disable clipboard, drag-and-drop, VRDE, audio).

.PARAMETER Url
A valid v3 .onion URL (56-char base32 host). Example: http://<56chars>.onion/path/file.bin

.PARAMETER OutputDir
Host directory to store the quarantined file. Created if missing.

.PARAMETER WhonixOvaUrl
Optional explicit OVA URL. When omitted, the cmdlet auto-discovers from the official VirtualBox page.

.PARAMETER Headless
Start the VMs headless.

.PARAMETER HardenVM
Disable clipboard and drag & drop on the Workstation for extra isolation.

.PARAMETER ForceReimport
Force re-import of the OVA even if Whonix VMs already exist.

.PARAMETER GuestCredential
Optional [pscredential] for the guest (e.g., 'user'). If omitted, only --username is passed (passwordless allowed if enabled in guest).

.PARAMETER GatewayName
Optional explicit name to assign to the Gateway VM at import (default: 'Whonix-Gateway').

.PARAMETER WorkstationName
Optional explicit name to assign to the Workstation VM at import (default: 'Whonix-Workstation').

.EXAMPLE
# Passwordless guestcontrol (many Whonix VB images allow this for user 'user'):
Invoke-WhonixOnionDownload -Url 'http://<56char>.onion/payload.bin' -OutputDir 'D:\OnionQuarantine' -Headless -HardenVM -Verbose

.EXAMPLE
# With credentials:
$cred = Get-Credential -UserName 'user' -Message 'Guest (Whonix Workstation)'
Invoke-WhonixOnionDownload -Url 'http://<56char>.onion/payload.bin' -OutputDir 'D:\OnionQuarantine' -Headless -HardenVM -GuestCredential $cred -Verbose

.NOTES
- Requires internet access and sufficient disk/RAM for two VMs.
- Do NOT open the downloaded file on the host; analyze offline in a separate VM.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [string]$WhonixOvaUrl,
        [switch]$Headless,
        [switch]$HardenVM,
        [switch]$ForceReimport,
        [pscredential]$GuestCredential,
        [string]$GatewayName,
        [string]$WorkstationName
    )

    #region Safety & utilities
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    function Write-Step([string]$Msg) {
        Write-Verbose "[*] $Msg" 
    }
    function Write-Ok  ([string]$Msg) {
        Write-Verbose "[OK] $Msg"  
    }

    function Test-OnionUrl([string]$u) {
        try {
            $uri = [Uri]$u
            if ($uri.Scheme -notin @('http', 'https')) {
                return $false 
            }
            if ($uri.Host -notmatch '\.onion$') {
                return $false 
            }
            # require a 56-char base32 label somewhere before .onion
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

    # central VBoxManage wrapper (argument array -> avoids quoting issues)
    $script:VBoxManage = $null
    function Invoke-VBoxManage([string[]]$CommandArgs) {
        $out = & $script:VBoxManage @CommandArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "VBoxManage failed ($LASTEXITCODE): $($CommandArgs -join ' ')`n$out"
        }
        return $out
    }

    function Get-VBoxManagePath {
        foreach ($p in @("$Env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
                "$Env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe")) {
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

    function Test-VirtualBoxInstalled {
        return [bool](Get-Command VBoxManage.exe -ErrorAction SilentlyContinue) 
    }

    function Install-VirtualBox {
        if ($PSCmdlet.ShouldProcess('VirtualBox', 'Install via winget')) {
            & winget install --id Oracle.VirtualBox --accept-package-agreements --accept-source-agreements --silent | Out-Null
        }
    }

    function Initialize-VirtualBox {
        Write-Step 'Ensuring VirtualBox is installed…'
        if (-not (Test-VirtualBoxInstalled)) {
            Install-VirtualBox 
        }
        else {
            Write-Ok 'VirtualBox already installed.' 
        }
    }

    function Get-WhonixLatestOva([string]$OverrideUrl) {
        if ($OverrideUrl) {
            return @{ Ova = $OverrideUrl; ShaUrl = "$OverrideUrl.sha512sums" } 
        }

        Write-Step 'Discovering latest Whonix OVA from official page…'
        $dlPage = 'https://www.whonix.org/wiki/VirtualBox'
        $page = Invoke-WebRequest -Uri $dlPage -UseBasicParsing -ErrorAction Stop
        $html = $page.Content

        # Prefer direct .ova links from the page (Xfce or CLI)
        $ova = $null
        if ($page.Links) {
            $ova = ($page.Links |
                    Where-Object { $_.href -match '\.ova$' -and $_.href -match '(?i)Whonix.*(Xfce|CLI)' } |
                        Select-Object -ExpandProperty href -First 1)
        }
        if (-not $ova) {
            $m = [regex]::Matches($html, 'href="(?<u>https?://[^"]+?\.ova)"', 'IgnoreCase')
            if ($m.Count -gt 0) {
                $ova = $m[0].Groups['u'].Value 
            }
        }
        if (-not $ova) {
            throw "Could not find an OVA link on $dlPage." 
        }

        # Normalize relative links if any
        $base = if ($page.BaseResponse -and $page.BaseResponse.ResponseUri) {
            $page.BaseResponse.ResponseUri 
        }
        else {
            [uri]$dlPage 
        }
        if ($ova -notmatch '^https?://') {
            $ova = [Uri]::new($base, $ova).AbsoluteUri 
        }

        # DERIVE checksum URL from the OVA: authoritative location
        $sha = "$ova.sha512sums"
        return @{ Ova = $ova; ShaUrl = $sha }
    }

    function Get-WhonixOvaAndVerify([string]$OvaUrl, [string]$ShaUrl, [string]$CacheDir) {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        $ovaName = Split-Path $OvaUrl -Leaf
        $ovaPath = Join-Path $CacheDir $ovaName
        $shaPath = Join-Path $CacheDir (Split-Path $ShaUrl -Leaf)

        if (-not (Test-Path $ovaPath)) {
            Write-Step "Downloading OVA: $ovaName"
            Invoke-WebRequest -UseBasicParsing -Uri $OvaUrl -OutFile $ovaPath -ErrorAction Stop
        }
        else {
            Write-Ok "OVA already cached: $ovaPath" 
        }

        Write-Step 'Downloading SHA-512 checksum…'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $ShaUrl -OutFile $shaPath -ErrorAction Stop
        }
        catch {
            # Fallback: try SHA512SUMS in same directory
            $u = [Uri]$OvaUrl
            $dir = $u.AbsoluteUri.Substring(0, $u.AbsoluteUri.LastIndexOf('/') + 1)
            $alt = $dir + 'SHA512SUMS'
            $shaPath = Join-Path $CacheDir 'SHA512SUMS'
            Invoke-WebRequest -UseBasicParsing -Uri $alt -OutFile $shaPath -ErrorAction Stop
        }

        Write-Step 'Verifying SHA-512…'
        $content = Get-Content -LiteralPath $shaPath -Raw
        $line = ($content -split '\r?\n' | Where-Object { $_ -match [regex]::Escape($ovaName) }) | Select-Object -First 1
        $expected = if ($line) {
            ($line -split '\s+')[0] 
        }
        else {
            if ($content -match '([0-9a-f]{128})') {
                $Matches[1] 
            }
            else {
                throw "Checksum file does not contain a SHA512 for $ovaName. Got: $shaPath" 
            }
        }
        $actual = (Get-FileHash -Path $ovaPath -Algorithm SHA512).Hash.ToLower()
        if ($actual -ne $expected.ToLower()) {
            throw "Checksum mismatch! expected=$expected actual=$actual" 
        }
        Write-Ok 'Checksum verified.'
        return $ovaPath
    }

    function Import-Whonix([string]$OvaPath, [switch]$Force, [string]$GWName, [string]$WSName) {
        Write-Step 'Checking for existing Whonix VMs…'
        $vms = Invoke-VBoxManage @('list', 'vms')
        $gwExists = $vms -match '(?i)whonix.*gateway'
        $wsExists = $vms -match '(?i)whonix.*workstation'
        if (($gwExists -and $wsExists) -and -not $Force) {
            Write-Ok 'Whonix VMs already present.'; return 
        }

        if (-not $GWName) {
            $GWName = 'Whonix-Gateway' 
        }
        if (-not $WSName) {
            $WSName = 'Whonix-Workstation' 
        }

        Write-Step 'Importing Whonix OVA (creates Gateway + Workstation)…'
        # Accept EULAs & set VM names for vsys 0 and 1
        $args = @(
            'import', $OvaPath,
            '--vsys', '0', '--eula', 'accept', '--vsys', '1', '--eula', 'accept',
            '--vsys', '0', '--vmname', $GWName,
            '--vsys', '1', '--vmname', $WSName
        )
        if ($PSCmdlet.ShouldProcess('Import OVA', $OvaPath)) {
            Invoke-VBoxManage $args | Out-Null
        }
        Write-Ok 'Import complete.'
    }

    function Get-WhonixVmNames {
        $names = @{ Gateway = $null; Workstation = $null }
        $list = Invoke-VBoxManage @('list', 'vms')
        foreach ($line in $list) {
            $n = ($line -split '"')[1]
            if (-not $n) {
                continue 
            }
            $lower = $n.ToLowerInvariant()
            if (-not $names.Gateway -and $lower -match 'whonix' -and $lower -match 'gateway') {
                $names.Gateway = $n; continue 
            }
            if (-not $names.Workstation -and $lower -match 'whonix' -and $lower -match 'workstation') {
                $names.Workstation = $n; continue 
            }
        }
        return $names
    }

    function Set-WorkstationHardening([string]$VMName) {
        Write-Step "Hardening '$VMName' settings…"
        foreach ($pair in @(
                @('modifyvm', $VMName, '--clipboard-mode', 'disabled'),
                @('modifyvm', $VMName, '--clipboard', 'disabled'),
                @('modifyvm', $VMName, '--drag-and-drop', 'disabled'),
                @('modifyvm', $VMName, '--draganddrop', 'disabled'),
                @('modifyvm', $VMName, '--vrde', 'off'),
                @('modifyvm', $VMName, '--audio', 'none')
            )) {
            try {
                Invoke-VBoxManage $pair | Out-Null 
            }
            catch {
            } 
        }
        Write-Ok 'Hardened (best-effort).'
    }

    function Start-Whonix([string]$Gateway, [string]$Workstation, [switch]$Headless) {
        $typeArgs = $Headless ? @('--type', 'headless') : @()
        Write-Step "Starting Gateway '$Gateway'…"
        Invoke-VBoxManage (@('startvm', $Gateway) + $typeArgs) | Out-Null
        Write-Step "Starting Workstation '$Workstation'…"
        Invoke-VBoxManage (@('startvm', $Workstation) + $typeArgs) | Out-Null

        Write-Step 'Waiting for Guest Additions in Workstation…'
        Invoke-VBoxManage @('guestproperty', 'wait', $Workstation, '/VirtualBox/GuestInfo/OS/Product', '--timeout', '600000') | Out-Null
        Write-Ok 'Guest properties available.'
    }

    function Invoke-GuestCommand {
        param(
            [string]$VM, [string]$Username, [securestring]$Password, [string]$Exe, [string[]]$CommandArgs
        )
        $cmd = @('guestcontrol', $VM, 'run', '--username', $Username, '--exe', $Exe, '--wait-stdout', '--wait-exit', '--')
        if ($PSBoundParameters.ContainsKey('Password') -and $Password) {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
                $cmd = @('guestcontrol', $VM, 'run', '--username', $Username, '--password', $plain, '--exe', $Exe, '--wait-stdout', '--wait-exit', '--')
            }
            finally {
                if ($ptr -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) 
                }
            }
        }
        Invoke-VBoxManage ($cmd + $CommandArgs) | Out-Null
    }

    function Copy-GuestItem([string]$VM, [string]$Username, [securestring]$Password, [string]$GuestPath, [string]$HostPath) {
        $cmd = @('guestcontrol', $VM, 'copyfrom', '--username', $Username, $GuestPath, $HostPath)
        if ($PSBoundParameters.ContainsKey('Password') -and $Password) {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
                $cmd = @('guestcontrol', $VM, 'copyfrom', '--username', $Username, '--password', $plain, $GuestPath, $HostPath)
            }
            finally {
                if ($ptr -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) 
                }
            }
        }
        Invoke-VBoxManage $cmd | Out-Null
    }

    function Set-MarkOfTheWeb([string]$Path, [string]$RefUrl) {
        try {
            Set-Content -Path $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3`nReferrerUrl=$RefUrl`nHostUrl=$RefUrl"
        }
        catch {
            Write-Verbose 'Could not set Mark-of-the-Web (non-NTFS?). Continuing.'
        }
    }

    function Stop-Whonix([string]$Gateway, [string]$Workstation) {
        foreach ($vm in @($Workstation, $Gateway)) {
            Write-Step "Powering off $vm…"
            try {
                Invoke-VBoxManage @('controlvm', $vm, 'poweroff') | Out-Null 
            }
            catch {
            }
        }
    }
    #endregion

    #region Main
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $cache = Join-Path $env:ProgramData 'WhonixCache'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null

    Initialize-VirtualBox
    $script:VBoxManage = Get-VBoxManagePath

    $links = Get-WhonixLatestOva -OverrideUrl:$WhonixOvaUrl
    $ovaPath = Get-WhonixOvaAndVerify -OvaUrl $links.Ova -ShaUrl $links.ShaUrl -CacheDir $cache

    Import-Whonix -OvaPath $ovaPath -Force:$ForceReimport -GWName $GatewayName -WSName $WorkstationName

    $resolved = Get-WhonixVmNames
    $gwName = if ($GatewayName) {
        $GatewayName 
    }
    else {
        $resolved.Gateway 
    }
    $wsName = if ($WorkstationName) {
        $WorkstationName 
    }
    else {
        $resolved.Workstation 
    }

    if (-not $gwName -or -not $wsName) {
        $all = (Invoke-VBoxManage @('list', 'vms')) -join "`n"
        throw "Whonix VMs not found after import. Found VMs:`n$all"
    }

    if ($HardenVM) {
        Set-WorkstationHardening -VMName $wsName 
    }

    Start-Whonix -Gateway $gwName -Workstation $wsName -Headless:$Headless

    # Prepare guest paths
    $guestUser = if ($GuestCredential) {
        $GuestCredential.UserName 
    }
    else {
        'user' 
    }
    $guestPass = if ($GuestCredential) {
        $GuestCredential.Password 
    }
    else {
        $null 
    }
    $guestDir = "/home/$guestUser/whonix_downloads"
    $leaf = [System.IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = ('download_' + [Guid]::NewGuid().ToString('N')) 
    }
    $guestOut = "$guestDir/$leaf"

    Write-Step 'Creating guest directory and fetching over Tor inside Workstation…'
    Invoke-GuestCommand -VM $wsName -Username $guestUser -Password $guestPass -Exe '/bin/mkdir' -CommandArgs @('-p', $guestDir)
    Invoke-GuestCommand -VM $wsName -Username $guestUser -Password $guestPass -Exe '/usr/bin/curl' -CommandArgs @(
        '--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url
    )

    # Copy to host quarantine
    $hostOut = Join-Path $OutputDir (Split-Path $guestOut -Leaf)
    Write-Step "Copying file from guest to host quarantine: $hostOut"
    Copy-GuestItem -VM $wsName -Username $guestUser -Password $guestPass -GuestPath $guestOut -HostPath $hostOut

    Set-MarkOfTheWeb -Path $hostOut -RefUrl $Url
    $sha256 = (Get-FileHash -Path $hostOut -Algorithm SHA256).Hash
    Write-Information ("Saved: {0}`nSHA256: {1}" -f $hostOut, $sha256)

    Stop-Whonix -Gateway $gwName -Workstation $wsName
    Write-Ok 'Done. File quarantined.'
    #endregion
}
