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
foreach($fault in @(@{Key='nic8';Value='nat'},@{Key='usb';Value='on'},@{Key='clipboard';Value='bidirectional'},@{Key='SharedFolderNameMachineMapping1';Value='host'},@{Key='UUID';Value='unrelated'},@{Key='SATA-1-0';Value=(Join-Path $owned 'host.iso')},@{Key='SATA-0-0';Value=(Join-Path $TestRoot 'outside.vdi')})){
    $broken=$valid.Clone();$broken[$fault.Key]=$fault.Value
    Assert-Throws {Assert-AnalysisWindowsVmIsolation $broken ([pscustomobject]$manifest)} ('Unsafe VM state was accepted: '+$fault.Key)
}
$broken=$valid.Clone();$broken.Remove('uart4');Assert-Throws {Assert-AnalysisWindowsVmIsolation $broken ([pscustomobject]$manifest)} 'Unknown UART state was accepted.'
Write-Host 'PASS: actual isolation validator rejects unknown settings, external storage, networking, and host integration'

# Run the real orchestration body with only its VBox process boundary mocked. It must
# neither need VirtualBox nor install software, start a VM, or execute an input in CI.
$runtimeSource=[IO.File]::ReadAllText((Join-Path $repo 'functions/Invoke-ExecutableAnalysisWindowsVm.ps1'))
$runtimeSource=$runtimeSource.Replace(". (Join-Path `$assets 'WindowsVm.Common.ps1')",'# Already imported the actual helpers; replace only the VBox process boundary below.')
$script:fixtureAssets=Join-Path $repo 'scripts/ExecutableAnalysis'
$runtimeSource=$runtimeSource.Replace("`$assets=Join-Path (Split-Path `$PSScriptRoot -Parent) 'scripts/ExecutableAnalysis'",'$assets=$script:fixtureAssets')
. ([scriptblock]::Create($runtimeSource))
$manifestPath=Join-Path $owned 'manifest.json';$manifest|ConvertTo-Json|Set-Content -LiteralPath $manifestPath -Encoding utf8
$script:fixtureManifestPath=$manifestPath
foreach($role in @('Guest','Admin')){
    $user=if($role -eq 'Guest'){$manifest.GuestUser}else{$manifest.AdminUser}
    $path=if($role -eq 'Guest'){$manifest.CredentialPath}else{$manifest.AdminCredentialPath}
    [pscredential]::new($user,(ConvertTo-SecureString 'FixtureOnly-NeverUsedOutsideMock-123!' -AsPlainText -Force))|Export-Clixml -LiteralPath $path
}
$script:vmSettings=$valid.Clone();$script:mutations=0;$script:restores=0;$script:failGuest=$false;$script:failFinalRestore=$false;$script:pauseGuest=$false
$inputHash=(Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
function Invoke-AnalysisWindowsVBox {
    param([string[]]$ArgumentList,[int]$TimeoutSeconds=60,[int]$MaxOutputCharacters=1048576)
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
                return ''
            }
            'createvm' {$script:vmSettings.name=$ArgumentList[2];return ''}
            {$_ -in 'setextradata','modifyvm','createmedium','storagectl','storageattach'} {return ''}
            'guestcontrol' {
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
        'showvminfo' {return ($script:vmSettings.GetEnumerator()|ForEach-Object {'{0}="{1}"' -f $_.Key,$_.Value}) -join "`n"}
        'getextradata' {return 'Value: '+$script:fixtureManifestPath}
        'snapshot' {
            if($ArgumentList[2] -eq 'list'){return 'SnapshotUUID="'+$manifest.SnapshotId+'"'+"`r`n"}
            $script:mutations++;$script:restores++
            if($script:failFinalRestore -and $script:restores -eq 2){throw 'Mock final snapshot restore failed'}
            Assert-True ($ArgumentList[3] -eq $manifest.SnapshotId) 'Runtime restored a snapshot other than the recorded UUID.'
            $script:vmSettings.VMState='poweroff';return ''
        }
        'startvm' {$script:mutations++;$script:vmSettings.VMState='running';return ''}
        'controlvm' {$script:mutations++;$script:vmSettings.VMState='poweroff';return ''}
        'guestcontrol' {
            if($ArgumentList[2] -eq 'copyto'){
                if($ArgumentList[-1] -like '*\target.exe'){Assert-True ($ArgumentList[-2] -eq $inputPath) 'Input path changed instead of remaining a literal process argument.'}
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\launch.json'){
                    $script:launchFileObserved=$ArgumentList[-2]
                    Assert-True ((Get-Acl -LiteralPath $script:launchFileObserved).AreAccessRulesProtected) 'The profile launch credential inherited ambient access.'
                    $launch=Get-Content -LiteralPath $script:launchFileObserved -Raw|ConvertFrom-Json
                    Assert-True ($launch.UserName -eq $manifest.GuestUser -and $launch.ExpectedSHA256 -eq $inputHash -and $launch.TimeoutSeconds -eq 1) 'The private standard-user launch configuration changed.'
                    if($script:failLaunchCopy){throw 'Mock private credential copy failed'}
                }
                elseif($ArgumentList[-1] -eq 'C:\ProfileAnalysis\Private\Controller.ps1'){Assert-True ($ArgumentList[-2] -eq (Join-Path $script:fixtureAssets 'WindowsGuestController.ps1')) 'The profile-loading controller was not the trusted asset.'}
                else{Assert-True ($ArgumentList[-2] -eq (Join-Path $script:fixtureAssets 'WindowsGuestRunner.ps1')) 'The copied guest runner was not the trusted asset.'}
                return ''
            }
            if($ArgumentList -contains 'echo ready'){return 'ready'}
            if($ArgumentList -contains '-File'){
                Assert-True ($ArgumentList -contains 'C:\ProfileAnalysis\Private\Controller.ps1') 'The target was launched without the profile-loading controller.'
                Assert-True (-not(Test-Path -LiteralPath $script:launchFileObserved)) 'The host retained its plaintext launch credential during execution.'
                if($script:pauseGuest){$script:vmSettings.VMState='paused';throw 'Mock guest was paused'}
                if($script:failGuest){throw 'Mock guest failed'}
                return 'PROFILE_ANALYSIS_RUNTIME=Completed'
            }
            $index=[Array]::IndexOf($ArgumentList,'-EncodedCommand')
            if($index -lt 0){throw 'Unexpected guest control invocation'}
            $transfer=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[$index+1]))
            if($transfer -match "New-Item -ItemType Directory -Path 'C:\\ProfileAnalysis\\Private'"){
                Assert-True ($transfer -match '/inheritance:r' -and $transfer -match 'S-1-5-32-544' -and $transfer -match 'S-1-5-18') 'Private guest launch directory restrictions were omitted.'
                return ''
            }
            Assert-True ($transfer -match '16777217') 'Evidence transfer lost its guest byte limit.'
            Assert-True ($MaxOutputCharacters -eq 23000000) 'Evidence transfer lost its host capture limit.'
            if($transfer -match 'runtime\.json'){
                $data=@{Status=if($script:failGuest){'Failed'}else{'Completed'};GuestUser=('FIXTURE\'+$manifest.GuestUser);UserEnvironment=@{UserName=$manifest.GuestUser;LoadedHiveSid='S-1-5-21-123-456-789-1001'};IsAdministrator=$false;TargetSHA256=$inputHash;RunnerSHA256=(Get-FileHash -LiteralPath (Join-Path $script:fixtureAssets 'WindowsGuestRunner.ps1')).Hash;Validation=@{AccountNotAdministrator=(-not $script:filteredAdmin);UserProfileLoaded=(-not $script:profileMissing);HashMatched=$true;NoNetworkAdapter=$true};Execution=@{JobAssigned=(-not $script:failGuest);JobClosed=$true;Reason='Completed';ExitCode=0}}|ConvertTo-Json -Depth 6 -Compress
            }elseif($transfer -match 'controller\.json'){
                Assert-True ($transfer -match 'Private\\controller\.json' -and $ArgumentList -contains $manifest.AdminUser) 'Controller evidence was not read privately by the management account.'
                $controllerData=@{Status='Completed';BatchLogonRightVerified=$true;TaskPrincipal=@{UserId=('FIXTURE\'+$manifest.GuestUser);UserSid='S-1-5-21-123-456-789-1001';ExpectedUserSid='S-1-5-21-123-456-789-1001';LogonType='Password';RunLevel='Limited'};CredentialRemovedBeforeLaunch=$true;TaskRemoved=$true;RunnerStarted=$true;RunnerExitCode=0;Error=$null}
                if($script:badController -eq 'controller-error'){$controllerData.Error='Fixture controller failure'}
                elseif($script:badController -eq 'controller-exit'){$controllerData.RunnerExitCode=1}
                elseif($script:badController -eq 'controller-principal'){$controllerData.TaskPrincipal.UserId='FIXTURE\unexpected'}
                elseif($script:badController -eq 'controller-elevation'){$controllerData.TaskPrincipal.RunLevel='Highest'}
                elseif($script:badController -eq 'controller-status'){$controllerData.Status='Failed'}
                elseif($script:badController){$controllerData[$script:badController]=$false}
                $data=$controllerData|ConvertTo-Json -Compress
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

foreach($case in @('success','guest-failure','cleanup-failure','paused-guest','filtered-admin','missing-profile','launch-copy-failure','CredentialRemovedBeforeLaunch','TaskRemoved','RunnerStarted','controller-error','controller-exit','controller-principal','controller-elevation','controller-status')){
    $script:badController=if($case -in 'CredentialRemovedBeforeLaunch','TaskRemoved','RunnerStarted','controller-error','controller-exit','controller-principal','controller-elevation','controller-status'){$case}else{$null}
    $script:restores=0;$script:vmSettings=$valid.Clone();$script:failGuest=$case -in 'guest-failure','paused-guest';$script:failFinalRestore=$case -eq 'cleanup-failure';$script:pauseGuest=$case -eq 'paused-guest';$script:filteredAdmin=$case -eq 'filtered-admin';$script:profileMissing=$case -eq 'missing-profile';$script:failLaunchCopy=$case -eq 'launch-copy-failure'
    $result=Invoke-ExecutableAnalysisWindowsVm -InputPath $inputPath -OutputPath (Join-Path $TestRoot $case) -VirtualMachineName $manifest.VirtualMachineName -TimeoutSeconds 1
    Assert-True ($script:restores -eq 2) "$case did not attempt both snapshot restores."
    Assert-True (@(Get-ChildItem -LiteralPath $owned -Filter 'runtime-*').Count -eq 0) "$case left plaintext credentials."
    Assert-True $result.Validation.SourceUnchanged "$case changed the input."
    Assert-True ($result.Budgets.TargetTimeoutSeconds -eq 1 -and $result.Budgets.PreparationAndObservationAllowanceSeconds -eq 300 -and $result.Budgets.GuestRunnerTimeoutSeconds -eq 301) 'Preparation allowance changed the actual target timeout or was not reported.'
    if($case -eq 'success'){
        Assert-True ($result.Status -eq 'Completed') ('Successful mock did not complete: '+($result.Errors -join '; '))
        Assert-True ($result.Validation.CleanSnapshotRestoredAfter -and $result.Validation.PoweredOffAfter) 'Successful mock did not verify cleanup.'
    }else{Assert-True ($result.Status -eq 'Failed') "$case was reported as success."}
    $available=Enter-AnalysisWindowsVmLock $owned;$available.Dispose()
}
Write-Host 'PASS: orchestration preserves literal paths and source bytes, bounds transfers, restores after failures, and removes credentials'

$before=$script:mutations
Assert-Throws {Invoke-ExecutableAnalysisWindowsVm -InputPath $empty -OutputPath (Join-Path $TestRoot 'unsupported')} 'Unsupported input reached the runtime.'
Assert-True ($script:mutations -eq $before) 'Unsupported input changed VM state.'
$whatIfPath=Join-Path $TestRoot 'whatif'
$null=Invoke-ExecutableAnalysisWindowsVm -InputPath $inputPath -OutputPath $whatIfPath -VirtualMachineName $manifest.VirtualMachineName -WhatIf
Assert-True (-not(Test-Path -LiteralPath $whatIfPath) -and $script:mutations -eq $before) 'WhatIf mutated the VM or output.'
Write-Host 'PASS: unsupported input and WhatIf perform no VM mutation or host execution'

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
Add-Type -TypeDefinition $runnerAssignment.Right.Expression.Value -Language CSharp -ErrorAction Stop
# Compile only. Never call the native policy or logon methods on the host.
Write-Output 'PASS: Windows PowerShell 5.1 compiles the guest native helper without invoking it'
'@|Set-Content -LiteralPath $compileFixture -Encoding utf8
& (Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe') -NoLogo -NoProfile -NonInteractive -File $compileFixture -ControllerPath (Join-Path $script:fixtureAssets 'WindowsGuestController.ps1') -RunnerPath (Join-Path $script:fixtureAssets 'WindowsGuestRunner.ps1')
Assert-True ($LASTEXITCODE -eq 0) 'The guest native helper failed to compile under Windows PowerShell 5.1.'
Add-Type -TypeDefinition 'public static class ProfileAnalysisBatchLogonFixture {public static bool Allow=true;public static bool Grant(string sid,string user,string domain,string password){if(sid!="S-1-5-21-123-456-789-1001"||user!="analysis-user"||password!="FIXTURE_PASSWORD_ONLY")throw new System.Exception("Unexpected batch-logon identity");return Allow;}}'
foreach($controllerCase in @('success','canonical-name','sid-principal','mismatched-sid','filtered-admin','batch-denied','collision','register-failure','start-failure','nonzero-result','cleanup-failure')){
    & {
        param($caseName)
        $controllerRoot=Join-Path $TestRoot ('controller-'+$caseName)
        $null=New-Item -ItemType Directory -Path (Join-Path $controllerRoot 'Private'),(Join-Path $controllerRoot 'Results')
        $launchPath=Join-Path $controllerRoot 'Private/launch.json'
        @{UserName='analysis-user';UserPassword='FIXTURE_PASSWORD_ONLY';TimeoutSeconds=1;ExpectedSHA256=('A'*64)}|ConvertTo-Json|Set-Content -LiteralPath $launchPath
        $state=@{Exists=($caseName -eq 'collision');Registered=$false;Started=$false;Removed=$false}
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
            Assert-True (-not(Test-Path -LiteralPath $launchPath)) 'Controller started a task before deleting its credential.'
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
            Assert-True ($flags -eq 2 -and $logonType -eq 1 -and $password -eq 'FIXTURE_PASSWORD_ONLY') 'Controller lost create-only registration or password logon.'
            Assert-True ($user -eq ($env:COMPUTERNAME+'\analysis-user') -and $taskDefinition.Principal.RunLevel -eq 0) 'Controller changed its limited account.'
            Assert-True ($taskDefinition.Settings.ExecutionTimeLimit -eq 'PT301S') 'Controller lost the bounded task lifetime.'
            Assert-True ($taskDefinition.Actions.Value.Path -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -and $taskDefinition.Actions.Value.Arguments -notmatch 'FIXTURE_PASSWORD_ONLY') 'Controller task command changed or exposed its credential.'
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
        if($caseName -eq 'collision'){Assert-True ($state.Exists -and -not $state.Removed) 'Controller touched an existing task.'}
    } $controllerCase
}
Write-Host 'PASS: the actual controller bounds limited password-logon tasks, deletes credentials before launch, retains native failure and cleans up only its owned task'
