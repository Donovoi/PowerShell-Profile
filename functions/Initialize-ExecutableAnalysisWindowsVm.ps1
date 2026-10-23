function Initialize-ExecutableAnalysisWindowsVm {
    <#
    .SYNOPSIS
    Creates a dedicated offline Windows 11 VM from caller-supplied installation media.
    .DESCRIPTION
    Creates only a new owned VirtualBox VM. Installs Windows and matching Guest Additions
    from local ISO files, creates a standard guest user, and takes a powered-off clean
    snapshot with all networking and host integrations disabled. Existing unrelated VMs
    are refused. Guest credentials are random and protected with Windows DPAPI.
    .PARAMETER IsoPath
    Existing Windows 11 x64 installation ISO. Required when creating the first VM.
    .PARAMETER ImageIndex
    Windows image to install. Index 6 is Pro in the validated Windows 11 client ISO;
    inspect your media with VBoxManage unattended detect when using another ISO.
    .EXAMPLE
    Initialize-ExecutableAnalysisWindowsVm -IsoPath C:\Downloads\Windows11.iso
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$VirtualMachineName='Profile-Analysis-Windows',
        [string]$IsoPath,
        [string]$StoragePath,
        [ValidateRange(1,100)][int]$ImageIndex=6,
        [ValidateRange(300,7200)][int]$ProvisioningTimeoutSeconds=3600
    )
    $ErrorActionPreference='Stop'
    if(-not $IsWindows){throw 'Windows VM setup requires PowerShell 7 on Windows.'}
    $assets=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis'
    . (Join-Path $assets 'WindowsVm.Common.ps1')
    if(-not $StoragePath){$StoragePath=Join-Path $env:LOCALAPPDATA "PowerShellProfile/AnalysisVm/$VirtualMachineName"}
    $storage=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StoragePath)
    $manifestPath=Join-Path $storage 'analysis-windows-vm.json'
    $registered=Invoke-AnalysisWindowsVBox @('list','vms')
    if($registered -match ('(?m)^"'+[regex]::Escape($VirtualMachineName)+'" \{(?<id>[^}]+)\}\r?$')) {
        $id=$Matches.id
        if(-not $PSBoundParameters.ContainsKey('StoragePath')){
            $ownership=Invoke-AnalysisWindowsVBox @('getextradata',$id,'PowerShellProfile.AnalysisVm.Manifest')
            if($ownership -notmatch '(?m)^Value: (.+)$'){throw 'The existing VM has no analysis ownership record.'}
            $manifestPath=$Matches[1].Trim()
        }
        if(-not(Test-Path -LiteralPath $manifestPath)){throw 'An existing VM has no expected ownership manifest; it will not be modified.'}
        $existing=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
        if($existing.VirtualMachineId -ne $id -or $existing.Status -ne 'Ready'){throw 'The owned VM is not ready. Inspect its retained provisioning evidence before recovery.'}
        $existingLock=Enter-AnalysisWindowsVmLock $existing.StoragePath
        try{
            $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$id,'--machinereadable'))
            Assert-AnalysisWindowsVmIsolation $settings $existing
            if($settings.VMState -ne 'poweroff'){throw 'The owned Windows VM must be powered off before reuse.'}
        }finally{$existingLock.Dispose()}
        return $existing
    }
    if(-not $IsoPath){throw 'Supply an existing Windows 11 x64 ISO with -IsoPath for first-time provisioning.'}
    $iso=(Get-Item -LiteralPath $IsoPath -ErrorAction Stop).FullName
    if([IO.Path]::GetExtension($iso) -ne '.iso'){throw 'IsoPath must name a local ISO file.'}
    $additions=Join-Path $env:ProgramFiles 'Oracle/VirtualBox/VBoxGuestAdditions.iso'
    if(-not(Test-Path -LiteralPath $additions -PathType Leaf)){throw 'The installed VirtualBox Guest Additions ISO is missing.'}
    $detected=Invoke-AnalysisWindowsVBox @('unattended','detect',('--iso='+$iso),'--machine-readable')
    if($detected -notmatch 'OSTypeId="Windows11_64"' -or $detected -notmatch ('ImageIndex'+$ImageIndex+'=')){throw 'The selected ISO/image is not a detected Windows 11 x64 installation.'}
    if(-not $PSCmdlet.ShouldProcess($storage,"Create dedicated offline Windows VM '$VirtualMachineName' from the selected local ISO")){return}
    if(Test-Path -LiteralPath $storage){throw 'Use a new empty storage path; existing files will not be overwritten.'}
    $null=[IO.Directory]::CreateDirectory($storage)
    Protect-AnalysisWindowsPrivatePath $storage
    if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($storage))).AvailableFreeSpace -lt 30GB){throw 'At least 30 GiB of free disk is required for setup and snapshots.'}
    $bootstrapFile=Join-Path $storage 'bootstrap-password.tmp'
    $bootstrapPassword=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
    $manifest=[ordered]@{Schema='PowerShellProfile.AnalysisWindowsVm.v1';VirtualMachineName=$VirtualMachineName;VirtualMachineId=$null;StoragePath=$storage;GuestOS='Windows 11 x64';GuestUser='analysis-user';AdminUser='Administrator';CredentialPath=(Join-Path $storage 'guest-credential.clixml');AdminCredentialPath=(Join-Path $storage 'admin-credential.clixml');SnapshotName='Profile-Clean-Windows';SnapshotId=$null;Status='Provisioning';IsoPath=$iso;IsoSHA256=(Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash;ImageIndex=$ImageIndex;StartedUtc=[DateTime]::UtcNow.ToString('o')}
    $created=$false;$ready=$false;$provisioningLock=$null;$provisioningFile=$null
    try {
        $provisioningLock=Enter-AnalysisWindowsVmLock $storage
        [IO.File]::WriteAllText($bootstrapFile,'');Protect-AnalysisWindowsPrivatePath $bootstrapFile
        [IO.File]::WriteAllText($bootstrapFile,$bootstrapPassword)
        [pscredential]::new('Administrator',(ConvertTo-AnalysisWindowsSecureString $bootstrapPassword))|Export-Clixml -LiteralPath $manifest.AdminCredentialPath
        Protect-AnalysisWindowsPrivatePath $manifest.AdminCredentialPath
        $null=Invoke-AnalysisWindowsVBox @('createvm','--name',$VirtualMachineName,'--platform-architecture','x86','--ostype','Windows11_64','--basefolder',$storage,'--register')
        $created=$true
        $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$VirtualMachineName,'--machinereadable'))
        $manifest.VirtualMachineId=$settings.UUID
        $manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding utf8
        $null=Invoke-AnalysisWindowsVBox @('setextradata',$VirtualMachineName,'PowerShellProfile.AnalysisVm.Manifest',$manifestPath)
        $modify=@('modifyvm',$VirtualMachineName,'--memory','6144','--cpus','4','--firmware','efi','--chipset','ich9','--ioapic','on','--tpm-type','2.0','--graphicscontroller','vboxsvga','--vram','128','--accelerate-3d','off','--boot1','dvd','--boot2','disk','--boot3','none','--boot4','none','--clipboard-mode','disabled','--clipboard-file-transfers','disabled','--drag-and-drop','disabled','--usb-ohci','off','--usb-ehci','off','--usb-xhci','off','--audio-enabled','off','--audio-in','off','--audio-out','off','--vrde','off','--nested-hw-virt','off','--teleporter','off')
        foreach($index in 1..8){$modify+=@("--nic$index",'none')};foreach($index in 1..4){$modify+=@("--uart$index",'off')}
        $null=Invoke-AnalysisWindowsVBox $modify
        $disk=Join-Path $storage 'windows.vdi'
        $null=Invoke-AnalysisWindowsVBox @('createmedium','disk','--filename',$disk,'--size','65536','--format','VDI')
        $null=Invoke-AnalysisWindowsVBox @('storagectl',$VirtualMachineName,'--name','SATA','--add','sata','--controller','IntelAhci','--portcount','4','--bootable','on')
        $null=Invoke-AnalysisWindowsVBox @('storageattach',$VirtualMachineName,'--storagectl','SATA','--port','0','--device','0','--type','hdd','--medium',$disk)
        # The additions installer can leave VBoxService stopped until reboot. First
        # logon runs this fixed command elevated; publish readiness only after the
        # guest-control service is running. The encoded command contains no secret.
        $postInstallScript=@'
$ErrorActionPreference='Stop'
try {
    Start-Service -Name VBoxService -ErrorAction Stop
    $service=Get-Service -Name VBoxService -ErrorAction Stop
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
    $service.Refresh()
    if($service.Status -ne [ServiceProcess.ServiceControllerStatus]::Running){throw 'VBoxService is not running.'}
    Set-Content -LiteralPath 'C:\profile-setup-ready.txt' -Value 'ready' -Encoding ascii
} catch {
    $_|Out-String|Set-Content -LiteralPath 'C:\profile-setup-error.txt' -Encoding utf8
    throw
}
'@
        $postInstallEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($postInstallScript))
        $postInstallCommand='powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$postInstallEncoded
        $null=Invoke-AnalysisWindowsVBox @('unattended','install',$VirtualMachineName,('--iso='+$iso),'--user=Administrator',('--user-password-file='+$bootstrapFile),('--admin-password-file='+$bootstrapFile),'--full-user-name=Profile Analysis Administrator',('--image-index='+$ImageIndex),'--hostname=profile-analysis-windows.local','--locale=en_US','--country=US','--time-zone=UTC','--install-additions',('--additions-iso='+$additions),('--auxiliary-base-path='+(Join-Path $storage 'Unattended-')),('--post-install-command='+$postInstallCommand),'--start-vm=headless') -TimeoutSeconds 180
        Write-Verbose 'Windows installation started in the dedicated offline VM.'
        $timer=[Diagnostics.Stopwatch]::StartNew();$attempt=0
        $auth=@('--username','Administrator','--passwordfile',$bootstrapFile)
        while($timer.Elapsed.TotalSeconds -lt $ProvisioningTimeoutSeconds) {
            Start-Sleep -Seconds 15
            $attempt++
            try {
                $probe=Invoke-AnalysisWindowsVBox (@('guestcontrol',$VirtualMachineName,'run')+$auth+@('--exe','C:\Windows\System32\cmd.exe','--timeout','10000','--wait-stdout','--','/d','/c','type C:\profile-setup-ready.txt')) -TimeoutSeconds 15
                if($probe -match 'ready'){break}
            } catch {Write-Verbose "Windows setup readiness probe $attempt is not ready."}
            if($attempt%4 -eq 0){Write-Progress -Activity 'Installing dedicated Windows analysis VM' -Status ('Waiting for guest provisioning ({0:N0} minutes)' -f $timer.Elapsed.TotalMinutes)}
        }
        if($timer.Elapsed.TotalSeconds -ge $ProvisioningTimeoutSeconds){throw 'Windows unattended installation did not reach the readiness marker before its deadline.'}
        # Preserve both sides of a password rotation before touching the guest.
        # A timeout can occur after the guest accepted its new password. Pending
        # credentials are DPAPI-protected and retained on failure for recovery.
        $manifest.BootstrapCredentialPath=Join-Path $storage 'bootstrap-credential.clixml'
        $manifest.PendingGuestCredentialPath=Join-Path $storage 'pending-guest-credential.clixml'
        $manifest.PendingAdminCredentialPath=Join-Path $storage 'pending-admin-credential.clixml'
        if(-not(Test-Path -LiteralPath $manifest.BootstrapCredentialPath)){
            Copy-Item -LiteralPath $manifest.AdminCredentialPath -Destination $manifest.BootstrapCredentialPath
            Protect-AnalysisWindowsPrivatePath $manifest.BootstrapCredentialPath
        }
        foreach($item in @(@('analysis-user',$manifest.PendingGuestCredentialPath),@('Administrator',$manifest.PendingAdminCredentialPath))){
            if(-not(Test-Path -LiteralPath $item[1])){
                $randomPassword=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
                [pscredential]::new($item[0],(ConvertTo-AnalysisWindowsSecureString $randomPassword))|Export-Clixml -LiteralPath $item[1]
                Protect-AnalysisWindowsPrivatePath $item[1]
                $randomPassword=$null
            }
            $pendingCredential=Import-Clixml -LiteralPath $item[1]
            if($pendingCredential -isnot [pscredential] -or $pendingCredential.UserName -ne $item[0]){throw 'A retained pending credential did not match its expected guest account.'}
            if($item[0] -eq 'analysis-user'){$guestPassword=$pendingCredential.GetNetworkCredential().Password}else{$adminPassword=$pendingCredential.GetNetworkCredential().Password}
        }
        $manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding utf8
        $provision=@"
`$ErrorActionPreference='Stop'
`$managementPrincipal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not `$managementPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Provisioning requires a full administrator management token.'}
`$guest=ConvertTo-SecureString '$guestPassword' -AsPlainText -Force
if(Get-LocalUser -Name 'analysis-user' -ErrorAction SilentlyContinue){Set-LocalUser -Name 'analysis-user' -Password `$guest -PasswordNeverExpires `$true -UserMayChangePassword `$false}
else{New-LocalUser -Name 'analysis-user' -Password `$guest -PasswordNeverExpires -UserMayNotChangePassword | Out-Null}
if(-not (Get-LocalGroupMember -SID 'S-1-5-32-545' | Where-Object {`$_.Name -like '*\analysis-user'})){Add-LocalGroupMember -SID 'S-1-5-32-545' -Member 'analysis-user'}
`$targetSid=(Get-LocalUser -Name 'analysis-user').SID.Value
if(Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object {`$_.SID.Value -eq `$targetSid}){Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member 'analysis-user' -Confirm:`$false}
if(Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object {`$_.SID.Value -eq `$targetSid}){throw 'The analysis account is still a member of Administrators.'}
New-Item -ItemType Directory -Path C:\ProfileAnalysis,C:\ProfileAnalysis\Work,C:\ProfileAnalysis\Results -Force | Out-Null
& icacls.exe C:\ProfileAnalysis /inheritance:r /grant 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' 'analysis-user:(OI)(CI)RX' | Out-Null
if(`$LASTEXITCODE -ne 0){throw 'Failed to restrict the guest analysis directory.'}
& icacls.exe C:\ProfileAnalysis\Work /grant 'analysis-user:(OI)(CI)M' | Out-Null
if(`$LASTEXITCODE -ne 0){throw 'Failed to grant guest work access.'}
& icacls.exe C:\ProfileAnalysis\Results /grant 'analysis-user:(OI)(CI)M' | Out-Null
if(`$LASTEXITCODE -ne 0){throw 'Failed to grant guest evidence access.'}
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' AutoAdminLogon '0'
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' DefaultPassword -ErrorAction SilentlyContinue
Get-LocalUser -Name 'analysis-admin' -ErrorAction SilentlyContinue | Disable-LocalUser
`$admin=ConvertTo-SecureString '$adminPassword' -AsPlainText -Force
`$builtInAdministrator=Get-LocalUser | Where-Object {`$_.SID.Value -match '-500$'}
`$builtInAdministrator | Set-LocalUser -Password `$admin
`$builtInAdministrator | Enable-LocalUser
Set-LocalUser -Name 'Administrator' -Password `$admin
Write-Output 'Provisioned standard account and rotated bootstrap password.'
"@
        # Credentials must not appear, even encoded, in host process arguments.
        $provisioningFile=Join-Path $storage ('provision-'+[guid]::NewGuid().ToString('N')+'.ps1')
        [IO.File]::WriteAllText($provisioningFile,'');Protect-AnalysisWindowsPrivatePath $provisioningFile
        $wrappedProvision="try {`n$provision`n} finally { Remove-Item -LiteralPath `$PSCommandPath -Force }"
        [IO.File]::WriteAllText($provisioningFile,$wrappedProvision)
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$VirtualMachineName,'copyto')+$auth+@($provisioningFile,'C:\Windows\Temp\ProfileAnalysisProvision.ps1'))
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$VirtualMachineName,'run')+$auth+@('--exe','C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','--timeout','300000','--wait-stdout','--wait-stderr','--','-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','C:\Windows\Temp\ProfileAnalysisProvision.ps1')) -TimeoutSeconds 310
        foreach($item in @(@('analysis-user',$guestPassword,$manifest.CredentialPath),@('Administrator',$adminPassword,$manifest.AdminCredentialPath))) {
            $credential=[pscredential]::new($item[0],(ConvertTo-AnalysisWindowsSecureString $item[1]))
            $credential|Export-Clixml -LiteralPath $item[2];Protect-AnalysisWindowsPrivatePath $item[2]
        }
        [IO.File]::WriteAllText($bootstrapFile,$adminPassword)
        $auth=@('--username','Administrator','--passwordfile',$bootstrapFile)
        $runner=Join-Path $assets 'WindowsGuestRunner.ps1'
        if(-not(Test-Path -LiteralPath $runner)){throw 'The trusted Windows guest runner asset is missing.'}
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$VirtualMachineName,'copyto')+$auth+@($runner,'C:\ProfileAnalysis\Runner.ps1'))
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$VirtualMachineName,'run')+$auth+@('--exe','C:\Windows\System32\shutdown.exe','--timeout','10000','--','/s','/t','0'))
        $stop=[Diagnostics.Stopwatch]::StartNew()
        do {Start-Sleep -Seconds 2;$settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$VirtualMachineName,'--machinereadable'))}while($settings.VMState -ne 'poweroff' -and $stop.Elapsed.TotalSeconds -lt 120)
        if($settings.VMState -ne 'poweroff'){throw 'Provisioned guest did not shut down cleanly.'}
        foreach($key in @($settings.Keys|Where-Object {$_ -match '^SATA-\d+-\d+$'})) {
            $medium=$settings[$key].Replace('\\','\')
            if($medium -in 'none','emptydrive' -or [IO.Path]::GetExtension($medium) -eq '.vdi'){continue}
            if($key -match '^SATA-(\d+)-(\d+)$'){$null=Invoke-AnalysisWindowsVBox @('storageattach',$VirtualMachineName,'--storagectl','SATA','--port',$Matches[1],'--device',$Matches[2],'--type','dvddrive','--medium','none')}
        }
        $null=Invoke-AnalysisWindowsVBox @('modifyvm',$VirtualMachineName,'--boot1','disk','--boot2','none')
        $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$VirtualMachineName,'--machinereadable'))
        Assert-AnalysisWindowsVmIsolation $settings ([pscustomobject]$manifest)
        $null=Invoke-AnalysisWindowsVBox @('snapshot',$VirtualMachineName,'take',$manifest.SnapshotName,'--description','Offline powered-off Windows clean baseline; standard-user target execution only') -TimeoutSeconds 120
        $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$VirtualMachineName,'--machinereadable'))
        $manifest.SnapshotId=$settings.CurrentSnapshotUUID
        if($manifest.SnapshotId -notmatch '^[a-f0-9-]{36}$'){throw 'The clean snapshot UUID was not verified.'}
        $manifest.Status='Ready';$manifest.CompletedUtc=[DateTime]::UtcNow.ToString('o');$ready=$true
        [pscustomobject]$manifest
    } catch {$manifest.Status='Failed';$manifest.Error=$_.Exception.Message;throw}
    finally {
        if($created -and -not $ready){try{$settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$VirtualMachineName,'--machinereadable'));if($settings.VMState -in 'running','paused'){$null=Invoke-AnalysisWindowsVBox @('controlvm',$VirtualMachineName,'poweroff')}}catch{Write-Warning 'The owned VM could not be powered off; inspect its retained provisioning evidence.'}}
        # A caller that lost a creation race must not delete the winner's password
        # file or overwrite its manifest merely because acquiring the lock failed.
        if($provisioningLock){try{
            $cleanupErrors=@()
            foreach($secretFile in @($bootstrapFile,$provisioningFile)){
                try{if($secretFile -and (Test-Path -LiteralPath $secretFile)){Remove-Item -LiteralPath $secretFile -Force}}
                catch{$cleanupErrors+=$_.Exception.Message}
            }
            if($cleanupErrors.Count){$manifest.Status='Failed';$manifest.Error='A provisioning credential file could not be removed.'}
            $manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $manifestPath -Encoding utf8
            if($cleanupErrors.Count){throw $manifest.Error}
        }finally{
            $bootstrapPassword=$null;$guestPassword=$null;$adminPassword=$null;$provision=$null;$wrappedProvision=$null
            $provisioningLock.Dispose()
        }}
    }
}
