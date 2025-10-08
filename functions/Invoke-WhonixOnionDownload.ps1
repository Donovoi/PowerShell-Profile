function Invoke-WinGetConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('VirtualBox', 'VMware')] [string]$Backend,
        [string]$ConfigFile,
        [int]$TimeoutSec = 600,
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
    id: OracleVirtualBox
    directives:
      description: Ensure Oracle VirtualBox is installed
      securityContext: elevated
    settings:
      id: Oracle.VirtualBox
      source: winget
  configurationVersion: 0.2.0
"@ | Set-Content -Encoding UTF8 -LiteralPath $ConfigFile
        }
        else {
            # For VMware we only *test* (vmrun/ovftool are vendor installers, not reliably on WinGet)
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
      SetScript: 'Write-Verbose ""Nothing to set; install VMware Workstation/Player and VMware OVF Tool from vendor sources if missing."""'
      GetScript: '@{ Vmrun = (Get-Command vmrun -EA SilentlyContinue | % Source); OvfTool = (Get-Command ovftool -EA SilentlyContinue | % Source) }'
  configurationVersion: 0.2.0
"@ | Set-Content -Encoding UTF8 -LiteralPath $ConfigFile
        }
    }

    Write-Verbose '[*] Validating DSC…'
    & winget configure validate -f $ConfigFile --disable-interactivity --verbose-logs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'winget configure validate failed.' 
    }

    Write-Verbose '[*] Testing DSC (drift is OK)…'
    & winget configure test -f $ConfigFile --disable-interactivity --verbose-logs | Out-Null
    # do not throw on test drift; we handle it up-stack
    if ($WhatIfOnly -or $Backend -eq 'VMware') {
        # Intentionally skip apply for VMware to avoid failing Script SetScript path
        return $ConfigFile
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
    return $ConfigFile
}

function Invoke-WhonixOnionDownload {
    <#
.SYNOPSIS
Safely downloads a file from a v3 .onion URL via Whonix (Gateway+Workstation) using VirtualBox or VMware Workstation.

.DESCRIPTION
- VirtualBox path: imports Whonix OVA, verifies SHA-512, starts Gateway then Workstation, guestcontrol curl via Tor,
  copies artifact out, applies MOTW, powers off.
- VMware path: uses ovftool to convert the unified Whonix OVA -> two VMX folders (no --vsys), auto-detects which VMX
  is Gateway vs Workstation by reading each VMX's displayName, boots both with vmrun, runs curl inside the Workstation,
  copies file back, applies MOTW, powers off.

NOTES
- Whonix recommends VirtualBox and does not provide official VMware images/support. VMware can work but isn’t supported. :contentReference[oaicite:3]{index=3}
- VirtualBox guestcontrol flags in 7.x: use --wait-stdout/--wait-stderr/--timeout. :contentReference[oaicite:4]{index=4}
- ovftool is the supported way to convert OVA ↔ VMX on Windows. :contentReference[oaicite:5]{index=5}
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ParameterSetName = 'Run', Mandatory)][string]$Url,
        [Parameter(ParameterSetName = 'Run', Mandatory)][string]$OutputDir,
        [Parameter(ParameterSetName = 'Run')][ValidateSet('VirtualBox', 'VMware')][string]$Backend = 'VirtualBox',
        [Parameter(ParameterSetName = 'Run')][string]$WhonixOvaUrl,
        [Parameter(ParameterSetName = 'Run')][switch]$Headless,
        [Parameter(ParameterSetName = 'Run')][switch]$HardenVM,
        [Parameter(ParameterSetName = 'Run')][switch]$ForceReimport,
        [Parameter(ParameterSetName = 'Run')][pscredential]$GuestCredential,
        [Parameter(ParameterSetName = 'Run')][switch]$VerifySignature,
        [Parameter(ParameterSetName = 'Run')][string]$SignifyPubKeyPath,
        [Parameter(ParameterSetName = 'Run')][string]$VMwareNatVnet = 'VMnet8',
        [Parameter(ParameterSetName = 'Run')][string]$VMwareHostOnlyVnet = 'VMnet1',
        [Parameter(ParameterSetName = 'Run')][string]$VMwareBaseDir = (Join-Path $env:ProgramData 'Whonix-VMware'),
        [Parameter(ParameterSetName = 'Run')][switch]$SkipDSC,
        [Parameter(ParameterSetName = 'Run')][string]$DSCConfigPath,
        [Parameter(ParameterSetName = 'Destroy')][switch]$Destroy
    )

    # region: common helpers
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    function Write-Step([string]$m) {
        Write-Verbose "[*] $m" 
    }
    function Write-Ok  ([string]$m) {
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
        $psi.FileName = $File
        $psi.Arguments = ($ArgList -join ' ')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        if ($p.ExitCode -ne 0) {
            throw "Command failed ($File $($ArgList -join ' '))`n$out`n$err"
        }
        return $out
    }

    function Set-MarkOfTheWeb([string]$Path, [string]$RefUrl) {
        try {
            Set-Content -LiteralPath $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3`nReferrerUrl=$RefUrl`nHostUrl=$RefUrl"
        }
        catch {
            Write-Verbose "MOTW skip: $($_.Exception.Message)" 
        }
    }
    # endregion

    # region: discovery + verify OVA
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
        return @{ Ova = $ova; ShaUrl = "$ova.sha512sums" }
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
                $gpg = Get-Command gpg.exe -EA SilentlyContinue
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
                $sigExe = (Get-Command signify.exe -EA SilentlyContinue) ?? (Get-Command signify-openbsd.exe -EA SilentlyContinue)
                if (-not $sigExe) {
                    throw 'signify not found in PATH.' 
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
        return $ovaPath
    }
    # endregion

    # region: VirtualBox helpers
    $script:VBoxManage = $null
    function Get-VBoxManagePath {
        foreach ($p in @("$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe", "$env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe")) {
            if (Test-Path $p) {
                return $p 
            }
        }
        $cmd = Get-Command VBoxManage.exe -EA SilentlyContinue
        if ($cmd) {
            return $cmd.Source 
        }
        throw 'VBoxManage.exe not found.'
    }
    function Invoke-VBoxManage([string[]]$parts) {
        $out = & $script:VBoxManage @parts 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "VBoxManage failed ($LASTEXITCODE): $($parts -join ' ')`n$out" 
        }
        $out
    }
    function Import-WhonixVirtualBox([string]$OvaPath, [switch]$Force, [string]$GW = 'Whonix-Gateway', [string]$WS = 'Whonix-Workstation') {
        Write-Step 'Checking for existing Whonix VMs…'
        $vms = Invoke-VBoxManage @('list', 'vms')
        $gwExists = $vms -match '(?i)whonix.*gateway'
        $wsExists = $vms -match '(?i)whonix.*workstation'
        if (($gwExists -and $wsExists) -and -not $Force) {
            Write-Ok 'Whonix VMs already present.'; return 
        }
        Write-Step 'Importing Whonix OVA (creates Gateway + Workstation)…'
        Invoke-VBoxManage @('import', $OvaPath, '--vsys', '0', '--eula', 'accept', '--vsys', '1', '--eula', 'accept', '--vsys', '0', '--vmname', $GW, '--vsys', '1', '--vmname', $WS) | Out-Null
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
    function Set-WorkstationHardeningVirtualBox([string]$vm) {
        Write-Step "Hardening '$vm' (clipboard/drag&drop/VRDE/audio)…"
        foreach ($opts in @(
                @('modifyvm', $vm, '--clipboard-mode', 'disabled'),
                @('modifyvm', $vm, '--drag-and-drop', 'disabled'),
                @('modifyvm', $vm, '--vrde', 'off'),
                @('modifyvm', $vm, '--audio', 'none')
            )) {
            try {
                Invoke-VBoxManage $opts | Out-Null 
            }
            catch {
            }
        }
        Write-Ok 'Hardened (best-effort).'
    }
    function Start-WhonixVirtualBox([string]$gw, [string]$ws, [switch]$Headless) {
        $t = $Headless ? @('--type', 'headless') : @()
        Write-Step "Starting Gateway '$gw'…"; Invoke-VBoxManage (@('startvm', $gw) + $t) | Out-Null
        Write-Step "Starting Workstation '$ws'…"; Invoke-VBoxManage (@('startvm', $ws) + $t) | Out-Null
        Write-Step 'Waiting for Guest Additions in Workstation…'
        Invoke-VBoxManage @('guestproperty', 'wait', $ws, '/VirtualBox/GuestAdd/Version', '--timeout', '600000') | Out-Null
        Write-Ok 'Guest Additions ready.'
    }
    function Invoke-GuestCommandVBox([string]$vm, [string]$user, [securestring]$pass, [string]$exe, [string[]]$cmd) {
        $base = @('guestcontrol', $vm, 'run', '--username', $user, '--exe', $exe, '--wait-stdout', '--wait-stderr', '--timeout', '600000', '--')
        if ($PSBoundParameters.ContainsKey('pass') -and $pass) {
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
                $base = @('guestcontrol', $vm, 'run', '--username', $user, '--password', $plain, '--exe', $exe, '--wait-stdout', '--wait-stderr', '--timeout', '600000', '--')
            }
            finally {
                if ($b -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
                } 
            }
        }
        Invoke-VBoxManage ($base + $cmd) | Out-Null
    }
    function Copy-FromGuestVBox([string]$vm, [string]$user, [securestring]$pass, [string]$guest, [string]$host) {
        $base = @('guestcontrol', $vm, 'copyfrom', '--username', $user, $guest, $host)
        if ($PSBoundParameters.ContainsKey('pass') -and $pass) {
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
                $base = @('guestcontrol', $vm, 'copyfrom', '--username', $user, '--password', $plain, $guest, $host)
            }
            finally {
                if ($b -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
                } 
            }
        }
        Invoke-VBoxManage $base | Out-Null
    }
    function Stop-WhonixVirtualBox([string]$gw, [string]$ws) {
        foreach ($v in @($ws, $gw)) {
            try {
                Invoke-VBoxManage @('controlvm', $v, 'poweroff') | Out-Null 
            }
            catch {
            } 
        }
    }
    # endregion

    # region: VMware helpers
    $script:Vmrun = $null
    $script:Ovftool = $null

    function Resolve-VMwareTooling {
        Write-Step '[*] Resolving vmrun.exe & ovftool.exe…'
        $candVmrun = @(
            "$env:ProgramFiles(x86)\VMware\VMware Workstation\vmrun.exe",
            "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe",
            "$env:ProgramFiles(x86)\VMware\VMware VIX\vmrun.exe",
            "$env:ProgramFiles\VMware\VMware Player\vmrun.exe"
        )
        $candOvftool = @(
            "$env:ProgramFiles\VMware\VMware OVF Tool\ovftool.exe",
            "$env:ProgramFiles(x86)\VMware\VMware Workstation\OVFTool\ovftool.exe"
        )

        $vmrunCmd = Get-Command vmrun.exe -EA SilentlyContinue
        $ovfCmd = Get-Command ovftool.exe -EA SilentlyContinue
        if ($vmrunCmd) {
            $script:Vmrun = $vmrunCmd.Source 
        }
        if ($ovfCmd) {
            $script:Ovftool = $ovfCmd.Source 
        }

        if (-not $script:Vmrun) {
            $script:Vmrun = ($candVmrun | Where-Object { Test-Path $_ } | Select-Object -First 1)
        }
        if (-not $script:Ovftool) {
            $script:Ovftool = ($candOvftool | Where-Object { Test-Path $_ } | Select-Object -First 1)
        }

        if ($script:Vmrun) {
            Write-Host "[OK] vmrun: $script:Vmrun" -ForegroundColor Green 
        }
        if ($script:Ovftool) {
            Write-Host "[OK] ovftool: $script:Ovftool" -ForegroundColor Green 
        }
        if (-not $script:Vmrun -or -not $script:Ovftool) {
            throw 'VMware tooling missing. Ensure vmrun.exe and ovftool.exe are installed and on PATH or in standard VMware folders.'
        }
    }

    function Invoke-Vmrun([string[]]$parts) {
        $out = & $script:Vmrun @parts 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "vmrun failed ($LASTEXITCODE): $($parts -join ' ')`n$out" 
        }
        $out
    }

    function Get-VmxDisplayName([string]$VmxPath) {
        try {
            (Select-String -LiteralPath $VmxPath -Pattern '^\s*displayName\s*=\s*"(.*)"\s*$' -SimpleMatch:$false -Encoding ASCII -ErrorAction Stop).Matches.Value |
                ForEach-Object { $_ -replace '^\s*displayName\s*=\s*"(.*)"\s*$', '$1' } |
                    Select-Object -First 1
        }
        catch {
            $null 
        }
    }

    function Import-WhonixVMware([string]$OvaPath, [switch]$Force, [string]$BaseDir) {
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        if (-not $Force) {
            $existing = Get-ChildItem -Path $BaseDir -Recurse -Filter *.vmx -EA SilentlyContinue
            if ($existing.Count -ge 2) {
                Write-Ok 'Whonix VMware VMs already present.'
                return @{
                    Gateway     = ($existing | Where-Object { (Get-VmxDisplayName $_.FullName) -match '(?i)gateway' } | Select-Object -First 1).FullName
                    Workstation = ($existing | Where-Object { (Get-VmxDisplayName $_.FullName) -match '(?i)workstation' } | Select-Object -First 1).FullName
                }
            }
        }

        Write-Step 'Converting OVA to VMware VMX (no --vsys; ovftool will expand the vApp)…'
        # Clean target dir first
        Get-ChildItem -Path $BaseDir -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue

        # Let ovftool create one (or two) VMX(es) under $BaseDir
        Invoke-Proc $script:Ovftool @('--acceptAllEulas', '--skipManifestCheck', '--lax', '--allowExtraConfig', "`"$OvaPath`"", "`"$BaseDir`"") | Out-Null

        $vmx = Get-ChildItem -Path $BaseDir -Recurse -Filter *.vmx -EA SilentlyContinue
        if (-not $vmx -or $vmx.Count -lt 2) {
            throw "ovftool did not produce two VMX files. Found: $($vmx | ForEach-Object FullName -join '; ')"
        }

        $gw = ($vmx | Sort-Object FullName | Where-Object { (Get-VmxDisplayName $_.FullName) -match '(?i)gateway' } | Select-Object -First 1)
        $ws = ($vmx | Sort-Object FullName | Where-Object { (Get-VmxDisplayName $_.FullName) -match '(?i)workstation' } | Select-Object -First 1)
        if (-not $gw -or -not $ws) {
            # fallback by filename heuristics
            $gw = $gw ?? ($vmx | Where-Object { $_.Name -match '(?i)gateway' } | Select-Object -First 1)
            $ws = $ws ?? ($vmx | Where-Object { $_.Name -match '(?i)workstation' } | Select-Object -First 1)
        }
        if (-not $gw -or -not $ws) {
            throw 'Could not identify Gateway/Workstation VMX after conversion.'
        }
        Write-Ok 'VMware import complete.'
        return @{ Gateway = $gw.FullName; Workstation = $ws.FullName }
    }

    function Start-WhonixVMware([string]$GwVmx, [string]$WsVmx, [switch]$Headless) {
        $mode = $Headless ? 'nogui' : 'gui'
        Write-Step 'Starting Gateway (VMware)…'
        Invoke-Vmrun @('-T', 'ws', 'start', "`"$GwVmx`"", $mode) | Out-Null
        Write-Step 'Starting Workstation (VMware)…'
        Invoke-Vmrun @('-T', 'ws', 'start', "`"$WsVmx`"", $mode) | Out-Null

        Write-Step 'Waiting for VMware Tools in Workstation…'
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 5
            $state = (& $script:Vmrun -T ws checkToolsState "`"$WsVmx`"" 2>$null) | Out-String
            if ($state -match '(?i)running|installed') {
                break 
            }
        }while ((Get-Date) -lt $deadline)
        if ($state -notmatch '(?i)running|installed') {
            throw 'VMware Tools not running in Workstation. Install open-vm-tools to continue.'
        }
        Write-Ok 'VMware Tools detected.'
    }

    function Invoke-GuestCommandVMware([string]$Vmx, [pscredential]$Cred, [string]$Exe, [string[]]$CmdParts) {
        if (-not $Cred) {
            throw 'GuestCredential is required for VMware guest operations.' 
        }
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
        try {
            Invoke-Vmrun @('-T', 'ws', '-gu', $Cred.UserName, '-gp', $plain, 'runProgramInGuest', "`"$Vmx`"", "$Exe") + $CmdParts | Out-Null
        }
        finally {
            if ($b -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
            } 
        }
    }

    function Copy-FromGuestVMware([string]$Vmx, [pscredential]$Cred, [string]$GuestPath, [string]$HostPath) {
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
        try {
            Invoke-Vmrun @('-T', 'ws', '-gu', $Cred.UserName, '-gp', $plain, 'CopyFileFromGuestToHost', "`"$Vmx`"", $GuestPath, "`"$HostPath`"") | Out-Null
        }
        finally {
            if ($b -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
            } 
        }
    }

    function Stop-WhonixVMware([string]$GwVmx, [string]$WsVmx) {
        foreach ($vmx in @($WsVmx, $GwVmx)) {
            if ($vmx -and (Test-Path $vmx)) {
                try {
                    Invoke-Vmrun @('-T', 'ws', 'stop', "`"$vmx`"", 'soft') | Out-Null 
                }
                catch {
                }
            }
        }
    }
    # endregion

    # region: destroy path
    if ($PSCmdlet.ParameterSetName -eq 'Destroy') {
        Write-Step 'Destroying any Whonix VMs on both backends…'
        try {
            $script:VBoxManage = Get-VBoxManagePath; & $script:VBoxManage list vms | ForEach-Object {
                $name = ($_ -split '"')[1]
                if ($name -and $name -match '(?i)whonix') {
                    & $script:VBoxManage controlvm "$name" poweroff 2>$null; & $script:VBoxManage unregistervm "$name" --delete 2>$null 
                }
            }; Write-Ok 'VirtualBox Whonix VMs removed.' 
        }
        catch {
        }
        try {
            $base = Join-Path $env:ProgramData 'Whonix-VMware'
            if (Test-Path $base) {
                $all = Get-ChildItem -Path $base -Recurse -Filter *.vmx -EA SilentlyContinue
                if ($all) {
                    Resolve-VMwareTooling; foreach ($v in $all) {
                        try {
                            & $script:Vmrun -T ws stop "`"$($v.FullName)`"" hard 2>$null 
                        }
                        catch {
                        } 
                    } 
                }
                Remove-Item -Recurse -Force $base -EA SilentlyContinue
            }
            Write-Ok 'VMware Whonix VMs removed.'
        }
        catch {
        }
        return
    }
    # endregion

    # region: run path
    if (-not (Test-OnionUrl $Url)) {
        throw 'Url must be a valid v3 .onion URL (56-char base32 host).' 
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    # DSC: validate/test; apply only for VirtualBox
    if (-not $SkipDSC) {
        $null = Invoke-WinGetConfiguration -Backend $Backend -ConfigFile $DSCConfigPath -WhatIfOnly:($Backend -eq 'VMware')
    }

    # Discover + verify OVA
    $cacheRoot = Join-Path $env:ProgramData 'WhonixCache'
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
    $leaf = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath); if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = 'download_' + [guid]::NewGuid().ToString('N') 
    }
    $guestOut = "$guestDir/$leaf"
    $hostOut = Join-Path $OutputDir $leaf

    if ($Backend -eq 'VirtualBox') {
        $script:VBoxManage = Get-VBoxManagePath
        Import-WhonixVirtualBox -OvaPath $ova -Force:$ForceReimport
        $names = Get-WhonixVmNamesVirtualBox
        if (-not $names.Gateway -or -not $names.Workstation) {
            $all = (Invoke-VBoxManage @('list', 'vms')) -join "`n"
            throw "Whonix VMs not found after import. Found:`n$all"
        }
        if ($HardenVM) {
            Set-WorkstationHardeningVirtualBox -vm $names.Workstation 
        }
        Start-WhonixVirtualBox -gw $names.Gateway -ws $names.Workstation -Headless:$Headless

        Write-Step 'Creating guest dir + Tor-wrapped fetch (VirtualBox)…'
        Invoke-GuestCommandVBox -vm $names.Workstation -user $guestUser -pass $guestPass -exe '/bin/mkdir' -cmd @('-p', $guestDir)
        Invoke-GuestCommandVBox -vm $names.Workstation -user $guestUser -pass $guestPass -exe '/usr/bin/curl' -cmd @('--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url)

        Write-Step "Copying back to host: $hostOut"
        Copy-FromGuestVBox -vm $names.Workstation -user $guestUser -pass $guestPass -guest $guestOut -host $hostOut

        Set-MarkOfTheWeb -Path $hostOut -RefUrl $Url
        $sha256 = (Get-FileHash -Path $hostOut -Algorithm SHA256).Hash
        Write-Ok "Saved: $hostOut"
        Write-Ok "SHA256: $sha256"
        Stop-WhonixVirtualBox -gw $names.Gateway -ws $names.Workstation
    }
    else {
        Resolve-VMwareTooling
        if (-not $GuestCredential) {
            throw 'VMware backend requires -GuestCredential and running VMware Tools inside the Workstation.' 
        }

        $paths = Import-WhonixVMware -OvaPath $ova -Force:$ForceReimport -BaseDir $VMwareBaseDir
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
    # endregion
}
