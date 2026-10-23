function Invoke-ExecutableAnalysisWindowsVm {
    <#
    .SYNOPSIS
    Observes an executable inside an owned, offline disposable Windows VM.
    .DESCRIPTION
    Accepts x86/x64 PE executables, never DLLs or host execution. Requires a Windows VM
    created by Initialize-ExecutableAnalysisWindowsVm. Runs with a standard guest token,
    no arguments, a bounded Windows Job, networking disabled, and no shared folders.
    An exclusive per-VM lock prevents concurrent runs. Restores the exact powered-off
    clean snapshot before execution and in finally, including after guest failures.
    Observations are bounded snapshots and process polling, not a complete system trace.
    .PARAMETER OutputPath
    A new or empty host directory for retained observations and the host manifest.
    .EXAMPLE
    Invoke-ExecutableAnalysisWindowsVm -InputPath .\program.exe -OutputPath .\runtime
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$VirtualMachineName='Profile-Analysis-Windows',
        [ValidateRange(1,600)][int]$TimeoutSeconds=120
    )
    $ErrorActionPreference='Stop'
    if(-not $IsWindows){throw 'Windows VM analysis requires PowerShell 7 on Windows.'}
    $assets=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis'
    . (Join-Path $assets 'WindowsVm.Common.ps1')
    $trustedRunner=Join-Path $assets 'WindowsGuestRunner.ps1'
    if(-not(Test-Path -LiteralPath $trustedRunner -PathType Leaf)){throw 'The trusted Windows guest runner asset is missing.'}
    $trustedController=Join-Path $assets 'WindowsGuestController.ps1'
    if(-not(Test-Path -LiteralPath $trustedController -PathType Leaf)){throw 'The trusted Windows profile-loading controller is missing.'}
    $runnerHash=(Get-FileHash -LiteralPath $trustedRunner -Algorithm SHA256).Hash
    $inputItem=Get-Item -LiteralPath $InputPath -ErrorAction Stop
    if($inputItem.PSIsContainer -or ($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'InputPath must name a regular executable file.'}
    $source=$inputItem.FullName
    if(-not(Test-AnalysisWindowsPe $source)){throw 'Windows runtime analysis supports x86/x64 PE executables; DLLs, nonexecutables, and other formats require a different harness.'}
    $sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
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
    if(-not $PSCmdlet.ShouldProcess($VirtualMachineName,'Restore the verified offline clean snapshot, run the executable as a bounded standard-user job, and restore the snapshot again')){return}
    $vmLock=$null;$passwordFiles=[Collections.Generic.List[string]]::new();$restoreRequired=$false
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
        $null=[IO.Directory]::CreateDirectory($output)
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
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@($source,'C:\ProfileAnalysis\Work\target.exe')) -TimeoutSeconds 120
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
        $launchFile=Join-Path $storage ('runtime-'+[guid]::NewGuid().ToString('N')+'.json');$passwordFiles.Add($launchFile)
        [IO.File]::WriteAllText($launchFile,'');Protect-AnalysisWindowsPrivatePath $launchFile
        $guestCredential=Import-Clixml -LiteralPath $manifest.CredentialPath
        @{UserName=$manifest.GuestUser;UserPassword=$guestCredential.GetNetworkCredential().Password;TimeoutSeconds=$TimeoutSeconds;ExpectedSHA256=$sourceHash}|ConvertTo-Json -Compress|Set-Content -LiteralPath $launchFile -Encoding utf8
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@($launchFile,'C:\ProfileAnalysis\Private\launch.json')) -TimeoutSeconds 60
        Remove-Item -LiteralPath $launchFile -Force
        $null=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'copyto')+$auth.Admin+@($trustedController,'C:\ProfileAnalysis\Private\Controller.ps1')) -TimeoutSeconds 60
        $executionError=$null
        try{
            $run=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$auth.Admin+@('--exe','C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','--timeout',(($TimeoutSeconds+330)*1000).ToString(),'--wait-stdout','--wait-stderr','--','-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','C:\ProfileAnalysis\Private\Controller.ps1')) -TimeoutSeconds ($TimeoutSeconds+360)
            $run|Set-Content -LiteralPath (Join-Path $output 'guest-runner.log') -Encoding utf8
        }catch{$executionError=$_.Exception.Message;$record.Errors+=$executionError}
        foreach($file in @('controller.json','runner-stdout.txt','runner-stderr.txt','runtime.json','stdout.txt','stderr.txt','files-before.json','files-after.json','registry-before.json','registry-after.json','network-before.json','network-after.json')){
            try{
                $destination=Join-Path $output $file
                $guestEvidencePath=if($file -eq 'controller.json'){'C:\ProfileAnalysis\Private\controller.json'}else{'C:\ProfileAnalysis\Results\'+$file}
                $evidenceAuth=if($file -eq 'controller.json'){$auth.Admin}else{$auth.Guest}
                # Read through a fixed trusted command and a host-side bounded pipe. A
                # guest-controlled size claim must never authorize an unbounded copy.
                $transferScript=@"
`$ErrorActionPreference='Stop'
`$stream=[IO.File]::OpenRead('$guestEvidencePath')
try{`$buffer=New-Object byte[] (16777217);`$total=0;while(`$total -lt `$buffer.Length){`$count=`$stream.Read(`$buffer,`$total,`$buffer.Length-`$total);if(`$count -eq 0){break};`$total+=`$count};if(`$total -gt 16777216){throw 'Guest evidence exceeds 16 MiB'};[Console]::Write([Convert]::ToBase64String(`$buffer,0,`$total))}finally{`$stream.Dispose()}
"@
                $transferEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($transferScript))
                $encodedEvidence=Invoke-AnalysisWindowsVBox (@('guestcontrol',$manifest.VirtualMachineId,'run')+$evidenceAuth+@('--exe','C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe','--timeout','30000','--wait-stdout','--wait-stderr','--','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$transferEncoded)) -TimeoutSeconds 40 -MaxOutputCharacters 23000000
                [IO.File]::WriteAllBytes($destination,[Convert]::FromBase64String($encodedEvidence.Trim()))
                $artifact=Get-Item -LiteralPath $destination
                if($artifact.Length -gt 16MB -or ($artifact.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A guest artifact exceeded the 16 MiB evidence limit or was a reparse point.'}
                $record.Artifacts+=@{Path=$file;Bytes=$artifact.Length;SHA256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash}
            }catch{$record.Errors+=('Could not retain '+$file+': '+$_.Exception.Message)}
        }
        $runtimePath=Join-Path $output 'runtime.json'
        if(-not(Test-Path -LiteralPath $runtimePath)){throw 'The guest produced no retained runtime report.'}
        if((Get-Item -LiteralPath $runtimePath).Length -gt 1MB){throw 'The guest runtime report exceeded its size limit.'}
        $guest=Get-Content -LiteralPath $runtimePath -Raw|ConvertFrom-Json -Depth 20
        $record.GuestResult=$guest
        $controllerPath=Join-Path $output 'controller.json'
        if(-not(Test-Path -LiteralPath $controllerPath) -or (Get-Item -LiteralPath $controllerPath).Length -gt 1MB){throw 'The guest produced no bounded controller report.'}
        $controller=Get-Content -LiteralPath $controllerPath -Raw|ConvertFrom-Json -Depth 10
        $record.ControllerResult=$controller
        if($controller.Status -ne 'Completed' -or $controller.BatchLogonRightVerified -ne $true -or $controller.CredentialRemovedBeforeLaunch -ne $true -or $controller.TaskRemoved -ne $true -or $controller.RunnerStarted -ne $true -or $controller.RunnerExitCode -ne 0 -or $controller.Error -or $controller.TaskPrincipal.LogonType -ne 'Password' -or $controller.TaskPrincipal.RunLevel -ne 'Limited' -or $controller.TaskPrincipal.UserId -ne $guest.GuestUser -or $controller.TaskPrincipal.UserSid -notmatch '^S-1-5-21-' -or $controller.TaskPrincipal.UserSid -ne $controller.TaskPrincipal.ExpectedUserSid -or $controller.TaskPrincipal.UserSid -ne $guest.UserEnvironment.LoadedHiveSid -or $guest.UserEnvironment.UserName -ne $manifest.GuestUser){throw 'The controller did not verify credential deletion, the expected limited task and account, successful execution, and task cleanup.'}
        if($guest.RunnerSHA256 -ne $runnerHash){throw 'The guest runner version did not match the trusted host asset.'}
        if($guest.IsAdministrator -ne $false -or $guest.Validation.AccountNotAdministrator -ne $true -or $guest.Validation.UserProfileLoaded -ne $true -or $guest.TargetSHA256 -ne $sourceHash -or $guest.Validation.HashMatched -ne $true -or $guest.Validation.NoNetworkAdapter -ne $true){throw 'The guest did not verify its standard-user account, token and profile, input hash, and disabled networking.'}
        if($guest.Status -eq 'Failed' -and $guest.Error){throw ('Guest target observation failed: '+$guest.Error)}
        if($guest.Execution.JobAssigned -ne $true -or $guest.Execution.JobClosed -ne $true){throw 'The guest did not verify its bounded job assignment and cleanup.'}
        $record.Status=if($guest.Status -eq 'Completed' -and -not $record.Errors.Count){'Completed'}else{'Partial'}
    }catch{$record.Errors+=$_.Exception.Message;$record.Status='Failed'}
    finally {
        if($restoreRequired){
            try{
                $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox @('showvminfo',$manifest.VirtualMachineId,'--machinereadable'))
                if($settings.UUID -ne $manifest.VirtualMachineId){throw 'VM identity changed during cleanup.'}
                if($settings.VMState -in 'running','paused'){$null=Invoke-AnalysisWindowsVBox @('controlvm',$manifest.VirtualMachineId,'poweroff') -TimeoutSeconds 60}
                elseif($settings.VMState -ne 'poweroff'){throw "Unexpected VM state during cleanup: $($settings.VMState)."}
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
        if(-not $record.Validation.SourceUnchanged){$record.Status='Failed';$record.Errors+='The source input changed during analysis.'}
        $record.FinishedUtc=[DateTime]::UtcNow.ToString('o')
        try{if(Test-Path -LiteralPath $output -PathType Container){$record|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $output 'runtime-host.json') -Encoding utf8}}
        finally{if($vmLock){$vmLock.Dispose()}}
    }
    [pscustomobject]$record
}
