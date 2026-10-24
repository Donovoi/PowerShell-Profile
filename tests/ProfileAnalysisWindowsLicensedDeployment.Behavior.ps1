#requires -Version 5.1
# Native deployment and filesystem readers below are fixtures; no host package is changed.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
# Load JSON commands before installing reader fixtures. On Windows PowerShell,
# first-use module loading would otherwise replace the Get-FileHash fixture.
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$asset=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestPackage.ps1'
$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($asset,[ref]$null,[ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'The deployment helper does not parse.'
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DeploymentLicensedPackage'},$true)
Assert-True ($null -ne $definition) 'The licensed deployment boundary is missing.'
. ([scriptblock]::Create($definition.Extent.Text))
$script:archiveHash='A'*64;$script:licenseHash='B'*64
$script:nativeCalls=0;$script:mode='Valid'
function Get-Item {
    [CmdletBinding()]
    param([string]$LiteralPath,[switch]$Force)
    Assert-True ($LiteralPath -cin @('C:\ProfileAnalysis\Private\package.msix','C:\ProfileAnalysis\Private\package-license.xml') -and $Force) 'Deployment read an arbitrary input path.'
    [pscustomobject]@{PSIsContainer=($script:mode -eq 'Directory');Attributes=if($script:mode -eq 'Reparse'){[IO.FileAttributes]::ReparsePoint}else{[IO.FileAttributes]::Normal};Length=if($script:mode -eq 'Empty'){0}elseif($script:mode -eq 'OversizedLicense' -and $LiteralPath.EndsWith('.xml')){1MB+1}elseif($script:mode -eq 'OversizedArchive' -and $LiteralPath.EndsWith('.msix')){64GB+1}else{100}}
}
function Get-FileHash {
    [CmdletBinding()]
    param([string]$LiteralPath,[string]$Algorithm)
    Assert-True ($Algorithm -ceq 'SHA256') 'Deployment changed its hash algorithm.'
    $hash=if($LiteralPath.EndsWith('.msix')){$script:archiveHash}else{$script:licenseHash}
    if($script:mode -eq 'ChangedArchive' -and $LiteralPath.EndsWith('.msix')){$hash='C'*64}
    if($script:mode -eq 'ChangedLicense' -and $LiteralPath.EndsWith('.xml')){$hash='D'*64}
    [pscustomobject]@{Hash=$hash}
}
function Add-AppxProvisionedPackage {
    [CmdletBinding()]
    param([switch]$Online,[string]$PackagePath,[string[]]$LicensePath,[string]$Regions,[switch]$SkipLicense)
    $script:nativeCalls++
    Assert-True ($Online -and $PackagePath -ceq 'C:\ProfileAnalysis\Private\package.msix' -and $LicensePath.Count -eq 1 -and $LicensePath[0] -ceq 'C:\ProfileAnalysis\Private\package-license.xml' -and $Regions -ceq 'all' -and -not $SkipLicense) 'The native call did not use the exact original package and supplied license.'
    if($script:mode -eq 'NativeFailure'){throw [Runtime.InteropServices.COMException]::new('Known license rejection.',-2147024891)}
    if($script:mode -eq 'NoResult'){return}
    $result=[pscustomobject]@{Online=($script:mode -ne 'OfflineImage');RestartNeeded=($script:mode -eq 'Restart')}
    if($script:mode -eq 'StringBoolean'){$result.RestartNeeded='false'}
    $result
    if($script:mode -eq 'DuplicateResult'){$result}
}
$result=Invoke-DeploymentLicensedPackage -ArchiveSHA256 $script:archiveHash -LicenseSHA256 $script:licenseHash
Assert-True ($result.Status -ceq 'Provisioned' -and $result.ArchiveSHA256 -ceq $script:archiveHash -and $result.LicenseSHA256 -ceq $script:licenseHash -and $result.RestartNeeded -is [bool] -and -not $result.RestartNeeded -and $script:nativeCalls -eq 1) 'Successful native deployment lost its exact input evidence.'
foreach($case in @('Directory','Reparse','Empty','OversizedLicense','OversizedArchive','ChangedArchive','ChangedLicense','NativeFailure','NoResult','OfflineImage','Restart','StringBoolean','DuplicateResult')){
    $script:mode=$case;$script:nativeCalls=0;$failure=$null
    try{Invoke-DeploymentLicensedPackage -ArchiveSHA256 $script:archiveHash -LicenseSHA256 $script:licenseHash}catch{$failure=$_.Exception.GetBaseException()}
    Assert-True ($null -ne $failure) ('Invalid deployment evidence was accepted: '+$case)
    $expectedCalls=if($case -in @('Directory','Reparse','Empty','OversizedLicense','OversizedArchive','ChangedArchive','ChangedLicense')){0}else{1}
    Assert-True ($script:nativeCalls -eq $expectedCalls) ('Invalid input reached native deployment: '+$case)
    if($case -eq 'NativeFailure'){Assert-True ($failure.HResult -eq -2147024891 -and $failure.Data['Operation'] -ceq 'Add-AppxProvisionedPackage') 'The native license error or operation was lost.'}
}
$script:mode='Valid';$script:nativeCalls=0;$failure=$null
try{Invoke-DeploymentLicensedPackage -ArchiveSHA256 $script:archiveHash -LicenseSHA256 $script:licenseHash -WhatIf}catch{$failure=$_}
Assert-True ($null -ne $failure -and $script:nativeCalls -eq 0) 'WhatIf performed native deployment or claimed success.'
& {
    foreach($name in 'Set-DeploymentDiagnosticText','Get-DeploymentPathPermission'){
        $helper=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        Assert-True ($null -ne $helper) ('Required diagnostic helper absent: '+$name)
        . ([scriptblock]::Create($helper.Extent.Text))
    }
    $entry=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Finally})
    Assert-True ($entry.Count -eq 1 -and $entry[0].CatchClauses.Count -eq 1) 'The package outer catch/finally shape changed.'
    # Keep the actual catch/finally lexical boundaries and final serialization.
    # Only the failing body and external diagnostic/cleanup readers are fixtures.
    $failureBoundary=[scriptblock]::Create('try { throw $primary } '+$entry[0].CatchClauses[0].Extent.Text+' finally '+$entry[0].Finally.Extent.Text)
    function Get-WinEvent {
        [CmdletBinding()]
        param([hashtable]$FilterHashtable,[int]$MaxEvents)
        $state.EventReads++
        Assert-True ($FilterHashtable.LogName -ceq 'Microsoft-Windows-AppXDeploymentServer/Operational' -and $MaxEvents -eq 64) 'Outer diagnostics changed their exact event boundary.'
        if($state.Case -eq 'known-reader-failure'){throw [InvalidOperationException]::new('Known secondary event-reader failure.')}
    }
    function Get-Acl {
        [CmdletBinding()]
        param([string]$LiteralPath)
        $state.AclReads++
        Assert-True ($LiteralPath -cin @('C:\ProfileAnalysis\Work\Application','C:\ProfileAnalysis\Work','C:\ProfileAnalysis')) 'Outer diagnostics inspected unrelated permissions.'
        if($state.Case -eq 'known-reader-failure'){throw [InvalidOperationException]::new('Known secondary permissions-reader failure.')}
        [pscustomobject]@{Owner='Fixture owner';Sddl='Fixture permissions'}
    }
    function Exit-AnalysisWindowsDeploymentProfile {
        param($Lease)
        Assert-True ([object]::ReferenceEquals($Lease,$deploymentProfile)) 'Outer cleanup changed the owned profile lease.'
        $state.CleanupCalls++
        if($state.Case -eq 'known-cleanup-failure'){throw [Runtime.InteropServices.COMException]::new('Known secondary profile cleanup failure.',-2147024864)}
        [pscustomobject]@{Status='Released';Released=$true;PrivilegesRestored=$true}
    }
    function Set-Content {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline)][string]$Value,[string]$LiteralPath,[string]$Encoding)
        process{
            Assert-True ($LiteralPath -ceq 'C:\ProfileAnalysis\Private\package-deployment.json' -and $Encoding -ceq 'utf8') 'Outer failure report left its fixed private artifact.'
            $state.Serialized=$Value;$state.ReportWrites++
        }
    }
    foreach($case in 'known','known-reader-failure','known-cleanup-failure','missing','different','wrong-case','non-string'){
        $script:mode='NativeFailure';$primary=$null
        try{Invoke-DeploymentLicensedPackage -ArchiveSHA256 $script:archiveHash -LicenseSHA256 $script:licenseHash}catch{$primary=$_.Exception.GetBaseException()}
        Assert-True ($primary.HResult -eq -2147024891 -and $primary.Data['Operation'] -ceq 'Add-AppxProvisionedPackage') ('The fake native boundary failed to establish the original operation for '+$case+': '+$primary.Message)
        switch($case){
            'missing' {$primary.Data.Remove('Operation')}
            'different' {$primary.Data['Operation']='Unapproved.Other.Operation'}
            'wrong-case' {$primary.Data['Operation']='add-appxprovisionedpackage'}
            'non-string' {$primary.Data['Operation']=[pscustomobject]@{Value='Add-AppxProvisionedPackage';Secret='DO-NOT-SERIALIZE-ARBITRARY-DATA'}}
        }
        $primary.Data['UnrelatedSecret']='DO-NOT-SERIALIZE-ARBITRARY-DATA'
        $state=@{Case=$case;EventReads=0;AclReads=0;CleanupCalls=0;ReportWrites=0;Serialized=$null}
        $record=[ordered]@{Status='Failed';StartedUtc=[datetime]::UtcNow.ToString('o');Error=$null;HResult=$null}
        $root='C:\ProfileAnalysis\Work\Application';$reportPath='C:\ProfileAnalysis\Private\package-deployment.json';$deploymentProfile=[pscustomobject]@{FixtureOwnedLease=$true}
        $caught=$null
        try{& $failureBoundary}catch{$caught=$_.Exception.GetBaseException()}
        Assert-True ([object]::ReferenceEquals($caught,$primary) -and $state.EventReads -eq 1 -and $state.CleanupCalls -eq 1 -and $state.ReportWrites -eq 1) 'Outer diagnostics or cleanup replaced the native cause or skipped final evidence.'
        $persisted=$state.Serialized|ConvertFrom-Json
        Assert-True ($persisted.Status -ceq 'Failed' -and $persisted.Error -ceq $primary.Message -and $persisted.HResult -eq $primary.HResult -and [bool]$persisted.FinishedUtc) 'Serialized package failure lost the original native error or completion evidence.'
        if($case -like 'known*'){Assert-True ($persisted.Operation -is [string] -and $persisted.Operation -ceq 'Add-AppxProvisionedPackage') 'The known native deployment operation was discarded by the outer handler.'}
        else{Assert-True (-not $persisted.PSObject.Properties['Operation']) 'An absent, arbitrary, differently cased or non-string operation was serialized.'}
        Assert-True (-not $state.Serialized.Contains('DO-NOT-SERIALIZE-ARBITRARY-DATA') -and -not $state.Serialized.Contains('UnrelatedSecret') -and -not $state.Serialized.Contains('Unapproved.Other.Operation')) 'The outer handler serialized arbitrary exception Data.'
        if($case -eq 'known-cleanup-failure'){Assert-True ($persisted.DeploymentProfileCleanupHResult -eq -2147024864 -and $persisted.DeploymentProfileCleanupError -ceq 'Known secondary profile cleanup failure.') 'Secondary cleanup evidence was not separate from the native deployment cause.'}
        else{Assert-True ($persisted.DeploymentProfileCleanup.Status -ceq 'Released' -and $persisted.DeploymentProfileCleanup.Released) 'Owned profile cleanup proof was lost.'}
        if($case -eq 'known-reader-failure'){Assert-True ($persisted.DeploymentEventsError -ceq 'Known secondary event-reader failure.' -and $persisted.DeploymentPermissionsError -ceq 'Known secondary permissions-reader failure.') 'Secondary diagnostic-reader evidence was lost.'}
        if($case -eq 'known'){[IO.File]::WriteAllText((Join-Path $TestRoot 'licensed-native-failure-report.json'),$state.Serialized,[Text.UTF8Encoding]::new($false))}
    }
    Write-Output 'PASS: the real package outer catch/finally serializes only the exact known native DISM operation, retains the original HRESULT, excludes arbitrary Data and preserves separate cleanup/reader failures.'
}
Write-Output 'PASS: licensed deployment uses exact private inputs and native license validation; changed/oversized/reparse inputs fail before deployment, native errors survive, and missing/ambiguous/restart-required results never claim success. No host deployment occurred.'
