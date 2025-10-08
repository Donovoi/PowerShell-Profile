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
    if ($WhatIfOnly -or $Backend -eq 'VMware') {
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
        }; throw "winget configure timed out after $TimeoutSec s." 
    }
    if ($p.ExitCode -ne 0) {
        $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
        throw "winget configure failed (code $($p.ExitCode)).`n$out`n$err"
    }
    Write-Verbose '[OK] DSC apply completed.'
    return $ConfigFile
}

function Invoke-WhonixOnionDownload {
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

    # --- common helpers ---
    $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
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
            $uri = [Uri]$u; if ($uri.Scheme -notin @('http', 'https')) {
                return $false
            }
            if ($uri.Host -notmatch '\.onion$') {
                return $false
            }
            return ($uri.Host -match '(?:^|\.)([a-z2-7]{56})\.onion$') 
        }
        catch {
            $false 
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
        $out
    }
    function Set-MarkOfTheWeb([string]$Path, [string]$RefUrl) {
        try {
            Set-Content -LiteralPath $Path -Stream Zone.Identifier -Value "[ZoneTransfer]`nZoneId=3`nReferrerUrl=$RefUrl`nHostUrl=$RefUrl" 
        }
        catch {
        }
    }

    # --- OVA discovery/verification ---
    function Get-WhonixLatestOva([string]$Override) {
        if ($Override) {
            return @{Ova = $Override; ShaUrl = "$Override.sha512sums" } 
        }
        Write-Step 'Discovering latest Whonix OVA from official page…'
        $pageUrl = 'https://www.whonix.org/wiki/VirtualBox'
        $page = Invoke-WebRequest -UseBasicParsing -Uri $pageUrl
        $ova = $page.Links | Where-Object { $_.href -match '\.ova$' -and $_.href -match '(?i)Whonix.*(Xfce|CLI)' } | Select-Object -ExpandProperty href -First 1
        if (-not $ova) {
            $m = [regex]::Matches($page.Content, 'href="(?<u>https?://[^"]+?\.ova)"', 'IgnoreCase')
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
            $u = [Uri]$OvaUrl; $dir = $u.AbsoluteUri.Substring(0, $u.AbsoluteUri.LastIndexOf('/') + 1); $alt = $dir + 'SHA512SUMS'
            $shaPath = Join-Path $CacheDir 'SHA512SUMS'; Invoke-WebRequest -UseBasicParsing -Uri $alt -OutFile $shaPath
        }

        if ($DoSig) {
            Write-Step 'Verifying checksum signature…'
            $asc = "$ShaUrl.asc"; $sig = "$ShaUrl.sig"
            $ascPath = Join-Path $CacheDir (Split-Path $asc -Leaf)
            $sigPath = Join-Path $CacheDir (Split-Path $sig -Leaf)
            $haveAsc = $false; $haveSig = $false
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $asc -OutFile $ascPath; $haveAsc = $true 
            }
            catch {
            }
            if (-not $haveAsc) {
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri $sig -OutFile $sigPath; $haveSig = $true 
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
                    throw 'signify not found in PATH.' 
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
        Write-Ok 'Checksum verified.'; $ovaPath
    }

    # --- VirtualBox helpers ---
    $script:VBoxManage = $null
    function Get-VBoxManagePath {
        foreach ($p in @("$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe", "$env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe")) {
            if (Test-Path $p) {
                return $p 
            } 
        }
        $c = Get-Command VBoxManage.exe -EA SilentlyContinue; if ($c) {
            return $c.Source 
        }
        throw 'VBoxManage.exe not found.'
    }
    function Invoke-VBoxManage([string[]]$parts) {
        $out = & $script:VBoxManage @parts 2>&1; if ($LASTEXITCODE -ne 0) {
            throw "VBoxManage failed ($LASTEXITCODE): $($parts -join ' ')`n$out" 
        } $out 
    }
    function Import-WhonixVirtualBox([string]$OvaPath, [switch]$Force, [string]$GW = 'Whonix-Gateway', [string]$WS = 'Whonix-Workstation') {
        Write-Step 'Checking for existing Whonix VMs…'
        $vms = Invoke-VBoxManage @('list', 'vms'); $gwExists = $vms -match '(?i)whonix.*gateway'; $wsExists = $vms -match '(?i)whonix.*workstation'
        if (($gwExists -and $wsExists) -and -not $Force) {
            Write-Ok 'Whonix VMs already present.'; return 
        }
        Write-Step 'Importing Whonix OVA (creates Gateway + Workstation)…'
        Invoke-VBoxManage @('import', $OvaPath, '--vsys', '0', '--eula', 'accept', '--vsys', '1', '--eula', 'accept', '--vsys', '0', '--vmname', $GW, '--vsys', '1', '--vmname', $WS) | Out-Null
        Write-Ok 'Import complete.'
    }
    function Get-WhonixVmNamesVirtualBox {
        $names = @{Gateway = $null; Workstation = $null }; $list = Invoke-VBoxManage @('list', 'vms')
        foreach ($line in $list) {
            $n = ($line -split '"')[1]; if (-not $n) {
                continue
            }; $l = $n.ToLowerInvariant()
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
        foreach ($opts in @(@('modifyvm', $vm, '--clipboard-mode', 'disabled'), @('modifyvm', $vm, '--drag-and-drop', 'disabled'), @('modifyvm', $vm, '--vrde', 'off'), @('modifyvm', $vm, '--audio', 'none'))) {
            try {
                Invoke-VBoxManage $opts | Out-Null 
            }
            catch {
            } 
        }
    }
    function Start-WhonixVirtualBox([string]$gw, [string]$ws, [switch]$Headless) {
        $t = $Headless ? @('--type', 'headless') : @()
        Invoke-VBoxManage (@('startvm', $gw) + $t) | Out-Null; Invoke-VBoxManage (@('startvm', $ws) + $t) | Out-Null
        Invoke-VBoxManage @('guestproperty', 'wait', $ws, '/VirtualBox/GuestAdd/Version', '--timeout', '600000') | Out-Null
        Write-Ok 'Guest Additions ready.'
    }
    function Invoke-GuestCommandVBox([string]$vm, [string]$user, [securestring]$pass, [string]$exe, [string[]]$cmd) {
        $base = @('guestcontrol', $vm, 'run', '--username', $user, '--exe', $exe, '--wait-stdout', '--wait-stderr', '--timeout', '600000', '--')
        if ($PSBoundParameters.ContainsKey('pass') -and $pass) {
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b); $base = @('guestcontrol', $vm, 'run', '--username', $user, '--password', $plain, '--exe', $exe, '--wait-stdout', '--wait-stderr', '--timeout', '600000', '--') 
            }
            finally {
                if ($b -ne [IntPtr]::Zero) {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
                } 
            } 
        }
        Invoke-VBoxManage ($base + $cmd) | Out-Null
    }
    function Copy-FromGuestVBox([string]$vm, [string]$user, [securestring]$pass, [string]$guest, [string]$HostName) {
        $base = @('guestcontrol', $vm, 'copyfrom', '--username', $user, $guest, $HostName)
        if ($PSBoundParameters.ContainsKey('pass') -and $pass) {
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b); $base = @('guestcontrol', $vm, 'copyfrom', '--username', $user, '--password', $plain, $guest, $HostName) 
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

    # --- VMware helpers ---
    $script:Vmrun = $null; $script:Ovftool = $null
    function Resolve-VMwareTooling {
        Write-Step '[*] Resolving vmrun.exe & ovftool.exe…'
        $candVmrun = @("$env:ProgramFiles(x86)\VMware\VMware Workstation\vmrun.exe", "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe", "$env:ProgramFiles(x86)\VMware\VMware VIX\vmrun.exe", "$env:ProgramFiles\VMware\VMware Player\vmrun.exe")
        $candOvftool = @("$env:ProgramFiles\VMware\VMware OVF Tool\ovftool.exe", "$env:ProgramFiles(x86)\VMware\VMware Workstation\OVFTool\ovftool.exe")
        $vmrunCmd = Get-Command vmrun.exe -EA SilentlyContinue; $ovfCmd = Get-Command ovftool.exe -EA SilentlyContinue
        if ($vmrunCmd) {
            $script:Vmrun = $vmrunCmd.Source 
        }
        else {
            $script:Vmrun = ($candVmrun | Where-Object { Test-Path $_ } | Select-Object -First 1) 
        }
        if ($ovfCmd) {
            $script:Ovftool = $ovfCmd.Source 
        }
        else {
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
        $out = & $script:Vmrun @parts 2>&1; if ($LASTEXITCODE -ne 0) {
            throw "vmrun failed ($LASTEXITCODE): $($parts -join ' ')`n$out" 
        } $out 
    }
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

    function Convert-Ova-To-Vmx-WithFallback([string]$OvaPath, [string]$BaseDir, [switch]$Force) {
        # 1) Try ovftool directly on the OVA.
        try {
            Write-Step 'Converting OVA to VMware VMX (direct ovftool)…'
            if (Test-Path $BaseDir -and $Force) {
                Remove-Item -Recurse -Force $BaseDir -EA SilentlyContinue 
            }
            New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
            Invoke-Proc $script:Ovftool @('--acceptAllEulas', '--skipManifestCheck', '--lax', '--allowExtraConfig', "`"$OvaPath`"", "`"$BaseDir`"") | Out-Null
            $vmx = Get-ChildItem -Path $BaseDir -Recurse -Filter *.vmx -EA SilentlyContinue
            if ($vmx.Count -ge 2) {
                return @{ Gateway = ($vmx | Where-Object { $_.Name -match '(?i)gateway' } | Select-Object -First 1).FullName; Workstation = ($vmx | Where-Object { $_.Name -match '(?i)workstation' } | Select-Object -First 1).FullName } 
            }
            if ($vmx.Count -ge 1) {
                throw 'ovftool produced fewer than two VMX files; Whonix OVA is a multi-VM vApp.' 
            }
        }
        catch {
            $msg = $_.ToString()
            # Known: OVF Tool does not support OVF 2.0 (VirtualBox exports 2.x) → fall back via VirtualBox export to OVF 1.0.
            Write-Warn "Direct ovftool conversion failed; falling back via VirtualBox export to OVF 1.0. Details: $msg"
            # 2) Ensure VirtualBox exists (DSC apply).
            try {
                Invoke-WinGetConfiguration -Backend VirtualBox | Out-Null 
            }
            catch {
            }
            $script:VBoxManage = Get-VBoxManagePath
            # 3) Import OVA into VirtualBox (creates both VMs).
            Import-WhonixVirtualBox -OvaPath $OvaPath -Force:$true
            $names = Get-WhonixVmNamesVirtualBox
            if (-not $names.Gateway -or -not $names.Workstation) {
                throw 'VirtualBox import succeeded but VM names not detected.' 
            }
            # 4) Export each VM as OVF 1.0.
            $tmpOut = Join-Path $BaseDir '_ovf10'
            New-Item -ItemType Directory -Force -Path $tmpOut | Out-Null
            $gwOvF = Join-Path $tmpOut 'Whonix-Gateway.ovf'
            $wsOvF = Join-Path $tmpOut 'Whonix-Workstation.ovf'
            Write-Step 'Exporting VirtualBox VMs as OVF 1.0…'
            Invoke-VBoxManage @('export', $names.Gateway, '--ovf10', '--output', $gwOvF, '--options', 'manifest,nomacs') | Out-Null
            Invoke-VBoxManage @('export', $names.Workstation, '--ovf10', '--output', $wsOvF, '--options', 'manifest,nomacs') | Out-Null
            # 5) Convert OVF 1.0 → VMX with ovftool.
            Write-Step 'Converting OVF 1.0 to VMX with ovftool…'
            $gwDir = Join-Path $BaseDir 'Whonix-Gateway'; $wsDir = Join-Path $BaseDir 'Whonix-Workstation'
            New-Item -ItemType Directory -Force -Path $gwDir, $wsDir | Out-Null
            Invoke-Proc $script:Ovftool @('--acceptAllEulas', '--lax', '--allowExtraConfig', "`"$gwOvF`"", "`"$gwDir`"") | Out-Null
            Invoke-Proc $script:Ovftool @('--acceptAllEulas', '--lax', '--allowExtraConfig', "`"$wsOvF`"", "`"$wsDir`"") | Out-Null
            $gwVmx = (Get-ChildItem -Path $gwDir -Filter *.vmx | Select-Object -First 1).FullName
            $wsVmx = (Get-ChildItem -Path $wsDir -Filter *.vmx | Select-Object -First 1).FullName
            if (-not $gwVmx -or -not $wsVmx) {
                throw 'ovftool did not produce VMX files from OVF 1.0.' 
            }
            return @{ Gateway = $gwVmx; Workstation = $wsVmx }
        }
    }

    function Start-WhonixVMware([string]$GwVmx, [string]$WsVmx, [switch]$Headless) {
        $mode = $Headless ? 'nogui' : 'gui'
        Write-Step 'Starting Gateway (VMware)…'; Invoke-Vmrun @('-T', 'ws', 'start', "`"$GwVmx`"", $mode) | Out-Null
        Write-Step 'Starting Workstation (VMware)…'; Invoke-Vmrun @('-T', 'ws', 'start', "`"$WsVmx`"", $mode) | Out-Null
        Write-Step 'Waiting for VMware Tools in Workstation…'
        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 5; $state = (& $script:Vmrun -T ws checkToolsState "`"$WsVmx`"" 2>$null) | Out-String
            if ($state -match '(?i)running|installed') {
                break 
            } 
        } while ((Get-Date) -lt $deadline)
        if ($state -notmatch '(?i)running|installed') {
            throw 'VMware Tools not running in Workstation. Install open-vm-tools to continue.' 
        }
        Write-Ok 'VMware Tools detected.'
    }
    function Invoke-GuestCommandVMware([string]$Vmx, [pscredential]$Cred, [string]$Exe, [string[]]$CmdParts) {
        if (-not $Cred) {
            throw 'GuestCredential is required for VMware guest operations.' 
        }
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password); $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
        try {
            Invoke-Vmrun @('-T', 'ws', '-gu', $Cred.UserName, '-gp', $plain, 'runProgramInGuest', "`"$Vmx`"", $Exe)+$CmdParts | Out-Null 
        }
        finally {
            if ($b -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) 
            } 
        }
    }
    function Copy-FromGuestVMware([string]$Vmx, [pscredential]$Cred, [string]$GuestPath, [string]$HostNamePath) {
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Cred.Password); $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
        try {
            Invoke-Vmrun @('-T', 'ws', '-gu', $Cred.UserName, '-gp', $plain, 'CopyFileFromGuestToHost', "`"$Vmx`"", $GuestPath, "`"$HostNamePath`"") | Out-Null 
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

    # --- destroy path ---
    if ($PSCmdlet.ParameterSetName -eq 'Destroy') {
        Write-Step 'Destroying any Whonix VMs on both backends…'
        try {
            $script:VBoxManage = Get-VBoxManagePath; & $script:VBoxManage list vms | ForEach-Object { $n = ($_ -split '"')[1]; if ($n -and $n -match '(?i)whonix') {
                    & $script:VBoxManage controlvm "$n" poweroff 2>$null; & $script:VBoxManage unregistervm "$n" --delete 2>$null 
                } }; Write-Ok 'VirtualBox Whonix VMs removed.' 
        }
        catch {
        }
        try {
            $base = Join-Path $env:ProgramData 'Whonix-VMware'; if (Test-Path $base) {
                Resolve-VMwareTooling; Get-ChildItem -Path $base -Recurse -Filter *.vmx -EA SilentlyContinue | ForEach-Object { try {
                        & $script:Vmrun -T ws stop "`"$($_.FullName)`"" hard 2>$null 
                    }
                    catch {
                    } }; Remove-Item -Recurse -Force $base -EA SilentlyContinue 
            }; Write-Ok 'VMware Whonix VMs removed.' 
        }
        catch {
        }
        return
    }

    # --- run path ---
    if (-not (Test-OnionUrl $Url)) {
        throw 'Url must be a valid v3 .onion URL (56-char base32 host).' 
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    if (-not $SkipDSC) {
        $null = Invoke-WinGetConfiguration -Backend $Backend -ConfigFile $DSCConfigPath -WhatIfOnly:($Backend -eq 'VMware') 
    }

    $cacheRoot = Join-Path $env:ProgramData 'WhonixCache'; New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    $links = Get-WhonixLatestOva -Override:$WhonixOvaUrl
    $ova = Get-WhonixOvaAndVerify -OvaUrl $links.Ova -ShaUrl $links.ShaUrl -CacheDir $cacheRoot -DoSig:$VerifySignature -SigPub:$SignifyPubKeyPath

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
    $guestOut = "$guestDir/$leaf"; $HostNameOut = Join-Path $OutputDir $leaf

    if ($Backend -eq 'VirtualBox') {
        $script:VBoxManage = Get-VBoxManagePath
        Import-WhonixVirtualBox -OvaPath $ova -Force:$ForceReimport
        $names = Get-WhonixVmNamesVirtualBox
        if (-not $names.Gateway -or -not $names.Workstation) {
            $all = (Invoke-VBoxManage @('list', 'vms')) -join "`n"; throw "Whonix VMs not found after import. Found:`n$all" 
        }
        if ($HardenVM) {
            Set-WorkstationHardeningVirtualBox -vm $names.Workstation 
        }
        Start-WhonixVirtualBox -gw $names.Gateway -ws $names.Workstation -Headless:$Headless
        Invoke-GuestCommandVBox -vm $names.Workstation -user $guestUser -pass $guestPass -exe '/bin/mkdir' -cmd @('-p', $guestDir)
        Invoke-GuestCommandVBox -vm $names.Workstation -user $guestUser -pass $guestPass -exe '/usr/bin/curl' -cmd @('--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url)
        Copy-FromGuestVBox -vm $names.Workstation -user $guestUser -pass $guestPass -guest $guestOut -host $HostNameOut
        Set-MarkOfTheWeb -Path $HostNameOut -RefUrl $Url
        $sha256 = (Get-FileHash -Path $HostNameOut -Algorithm SHA256).Hash; Write-Ok "Saved: $HostNameOut"; Write-Ok "SHA256: $sha256"
        Stop-WhonixVirtualBox -gw $names.Gateway -ws $names.Workstation
    }
    else {
        Resolve-VMwareTooling
        if (-not $GuestCredential) {
            throw 'VMware backend requires -GuestCredential and running VMware Tools inside the Workstation.' 
        }
        $paths = Convert-Ova-To-Vmx-WithFallback -OvaPath $ova -BaseDir $VMwareBaseDir -Force:$ForceReimport

        # Patch networking (Gateway: NAT+Host-only; Workstation: Host-only)
        Set-VmxNet $paths.Gateway @{
            'ethernet0.present' = 'TRUE'; 'ethernet0.connectionType' = 'custom'; 'ethernet0.vnet' = $VMwareNatVnet; 'ethernet0.virtualDev' = 'e1000e'; 'ethernet0.startConnected' = 'TRUE'
            'ethernet1.present' = 'TRUE'; 'ethernet1.connectionType' = 'custom'; 'ethernet1.vnet' = $VMwareHostOnlyVnet; 'ethernet1.virtualDev' = 'e1000e'; 'ethernet1.startConnected' = 'TRUE'
        }
        Set-VmxNet $paths.Workstation @{
            'ethernet0.present' = 'TRUE'; 'ethernet0.connectionType' = 'custom'; 'ethernet0.vnet' = $VMwareHostOnlyVnet; 'ethernet0.virtualDev' = 'e1000e'; 'ethernet0.startConnected' = 'TRUE'
            'ethernet1.present' = 'FALSE'
        }

        Start-WhonixVMware -GwVmx $paths.Gateway -WsVmx $paths.Workstation -Headless:$Headless
        Invoke-GuestCommandVMware -Vmx $paths.Workstation -Cred $GuestCredential -Exe '/bin/mkdir' -CmdParts @('-p', $guestDir)
        Invoke-GuestCommandVMware -Vmx $paths.Workstation -Cred $GuestCredential -Exe '/usr/bin/curl' -CmdParts @('--fail', '-L', '--retry', '10', '--retry-delay', '5', '--retry-connrefused', '--output', $guestOut, $Url)
        Copy-FromGuestVMware -Vmx $paths.Workstation -Cred $GuestCredential -GuestPath $guestOut -HostPath $HostNameOut
        Set-MarkOfTheWeb -Path $HostNameOut -RefUrl $Url
        $sha256 = (Get-FileHash -Path $HostNameOut -Algorithm SHA256).Hash; Write-Ok "Saved: $HostNameOut"; Write-Ok "SHA256: $sha256"
        Stop-WhonixVMware -GwVmx $paths.Gateway -WsVmx $paths.Workstation
    }
}
