function Invoke-WhonixOnionDownload {
    <#
.SYNOPSIS
Safely downloads a file from a v3 .onion URL via Whonix (Gateway+Workstation) using VirtualBox or (experimental) VMware.

.DESCRIPTION
- Validates tooling with WinGet Configuration (DSC v3). For VMware we validate/test but **skip apply** on purpose. :contentReference[oaicite:1]{index=1}
- Finds latest Whonix OVA (or uses -WhonixOvaUrl); verifies SHA-512 and optionally the signature (.asc/.sig).
- Imports:
  * VirtualBox: OVA import creates both VMs (Gateway + Workstation). Uses `VBoxManage` guest ops. :contentReference[oaicite:2]{index=2}
  * VMware (experimental): uses **ovftool** to convert OVA and then **discovers .vmx files**; uses `vmrun`. (ovftool can convert OVA/OVF to `.vmx`.) :contentReference[oaicite:3]{index=3}
- Starts Gateway → Workstation, waits for guest readiness (VBox: Guest Additions; VMware: VMware Tools).
- Runs `curl` in the Workstation to fetch the `.onion` URL (torified by Whonix), copies to host, applies MOTW, prints SHA-256.
- `-Destroy` removes any Whonix VMs on both backends.

⚠️ **Note on VMware**: Whonix explicitly does **not** support VMware; images are provided for VirtualBox/KVM. VMware path here is best-effort and requires VMware Tools inside the guest; prefer VirtualBox for reliability. :contentReference[oaicite:4]{index=4}
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

        [Parameter(ParameterSetName = 'Run')][string]$VMwareBaseDir = (Join-Path $Env:ProgramData 'Whonix-VMware')
    )

    # ---- utils
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    function Write-Step([string]$m) {
        Write-Verbose "[*] $m" 
    }
    function Write-Ok([string]$m) {
        Write-Verbose "[OK] $m" 
    }
    function Write-Warn([string]$m) {
        Write-Warning $m 
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

    function Invoke-Proc([string]$File, [string[]]$ArgList) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $File; $psi.Arguments = ($ArgList -join ' ')
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi); $p.WaitForExit()
        $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
        if ($p.ExitCode -ne 0) {
            throw "Command failed ($File $($ArgList -join ' '))`n$out`n$err" 
        }
        return $out
    }

    function Set-MarkOfTheWeb([string]$Path, [string]$RefUrl) {
        try {
            Set-Content -Path $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3`nReferrerUrl=$RefUrl`nHostUrl=$RefUrl"
        }
        catch {
            Write-Verbose "MOTW skipped: $($_.Exception.Message)" 
        }
    }

    # ---- OVA discovery & verification
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
            Write-Step "Downloading OVA: $ovaName"; Invoke-WebRequest -UseBasicParsing -Uri $OvaUrl -OutFile $ovaPath 
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
            $alt = $dir + 'SHA512SUMS'; $shaPath = Join-Path $CacheDir 'SHA512SUMS'
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
                $gpg = Get-Command gpg.exe -EA SilentlyContinue; if (-not $gpg) {
                    throw 'OpenPGP signature found but gpg.exe missing.' 
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
                    throw 'signify not found on PATH.' 
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

    # ---- VirtualBox helpers
    $script:VBoxManage = $null
    function Get-VBoxManagePath {
        foreach ($p in @("$Env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe", "$Env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe")) {
            if (Test-Path $p) {
                return $p
            }
        }
        $c = Get-Command VBoxManage.exe -EA SilentlyContinue
        if ($c) {
            return $c.Source
        }
        throw 'VBoxManage.exe not found.'
    }
    function Invoke-VBoxManage([string[]]$Parts) {
        $out = & $script:VBoxManage @Parts 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "VBoxManage failed ($LASTEXITCODE): $($Parts -join ' ')`n$out" 
        }
        $out
    }
    function Import-WhonixVirtualBox([string]$Ova, [switch]$Force) {
        Write-Step 'Checking for existing Whonix VMs…'
        $vms = Invoke-VBoxManage @('list', 'vms')
        $gwExists = $vms -match '(?i)whonix.*gateway'
        $wsExists = $vms -match '(?i)whonix.*workstation'
        if (($gwExists -and $wsExists) -and -not $Force) {
            Write-Ok 'Whonix VMs already present.'; return 
        }
        Write-Step 'Importing OVA (creates Gateway + Workstation)…'
        Invoke-VBoxManage @('import', $Ova, '--vsys', '0', '--eula', 'accept', '--vsys', '1', '--eula', 'accept', '--vsys', '0', '--vmname', 'Whonix-Gateway', '--vsys', '1', '--vmname', 'Whonix-Workstation') | Out-Null
        Write-Ok 'Import complete.'
    }
    function Get-WhonixVmNamesVirtualBox {
        $names = @{Gateway = $null; Workstation = $null }
        $list = Invoke-VBoxManage @('list', 'vms')
        foreach ($line in $list) {
            $n = ($line -split '"')[1]; if (-not $n) {
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
    function Set-WorkstationHardeningVirtualBox([string]$VM) {
        foreach ($opts in @(
                @('modifyvm', $VM, '--clipboard-mode', 'disabled'),
                @('modifyvm', $VM, '--drag-and-drop', 'disabled'),
                @('modifyvm', $VM, '--vrde', 'off'),
                @('modifyvm', $VM, '--audio', 'none')
            )) {
            try {
                Invoke-VBoxManage $opts | Out-Null 
            }
            catch {
            } 
        }
        Write-Ok 'Hardened (best-effort).'
    }
    function Start-WhonixVirtualBox([string]$GW, [string]$WS, [switch]$Headless) {
        $t = $Headless ? @('--type', 'headless') : @()
        Invoke-VBoxManage (@('startvm', $GW) + $t) | Out-Null
        Invoke-VBoxManage (@('startvm', $WS) + $t) | Out-Null
        # wait for guest additions in WS
        Invoke-VBoxManage @('guestproperty', 'wait', $WS, '/VirtualBox/GuestAdd/Version', '--timeout', '600000') | Out-Null
        Write-Ok 'Guest Additions ready.'
    }
    function Invoke-GuestCommandVBox([string]$VM, [string]$User, [securestring]$Password, [string]$Exe, [string[]]$Arguments) {
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
        Invoke-VBoxManage ($base + $Arguments) | Out-Null
    }
    function Copy-FromGuestVBox([string]$VM, [string]$User, [securestring]$Password, [string]$Guest, [string]$Hostname) {
        $base = @('guestcontrol', $VM, 'copyfrom', '--username', $User, $Guest, $Hostname)
        if ($PSBoundParameters.ContainsKey('Password') -and $Password) {
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
                $base = @('guestcontrol', $VM, 'copyfrom', '--username', $User, '--password', $plain, $Guest, $Hostname)
            }
            finally {
                if ($b -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
                } 
            }
        }
        Invoke-VBoxManage $base | Out-Null
    }
    function Stop-WhonixVirtualBox([string]$GW, [string]$WS) {
        foreach ($vm in @($WS, $GW)) {
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
                $name = ($line -split '"')[1]; if ($name -and $name -match '(?i)whonix.*(gateway|workstation)') {
                    $name 
                } 
            }
            foreach ($vm in $targets | Select-Object -Unique) {
                try {
                    & $script:VBoxManage controlvm "$vm" poweroff 2>$null | Out-Null 
                }
                catch {
                }
                try {
                    & $script:VBoxManage unregistervm "$vm" --delete 2>$null | Out-Null 
                }
                catch {
                }
                Write-Ok "Removed VirtualBox VM: $vm"
            }
        }
        catch {
        }
    }

    # ---- VMware helpers (experimental)
    $script:Vmrun = $null; $script:Ovftool = $null
    function Resolve-VMwareTooling {
        Write-Step '[*] Resolving vmrun.exe & ovftool.exe…'
        $vmrun = (Get-Command vmrun.exe -EA SilentlyContinue)?.Source
        $ovf = (Get-Command ovftool.exe -EA SilentlyContinue)?.Source
        # Common extra path for ovftool
        if (-not $ovf) {
            $cand = 'C:\Program Files (x86)\VMware\VMware Workstation\OVFTool'
            if (Test-Path $cand) {
                $env:Path += ';' + $cand; $ovf = (Get-Command ovftool.exe -EA SilentlyContinue)?.Source 
            }
        }
        if ($vmrun) {
            $script:Vmrun = $vmrun 
        }
        if ($ovf) {
            $script:Ovftool = $ovf 
        }
        if (-not $script:Vmrun -or -not $script:Ovftool) {
            throw 'VMware tooling missing. Ensure vmrun.exe and ovftool.exe are installed and on PATH.'
        }
        Write-Ok "vmrun: $script:Vmrun"
        Write-Ok "ovftool: $script:Ovftool"
    }
    function Invoke-Vmrun([string[]]$Arguments) {
        $out = & $script:Vmrun @Args 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "vmrun failed ($LASTEXITCODE): $($Arguments -join ' ')`n$out" 
        }
        $out
    }
    function Import-WhonixVMware([string]$Ova, [switch]$Force, [string]$BaseDir) {
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        if (-not $Force -and (Get-ChildItem -Path $BaseDir -Recurse -Filter *.vmx -EA SilentlyContinue)) {
            Write-Ok 'Whonix VMware VMs already present.' 
            $vms = Get-ChildItem -Path $BaseDir -Recurse -Filter *.vmx | Select-Object -Expand FullName
            return $vms
        }
        Write-Step 'Converting OVA to VMware format (ovftool)…'
        # Remove old
        if (Test-Path $BaseDir) {
            Get-ChildItem $BaseDir -Force | Remove-Item -Recurse -Force -EA SilentlyContinue 
        }
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null

        # Ask ovftool to expand the OVA into a Workstation-friendly set; it often yields one folder per VM with .vmx files.
        Invoke-Proc $script:Ovftool @('--acceptAllEulas', '--skipManifestCheck', '--lax', '--allowExtraConfig', $Ova, $BaseDir) | Out-Null

        $vmx = Get-ChildItem -Path $BaseDir -Recurse -Filter *.vmx -EA SilentlyContinue | Select-Object -Expand FullName
        if (-not $vmx -or $vmx.Count -lt 2) {
            throw 'OVF Tool did not produce multiple .vmx as expected. This OVA is multi-VM and VMware import is not officially supported by Whonix. Try VirtualBox backend instead.'
        }
        $vmx
    }
    function Start-WhonixVMware([string[]]$Vmx, [switch]$Headless) {
        $mode = $Headless ? 'nogui' : 'gui'
        # crude order: start the one that contains 'Gateway' first if available
        $gw = $Vmx | Where-Object { $_ -match '(?i)gateway' } | Select-Object -First 1
        $ws = $Vmx | Where-Object { $_ -match '(?i)workstation' } | Select-Object -First 1
        if (-not $gw) {
            $gw = $Vmx[0] 
        }
        if (-not $ws) {
            $ws = ($Vmx | Where-Object { $_ -ne $gw } | Select-Object -First 1) 
        }

        Invoke-Vmrun @('-T', 'ws', 'start', $gw, $mode) | Out-Null
        Invoke-Vmrun @('-T', 'ws', 'start', $ws, $mode) | Out-Null

        # Wait for VMware Tools in WS
        Write-Step 'Waiting for VMware Tools in Workstation…'
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 5
            $s = (& $script:Vmrun -T ws checkToolsState $ws 2>$null) | Out-String
            if ($s -match '(?i)running|installed') {
                break 
            }
        } while ((Get-Date) -lt $deadline)
        if ($s -notmatch '(?i)running|installed') {
            throw 'VMware Tools not running in Workstation. Whonix-on-VMware is not supported; consider VirtualBox instead.'
        }
        @{ Gateway = $gw; Workstation = $ws }
    }
    function Invoke-GuestCommandVMware([string]$Vmx, [pscredential]$Cred, [string]$Exe, [string[]]$Arguments) {
        if (-not $Cred) {
            throw 'GuestCredential is required for VMware guest operations.' 
        }
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
        try {
            Invoke-Vmrun @('-T', 'ws', '-gu', $Cred.UserName, '-gp', $plain, 'runProgramInGuest', $Vmx, $Exe) + $Arguments | Out-Null 
        }
        finally {
            if ($b -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
            } 
        }
    }
    function Copy-FromGuestVMware([string]$Vmx, [pscredential]$Cred, [string]$Guest, [string]$Hostname) {
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
        try {
            Invoke-Vmrun @('-T', 'ws', '-gu', $Cred.UserName, '-gp', $plain, 'CopyFileFromGuestToHost', $Vmx, $Guest, $Hostname) | Out-Null 
        }
        finally {
            if ($b -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
            } 
        }
    }
    function Stop-WhonixVMware([string[]]$Vmx) {
        foreach ($v in $Vmx) {
            try {
                Invoke-Vmrun @('-T', 'ws', 'stop', $v, 'soft') | Out-Null 
            }
            catch {
            } 
        }
    }
    function Remove-WhonixVMware([string]$BaseDir) {
        try {
            if (Test-Path $BaseDir) {
                $vmx = Get-ChildItem -Path $BaseDir -Recurse -Filter *.vmx -EA SilentlyContinue
                foreach ($v in $vmx) {
                    try {
                        & $script:Vmrun -T ws stop $v.FullName hard 2>$null | Out-Null 
                    }
                    catch {
                    }
                    try {
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

    # ---- Destroy path
    if ($PSCmdlet.ParameterSetName -eq 'Destroy') {
        Write-Step 'Destroying any Whonix VMs on both backends…'
        try {
            $script:VBoxManage = Get-VBoxManagePath; Remove-WhonixVirtualBox 
        }
        catch {
        }
        try {
            Resolve-VMwareTooling; Remove-WhonixVMware -BaseDir (Join-Path $Env:ProgramData 'Whonix-VMware') 
        }
        catch {
        }
        Write-Ok 'Destroy completed.'; return
    }

    # ---- Run path
    if (-not (Test-OnionUrl $Url)) {
        throw 'Url must be a valid v3 .onion URL (56-char base32 host).' 
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    # DSC validate/test; apply only for VirtualBox
    Invoke-WinGetConfiguration -Backend $Backend

    $cacheRoot = Join-Path $Env:ProgramData 'WhonixCache'
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

    $links = Get-WhonixLatestOva -Override:$WhonixOvaUrl
    $ova = Get-WhonixOvaAndVerify -OvaUrl $links.Ova -ShaUrl $links.ShaUrl -CacheDir $cacheRoot -DoSig:$VerifySignature -SigPub:$SignifyPubKeyPath

    $guestUser = ($GuestCredential?.UserName) ?? 'user'
    $guestPass = $GuestCredential?.Password
    $guestDir = "/home/$guestUser/whonix_downloads"
    $leaf = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath); if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = 'download_{0}' -f ([Guid]::NewGuid().ToString('N')) 
    }
    $guestOut = "$guestDir/$leaf"
    $HostnameOut = Join-Path $OutputDir $leaf

    if ($Backend -eq 'VirtualBox') {
        $script:VBoxManage = Get-VBoxManagePath
        Import-WhonixVirtualBox -Ova $ova -Force:$ForceReimport
        $names = Get-WhonixVmNamesVirtualBox
        if (-not $names.Gateway -or -not $names.Workstation) {
            $all = (Invoke-VBoxManage @('list', 'vms')) -join "`n"; throw "Whonix VMs not found after import. Found:`n$all"
        }
        if ($HardenVM) {
            Set-WorkstationHardeningVirtualBox -VM $names.Workstation 
        }
        Start-WhonixVirtualBox -GW $names.Gateway -WS $names.Workstation -Headless:$Headless

        Write-Step 'Creating guest dir + Tor fetch (VirtualBox)…'
        Invoke-GuestCommandVBox -VM $names.Workstation -User $guestUser -Password $guestPass -Exe '/bin/mkdir' -Args @('-p', $guestDir)
        Invoke-GuestCommandVBox -VM $names.Workstation -User $guestUser -Password $guestPass -Exe '/usr/bin/curl' -Args @('--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url)

        Write-Step "Copying back to host: $HostnameOut"
        Copy-FromGuestVBox -VM $names.Workstation -User $guestUser -Password $guestPass -Guest $guestOut -Host $HostnameOut

        Set-MarkOfTheWeb -Path $HostnameOut -RefUrl $Url
        $sha256 = (Get-FileHash -Path $HostnameOut -Algorithm SHA256).Hash
        Write-Ok "Saved: $HostnameOut"
        Write-Ok "SHA256: $sha256"

        Stop-WhonixVirtualBox -GW $names.Gateway -WS $names.Workstation
    }
    else {
        Resolve-VMwareTooling
        $vmxList = Import-WhonixVMware -Ova $ova -Force:$ForceReimport -BaseDir $VMwareBaseDir
        $order = Start-WhonixVMware -Vmx $vmxList -Headless:$Headless

        if (-not $GuestCredential) {
            throw 'VMware backend requires -GuestCredential and running VMware Tools inside the Workstation.'
        }

        Write-Step 'Creating guest dir + Tor fetch (VMware)…'
        Invoke-GuestCommandVMware -Vmx $order.Workstation -Cred $GuestCredential -Exe '/bin/mkdir' -Args @('-p', $guestDir)
        Invoke-GuestCommandVMware -Vmx $order.Workstation -Cred $GuestCredential -Exe '/usr/bin/curl' -Args @('--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url)

        Write-Step "Copying back to host: $HostnameOut"
        Copy-FromGuestVMware -Vmx $order.Workstation -Cred $GuestCredential -GuestPath $guestOut -HostPath $HostnameOut

        Set-MarkOfTheWeb -Path $HostnameOut -RefUrl $Url
        $sha256 = (Get-FileHash -Path $HostnameOut -Algorithm SHA256).Hash
        Write-Ok "Saved: $HostnameOut"
        Write-Ok "SHA256: $sha256"

        Stop-WhonixVMware -Vmx $vmxList
    }
}

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
            # VMware: only a "test" Script resource (no-op set). We will SKIP APPLY below.
            $ConfigFile = Join-Path $cache 'whonix.vmware.dsc.yaml'
            @"
# yaml-language-server: \$schema=https://aka.ms/configuration-dsc-schema/0.2
properties:
  resources:
  - resource: PSDscResources/Script
    id: CheckVmwareTooling
    directives:
      description: Assert vmrun.exe and ovftool.exe are present
    settings:
      TestScript: '(Get-Command vmrun -EA SilentlyContinue) -and (Get-Command ovftool -EA SilentlyContinue)'
      GetScript: '@{ Vmrun = (Get-Command vmrun -EA SilentlyContinue | %% Source); OvfTool = (Get-Command ovftool -EA SilentlyContinue | %% Source) }'
      SetScript: 'return'
  configurationVersion: 0.2.0
"@ | Set-Content -Encoding UTF8 -Path $ConfigFile
        }
    }

    Write-Verbose '[*] Validating DSC…'
    & winget configure validate -f $ConfigFile --disable-interactivity --verbose-logs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'winget configure validate failed.' 
    }

    Write-Verbose '[*] Testing DSC (drift is OK)…'
    & winget configure test -f $ConfigFile --disable-interactivity --verbose-logs | Out-Null
    if ($LASTEXITCODE -ne 0 -and $Backend -eq 'VMware') {
        Write-Verbose "[!] DSC test reported drift for VMware tooling (vmrun/ovftool not on PATH). We'll probe known paths next."
    }
    elseif ($LASTEXITCODE -ne 0) {
        throw 'winget configure test indicates drift or an error.'
    }

    if ($WhatIfOnly) {
        return 
    }

    # APPLY only for VirtualBox (VMware has no MSI via WinGet; Script Set is a no-op by design).
    if ($Backend -eq 'VMware') {
        Write-Verbose '[*] Skipping DSC apply for VMware (intentional).'
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
        throw "winget configure timed out after $TimeoutSec s."
    }
    if ($p.ExitCode -ne 0) {
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        throw "winget configure failed (code $($p.ExitCode)).`n$out`n$err"
    }
    Write-Verbose '[OK] DSC apply completed.'
}
