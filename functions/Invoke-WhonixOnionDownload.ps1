function Invoke-WhonixOnionDownload {
    <#
.SYNOPSIS
Safely downloads a file from a v3 .onion URL through Whonix (Gateway + Workstation) using VirtualBox or VMware Workstation.

.DESCRIPTION
This cmdlet is declarative and idempotent. It first applies a WinGet/DSC v3 configuration to ensure required tools
are present (VirtualBox or VMware tooling + optional GPG/signify), then:

  1) Discovers the latest Whonix OVA for VirtualBox (or uses -WhonixOvaUrl) and its *.sha512sums file.
  2) (Optional) Verifies the checksum file signature (.asc via gpg, or .sig via signify).
  3) Verifies the OVA SHA-512 against the checksum file.
  4) Imports Whonix:
     - VirtualBox: single import creates Gateway + Workstation.
     - VMware: uses ovftool to make two VMX folders; NICs are patched so Gateway = NAT + Host-only; Workstation = Host-only.
  5) Boots Gateway then Workstation; waits for readiness (VBox: Guest Additions; VMware: Tools).
  6) In Workstation, uses Tor-wrapped curl to fetch the .onion URL.
  7) Copies file to host quarantine, applies Mark-of-the-Web, logs SHA-256.
  8) Powers off both VMs. Use -Destroy to remove Whonix VMs on BOTH backends.

The DSC step uses WinGet Configuration (DSC v3) under the hood:
- Documentation: WinGet Configuration + DSC v3 YAML schema and usage. (winget configure) 
- VirtualBox guestcontrol flags per VirtualBox 7.x manual.
- VMware vmrun and ovftool usage per VMware docs.
These are applied automatically unless -SkipDSC is provided, or you supply a custom -DSCConfigPath.

.PARAMETER Url
A valid v3 .onion URL (56-char base32 host). Example: http://<56chars>.onion/path/file.bin

.PARAMETER OutputDir
Host folder for the quarantined file.

.PARAMETER Backend
'VirtualBox' (default) or 'VMware'.

.PARAMETER Destroy
Stop and remove any Whonix VMs (VirtualBox + VMware) created by/for this function, then exit.

.PARAMETER WhonixOvaUrl
Optional OVA URL override. When absent, the cmdlet scrapes Whonix’s VirtualBox page to find a current OVA and <ova>.sha512sums.

.PARAMETER Headless
Start VMs without UI (VBox: --type headless; VMware: nogui).

.PARAMETER HardenVM
(VirtualBox) Disable clipboard/drag&drop, VRDE, and audio on the Workstation.

.PARAMETER ForceReimport
Force re-import / reconversion even if Whonix VMs already exist.

.PARAMETER GuestCredential
[PSCredential] for the guest user (usually 'user'). VMware guest operations require credentials and running VMware Tools.

.PARAMETER VerifySignature
Verify the checksum file’s signature before using it (.asc via gpg, or .sig via signify with -SignifyPubKeyPath).

.PARAMETER SignifyPubKeyPath
Public key to validate the *.sha512sums.sig when using -VerifySignature and a .sig is provided.

.PARAMETER DSCConfigPath
Optional path to a WinGet/DSC v3 YAML file to apply instead of the built-in default. If omitted, a built-in config is generated.

.PARAMETER SkipDSC
Skip the DSC configuration step (not recommended).

.PARAMETER VMwareNatVnet
VMware NAT vnet (default VMnet8).

.PARAMETER VMwareHostOnlyVnet
VMware Host-only vnet (default VMnet1).

.PARAMETER VMwareBaseDir
Folder for VMware VMX directories (default $Env:ProgramData\Whonix-VMware).

.EXAMPLE
Invoke-WhonixOnionDownload -Url 'http://<56char>.onion/payload.bin' -OutputDir 'D:\OnionQuarantine' -Headless -HardenVM -Verbose

.EXAMPLE
$cred = Get-Credential -UserName 'user' -Message 'Guest (Whonix Workstation)'
Invoke-WhonixOnionDownload -Backend VMware -Url 'http://<56char>.onion/file.bin' -OutputDir 'C:\Quarantine' -GuestCredential $cred -Headless -Verbose

.NOTES
- WinGet/DSC v3 reference for configuration files and the WinGetPackage resource is on Microsoft Learn.
- VirtualBox guestcontrol run flags in 7.x use --wait-stdout/--wait-stderr/--timeout (no --wait-exit).
- Whonix recommends verifying signature of the *.sha512sums and then the OVA’s SHA-512 against that file.
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

    # --------------------------- Utilities & safety ---------------------------
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    function Write-Step([string]$Msg) {
        Write-Verbose "[*] $Msg" 
    }
    function Write-Ok  ([string]$Msg) {
        Write-Verbose "[OK] $Msg" 
    }
    function Write-Warn([string]$Msg) {
        Write-Warning $Msg 
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
            return ($uri.Host -match '(?:^|\.)([a-z2-7]{56})\.onion$')
        }
        catch {
            return $false 
        }
    }

    function Invoke-Proc([string]$File, [string[]]$ProcArgs) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $File
        $psi.Arguments = ($ProcArgs -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        if ($p.ExitCode -ne 0) {
            throw "Command failed ($File $($ProcArgs -join ' '))`n$out`n$err" 
        }
        $out
    }

    function Set-MarkOfTheWeb([string]$Path, [string]$RefUrl) {
        try {
            Set-Content -Path $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3`nReferrerUrl=$RefUrl`nHostUrl=$RefUrl"
        }
        catch {
            Write-Verbose "MOTW failed (non-NTFS?): $($_.Exception.Message)" 
        }
    }

    # --------------------------- DSC (WinGet Configuration) ---------------------------
    function Get-EmbeddedDscYaml([string]$ChosenBackend, [switch]$IncludeVerifiers) {
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
  - resource: Microsoft.WinGet.DSC/WinGetPackage
    id: VMwareWorkstation
    directives:
      description: Ensure VMware Workstation Pro (if chosen) is installed
      securityContext: elevated
    settings:
      id: VMware.WorkstationPro
      source: winget
  - resource: Microsoft.WinGet.DSC/WinGetPackage
    id: Gpg4win
    directives:
      description: Install Gpg4win for OpenPGP verification
      securityContext: elevated
    settings:
      id: GnuPG.Gpg4win
      source: winget
  - resource: Microsoft.WinGet.DSC/WinGetPackage
    id: Signify
    directives:
      description: Install signify-openbsd for .sha512sums.sig verification
      securityContext: elevated
    settings:
      id: OpenBSD.signify
      source: winget
  configurationVersion: 0.2.0
"@
        # NOTE: We include both packages, but the backend you pick is what we’ll actually use later.
        # This keeps the DSC “one file fits all” and simple to trust/audit. See WinGet Configuration docs.
    }

    function Invoke-DscConfiguration([string]$YamlPath) {
        Write-Step "Applying WinGet/DSC configuration: $YamlPath"
        # winget configure handles DSC v3 resources; it runs elevated resources elevated.
        Invoke-Proc 'winget' @('configure', '--file', "`"$YamlPath`"", '--accept-configuration-agreements', '--disable-interactivity') | Out-Null
        Write-Ok 'DSC configuration applied.'
    }

    # --------------------------- OVA discovery & verification ---------------------------
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
            $ova = ($page.Links | Where-Object { $_.href -match '\.ova$' -and $_.href -match '(?i)Whonix.*(Xfce|CLI)' } |
                    Select-Object -ExpandProperty href -First 1)
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

    function Get-WhonixOvaAndVerify([string]$OvaUrl, [string]$ShaUrl, [string]$CacheDir, [switch]$DoSig, [string]$SigPub) {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        $ovaName = Split-Path $OvaUrl -Leaf
        $ovaPath = Join-Path $CacheDir $ovaName
        $shaPath = Join-Path $CacheDir (Split-Path $ShaUrl -Leaf)

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
            $u = [Uri]$OvaUrl
            $dir = $u.AbsoluteUri.Substring(0, $u.AbsoluteUri.LastIndexOf('/') + 1)
            $alt = $dir + 'SHA512SUMS'
            $shaPath = Join-Path $CacheDir 'SHA512SUMS'
            Invoke-WebRequest -UseBasicParsing -Uri $alt -OutFile $shaPath
        }

        if ($DoSig) {
            Write-Step 'Verifying checksum signature…'
            $ascUrl = "$ShaUrl.asc"; $sigUrl = "$ShaUrl.sig"
            $ascPath = Join-Path $CacheDir (Split-Path $ascUrl -Leaf)
            $sigPath = Join-Path $CacheDir (Split-Path $sigUrl -Leaf)
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
                $gpg = Get-Command gpg.exe -ErrorAction SilentlyContinue
                if (-not $gpg) {
                    throw 'OpenPGP signature found but gpg.exe missing (install Gpg4win).' 
                }
                & $gpg.Source --verify $ascPath $shaPath | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "OpenPGP signature verification failed: $ascPath" 
                }
                Write-Ok 'OpenPGP signature OK.'
            }
            elseif ($haveSig) {
                if (-not (Test-Path $SigPub)) {
                    throw 'Signify .sig found but -SignifyPubKeyPath missing.' 
                }
                $sigExe = (Get-Command signify.exe -ErrorAction SilentlyContinue) ?? (Get-Command signify-openbsd.exe -ErrorAction SilentlyContinue)
                if (-not $sigExe) {
                    throw 'signify not found in PATH (install OpenBSD.signify).' 
                }
                & $sigExe.Source -V -p $SigPub -x $sigPath -m $shaPath | Out-Null
                if ($LASTEXITCODE -ne 0) {
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

    # --------------------------- VirtualBox helpers ---------------------------
    $script:VBoxManage = $null

    function Get-VBoxManagePath {
        foreach ($p in @("$Env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe", "$Env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe")) {
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
    function Invoke-VBoxManage([string[]]$CommandParts) {
        $out = & $script:VBoxManage @CommandParts 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "VBoxManage failed ($LASTEXITCODE): $($CommandParts -join ' ')`n$out" 
        }
        $out
    }
    function Import-WhonixVirtualBox([string]$OvaPath, [switch]$Force, [string]$GWName = 'Whonix-Gateway', [string]$WSName = 'Whonix-Workstation') {
        Write-Step 'Checking for existing Whonix VMs…'
        $vms = Invoke-VBoxManage @('list', 'vms')
        $gwExists = $vms -match '(?i)whonix.*gateway'
        $wsExists = $vms -match '(?i)whonix.*workstation'
        if (($gwExists -and $wsExists) -and -not $Force) {
            Write-Ok 'Whonix VMs already present.'; return 
        }

        Write-Step 'Importing Whonix OVA (creates Gateway + Workstation)…'
        $importParts = @('import', $OvaPath,
            '--vsys', '0', '--eula', 'accept', '--vsys', '1', '--eula', 'accept',
            '--vsys', '0', '--vmname', $GWName,
            '--vsys', '1', '--vmname', $WSName)
        Invoke-VBoxManage $importParts | Out-Null
        Write-Ok 'Import complete.'
    }
    function Get-WhonixVmNamesVirtualBox {
        $names = @{ Gateway = $null; Workstation = $null }
        $list = Invoke-VBoxManage @('list', 'vms')
        foreach ($line in $list) {
            $n = ($line -split '"')[1]
            if (-not $n) {
                continue 
            }
            $l = $n.ToLowerInvariant()
            if (-not $names.Gateway -and $l -match 'whonix' -and $l -match 'gateway') {
                $names.Gateway = $n; continue 
            }
            if (-not $names.Workstation -and $l -match 'whonix' -and $l -match 'workstation') {
                $names.Workstation = $n; continue 
            }
        }
        $names
    }
    function Set-WorkstationHardeningVirtualBox([string]$VMName) {
        Write-Step "Hardening '$VMName' (clipboard/drag&drop/VRDE/audio)…"
        foreach ($opts in @(
                @('modifyvm', $VMName, '--clipboard-mode', 'disabled'),
                @('modifyvm', $VMName, '--clipboard', 'disabled'),
                @('modifyvm', $VMName, '--drag-and-drop', 'disabled'),
                @('modifyvm', $VMName, '--draganddrop', 'disabled'),
                @('modifyvm', $VMName, '--vrde', 'off'),
                @('modifyvm', $VMName, '--audio', 'none')
            )) {
            try {
                Invoke-VBoxManage $opts | Out-Null 
            }
            catch {
            }
        }
        Write-Ok 'Hardened (best-effort).'
    }
    function Start-WhonixVirtualBox([string]$Gateway, [string]$Workstation, [switch]$Headless) {
        $typeParts = $Headless ? @('--type', 'headless') : @()
        Write-Step "Starting Gateway '$Gateway'…"
        Invoke-VBoxManage (@('startvm', $Gateway) + $typeParts) | Out-Null
        Write-Step "Starting Workstation '$Workstation'…"
        Invoke-VBoxManage (@('startvm', $Workstation) + $typeParts) | Out-Null

        Write-Step 'Waiting for Guest Additions in Workstation…'
        Invoke-VBoxManage @('guestproperty', 'wait', $Workstation, '/VirtualBox/GuestAdd/Version', '--timeout', '600000') | Out-Null
        Write-Ok 'Guest Additions ready.'
    }
    function Invoke-GuestCommandVBox([string]$VM, [string]$User, [securestring]$Password, [string]$Exe, [string[]]$CmdParts) {
        $base = @('guestcontrol', $VM, 'run', '--username', $User, '--exe', $Exe, '--wait-stdout', '--wait-stderr', '--timeout', '600000', '--')
        if ($PSBoundParameters.ContainsKey('Password') -and $Password) {
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
                $base = @('guestcontrol', $VM, 'run', '--username', $User, '--password', $plain, '--exe', $Exe, '--wait-stdout', '--wait-stderr', '--timeout', '600000', '--')
            }
            finally {
                if ($b -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
                } 
            }
        }
        Invoke-VBoxManage ($base + $CmdParts) | Out-Null
    }
    function Copy-FromGuestVBox([string]$VM, [string]$User, [securestring]$Password, [string]$GuestPath, [string]$HostPath) {
        $base = @('guestcontrol', $VM, 'copyfrom', '--username', $User, $GuestPath, $HostPath)
        if ($PSBoundParameters.ContainsKey('Password') -and $Password) {
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
                $base = @('guestcontrol', $VM, 'copyfrom', '--username', $User, '--password', $plain, $GuestPath, $HostPath)
            }
            finally {
                if ($b -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
                } 
            }
        }
        Invoke-VBoxManage $base | Out-Null
    }
    function Stop-WhonixVirtualBox([string]$Gateway, [string]$Workstation) {
        foreach ($vm in @($Workstation, $Gateway)) {
            Write-Step "Powering off $vm…"
            try {
                Invoke-VBoxManage @('controlvm', $vm, 'poweroff') | Out-Null 
            }
            catch {
            }
        }
    }
    function Remove-WhonixVirtualBox {
        try {
            $list = & $script:VBoxManage list vms 2>$null
            if (-not $list) {
                return 
            }
            $targets = foreach ($line in $list) {
                $name = ($line -split '"')[1]
                if ($name -and ($name -match '(?i)whonix.*(gateway|workstation)')) {
                    $name 
                }
            }
            foreach ($vm in $targets | Select-Object -Unique) {
                try {
                    & $script:VBoxManage controlvm "$vm" poweroff 2>$null | Out-Null
                    & $script:VBoxManage unregistervm "$vm" --delete 2>$null | Out-Null
                    Write-Ok "Removed VirtualBox VM: $vm"
                }
                catch {
                    Write-Warn "Failed removing VirtualBox VM '$vm': $($_.Exception.Message)" 
                }
            }
        }
        catch {
        }
    }

    # --------------------------- VMware helpers ---------------------------
    $script:Vmrun = $null
    $script:Ovftool = $null

    function Get-VMwarePaths {
        foreach ($p in @("$Env:ProgramFiles(x86)\VMware\VMware Workstation\vmrun.exe", "$Env:ProgramFiles\VMware\VMware Workstation\vmrun.exe")) {
            if (Test-Path $p) {
                $script:Vmrun = $p; break 
            }
        }
        if (-not $script:Vmrun) {
            $c = Get-Command vmrun.exe -ErrorAction SilentlyContinue
            if ($c) {
                $script:Vmrun = $c.Source 
            }
        }
        foreach ($p in @("$Env:ProgramFiles\VMware\VMware OVF Tool\ovftool.exe", "$Env:ProgramFiles(x86)\VMware\VMware OVF Tool\ovftool.exe")) {
            if (Test-Path $p) {
                $script:Ovftool = $p; break 
            }
        }
        if (-not $script:Ovftool) {
            $c2 = Get-Command ovftool.exe -ErrorAction SilentlyContinue
            if ($c2) {
                $script:Ovftool = $c2.Source 
            }
        }
        if (-not $script:Vmrun) {
            throw 'vmrun.exe not found (install VMware Workstation Pro).' 
        }
        if (-not $script:Ovftool) {
            throw 'ovftool.exe not found (install VMware OVF Tool).' 
        }
    }
    function Invoke-Vmrun([string[]]$VmrunParts) {
        $out = & $script:Vmrun @VmrunParts 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "vmrun failed ($LASTEXITCODE): $($VmrunParts -join ' ')`n$out" 
        }
        $out
    }
    function Import-WhonixVMware([string]$OvaPath, [switch]$Force, [string]$BaseDir, [string]$NatVnet, [string]$HostOnlyVnet) {
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        $gwDir = Join-Path $BaseDir 'Whonix-Gateway'
        $wsDir = Join-Path $BaseDir 'Whonix-Workstation'
        $gwVmx = Join-Path $gwDir 'Whonix-Gateway.vmx'
        $wsVmx = Join-Path $wsDir 'Whonix-Workstation.vmx'

        if ((Test-Path $gwVmx) -and (Test-Path $wsVmx) -and -not $Force) {
            Write-Ok 'Whonix VMware VMs already present.'
            return @{ Gateway = $gwVmx; Workstation = $wsVmx }
        }

        Write-Step 'Converting OVA to VMware VMX (creates Gateway + Workstation)…'
        if (Test-Path $gwDir) {
            Remove-Item -Recurse -Force $gwDir 
        }
        if (Test-Path $wsDir) {
            Remove-Item -Recurse -Force $wsDir 
        }
        New-Item -ItemType Directory -Force -Path $gwDir, $wsDir | Out-Null

        Invoke-Proc $script:Ovftool @('--acceptAllEulas', '--skipManifestCheck', '--lax', '--allowExtraConfig', '--vsys=0', $OvaPath, $gwDir) | Out-Null
        Invoke-Proc $script:Ovftool @('--acceptAllEulas', '--skipManifestCheck', '--lax', '--allowExtraConfig', '--vsys=1', $OvaPath, $wsDir) | Out-Null

        $gwVmxFound = Get-ChildItem -Path $gwDir -Filter *.vmx | Select-Object -First 1
        $wsVmxFound = Get-ChildItem -Path $wsDir -Filter *.vmx | Select-Object -First 1
        if (-not $gwVmxFound -or -not $wsVmxFound) {
            throw 'OVF Tool did not produce VMX files as expected.' 
        }
        Move-Item -Force $gwVmxFound.FullName $gwVmx
        Move-Item -Force $wsVmxFound.FullName $wsVmx

        # Patch .vmx networking
        Write-Step 'Patching VMware .vmx NICs…'
        function Set-VmxNet($vmxPath, [hashtable]$Pairs) {
            $text = Get-Content -LiteralPath $vmxPath -Raw
            foreach ($k in $Pairs.Keys) {
                $rx = [regex]::Escape($k) + '\s*=\s*".*?"'
                if ($text -match $rx) {
                    $text = [regex]::Replace($text, $rx, ("$k = `"{0}`"" -f $Pairs[$k])) 
                }
                else {
                    $text += "`r`n$k = `"$($Pairs[$k])`"" 
                }
            }
            Set-Content -LiteralPath $vmxPath -Value $text -Encoding ASCII
        }
        Set-VmxNet $gwVmx @{
            'ethernet0.present' = 'TRUE'; 'ethernet0.connectionType' = 'custom'; 'ethernet0.vnet' = $NatVnet; 'ethernet0.virtualDev' = 'e1000e'; 'ethernet0.startConnected' = 'TRUE'
            'ethernet1.present' = 'TRUE'; 'ethernet1.connectionType' = 'custom'; 'ethernet1.vnet' = $HostOnlyVnet; 'ethernet1.virtualDev' = 'e1000e'; 'ethernet1.startConnected' = 'TRUE'
        }
        Set-VmxNet $wsVmx @{
            'ethernet0.present' = 'TRUE'; 'ethernet0.connectionType' = 'custom'; 'ethernet0.vnet' = $HostOnlyVnet; 'ethernet0.virtualDev' = 'e1000e'; 'ethernet0.startConnected' = 'TRUE'
            'ethernet1.present' = 'FALSE'
        }

        Write-Ok 'VMware import complete.'
        @{ Gateway = $gwVmx; Workstation = $wsVmx }
    }
    function Start-WhonixVMware([string]$GwVmx, [string]$WsVmx, [switch]$Headless) {
        $mode = $Headless ? 'nogui' : 'gui'
        Write-Step 'Starting Gateway (VMware)…'
        Invoke-Vmrun @('-T', 'ws', 'start', $GwVmx, $mode) | Out-Null
        Write-Step 'Starting Workstation (VMware)…'
        Invoke-Vmrun @('-T', 'ws', 'start', $WsVmx, $mode) | Out-Null

        Write-Step 'Waiting for VMware Tools in Workstation…'
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 5
            $state = (& $script:Vmrun -T ws checkToolsState $WsVmx 2>$null) | Out-String
            if ($state -match 'running') {
                break 
            }
        } while ((Get-Date) -lt $deadline)
        if ($state -notmatch 'running') {
            throw 'VMware Tools not running in Workstation. (Install open-vm-tools if needed.)' 
        }
        Write-Ok 'VMware Tools detected.'
    }
    function Invoke-GuestCommandVMware([string]$Vmx, [pscredential]$Cred, [string]$Exe, [string[]]$CmdParts) {
        if (-not $Cred) {
            throw 'GuestCredential is required for VMware guest operations.' 
        }
        $pBSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pBSTR)
        try {
            Invoke-Vmrun @('-T', 'ws', '-gu', $Cred.UserName, '-gp', $plain, 'runProgramInGuest', $Vmx, $Exe) + $CmdParts | Out-Null
        }
        finally {
            if ($pBSTR -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pBSTR) 
            }
        }
    }
    function Copy-FromGuestVMware([string]$Vmx, [pscredential]$Cred, [string]$GuestPath, [string]$HostPath) {
        $pBSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pBSTR)
        try {
            Invoke-Vmrun @('-T', 'ws', '-gu', $Cred.UserName, '-gp', $plain, 'CopyFileFromGuestToHost', $Vmx, $GuestPath, $HostPath) | Out-Null
        }
        finally {
            if ($pBSTR -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pBSTR) 
            }
        }
    }
    function Stop-WhonixVMware([string]$GwVmx, [string]$WsVmx) {
        foreach ($vmx in @($WsVmx, $GwVmx)) {
            if ($vmx -and (Test-Path $vmx)) {
                Write-Step "Stopping $([IO.Path]::GetFileName($vmx))…"
                try {
                    Invoke-Vmrun @('-T', 'ws', 'stop', $vmx, 'soft') | Out-Null 
                }
                catch {
                }
            }
        }
    }
    function Remove-WhonixVMware([string]$BaseDir) {
        try {
            if (Test-Path $BaseDir) {
                $vmx = Get-ChildItem -Path $BaseDir -Filter *.vmx -Recurse -ErrorAction SilentlyContinue
                foreach ($v in $vmx) {
                    try {
                        & $script:Vmrun -T ws stop $v.FullName hard 2>$null | Out-Null
                        & $script:Vmrun -T ws deleteVM $v.FullName 2>$null | Out-Null
                    }
                    catch {
                    }
                }
                try {
                    Remove-Item -Recurse -Force $BaseDir 
                }
                catch {
                }
                Write-Ok "Removed VMware Whonix folder: $BaseDir"
            }
        }
        catch {
        }
    }

    # --------------------------- Destroy path ---------------------------
    if ($PSCmdlet.ParameterSetName -eq 'Destroy') {
        Write-Step 'Destroying any Whonix VMs on both backends…'
        try {
            $script:VBoxManage = Get-VBoxManagePath; Remove-WhonixVirtualBox 
        }
        catch {
        }
        try {
            Get-VMwarePaths; Remove-WhonixVMware -BaseDir (Join-Path $Env:ProgramData 'Whonix-VMware') 
        }
        catch {
        }
        Write-Ok 'Destroy completed.'
        return
    }

    # --------------------------- Run path ---------------------------
    if (-not (Test-OnionUrl $Url)) {
        throw 'Url must be a valid v3 .onion URL (56-char base32 host).' 
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    # Apply DSC unless skipped (built-in YAML if -DSCConfigPath not provided)
    if (-not $SkipDSC) {
        $cache = Join-Path $Env:ProgramData 'WhonixCache'
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        $yamlToUse = if ($DSCConfigPath) {
            if (-not (Test-Path $DSCConfigPath)) {
                throw "DSCConfigPath not found: $DSCConfigPath" 
            }
            $DSCConfigPath
        }
        else {
            $defaultYaml = Join-Path $cache 'whonix.dsc.yaml'
            (Get-EmbeddedDscYaml -ChosenBackend $Backend -IncludeVerifiers) | Set-Content -LiteralPath $defaultYaml -Encoding UTF8
            $defaultYaml
        }
        Invoke-DscConfiguration -YamlPath $yamlToUse
    }

    # Locate tooling after DSC
    if ($Backend -eq 'VirtualBox') {
        $script:VBoxManage = Get-VBoxManagePath
    }
    else {
        Get-VMwarePaths
    }

    # Discover and verify OVA
    $cacheRoot = Join-Path $Env:ProgramData 'WhonixCache'
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

    $links = Get-WhonixLatestOva -Override:$WhonixOvaUrl
    $ova = Get-WhonixOvaAndVerify -OvaUrl $links.Ova -ShaUrl $links.ShaUrl -CacheDir $cacheRoot -DoSig:$VerifySignature -SigPub:$SignifyPubKeyPath

    # Guest paths
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
    $leaf = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = 'download_' + [Guid]::NewGuid().ToString('N') 
    }
    $guestOut = "$guestDir/$leaf"
    $hostOut = Join-Path $OutputDir $leaf

    if ($Backend -eq 'VirtualBox') {
        Import-WhonixVirtualBox -OvaPath $ova -Force:$ForceReimport
        $names = Get-WhonixVmNamesVirtualBox
        if (-not $names.Gateway -or -not $names.Workstation) {
            $all = (Invoke-VBoxManage @('list', 'vms')) -join "`n"
            throw "Whonix VMs not found after import. Found:`n$all"
        }
        if ($HardenVM) {
            Set-WorkstationHardeningVirtualBox -VMName $names.Workstation 
        }
        Start-WhonixVirtualBox -Gateway $names.Gateway -Workstation $names.Workstation -Headless:$Headless

        Write-Step 'Creating guest dir + Tor-wrapped fetch (VirtualBox)…'
        Invoke-GuestCommandVBox -VM $names.Workstation -User $guestUser -Password $guestPass -Exe '/bin/mkdir' -CmdParts @('-p', $guestDir)
        Invoke-GuestCommandVBox -VM $names.Workstation -User $guestUser -Password $guestPass -Exe '/usr/bin/curl' -CmdParts @('--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url)

        Write-Step "Copying back to host: $hostOut"
        Copy-FromGuestVBox -VM $names.Workstation -User $guestUser -Password $guestPass -GuestPath $guestOut -HostPath $hostOut

        Set-MarkOfTheWeb -Path $hostOut -RefUrl $Url
        $sha256 = (Get-FileHash -Path $hostOut -Algorithm SHA256).Hash
        Write-Ok "Saved: $hostOut"
        Write-Ok "SHA256: $sha256"

        Stop-WhonixVirtualBox -Gateway $names.Gateway -Workstation $names.Workstation
    }
    else {
        if (-not $GuestCredential) {
            throw 'VMware backend requires -GuestCredential and running VMware Tools inside the Workstation.'
        }
        $paths = Import-WhonixVMware -OvaPath $ova -Force:$ForceReimport -BaseDir $VMwareBaseDir -NatVnet $VMwareNatVnet -HostOnlyVnet $VMwareHostOnlyVnet
        Start-WhonixVMware -GwVmx $paths.Gateway -WsVmx $paths.Workstation -Headless:$Headless

        Write-Step 'Creating guest dir + Tor fetch (VMware)…'
        Invoke-GuestCommandVMware -Vmx $paths.Workstation -Cred $GuestCredential -Exe '/bin/mkdir' -CmdParts @('-p', $guestDir)
        Invoke-GuestCommandVMware -Vmx $paths.Workstation -Cred $GuestCredential -Exe '/usr/bin/curl' -CmdParts @('--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url)

        Write-Step "Copying back to host: $hostOut"
        Copy-FromGuestVMware -Vmx $paths.Workstation -Cred $GuestCredential -GuestPath $guestOut -HostPath $hostOut

        Set-MarkOfTheWeb -Path $hostOut -RefUrl $Url
        $sha256 = (Get-FileHash -Path $hostOut -Algorithm SHA256).Hash
        Write-Ok "Saved: $hostOut"
        Write-Ok "SHA256: $sha256"

        Stop-WhonixVMware -GwVmx $paths.Gateway -WsVmx $paths.Workstation
    }
}
