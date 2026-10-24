function Invoke-ExecutableAnalysisWindowsVm {
    <#
    .SYNOPSIS
    Observes an executable inside an owned, offline disposable Windows VM.
    .DESCRIPTION
    Accepts x86/x64 PE executables, never DLLs or host execution. Requires a Windows VM
    created by Initialize-ExecutableAnalysisWindowsVm. Preserves a bounded application
    layout when detected or explicitly selected, verifying files, directory inventory
    and hashes before deployment and original-source integrity again after observation.
    DesktopLayout launches with a standard guest token, no arguments and a bounded Job.
    RegisteredPackage explicitly stages/registers original signed Appx bytes and uses
    standard-user AUMID activation. Declared services can run with elevated privileges;
    this mode relies on the offline VM and independent host deadline, not Job limits.
    Application payloads use a verified interactive console with temporary autologon
    secrets removed before deployment. Host sign-in state and external credentials,
    source ACLs and host package-registration state are not copied. Networking and shared
    folders remain disabled. No GUI interaction or application sign-in is performed.
    An exclusive per-VM lock prevents concurrent runs. Restores the exact powered-off
    clean snapshot before execution and in finally, including after guest failures.
    Observations are bounded snapshots and process polling, not a complete system trace.
    Screenshots are optional evidence and require visual verification. A zero exit code
    is not complete feature coverage; a GUI running at its observation limit is partial.
    .PARAMETER InputPath
    Literal path to the selected x86/x64 PE executable inside its application root.
    .PARAMETER OutputPath
    A new or empty host directory outside the source root for evidence and host manifest.
    .PARAMETER VirtualMachineName
    Name of a ready owned Windows analysis VM; unrelated or running VMs are not reused.
    .PARAMETER ApplicationRoot
    Complete directory to preserve, containing InputPath. Automatic discovery checks
    adjacent Appx manifests and resources/app.asar. Files and empty directories are
    retained with a hash manifest; external dependencies and user data are not imported.
    .PARAMETER LaunchMode
    DesktopLayout preserves files without registering package identity or services.
    RegisteredPackage attempts signed offline deployment and AUMID activation without
    re-signing, manifest changes, development-mode substitution or license bypass.
    Registered target stdout/stderr are unavailable; runner diagnostics remain separate.
    .PARAMETER PackageArchivePath
    Optional original signed MSIX/AppX container for licensed offline deployment. Requires
    PackageLicensePath and RegisteredPackage mode. Every installed payload file must match.
    .PARAMETER PackageLicensePath
    Vendor-issued offline XML license paired with PackageArchivePath. Windows validates it
    inside the guest; host license or account state is never imported.
    .PARAMETER TimeoutSeconds
    Observation allowance from 1 to 600 seconds. Application payloads also start an
    independent watchdog before transfer/deployment, expiring after this value plus
    1200 seconds, or 1500 seconds when a signed package and offline license are supplied.
    Licensed deployment allows 1200 seconds beyond observation for controller preparation
    and evidence, leaving a combined 300 seconds for transfer and evidence outside it.
    Identity inspection, power-off and verification each allow 15 seconds.
    .PARAMETER MaxPackageBytes
    Total preserved payload byte limit, default 8 GiB and maximum 64 GiB.
    .PARAMETER MaxPackageFiles
    Preserved file count limit, default 10000 and maximum 50000. Directory depth is 64;
    directory count is bounded separately. Incomplete layouts are rejected.
    .PARAMETER MaxProcessMemoryMB
    Committed-memory limit for each Job-assigned process, default 1024 MiB. Does not
    apply to RegisteredPackage activation or package services.
    .PARAMETER MaxJobMemoryMB
    Combined committed-memory Job limit, default 4096 MiB and at least the process
    limit. Does not apply to RegisteredPackage; the VM's resources remain its bound.
    .PARAMETER ExpectedInputSHA256
    Optional exact executable hash from the parent analysis, checked before preparation.
    .EXAMPLE
    Invoke-ExecutableAnalysisWindowsVm -InputPath .\program.exe -OutputPath .\runtime
    .EXAMPLE
    Invoke-ExecutableAnalysisWindowsVm -InputPath C:\Apps\Example\app\Example.exe -ApplicationRoot C:\Apps\Example -LaunchMode RegisteredPackage -OutputPath C:\Analysis\Example-Runtime
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$VirtualMachineName='Profile-Analysis-Windows',
        [ValidateRange(1,600)][int]$TimeoutSeconds=120,
        [string]$ApplicationRoot,
        [ValidateSet('DesktopLayout','RegisteredPackage')][string]$LaunchMode='DesktopLayout',
        [string]$PackageArchivePath,
        [string]$PackageLicensePath,
        [ValidateRange(1,68719476736)][long]$MaxPackageBytes=8GB,
        [ValidateRange(1,50000)][int]$MaxPackageFiles=10000,
        [ValidateRange(128,8192)][int]$MaxProcessMemoryMB=1024,
        [ValidateRange(128,16384)][int]$MaxJobMemoryMB=4096,
        [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedInputSHA256
    )
    $ErrorActionPreference='Stop'
    if(-not $IsWindows){throw 'Windows VM analysis requires PowerShell 7 on Windows.'}
    $assets=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis'
    . (Join-Path $assets 'WindowsVm.Common.ps1')
    . (Join-Path $assets 'New-AnalysisWindowsPayload.ps1')
    if([bool]$PackageArchivePath -ne [bool]$PackageLicensePath -or (($PackageArchivePath -or $PackageLicensePath) -and $LaunchMode -ne 'RegisteredPackage')){throw 'PackageArchivePath and PackageLicensePath must be supplied together in RegisteredPackage mode.'}
    if($PackageArchivePath){. (Join-Path $assets 'New-AnalysisWindowsPackageInput.ps1')}
    if($MaxJobMemoryMB -lt $MaxProcessMemoryMB){throw 'The job memory budget must be at least the per-process budget.'}
    $trustedRunner=Join-Path $assets 'WindowsGuestRunner.ps1'
    if(-not(Test-Path -LiteralPath $trustedRunner -PathType Leaf)){throw 'The trusted Windows guest runner asset is missing.'}
    $trustedController=Join-Path $assets 'WindowsGuestController.ps1'
    if(-not(Test-Path -LiteralPath $trustedController -PathType Leaf)){throw 'The trusted Windows profile-loading controller is missing.'}
    $runnerHash=(Get-FileHash -LiteralPath $trustedRunner -Algorithm SHA256).Hash
    $inputItem=Get-Item -LiteralPath $InputPath -ErrorAction Stop
    if($inputItem.PSIsContainer -or ($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'InputPath must name a regular executable file.'}
    $source=$inputItem.FullName
    . (Join-Path $assets 'Get-AnalysisFirmwareContext.ps1')
    $firmware=Get-AnalysisFirmwareContext -SourcePath $source
    if($firmware.RequiresStaticOnly){throw 'Firmware updater candidates require static analysis; runtime execution and flashing are not supported.'}
    if(-not(Test-AnalysisWindowsPe $source)){throw 'Windows runtime analysis supports x86/x64 PE executables; DLLs, nonexecutables, and other formats require a different harness.'}
    $sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if($ExpectedInputSHA256 -and $sourceHash -ne $ExpectedInputSHA256){throw 'The runtime source differs from the selected analysis input.'}
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if(Test-Path -LiteralPath $output){
        $directory=Get-Item -LiteralPath $output
        if(-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or @(Get-ChildItem -LiteralPath $output -Force).Count){throw 'OutputPath must be a new or empty regular directory.'}
    }
    $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$VirtualMachineName,'--machinereadable'))
    $ownership=Invoke-AnalysisWindowsVBox @('getextradata',$VirtualMachineName,'PowerShellProfile.AnalysisVm.Manifest')
    if($ownership -notmatch '(?m)^Value: (.+)$'){throw 'The requested VM has no analysis ownership manifest.'}
    $manifestPath=$Matches[1].Trim()
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw 'The owned VM manifest is unavailable.'}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    if($manifest.Status -ne 'Ready' -or $manifest.VirtualMachineName -ne $VirtualMachineName -or $manifest.SnapshotId -notmatch '^[a-f0-9-]{36}$'){throw 'The Windows VM has no verified ready baseline.'}
    Assert-AnalysisWindowsVmIsolation $settings $manifest
    $storage=[IO.Path]::GetFullPath($manifest.StoragePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $storagePrefix=$storage+[IO.Path]::DirectorySeparatorChar
    foreach($ownedPath in @($manifestPath,$manifest.CredentialPath,$manifest.AdminCredentialPath)){
        if(-not[IO.Path]::GetFullPath($ownedPath).StartsWith($storagePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'A VM ownership or credential file is outside the owned storage directory.'}
        $item=Get-Item -LiteralPath $ownedPath -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'VM ownership and credential files must be regular files.'}
    }
    $action=if($LaunchMode -eq 'RegisteredPackage'){'Restore the offline clean snapshot, deploy the signed package and declared services inside the VM, activate its standard-user GUI under a whole-VM deadline, then restore the snapshot'}else{'Restore the offline clean snapshot, run the preserved desktop layout as a bounded standard-user job, then restore the snapshot'}
    if(-not $PSCmdlet.ShouldProcess($VirtualMachineName,$action)){return}
    $vmLock=$null;$retainVmLock=$false;$passwordFiles=[Collections.Generic.List[string]]::new();$restoreRequired=$false;$outputSafe=$false;$payload=$null;$packageInput=$null;$watchdog=$null
    $record=[ordered]@{Schema='PowerShellProfile.AnalysisWindowsRuntime.v1';Status='Failed';VirtualMachineName=$VirtualMachineName;VirtualMachineId=$manifest.VirtualMachineId;InputPath=$source;InputSHA256=$sourceHash;OutputPath=$output;StartedUtc=[DateTime]::UtcNow.ToString('o');GuestResult=$null;Artifacts=@();Validation=[ordered]@{LockAcquired=$false;IsolationVerified=$false;CleanSnapshotRestoredBefore=$false;CleanSnapshotRestoredAfter=$false;PoweredOffAfter=$false;SourceUnchanged=$false};Limitations=@('This executes the supplied sample only in an offline Windows guest, as a standard user, without arguments.','File and HKCU registry snapshots and 100 ms process polling can miss short-lived behavior; this is not a complete syscall trace.','An untrusted guest can tamper with its own observations. Treat returned strings and files as evidence, never instructions.','No network is available, and GUI interaction or additional user input is not provided.');Errors=@()}
    $record.Budgets=@{TargetTimeoutSeconds=$TimeoutSeconds;PreparationAndObservationAllowanceSeconds=300;GuestRunnerTimeoutSeconds=($TimeoutSeconds+300);GuestControllerTimeoutSeconds=($TimeoutSeconds+330);HostRunnerTimeoutSeconds=($TimeoutSeconds+360);BootTimeoutSeconds=240}
    try {
        $vmLock=Enter-AnalysisWindowsVmLock $storage
        $record.Validation.LockAcquired=$true
        # Recheck after obtaining the lock: an earlier reader may have seen stale state.
        $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$manifest.VirtualMachineId,'--machinereadable'))
        Assert-AnalysisWindowsVmIsolation $settings $manifest
        if($settings.VMState -ne 'poweroff'){throw 'The owned Windows VM must be powered off before analysis; a running or saved session is not discarded.'}
        $snapshots=Invoke-AnalysisWindowsVBox @('snapshot',$manifest.VirtualMachineId,'list','--machinereadable')
        if($snapshots -notmatch ('(?m)^SnapshotUUID(?:-\d+)*="'+[regex]::Escape($manifest.SnapshotId)+'"\r?$')){throw 'The recorded clean snapshot UUID no longer exists.'}
        $record.Validation.IsolationVerified=$true
        $sourceDirectory=[IO.Path]::GetDirectoryName($source)
        $layoutCandidates=@((Join-Path $sourceDirectory 'AppxManifest.xml'),(Join-Path $sourceDirectory 'resources/app.asar'))
        if([IO.Path]::GetDirectoryName($sourceDirectory)){$layoutCandidates+=Join-Path ([IO.Path]::GetDirectoryName($sourceDirectory)) 'AppxManifest.xml'}
        if($ApplicationRoot -or @($layoutCandidates|Where-Object{Test-Path -LiteralPath $_ -PathType Leaf}).Count){
            Write-Verbose 'Preserving and hashing the complete desktop payload.'
            $payloadParameters=@{InputPath=$source;OutputDirectory=(Join-Path $output 'payload');MaxPackageBytes=$MaxPackageBytes;MaxPackageFiles=$MaxPackageFiles}
            if($ApplicationRoot){$payloadParameters.ApplicationRoot=$ApplicationRoot}
            $payload=New-AnalysisWindowsPayload @payloadParameters
            if($payload.SourceSHA256 -ne $sourceHash){throw 'The selected executable changed before payload preservation.'}
            $payloadManifestHash=(Get-FileHash -LiteralPath $payload.ManifestPath -Algorithm SHA256).Hash
            $record['Payload']=$payload|Select-Object Mode,RootKind,EntryPoint,WorkingDirectory,TotalBytes,SourceSHA256,ArchiveSHA256,Package,ManifestPath,ArchivePath
            $record.Payload|Add-Member -NotePropertyName ManifestSHA256 -NotePropertyValue $payloadManifestHash
        }else{
            $ancestor=$output
            while($ancestor){
                if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Runtime output cannot traverse a reparse point.'}
                $ancestor=[IO.Path]::GetDirectoryName($ancestor)
            }
            $null=[IO.Directory]::CreateDirectory($output)
        }
        $outputSafe=$true
        $record['LaunchMode']=$LaunchMode
        if($LaunchMode -eq 'RegisteredPackage'){
            if(-not $payload -or $payload.RootKind -notin 'AppxDirectory','Explicit' -or $payload.Package.ManifestPath -ne 'AppxManifest.xml' -or -not $payload.Package.Identity.Name){throw 'RegisteredPackage requires a complete Appx package directory.'}
            $declaredApplications=@($payload.Package.Applications|Where-Object {$_.Executable.Replace('\','/') -ieq $payload.EntryPoint})
            if($declaredApplications.Count -ne 1){throw 'The selected executable must match exactly one declared Appx application for registered activation.'}
            $record.Limitations+='Signed package deployment can start privileged services and extensions. Registered mode is bounded by the entire offline VM and host deadline, not a per-process Job.'
            if($PackageArchivePath){
                Write-Verbose 'Preserving the signed container and offline license, and comparing every package file with the selected layout.'
                $packageInput=New-AnalysisWindowsPackageInput -PackageArchivePath $PackageArchivePath -PackageLicensePath $PackageLicensePath -Payload $payload -OutputDirectory (Join-Path $output 'package-input') -MaxPackageBytes $MaxPackageBytes
                if($packageInput.Status -ne 'Completed'){throw 'Signed package inputs were not completely preserved and verified.'}
                $record.PackageInput=$packageInput
            }
        }
        $controllerAllowance=if($packageInput){1200}elseif($payload){900}else{330}
        $runnerPreparationAllowance=if($payload){600}else{300}
        $record.Budgets.PreparationAndObservationAllowanceSeconds=$runnerPreparationAllowance
        $record.Budgets.GuestRunnerTimeoutSeconds=$TimeoutSeconds+$runnerPreparationAllowance
        $evidenceTimeoutSeconds=if($payload){60}else{30}
        $record.Budgets.GuestEvidenceTransferTimeoutSeconds=$evidenceTimeoutSeconds
        $record.Budgets.HostEvidenceTransferTimeoutSeconds=$evidenceTimeoutSeconds+10
        $record.Budgets.ControllerPreparationAndEvidenceAllowanceSeconds=$controllerAllowance
        $record.Budgets.GuestControllerTimeoutSeconds=$TimeoutSeconds+$controllerAllowance
        $record.Budgets.HostControllerCompletionAllowanceSeconds=30
        $record.Budgets.HostRunnerTimeoutSeconds=$TimeoutSeconds+$controllerAllowance+30
        $auth=@{}
        foreach($role in @('Guest','Admin')){
            $credentialPath=if($role -eq 'Guest'){$manifest.CredentialPath}else{$manifest.AdminCredentialPath}
            $expectedUser=if($role -eq 'Guest'){$manifest.GuestUser}else{$manifest.AdminUser}
            $credential=Import-Clixml -LiteralPath $credentialPath
            if($credential -isnot [pscredential] -or $credential.UserName -ne $expectedUser){throw "The $role credential does not match the owned manifest."}
            $passwordFile=Join-Path $storage ('runtime-'+[guid]::NewGuid().ToString('N')+'.tmp')
            $passwordFiles.Add($passwordFile)
            # Set restrictive permissions while empty, before storing plaintext.
            [IO.File]::WriteAllText($passwordFile,'');Protect-AnalysisWindowsPrivatePath $passwordFile
            [IO.File]::WriteAllText($passwordFile,$credential.GetNetworkCredential().Password)
            $auth[$role]=@('--username',$credential.UserName,'--passwordfile',$passwordFile)
        }
        $restoreRequired=$true
        $null=Invoke-AnalysisWindowsVBox @('snapshot',$manifest.VirtualMachineId,'restore',$manifest.SnapshotId) -TimeoutSeconds 120
        $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$manifest.VirtualMachineId,'--machinereadable'))
        Assert-AnalysisWindowsVmIsolation $settings $manifest
        if($settings.VMState -ne 'poweroff' -or $settings.CurrentSnapshotUUID -ne $manifest.SnapshotId){throw 'The initial clean snapshot restore was not verified.'}
        $record.Validation.CleanSnapshotRestoredBefore=$true
        $null=Invoke-AnalysisWindowsVBox @('startvm',$manifest.VirtualMachineId,'--type','headless')
        $boot=[Diagnostics.Stopwatch]::StartNew();$bootReady=$false
        while($boot.Elapsed.TotalSeconds -lt 240){
            Start-Sleep -Seconds 3
            try{
                $probe=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$auth.Admin+@('--exe','C:\Windows\System32\cmd.exe','--timeout','10000','--wait-stdout','--','/d','/c','echo ready')) -TimeoutSeconds 15
                if($probe.Trim() -eq 'ready'){$bootReady=$true;break}
            }catch{Write-Verbose 'The Windows guest is still booting.'}
        }
        if(-not $bootReady){throw 'The Windows guest did not become ready before the boot deadline.'}
        # Refresh the trusted runner on every restored guest so profile updates cannot
        # silently continue using an older runner captured in the clean snapshot.
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@($trustedRunner,'C:\ProfileAnalysis\Runner.ps1')) -TimeoutSeconds 60
        if(-not $payload){$null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@($source,'C:\ProfileAnalysis\Work\target.exe')) -TimeoutSeconds 120}
        # Only the management account can read the transient launch credential.
        # No password is embedded in process arguments or accessible to the target.
        $privateScript=@'
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath 'C:\ProfileAnalysis\Private'){throw 'The clean baseline unexpectedly contains a private launch directory.'}
New-Item -ItemType Directory -Path 'C:\ProfileAnalysis\Private'|Out-Null
& icacls.exe 'C:\ProfileAnalysis\Private' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'|Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not restrict the private guest launch directory.'}
'@
        $privateEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($privateScript))
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$auth.Admin+@('--exe','C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','--timeout','300000','--wait-stdout','--wait-stderr','--','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$privateEncoded)) -TimeoutSeconds 310
        if($payload){
            Write-Verbose 'Preparing the dedicated standard-user console session.'
            $sessionHelper=Join-Path $assets 'WindowsGuestSession.ps1'
            $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@($sessionHelper,'C:\ProfileAnalysis\Private\WindowsGuestSession.ps1')) -TimeoutSeconds 60
            $sessionFile=Join-Path $storage ('runtime-'+[guid]::NewGuid().ToString('N')+'.json');$passwordFiles.Add($sessionFile)
            [IO.File]::WriteAllText($sessionFile,'');Protect-AnalysisWindowsPrivatePath $sessionFile
            $sessionCredential=Import-Clixml -LiteralPath $manifest.CredentialPath
            $baselineCredentials=@(foreach($candidatePath in @($manifest.AdminCredentialPath,(Join-Path $storage 'bootstrap-credential.clixml'),(Join-Path $storage 'legacy-analysis-admin-credential.clixml'))){
                if(Test-Path -LiteralPath $candidatePath){
                    $candidateItem=Get-Item -LiteralPath $candidatePath
                    if($candidateItem.PSIsContainer -or ($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $candidateItem.FullName.StartsWith($storagePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'A baseline credential is outside the owned regular VM storage.'}
                    $candidateCredential=Import-Clixml -LiteralPath $candidatePath
                    if($candidateCredential -isnot [pscredential]){throw 'An owned baseline credential has an invalid type.'}
                    @{UserName=$candidateCredential.UserName;UserPassword=$candidateCredential.GetNetworkCredential().Password}
                }
            })
            @{UserName=$manifest.GuestUser;UserPassword=$sessionCredential.GetNetworkCredential().Password;BaselineCredentials=$baselineCredentials}|ConvertTo-Json -Depth 4 -Compress|Set-Content -LiteralPath $sessionFile -Encoding utf8
            $baselineCredentials=$null;$candidateCredential=$null
            $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@($sessionFile,'C:\ProfileAnalysis\Private\session-config.json')) -TimeoutSeconds 60
            Remove-Item -LiteralPath $sessionFile -Force
            $sessionArguments=@('--exe','C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','--timeout','60000','--wait-stdout','--wait-stderr','--','-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','C:\ProfileAnalysis\Private\WindowsGuestSession.ps1')
            $configureArguments=@($sessionArguments);$configureArguments[[Array]::IndexOf($configureArguments,'--timeout')+1]='180000'
            $configured=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$auth.Admin+$configureArguments+@('-Mode','Configure')) -TimeoutSeconds 195|ConvertFrom-Json
            if($configured.Status -ne 'Configured' -or $configured.UserName -ne $manifest.GuestUser -or $configured.CredentialsInTask -ne $false){throw 'The dedicated interactive logon was not configured safely.'}
            $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$auth.Admin+@('--exe','C:\Windows\System32\shutdown.exe','--timeout','10000','--','/r','/t','3')) -TimeoutSeconds 15
            $sessionTimer=[Diagnostics.Stopwatch]::StartNew();$sessionReady=$null;$sessionError=$null
            $record.Budgets.InteractiveSessionTimeoutSeconds=600
            while($sessionTimer.Elapsed.TotalSeconds -lt 600){
                Start-Sleep -Seconds 3
                try{
                    # First logon is CPU intensive on small guests. Do not compile
                    # another PowerShell helper while SYSTEM is still cleaning up.
                    $marker=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$auth.Admin+@('--exe','C:\Windows\System32\cmd.exe','--timeout','10000','--wait-stdout','--wait-stderr','--','/d','/c','if exist C:\ProfileAnalysis\Private\interactive-session-cleanup.json (echo ready) else (echo pending)')) -TimeoutSeconds 15
                    if($marker.Trim() -ne 'ready'){continue}
                    $candidate=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$auth.Admin+$sessionArguments+@('-Mode','Verify','-ExpectedUser',$manifest.GuestUser)) -TimeoutSeconds 75|ConvertFrom-Json
                    if($candidate.Status -eq 'Ready' -and $candidate.UserSid -eq $configured.UserSid -and $candidate.RunId -eq $configured.RunId -and $candidate.StandardTokenVerified -eq $true -and $candidate.AutoLogonSecretsRemoved -eq $true -and $candidate.TaskRemoved -eq $true){$sessionReady=$candidate;break}
                }catch{$sessionError=$_.Exception.Message;Write-Verbose 'Waiting for the dedicated console and removal of temporary logon secrets.'}
            }
            if(-not $sessionReady){throw ('The standard-user interactive desktop did not become ready: '+$sessionError)}
            $verifiedPowerScheme=[guid]::Empty
            if($sessionReady.PowerPolicy.Status -ne 'Verified' -or -not [guid]::TryParseExact([string]$sessionReady.PowerPolicy.ActiveSchemeId,'D',[ref]$verifiedPowerScheme) -or $verifiedPowerScheme -eq [guid]::Empty){throw 'The guest did not verify an active power policy for uninterrupted observation.'}
            foreach($setting in 'MonitorTimeoutAcSeconds','MonitorTimeoutDcSeconds','StandbyTimeoutAcSeconds','StandbyTimeoutDcSeconds'){
                $timeoutValue=$sessionReady.PowerPolicy.$setting
                if(($timeoutValue -isnot [int] -and $timeoutValue -isnot [long] -and $timeoutValue -isnot [uint32] -and $timeoutValue -isnot [uint64]) -or $timeoutValue -ne 0){throw 'The guest display or standby idle timeout remains enabled or unknown.'}
            }
            $record['InteractiveSession']=$sessionReady
            $wholeVmAllowance=if($packageInput){1500}else{1200}
            $record.Budgets.WholeVmPreparationTransferAndEvidenceAllowanceSeconds=$wholeVmAllowance
            $record.Budgets.OutsideControllerTransferAndEvidenceAllowanceSeconds=$wholeVmAllowance-$controllerAllowance
            $record.Budgets.WholeVmDeadlineSeconds=$TimeoutSeconds+$wholeVmAllowance
            $watchdog=Start-AnalysisWindowsWatchdog -VirtualMachineId $manifest.VirtualMachineId -OwnershipManifestPath $manifestPath -DeadlineSeconds ($TimeoutSeconds+$wholeVmAllowance) -EvidenceDirectory (Join-Path $output 'watchdog')
            $record['WatchdogStarted']=$watchdog.Ready
            Write-Verbose 'Transferring the verified payload into the isolated guest.'
            foreach($transfer in @(@($payload.ArchivePath,'C:\ProfileAnalysis\Private\payload.zip'),@($payload.ManifestPath,'C:\ProfileAnalysis\payload-manifest.json'),@((Join-Path $assets 'Expand-AnalysisWindowsPayload.ps1'),'C:\ProfileAnalysis\Private\Expand-AnalysisWindowsPayload.ps1'))){
                $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+$transfer) -TimeoutSeconds 600
            }
            if($LaunchMode -eq 'RegisteredPackage'){
                $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@((Join-Path $assets 'WindowsGuestPackage.ps1'),'C:\ProfileAnalysis\WindowsGuestPackage.ps1')) -TimeoutSeconds 60
                $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@((Join-Path $assets 'WindowsGuestDeploymentProfile.ps1'),'C:\ProfileAnalysis\Private\WindowsGuestDeploymentProfile.ps1')) -TimeoutSeconds 60
                $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@((Join-Path $assets 'WindowsGuestActivationDiagnostics.ps1'),'C:\ProfileAnalysis\Private\WindowsGuestActivationDiagnostics.ps1')) -TimeoutSeconds 60
                if($packageInput){
                    foreach($transfer in @(@($packageInput.ArchivePath,'C:\ProfileAnalysis\Private\package.msix'),@($packageInput.LicensePath,'C:\ProfileAnalysis\Private\package-license.xml'))){
                        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+$transfer) -TimeoutSeconds 600
                    }
                }
            }
        }
        $launchFile=Join-Path $storage ('runtime-'+[guid]::NewGuid().ToString('N')+'.json');$passwordFiles.Add($launchFile)
        [IO.File]::WriteAllText($launchFile,'');Protect-AnalysisWindowsPrivatePath $launchFile
        $guestCredential=Import-Clixml -LiteralPath $manifest.CredentialPath
        $launchConfiguration=@{UserName=$manifest.GuestUser;UserPassword=$guestCredential.GetNetworkCredential().Password;TimeoutSeconds=$TimeoutSeconds;ExpectedSHA256=$sourceHash;MaxProcessMemoryMB=$MaxProcessMemoryMB;MaxJobMemoryMB=$MaxJobMemoryMB}
        if($payload){$launchConfiguration.PayloadManifestSHA256=$payloadManifestHash;$launchConfiguration.InteractiveSessionId=$sessionReady.SessionId;$launchConfiguration.InteractiveSessionRunId=$sessionReady.RunId;$launchConfiguration.LaunchMode=$LaunchMode}
        if($packageInput){$launchConfiguration.PackageArchiveSHA256=$packageInput.ArchiveSHA256;$launchConfiguration.PackageLicenseSHA256=$packageInput.LicenseSHA256}
        $launchConfiguration|ConvertTo-Json -Compress|Set-Content -LiteralPath $launchFile -Encoding utf8
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@($launchFile,'C:\ProfileAnalysis\Private\launch.json')) -TimeoutSeconds 60
        Remove-Item -LiteralPath $launchFile -Force
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@($trustedController,'C:\ProfileAnalysis\Private\Controller.ps1')) -TimeoutSeconds 60
        $executionError=$null
        try{
            Write-Verbose ('Running the guest controller in '+$LaunchMode+' mode.')
            $run=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$auth.Admin+@('--exe','C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','--timeout',(($TimeoutSeconds+$controllerAllowance)*1000).ToString(),'--wait-stdout','--wait-stderr','--','-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','C:\ProfileAnalysis\Private\Controller.ps1')) -TimeoutSeconds ($TimeoutSeconds+$controllerAllowance+30)
            $run|Set-Content -LiteralPath (Join-Path $output 'guest-runner.log') -Encoding utf8
        }catch{$executionError=$_.Exception.Message;$record.Errors+=$executionError}
        $evidenceFiles=@('controller.json','runtime-progress.json','runner-stdout.txt','runner-stderr.txt','runtime.json','stdout.txt','stderr.txt','files-before.json','files-after.json','registry-before.json','registry-after.json','network-before.json','network-after.json')
        if($LaunchMode -eq 'RegisteredPackage'){
            $evidenceFiles=@('controller.json','package-deployment.json','runtime-progress.json','activation-progress.json')+@($evidenceFiles|Where-Object {$_ -notin 'controller.json','runtime-progress.json','stdout.txt','stderr.txt'})+@('package-registration.json','activation-events.json')
            $record.Limitations+='Windows-brokered package activation does not provide redirected target stdout/stderr; those streams are unavailable, not empty.'
        }
        $preRunFailure=$false
        foreach($file in $evidenceFiles){
            if($preRunFailure -and $file -notin 'controller.json','package-deployment.json'){continue}
            try{
                $destination=Join-Path $output $file
                $privateEvidence=$file -in 'controller.json','package-deployment.json','activation-events.json'
                $guestEvidencePath=if($privateEvidence){'C:\ProfileAnalysis\Private\'+$file}else{'C:\ProfileAnalysis\Results\'+$file}
                $evidenceAuth=if($privateEvidence){$auth.Admin}else{$auth.Guest}
                # Read through a fixed trusted command and a host-side bounded pipe. A
                # guest-controlled size claim must never authorize an unbounded copy.
                $transferScript=@"
`$ErrorActionPreference='Stop'
`$stream=[IO.File]::OpenRead('$guestEvidencePath')
try{`$buffer=New-Object byte[] (16777217);`$total=0;while(`$total -lt `$buffer.Length){`$count=`$stream.Read(`$buffer,`$total,`$buffer.Length-`$total);if(`$count -eq 0){break};`$total+=`$count};if(`$total -gt 16777216){throw 'Guest evidence exceeds 16 MiB'};[Console]::Write([Convert]::ToBase64String(`$buffer,0,`$total))}finally{`$stream.Dispose()}
"@
                $transferEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($transferScript))
                $encodedEvidence=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$evidenceAuth+@('--exe','C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','--timeout',([string]($evidenceTimeoutSeconds*1000)),'--wait-stdout','--wait-stderr','--','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$transferEncoded)) -TimeoutSeconds ($evidenceTimeoutSeconds+10) -MaxOutputCharacters 23000000
                [IO.File]::WriteAllBytes($destination,[Convert]::FromBase64String($encodedEvidence.Trim()))
                $artifact=Get-Item -LiteralPath $destination
                if($artifact.Length -gt 16MB -or ($artifact.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A guest artifact exceeded the 16 MiB evidence limit or was a reparse point.'}
                $record.Artifacts+=@{Path=$file;Bytes=$artifact.Length;SHA256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}
                if($file -eq 'controller.json' -and $artifact.Length -le 1MB){
                    try{
                        $preparation=Get-Content -LiteralPath $destination -Raw|ConvertFrom-Json -Depth 10
                        if($preparation -is [pscustomobject]){$record.ControllerResult=$preparation}
                        if($preparation -is [pscustomobject] -and $preparation.Status -ceq 'Failed' -and $preparation.RunnerStarted -is [bool] -and -not $preparation.RunnerStarted -and $preparation.Error -is [string] -and -not [string]::IsNullOrWhiteSpace($preparation.Error)){
                            $record.ControllerResult=$preparation;$preRunFailure=$true
                        }
                    }catch{Write-Verbose 'The controller report did not establish a bounded pre-run failure; retaining the remaining evidence.'}
                }
            }catch{
                if($file -in 'runtime-progress.json','activation-progress.json'){
                    # Checkpoints diagnose interrupted runs; they never replace the final runtime proof.
                    $detail=[string]$_.Exception.Message
                    if(-not $record.Contains('ProgressArtifactErrors')){$record.ProgressArtifactErrors=@()}
                    $record.ProgressArtifactErrors+=@{Path=$file;Error=$detail.Substring(0,[Math]::Min(2048,$detail.Length))}
                }else{$record.Errors+=('Could not retain '+$file+': '+$_.Exception.Message)}
            }
        }
        if($preRunFailure){throw ('Guest preparation failed before runner launch (HRESULT '+$record.ControllerResult.HResult+'): '+$record.ControllerResult.Error)}
        $runtimePath=Join-Path $output 'runtime.json'
        if(-not(Test-Path -LiteralPath $runtimePath)){throw 'The guest produced no retained runtime report.'}
        if((Get-Item -LiteralPath $runtimePath).Length -gt 1MB){throw 'The guest runtime report exceeded its size limit.'}
        $guest=Get-Content -LiteralPath $runtimePath -Raw|ConvertFrom-Json -Depth 20
        $record.GuestResult=$guest
        if($guest.Execution.Screenshot -eq 'window.png'){
            try{
                $imageScript=@'
$ErrorActionPreference='Stop'
$stream=[IO.File]::OpenRead('C:\ProfileAnalysis\Results\window.png')
try{if($stream.Length -gt 16777216){throw 'Guest image exceeds 16 MiB'};$buffer=New-Object byte[] ([int]$stream.Length);$total=0;while($total -lt $buffer.Length){$count=$stream.Read($buffer,$total,$buffer.Length-$total);if($count -eq 0){throw 'Guest image ended unexpectedly'};$total+=$count};[Console]::Write([Convert]::ToBase64String($buffer))}finally{$stream.Dispose()}
'@
                $imageEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($imageScript))
                $imageBase64=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$auth.Guest+@('--exe','C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','--timeout',([string]($evidenceTimeoutSeconds*1000)),'--wait-stdout','--wait-stderr','--','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$imageEncoded)) -TimeoutSeconds ($evidenceTimeoutSeconds+10) -MaxOutputCharacters 23000000
                $imageBytes=[Convert]::FromBase64String($imageBase64.Trim())
                if($imageBytes.Length -gt 16MB){throw 'The decoded guest image exceeded the 16 MiB evidence limit.'}
                $imagePath=Join-Path $output 'window.png';[IO.File]::WriteAllBytes($imagePath,$imageBytes)
                $record.Artifacts+=@{Path='window.png';Bytes=(Get-Item -LiteralPath $imagePath).Length;SHA256=(Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash}
            }catch{$record.Errors+=('Could not retain window.png: '+$_.Exception.Message)}
        }
        $controllerPath=Join-Path $output 'controller.json'
        if(-not(Test-Path -LiteralPath $controllerPath) -or (Get-Item -LiteralPath $controllerPath).Length -gt 1MB){throw 'The guest produced no bounded controller report.'}
        $controller=Get-Content -LiteralPath $controllerPath -Raw|ConvertFrom-Json -Depth 10
        $record.ControllerResult=$controller
        if($guest.Status -eq 'Failed' -and $guest.Error){throw ('Guest target observation failed: '+$guest.Error)}
        if($payload -and ($controller.PayloadVerification.Status -ne 'Completed' -or $controller.PayloadVerification.ManifestSHA256 -ne $payloadManifestHash -or $controller.PayloadVerification.FilesVerified -ne @($payload.Files).Count -or $controller.PayloadVerification.BytesVerified -ne $payload.TotalBytes -or $guest.PayloadManifestSHA256 -ne $payloadManifestHash)){throw 'The complete package layout was not independently verified in the guest.'}
        $logonVerified=if($payload){$controller.TaskPrincipal.LogonType -eq 'InteractiveToken' -and $controller.InteractiveSession.RunId -eq $sessionReady.RunId -and $controller.InteractiveSession.AutoLogonSecretsRemoved -eq $true -and $guest.UserEnvironment.SessionId -eq $sessionReady.SessionId -and $guest.UserEnvironment.UserInteractive -eq $true}else{$controller.BatchLogonRightVerified -eq $true -and $controller.TaskPrincipal.LogonType -eq 'Password'}
        if($controller.Status -ne 'Completed' -or -not $logonVerified -or $controller.CredentialRemovedBeforeLaunch -ne $true -or $controller.TaskRemoved -ne $true -or $controller.RunnerStarted -ne $true -or $controller.RunnerExitCode -ne 0 -or $controller.Error -or $controller.TaskPrincipal.RunLevel -ne 'Limited' -or $controller.TaskPrincipal.UserId -ne $guest.GuestUser -or $controller.TaskPrincipal.UserSid -notmatch '^S-1-5-21-' -or $controller.TaskPrincipal.UserSid -ne $controller.TaskPrincipal.ExpectedUserSid -or $controller.TaskPrincipal.UserSid -ne $guest.UserEnvironment.LoadedHiveSid -or $guest.UserEnvironment.UserName -ne $manifest.GuestUser){throw 'The controller did not verify credential deletion, the expected limited task and account, successful execution, and task cleanup.'}
        if($guest.RunnerSHA256 -ne $runnerHash){throw 'The guest runner version did not match the trusted host asset.'}
        if($guest.IsAdministrator -ne $false -or $guest.Validation.AccountNotAdministrator -ne $true -or $guest.Validation.UserProfileLoaded -ne $true -or $guest.TargetSHA256 -ne $sourceHash -or $guest.Validation.HashMatched -ne $true -or $guest.Validation.NoNetworkAdapter -ne $true){throw 'The guest did not verify its standard-user account, token and profile, input hash, and disabled networking.'}
        if($LaunchMode -eq 'RegisteredPackage'){
            $profileProof=$controller.PackageDeployment.DeploymentProfile
            if($packageInput){
                $licenseProof=$controller.PackageDeployment.OfflineLicense
                if($licenseProof.Status -cne 'Completed' -or $licenseProof.ArchiveSHA256 -cne $packageInput.ArchiveSHA256 -or $licenseProof.LicenseSHA256 -cne $packageInput.LicenseSHA256 -or $licenseProof.PackageFullName -cne $controller.PackageDeployment.PackageFullName -or $licenseProof.RestartNeeded -isnot [bool] -or $licenseProof.RestartNeeded){throw 'The exact signed package and supplied offline license were not verified as provisioned without a restart.'}
            }
            $profileCleanup=$controller.PackageDeployment.DeploymentProfileCleanup
            if($profileProof.Status -ne 'Ready' -or $profileProof.UserSid -notmatch '^S-1-5-21-' -or $profileProof.PrivilegesRestored -isnot [bool] -or -not $profileProof.PrivilegesRestored -or ($profileProof.ProfileType -isnot [int] -and $profileProof.ProfileType -isnot [long] -and $profileProof.ProfileType -isnot [uint32]) -or $profileProof.ProfileType -ne 0 -or $profileCleanup.Status -ne 'Released' -or $profileCleanup.UserSid -ne $profileProof.UserSid -or $profileCleanup.Released -isnot [bool] -or -not $profileCleanup.Released -or $profileCleanup.PrivilegesRestored -isnot [bool] -or -not $profileCleanup.PrivilegesRestored){throw 'The normal local deployment profile, restored token privileges and owned profile release were not verified.'}
            $packageIdentityPattern='^'+[regex]::Escape($payload.Package.Identity.Name)+'_'+[regex]::Escape($payload.Package.Identity.Version)+'_'+[regex]::Escape($payload.Package.Identity.ProcessorArchitecture)+'_[A-Za-z0-9.]*_[a-z0-9]{13}$'
            if($controller.PackageDeployment.Status -ne 'Completed' -or $guest.PackageRegistration.Status -ne 'Completed' -or -not $controller.PackageDeployment.PackageFullName -or $controller.PackageDeployment.PackageFullName -notmatch $packageIdentityPattern -or $guest.PackageRegistration.PackageFullName -ne $controller.PackageDeployment.PackageFullName -or $guest.Execution.RootPackageFullName -ne $controller.PackageDeployment.PackageFullName -or $guest.Execution.RootUserSid -ne $guest.UserEnvironment.LoadedHiveSid -or $guest.Execution.RootAdministrator -isnot [bool] -or $guest.Execution.RootAdministrator -ne $false -or $guest.ActivatedImageSHA256 -ne $sourceHash -or -not $watchdog){throw 'The registered package image, package identity, standard token and VM deadline were not verified.'}
        }elseif($guest.Execution.JobAssigned -ne $true -or $guest.Execution.JobClosed -ne $true){throw 'The guest did not verify its bounded job assignment and cleanup.'}
        $record.Status=if($guest.Status -eq 'Completed' -and -not $record.Errors.Count){'Completed'}else{'Partial'}
        if($guest.Execution.Reason -eq 'Completed' -and $guest.Execution.ExitCode -ne 0){$record.Status='Partial';$record.Limitations+='The target exited with a nonzero code; observation completion is not successful application startup.'}
    }catch{$record.Errors+=$_.Exception.Message;$record.Status='Failed'}
    finally {
        $powerOffVerified=$false
        $verifyPowerOff={
            $current=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$manifest.VirtualMachineId,'--machinereadable'))
            if($current.UUID -ne $manifest.VirtualMachineId){throw 'VM identity changed during cleanup.'}
            if($current.VMState -in 'running','paused'){
                $null=Invoke-AnalysisWindowsVBox @('controlvm',$manifest.VirtualMachineId,'poweroff') -TimeoutSeconds 60
                $current=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$manifest.VirtualMachineId,'--machinereadable'))
                if($current.UUID -ne $manifest.VirtualMachineId){throw 'VM identity changed after power-off.'}
            }
            if($current.VMState -ne 'poweroff'){throw "Power-off could not be verified during cleanup: $($current.VMState)."}
        }
        if($restoreRequired){
            try{& $verifyPowerOff;$powerOffVerified=$true}
            catch{$record.Status='Failed';$record.Errors+=('Initial shutdown failed: '+$_.Exception.Message)}
        }
        if($watchdog){
            try{
                $record.Validation['PoweredOffBeforeWatchdogCancellation']=$powerOffVerified
                $record['WatchdogResult']=Stop-AnalysisWindowsWatchdog -Context $watchdog -WaitForExpiry:(-not $powerOffVerified)
                if($record.WatchdogResult.Status -ne 'Cancelled'){$record.Status='Failed';$record.Errors+=('The whole-VM watchdog ended with status '+$record.WatchdogResult.Status+'. '+$record.WatchdogResult.Error)}
            }catch{$record.Status='Failed';$record.Errors+=('Watchdog completion failed: '+$_.Exception.Message)}
            if($watchdog.Exited -ne $true){
                $record.Status='Failed'
                try{$record['QuarantinePath']=Set-AnalysisWindowsVmQuarantine -StoragePath $storage -Context $watchdog}
                catch{
                    $retainVmLock=$true;$record['LockRetainedForUnresolvedWatchdog']=$true
                    $record.Errors+=('Could not establish the unresolved-watchdog quarantine: '+$_.Exception.Message+' The exclusive VM lock remains held in this PowerShell process; manually verify power-off and watchdog termination before closing that process.')
                }
                $record.Errors+='The watchdog is still active. This VM requires manual power-off and watchdog verification before another run.'
            }elseif(-not $powerOffVerified -and $restoreRequired){
                # Keep the exclusive VM lock while the armed watchdog finishes,
                # then retry exact-UUID cleanup after its last possible action.
                try{& $verifyPowerOff;$powerOffVerified=$true}
                catch{$record.Status='Failed';$record.Errors+=('Shutdown retry failed: '+$_.Exception.Message)}
            }
        }
        if($restoreRequired -and $powerOffVerified -and (-not $watchdog -or $watchdog.Exited -eq $true)){
            try{
                $null=Invoke-AnalysisWindowsVBox @('snapshot',$manifest.VirtualMachineId,'restore',$manifest.SnapshotId) -TimeoutSeconds 120
                $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$manifest.VirtualMachineId,'--machinereadable'))
                Assert-AnalysisWindowsVmIsolation $settings $manifest
                $record.Validation.CleanSnapshotRestoredAfter=$settings.CurrentSnapshotUUID -eq $manifest.SnapshotId
                $record.Validation.PoweredOffAfter=$settings.VMState -eq 'poweroff'
                if(-not $record.Validation.CleanSnapshotRestoredAfter -or -not $record.Validation.PoweredOffAfter){throw 'The final clean snapshot and power-off state could not be verified.'}
            }catch{$record.Status='Failed';$record.Errors+=('Cleanup failed: '+$_.Exception.Message)}
        }
        foreach($file in $passwordFiles){try{if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}}catch{$record.Status='Failed';$record.Errors+='A temporary guest credential could not be removed.'}}
        try{$record.Validation.SourceUnchanged=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -eq $sourceHash}catch{$record.Validation.SourceUnchanged=$false}
        if($payload){
            try{
                Write-Verbose 'Verifying that every source payload file and directory is unchanged after the run.'
                $record['PayloadSourceVerification']=Test-AnalysisWindowsPayloadSource -Payload $payload
                $record.Validation['PayloadSourceUnchanged']=$record.PayloadSourceVerification.Status -eq 'Completed'
            }catch{$record.Validation['PayloadSourceUnchanged']=$false;$record.Errors+=('Source package changed during observation: '+$_.Exception.Message)}
            if(-not $record.Validation.PayloadSourceUnchanged){$record.Status='Failed'}
        }
        if(-not $record.Validation.SourceUnchanged){$record.Status='Failed';$record.Errors+='The source input changed during analysis.'}
        if($packageInput){
            try{
                $record.PackageInputSourceVerification=Test-AnalysisWindowsPackageInputSource -PackageInput $packageInput
                $record.Validation.PackageInputsUnchanged=$record.PackageInputSourceVerification.Status -eq 'Completed'
            }catch{$record.Validation.PackageInputsUnchanged=$false;$record.Errors+=('Signed package inputs changed during observation: '+$_.Exception.Message)}
            if(-not $record.Validation.PackageInputsUnchanged){$record.Status='Failed'}
        }
        $record.FinishedUtc=[DateTime]::UtcNow.ToString('o')
        try{if($outputSafe -and (Test-Path -LiteralPath $output -PathType Container)){$record|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $output 'runtime-host.json') -Encoding utf8}}
        finally{
            if($vmLock){
                if($retainVmLock){
                    if(-not $script:AnalysisWindowsQuarantineLocks){$script:AnalysisWindowsQuarantineLocks=[Collections.Generic.List[IDisposable]]::new()}
                    $script:AnalysisWindowsQuarantineLocks.Add($vmLock)
                }else{$vmLock.Dispose()}
            }
        }
    }
    [pscustomobject]$record
}
