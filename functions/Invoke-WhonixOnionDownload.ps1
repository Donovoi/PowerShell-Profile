function Invoke-WhonixOnionDownload {
    <#
.SYNOPSIS
Safely downloads a file from a .onion URL via Whonix (Gateway + Workstation) in VirtualBox.

.DESCRIPTION
Idempotently:
1) Installs VirtualBox (winget) if needed.
2) Discovers the latest Whonix VirtualBox OVA and its checksum; verifies SHA-512 (if checksum found).
3) Imports Whonix (creates Gateway + Workstation) if not already present.
4) Starts Gateway, then Workstation (optionally headless) and waits for Guest Additions readiness.
5) Runs Tor-isolated curl inside Workstation to fetch the .onion URL.
6) Copies the file to a host quarantine folder and writes Mark-of-the-Web (ZoneId=3).
7) Optionally hardens Workstation (disable clipboard, drag-and-drop, VRDE, audio).

.PARAMETER Url
A valid **v3** .onion URL (56-char base32 host). Example: http://<56chars>.onion/path/file.bin

.PARAMETER OutputDir
Host directory to store the quarantined file. Created if missing.

.PARAMETER WhonixOvaUrl
Optional explicit OVA URL. When omitted, the cmdlet auto-discovers from the official VirtualBox page.

.PARAMETER Headless
Start VMs headless.

.PARAMETER HardenVM
Disable clipboard and drag & drop on the Workstation for extra isolation.

.PARAMETER ForceReimport
Force re-import of the OVA even if Whonix VMs already exist.

.PARAMETER GuestCredential
Optional [pscredential] for the guest (e.g., user 'user'). If omitted, we pass only --username (no password).

.EXAMPLE
# Typical:
$cred = [pscredential]::new('user',(Read-Host 'Guest password' -AsSecureString))
Invoke-WhonixOnionDownload -Url 'http://<56char>.onion/tool.bin' -OutputDir 'D:\OnionQuarantine' -Headless -HardenVM -GuestCredential $cred

.EXAMPLE
# Passwordless (current Whonix 'user' often doesn’t require a password for guestcontrol):
Invoke-WhonixOnionDownload -Url 'http://<56char>.onion/file' -OutputDir 'C:\Quarantine' -Headless

.NOTES
- Uses approved PowerShell verbs to satisfy PSScriptAnalyzer.
- Uses PSCredential instead of a plain string password (PSAvoidUsingPlainTextForPassword).
- VirtualBox GuestControl & GuestProperty usage per Oracle docs.
- Whonix VirtualBox page is the “source of truth” for OVA discovery.

.LINK
Whonix for VirtualBox: https://www.whonix.org/wiki/VirtualBox
Oracle VBoxManage manual (guestcontrol/guestproperty): https://www.virtualbox.org/manual/ch08.html
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [string]$WhonixOvaUrl,
        [switch]$Headless,
        [switch]$HardenVM,
        [switch]$ForceReimport,
        [pscredential]$GuestCredential
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

    # central VBoxManage wrapper (argument array -> avoids quoting bugs)
    $script:VBoxManage = $null
    function Invoke-VBoxManage {
        param([Parameter(Mandatory = $true)][string[]]$CommandArgs)
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

    function Get-WhonixLatestOva {
        param([string]$OverrideUrl)
        if ($OverrideUrl) {
            return @{ Ova = $OverrideUrl; ShaUrl = $null } 
        }

        Write-Step 'Discovering latest Whonix OVA from official page…'
        $dlPage = 'https://www.whonix.org/wiki/VirtualBox'
        $page = Invoke-WebRequest -Uri $dlPage -UseBasicParsing -ErrorAction Stop
        $html = $page.Content

        # Try link collections first (when populated)
        $ova = $null; $sha = $null
        if ($page.Links) {
            $ova = ($page.Links | Where-Object { $_.href -match '\.ova$' -and $_.href -match '(?i)Whonix.*Xfce' } | Select-Object -First 1).href
            $sha = ($page.Links | Where-Object { $_.innerText -match '(?i)checksum|sha-?512' } | Select-Object -First 1).href
        }
        # Fallback: regex over HTML
        if (-not $ova) {
            $m = [regex]::Matches($html, 'href="(?<u>[^"]+?\.ova)"', 'IgnoreCase')
            if ($m.Count -gt 0) {
                $ova = $m[0].Groups['u'].Value 
            }
        }
        if (-not $sha) {
            $m2 = [regex]::Matches($html, 'href="(?<u>[^"]+?(checksum|sha(?:512)?)[^"]*)"', 'IgnoreCase')
            if ($m2.Count -gt 0) {
                $sha = $m2[0].Groups['u'].Value 
            }
        }

        if (-not $ova) {
            throw "Could not find an OVA link on $dlPage." 
        }

        # Normalize relative links with a safe base if BaseResponse is missing
        $base = if ($page.BaseResponse -and $page.BaseResponse.ResponseUri) {
            $page.BaseResponse.ResponseUri 
        }
        else {
            [uri]$dlPage 
        }
        if ($ova -notmatch '^https?://') {
            $ova = [Uri]::new($base, $ova).AbsoluteUri 
        }
        if ($sha -and $sha -notmatch '^https?://') {
            $sha = [Uri]::new($base, $sha).AbsoluteUri 
        }

        return @{ Ova = $ova; ShaUrl = $sha }
    }

    function Get-WhonixOvaAndVerify {
        param([string]$OvaUrl, [string]$ShaUrl, [string]$CacheDir)
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        $ovaName = Split-Path $OvaUrl -Leaf
        $ovaPath = Join-Path $CacheDir $ovaName
        $shaPath = if ($ShaUrl) {
            Join-Path $CacheDir (Split-Path $ShaUrl -Leaf) 
        }
        else {
            $null 
        }

        if (-not (Test-Path $ovaPath)) {
            Write-Step "Downloading OVA: $ovaName"
            Invoke-WebRequest -UseBasicParsing -Uri $OvaUrl -OutFile $ovaPath -ErrorAction Stop
        }
        else {
            Write-Ok "OVA already cached: $ovaPath" 
        }

        if ($ShaUrl) {
            if (-not (Test-Path $shaPath)) {
                Write-Step 'Downloading SHA-512 checksum file…'
                Invoke-WebRequest -UseBasicParsing -Uri $ShaUrl -OutFile $shaPath -ErrorAction Stop
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
            Write-Warning 'No checksum file link found; continuing without verification (see Whonix signature docs).'
        }
        return $ovaPath
    }

    function Import-Whonix {
        param([string]$OvaPath, [switch]$Force)
        Write-Step 'Checking for existing Whonix VMs…'
        $vms = Invoke-VBoxManage @('list', 'vms')
        $gwExists = $vms -match 'Whonix-.*Gateway'
        $wsExists = $vms -match 'Whonix-.*Workstation'
        if (($gwExists -and $wsExists) -and -not $Force) {
            Write-Ok 'Whonix VMs already present.'; return 
        }
        Write-Step 'Importing Whonix OVA (creates Gateway + Workstation)…'
        if ($PSCmdlet.ShouldProcess('Import OVA', "$OvaPath")) {
            Invoke-VBoxManage @('import', $OvaPath) | Out-Null
        }
        Write-Ok 'Import complete.'
    }

    function Set-WorkstationHardening {
        param([string]$VMName)
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

    function Start-Whonix {
        param([string]$Gateway, [string]$Workstation, [switch]$Headless)
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
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
            try {
                $cmd = @('guestcontrol', $VM, 'run', '--username', $Username, '--password', $plain, '--exe', $Exe, '--wait-stdout', '--wait-exit', '--') 
            }
            finally {
                if ($plain) {
                    [System.Array]::Clear([char[]]$plain, 0, $plain.Length) 
                } 
            }
        }
        Invoke-VBoxManage ($cmd + $CommandArgs) | Out-Null
    }

    function Copy-GuestItem {
        param([string]$VM, [string]$Username, [securestring]$Password, [string]$GuestPath, [string]$HostPath)
        $cmd = @('guestcontrol', $VM, 'copyfrom', '--username', $Username, $GuestPath, $HostPath)
        if ($PSBoundParameters.ContainsKey('Password') -and $Password) {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
            try {
                $cmd = @('guestcontrol', $VM, 'copyfrom', '--username', $Username, '--password', $plain, $GuestPath, $HostPath) 
            }
            finally {
                if ($plain) {
                    [System.Array]::Clear([char[]]$plain, 0, $plain.Length) 
                } 
            }
        }
        Invoke-VBoxManage $cmd | Out-Null
    }

    function Set-MarkOfTheWeb {
        param([string]$Path, [string]$RefUrl)
        Set-Content -Path $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3`nReferrerUrl=$RefUrl`nHostUrl=$RefUrl"
    }

    function Stop-Whonix {
        param([string]$Gateway, [string]$Workstation)
        foreach ($vm in @($Workstation, $Gateway)) {
            Write-Step "Powering off $vm…"
            try {
                Invoke-VBoxManage @('controlvm', $vm, 'poweroff') | Out-Null 
            }
            catch {
            }
        }
    }
    # endregion

    # region: main
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $cache = Join-Path $env:ProgramData 'WhonixCache'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null

    Initialize-VirtualBox
    $script:VBoxManage = Get-VBoxManagePath

    $links = Get-WhonixLatestOva -OverrideUrl:$WhonixOvaUrl  # discovery from Whonix page
    $ovaPath = Get-WhonixOvaAndVerify -OvaUrl $links.Ova -ShaUrl $links.ShaUrl -CacheDir $cache

    Import-Whonix -OvaPath $ovaPath -Force:$ForceReimport

    $gwName = (Invoke-VBoxManage @('list', 'vms') | Select-String 'Whonix-.*Gateway' | ForEach-Object { ($_ -split '"')[1] } | Select-Object -First 1)
    $wsName = (Invoke-VBoxManage @('list', 'vms') | Select-String 'Whonix-.*Workstation' | ForEach-Object { ($_ -split '"')[1] } | Select-Object -First 1)
    if (-not $gwName -or -not $wsName) {
        throw 'Whonix VMs not found after import.' 
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
    Invoke-GuestCommand -VM $wsName -Username $guestUser -Password $guestPass -Exe '/usr/bin/curl' -CommandArgs @('--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url)

    # Copy to host quarantine
    $hostOut = Join-Path $OutputDir (Split-Path $guestOut -Leaf)
    Write-Step "Copying file from guest to host quarantine: $hostOut"
    Copy-GuestItem -VM $wsName -Username $guestUser -Password $guestPass -GuestPath $guestOut -HostPath $hostOut

    Set-MarkOfTheWeb -Path $hostOut -RefUrl $Url
    $sha256 = (Get-FileHash -Path $hostOut -Algorithm SHA256).Hash
    Write-Ok "Downloaded file SHA256: $sha256"
    "Saved: $hostOut`nSHA256: $sha256`n" | Out-File -Append -FilePath (Join-Path $OutputDir 'download.log')

    Stop-Whonix -Gateway $gwName -Workstation $wsName
    Write-Ok "Done. File quarantined at: $hostOut"
    # endregion
}
