function Invoke-WinGetConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('VirtualBox', 'VMware')] [string]$Backend,
        [string]$ConfigFile,
        [int]$TimeoutSec = 900,
        [switch]$WhatIfOnly
    )
    $ErrorActionPreference = 'Stop'
    $cache = Join-Path $env:ProgramData 'WhonixCache'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null

    if (-not $ConfigFile) {
        if ($Backend -eq 'VirtualBox') {
            $ConfigFile = Join-Path $cache 'whonix.vbox.dsc.yaml'
            @"
# yaml-language-server: \$schema=https://aka.ms/configuration-dsc-schema/0.2
properties:
  resources:
    - resource: Microsoft.WinGet.DSC/WinGetPackage
      id: VirtualBox
      directives:
        description: Ensure Oracle VirtualBox is installed
        securityContext: elevated
      settings:
        id: Oracle.VirtualBox
        source: winget
  configurationVersion: 0.2.0
"@ | Set-Content -Encoding UTF8 -Path $ConfigFile
        }
        else {
            # VMware is not reliably available via WinGet; we just _check_ tools via Script.
            $ConfigFile = Join-Path $cache 'whonix.vmware.dsc.yaml'
            @"
# yaml-language-server: \$schema=https://aka.ms/configuration-dsc-schema/0.2
properties:
  resources:
    - resource: PSDscResources/Script
      id: CheckVmwareTooling
      directives:
        description: Assert vmrun.exe and ovftool.exe are present on PATH
      settings:
        TestScript:  '(Get-Command vmrun -EA SilentlyContinue) -and (Get-Command ovftool -EA SilentlyContinue)'
        GetScript:   '@{ Vmrun = (Get-Command vmrun -EA SilentlyContinue | % Source); OvfTool = (Get-Command ovftool -EA SilentlyContinue | % Source) }'
        SetScript:   'Write-Verbose ""Nothing to set; install VMware Workstation/Player and VMware OVF Tool from vendor sources if missing."""'
  configurationVersion: 0.2.0
"@ | Set-Content -Encoding UTF8 -Path $ConfigFile
        }
    }

    Write-Verbose '[*] Validating DSC…'
    & winget configure validate -f $ConfigFile --disable-interactivity --verbose-logs | Write-Verbose
    if ($LASTEXITCODE -ne 0) {
        throw 'winget configure validate failed.' 
    }

    Write-Verbose '[*] Testing DSC (drift is OK)…'
    & winget configure test -f $ConfigFile --disable-interactivity --verbose-logs | Write-Verbose
    # Do NOT throw on drift for VMware. The Script resource only checks presence.

    if ($WhatIfOnly) {
        return 
    }

    Write-Verbose "[*] Applying WinGet/DSC configuration: $ConfigFile"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'winget.exe'
    $psi.Arguments = "configure -f `"$ConfigFile`" --accept-configuration-agreements --disable-interactivity --verbose-logs"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)

    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try {
            $p.Kill() 
        }
        catch {
        }
        $logRoot = (& winget --info | Select-String -SimpleMatch 'Logs:').ToString().Split(':')[-1].Trim()
        throw "winget configure timed out after $TimeoutSec s. Check logs in: $logRoot"
    }

    if ($p.ExitCode -ne 0) {
        $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
        throw "winget configure failed (code $($p.ExitCode)).`n$out`n$err"
    }
    Write-Verbose '[OK] DSC apply completed.'
}

function Invoke-WhonixOnionDownload {
    <#
.SYNOPSIS
Safely downloads a file from a v3 .onion URL through Whonix (Gateway + Workstation) using VirtualBox or VMware Workstation.

.DESCRIPTION
Idempotent workflow:
  1) Apply a WinGet/DSC v3 config to make sure the chosen backend tooling exists.
  2) Discover latest Whonix OVA (or use -WhonixOvaUrl) and its .sha512sums.
  3) (Optional) Verify checksum signature (.asc via gpg, or .sig via signify).
  4) Verify OVA SHA-512.
  5) Import Whonix (VirtualBox) or convert to VMX (VMware) and patch NICs.
  6) Boot Gateway → Workstation; wait for tools/guest-additions.
  7) In Workstation, Tor-wrapped `curl` to fetch the .onion file.
  8) Copy to host quarantine, set MOTW, log SHA-256, and power off VMs.

.PARAMETER Url
A valid v3 .onion URL.

.PARAMETER OutputDir
Host directory for the quarantined file.

.PARAMETER Backend
'VirtualBox' (default) or 'VMware'.

.PARAMETER Destroy
Remove any Whonix VMs from both backends, then exit.

.PARAMETER WhonixOvaUrl
Explicit OVA URL override.

.PARAMETER Headless
Headless start (VBox: --type headless; VMware: nogui).

.PARAMETER HardenVM
(VirtualBox) Disable clipboard/drag&drop, VRDE and audio on Workstation.

.PARAMETER ForceReimport
Force re-import / reconversion.

.PARAMETER GuestCredential
[PSCredential] for guest user (VMware requires this + open-vm-tools).

.PARAMETER VerifySignature
Verify the .sha512sums signature (.asc via gpg or .sig via signify).

.PARAMETER SignifyPubKeyPath
Public key to verify .sig.

.PARAMETER DSCConfigPath
Optional WinGet/DSC YAML to apply instead of the built-in default.

.PARAMETER SkipDSC
Skip the DSC step.

.PARAMETER VMwareNatVnet
VMware NAT network name (default VMnet8).

.PARAMETER VMwareHostOnlyVnet
VMware Host-only network name (default VMnet1).

.PARAMETER VMwareBaseDir
Where VMware VMX dirs are created (default %ProgramData%\Whonix-VMware).
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(ParameterSetName = 'Run', Mandatory)][string]$Url,
        [Parameter(ParameterSetName = 'Run', Mandatory)][string]$OutputDir,
        [Parameter(ParameterSetName = 'Run')][ValidateSet('VirtualBox', 'VMware')][string]$Backend = 'VirtualBox',
        [Parameter(ParameterSetName = 'Destroy')][switch]$Destroy,
        [Parameter(ParameterSetName = 'Run')][string]$WhonixOvaUrl,
        [Parameter(ParameterSetName = 'Run')][switch]$Headless,
        [Parameter(ParameterSetName = 'Run')][switch]$HardenVM,
        [Parameter(ParameterSetName = 'Run')][switch]$ForceReimport,
        [Parameter(ParameterSetName = 'Run')][pscredential]$GuestCredential,
        [Parameter(ParameterSetName = 'Run')][switch]$VerifySignature,
        [Parameter(ParameterSetName = 'Run')][string]$SignifyPubKeyPath,
        [Parameter(ParameterSetName = 'Run')][string]$DSCConfigPath,
        [Parameter(ParameterSetName = 'Run')][switch]$SkipDSC,
        [Parameter(ParameterSetName = 'Run')][string]$VMwareNatVnet = 'VMnet8',
        [Parameter(ParameterSetName = 'Run')][string]$VMwareHostOnlyVnet = 'VMnet1',
        [Parameter(ParameterSetName = 'Run')][string]$VMwareBaseDir = (Join-Path $Env:ProgramData 'Whonix-VMware')
    )

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    function Write-Step([string]$s) {
        Write-Verbose "[*] $s" 
    }
    function Write-Ok([string]$s) {
        Write-Verbose "[OK] $s" 
    }
    function Write-Warn([string]$s) {
        Write-Warning $s 
    }

    # --- helpers (trimmed to only the parts relevant to your issue) ---
    function Test-OnionUrl($u) {
        try {
            $uri = [Uri]$u
            if ($uri.Scheme -notin 'http', 'https') {
                return $false
            }
            if ($uri.Host -notmatch '\.onion$') {
                return $false
            }
            return ($uri.Host -match '(?:^|\.)([a-z2-7]{56})\.onion$')
        }
        catch {
            return $false 
        }
    }
    function Invoke-Proc([string]$File, [string[]]$Args) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $File; $psi.Arguments = ($Args -join ' ')
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi); $p.WaitForExit()
        $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
        if ($p.ExitCode -ne 0) {
            throw "Command failed ($File $($Args -join ' '))`n$out`n$err" 
        }
        $out
    }
    function Set-MarkOfTheWeb([string]$Path, [string]$Ref) {
        try {
            Set-Content -Path $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3`nReferrerUrl=$Ref`nHostUrl=$Ref" 
        }
        catch {
        } 
    }

    # --- VMware tool resolution (fix for your current error) ---
    $script:Vmrun = $null; $script:Ovftool = $null
    function Resolve-VMwareTooling {
        # Try PATH first
        $vm = Get-Command vmrun.exe -EA SilentlyContinue
        $ovf = Get-Command ovftool.exe -EA SilentlyContinue
        if (-not $ovf) {
            # Common Workstation layout
            $candidates = @(
                "$Env:ProgramFiles\VMware\VMware OVF Tool\ovftool.exe",
                "$Env:ProgramFiles(x86)\VMware\VMware OVF Tool\ovftool.exe",
                "$Env:ProgramFiles\VMware\VMware Workstation\OVFTool\ovftool.exe",
                "$Env:ProgramFiles(x86)\VMware\VMware Workstation\OVFTool\ovftool.exe"
            )
            foreach ($p in $candidates) {
                if (Test-Path $p) {
                    $ovf = [System.IO.FileInfo]$p; break 
                } 
            }
        }
        if (-not $vm) {
            $vmCand = @(
                "$Env:ProgramFiles\VMware\VMware Workstation\vmrun.exe",
                "$Env:ProgramFiles(x86)\VMware\VMware Workstation\vmrun.exe"
            )
            foreach ($p in $vmCand) {
                if (Test-Path $p) {
                    $vm = [System.IO.FileInfo]$p; break 
                } 
            }
        }
        if ($vm) {
            $script:Vmrun = $vm.Source 
        }
        if ($ovf) {
            $script:Ovftool = $ovf.Source 
        }
        return [bool]($script:Vmrun -and $script:Ovftool)
    }

    # --- VBox bits used later (unchanged logic) ---
    $script:VBoxManage = $null
    function Get-VBoxManagePath {
        foreach ($p in @("$Env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe", "$Env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe")) {
            if (Test-Path $p) {
                return $p 
            } 
        }
        $c = Get-Command VBoxManage.exe -EA SilentlyContinue; if ($c) {
            return $c.Source 
        } throw 'VBoxManage.exe not found.'
    }
    function Invoke-VBoxManage([string[]]$parts) {
        $out = & $script:VBoxManage @parts 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "VBoxManage failed ($LASTEXITCODE): $($parts -join ' ')`n$out" 
        }
        $out
    }

    # --- OVA discover/verify (unchanged) ---
    function Get-WhonixLatestOva([string]$Override) {
        if ($Override) {
            return @{ Ova = $Override; ShaUrl = "$Override.sha512sums" } 
        }
        Write-Step 'Discovering latest Whonix OVA from official page…'
        $pageUrl = 'https://www.whonix.org/wiki/VirtualBox'
        $page = Invoke-WebRequest -UseBasicParsing -Uri $pageUrl
        $html = $page.Content
        $ova = $null
        if ($page.Links) {
            $ova = ($page.Links | Where-Object { $_.href -match '\.ova$' -and $_.href -match '(?i)Whonix.*(Xfce|CLI)' } | Select-Object -Expand href -First 1) 
        }
        if (-not $ova) {
            $m = [regex]::Matches($html, 'href="(?<u>https?://[^"]+?\.ova)"', 'IgnoreCase')
            if ($m.Count -gt 0) {
                $ova = $m[0].Groups['u'].Value 
            }
        }
        if (-not $ova) {
            throw "Could not find an OVA link on $pageUrl" 
        }
        if ($ova -notmatch '^https?://') {
            $base = if ($page.BaseResponse -and $page.BaseResponse.ResponseUri) {
                $page.BaseResponse.ResponseUri 
            }
            else {
                [uri]$pageUrl 
            }
            $ova = [Uri]::new($base, $ova).AbsoluteUri
        }
        @{ Ova = $ova; ShaUrl = "$ova.sha512sums" }
    }
    function Get-WhonixOvaAndVerify([string]$OvaUrl, [string]$ShaUrl, [string]$Cache, [switch]$DoSig, [string]$SigPub) {
        New-Item -ItemType Directory -Force -Path $Cache | Out-Null
        $ovaName = Split-Path $OvaUrl -Leaf
        $ovaPath = Join-Path $Cache $ovaName
        $shaPath = Join-Path $Cache (Split-Path $ShaUrl -Leaf)
        if (-not (Test-Path $ovaPath)) {
            Write-Step "Downloading OVA: $ovaName"
            Invoke-WebRequest -UseBasicParsing -Uri $OvaUrl -OutFile $ovaPath
        }
        else {
            Write-Ok "OVA already cached: $ovaPath" 
        }

        Write-Step 'Downloading SHA-512 checksum…'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $ShaUrl -OutFile $shaPath 
        }
        catch {
            $u = [Uri]$OvaUrl; $dir = $u.AbsoluteUri.Substring(0, $u.AbsoluteUri.LastIndexOf('/') + 1)
            $alt = $dir + 'SHA512SUMS'; $shaPath = Join-Path $Cache 'SHA512SUMS'
            Invoke-WebRequest -UseBasicParsing -Uri $alt -OutFile $shaPath
        }

        if ($DoSig) {
            Write-Step 'Verifying checksum signature…'
            $ascUrl = "$ShaUrl.asc"; $sigUrl = "$ShaUrl.sig"
            $ascPath = Join-Path $Cache (Split-Path $ascUrl -Leaf)
            $sigPath = Join-Path $Cache (Split-Path $sigUrl -Leaf)
            $haveAsc = $false; $haveSig = $false
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $ascUrl -OutFile $ascPath; $haveAsc = $true 
            }
            catch {
            }
            if (-not $haveAsc) {
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri $sigUrl -OutFile $sigPath; $haveSig = $true 
                }
                catch {
                } 
            }
            if ($haveAsc) {
                $gpg = Get-Command gpg.exe -EA SilentlyContinue; if (-not $gpg) {
                    throw 'OpenPGP signature found but gpg.exe missing (install Gpg4win).' 
                }
                & $gpg.Source --verify $ascPath $shaPath | Out-Null; if ($LASTEXITCODE -ne 0) {
                    throw "OpenPGP signature verification failed: $ascPath" 
                }
                Write-Ok 'OpenPGP signature OK.'
            }
            elseif ($haveSig) {
                if (-not (Test-Path $SigPub)) {
                    throw 'Signify .sig found but -SignifyPubKeyPath missing.' 
                }
                $sigExe = (Get-Command signify.exe -EA SilentlyContinue) ?? (Get-Command signify-openbsd.exe -EA SilentlyContinue)
                if (-not $sigExe) {
                    throw 'signify not found in PATH (install OpenBSD.signify).' 
                }
                & $sigExe.Source -V -p $SigPub -x $sigPath -m $shaPath | Out-Null; if ($LASTEXITCODE -ne 0) {
                    throw "signify verification failed: $sigPath" 
                }
                Write-Ok 'signify signature OK.'
            }
            else {
                throw 'No .asc or .sig available to verify; aborting due to -VerifySignature.' 
            }
        }

        Write-Step 'Verifying SHA-512…'
        $content = Get-Content -LiteralPath $shaPath -Raw
        $line = ($content -split '\r?\n' | Where-Object { $_ -match [regex]::Escape($ovaName) }) | Select-Object -First 1
        $expected = if ($line) {
            ($line -split '\s+')[0] 
        }
        elseif ($content -match '([0-9a-f]{128})') {
            $Matches[1] 
        }
        else {
            $null 
        }
        if (-not $expected) {
            throw "Checksum file lacks SHA512 for $ovaName. Path: $shaPath" 
        }
        $actual = (Get-FileHash -Path $ovaPath -Algorithm SHA512).Hash.ToLower()
        if ($actual -ne $expected.ToLower()) {
            throw "Checksum mismatch! expected=$expected actual=$actual" 
        }
        Write-Ok 'Checksum verified.'
        $ovaPath
    }

    # ---------------- Destroy path ----------------
    if ($PSCmdlet.ParameterSetName -eq 'Destroy') {
        Write-Step 'Destroying any Whonix VMs on both backends…'
        try {
            $script:VBoxManage = Get-VBoxManagePath; $list = & $script:VBoxManage list vms 2>$null; foreach ($l in $list) {
                $n = ($l -split '"')[1]; if ($n -and ($n -match '(?i)whonix.*(gateway|workstation)')) {
                    & $script:VBoxManage controlvm $n poweroff 2>$null; & $script:VBoxManage unregistervm $n --delete 2>$null; Write-Ok "Removed VirtualBox VM: $n" 
                } 
            } 
        }
        catch {
        }
        try {
            # VMware: hunt VMX under default base dir
            $base = (Join-Path $Env:ProgramData 'Whonix-VMware')
            if (Test-Path $base) {
                $vmx = Get-ChildItem -Path $base -Filter *.vmx -Recurse -EA SilentlyContinue
                if (Resolve-VMwareTooling) {
                    foreach ($v in $vmx) {
                        & $script:Vmrun -T ws stop $v.FullName hard 2>$null; & $script:Vmrun -T ws deleteVM $v.FullName 2>$null 
                    }
                }
                Remove-Item -Recurse -Force $base -EA SilentlyContinue
                Write-Ok "Removed VMware Whonix folder: $base"
            }
        }
        catch {
        }
        return
    }

    # ---------------- Run path ----------------
    if (-not (Test-OnionUrl $Url)) {
        throw 'Url must be a valid v3 .onion URL (56-char base32 host).' 
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $cacheRoot = Join-Path $Env:ProgramData 'WhonixCache'; New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

    if (-not $SkipDSC) {
        Invoke-WinGetConfiguration -Backend $Backend -ConfigFile $DSCConfigPath 
    }

    if ($Backend -eq 'VMware') {
        if (-not (Resolve-VMwareTooling)) {
            throw 'VMware tooling missing. Please install VMware Workstation/Player (vmrun) and VMware OVF Tool (ovftool), or add their folders to PATH, then re-run.'
        }
        Write-Ok "vmrun: $script:Vmrun"
        Write-Ok "ovftool: $script:Ovftool"
    }
    else {
        $script:VBoxManage = Get-VBoxManagePath
    }

    # discover/verify OVA
    $links = Get-WhonixLatestOva -Override:$WhonixOvaUrl
    $ova = Get-WhonixOvaAndVerify -OvaUrl $links.Ova -ShaUrl $links.ShaUrl -Cache $cacheRoot -DoSig:$VerifySignature -SigPub:$SignifyPubKeyPath

    # guest paths
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
    $leaf = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath); if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = 'download_' + [Guid]::NewGuid().ToString('N') 
    }
    $guestOut = "$guestDir/$leaf"
    $hostOut = Join-Path $OutputDir $leaf

    if ($Backend -eq 'VirtualBox') {
        # import & start
        $vms = Invoke-VBoxManage @('list', 'vms')
        $gwExists = $vms -match '(?i)whonix.*gateway'
        $wsExists = $vms -match '(?i)whonix.*workstation'
        if ((-not $gwExists -or -not $wsExists) -or $ForceReimport) {
            Write-Step 'Importing Whonix OVA (creates Gateway + Workstation)…'
            Invoke-VBoxManage @('import', $ova, '--vsys', '0', '--eula', 'accept', '--vsys', '1', '--eula', 'accept', '--vsys', '0', '--vmname', 'Whonix-Gateway', '--vsys', '1', '--vmname', 'Whonix-Workstation') | Out-Null
        }
        else {
            Write-Ok 'Whonix VMs already present.' 
        }

        $names = @{Gateway = $null; Workstation = $null }
        foreach ($line in (Invoke-VBoxManage @('list', 'vms'))) {
            $n = ($line -split '"')[1]; if ($n -match '(?i)whonix.*gateway') {
                $names.Gateway = $n 
            }
            elseif ($n -match '(?i)whonix.*workstation') {
                $names.Workstation = $n 
            } 
        }
        if (-not $names.Gateway -or -not $names.Workstation) {
            throw 'Whonix VMs not found after import.' 
        }

        if ($HardenVM) {
            foreach ($opts in @(
                    @('modifyvm', $names.Workstation, '--clipboard-mode', 'disabled'),
                    @('modifyvm', $names.Workstation, '--drag-and-drop', 'disabled'),
                    @('modifyvm', $names.Workstation, '--vrde', 'off'),
                    @('modifyvm', $names.Workstation, '--audio', 'none')
                )) {
                try {
                    Invoke-VBoxManage $opts | Out-Null 
                }
                catch {
                } 
            }
        }

        Write-Step "Starting Gateway '$($names.Gateway)'…"; Invoke-VBoxManage @('startvm', $names.Gateway) + ($Headless ? @('--type', 'headless') : @()) | Out-Null
        Write-Step "Starting Workstation '$($names.Workstation)'…"; Invoke-VBoxManage @('startvm', $names.Workstation) + ($Headless ? @('--type', 'headless') : @()) | Out-Null
        # Wait for Guest Additions property (VirtualBox 7.x docs recommend guestproperty/guestcontrol flags like below). 
        Invoke-VBoxManage @('guestproperty', 'wait', $names.Workstation, '/VirtualBox/GuestAdd/Version', '--timeout', '600000') | Out-Null

        # run curl inside guest (no --wait-exit in VBox 7; use --wait-stdout/--wait-stderr)
        $base = @('guestcontrol', $names.Workstation, 'run', '--username', $guestUser, '--exe', '/bin/mkdir', '--wait-stdout', '--wait-stderr', '--timeout', '600000', '--')
        & $script:VBoxManage @base '-p' $guestDir | Out-Null
        $run = @('guestcontrol', $names.Workstation, 'run', '--username', $guestUser, '--exe', '/usr/bin/curl', '--wait-stdout', '--wait-stderr', '--timeout', '600000', '--', '--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url)
        & $script:VBoxManage @run | Out-Null

        # copy back
        $cp = @('guestcontrol', $names.Workstation, 'copyfrom', '--username', $guestUser, $guestOut, $hostOut); & $script:VBoxManage @cp | Out-Null
        Set-MarkOfTheWeb -Path $hostOut -RefUrl $Url
        $sha256 = (Get-FileHash -Path $hostOut -Algorithm SHA256).Hash; Write-Ok "Saved: $hostOut"; Write-Ok "SHA256: $sha256"

        foreach ($vm in @($names.Workstation, $names.Gateway)) {
            try {
                Invoke-VBoxManage @('controlvm', $vm, 'poweroff') | Out-Null 
            }
            catch {
            } 
        }
    }
    else {
        if (-not (Resolve-VMwareTooling)) {
            throw 'VMware tooling missing (vmrun/ovftool).' 
        }

        # Convert OVA into two VMX dirs
        New-Item -ItemType Directory -Force -Path $VMwareBaseDir | Out-Null
        $gwDir = Join-Path $VMwareBaseDir 'Whonix-Gateway'; $wsDir = Join-Path $VMwareBaseDir 'Whonix-Workstation'
        $gwVmx = Join-Path $gwDir 'Whonix-Gateway.vmx'; $wsVmx = Join-Path $wsDir 'Whonix-Workstation.vmx'
        if ($ForceReimport -or -not (Test-Path $gwVmx) -or -not (Test-Path $wsVmx)) {
            if (Test-Path $gwDir) {
                Remove-Item -Recurse -Force $gwDir 
            }
            if (Test-Path $wsDir) {
                Remove-Item -Recurse -Force $wsDir 
            }
            New-Item -ItemType Directory -Force -Path $gwDir, $wsDir | Out-Null
            Invoke-Proc $script:Ovftool @('--acceptAllEulas', '--skipManifestCheck', '--lax', '--allowExtraConfig', '--vsys=0', $ova, $gwDir) | Out-Null
            Invoke-Proc $script:Ovftool @('--acceptAllEulas', '--skipManifestCheck', '--lax', '--allowExtraConfig', '--vsys=1', $ova, $wsDir) | Out-Null
            $gwFound = Get-ChildItem -Path $gwDir -Filter *.vmx | Select-Object -First 1
            $wsFound = Get-ChildItem -Path $wsDir -Filter *.vmx | Select-Object -First 1
            if (-not $gwFound -or -not $wsFound) {
                throw 'OVF Tool did not produce VMX files as expected.' 
            }
            Move-Item -Force $gwFound.FullName $gwVmx; Move-Item -Force $wsFound.FullName $wsVmx
            # Patch NICs (Gateway NAT+HostOnly; Workstation HostOnly)
            foreach ($pair in @(@($gwVmx, @{
                            'ethernet0.present' = 'TRUE'; 'ethernet0.connectionType' = 'custom'; 'ethernet0.vnet' = $VMwareNatVnet; 'ethernet0.virtualDev' = 'e1000e'; 'ethernet0.startConnected' = 'TRUE'
                            'ethernet1.present' = 'TRUE'; 'ethernet1.connectionType' = 'custom'; 'ethernet1.vnet' = $VMwareHostOnlyVnet; 'ethernet1.virtualDev' = 'e1000e'; 'ethernet1.startConnected' = 'TRUE'
                        }), @($wsVmx, @{
                            'ethernet0.present' = 'TRUE'; 'ethernet0.connectionType' = 'custom'; 'ethernet0.vnet' = $VMwareHostOnlyVnet; 'ethernet0.virtualDev' = 'e1000e'; 'ethernet0.startConnected' = 'TRUE'
                            'ethernet1.present' = 'FALSE'
                        }))) {
                $vmx = $pair[0]; $kv = $pair[1]
                $text = Get-Content -LiteralPath $vmx -Raw
                foreach ($k in $kv.Keys) {
                    $rx = [regex]::Escape($k) + '\s*=\s*".*?"'
                    if ($text -match $rx) {
                        $text = [regex]::Replace($text, $rx, ("$k = `"{0}`"" -f $kv[$k])) 
                    }
                    else {
                        $text += "`r`n$k = `"$($kv[$k])`"" 
                    }
                }
                Set-Content -LiteralPath $vmx -Value $text -Encoding ASCII
            }
        }
        else {
            Write-Ok 'Whonix VMware VMs already present.' 
        }

        if (-not $GuestCredential) {
            throw 'VMware backend requires -GuestCredential and open-vm-tools in the guest.' 
        }

        $mode = if ($Headless) {
            'nogui'
        }
        else {
            'gui'
        }
        & $script:Vmrun -T ws start $gwVmx $mode | Out-Null
        & $script:Vmrun -T ws start $wsVmx $mode | Out-Null

        # Wait for VMware Tools
        $deadline = (Get-Date).AddMinutes(10); do {
            Start-Sleep 5; $state = (& $script:Vmrun -T ws checkToolsState $wsVmx 2>$null) | Out-String 
        } while ((Get-Date) -lt $deadline -and $state -notmatch 'running')
        if ($state -notmatch 'running') {
            throw 'VMware Tools not running in Workstation (install open-vm-tools).' 
        }

        # In-guest mkdir + curl
        $pB = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($GuestCredential.Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pB)
        try {
            & $script:Vmrun -T ws -gu $GuestCredential.UserName -gp $plain runProgramInGuest $wsVmx /bin/mkdir -noWait -p $guestDir 2>$null | Out-Null
            & $script:Vmrun -T ws -gu $GuestCredential.UserName -gp $plain runProgramInGuest $wsVmx /usr/bin/curl -noWait --fail -L --retry 10 --retry-delay 5 --retry-connrefused --output $guestOut $Url 2>$null | Out-Null
            # crude wait for file to appear
            Start-Sleep -Seconds 10
        }
        finally {
            if ($pB -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pB) 
            }
        }

        & $script:Vmrun -T ws -gu $GuestCredential.UserName -gp $plain CopyFileFromGuestToHost $wsVmx $guestOut $hostOut | Out-Null
        Set-MarkOfTheWeb -Path $hostOut -RefUrl $Url
        $sha256 = (Get-FileHash -Path $hostOut -Algorithm SHA256).Hash; Write-Ok "Saved: $hostOut"; Write-Ok "SHA256: $sha256"

        foreach ($v in @($wsVmx, $gwVmx)) {
            try {
                & $script:Vmrun -T ws stop $v soft 2>$null | Out-Null 
            }
            catch {
            } 
        }
    }
}
