# Trusted deployment helper. Run only inside the owned offline disposable VM.
#requires -Version 5.1
param(
    [Parameter(Mandatory)][ValidateSet('Stage','Register')][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$PayloadManifestSHA256,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{2,255}$')][string]$ExpectedPackageFullName,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$PackageArchiveSHA256,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$PackageLicenseSHA256
)
$ErrorActionPreference='Stop'
$manifestPath='C:\ProfileAnalysis\payload-manifest.json'
$root='C:\ProfileAnalysis\Work\Application'
$reportPath=if($Mode -eq 'Stage'){'C:\ProfileAnalysis\Private\package-deployment.json'}else{'C:\ProfileAnalysis\Results\package-registration.json'}
$deploymentProfile=$null
$record=[ordered]@{Status='Failed';Mode=$Mode;StartedUtc=[DateTime]::UtcNow.ToString('o');PayloadManifestSHA256=$PayloadManifestSHA256;Steps=@();Error=$null;HResult=$null;Containment='Whole offline VM; package services and deployment are not contained by an application process Job.'}
function Save-DeploymentStep([string]$Name){$record.Steps+=@{Name=$Name;Utc=[DateTime]::UtcNow.ToString('o')};$record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding utf8}
function Invoke-DeploymentLicensedPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ArchiveSHA256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$LicenseSHA256
    )
    $archivePath='C:\ProfileAnalysis\Private\package.msix'
    $licensePath='C:\ProfileAnalysis\Private\package-license.xml'
    foreach($inputFile in @(@($archivePath,$ArchiveSHA256,64GB),@($licensePath,$LicenseSHA256,1MB))){
        $item=Get-Item -LiteralPath $inputFile[0] -Force -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -le 0 -or $item.Length -gt $inputFile[2]){throw 'A licensed deployment input is not a bounded regular file.'}
        if((Get-FileHash -LiteralPath $inputFile[0] -Algorithm SHA256 -ErrorAction Stop).Hash -cne $inputFile[1].ToUpperInvariant()){throw 'A licensed deployment input changed during transfer.'}
    }
    if(-not $PSCmdlet.ShouldProcess('Owned offline Windows guest','Provision the original signed package with its supplied offline license')){throw 'Licensed deployment was not performed.'}
    # Online selects the running guest OS. It does not enable network connectivity.
    # Never use SkipLicense, alter a manifest, or import a host license store.
    try{$provision=@(Add-AppxProvisionedPackage -Online -PackagePath $archivePath -LicensePath $licensePath -Regions all -ErrorAction Stop)}
    catch{$cause=$_.Exception.GetBaseException();$cause.Data['Operation']='Add-AppxProvisionedPackage';throw}
    if($provision.Count -ne 1 -or $provision[0].Online -isnot [bool] -or -not $provision[0].Online -or $provision[0].RestartNeeded -isnot [bool] -or $provision[0].RestartNeeded){throw 'Licensed package provisioning did not verify the running guest without a required restart.'}
    [pscustomobject]@{Status='Provisioned';ArchiveSHA256=$ArchiveSHA256;LicenseSHA256=$LicenseSHA256;RestartNeeded=$false;Method='Add-AppxProvisionedPackage -Online -PackagePath -LicensePath -Regions all';Validation='Windows accepted the supplied original package and license; exact provisioned identity is checked separately.'}
}
function Select-DeploymentStagedPackage {
    [CmdletBinding()]
    param([object[]]$Candidates,[Parameter(Mandatory)]$Identity)
    $pattern='^'+[regex]::Escape($Identity.Name)+'_'+[regex]::Escape($Identity.Version)+'_'+[regex]::Escape($Identity.ProcessorArchitecture)+'_'+[regex]::Escape([string]$Identity.ResourceId)+'_[a-z0-9]{13}$'
    $matchingPackages=@($Candidates|Where-Object {$_.Name -eq $Identity.Name -and $_.Version -and $_.Version.ToString() -eq $Identity.Version -and $_.Publisher -eq $Identity.Publisher -and $_.Architecture -and $_.Architecture.ToString() -ieq $Identity.ProcessorArchitecture -and [string]$_.ResourceId -ceq [string]$Identity.ResourceId})
    if($matchingPackages.Count -ne 1 -or $matchingPackages[0].PackageFullName -notmatch $pattern){throw 'The exact staged package identity is missing or ambiguous.'}
    return $matchingPackages[0]
}
function Set-DeploymentDiagnosticText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Updates only the in-memory bounded diagnostic record; it has no external side effects.')]
    [CmdletBinding()]
    param([string]$Name,[string]$Value,[int]$Limit=16384)
    $record[$Name]=$Value.Substring(0,[Math]::Min($Limit,$Value.Length))
    $record[$Name+'Truncated']=$Value.Length -gt $Limit
}
function Get-DeploymentPathPermission([string]$Root){
    @($Root,(Split-Path -Parent $Root),'C:\ProfileAnalysis'|ForEach-Object {
        $acl=Get-Acl -LiteralPath $_ -ErrorAction Stop
        $owner=[string]$acl.Owner;$sddl=[string]$acl.Sddl
        [ordered]@{Path=$_;Owner=$owner.Substring(0,[Math]::Min(16384,$owner.Length));OwnerTruncated=$owner.Length -gt 16384;Sddl=$sddl.Substring(0,[Math]::Min(65536,$sddl.Length));SddlTruncated=$sddl.Length -gt 65536}
    })
}
function New-DeploymentOperationView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Constructs an in-memory interface adapter; creating the adapter does not invoke or cancel the operation.')]
    [CmdletBinding()]
    param($Operation,[Type]$Contract)
    if($null -eq $Operation -or $null -eq $Contract){throw 'The WinRT operation and metadata are required.'}
    # Windows PowerShell exposes these operations as System.__ComObject. Direct
    # .Status/.GetResults() access is unavailable; invoke the projected interfaces.
    $info=@($Contract.GetInterfaces()|Where-Object FullName -EQ 'Windows.Foundation.IAsyncInfo')
    if($info.Count -ne 1 -or -not $Contract.GetMethod('GetResults')){throw 'The WinRT operation metadata is unavailable.'}
    $infoType=$info[0];$view=[pscustomobject]@{}
    $view|Add-Member ScriptProperty Status {$infoType.GetProperty('Status').GetValue($Operation,$null)}.GetNewClosure()
    $view|Add-Member ScriptProperty ErrorCode {$infoType.GetProperty('ErrorCode').GetValue($Operation,$null)}.GetNewClosure()
    $view|Add-Member ScriptMethod GetResults {$Contract.GetMethod('GetResults').Invoke($Operation,[object[]]@())}.GetNewClosure()
    $view|Add-Member ScriptMethod Cancel {$infoType.GetMethod('Cancel').Invoke($Operation,[object[]]@())}.GetNewClosure()
    return $view
}
function Get-DeploymentFailure($Operation,[Exception]$OriginalError) {
    $cause=$OriginalError.GetBaseException()
    $code=$cause.HResult
    try {
        $record['DeploymentOperationStatus']=$Operation.Status.ToString()
        if($Operation.ErrorCode){$record['DeploymentOperationHResult']=$Operation.ErrorCode.HResult}
        # A faulted AsTask throws before returning DeploymentResult. The original
        # WinRT operation still provides its detailed result in the Error state.
        if($Operation.Status.ToString() -eq 'Error'){
            $details=$Operation.GetResults()
            $record['DeploymentActivityId']=$details.ActivityId.ToString()
            $message=[string]$details.ErrorText
            Set-DeploymentDiagnosticText 'DeploymentErrorText' $message
            if($details.ExtendedErrorCode -and $details.ExtendedErrorCode.HResult -ne 0){
                $code=$details.ExtendedErrorCode.HResult
                $record['DeploymentExtendedHResult']=$code
            }
            if($message -or $code -ne $cause.HResult){
                if(-not $message){Set-DeploymentDiagnosticText 'DeploymentExtendedErrorText' ([string]$details.ExtendedErrorCode.Message)}
                $reason=if($message){$record.DeploymentErrorText}else{$record.DeploymentExtendedErrorText}
                return [Runtime.InteropServices.COMException]::new(('Package deployment failed: '+$reason),$code)
            }
        }
    }catch{Set-DeploymentDiagnosticText 'DeploymentDiagnosticError' $_.Exception.GetBaseException().Message}
    return $cause
}
function Wait-DeploymentOperation($Operation) {
    $method=[System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Count -eq 2 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperationWithProgress`2'}|Select-Object -First 1
    if(-not $method){throw 'The bounded WinRT deployment adapter is unavailable.'}
    $closed=$method.MakeGenericMethod([Windows.Management.Deployment.DeploymentResult],[Windows.Management.Deployment.DeploymentProgress])
    $view=New-DeploymentOperationView -Operation $Operation -Contract $closed.GetParameters()[0].ParameterType
    $task=$closed.Invoke($null,@($Operation))
    try{
        if(-not $task.Wait(180000)){try{$view.Cancel()}catch{Write-Verbose 'The deployment broker could not acknowledge cancellation; the independent host VM deadline still applies.'};throw [TimeoutException]::new('Package deployment exceeded its 180-second operation deadline.')}
        $result=$task.GetAwaiter().GetResult()
    }catch{throw (Get-DeploymentFailure -Operation $view -OriginalError $_.Exception)}
    if($result.ExtendedErrorCode -and $result.ExtendedErrorCode.HResult -ne 0){
        Set-DeploymentDiagnosticText 'DeploymentErrorText' ([string]$result.ErrorText)
        $record['DeploymentActivityId']=$result.ActivityId.ToString()
        $record['DeploymentExtendedHResult']=$result.ExtendedErrorCode.HResult
        throw [Runtime.InteropServices.COMException]::new(('Package deployment failed: '+$record.DeploymentErrorText),$result.ExtendedErrorCode.HResult)
    }
}
try {
    if([bool]$PackageArchiveSHA256 -ne [bool]$PackageLicenseSHA256 -or (($PackageArchiveSHA256 -or $PackageLicenseSHA256) -and $Mode -ne 'Stage')){throw 'Licensed package inputs must be paired and supplied only to machine deployment.'}
    if((Get-Item -LiteralPath $manifestPath -ErrorAction Stop).Length -gt 32MB -or (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256 -ErrorAction Stop).Hash -ne $PayloadManifestSHA256){throw 'The preserved payload manifest changed before deployment.'}
    $payload=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($payload.RootKind -notin 'AppxDirectory','Explicit' -or -not $payload.Package.Identity.Name -or $payload.Package.ManifestPath -ne 'AppxManifest.xml'){throw 'Registered activation requires a preserved Appx package root.'}
    $appx=Join-Path $root 'AppxManifest.xml'
    $identity=$payload.Package.Identity
    if($identity.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{2,49}$' -or $identity.Version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or @($payload.Package.Services).Count -gt 128){throw 'Package identity or service inventory exceeds the supported schema.'}
    $record.Identity=$identity
    $record.PackageManifestUnmodified=$null
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $record.Caller=[Security.Principal.WindowsIdentity]::GetCurrent().Name;$record.CallerAdministrator=$isAdmin
    $fullNamePattern='^'+[regex]::Escape($identity.Name)+'_'+[regex]::Escape($identity.Version)+'_'+[regex]::Escape($identity.ProcessorArchitecture)+'_'+[regex]::Escape([string]$identity.ResourceId)+'_[a-z0-9]{13}$'
    $null=[Windows.Management.Deployment.PackageManager,Windows.Management.Deployment,ContentType=WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $manager=New-Object Windows.Management.Deployment.PackageManager
    if($Mode -eq 'Stage'){
        if(-not $isAdmin){throw 'Machine-level signed package staging requires the guest management administrator.'}
        if((Get-FileHash -LiteralPath $appx -Algorithm SHA256 -ErrorAction Stop).Hash -ne $payload.Package.ManifestSHA256){throw 'The Appx manifest changed after preservation.'}
        $record.PackageManifestUnmodified=$true
        . 'C:\ProfileAnalysis\Private\WindowsGuestDeploymentProfile.ps1'
        $deploymentProfile=Enter-AnalysisWindowsDeploymentProfile -ExpectedUserSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $record.DeploymentProfile=$deploymentProfile.Proof|ConvertTo-Json -Depth 5|ConvertFrom-Json
        if(@(Get-AppxPackage -AllUsers -Name $identity.Name).Count){throw 'The clean baseline already contains this package; refusing replacement.'}
        $record.DeclaredServices=$payload.Package.Services
        foreach($service in $payload.Package.Services){
            if($service.Name -notmatch '^[A-Za-z0-9_.-]{1,256}$'){throw 'A declared service name is outside the supported schema.'}
            if(Get-Service -Name $service.Name -ErrorAction SilentlyContinue){throw 'A declared package service already exists in the clean baseline.'}
        }
        if($PackageArchiveSHA256){
            Save-DeploymentStep 'ProvisionOriginalSignedPackageAndOfflineLicense'
            $record.OfflineLicense=Invoke-DeploymentLicensedPackage -ArchiveSHA256 $PackageArchiveSHA256 -LicenseSHA256 $PackageLicenseSHA256
        }else{
            Save-DeploymentStep 'StageOriginalSignedLayout'
            Wait-DeploymentOperation ($manager.StagePackageAsync([uri]($root+'\'),$null,[Windows.Management.Deployment.DeploymentOptions]::StageInPlace))
        }
        $staged=Select-DeploymentStagedPackage -Candidates @(Get-AppxPackage -AllUsers -Name $identity.Name) -Identity $identity
        $ExpectedPackageFullName=$staged.PackageFullName
        $record.StagedPackageFullName=$ExpectedPackageFullName
        $record.StagedPackageFamilyName=$staged.PackageFamilyName
        $record.StagedPackageUsers=@($staged.PackageUserInformation|Select-Object UserSecurityId,InstallState)
        if($PackageArchiveSHA256){
            $provisioned=@(Get-AppxProvisionedPackage -Online -ErrorAction Stop|Where-Object {$_.PackageName -ceq $ExpectedPackageFullName})
            if($provisioned.Count -ne 1){throw 'The exact licensed package identity was not provisioned in the guest.'}
            $record.OfflineLicense|Add-Member NoteProperty PackageFullName $ExpectedPackageFullName
            $record.OfflineLicense.Status='Completed'
        }
        Save-DeploymentStep 'RegisterManagementAccountAndMachineExtensions'
        # Signed deployment only. Do not edit manifests, trust a new certificate,
        # enable development mode, re-sign content or bypass Store licensing.
        # Register the staged identity, not the source manifest path. StageInPlace
        # creates a Windows-managed package root distinct from that source path.
        Wait-DeploymentOperation ($manager.RegisterPackageByFullNameAsync($ExpectedPackageFullName,[string[]]@(),[Windows.Management.Deployment.DeploymentOptions]::None))
        $registered=@(Get-AppxPackage -Name $identity.Name|Where-Object {$_.Version.ToString() -eq $identity.Version -and $_.Publisher -eq $identity.Publisher})
        if($registered.Count -ne 1 -or $registered[0].PackageFullName -cne $ExpectedPackageFullName){throw 'The management account did not register the exact staged identity.'}
        $record.PackageFullName=$registered[0].PackageFullName;$record.PackageFamilyName=$registered[0].PackageFamilyName
        Save-DeploymentStep 'ProvisionVerifiedPackageForAnalysisUser'
        Wait-DeploymentOperation ($manager.ProvisionPackageForAllUsersAsync($registered[0].PackageFamilyName))
        $declaredNames=@($payload.Package.Services|ForEach-Object {$_.Name})
        $record.Services=@(Get-CimInstance Win32_Service|Where-Object {$_.Name -in $declaredNames}|Select-Object Name,StartName,State,StartMode,PathName,ProcessId)
        try{$record.DeploymentPathPermissions=@(Get-DeploymentPathPermission -Root $root)}catch{Set-DeploymentDiagnosticText 'DeploymentPermissionsError' $_.Exception.GetBaseException().Message}
    }else{
        if($isAdmin){throw 'Application registration and activation require the standard analysis user.'}
        if(-not $ExpectedPackageFullName -or $ExpectedPackageFullName -notmatch $fullNamePattern){throw 'Standard-user registration requires the exact staged package identity.'}
        Save-DeploymentStep 'RegisterStandardAnalysisUser'
        Wait-DeploymentOperation ($manager.RegisterPackageByFullNameAsync($ExpectedPackageFullName,[string[]]@(),[Windows.Management.Deployment.DeploymentOptions]::None))
        $registered=@(Get-AppxPackage -Name $identity.Name|Where-Object {$_.Version.ToString() -eq $identity.Version -and $_.Publisher -eq $identity.Publisher})
        if($registered.Count -ne 1 -or $registered[0].PackageFullName -cne $ExpectedPackageFullName){throw 'The standard user did not register the exact staged identity.'}
        $record.PackageFullName=$registered[0].PackageFullName;$record.PackageFamilyName=$registered[0].PackageFamilyName
        $record.ManifestValidation='Application declarations come from the hashed preservation manifest and the previously verified signed machine deployment.'
        $applications=@($payload.Package.Applications|Where-Object {$_.Executable.Replace('\','/') -ieq $payload.EntryPoint})
        if($applications.Count -ne 1 -or $applications[0].Id -notmatch '^[A-Za-z][A-Za-z0-9.]{0,63}$'){throw 'The selected executable does not have one unambiguous Appx application declaration.'}
        $record.ApplicationId=$applications[0].Id;$record.Aumid=$record.PackageFamilyName+'!'+$record.ApplicationId
        $record.InstallLocation=$registered[0].InstallLocation
        $record.RegisteredUserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $record.Status='Completed'
}catch{
    $cause=$_.Exception.GetBaseException();$record.Error=$cause.Message;$record.HResult=$cause.HResult
    if($cause.Data.Contains('Operation') -and $cause.Data['Operation'] -is [string] -and $cause.Data['Operation'] -ceq 'Add-AppxProvisionedPackage'){$record.Operation='Add-AppxProvisionedPackage'}
    # Acquisition may fail before assigning the lease. Preserve only the known
    # bounded cleanup fields carried by the helper, not arbitrary exception Data.
    if($cause.Data.Contains('DeploymentProfileProof')){
        $record.DeploymentProfileAcquisitionFailed=$true
        $record.DeploymentProfile=$cause.Data['DeploymentProfileProof']|ConvertTo-Json -Depth 5|ConvertFrom-Json
    }
    foreach($field in 'DeploymentProfileCleanupError','PrivilegeRestorationErrors'){
        if($cause.Data.Contains($field)){Set-DeploymentDiagnosticText $field ([string]$cause.Data[$field])}
    }
    try{
        $record['DeploymentEventsScope']='AppX deployment events since this operation began; ActivityId matched when available.'
        $events=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-AppXDeploymentServer/Operational';StartTime=([DateTime]::Parse($record.StartedUtc)).AddSeconds(-2)} -MaxEvents 64 -ErrorAction Stop)
        if($record.DeploymentActivityId -and $record.DeploymentActivityId -ne [Guid]::Empty.ToString()){
            $events=@($events|Where-Object {$_.ActivityId -and $_.ActivityId.ToString() -eq $record.DeploymentActivityId})
        }
        $record['DeploymentEvents']=@($events|ForEach-Object {
            $message=[string]$_.Message
            [ordered]@{Id=$_.Id;Utc=$_.TimeCreated.ToUniversalTime().ToString('o');ActivityId=[string]$_.ActivityId;Level=$_.LevelDisplayName;Message=$message.Substring(0,[Math]::Min(4096,$message.Length))}
        })
    }catch{Set-DeploymentDiagnosticText 'DeploymentEventsError' $_.Exception.GetBaseException().Message}
    try{
        $record['DeploymentPathPermissions']=@(Get-DeploymentPathPermission -Root $root)
    }catch{Set-DeploymentDiagnosticText 'DeploymentPermissionsError' $_.Exception.GetBaseException().Message}
    throw $cause
}
finally{
    try{
        if($deploymentProfile){$record.DeploymentProfileCleanup=Exit-AnalysisWindowsDeploymentProfile -Lease $deploymentProfile}
    }catch{
        $profileCleanupCause=$_.Exception.GetBaseException()
        Set-DeploymentDiagnosticText 'DeploymentProfileCleanupError' $profileCleanupCause.Message
        $record.DeploymentProfileCleanupHResult=$profileCleanupCause.HResult
        $record.Status='Failed'
        if(-not $record.Error){$record.Error=$profileCleanupCause.Message;$record.HResult=$profileCleanupCause.HResult;throw}
    }finally{$record.FinishedUtc=[DateTime]::UtcNow.ToString('o');$record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding utf8}
}
[pscustomobject]$record
