#requires -Version 7.0
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'These Windows credential and VM behavior tests require PowerShell 7 on Windows.'}
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$TestRoot=(Get-Item -LiteralPath $TestRoot).FullName
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/ExecutableAnalysis/WindowsVm.Common.ps1')
function Assert-True {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Assert-Throws {param([scriptblock]$Action,[string]$Message)$thrown=$false;try{& $Action}catch{$thrown=$true};Assert-True $thrown $Message}

$parsed=ConvertFrom-AnalysisWindowsVmInfo "name=`"Fixture`"`r`ncpus=1`r`nmemory=6144`r`nVMState=`"poweroff`""
Assert-True ($parsed.cpus -eq '1' -and $parsed.memory -eq '6144' -and $parsed.VMState -eq 'poweroff') 'Unquoted VirtualBox numeric settings were not parsed.'

# The actual parser rejects other operating systems, DLLs, malformed offsets and objects.
$header=[byte[]]::new(256);$header[0]=0x4d;$header[1]=0x5a;$header[60]=128
$header[128]=0x50;$header[129]=0x45;$header[132]=0x64;$header[133]=0x86;$header[150]=2
$inputPath=Join-Path $TestRoot 'literal & $(must-not-run) [1].exe'
[IO.File]::WriteAllBytes($inputPath,$header)
Assert-True (Test-AnalysisWindowsPe $inputPath) 'An x64 executable header was rejected.'
$header[132]=0x4c;$header[133]=1;[IO.File]::WriteAllBytes($inputPath,$header)
Assert-True (Test-AnalysisWindowsPe $inputPath) 'An x86 executable header was rejected.'
foreach($fault in @(@{Index=151;Value=0x20},@{Index=150;Value=0},@{Index=60;Value=255},@{Index=0;Value=0x7f},@{Index=133;Value=0xaa})){
    $broken=$header.Clone();$broken[$fault.Index]=$fault.Value
    $file=Join-Path $TestRoot ('invalid-'+$fault.Index+'.exe');[IO.File]::WriteAllBytes($file,$broken)
    Assert-True (-not(Test-AnalysisWindowsPe $file)) ('Unsafe PE header was accepted: '+$fault.Index)
}
$empty=Join-Path $TestRoot 'empty';[IO.File]::WriteAllBytes($empty,[byte[]]@())
Assert-True (-not(Test-AnalysisWindowsPe $empty)) 'An empty input was accepted.'
Write-Host 'PASS: actual PE validation rejects unsupported architecture, DLLs, objects, and malformed inputs'

$owned=Join-Path $TestRoot 'owned';$null=[IO.Directory]::CreateDirectory($owned)
$manifest=[ordered]@{Schema='PowerShellProfile.AnalysisWindowsVm.v1';GuestOS='Windows 11 x64';VirtualMachineName='Fixture-Windows';VirtualMachineId='11111111-2222-3333-4444-555555555555';StoragePath=$owned;Status='Ready';SnapshotId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';GuestUser='fixture-standard';AdminUser='fixture-admin';CredentialPath=(Join-Path $owned 'guest.clixml');AdminCredentialPath=(Join-Path $owned 'admin.clixml')}
$valid=@{UUID=$manifest.VirtualMachineId;name=$manifest.VirtualMachineName;VMState='poweroff';CurrentSnapshotUUID=$manifest.SnapshotId;clipboard='disabled';draganddrop='disabled';clipboard_file_transfers='off'}
foreach($key in @('usb','ehci','xhci','vrde','audio_in','audio_out','nested-hw-virt','teleporterenabled')){$valid[$key]='off'}
foreach($index in 1..8){$valid["nic$index"]='none'};foreach($index in 1..4){$valid["uart$index"]='off'}
$valid['SATA-0-0']=Join-Path $owned 'owned.vdi'
Assert-AnalysisWindowsVmIsolation $valid ([pscustomobject]$manifest)
foreach($fault in @(@{Key='nic8';Value='nat'},@{Key='nic9';Value='nat'},@{Key='nic36';Value='intnet'},@{Key='usb';Value='on'},@{Key='clipboard';Value='bidirectional'},@{Key='SharedFolderNameMachineMapping1';Value='host'},@{Key='UUID';Value='unrelated'},@{Key='SATA-1-0';Value=(Join-Path $owned 'host.iso')},@{Key='SATA-0-0';Value=(Join-Path $TestRoot 'outside.vdi')})){
    $broken=$valid.Clone();$broken[$fault.Key]=$fault.Value
    Assert-Throws {Assert-AnalysisWindowsVmIsolation $broken ([pscustomobject]$manifest)} ('Unsafe VM state was accepted: '+$fault.Key)
}
$broken=$valid.Clone();$broken.Remove('uart4');Assert-Throws {Assert-AnalysisWindowsVmIsolation $broken ([pscustomobject]$manifest)} 'Unknown UART state was accepted.'
Write-Host 'PASS: actual isolation validator rejects unknown settings, external storage, networking, and host integration'

# Cross the actual launcher, child-script and watchdog parameter boundaries.
# The inert manifest deliberately fails before the first VBox call, so this
# verifies licensed/default/maximum budgets without accessing any real VM.
$rejectedManifest=Join-Path $owned 'watchdog-not-ready.json'
@{Status='FixtureNotReady';VirtualMachineId=$manifest.VirtualMachineId;VirtualMachineName='Fixture-Only';StoragePath=$owned}|ConvertTo-Json|Set-Content -LiteralPath $rejectedManifest
foreach($deadline in 1201,1620,1800,2100){
    $failure=$null
    try{$null=Start-AnalysisWindowsWatchdog -VirtualMachineId $manifest.VirtualMachineId -OwnershipManifestPath $rejectedManifest -EvidenceDirectory (Join-Path $owned ('watchdog-boundary-'+$deadline)) -DeadlineSeconds $deadline}catch{$failure=$_}
    Assert-True ($null -ne $failure -and $failure.Exception.Message.Contains('The watchdog requires the exact ready owned VM identity.')) ('A valid watchdog deadline failed parameter validation or escaped the inert manifest gate: '+$deadline)
}
foreach($deadline in 0,2101){
    $failure=$null
    try{$null=Start-AnalysisWindowsWatchdog -VirtualMachineId $manifest.VirtualMachineId -OwnershipManifestPath $rejectedManifest -EvidenceDirectory (Join-Path $owned ('watchdog-invalid-'+$deadline)) -DeadlineSeconds $deadline}catch{$failure=$_}
    Assert-True ($null -ne $failure -and $failure.FullyQualifiedErrorId -like 'ParameterArgumentValidationError*') 'An out-of-range watchdog deadline crossed the launch boundary.'
}
Write-Host 'PASS: real watchdog launcher and child parameter validation accept all runtime budgets through 2100 seconds and reject out-of-range values before any VM access'

# Exercise the actual expiry-wait helper using a fake process only. No watchdog,
# VBox command, target, or live VM is started by these completion fixtures.
foreach($outcome in @('Cancelled','Expired','Failed','Hung')){
    $evidence=Join-Path $TestRoot ('watchdog-wait-'+$outcome);$null=[IO.Directory]::CreateDirectory($evidence)
    $fakeProcess=[pscustomobject]@{HasExited=$false;WaitCalls=0;Killed=$false;Disposed=$false;MaximumWait=if($outcome -eq 'Cancelled'){10000}else{1000}}
    $fakeProcess|Add-Member ScriptMethod WaitForExit {param([int]$Milliseconds) if($Milliseconds -gt $this.MaximumWait){throw 'Watchdog waits must use bounded slices.'};$this.WaitCalls++;$this.HasExited=$true;return $true}
    $fakeProcess|Add-Member ScriptMethod Kill {param([bool]$Tree)$this.Killed=$true;throw 'An armed watchdog must not be killed by expiry wait.'}
    $fakeProcess|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
    $context=[pscustomobject]@{Process=$fakeProcess;EvidenceDirectory=$evidence;DeadlineSeconds=2100;DeadlineTimer=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=if($outcome -eq 'Hung'){2200}else{0}}};Ready=[pscustomobject]@{BoundUUID=$manifest.VirtualMachineId;WatchdogId='0123456789abcdef0123456789abcdef'}}
    if($outcome -eq 'Hung'){
        Assert-Throws {Stop-AnalysisWindowsWatchdog -Context $context -WaitForExpiry} 'A live watchdog exceeded its deadline without failure.'
        Assert-True (-not $context.Exited -and -not $fakeProcess.Disposed -and $fakeProcess.WaitCalls -eq 0) 'Expiry timeout disposed or misreported the unresolved live watchdog.'
    }else{
        @{Status=$outcome;BoundUUID=$context.Ready.BoundUUID;WatchdogId=$context.Ready.WatchdogId}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $evidence 'result.json')
        $completion=Stop-AnalysisWindowsWatchdog -Context $context -WaitForExpiry:($outcome -ne 'Cancelled')
        Assert-True ($completion.Status -eq $outcome -and $context.Exited -and $fakeProcess.Disposed -and $fakeProcess.WaitCalls -eq 1) 'Expiry wait did not preserve the terminal watchdog result.'
    }
    Assert-True (-not $fakeProcess.Killed -and ((Test-Path -LiteralPath (Join-Path $evidence 'cancel.json')) -eq ($outcome -eq 'Cancelled'))) 'Watchdog completion used the wrong cancellation policy.'
}
Write-Host 'PASS: actual watchdog expiry wait is bounded, never cancels or kills, and preserves expiry/failure evidence'

# Run the real orchestration body with only its VBox process boundary mocked. It must
# neither need VirtualBox nor install software, start a VM, or execute an input in CI.
$runtimeSource=[IO.File]::ReadAllText((Join-Path $repo 'functions/Invoke-ExecutableAnalysisWindowsVm.ps1'))
$runtimeSource=$runtimeSource.Replace(". (Join-Path `$assets 'WindowsVm.Common.ps1')",'# Already imported the actual helpers; replace only the VBox process boundary below.')
$script:fixtureAssets=Join-Path $repo 'scripts/ExecutableAnalysis'
$runtimeSource=$runtimeSource.Replace("`$assets=Join-Path (Split-Path `$PSScriptRoot -Parent) 'scripts/ExecutableAnalysis'",'$assets=$script:fixtureAssets')
$runtimeSource=$runtimeSource.Replace('$sessionTimer=[Diagnostics.Stopwatch]::StartNew()','$sessionTimer=New-FixtureSessionTimer')
. ([scriptblock]::Create($runtimeSource))
$manifestPath=Join-Path $owned 'manifest.json';$manifest|ConvertTo-Json|Set-Content -LiteralPath $manifestPath -Encoding utf8
$script:fixtureManifestPath=$manifestPath
foreach($role in @('Guest','Admin')){
    $user=if($role -eq 'Guest'){$manifest.GuestUser}else{$manifest.AdminUser}
    $path=if($role -eq 'Guest'){$manifest.CredentialPath}else{$manifest.AdminCredentialPath}
    [pscredential]::new($user,(ConvertTo-SecureString 'FixtureOnly-NeverUsedOutsideMock-123!' -AsPlainText -Force))|Export-Clixml -LiteralPath $path
}
$script:vmSettings=$valid.Clone();$script:mutations=0;$script:restores=0;$script:failGuest=$false;$script:failFinalRestore=$false;$script:pauseGuest=$false
$script:vboxCalls=0;$script:packageCase=$null;$script:payloadObserved=$null
$script:sessionRunId='0123456789abcdef0123456789abcdef';$script:sessionId=7
$script:expectedObservationSeconds=1
$script:progressCase=$null;$script:progressEvidenceReads=@()
$script:imageCase=$null;$script:imageReads=0;$script:imageTransferScript=$null
$inputHash=(Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
# Fake VBox replies are immediately ready; wall-clock boot sleeps add no coverage.
# Restore the real command before the initializer and guest-controller checks.
function Start-Sleep {param([int]$Seconds) Assert-True ($Seconds -eq 3) 'Unexpected wait in mocked VM orchestration.'}
function New-FixtureSessionTimer {
    $script:sessionMarkerCalls=0;$script:sessionVerifyCalls=0;$script:sessionMarkerReady=$false
    if($script:packageCase -ne 'session-marker-timeout'){return [Diagnostics.Stopwatch]::StartNew()}
    # Advance the observation clock across the exact deadline without a 600-second wait.
    $state=@{Next=599.0};$timer=[pscustomobject]@{}
    $timer|Add-Member ScriptProperty Elapsed {$elapsed=$state.Next;$state.Next+=1.0;[pscustomobject]@{TotalSeconds=$elapsed}}.GetNewClosure()
    return $timer
}
function Start-AnalysisWindowsWatchdog {
    param([string]$VirtualMachineId,[string]$OwnershipManifestPath,[int]$DeadlineSeconds,[string]$EvidenceDirectory)
    $expectedAllowance=if($script:packageCase -like 'registered-license-*'){1500}else{1200}
    Assert-True ($VirtualMachineId -eq $manifest.VirtualMachineId -and $OwnershipManifestPath -eq $manifestPath -and $DeadlineSeconds -eq ($script:expectedObservationSeconds+$expectedAllowance) -and $EvidenceDirectory) 'The watchdog was not bound to the owned VM and exact licensed or unlicensed deadline.'
    $script:watchdogDeadlineObserved=$DeadlineSeconds
    $script:watchdogStarts++
    if($script:packageCase -eq 'watchdog-start-failure'){throw 'Fixture watchdog readiness was not established.'}
    return [pscustomobject]@{Exited=$false;Ready=[pscustomobject]@{PID=12345;BoundUUID=$VirtualMachineId;WatchdogId='1234567890abcdef1234567890abcdef'}}
}
function Stop-AnalysisWindowsWatchdog {
    param([psobject]$Context,[switch]$WaitForExpiry)
    Assert-True ($Context.Ready.BoundUUID -eq $manifest.VirtualMachineId) 'The watchdog cancellation targeted another VM.'
    Assert-Throws {Enter-AnalysisWindowsVmLock $owned} 'The VM lock was released before watchdog termination.'
    if($WaitForExpiry){
        $script:watchdogWaits++
        if($script:packageCase -in 'shutdown-watchdog-hung','shutdown-quarantine-failure'){throw 'Fixture watchdog remains active after bounded expiry wait.'}
        $Context.Exited=$true
        if($script:packageCase -eq 'shutdown-watchdog-failed'){return [pscustomobject]@{Status='Failed';BoundUUID=$Context.Ready.BoundUUID;Error='Fixture watchdog power-off failed.'}}
        $script:vmSettings.VMState='poweroff'
        return [pscustomobject]@{Status='Expired';BoundUUID=$Context.Ready.BoundUUID;PowerOffVerified=$true}
    }
    Assert-True ($script:vmSettings.VMState -eq 'poweroff') 'The independent watchdog was cancelled before verified VM power-off.'
    $script:watchdogCancellations++;$Context.Exited=$true
    if($script:packageCase -eq 'watchdog-failure'){throw 'Fixture watchdog did not confirm cancellation.'}
    if($script:packageCase -eq 'source-mutation'){[IO.File]::WriteAllText((Join-Path $packageRoot 'app/resources/added-during-runtime.txt'),'Changed after preservation.')}
    if($script:packageCase -like 'registered-license-*-mutation'){
        $changedPath=switch($script:packageCase){
            'registered-license-source-archive-mutation' {$script:licenseSourceArchive}
            'registered-license-source-license-mutation' {$script:licenseSourceLicense}
            'registered-license-preserved-archive-mutation' {$script:licensePreservedArchive}
            'registered-license-preserved-license-mutation' {$script:licensePreservedLicense}
        }
        Assert-True ([bool]$changedPath -and $changedPath.StartsWith($TestRoot,[StringComparison]::OrdinalIgnoreCase)) 'Package-input mutation escaped the isolated fixture root.'
        [IO.File]::AppendAllText($changedPath,'Fixture mutation after observation.')
    }
    return [pscustomobject]@{Status=if($script:packageCase -eq 'watchdog-expired'){'Expired'}else{'Cancelled'};BoundUUID=$Context.Ready.BoundUUID}
}
$script:realSetQuarantine=(Get-Command Set-AnalysisWindowsVmQuarantine).ScriptBlock
function Set-AnalysisWindowsVmQuarantine {
    param([string]$StoragePath,[psobject]$Context)
    if($script:packageCase -eq 'shutdown-quarantine-failure'){throw 'Fixture quarantine persistence failed.'}
    & $script:realSetQuarantine -StoragePath $StoragePath -Context $Context
}
function Invoke-AnalysisWindowsVBox {
    param([string[]]$ArgumentList,[int]$TimeoutSeconds=60,[int]$MaxOutputCharacters=1048576)
    $script:vboxCalls++
    if($script:licenseFixtureSentinel){foreach($argument in $ArgumentList){Assert-True (-not $argument.Contains($script:licenseFixtureSentinel)) 'License content appeared in VBox process arguments.'}}
    foreach($sentinel in $script:baselineSecretSentinels){foreach($argument in $ArgumentList){Assert-True (-not $argument.Contains($sentinel)) 'A baseline credential appeared in a VBox process argument.'}}
    if($script:freshMode){
        switch($ArgumentList[0]){
            'list' {return ''}
            'unattended' {
                if($ArgumentList[1] -eq 'detect'){return "OSTypeId=`"Windows11_64`"`nImageIndex6=Windows 11 Pro"}
                $postInstallArgument=@($ArgumentList|Where-Object {$_ -like '--post-install-command=*'})
                Assert-True ($postInstallArgument.Count -eq 1 -and $postInstallArgument[0] -match ' -EncodedCommand ([A-Za-z0-9+/=]+)$') 'The fixed post-install command was not passed as one encoded argument.'
                $script:postInstallRecipe=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
                Assert-True ($script:postInstallRecipe.IndexOf('Start-Service') -lt $script:postInstallRecipe.IndexOf("Set-Content -LiteralPath 'C:\profile-setup-ready.txt'")) 'Readiness was published before starting the guest-control service.'
                $script:vmSettings.VMState='running'
                if($script:freshMode -eq 'unattended-failure'){throw 'Mock unattended installation failed'}
                Assert-True $script:resetConversion 'Setup did not arm its one-time reboot boundary.'
                $script:vmSettings.VMState='poweroff'
                return ''
            }
            'createvm' {$script:vmSettings.name=$ArgumentList[2];return ''}
            'setextradata' {
                if($ArgumentList[2] -eq 'VBoxInternal2/TurnResetIntoPowerOff'){$script:resetConversion=$ArgumentList.Count -eq 4 -and $ArgumentList[3] -eq '1'}
                return ''
            }
            'guestproperty' {
                Assert-True ($ArgumentList[2] -eq $script:vmSettings.UUID -and $ArgumentList[3] -eq '/VirtualBox/HostInfo/VMPowerOffReason') 'Setup queried the wrong reboot evidence.'
                if($script:freshMode -eq 'unexpected-poweroff'){return 'Value: PowerOff'}
                return 'Value: Reset'
            }
            'modifyvm' {
                if($ArgumentList -contains '--cpus'){
                    $cpu=$ArgumentList[[Array]::IndexOf($ArgumentList,'--cpus')+1]
                    if($cpu -eq '1'){
                        Assert-True ($script:vmSettings.VMState -eq 'poweroff' -and -not $script:resetConversion) 'CPU changed while running or without disarming reboot conversion.'
                        $script:firstBootConfigured=$true
                    }
                    $script:vmSettings.cpus=if($script:freshMode -eq 'cpu-verification-failure'){'4'}else{$cpu}
                }
                return ''
            }
            {$_ -in 'createmedium','storagectl','storageattach'} {return ''}
            'guestcontrol' {
                Assert-True ($script:firstBootConfigured -and $script:vmSettings.cpus -eq '1') 'Guest readiness was trusted before the first-boot transition.'
                if($ArgumentList[2] -eq 'copyto'){
                    $script:provisioningFileObserved=$ArgumentList[-2]
                    Assert-True (Test-Path -LiteralPath $script:provisioningFileObserved) 'The protected provisioning file was not created.'
                    Assert-True ((Get-Acl -LiteralPath $script:provisioningFileObserved).AreAccessRulesProtected) 'The provisioning secret file inherited ambient access.'
                    $pendingManifest=Get-Content -LiteralPath (Join-Path $script:freshStorage 'analysis-windows-vm.json') -Raw|ConvertFrom-Json
                    foreach($pending in @(@($pendingManifest.PendingGuestCredentialPath,'analysis-user'),@($pendingManifest.PendingAdminCredentialPath,'Administrator'),@($pendingManifest.BootstrapCredentialPath,'Administrator'))){
                        Assert-True ((Import-Clixml -LiteralPath $pending[0]).UserName -eq $pending[1]) 'Recoverable DPAPI credentials were not saved before guest mutation.'
                        Assert-True ((Get-Acl -LiteralPath $pending[0]).AreAccessRulesProtected) 'A retained credential inherited ambient access.'
                    }
                    return ''
                }
                if($ArgumentList -contains '-File'){
                    Assert-True ($ArgumentList -contains '300000' -and $TimeoutSeconds -eq 310) 'Provisioning did not retain its bounded cold-start allowance.'
                    if($script:freshMode -eq 'manifest-write-failure'){
                        $readonly=Get-Item -LiteralPath (Join-Path $script:freshStorage 'analysis-windows-vm.json')
                        $readonly.IsReadOnly=$true
                    }
                    throw 'Mock guest provisioning failed after protected file creation'
                }
                return 'ready'
            }
        }
    }
    switch($ArgumentList[0]){
        'list' {return '"'+$manifest.VirtualMachineName+'" {'+$manifest.VirtualMachineId+'}'+"`r`n"}
        'showvminfo' {
            if($script:cleanupReady -and $script:packageCase -in 'shutdown-query-failure','shutdown-watchdog-hung','shutdown-quarantine-failure' -and -not $script:shutdownFailureInjected){$script:shutdownFailureInjected=$true;throw 'Fixture initial shutdown query failed.'}
            return ($script:vmSettings.GetEnumerator()|ForEach-Object {'{0}="{1}"' -f $_.Key,$_.Value}) -join "`n"
        }
        'getextradata' {return 'Value: '+$script:fixtureManifestPath}
        'snapshot' {
            if($ArgumentList[2] -eq 'list'){return 'SnapshotUUID="'+$manifest.SnapshotId+'"'+"`r`n"}
            $script:mutations++;$script:restores++
            if($script:failFinalRestore -and $script:restores -eq 2){throw 'Mock final snapshot restore failed'}
            Assert-True ($ArgumentList[3] -eq $manifest.SnapshotId) 'Runtime restored a snapshot other than the recorded UUID.'
            $script:vmSettings.VMState='poweroff';return ''
        }
        'startvm' {$script:mutations++;$script:vmStarts++;$script:vmSettings.VMState='running';return ''}
        'controlvm' {
            if($script:cleanupReady -and $script:packageCase -in 'shutdown-poweroff-failure','shutdown-watchdog-failed' -and -not $script:shutdownFailureInjected){$script:shutdownFailureInjected=$true;throw 'Fixture initial power-off command failed.'}
            $script:mutations++;$script:vmSettings.VMState='poweroff';return ''
        }
        'guestcontrol' {
            if($ArgumentList[2] -eq 'copyto'){
                if($ArgumentList[-1] -like '*\target.exe'){Assert-True ($ArgumentList[-2] -eq $inputPath) 'Input path changed instead of remaining a literal process argument.'}
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\launch.json'){
                    $script:launchFileObserved=$ArgumentList[-2]
                    Assert-True ((Get-Acl -LiteralPath $script:launchFileObserved).AreAccessRulesProtected) 'The profile launch credential inherited ambient access.'
                    $launch=Get-Content -LiteralPath $script:launchFileObserved -Raw|ConvertFrom-Json
                    Assert-True ($launch.UserName -eq $manifest.GuestUser -and $launch.ExpectedSHA256 -eq $inputHash -and $launch.TimeoutSeconds -eq $script:expectedObservationSeconds) 'The private standard-user launch configuration changed.'
                    if($script:packageCase){Assert-True ($launch.PayloadManifestSHA256 -eq $script:payloadManifestHash -and $launch.InteractiveSessionId -eq $script:sessionId -and $launch.InteractiveSessionRunId -eq $script:sessionRunId) 'Packaged launch lost payload identity or the verified interactive session.'}
                    if($script:packageCase -like 'registered-*'){Assert-True ($launch.LaunchMode -eq 'RegisteredPackage') 'Registered launch mode did not reach the trusted controller configuration.'}
                    if($script:packageCase -like 'registered-license-*'){
                        Assert-True ($launch.PackageArchiveSHA256 -ceq $script:licenseArchiveHash -and $launch.PackageLicenseSHA256 -ceq $script:licenseXmlHash -and -not $launch.PSObject.Properties['PackageArchivePath'] -and -not $launch.PSObject.Properties['PackageLicensePath']) 'The private launch configuration lost exact package/license hashes or leaked host paths.'
                        $script:licenseLaunchHashesVerified=$true
                    }
                    if($script:failLaunchCopy){throw 'Mock private credential copy failed'}
                }
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\WindowsGuestSession.ps1'){Assert-True ($ArgumentList[-2] -eq (Join-Path $script:fixtureAssets 'WindowsGuestSession.ps1')) 'Interactive session setup did not use its trusted helper.'}
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\session-config.json'){
                    $script:sessionFileObserved=$ArgumentList[-2]
                    Assert-True ((Get-Acl -LiteralPath $script:sessionFileObserved).AreAccessRulesProtected) 'Session credential inherited ambient access.'
                    $sessionConfiguration=Get-Content -LiteralPath $script:sessionFileObserved -Raw|ConvertFrom-Json
                    Assert-True ($sessionConfiguration.UserName -eq $manifest.GuestUser) 'Interactive session selected the wrong account.'
                    if($script:baselineCredentialCase){
                        $script:baselineSessionTransfers++
                        Assert-True ($script:baselineCredentialCase -eq 'valid' -and @($sessionConfiguration.BaselineCredentials).Count -eq 3) 'Invalid baseline credentials reached transfer or owned credentials were omitted.'
                        foreach($expected in $script:expectedBaselineCredentials){Assert-True (@($sessionConfiguration.BaselineCredentials|Where-Object {$_.UserName -ceq $expected.UserName -and $_.UserPassword -ceq $expected.UserPassword}).Count -eq 1) 'The private baseline transfer changed an owned credential.'}
                    }
                }
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\payload.zip'){
                    $script:payloadTransferCalls++
                    Assert-True (Test-Path -LiteralPath $ArgumentList[-2] -PathType Leaf) 'Payload archive was not preserved before transfer.'
                    $script:payloadArchiveHash=(Get-FileHash -LiteralPath $ArgumentList[-2]).Hash
                }
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\payload-manifest.json'){
                    $script:payloadManifestHash=(Get-FileHash -LiteralPath $ArgumentList[-2]).Hash
                    $script:payloadObserved=Get-Content -LiteralPath $ArgumentList[-2] -Raw|ConvertFrom-Json
                    Assert-True ($script:payloadObserved.Status -eq 'Completed' -and $script:payloadObserved.ArchiveSHA256 -eq $script:payloadArchiveHash -and $script:payloadObserved.SourceSHA256 -eq $inputHash) 'The payload transfer was not bound to its preserved source/archive.'
                }
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\Expand-AnalysisWindowsPayload.ps1'){Assert-True ($ArgumentList[-2] -eq (Join-Path $script:fixtureAssets 'Expand-AnalysisWindowsPayload.ps1')) 'The payload extractor was not the trusted helper.'}
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\WindowsGuestPackage.ps1'){Assert-True ($script:packageCase -like 'registered-*' -and $ArgumentList[-2] -eq (Join-Path $script:fixtureAssets 'WindowsGuestPackage.ps1')) 'The package deployment helper was not the trusted asset.'}
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\WindowsGuestDeploymentProfile.ps1'){Assert-True ($script:packageCase -like 'registered-*' -and $ArgumentList[-2] -eq (Join-Path $script:fixtureAssets 'WindowsGuestDeploymentProfile.ps1')) 'The deployment profile helper was not its trusted private asset.'}
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\WindowsGuestActivationDiagnostics.ps1'){Assert-True ($script:packageCase -like 'registered-*' -and $ArgumentList[-2] -eq (Join-Path $script:fixtureAssets 'WindowsGuestActivationDiagnostics.ps1')) 'The activation diagnostic helper was not its trusted private asset.'}
                elseif($ArgumentList[-1] -in 'C:\ProfileAnalysis\Private\package.msix','C:\ProfileAnalysis\Private\package-license.xml'){
                    Assert-True ($script:packageCase -like 'registered-license-*' -and $ArgumentList -contains $manifest.AdminUser -and $ArgumentList -notcontains $manifest.GuestUser -and $TimeoutSeconds -eq 600) 'Package/license transfer lost the private management boundary or its time limit.'
                    $sourceFile=$ArgumentList[-2];$sourceDigest=(Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
                    if($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\package.msix'){
                        Assert-True ($sourceFile -cne $script:licenseSourceArchive -and $sourceDigest -ceq $script:licenseArchiveHash) 'The package transfer did not use the exact preserved container.'
                        $script:licensePreservedArchive=$sourceFile
                    }else{
                        Assert-True ($sourceFile -cne $script:licenseSourceLicense -and $sourceDigest -ceq $script:licenseXmlHash) 'The license transfer did not use the exact preserved license.'
                        $script:licensePreservedLicense=$sourceFile
                    }
                    $script:licenseTransfers++
                }
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\Controller.ps1'){Assert-True ($ArgumentList[-2] -eq (Join-Path $script:fixtureAssets 'WindowsGuestController.ps1')) 'The profile-loading controller was not the trusted asset.'}
                else{Assert-True ($ArgumentList[-2] -eq (Join-Path $script:fixtureAssets 'WindowsGuestRunner.ps1')) 'The copied guest runner was not the trusted asset.'}
                return ''
            }
            if($ArgumentList -contains 'echo ready'){return 'ready'}
            if($ArgumentList -contains 'if exist C:\ProfileAnalysis\Private\interactive-session-cleanup.json (echo ready) else (echo pending)'){
                Assert-True ($ArgumentList -contains 'C:\Windows\System32\cmd.exe' -and $ArgumentList -contains '/d' -and $ArgumentList -contains '/c' -and $ArgumentList -contains $manifest.AdminUser -and $ArgumentList -contains '10000' -and $TimeoutSeconds -eq 15) 'Readiness polling lost its fixed command, management identity, or short timeout.'
                $script:sessionMarkerCalls++
                if($script:packageCase -eq 'session-marker-timeout' -or ($script:packageCase -eq 'session-marker-pending' -and $script:sessionMarkerCalls -le 2)){
                    Assert-True ($script:sessionVerifyCalls -eq 0) 'PowerShell session verification started before cleanup evidence existed.'
                    return 'pending'
                }
                $script:sessionMarkerReady=$true;return 'ready'
            }
            if($ArgumentList -contains 'C:\Windows\System32\shutdown.exe'){
                Assert-True ($script:packageCase -and $ArgumentList -contains '/r') 'Unexpected reboot outside packaged interactive setup.'
                $script:mutations++;return ''
            }
            if($ArgumentList -contains '-File'){
                if($ArgumentList -contains 'C:\ProfileAnalysis\Private\WindowsGuestSession.ps1'){
                    Assert-True (-not(Test-Path -LiteralPath $script:sessionFileObserved)) 'The host retained its plaintext session credential.'
                    if($ArgumentList -contains 'Configure'){
                        Assert-True ($ArgumentList[[Array]::IndexOf($ArgumentList,'--timeout')+1] -eq '180000' -and $TimeoutSeconds -eq 195) 'Session configuration lacks the bounded allowance for cold native startup and power policy changes.'
                        $script:sessionConfigureCalls++
                        return (@{Status='Configured';UserName=if($script:packageCase -eq 'configure-identity'){'unexpected'}else{$manifest.GuestUser};UserSid='S-1-5-21-123-456-789-1001';RunId=$script:sessionRunId;CredentialsInTask=$false}|ConvertTo-Json -Compress)
                    }
                    Assert-True ($ArgumentList -contains 'Verify' -and $ArgumentList[-1] -eq $manifest.GuestUser) 'Interactive session verification did not select the expected account.'
                    Assert-True ($ArgumentList[[Array]::IndexOf($ArgumentList,'--timeout')+1] -eq '60000' -and $TimeoutSeconds -eq 75) 'Read-only session verification lost its distinct short timeout.'
                    Assert-True $script:sessionMarkerReady 'PowerShell session verification ran before the lightweight marker probe was ready.'
                    $script:sessionVerifyCalls++
                    $sessionReply=@{Status='Ready';UserName=$manifest.GuestUser;UserSid='S-1-5-21-123-456-789-1001';RunId=$script:sessionRunId;SessionId=$script:sessionId;StandardTokenVerified=$true;AutoLogonSecretsRemoved=$true;TaskRemoved=$true;BaselineAutoLogon=@{Classification=if($script:baselineCredentialCase -eq 'valid'){'OwnedProvisioningCredential'}else{'Absent'};UserName=if($script:baselineCredentialCase -eq 'valid'){'analysis-admin'}else{$null}};PowerPolicy=@{Status='Verified';ActiveSchemeId='381b4222-f694-41f0-9685-ff5bb260df2e';MonitorTimeoutAcSeconds=0;MonitorTimeoutDcSeconds=0;StandbyTimeoutAcSeconds=0;StandbyTimeoutDcSeconds=0}}
                    $powerSettings=@{'power-monitor-ac'='MonitorTimeoutAcSeconds';'power-monitor-dc'='MonitorTimeoutDcSeconds';'power-standby-ac'='StandbyTimeoutAcSeconds';'power-standby-dc'='StandbyTimeoutDcSeconds'}
                    if($powerSettings.ContainsKey($script:packageCase)){$sessionReply.PowerPolicy[$powerSettings[$script:packageCase]]=60}
                    switch($script:packageCase){
                        'power-proof-missing' {$sessionReply.Remove('PowerPolicy')}
                        'power-field-missing' {$sessionReply.PowerPolicy.Remove('StandbyTimeoutDcSeconds')}
                        'power-proof-unverified' {$sessionReply.PowerPolicy.Status='Unverified'}
                        'power-string-zero' {$sessionReply.PowerPolicy.MonitorTimeoutAcSeconds='0'}
                        'power-boolean-zero' {$sessionReply.PowerPolicy.StandbyTimeoutAcSeconds=$false}
                        'power-invalid-scheme' {$sessionReply.PowerPolicy.ActiveSchemeId='-'*36}
                        'power-empty-scheme' {$sessionReply.PowerPolicy.ActiveSchemeId=[guid]::Empty.ToString()}
                    }
                    return ($sessionReply|ConvertTo-Json -Depth 5 -Compress)
                }
                Assert-True ($ArgumentList -contains 'C:\ProfileAnalysis\Private\Controller.ps1') 'The target was launched without the profile-loading controller.'
                $expectedControllerAllowance=if($script:packageCase -like 'registered-license-*'){1200}elseif($script:packageCase){900}else{330}
                $nativeTimeout=$ArgumentList[[Array]::IndexOf($ArgumentList,'--timeout')+1]
                Assert-True ($nativeTimeout -ceq (($script:expectedObservationSeconds+$expectedControllerAllowance)*1000).ToString() -and $TimeoutSeconds -eq ($script:expectedObservationSeconds+$expectedControllerAllowance+30)) 'The actual VBox controller call disagrees with its licensed or unlicensed preparation and host completion budgets.'
                $script:controllerNativeTimeoutObserved=$nativeTimeout;$script:controllerHostTimeoutObserved=$TimeoutSeconds
                $script:controllerLaunches++
                Assert-True (-not(Test-Path -LiteralPath $script:launchFileObserved)) 'The host retained its plaintext launch credential during execution.'
                if($script:pauseGuest){$script:vmSettings.VMState='paused';throw 'Mock guest was paused'}
                if($script:failGuest){throw 'Mock guest failed'}
                return 'PROFILE_ANALYSIS_RUNTIME=Completed'
            }
            $index=[Array]::IndexOf($ArgumentList,'-EncodedCommand')
            if($index -lt 0){throw 'Unexpected guest control invocation'}
            $transfer=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[$index+1]))
            if($script:licenseFixtureSentinel){Assert-True (-not $transfer.Contains($script:licenseFixtureSentinel)) 'License content appeared in an encoded process command.'}
            foreach($sentinel in $script:baselineSecretSentinels){Assert-True (-not $transfer.Contains($sentinel)) 'A baseline credential appeared in an encoded process argument.'}
            if($script:packageCase -like 'registered-*'){Assert-True ($transfer -notmatch 'Results\\(?:stdout|stderr)\.txt') 'Registered activation attempted to collect unavailable target stdout/stderr.'}
            if($transfer -match "New-Item -ItemType Directory -Path 'C:\\ProfileAnalysis\\Private'"){
                Assert-True ($transfer -match '/inheritance:r' -and $transfer -match 'S-1-5-32-544' -and $transfer -match 'S-1-5-18') 'Private guest launch directory restrictions were omitted.'
                return ''
            }
            Assert-True ($MaxOutputCharacters -eq 23000000) 'Evidence transfer lost its host capture limit.'
            $expectedEvidenceSeconds=if($script:packageCase){60}else{30}
            Assert-True ($ArgumentList -contains ([string]($expectedEvidenceSeconds*1000)) -and $TimeoutSeconds -eq ($expectedEvidenceSeconds+10)) 'Evidence transfer lost its bounded payload-specific deadline.'
            if($transfer -match "OpenRead\('C:\\ProfileAnalysis\\Results\\window\.png'\)"){
                Assert-True ($script:imageCase -and $ArgumentList -contains $manifest.GuestUser -and $transfer -match '16777216') 'Image collection changed its fixed path, standard-user authentication or guest size cap.'
                $script:imageReads++;$script:imageTransferScript=$transfer
                if($script:imageCase -eq 'guest-failure'){throw 'Fixture bounded image transfer failed.'}
                if($script:imageCase -eq 'invalid-base64'){return 'not a valid base64 image!'}
                $imageBytes=if($script:imageCase -eq 'oversized'){[byte[]]::new(16MB+1)}elseif($script:imageCase -eq 'exact-limit'){[byte[]]::new(16MB)}else{$script:imageFixtureBytes}
                if($script:imageCase -eq 'exact-limit'){[Array]::Copy($script:imageFixtureBytes,$imageBytes,$script:imageFixtureBytes.Length)}
                $script:imageExpectedBytes=$imageBytes
                return [Convert]::ToBase64String($imageBytes)
            }
            Assert-True ($transfer -match '16777217') 'Evidence transfer lost its guest byte limit.'
            if($script:collectEvidenceOrder -and $transfer -match "OpenRead\('([^']+)'\)"){$script:evidenceOrder+=@([IO.Path]::GetFileName($Matches[1]))}
            $evidenceMatch=[regex]::Match($transfer,"OpenRead\('([^']+)'\)")
            $evidenceName=if($evidenceMatch.Success){[IO.Path]::GetFileName($evidenceMatch.Groups[1].Value)}else{$null}
            if($script:progressCase){$script:progressEvidenceReads+=@($evidenceName)}
            if($evidenceName -in 'runtime-progress.json','activation-progress.json'){
                Assert-True ($evidenceMatch.Groups[1].Value -ceq ('C:\ProfileAnalysis\Results\'+$evidenceName) -and $ArgumentList -contains $manifest.GuestUser) 'A progress artifact crossed its standard-user results boundary.'
                if($evidenceName -eq 'activation-progress.json'){Assert-True ($script:packageCase -like 'registered-*') 'Activation progress was requested for a nonregistered launch.'}
                if($script:progressCase -eq 'unavailable'){throw ('Fixture optional progress unavailable. '+('X'*5000))}
                $checkpoint=@{Status='Completed';Phase='Finished';Utc=[datetime]::UtcNow.ToString('o');FixtureOnly=$true}|ConvertTo-Json -Compress
                return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($checkpoint))
            }
            if($transfer -match 'runtime\.json'){
                if($script:progressCase -in 'missing-final','incomplete-header','started-header','oversized-header'){throw 'Fixture terminal runtime report is unavailable.'}
                if($script:packageCase -like 'shutdown-*'){$script:cleanupReady=$true;$script:vmSettings.VMState='running'}
                $data=@{Status=if($script:failGuest){'Failed'}else{'Completed'};GuestUser=('FIXTURE\'+$manifest.GuestUser);UserEnvironment=@{UserName=$manifest.GuestUser;LoadedHiveSid='S-1-5-21-123-456-789-1001'};IsAdministrator=$false;TargetSHA256=$inputHash;RunnerSHA256=(Get-FileHash -LiteralPath (Join-Path $script:fixtureAssets 'WindowsGuestRunner.ps1')).Hash;Validation=@{AccountNotAdministrator=(-not $script:filteredAdmin);UserProfileLoaded=(-not $script:profileMissing);HashMatched=$true;NoNetworkAdapter=$true};Execution=@{JobAssigned=(-not $script:failGuest);JobClosed=$true;Reason='Completed';ExitCode=0}}|ConvertTo-Json -Depth 6 -Compress
                if($script:packageCase){
                    $data=$data|ConvertFrom-Json
                    $data|Add-Member NoteProperty PayloadManifestSHA256 $(if($script:packageCase -eq 'guest-manifest'){'0'*64}else{$script:payloadManifestHash})
                    $data.UserEnvironment|Add-Member NoteProperty SessionId $(if($script:packageCase -eq 'session-id'){99}else{$script:sessionId})
                    $data.UserEnvironment|Add-Member NoteProperty UserInteractive ($script:packageCase -ne 'noninteractive')
                    if($script:packageCase -eq 'nonzero-exit'){$data.Execution.ExitCode=7}
                    if($script:packageCase -like 'registered-*'){
                        $data|Add-Member NoteProperty PackageRegistration @{Status=if($script:packageCase -eq 'registered-registration'){ 'Failed' }else{ 'Completed' };PackageFullName='Known.RuntimeFixture_1.0.0.0_x64__0123456789abc'}
                        $data|Add-Member NoteProperty ActivatedImageSHA256 $(if($script:packageCase -eq 'registered-image'){'0'*64}else{$inputHash})
                        $data.Execution.JobAssigned=$false;$data.Execution.JobClosed=$false
                        $data.Execution|Add-Member NoteProperty RootPackageFullName $(if($script:packageCase -eq 'registered-identity'){'Different.Package_1.0.0.0_x64__0123456789abc'}elseif($script:packageCase -eq 'registered-identity-missing'){$null}else{'Known.RuntimeFixture_1.0.0.0_x64__0123456789abc'})
                        $data.Execution|Add-Member NoteProperty RootUserSid $(if($script:packageCase -eq 'registered-user'){'S-1-5-21-123-456-789-9999'}else{'S-1-5-21-123-456-789-1001'})
                        $data.Execution|Add-Member NoteProperty RootAdministrator ($script:packageCase -eq 'registered-administrator')
                    }
                    $data=$data|ConvertTo-Json -Depth 6 -Compress
                }
                if($script:launchFailure){$data=($data|ConvertFrom-Json);$data.Status='Failed';$data.Execution=$null;$data|Add-Member NoteProperty Error 'Side-by-side configuration is incorrect';$data|Add-Member NoteProperty ErrorDetails @{NativeErrorCode=14001;Operation='Create suspended target'};$data=$data|ConvertTo-Json -Depth 6 -Compress}
                if($script:imageCase){$data=$data|ConvertFrom-Json;$data.Execution|Add-Member NoteProperty Screenshot 'window.png';$data=$data|ConvertTo-Json -Depth 6 -Compress}
            }elseif($transfer -match 'controller\.json'){
                Assert-True ($transfer -match 'Private\\controller\.json' -and $ArgumentList -contains $manifest.AdminUser) 'Controller evidence was not read privately by the management account.'
                $controllerData=@{Status='Completed';BatchLogonRightVerified=$true;TaskPrincipal=@{UserId=('FIXTURE\'+$manifest.GuestUser);UserSid='S-1-5-21-123-456-789-1001';ExpectedUserSid='S-1-5-21-123-456-789-1001';LogonType='Password';RunLevel='Limited'};CredentialRemovedBeforeLaunch=$true;TaskRemoved=$true;RunnerStarted=$true;RunnerExitCode=0;Error=$null}
                if($script:packageCase){
                    $controllerData.TaskPrincipal.LogonType='InteractiveToken';$controllerData.BatchLogonRightVerified=$false
                    $controllerData.PayloadVerification=@{Status='Completed';ManifestSHA256=if($script:packageCase -eq 'payload-manifest'){'0'*64}else{$script:payloadManifestHash};FilesVerified=if($script:packageCase -eq 'payload-count'){$script:payloadObserved.Files.Count-1}else{$script:payloadObserved.Files.Count};BytesVerified=$script:payloadObserved.TotalBytes}
                    $controllerData.InteractiveSession=@{RunId=if($script:packageCase -eq 'session-runid'){'f'*32}else{$script:sessionRunId};AutoLogonSecretsRemoved=($script:packageCase -ne 'session-dirty')}
                    if($script:packageCase -eq 'payload-proof-missing'){$controllerData.Remove('PayloadVerification')}
                    if($script:packageCase -eq 'payload-hash-missing'){$controllerData.PayloadVerification.Remove('ManifestSHA256')}
                    if($script:packageCase -like 'registered-*'){
                        $controllerData.PackageDeployment=@{Status=if($script:packageCase -eq 'registered-stage'){'Failed'}else{'Completed'};PackageFullName=if($script:packageCase -eq 'registered-identity-missing'){$null}else{'Known.RuntimeFixture_1.0.0.0_x64__0123456789abc'};DeploymentProfile=@{Status='Ready';UserSid='S-1-5-21-123-456-789-500';PrivilegesRestored=$true;ProfileType=0};DeploymentProfileCleanup=@{Status='Released';UserSid='S-1-5-21-123-456-789-500';PrivilegesRestored=$true;Released=$true}}
                        if($script:packageCase -like 'registered-license-*'){
                            $proof=@{Status='Completed';ArchiveSHA256=$script:licenseArchiveHash;LicenseSHA256=$script:licenseXmlHash;PackageFullName=$controllerData.PackageDeployment.PackageFullName;RestartNeeded=$false}
                            switch($script:packageCase){
                                'registered-license-status' {$proof.Status='Failed'}
                                'registered-license-archive-hash' {$proof.ArchiveSHA256='0'*64}
                                'registered-license-hash-case' {$proof.ArchiveSHA256=$proof.ArchiveSHA256.ToLowerInvariant()}
                                'registered-license-license-hash' {$proof.LicenseSHA256='0'*64}
                                'registered-license-full-name' {$proof.PackageFullName='Different.Package_1.0.0.0_x64__0123456789abc'}
                                'registered-license-restart' {$proof.RestartNeeded=$true}
                                'registered-license-restart-string' {$proof.RestartNeeded='false'}
                                'registered-license-restart-number' {$proof.RestartNeeded=0}
                                'registered-license-restart-missing' {$proof.Remove('RestartNeeded')}
                            }
                            if($script:packageCase -ne 'registered-license-proof-missing'){$controllerData.PackageDeployment.OfflineLicense=$proof}
                        }
                        switch($script:packageCase){
                            'registered-profile-missing' {$controllerData.PackageDeployment.Remove('DeploymentProfile')}
                            'registered-profile-type' {$controllerData.PackageDeployment.DeploymentProfile.ProfileType=1}
                            'registered-profile-string' {$controllerData.PackageDeployment.DeploymentProfile.ProfileType='0'}
                            'registered-profile-privileges' {$controllerData.PackageDeployment.DeploymentProfile.PrivilegesRestored=$false}
                            'registered-profile-release' {$controllerData.PackageDeployment.DeploymentProfileCleanup.Released=$false}
                            'registered-profile-user' {$controllerData.PackageDeployment.DeploymentProfileCleanup.UserSid='S-1-5-21-123-456-789-1001'}
                        }
                    }
                }
                if($script:badController -eq 'controller-error'){$controllerData.Error='Fixture controller failure'}
                elseif($script:badController -eq 'controller-exit'){$controllerData.RunnerExitCode=1}
                elseif($script:badController -eq 'controller-principal'){$controllerData.TaskPrincipal.UserId='FIXTURE\unexpected'}
                elseif($script:badController -eq 'controller-elevation'){$controllerData.TaskPrincipal.RunLevel='Highest'}
                elseif($script:badController -eq 'controller-status'){$controllerData.Status='Failed'}
                elseif($script:badController){$controllerData[$script:badController]=$false}
                if($script:packageCase -like 'registered-pre-run-*'){
                    $controllerData.Status='Failed';$controllerData.RunnerStarted=$false;$controllerData.Error='Fixture deployment failed before runner launch.';$controllerData.HResult=-2147009287
                    if($script:packageCase -eq 'registered-pre-run-string'){$controllerData.RunnerStarted='false'}
                    if($script:packageCase -eq 'registered-pre-run-missing'){$controllerData.Remove('RunnerStarted')}
                }
                $data=$controllerData|ConvertTo-Json -Depth 6 -Compress
                if($script:packageCase -eq 'registered-pre-run-malformed'){$data='{'}
                if($script:progressCase -in 'incomplete-header','started-header','oversized-header'){
                    $header=@{Status='Failed';RunnerStarted=($script:progressCase -eq 'started-header');RunnerExitCode=$null;Error=$null;Phases=@(@{Name=if($script:progressCase -eq 'started-header'){'RunnerStarted'}else{'ObserveTask'};Utc=[datetime]::UtcNow.ToString('o')})}
                    if($script:progressCase -eq 'oversized-header'){$header.Padding='X'*(1MB)}
                    $data=$header|ConvertTo-Json -Depth 4 -Compress
                }
            }else{$data='{}'}
            return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($data))
        }
        default {throw 'Unexpected VBox command in mock'}
    }
}
$held=Enter-AnalysisWindowsVmLock $owned
try{
    Assert-Throws {Enter-AnalysisWindowsVmLock $owned} 'A second caller acquired the same VM lock.'
    $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $inputPath -OutputPath (Join-Path $TestRoot 'busy') -VirtualMachineName $manifest.VirtualMachineName
    Assert-True ($result.Status -eq 'Failed' -and $result.Errors -match 'busy' -and $script:mutations -eq 0) 'A busy VM was mutated or misreported.'
}finally{$held.Dispose()}
Write-Host 'PASS: exclusive lock rejects a concurrent analysis without changing any VM state'

foreach($case in @('success','launch-failure','guest-failure','cleanup-failure','paused-guest','filtered-admin','missing-profile','launch-copy-failure','CredentialRemovedBeforeLaunch','TaskRemoved','RunnerStarted','controller-error','controller-exit','controller-principal','controller-elevation','controller-status')){
    $script:launchFailure=$case -eq 'launch-failure'
    $script:badController=if($case -in 'CredentialRemovedBeforeLaunch','TaskRemoved','RunnerStarted','controller-error','controller-exit','controller-principal','controller-elevation','controller-status'){$case}else{$null}
    $script:restores=0;$script:vmSettings=$valid.Clone();$script:failGuest=$case -in 'guest-failure','paused-guest';$script:failFinalRestore=$case -eq 'cleanup-failure';$script:pauseGuest=$case -eq 'paused-guest';$script:filteredAdmin=$case -eq 'filtered-admin';$script:profileMissing=$case -eq 'missing-profile';$script:failLaunchCopy=$case -eq 'launch-copy-failure'
    $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $inputPath -OutputPath (Join-Path $TestRoot $case) -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1
    Assert-True ($script:restores -eq 2) "$case did not attempt both snapshot restores."
    Assert-True (@(Get-ChildItem -LiteralPath $owned -Filter 'runtime-*').Count -eq 0) "$case left plaintext credentials."
    Assert-True $result.Validation.SourceUnchanged "$case changed the input."
    Assert-True ($result.Budgets.TargetTimeoutSeconds -eq 1 -and $result.Budgets.PreparationAndObservationAllowanceSeconds -eq 300 -and $result.Budgets.GuestRunnerTimeoutSeconds -eq 301) 'Preparation allowance changed the actual target timeout or was not reported.'
    if($case -eq 'success'){
        Assert-True ($result.Status -eq 'Completed') ('Successful mock did not complete: '+($result.Errors -join '; '))
        Assert-True ($result.Budgets.ControllerPreparationAndEvidenceAllowanceSeconds -eq 330 -and $result.Budgets.GuestControllerTimeoutSeconds -eq 331 -and $result.Budgets.HostRunnerTimeoutSeconds -eq 361 -and -not $result.Budgets.ContainsKey('WholeVmDeadlineSeconds')) 'Standalone execution inherited a packaged or licensed deadline.'
        Assert-True ($result.Validation.CleanSnapshotRestoredAfter -and $result.Validation.PoweredOffAfter) 'Successful mock did not verify cleanup.'
    }else{Assert-True ($result.Status -eq 'Failed') "$case was reported as success."}
    if($case -eq 'launch-failure'){Assert-True ($result.Errors -match 'Guest target observation failed' -and $result.GuestResult.ErrorDetails.NativeErrorCode -eq 14001 -and $null -eq $result.GuestResult.Execution) 'Launch failure lost native diagnosis or implied execution.'}
    $available=Enter-AnalysisWindowsVmLock $owned;$available.Dispose()
}
Write-Host 'PASS: orchestration preserves literal paths and source bytes, bounds transfers, restores after failures, and removes credentials'

$packageRoot=Join-Path $TestRoot 'packaged-source'
$null=[IO.Directory]::CreateDirectory((Join-Path $packageRoot 'app/resources'))
$packagedInput=Join-Path $packageRoot 'app/entry.exe';Copy-Item -LiteralPath $inputPath -Destination $packagedInput
[IO.File]::WriteAllText((Join-Path $packageRoot 'app/resources/app.asar'),'Known opaque archive fixture; no target execution.')
[IO.File]::WriteAllText((Join-Path $packageRoot 'AppxManifest.xml'),'<Package><Identity Name="Known.RuntimeFixture" Version="1.0.0.0" ProcessorArchitecture="x64"/><Applications><Application Id="App" Executable="app/entry.exe" EntryPoint="Windows.FullTrustApplication"/></Applications></Package>')
foreach($case in @('success','session-marker-pending','session-marker-timeout','power-proof-missing','power-field-missing','power-proof-unverified','power-monitor-ac','power-monitor-dc','power-standby-ac','power-standby-dc','power-string-zero','power-boolean-zero','power-invalid-scheme','power-empty-scheme','payload-manifest','payload-count','payload-proof-missing','payload-hash-missing','guest-manifest','session-id','session-runid','session-dirty','noninteractive','configure-identity','cleanup-failure','watchdog-start-failure','watchdog-expired','watchdog-failure','source-mutation','nonzero-exit')){
    $script:packageCase=$case;$script:payloadObserved=$null;$script:payloadManifestHash=$null;$script:badController=$null
    $script:launchFailure=$false;$script:failGuest=$false;$script:pauseGuest=$false;$script:filteredAdmin=$false;$script:profileMissing=$false;$script:failLaunchCopy=$false
    $script:restores=0;$script:controllerLaunches=0;$script:watchdogStarts=0;$script:payloadTransferCalls=0;$script:vmSettings=$valid.Clone();$script:failFinalRestore=$case -eq 'cleanup-failure'
    $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath (Join-Path $TestRoot ('packaged-'+$case)) -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1 -ExpectedInputSHA256 $inputHash -MaxPackageBytes 1MB -MaxPackageFiles 10
    Assert-True ($script:restores -eq 2 -and $result.Validation.SourceUnchanged) ($case+' package run did not preserve source or attempt both snapshot restores.')
    Assert-True (@(Get-ChildItem -LiteralPath $owned -Filter 'runtime-*').Count -eq 0) ($case+' package run left host credentials.')
    if($case -in 'success','session-marker-pending'){
        Assert-True ($result.Status -eq 'Completed' -and $result.Payload.RootKind -eq 'AppxDirectory' -and $result.Payload.EntryPoint -ceq 'app/entry.exe') ('The valid packaged fixture failed: '+($result.Errors -join '; '))
        Assert-True ($result.ControllerResult.TaskPrincipal.LogonType -eq 'InteractiveToken' -and $result.ControllerResult.PayloadVerification.FilesVerified -eq 3 -and $result.GuestResult.UserEnvironment.UserInteractive -and $result.GuestResult.UserEnvironment.SessionId -eq $script:sessionId) 'Package per-file verification or standard interactive-session evidence was lost.'
        Assert-True ($result.Validation.CleanSnapshotRestoredAfter -and $result.Validation.PoweredOffAfter -and $result.Validation.PayloadSourceUnchanged -and $result.PayloadSourceVerification.FilesVerified -eq 3 -and $result.WatchdogResult.Status -eq 'Cancelled') 'Packaged success did not verify final cleanup, complete source preservation, or watchdog cancellation.'
        Assert-True ($result.Budgets.InteractiveSessionTimeoutSeconds -eq 600) 'Interactive preparation lost its bounded 600-second allowance.'
        Assert-True ($result.Budgets.PreparationAndObservationAllowanceSeconds -eq 600 -and $result.Budgets.GuestRunnerTimeoutSeconds -eq 601 -and $result.Budgets.ControllerPreparationAndEvidenceAllowanceSeconds -eq 900 -and $result.Budgets.GuestControllerTimeoutSeconds -eq 901 -and $result.Budgets.HostRunnerTimeoutSeconds -eq 931 -and $result.Budgets.WholeVmPreparationTransferAndEvidenceAllowanceSeconds -eq 1200 -and $result.Budgets.WholeVmDeadlineSeconds -eq 1201 -and $result.Budgets.OutsideControllerTransferAndEvidenceAllowanceSeconds -eq 300) 'Desktop layout execution lost its measured preparation allowance or inherited licensed deployment time.'
        Assert-True ($result.InteractiveSession.PowerPolicy.Status -eq 'Verified' -and $result.InteractiveSession.PowerPolicy.MonitorTimeoutAcSeconds -eq 0 -and $result.InteractiveSession.PowerPolicy.StandbyTimeoutDcSeconds -eq 0) 'Verified uninterrupted observation policy was lost from runtime evidence.'
    }elseif($case -eq 'nonzero-exit'){
        Assert-True ($result.Status -eq 'Partial' -and $result.GuestResult.Execution.ExitCode -eq 7 -and ($result.Limitations -join ' ') -match 'nonzero') 'Nonzero application exit was hidden behind successful observation.'
    }else{Assert-True ($result.Status -eq 'Failed' -and $result.Errors.Count -gt 0) ($case+' packaged runtime failure was reported as successful.')}
    if($case -eq 'watchdog-start-failure'){Assert-True ($script:controllerLaunches -eq 0) 'The controller launched without an independently verified whole-VM deadline.'}
    if($case -eq 'session-marker-pending'){Assert-True ($script:sessionMarkerCalls -eq 3 -and $script:sessionVerifyCalls -eq 1) 'Pending cleanup markers caused premature or repeated PowerShell verification.'}
    if($case -eq 'session-marker-timeout'){Assert-True ($result.Budgets.InteractiveSessionTimeoutSeconds -eq 600 -and $script:sessionMarkerCalls -eq 1 -and $script:sessionVerifyCalls -eq 0 -and $script:controllerLaunches -eq 0 -and ($result.Errors -join ' ') -match 'did not become ready') 'Session preparation crossed its 600-second boundary or reached target execution without readiness.'}
    if($case -like 'power-*'){Assert-True ($script:watchdogStarts -eq 0 -and $script:payloadTransferCalls -eq 0 -and $script:controllerLaunches -eq 0 -and ($result.Errors -join ' ') -match 'power policy|idle timeout') 'Unknown or enabled idle policy reached watchdog, payload transfer, or target deployment.'}
    if($case -eq 'source-mutation'){
        Assert-True ($result.Validation.PayloadSourceUnchanged -eq $false -and ($result.Errors -join ' ') -match 'Source package changed') 'A changed source layout was not identified after observation.'
        [IO.File]::Delete((Join-Path $packageRoot 'app/resources/added-during-runtime.txt'))
    }
}
foreach($case in @('shutdown-normal','shutdown-query-failure','shutdown-poweroff-failure','shutdown-watchdog-failed','shutdown-watchdog-hung','shutdown-quarantine-failure')){
    $script:packageCase=$case;$script:restores=0;$script:controllerLaunches=0;$script:failFinalRestore=$false;$script:vmSettings=$valid.Clone()
    $script:cleanupReady=$false;$script:shutdownFailureInjected=$false;$script:watchdogWaits=0;$script:watchdogCancellations=0
    $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath (Join-Path $TestRoot $case) -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1 -ExpectedInputSHA256 $inputHash
    if($case -eq 'shutdown-normal'){
        Assert-True ($result.Status -eq 'Completed' -and $script:watchdogCancellations -eq 1 -and $script:watchdogWaits -eq 0 -and $result.Validation.PoweredOffBeforeWatchdogCancellation) 'Normal shutdown did not verify power-off before cancelling its watchdog.'
    }else{
        Assert-True ($result.Status -eq 'Failed' -and $script:watchdogCancellations -eq 0 -and $script:watchdogWaits -eq 1 -and ($result.Errors -join ' ') -match 'Initial shutdown failed') 'Uncertain shutdown cancelled the deadline, lost its primary error, or failed to wait under the lock.'
    }
    if($case -eq 'shutdown-quarantine-failure'){
        Assert-True ($result.LockRetainedForUnresolvedWatchdog -and $script:AnalysisWindowsQuarantineLocks.Count -eq 1 -and $script:restores -eq 1) 'Failed quarantine persistence released an unresolved live watchdog into a permitted next run.'
        Assert-Throws {Enter-AnalysisWindowsVmLock $owned} 'The fallback exclusive lock was not retained after quarantine persistence failed.'
        # Release the fixture's deliberately retained lock after proving exclusion.
        $script:AnalysisWindowsQuarantineLocks[0].Dispose();$script:AnalysisWindowsQuarantineLocks.Clear()
    }elseif($case -eq 'shutdown-watchdog-hung'){
        $marker=Join-Path $owned 'runtime-quarantine.json'
        Assert-True ($result.QuarantinePath -eq $marker -and $script:restores -eq 1 -and (Get-Item -LiteralPath $marker).Length -le 4096 -and (Get-Acl -LiteralPath $marker).AreAccessRulesProtected) 'An unresolved live watchdog did not leave a bounded protected quarantine before lock release.'
        $quarantine=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
        Assert-True ($quarantine.BoundUUID -eq $manifest.VirtualMachineId -and $quarantine.Recovery -match 'watchdog has exited') 'The quarantine lost its exact VM identity or recovery condition.'
        Assert-Throws {Enter-AnalysisWindowsVmLock $owned} 'A quarantined VM permitted a new runtime lock.'
        # Only a fixture marker is removed; no real VM/watchdog exists in this test.
        [IO.File]::Delete($marker)
    }else{
        Assert-True ($script:restores -eq 2 -and $result.Validation.PoweredOffAfter -and $result.Validation.CleanSnapshotRestoredAfter) 'Cleanup was not retried and verified after watchdog completion.'
        if($case -eq 'shutdown-watchdog-failed'){Assert-True ($result.WatchdogResult.Status -eq 'Failed') 'Terminal watchdog failure evidence was discarded.'}
        elseif($case -ne 'shutdown-normal'){Assert-True ($result.WatchdogResult.Status -eq 'Expired') 'Armed watchdog expiry evidence was discarded.'}
    }
    $available=Enter-AnalysisWindowsVmLock $owned;$available.Dispose()
}
$script:cleanupReady=$false
Write-Host 'PASS: shutdown proves power-off before cancellation; uncertain shutdown keeps its deadline and lock, retries cleanup, and quarantines unresolved watchdogs'
foreach($case in @('registered-success','registered-explicit','registered-stage','registered-registration','registered-image','registered-identity','registered-identity-missing','registered-user','registered-administrator','registered-profile-missing','registered-profile-type','registered-profile-string','registered-profile-privileges','registered-profile-release','registered-profile-user')){
    $script:packageCase=$case;$script:restores=0;$script:controllerLaunches=0;$script:failFinalRestore=$false;$script:vmSettings=$valid.Clone()
    $rootParameters=@{};if($case -eq 'registered-explicit'){$rootParameters.ApplicationRoot=$packageRoot}
    $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath (Join-Path $TestRoot $case) -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1 -ExpectedInputSHA256 $inputHash -LaunchMode RegisteredPackage @rootParameters
    Assert-True ($script:restores -eq 2 -and $result.Validation.SourceUnchanged -and $result.Validation.PayloadSourceUnchanged -and $result.WatchdogResult.Status -eq 'Cancelled') ($case+' did not restore the baseline and verify preserved source/deadline cleanup.')
    if($case -in 'registered-success','registered-explicit'){
        Assert-True ($result.Status -eq 'Completed' -and $result.LaunchMode -eq 'RegisteredPackage' -and $result.GuestResult.Execution.JobAssigned -eq $false) ('Registered activation did not accept verified whole-VM containment: '+($result.Errors -join '; '))
        Assert-True ($result.Budgets.PreparationAndObservationAllowanceSeconds -eq 600 -and $result.Budgets.GuestRunnerTimeoutSeconds -eq 601 -and $result.Budgets.ControllerPreparationAndEvidenceAllowanceSeconds -eq 900 -and $result.Budgets.GuestControllerTimeoutSeconds -eq 901 -and $result.Budgets.WholeVmDeadlineSeconds -eq 1201) 'Unlicensed registered activation lost its measured preparation allowance or inherited licensed deployment time.'
        Assert-True (($result.Limitations -join ' ') -match 'streams are unavailable' -and -not(Test-Path -LiteralPath (Join-Path $TestRoot ($case+'/stdout.txt'))) -and -not(Test-Path -LiteralPath (Join-Path $TestRoot ($case+'/stderr.txt')))) 'Unavailable brokered process streams were represented as captured or empty files.'
        if($case -eq 'registered-explicit'){Assert-True ($result.Payload.RootKind -eq 'Explicit' -and $result.Payload.Package.ManifestPath -ceq 'AppxManifest.xml') 'Explicit package root did not retain verified manifest identity.'}
    }else{Assert-True ($result.Status -eq 'Failed' -and $result.Errors.Count -gt 0) ($case+' accepted missing or contradictory package identity evidence.')}
}
# Preserve real inert ZIP/XML bytes; only the existing VBox/watchdog boundary is
# fake. Windows signature/license acceptance is supplied as explicit guest proof.
$script:licenseSourceArchive=Join-Path $TestRoot 'signed fixture [1] &.msix'
$script:licenseSourceLicense=Join-Path $TestRoot 'offline fixture [2] &.xml'
$script:licenseFixtureSentinel='FixtureOfflineLicensePrivateValue'
function New-FixturePackageContainer {
    param([string]$Destination,[switch]$Mismatch)
    $stream=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $zip=$null
    try{
        $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        foreach($file in Get-ChildItem -LiteralPath $packageRoot -File -Recurse){
            $relative=[IO.Path]::GetRelativePath($packageRoot,$file.FullName).Replace('\','/')
            $entry=$zip.CreateEntry($relative,[IO.Compression.CompressionLevel]::NoCompression)
            $bytes=[IO.File]::ReadAllBytes($file.FullName)
            if($Mismatch -and $relative -eq 'app/entry.exe'){$bytes[0]=0}
            $member=$entry.Open();try{$member.Write($bytes,0,$bytes.Length)}finally{$member.Dispose()}
        }
        $entry=$zip.CreateEntry('[Content_Types].xml',[IO.Compression.CompressionLevel]::NoCompression)
        $member=$entry.Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>');$member.Write($bytes,0,$bytes.Length)}finally{$member.Dispose()}
    }finally{if($zip){$zip.Dispose()};$stream.Dispose()}
}
New-FixturePackageContainer -Destination $script:licenseSourceArchive
[IO.File]::WriteAllText($script:licenseSourceLicense,('<License xmlns="urn:schemas-microsoft-com:windows:store:licensing:ls"><Binding><PFM>Known.RuntimeFixture_0123456789abc</PFM></Binding><Fixture>'+ $script:licenseFixtureSentinel+'</Fixture></License>'))
$archiveOriginal=[IO.File]::ReadAllBytes($script:licenseSourceArchive);$licenseOriginal=[IO.File]::ReadAllBytes($script:licenseSourceLicense)
$script:licenseArchiveHash=(Get-FileHash -LiteralPath $script:licenseSourceArchive -Algorithm SHA256).Hash
$script:licenseXmlHash=(Get-FileHash -LiteralPath $script:licenseSourceLicense -Algorithm SHA256).Hash
foreach($preflight in @(@{Name='archive-only';LaunchMode='RegisteredPackage';PackageArchivePath=$script:licenseSourceArchive},@{Name='license-only';LaunchMode='RegisteredPackage';PackageLicensePath=$script:licenseSourceLicense},@{Name='desktop-pair';LaunchMode='DesktopLayout';PackageArchivePath=$script:licenseSourceArchive;PackageLicensePath=$script:licenseSourceLicense})){
    $preflightName=$preflight.Name;$preflight.Remove('Name');$preflightOutput=Join-Path $TestRoot ('license-preflight-'+$preflightName)
    $callsBefore=$script:vboxCalls;$mutationsBefore=$script:mutations
    Assert-Throws {Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath $preflightOutput -VirtualMachineName $manifest.VirtualMachineName @preflight} 'Unpaired or nonregistered license inputs were accepted.'
    Assert-True ($script:vboxCalls -eq $callsBefore -and $script:mutations -eq $mutationsBefore -and -not(Test-Path -LiteralPath $preflightOutput)) 'Invalid license options reached VM inspection/mutation or created output.'
}
$mismatchedContainer=Join-Path $TestRoot 'different-package.msix';New-FixturePackageContainer -Destination $mismatchedContainer -Mismatch
$invalidLicense=Join-Path $TestRoot 'invalid-license.xml';[IO.File]::WriteAllText($invalidLicense,'<UnrelatedXml/>')
foreach($badInput in @(@{Name='container-mismatch';Archive=$mismatchedContainer;License=$script:licenseSourceLicense},@{Name='invalid-license';Archive=$script:licenseSourceArchive;License=$invalidLicense})){
    $script:packageCase='registered-license-'+$badInput.Name;$script:mutations=0;$script:vmStarts=0;$script:restores=0;$script:controllerLaunches=0;$script:vmSettings=$valid.Clone();$script:licenseTransfers=0
    $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath (Join-Path $TestRoot $script:packageCase) -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1 -LaunchMode RegisteredPackage -PackageArchivePath $badInput.Archive -PackageLicensePath $badInput.License -MaxPackageBytes 1MB
    Assert-True ($result.Status -eq 'Failed' -and $result.Errors.Count -gt 0 -and $script:mutations -eq 0 -and $script:vmStarts -eq 0 -and $script:restores -eq 0 -and $script:controllerLaunches -eq 0 -and $script:licenseTransfers -eq 0) 'Rejected package inputs reached snapshot mutation, VM startup, transfer, or deployment.'
}
foreach($case in 'registered-license-success','registered-license-proof-missing','registered-license-status','registered-license-archive-hash','registered-license-hash-case','registered-license-license-hash','registered-license-full-name','registered-license-restart','registered-license-restart-string','registered-license-restart-number','registered-license-restart-missing','registered-license-source-archive-mutation','registered-license-source-license-mutation','registered-license-preserved-archive-mutation','registered-license-preserved-license-mutation'){
    $script:packageCase=$case;$script:mutations=0;$script:vmStarts=0;$script:restores=0;$script:controllerLaunches=0;$script:vmSettings=$valid.Clone();$script:licenseTransfers=0;$script:licenseLaunchHashesVerified=$false;$script:licensePreservedArchive=$null;$script:licensePreservedLicense=$null
    try{
        $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath (Join-Path $TestRoot $case) -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1 -ExpectedInputSHA256 $inputHash -LaunchMode RegisteredPackage -PackageArchivePath $script:licenseSourceArchive -PackageLicensePath $script:licenseSourceLicense -MaxPackageBytes 1MB
        Assert-True ($script:restores -eq 2 -and $result.Validation.SourceUnchanged -and $result.Validation.PayloadSourceUnchanged -and $result.Validation.CleanSnapshotRestoredAfter -and $result.Validation.PoweredOffAfter -and $result.WatchdogResult.Status -eq 'Cancelled') ($case+' lost clean restoration or unrelated source verification.')
        Assert-True ($script:licenseTransfers -eq 2 -and $script:licenseLaunchHashesVerified -and $script:vmStarts -eq 1 -and $script:controllerLaunches -eq 1) 'Preserved package/license inputs did not reach their exact private transfer and hash-bound launch.'
        Assert-True ($result.Budgets.TargetTimeoutSeconds -eq 1 -and $result.Budgets.PreparationAndObservationAllowanceSeconds -eq 600 -and $result.Budgets.GuestRunnerTimeoutSeconds -eq 601 -and $result.Budgets.ControllerPreparationAndEvidenceAllowanceSeconds -eq 1200 -and $result.Budgets.GuestControllerTimeoutSeconds -eq 1201 -and $result.Budgets.HostControllerCompletionAllowanceSeconds -eq 30 -and $result.Budgets.HostRunnerTimeoutSeconds -eq 1231 -and $result.Budgets.WholeVmPreparationTransferAndEvidenceAllowanceSeconds -eq 1500 -and $result.Budgets.WholeVmDeadlineSeconds -eq 1501 -and $result.Budgets.OutsideControllerTransferAndEvidenceAllowanceSeconds -eq 300) 'Licensed deployment lost its explicit bounded preparation, controller, host or whole-VM allowance.'
        Assert-True ($result.PackageInput.SourceArchivePath -ceq $script:licenseSourceArchive -and $result.PackageInput.SourceLicensePath -ceq $script:licenseSourceLicense -and $result.PackageInput.ArchivePath -ceq $script:licensePreservedArchive -and $result.PackageInput.LicensePath -ceq $script:licensePreservedLicense -and $result.PackageInput.FilesVerified -eq $script:payloadObserved.Files.Count -and $result.PackageInput.Validation.SignatureValidated -eq $false -and $result.PackageInput.Validation.LicenseAcceptedByWindows -eq $false) 'Host byte preservation was confused with authoritative Windows license/signature acceptance.'
        if($case -eq 'registered-license-success'){
            Assert-True ($result.Status -eq 'Completed' -and $result.Validation.PackageInputsUnchanged -and $result.PackageInputSourceVerification.SourcesVerified -eq 2 -and $result.PackageInputSourceVerification.PreservedFilesVerified -eq 2) ('Verified offline licensing failed at the mock boundary: '+($result.Errors -join '; '))
        }elseif($case -like '*-mutation'){
            Assert-True ($result.Status -eq 'Failed' -and -not $result.Validation.PackageInputsUnchanged -and ($result.Errors -join ' ') -match 'Signed package inputs changed') 'Modified original or preserved package/license bytes were not identified after the run.'
        }else{
            Assert-True ($result.Status -eq 'Failed' -and $result.Validation.PackageInputsUnchanged -and ($result.Errors -join ' ') -match 'exact signed package and supplied offline license') 'Missing or contradictory guest license proof was accepted or lost source verification.'
        }
        $hostEvidence=[IO.File]::ReadAllText((Join-Path $result.OutputPath 'runtime-host.json'))
        Assert-True (-not $hostEvidence.Contains($script:licenseFixtureSentinel)) 'Private license XML content leaked into runtime-host evidence.'
    }finally{
        [IO.File]::WriteAllBytes($script:licenseSourceArchive,$archiveOriginal);[IO.File]::WriteAllBytes($script:licenseSourceLicense,$licenseOriginal)
    }
}
Write-Host 'PASS: paired registered-only package/license inputs are preserved as real inert bytes, privately transferred with exact hashes, gated on typed guest license proof, and reverified after cleanup for both originals and retained copies'
foreach($observationSeconds in 120,600){
    $script:expectedObservationSeconds=$observationSeconds;$script:packageCase='registered-license-success';$script:restores=0;$script:controllerLaunches=0;$script:watchdogStarts=0;$script:vmSettings=$valid.Clone()
    $script:watchdogDeadlineObserved=$null;$script:controllerNativeTimeoutObserved=$null;$script:controllerHostTimeoutObserved=$null
    $timeoutParameter=@{};if($observationSeconds -ne 120){$timeoutParameter.TimeoutSeconds=$observationSeconds}
    try{
        $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath (Join-Path $TestRoot ('licensed-deadline-'+$observationSeconds)) -VirtualMachineName $manifest.VirtualMachineName -ExpectedInputSHA256 $inputHash -LaunchMode RegisteredPackage -PackageArchivePath $script:licenseSourceArchive -PackageLicensePath $script:licenseSourceLicense -MaxPackageBytes 1MB @timeoutParameter
        Assert-True ($result.Status -eq 'Completed' -and $script:watchdogStarts -eq 1 -and $script:controllerLaunches -eq 1 -and $script:restores -eq 2) ('A fresh licensed deadline fixture failed: '+($result.Errors -join '; '))
        Assert-True ($result.Budgets.TargetTimeoutSeconds -eq $observationSeconds -and $result.Budgets.GuestRunnerTimeoutSeconds -eq ($observationSeconds+600) -and $result.Budgets.GuestControllerTimeoutSeconds -eq ($observationSeconds+1200) -and $result.Budgets.HostRunnerTimeoutSeconds -eq ($observationSeconds+1230) -and $result.Budgets.WholeVmDeadlineSeconds -eq ($observationSeconds+1500)) 'Default or maximum observation duration was not preserved in explicit licensed budgets.'
        Assert-True ($script:watchdogDeadlineObserved -eq $result.Budgets.WholeVmDeadlineSeconds -and $script:controllerNativeTimeoutObserved -ceq ($result.Budgets.GuestControllerTimeoutSeconds*1000).ToString() -and $script:controllerHostTimeoutObserved -eq $result.Budgets.HostRunnerTimeoutSeconds) 'Fresh native-boundary calls did not use the budgets recorded in evidence.'
    }finally{$script:expectedObservationSeconds=1}
}
Write-Host 'PASS: licensed and unlicensed payload deadlines preserve 1/default120/maximum600-second observation, match watchdog and VBox call arguments, and retain the standalone300-second preparation allowance'
foreach($case in @('registered-pre-run-failure','registered-pre-run-string','registered-pre-run-missing','registered-pre-run-malformed')){
    $script:packageCase=$case;$script:restores=0;$script:controllerLaunches=0;$script:failFinalRestore=$false;$script:vmSettings=$valid.Clone();$script:collectEvidenceOrder=$true;$script:evidenceOrder=@()
    $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath (Join-Path $TestRoot $case) -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1 -ExpectedInputSHA256 $inputHash -LaunchMode RegisteredPackage
    Assert-True ($result.Status -eq 'Failed' -and $script:restores -eq 2 -and $result.WatchdogResult.Status -eq 'Cancelled' -and $script:evidenceOrder[0] -eq 'controller.json' -and $script:evidenceOrder[1] -eq 'package-deployment.json') 'Pre-run diagnostics did not prioritize deployment evidence or preserve verified shutdown.'
    if($case -eq 'registered-pre-run-failure'){
        Assert-True ($script:evidenceOrder.Count -eq 2 -and $result.ControllerResult.HResult -eq -2147009287 -and ($result.Errors -join ' ') -match 'Fixture deployment failed before runner launch' -and -not(Test-Path -LiteralPath (Join-Path $result.OutputPath 'runtime.json'))) 'A proven pre-run failure attempted nonexistent runner files or lost its native diagnostic.'
    }else{
        Assert-True ($script:evidenceOrder.Count -gt 2 -and $script:evidenceOrder -contains 'runtime.json') 'Unknown or malformed controller evidence incorrectly suppressed runner diagnostics.'
    }
}
$script:collectEvidenceOrder=$false
Write-Host 'PASS: proven pre-run failures retain deployment diagnostics first and skip nonexistent runner files; unknown controller records retain full evidence collection'
$progressFixtures=@(
    foreach($mode in 'Standalone','DesktopLayout','RegisteredPackage'){
        foreach($progressCase in 'available','unavailable','missing-final'){@{Mode=$mode;Case=$progressCase}}
    }
    foreach($progressCase in 'incomplete-header','started-header','oversized-header'){@{Mode='RegisteredPackage';Case=$progressCase}}
)
foreach($fixture in $progressFixtures){
    $script:progressCase=$fixture.Case;$script:progressEvidenceReads=@();$script:restores=0;$script:controllerLaunches=0;$script:failFinalRestore=$false;$script:vmSettings=$valid.Clone()
    $script:packageCase=if($fixture.Mode -eq 'RegisteredPackage'){'registered-success'}elseif($fixture.Mode -eq 'DesktopLayout'){'success'}else{$null}
    $parameters=@{InputPath=if($fixture.Mode -eq 'Standalone'){$inputPath}else{$packagedInput};OutputPath=(Join-Path $TestRoot ('progress-'+$fixture.Mode+'-'+$fixture.Case));VirtualMachineName=$manifest.VirtualMachineName;TimeoutSeconds=1;ExpectedInputSHA256=$inputHash}
    if($fixture.Mode -eq 'RegisteredPackage'){$parameters.LaunchMode='RegisteredPackage'}
    try{
        $result=Invoke-ExecutableAnalysisWindowsVm @parameters
        $expectedProgress=if($fixture.Mode -eq 'RegisteredPackage'){@('runtime-progress.json','activation-progress.json')}else{@('runtime-progress.json')}
        $actualProgress=@($script:progressEvidenceReads|Where-Object {$_ -in 'runtime-progress.json','activation-progress.json'})
        Assert-True (($actualProgress -join ',') -ceq ($expectedProgress -join ',') -and $script:progressEvidenceReads -contains 'runtime.json') 'Progress collection selected the wrong launch modes or skipped authoritative runtime evidence.'
        Assert-True ($script:restores -eq 2 -and $result.Validation.CleanSnapshotRestoredAfter -and $result.Validation.PoweredOffAfter -and $result.Validation.SourceUnchanged) 'Progress collection changed restoration or source verification.'
        if($fixture.Case -eq 'unavailable'){
            Assert-True ($result.Status -eq 'Completed' -and $result.Errors.Count -eq 0 -and $result.ProgressArtifactErrors.Count -eq $expectedProgress.Count) 'Missing optional progress poisoned a successful authoritative runtime report.'
            foreach($progressError in $result.ProgressArtifactErrors){Assert-True ($progressError.Path -cin $expectedProgress -and $progressError.Error.Length -eq 2048 -and $progressError.Error.StartsWith('Fixture optional progress unavailable.')) 'Optional progress errors were unbounded or lost their exact artifact identity.'}
            Assert-True (@($result.Artifacts|Where-Object Path -In $expectedProgress).Count -eq 0) 'Unavailable progress was reported as retained evidence.'
        }else{
            Assert-True (@($result.Artifacts|Where-Object Path -In $expectedProgress).Count -eq $expectedProgress.Count -and -not $result.ProgressArtifactErrors) 'Available progress was not retained independently of terminal results.'
            foreach($file in $expectedProgress){$progress=Get-Content -LiteralPath (Join-Path $result.OutputPath $file) -Raw|ConvertFrom-Json;Assert-True ($progress.Phase -ceq 'Finished' -and $progress.Status -ceq 'Completed') 'The terminal-looking checkpoint fixture was not retained.'}
            if($fixture.Case -eq 'available'){
                Assert-True ($result.Status -eq 'Completed' -and $result.GuestResult.Status -eq 'Completed') 'Available checkpoints altered a successful terminal result.'
            }else{
                Assert-True ($result.Status -eq 'Failed' -and -not $result.GuestResult -and ($result.Errors -join ' ') -match 'no retained runtime report' -and -not(Test-Path -LiteralPath (Join-Path $result.OutputPath 'runtime.json'))) 'A checkpoint claiming Finished substituted for missing authoritative runtime evidence.'
                if($fixture.Case -eq 'oversized-header'){
                    Assert-True (-not $result.ControllerResult -and (Get-Item -LiteralPath (Join-Path $result.OutputPath 'controller.json')).Length -gt 1MB) 'An oversized controller diagnostic was parsed into the bounded host report.'
                }elseif($fixture.Case -in 'incomplete-header','started-header'){
                    Assert-True ($result.ControllerResult.Status -ceq 'Failed' -and $result.ControllerResult.RunnerStarted -is [bool] -and $result.ControllerResult.RunnerStarted -eq ($fixture.Case -eq 'started-header') -and $null -eq $result.ControllerResult.Error -and $script:progressEvidenceReads -contains 'network-after.json' -and ($result.Errors -join ' ') -notmatch 'Guest preparation failed before runner launch') 'An incomplete controller header was lost or misclassified as a proven pre-run failure.'
                }else{Assert-True ($result.ControllerResult.Status -ceq 'Completed' -and $result.ControllerResult.RunnerStarted) 'Bounded controller diagnostics were lost when terminal runtime evidence was missing.'}
            }
        }
    }finally{$script:progressCase=$null;$script:progressEvidenceReads=@()}
}
Write-Host 'PASS: optional progress is mode-specific and bounded, cannot replace terminal runtime proof, and preserves bounded controller headers without falsely declaring pre-run failure'
$script:imageFixtureBytes=[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY1sAAAAASUVORK5CYII=')
$imageFixtures=@(
    foreach($mode in 'Standalone','DesktopLayout','RegisteredPackage'){
        foreach($imageCase in 'valid','guest-failure'){@{Mode=$mode;Case=$imageCase}}
    }
    foreach($imageCase in 'exact-limit','oversized','invalid-base64'){@{Mode='RegisteredPackage';Case=$imageCase}}
)
foreach($fixture in $imageFixtures){
    $script:imageCase=$fixture.Case;$script:imageReads=0;$script:imageExpectedBytes=$null;$script:restores=0;$script:controllerLaunches=0;$script:failFinalRestore=$false;$script:vmSettings=$valid.Clone()
    $script:packageCase=if($fixture.Mode -eq 'RegisteredPackage'){'registered-success'}elseif($fixture.Mode -eq 'DesktopLayout'){'success'}else{$null}
    $parameters=@{InputPath=if($fixture.Mode -eq 'Standalone'){$inputPath}else{$packagedInput};OutputPath=(Join-Path $TestRoot ('image-'+$fixture.Mode+'-'+$fixture.Case));VirtualMachineName=$manifest.VirtualMachineName;TimeoutSeconds=1;ExpectedInputSHA256=$inputHash}
    if($fixture.Mode -eq 'RegisteredPackage'){$parameters.LaunchMode='RegisteredPackage'}
    try{
        $result=Invoke-ExecutableAnalysisWindowsVm @parameters
        $imagePath=Join-Path $result.OutputPath 'window.png';$imageArtifacts=@($result.Artifacts|Where-Object Path -CEQ 'window.png')
        $expectedGuestSeconds=if($fixture.Mode -eq 'Standalone'){30}else{60}
        Assert-True ($script:imageReads -eq 1 -and $result.Budgets.GuestEvidenceTransferTimeoutSeconds -eq $expectedGuestSeconds -and $result.Budgets.HostEvidenceTransferTimeoutSeconds -eq ($expectedGuestSeconds+10) -and $script:restores -eq 2 -and $result.Validation.CleanSnapshotRestoredAfter -and $result.Validation.PoweredOffAfter -and $result.Validation.SourceUnchanged -and $result.GuestResult.Status -eq 'Completed') 'Image transfer lost its bounded deadline, terminal runtime evidence or verified cleanup.'
        if($fixture.Case -in 'valid','exact-limit'){
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$expectedImageHash=[BitConverter]::ToString($sha.ComputeHash($script:imageExpectedBytes)).Replace('-','')}finally{$sha.Dispose()}
            Assert-True ($result.Status -eq 'Completed' -and $result.Errors.Count -eq 0 -and $imageArtifacts.Count -eq 1 -and $imageArtifacts[0].Bytes -eq $script:imageExpectedBytes.Length -and $imageArtifacts[0].SHA256 -ceq $expectedImageHash -and (Get-FileHash -LiteralPath $imagePath).Hash -ceq $expectedImageHash) 'Image collection changed its exact bytes, size or recorded checksum.'
            if($fixture.Case -eq 'exact-limit'){Assert-True ($imageArtifacts[0].Bytes -eq 16MB) 'The exact maximum image-size boundary was not accepted.'}
        }else{
            Assert-True ($result.Status -eq 'Partial' -and $result.Errors.Count -eq 1 -and $result.Errors[0] -like 'Could not retain window.png:*' -and $imageArtifacts.Count -eq 0 -and -not(Test-Path -LiteralPath $imagePath)) 'A failed, malformed or oversized image was written, claimed as retained, or lost its separate observation error.'
            if($fixture.Case -eq 'oversized'){Assert-True ($result.Errors[0] -match 'decoded guest image exceeded the 16 MiB' -and [Convert]::ToBase64String($script:imageExpectedBytes).Length -lt 23000000) 'The image test did not prove an independent decoded-byte cap below the encoded capture limit.'}
        }
    }finally{$script:imageCase=$null;$script:imageExpectedBytes=$null}
}
# Execute the actual fixed guest size-check statement against inert lengths;
# this exercises the guard without reading a guest path or emitting image data.
$imageParseErrors=$null
$imageAst=[Management.Automation.Language.Parser]::ParseInput($script:imageTransferScript,[ref]$null,[ref]$imageParseErrors)
$imageTry=@($imageAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
Assert-True ($imageParseErrors.Count -eq 0 -and $imageTry.Count -eq 1) 'The encoded image reader no longer has a bounded try/finally shape.'
$sizeCheck=@($imageTry[0].Body.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst]})
Assert-True ($sizeCheck.Count -eq 1) 'The encoded image size guard is missing or ambiguous.'
foreach($imageLength in 16MB,(16MB+1)){
    $stream=[pscustomobject]@{Length=$imageLength};$imageFailure=$null
    try{& ([scriptblock]::Create($sizeCheck[0].Extent.Text))}catch{$imageFailure=$_.Exception.GetBaseException()}
    if($imageLength -eq 16MB){Assert-True ($null -eq $imageFailure) 'The guest reader rejected the exact maximum image size.'}
    else{Assert-True ($imageFailure.Message -ceq 'Guest image exceeds 16 MiB') 'The actual guest image reader accepted an oversized image.'}
}
Write-Host 'PASS: actual image transfer uses payload60/70 or standalone30/40 deadlines, bounded capture and a separate16MiB decoded cap; exact bytes/maximum are retained, failures preserve terminal runtime and cleanup'
$script:packageCase='success';$script:restores=0;$script:failFinalRestore=$false;$script:vmSettings=$valid.Clone()
$electronRoot=Join-Path $TestRoot 'electron-source';$null=[IO.Directory]::CreateDirectory((Join-Path $electronRoot 'resources'))
$electronInput=Join-Path $electronRoot 'entry.exe';Copy-Item -LiteralPath $inputPath -Destination $electronInput
[IO.File]::WriteAllText((Join-Path $electronRoot 'resources/app.asar'),'Known Electron fixture.')
$electron=Invoke-ExecutableAnalysisWindowsVm -InputPath $electronInput -OutputPath (Join-Path $TestRoot 'electron-runtime') -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1 -ExpectedInputSHA256 $inputHash
Assert-True ($electron.Status -eq 'Completed' -and $electron.Payload.RootKind -eq 'Electron' -and $script:payloadObserved.Files.Count -eq 2) ('Automatic Electron preservation failed: '+($electron.Errors -join '; '))
$script:packageCase=$null;$script:payloadObserved=$null;$script:failFinalRestore=$false;$script:vmSettings=$valid.Clone()
Write-Host 'PASS: Appx/Electron layouts and registered activation require complete hashes, interactive identity, deployment evidence, standard activated token and clean restoration at mocked VBox boundaries'

# Exercise real CLIXML imports and private file creation; only the VBox boundary
# is replaced. Passwords are fixed fixture sentinels and are never output.
$script:baselineSecretSentinels=@('FixtureOnly-NeverUsedOutsideMock-123!','BaselineFixture-Bootstrap-456!','BaselineFixture-Legacy-789!')
$script:expectedBaselineCredentials=@(
    [pscustomobject]@{UserName=$manifest.AdminUser;UserPassword=$script:baselineSecretSentinels[0]},
    [pscustomobject]@{UserName=$manifest.AdminUser;UserPassword=$script:baselineSecretSentinels[1]},
    [pscustomobject]@{UserName='analysis-admin';UserPassword=$script:baselineSecretSentinels[2]}
)
$bootstrapFixture=Join-Path $owned 'bootstrap-credential.clixml';$legacyFixture=Join-Path $owned 'legacy-analysis-admin-credential.clixml'
foreach($entry in @(@($bootstrapFixture,$script:expectedBaselineCredentials[1]),@($legacyFixture,$script:expectedBaselineCredentials[2]))){
    [pscredential]::new($entry[1].UserName,(ConvertTo-SecureString $entry[1].UserPassword -AsPlainText -Force))|Export-Clixml -LiteralPath $entry[0]
    Protect-AnalysisWindowsPrivatePath $entry[0]
}
$bootstrapBytes=[IO.File]::ReadAllBytes($bootstrapFixture);$legacyHash=(Get-FileHash -LiteralPath $legacyFixture).Hash
$reparseTarget=Join-Path $TestRoot 'unrelated-credential-storage';$null=[IO.Directory]::CreateDirectory($reparseTarget)
$reparseMarker=Join-Path $reparseTarget 'preserve.txt';[IO.File]::WriteAllText($reparseMarker,'Known unrelated directory must remain unchanged.')
$reparseMarkerHash=(Get-FileHash -LiteralPath $reparseMarker).Hash
foreach($case in 'valid','invalid-type','reparse-path'){
    $script:baselineCredentialCase=$case;$script:baselineSessionTransfers=0;$script:sessionConfigureCalls=0;$script:controllerLaunches=0
    $script:packageCase='baseline-credentials';$script:restores=0;$script:failFinalRestore=$false;$script:vmSettings=$valid.Clone()
    $baselineOutput=Join-Path $TestRoot ('baseline-credentials-'+$case)
    try{
        if($case -eq 'invalid-type'){[pscustomobject]@{UserName='analysis-admin';UserPassword=$script:baselineSecretSentinels[2]}|Export-Clixml -LiteralPath $bootstrapFixture}
        if($case -eq 'reparse-path'){
            [IO.File]::Delete($bootstrapFixture)
            $null=New-Item -ItemType Junction -Path $bootstrapFixture -Target $reparseTarget
            Assert-True ([bool]((Get-Item -LiteralPath $bootstrapFixture -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'The credential-path reparse fixture was not created.'
        }
        $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath $baselineOutput -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1
        Assert-True ($script:restores -eq 2 -and $result.Validation.CleanSnapshotRestoredAfter -and $result.Validation.PoweredOffAfter) 'Baseline credential handling did not restore its disposable VM fixture.'
        if($case -eq 'valid'){
            Assert-True ($result.Status -eq 'Completed' -and $script:baselineSessionTransfers -eq 1 -and $script:sessionConfigureCalls -eq 1 -and $script:controllerLaunches -eq 1) ('Valid owned baseline credentials did not reach private configuration: '+($result.Errors -join '; '))
            Assert-True ($result.InteractiveSession.BaselineAutoLogon.Classification -eq 'OwnedProvisioningCredential' -and $result.InteractiveSession.BaselineAutoLogon.UserName -eq 'analysis-admin' -and @($result.InteractiveSession.BaselineAutoLogon.PSObject.Properties).Count -eq 2) 'The session result lost its credential-free baseline migration proof.'
        }else{
            Assert-True ($result.Status -eq 'Failed' -and $script:baselineSessionTransfers -eq 0 -and $script:sessionConfigureCalls -eq 0 -and $script:controllerLaunches -eq 0) 'Invalid or reparse baseline credentials reached guest configuration or target launch.'
            Assert-True (($result.Errors -join ' ') -match 'baseline credential') 'Credential refusal lost its explicit validation reason.'
        }
        Assert-True (@(Get-ChildItem -LiteralPath $owned -Filter 'runtime-*').Count -eq 0) 'Baseline credential handling retained a plaintext temporary file.'
        foreach($file in Get-ChildItem -LiteralPath $baselineOutput -Recurse -File|Where-Object Extension -In '.json','.txt','.log'){
            $text=[IO.File]::ReadAllText($file.FullName)
            foreach($sentinel in $script:baselineSecretSentinels){Assert-True (-not $text.Contains($sentinel)) 'A baseline password leaked into retained runtime evidence.'}
        }
        Assert-True ((Get-FileHash -LiteralPath $legacyFixture).Hash -eq $legacyHash -and (Get-FileHash -LiteralPath $reparseMarker).Hash -eq $reparseMarkerHash) 'Credential validation changed unrelated owned credentials or the reparse target.'
    }finally{
        if($case -eq 'reparse-path'){[IO.Directory]::Delete($bootstrapFixture)}
        [IO.File]::WriteAllBytes($bootstrapFixture,$bootstrapBytes);Protect-AnalysisWindowsPrivatePath $bootstrapFixture
    }
}
$script:baselineCredentialCase=$null;$script:packageCase=$null;$script:expectedBaselineCredentials=$null;$script:baselineSecretSentinels=$null
Write-Host 'PASS: owned baseline credentials use private transfer only; invalid types/reparse paths fail before configuration, and arguments/evidence retain no plaintext passwords'

foreach($existing in @($false,$true)){
    $unsafeOutput=Join-Path $packageRoot ('unsafe-output-'+$existing)
    if($existing){$null=[IO.Directory]::CreateDirectory($unsafeOutput)}
    $beforeMutations=$script:mutations
    $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $packagedInput -OutputPath $unsafeOutput -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1
    Assert-True ($result.Status -eq 'Failed' -and $script:mutations -eq $beforeMutations) 'Overlapping package output was accepted or changed VM state.'
    if($existing){
        Assert-True (@(Get-ChildItem -LiteralPath $unsafeOutput -Force).Count -eq 0) 'Refusing an overlapping preexisting output left files behind.'
        [IO.Directory]::Delete($unsafeOutput)
    }else{Assert-True (-not(Test-Path -LiteralPath $unsafeOutput)) 'Refusing overlapping output created a directory.'}
}
Write-Host 'PASS: unsafe package output creates no files or directories and expired deadlines or changed source layouts fail closed'

$beforeCalls=$script:vboxCalls
Assert-Throws {Invoke-ExecutableAnalysisWindowsVm -InputPath $inputPath -OutputPath (Join-Path $TestRoot 'changed-source') -VirtualMachineName $manifest.VirtualMachineName -ExpectedInputSHA256 ('0'*64)} 'A changed source reached the VM adapter.'
Assert-True ($script:vboxCalls -eq $beforeCalls -and -not(Test-Path -LiteralPath (Join-Path $TestRoot 'changed-source'))) 'Source identity mismatch performed VM operations or created output.'

$before=$script:mutations
Assert-Throws {Invoke-ExecutableAnalysisWindowsVm -InputPath $empty -OutputPath (Join-Path $TestRoot 'unsupported')} 'Unsupported input reached the runtime.'
Assert-True ($script:mutations -eq $before) 'Unsupported input changed VM state.'
$whatIfPath=Join-Path $TestRoot 'whatif'
$null=Invoke-ExecutableAnalysisWindowsVm -InputPath $inputPath -OutputPath $whatIfPath -VirtualMachineName $manifest.VirtualMachineName -WhatIf
Assert-True (-not(Test-Path -LiteralPath $whatIfPath) -and $script:mutations -eq $before) 'WhatIf mutated the VM or output.'
Write-Host 'PASS: unsupported input and WhatIf perform no VM mutation or host execution'

Remove-Item -LiteralPath Function:Start-Sleep
$initializerSource=[IO.File]::ReadAllText((Join-Path $repo 'functions/Initialize-ExecutableAnalysisWindowsVm.ps1'))
$initializerSource=$initializerSource.Replace(". (Join-Path `$assets 'WindowsVm.Common.ps1')",'# Helpers already loaded for the mocked process boundary.')
$initializerSource=$initializerSource.Replace("`$assets=Join-Path (Split-Path `$PSScriptRoot -Parent) 'scripts/ExecutableAnalysis'","`$assets='Test boundary already loaded'")
. ([scriptblock]::Create($initializerSource))
$script:vmSettings=$valid.Clone()
$reused=Initialize-ExecutableAnalysisWindowsVm -VirtualMachineName $manifest.VirtualMachineName
Assert-True ($reused.StoragePath -eq $owned -and $reused.VirtualMachineId -eq $manifest.VirtualMachineId) 'Existing custom storage was not resolved through its ownership record.'
Assert-True ($script:mutations -eq $before) 'Reusing an existing owned VM changed VM state.'
$private=Join-Path $TestRoot 'private';$null=[IO.Directory]::CreateDirectory($private)
Protect-AnalysisWindowsPrivatePath $private
$acl=Get-Acl -LiteralPath $private
Assert-True $acl.AreAccessRulesProtected 'Private storage continued to inherit ambient permissions.'
Assert-True (@($acl.Access).Count -eq 3) 'Private storage did not restrict access to its user, SYSTEM, and Administrators.'
Write-Host 'PASS: CRLF VM reuse discovers custom ownership storage; private inheritable ACLs require no elevation'

# Fresh creation failures exercise the current initializer's actual try/finally.
# Replace only local media/free-space/readiness prerequisites: no real disk, ISO,
# VirtualBox process, or network is used, and generated credentials stay in TestRoot.
$script:fixtureIso=Join-Path $TestRoot 'fixture.iso';[IO.File]::WriteAllBytes($script:fixtureIso,[byte[]](1,2,3,4))
$freshSource=$initializerSource.Replace("`$additions=Join-Path `$env:ProgramFiles 'Oracle/VirtualBox/VBoxGuestAdditions.iso'",'$additions=$script:fixtureIso')
$freshSource=$freshSource.Replace('-lt 30GB','-lt 0').Replace('Start-Sleep -Seconds 15','# Readiness is immediate at the mocked boundary.')
. ([scriptblock]::Create($freshSource))
foreach($mode in @('unattended-failure','provision-failure','manifest-write-failure')){
    $script:freshMode=$mode;$script:freshStorage=Join-Path $TestRoot $mode;$script:provisioningFileObserved=$null
    $script:resetConversion=$false;$script:firstBootConfigured=$false
    $script:vmSettings=$valid.Clone()
    try{
        Assert-Throws {Initialize-ExecutableAnalysisWindowsVm -VirtualMachineName ('Fresh-'+$mode) -IsoPath $script:fixtureIso -StoragePath $script:freshStorage} "$mode did not fail as expected."
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $script:freshStorage 'bootstrap-password.tmp'))) "$mode retained its bootstrap password file."
        Assert-True (@(Get-ChildItem -LiteralPath $script:freshStorage -Filter 'provision-*.ps1').Count -eq 0) "$mode retained its provisioning secret file."
        if($mode -ne 'unattended-failure'){
            Assert-True ([bool]$script:provisioningFileObserved) "$mode never reached the intended secret cleanup branch."
            foreach($file in @('pending-guest-credential.clixml','pending-admin-credential.clixml','bootstrap-credential.clixml')){
                Assert-True ((Import-Clixml -LiteralPath (Join-Path $script:freshStorage $file)) -is [pscredential]) "$mode lost a recoverable encrypted credential."
            }
        }
        $released=Enter-AnalysisWindowsVmLock $script:freshStorage;$released.Dispose()
        Assert-True ($script:vmSettings.VMState -eq 'poweroff') "$mode did not power off its owned mock VM."
    }finally{
        $manifestFile=Join-Path $script:freshStorage 'analysis-windows-vm.json'
        if(Test-Path -LiteralPath $manifestFile){(Get-Item -LiteralPath $manifestFile).IsReadOnly=$false}
        $script:freshMode=$null
    }
}
Write-Host 'PASS: fresh initializer failures remove bootstrap/provisioning secrets and release the lock even when manifest persistence fails'

foreach($mode in @('unexpected-poweroff','cpu-verification-failure')){
    $script:freshMode=$mode;$script:freshStorage=Join-Path $TestRoot $mode
    $script:resetConversion=$false;$script:firstBootConfigured=$false;$script:vmSettings=$valid.Clone()
    try{
        Assert-Throws {Initialize-ExecutableAnalysisWindowsVm -VirtualMachineName ('Fresh-'+$mode) -IsoPath $script:fixtureIso -StoragePath $script:freshStorage} "$mode was accepted."
        $failed=Get-Content -LiteralPath (Join-Path $script:freshStorage 'analysis-windows-vm.json') -Raw|ConvertFrom-Json
        Assert-True ($failed.Status -eq 'Failed' -and $failed.ProvisioningPhase -eq 'WindowsPE') 'An invalid transition advanced provisioning.'
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $script:freshStorage 'pending-admin-credential.clixml'))) 'Invalid transition reached account mutation.'
        Assert-True (-not(Test-Path -LiteralPath (Join-Path $script:freshStorage 'bootstrap-password.tmp'))) 'Invalid transition retained the bootstrap plaintext.'
        $released=Enter-AnalysisWindowsVmLock $script:freshStorage;$released.Dispose()
    }finally{$script:freshMode=$null}
}
Write-Host 'PASS: only a verified guest reboot allows the powered-off CPU transition; invalid shutdown/topology fail before account changes'

# Execute the decoded production recipe with only service APIs and its two output
# paths substituted. A failed service start must never publish a readiness marker.
& {
    $readyFile=Join-Path $TestRoot 'postinstall-ready.txt'
    $errorFile=Join-Path $TestRoot 'postinstall-error.txt'
    $recipe=$script:postInstallRecipe.Replace('C:\profile-setup-ready.txt',$readyFile.Replace("'","''")).Replace('C:\profile-setup-error.txt',$errorFile.Replace("'","''"))
    $startFails=$true
    function Start-Service {param([string]$Name,[string]$ErrorAction)if($Name -ne 'VBoxService' -or $startFails){throw 'Mock guest service start failed'}}
    function Get-Service {
        param([string]$Name,[string]$ErrorAction)
        Assert-True ($Name -eq 'VBoxService') 'The recipe queried an unrelated service.'
        $service=[pscustomobject]@{Status=[ServiceProcess.ServiceControllerStatus]::Running}
        $service|Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout)if($Timeout.TotalSeconds -ne 30){throw 'Unbounded readiness wait'}}
        $service|Add-Member ScriptMethod Refresh {}
        $service
    }
    Assert-Throws {& ([scriptblock]::Create($recipe))} 'A guest service failure was ignored.'
    Assert-True (-not(Test-Path -LiteralPath $readyFile)) 'A failed guest service published readiness.'
    Assert-True ((Get-Content -LiteralPath $errorFile -Raw) -match 'Mock guest service start failed') 'The service failure evidence was lost.'
    $startFails=$false
    & ([scriptblock]::Create($recipe))
    Assert-True ((Get-Content -LiteralPath $readyFile -Raw).Trim() -eq 'ready') 'A running guest service did not publish readiness.'
}
Write-Host 'PASS: the exact decoded post-install recipe starts and verifies VBoxService before publishing readiness'

$script:realEnterLock=(Get-Command Enter-AnalysisWindowsVmLock).ScriptBlock
function Enter-AnalysisWindowsVmLock {
    param([string]$StoragePath)
    if($script:freshMode -eq 'lock-failure'){
        [IO.File]::WriteAllText((Join-Path $StoragePath 'bootstrap-password.tmp'),'OTHER_CALLER_FIXTURE')
        [IO.File]::WriteAllText((Join-Path $StoragePath 'analysis-windows-vm.json'),'OTHER_CALLER_MANIFEST')
        throw 'Mock concurrent caller already owns the lock'
    }
    & $script:realEnterLock -StoragePath $StoragePath
}
$script:freshMode='lock-failure';$script:freshStorage=Join-Path $TestRoot 'creation-race'
try{
    Assert-Throws {Initialize-ExecutableAnalysisWindowsVm -VirtualMachineName 'Fresh-creation-race' -IsoPath $script:fixtureIso -StoragePath $script:freshStorage} 'The creation race did not fail closed.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $script:freshStorage 'bootstrap-password.tmp') -Raw) -eq 'OTHER_CALLER_FIXTURE') 'The losing initializer deleted the lock owner credential file.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $script:freshStorage 'analysis-windows-vm.json') -Raw) -eq 'OTHER_CALLER_MANIFEST') 'The losing initializer overwrote the lock owner manifest.'
}finally{$script:freshMode=$null}
Write-Host 'PASS: a losing initializer leaves the active caller credential and ownership files untouched'


# Exercise the controller body with mocked Windows service boundaries. No task is
# registered on the host; the runner report is a fixture, not an executable.
$compileFixture=Join-Path $TestRoot 'Compile-BatchLogonNative.ps1'
@'
param([string]$ControllerPath,[string]$RunnerPath)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($ControllerPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The controller did not parse.'}
$assignment=$ast.Find({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.VariablePath.UserPath -eq 'batchLogonNative'},$true)
$code=$assignment.Right.Expression.Value
if(-not $code){throw 'The native batch-logon source was not found.'}
$types=@(Add-Type -TypeDefinition $code -Language CSharp -PassThru -ErrorAction Stop|Where-Object {$_.IsPublic -and $_.GetMethod('Grant')})
if($types.Count -ne 1){throw 'The native helper did not return exactly one public entrypoint type.'}
$runnerAst=[Management.Automation.Language.Parser]::ParseFile($RunnerPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The runner did not parse.'}
$runnerAssignment=$runnerAst.Find({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.VariablePath.UserPath -eq 'native'},$true)
Add-Type -TypeDefinition $runnerAssignment.Right.Expression.Value -Language CSharp -ReferencedAssemblies System.Drawing,System.Core -ErrorAction Stop
$detailFunction=$runnerAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GuestExceptionDetail'},$true)
. ([scriptblock]::Create($detailFunction.Extent.Text))
$cause=[ComponentModel.Win32Exception]::new(14001);$cause.Data['Operation']='Create suspended target'
$wrapper=[Exception]::new('PowerShell invocation wrapper',$cause)
$detail=Get-GuestExceptionDetail -Exception $wrapper
if($detail.NativeErrorCode -ne 14001 -or $detail.Operation -ne 'Create suspended target' -or $detail.ExceptionType -ne 'System.ComponentModel.Win32Exception' -or -not $detail.NativeErrorMessage -or $detail.WrapperMessage -ne 'PowerShell invocation wrapper'){throw 'Native launch exception details were lost.'}
$plain=Get-GuestExceptionDetail -Exception ([InvalidOperationException]::new('Fixture failure'))
if($null -ne $plain.NativeErrorCode -or $plain.Message -ne 'Fixture failure'){throw 'Non-Win32 failure was mislabeled.'}
# Compile only. Never call the native policy or logon methods on the host.
Write-Output 'PASS: Windows PowerShell 5.1 compiles the guest native helper without invoking it'
'@|Set-Content -LiteralPath $compileFixture -Encoding utf8
& (Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoLogo -NoProfile -NonInteractive -File $compileFixture -ControllerPath (Join-Path $script:fixtureAssets 'WindowsGuestController.ps1') -RunnerPath (Join-Path $script:fixtureAssets 'WindowsGuestRunner.ps1')
Assert-True ($LASTEXITCODE -eq 0) 'The guest native helper failed to compile under Windows PowerShell 5.1.'
Add-Type -TypeDefinition 'public static class ProfileAnalysisBatchLogonFixture {public static bool Allow=true;public static bool Grant(string sid,string user,string domain,string password){if(sid!="S-1-5-21-123-456-789-1001"||user!="analysis-user"||password!="FIXTURE_PASSWORD_ONLY")throw new System.Exception("Unexpected batch-logon identity");return Allow;}}'
foreach($controllerCase in @('success','canonical-name','sid-principal','mismatched-sid','filtered-admin','batch-denied','collision','register-failure','start-failure','nonzero-result','cleanup-failure')){
    & {
        param($caseName)
        $assertController=${function:Assert-True}
        $controllerRoot=Join-Path $TestRoot ('controller-'+$caseName)
        $null=New-Item -ItemType Directory -Path (Join-Path $controllerRoot 'Private'),(Join-Path $controllerRoot 'Results')
        $launchPath=Join-Path $controllerRoot 'Private/launch.json'
        @{UserName='analysis-user';UserPassword='FIXTURE_PASSWORD_ONLY';TimeoutSeconds=1;ExpectedSHA256=('A'*64);MaxProcessMemoryMB=1024;MaxJobMemoryMB=4096}|ConvertTo-Json|Set-Content -LiteralPath $launchPath
        $state=@{Exists=($caseName -eq 'collision');Registered=$false;Started=$false;Removed=$false;RunnerStartedWrites=0;RunnerStartedCheckpoint=$null}
        function Set-Content {
            [CmdletBinding()]
            param([string]$LiteralPath,[string]$Encoding,[Parameter(ValueFromPipeline)]$Value)
            process{
                if($LiteralPath -ceq (Join-Path $controllerRoot 'Private/controller.json')){
                    $checkpoint=$Value|ConvertFrom-Json
                    if($checkpoint.Phases.Count -gt 0 -and $checkpoint.Phases[-1].Name -ceq 'RunnerStarted'){$state.RunnerStartedWrites++;$state.RunnerStartedCheckpoint=$checkpoint}
                }
                Microsoft.PowerShell.Management\Set-Content @PSBoundParameters
            }
        }
        [ProfileAnalysisBatchLogonFixture]::Allow=$caseName -ne 'batch-denied'
        function Add-Type {param($TypeDefinition,$Language,[switch]$PassThru)return [ProfileAnalysisBatchLogonFixture]}
        function Get-LocalGroupMember {
            [CmdletBinding()]param($SID)
            Assert-True ($SID -eq 'S-1-5-32-544') 'The controller queried an unexpected local group.'
            if($caseName -eq 'filtered-admin'){[pscustomobject]@{SID=[pscustomobject]@{Value='S-1-5-21-123-456-789-1001'}}}
        }
        $action=[pscustomobject]@{Path='';Arguments='';WorkingDirectory=''}
        $actions=[pscustomobject]@{Value=$action}
        $actions|Add-Member ScriptMethod Create {param($type)return $this.Value}
        $definition=[pscustomobject]@{Principal=[pscustomobject]@{UserId='';LogonType=0;RunLevel=1};Settings=[pscustomobject]@{Enabled=$false;AllowDemandStart=$false;DisallowStartIfOnBatteries=$true;StopIfGoingOnBatteries=$true;MultipleInstances=0;ExecutionTimeLimit=''};Actions=$actions}
        $task=[pscustomobject]@{Name='PowerShellProfile-ExecutableAnalysis';Definition=$definition;State=3;LastRunTime=[datetime]'2000-01-01';LastTaskResult=267011;Xml='<Task>No credential in task XML</Task>'}
        $task|Add-Member ScriptMethod Run ({
            param($arguments)
            & $assertController (-not(Test-Path -LiteralPath $launchPath)) 'Controller started a task before deleting its credential.'
            if($caseName -eq 'start-failure'){throw 'Fixture start failed'}
            $state.Started=$true
            $this.LastRunTime=[datetime]::UtcNow
            $this.LastTaskResult=if($caseName -eq 'nonzero-result'){1}else{0}
            '{"Status":"Completed"}'|Set-Content -LiteralPath (Join-Path $controllerRoot 'Results/runtime.json')
        }.GetNewClosure())
        $task|Add-Member ScriptMethod Stop ({
            param($flags)
            if($caseName -eq 'cleanup-failure'){throw 'Fixture stop failed'}
        }.GetNewClosure())
        $state.Task=$task
        $folder=[pscustomobject]@{}
        $folder|Add-Member ScriptMethod GetTasks ({param($flags)if($state.Exists){return $state.Task}}.GetNewClosure())
        $folder|Add-Member ScriptMethod GetTask ({param($name)return $state.Task}.GetNewClosure())
        $folder|Add-Member ScriptMethod DeleteTask ({param($name,$flags)$state.Exists=$false;$state.Removed=$true}.GetNewClosure())
        $folder|Add-Member ScriptMethod RegisterTaskDefinition ({
            param($name,$taskDefinition,$flags,$user,$password,$logonType)
            & $assertController ($flags -eq 2 -and $logonType -eq 1 -and $password -eq 'FIXTURE_PASSWORD_ONLY') 'Controller lost create-only registration or password logon.'
            & $assertController ($user -eq ($env:COMPUTERNAME+'\analysis-user') -and $taskDefinition.Principal.RunLevel -eq 0) 'Controller changed its limited account.'
            & $assertController ($taskDefinition.Settings.ExecutionTimeLimit -eq 'PT301S') 'Controller lost the bounded task lifetime.'
            & $assertController ($taskDefinition.Actions.Value.Path -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -and $taskDefinition.Actions.Value.Arguments -notmatch 'FIXTURE_PASSWORD_ONLY') 'Controller task command changed or exposed its credential.'
            if($caseName -eq 'register-failure'){throw 'Fixture registration failed'}
            $state.Exists=$true;$state.Registered=$true;$state.Task.Definition=$taskDefinition
            if($caseName -eq 'canonical-name'){$state.Task.Definition.Principal.UserId='analysis-user'}
            if($caseName -eq 'sid-principal'){$state.Task.Definition.Principal.UserId='S-1-5-21-123-456-789-1001'}
            if($caseName -eq 'mismatched-sid'){$state.Task.Definition.Principal.UserId='unexpected-user'}
            return $state.Task
        }.GetNewClosure())
        $scheduler=[pscustomobject]@{}
        $scheduler|Add-Member ScriptMethod Connect {}
        $scheduler|Add-Member ScriptMethod GetFolder ({param($path)return $folder}.GetNewClosure())
        $scheduler|Add-Member ScriptMethod NewTask ({param($flags)return $definition}.GetNewClosure())
        function New-Object {
            param($TypeName,$ArgumentList,$ComObject)
            if($ComObject -eq 'Schedule.Service'){return $scheduler}
            if($TypeName -eq 'Security.Principal.NTAccount'){
                $account=[pscustomobject]@{AccountName=[string]$ArgumentList}
                $account|Add-Member ScriptMethod Translate {param($targetType)return [pscustomobject]@{Value=$(if($this.AccountName -eq 'unexpected-user'){'S-1-5-21-123-456-789-9999'}else{'S-1-5-21-123-456-789-1001'})}}
                return $account
            }
            if($TypeName -ne 'Security.Principal.WindowsPrincipal'){throw 'Unexpected native object in controller fixture'}
            $value=[pscustomobject]@{};$value|Add-Member ScriptMethod IsInRole {param($role)return $true};return $value
        }

        $controllerSource=(Get-Content -LiteralPath (Join-Path $script:fixtureAssets 'WindowsGuestController.ps1') -Raw).Replace('C:\ProfileAnalysis',$controllerRoot)
        $failed=$false
        try{& ([scriptblock]::Create($controllerSource))|Out-Null}catch{$failed=$true}
        $observation=Get-Content -LiteralPath (Join-Path $controllerRoot 'Private/controller.json') -Raw|ConvertFrom-Json
        Assert-True $observation.CredentialRemovedBeforeLaunch 'Controller did not retain credential deletion evidence.'
        Assert-True (-not(Test-Path -LiteralPath $launchPath)) 'Controller left its credential after failure.'
        if($caseName -in 'success','canonical-name','sid-principal'){
            Assert-True (-not $failed -and $observation.Status -eq 'Completed' -and $observation.TaskRemoved -and $observation.RunnerExitCode -eq 0) 'Successful task controller failed its outcome checks.'
        }else{
            Assert-True ($failed -and $observation.Status -eq 'Failed') ($caseName+' was falsely reported as successful.')
        }
        if($state.Registered){Assert-True $state.Removed ($caseName+' did not remove its owned task.')}
        if($state.Started){
            Assert-True ($state.RunnerStartedWrites -eq 1 -and $state.RunnerStartedCheckpoint.RunnerStarted -and $null -eq $state.RunnerStartedCheckpoint.RunnerExitCode -and -not $state.RunnerStartedCheckpoint.TaskRemoved) 'The controller did not persist first-observed runner startup before terminal validation and cleanup.'
        }else{Assert-True ($state.RunnerStartedWrites -eq 0) 'The controller persisted runner startup before observing it.'}
        if($caseName -eq 'collision'){Assert-True ($state.Exists -and -not $state.Removed) 'Controller touched an existing task.'}
    } $controllerCase
}
Write-Host 'PASS: the actual controller bounds limited password-logon tasks, deletes credentials before launch, retains native failure and cleans up only its owned task'
