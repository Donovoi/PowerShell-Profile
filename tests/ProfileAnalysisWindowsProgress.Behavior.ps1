# Compile and exercise progress-file helpers only; never run the guest asset or target APIs.
#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$runner=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestRunner.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) 'Guest runner parse failed.'
$checkpoint=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-GuestCheckpoint'},$true))
Assert-True ($checkpoint.Count -eq 1) 'Exact checkpoint helper was not found.'
. ([scriptblock]::Create($checkpoint[0].Extent.Text))
$native=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class ProfileAnalysisGuestJob')},$true))
Assert-True ($native.Count -eq 1) 'Exact native guest source was not found.'
$nativeSource=$native[0].Value
$start=$nativeSource.IndexOf(' public enum ActivationProgressStage ')
$end=$nativeSource.IndexOf(' static void WriteActivationCheckpoint(',$start)
Assert-True ($start -ge 0 -and $end -gt $start) 'Pure native checkpoint boundary changed.'
$pureSource='using System;using System.IO;using System.Text;public static class ProfileAnalysisProgressFixture {'+$nativeSource.Substring($start,$end-$start)+'}'
Add-Type -TypeDefinition $pureSource -Language CSharp

$output=Join-Path $TestRoot 'powershell';$null=[IO.Directory]::CreateDirectory($output)
$record=[ordered]@{Status='Failed';StartedUtc=[DateTime]::UtcNow.ToString('o');RunnerSHA256=('A'*64);Error='primary target failure';ErrorDetails=@{HResult=-2147023665;Operation='Check activated process administrator membership';ExceptionType='System.Security.SecurityException'};ErrorContext=@{ScriptLineNumber=123};Execution=$null}
# Exercise the exact default call used by the guest, including case-insensitive parameter scopes.
Write-GuestCheckpoint -Phase Started
$progressPath=Join-Path $output 'runtime-progress.json'
Assert-True (Test-Path -LiteralPath $progressPath) 'Default record/output binding did not write progress.'
$progress=Get-Content -LiteralPath $progressPath -Raw|ConvertFrom-Json
Assert-True ($progress.Status -ceq 'InProgress' -and $progress.DiagnosticOnly -and $progress.Phase -ceq 'Started' -and $progress.RunnerSHA256 -ceq ('A'*64)) 'Initial progress schema/identity differs.'
Assert-True ($record.Status -ceq 'Failed' -and $record.Error -ceq 'primary target failure' -and $progress.ErrorHResult -eq -2147023665) 'Checkpoint changed or obscured the primary failure.'
Assert-True ($progress.ErrorOperation -ceq $record.ErrorDetails.Operation -and $progress.ErrorExceptionType -ceq $record.ErrorDetails.ExceptionType) 'Checkpoint lost the native inspection failure stage.'
$firstUtc=([DateTime]$progress.UpdatedUtc).ToUniversalTime()
Assert-True ([Math]::Abs(([DateTime]::UtcNow-$firstUtc).TotalSeconds) -lt 30) 'Checkpoint UTC time is invalid.'
$record.Execution=@{RootProcessId=456;ExitCode=259;Reason=([string][char]1)*2000;DurationMilliseconds=42;JobAssigned=$false;JobClosed=$false;Processes=@(@{Name='DO_NOT_INCLUDE_PROCESS_SECRET'});Windows=@(@{Title='DO_NOT_INCLUDE_WINDOW_SECRET'});ActivationProgressWriteFailures=2}
$record.FileInventoryBefore=@{Status='Partial';Complete=$false;ErrorCount=4;Truncated=$true;ErrorsTruncated=$true}
$record.FileInventoryAfter=@{Status='Completed';Complete=$true;ErrorCount=0;Truncated=$false}
$record.RegistryInventoryBefore=@{Status='Completed';Complete=$true;ErrorCount=0;Truncated=$false}
$record.RegistryInventoryAfter=@{Status='Failed';Complete=$false;ErrorCount=1;Truncated=$false}
$record.Error=([string][char]2)*10000
$record.ErrorDetails.Operation=([string][char]3)*10000;$record.ErrorDetails.ExceptionType=([string][char]4)*10000
foreach($iteration in 1..40){Write-GuestCheckpoint -Phase BeforeCompile -Record $record -OutputDirectory $output}
$progress=Get-Content -LiteralPath $progressPath -Raw|ConvertFrom-Json
Assert-True ($progress.Phases.Count -eq 32 -and $progress.CheckpointDiagnostics.HistoryTruncated -and $progress.Error.Length -eq 1024 -and $progress.Execution.Reason.Length -eq 128) 'Bounded history or diagnostic text was lost.'
Assert-True ($progress.ErrorOperation.Length -eq 128 -and $progress.ErrorExceptionType.Length -eq 128) 'Failure-stage checkpoint text was not bounded.'
Assert-True ((Get-Item -LiteralPath $progressPath).Length -le 16384 -and $progress.Execution.RootProcessId -eq 456 -and $progress.Execution.ActivationProgressWriteFailures -eq 2) 'Execution summary or progress byte cap differs.'
Assert-True ($progress.Inventories.FileInventoryBefore.ErrorCount -eq 4 -and $progress.Inventories.RegistryInventoryAfter.Status -ceq 'Failed') 'Inventory coverage/error summaries were lost.'
Assert-True ((Get-Content -LiteralPath $progressPath -Raw) -notmatch 'DO_NOT_INCLUDE') 'Progress serialized arbitrary execution data.'
Assert-True ($record.Status -ceq 'Failed' -and $progress.Status -ceq 'InProgress') 'In-progress observation was reported as success.'

$primaryError=$record.Error;$priorBytes=[IO.File]::ReadAllBytes($progressPath)
$held=[IO.File]::Open($progressPath,'Open','Read','None')
try{Write-GuestCheckpoint -Phase BeforePostFileInventory -Record $record -OutputDirectory $output}finally{$held.Dispose()}
Assert-True ($record.CheckpointDiagnostics.LastWriteFailed -and $record.CheckpointDiagnostics.WriteFailures -eq 1 -and $record.Error -ceq $primaryError -and $record.Status -ceq 'Failed') 'Checkpoint IO error masked the primary failure.'
Assert-True ([Convert]::ToBase64String($priorBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($progressPath))) 'Failed atomic replacement damaged prior progress.'
Assert-True (@(Get-ChildItem -LiteralPath $output -Filter '*.tmp').Count -eq 0) 'Failed checkpoint left its temporary file.'
Write-GuestCheckpoint -Phase BeforePostNetworkInventory -Record $record -OutputDirectory $output
$progress=Get-Content -LiteralPath $progressPath -Raw|ConvertFrom-Json
Assert-True (-not $progress.CheckpointDiagnostics.LastWriteFailed -and $progress.CheckpointDiagnostics.WriteFailures -eq 1 -and $progress.CheckpointDiagnostics.LastFailureUtc) 'Successful retry erased prior diagnostic failure evidence.'
Write-GuestCheckpoint -Phase FinalSavedReport -Record $record -OutputDirectory $output -Finished
$progress=Get-Content -LiteralPath $progressPath -Raw|ConvertFrom-Json
Assert-True ($progress.Status -ceq 'Finished' -and $progress.Status -cne 'Completed' -and $progress.DiagnosticOnly -and $record.Status -ceq 'Failed') 'Finished diagnostic record claimed successful analysis.'
$record.CheckpointDiagnostics.WriteFailures=[int]::MaxValue
Write-GuestCheckpoint -Phase UnexpectedUntrustedPhase -Record $record -OutputDirectory $output
Assert-True ($record.CheckpointDiagnostics.WriteFailures -eq [int]::MaxValue -and $record.CheckpointDiagnostics.LastWriteFailed) 'Failure counter overflowed or invalid phase escaped the helper.'
Write-Output 'PASS: PS checkpoints retain identity/timing, bounded history/text/execution/inventory summaries and primary errors; IO is atomic and best effort.'

$nativeOutput=Join-Path $TestRoot 'native-CREDENTIAL_MARKER';$null=[IO.Directory]::CreateDirectory($nativeOutput)
$nativePath=Join-Path $nativeOutput 'activation-progress.json'
foreach($stageName in 'BeforeActivation','ActivationReturned','IdentityVerified','ObservationCompleted'){
    $stage=[Enum]::Parse([ProfileAnalysisProgressFixture+ActivationProgressStage],$stageName)
    $hasIdentity=$stageName -in 'IdentityVerified','ObservationCompleted'
    $errorCode=if($stageName -eq 'ActivationReturned'){-2147023665}else{$null}
    Assert-True ([ProfileAnalysisProgressFixture]::TryWriteActivationProgress($nativeOutput,$stage,$errorCode,456,$true,$hasIdentity,250,3)) 'Native pure progress write failed.'
    $progress=Get-Content -LiteralPath $nativePath -Raw|ConvertFrom-Json
    Assert-True ($progress.Schema -ceq 'PowerShellProfile.WindowsActivationProgress.v1' -and $progress.DiagnosticOnly -and $progress.Phase -ceq $stageName -and $progress.RootProcessId -eq 456 -and $progress.IdentityVerified -eq $hasIdentity -and $progress.ActivationManagerCreated -and $progress.PreviousWriteFailures -eq 3 -and $progress.ElapsedMilliseconds -eq 250) 'Native checkpoint fields differ.'
    Assert-True ((Get-Item -LiteralPath $nativePath).Length -lt 8192 -and (Get-Content -LiteralPath $nativePath -Raw) -notmatch 'CREDENTIAL_MARKER') 'Native checkpoint exceeded its cap or included arbitrary paths.'
    Assert-True ([Math]::Abs(([DateTime]::UtcNow-([DateTime]$progress.UpdatedUtc).ToUniversalTime()).TotalSeconds) -lt 30) 'Native timestamp is invalid.'
    if($stageName -eq 'ActivationReturned'){Assert-True ($progress.HResult -eq -2147023665 -and $progress.Status -ceq 'InProgress') 'Native activation HRESULT or status was lost.'}
    if($stageName -eq 'ObservationCompleted'){Assert-True ($progress.Status -ceq 'Finished' -and $progress.Status -cne 'Completed') 'Native observation completion claimed application success.'}
}
$priorNative=[IO.File]::ReadAllBytes($nativePath);$held=[IO.File]::Open($nativePath,'Open','Read','None')
try{Assert-True (-not [ProfileAnalysisProgressFixture]::TryWriteActivationProgress($nativeOutput,[ProfileAnalysisProgressFixture+ActivationProgressStage]::BeforeActivation,$null,0,$false,$false,0,0)) 'Locked native progress replacement incorrectly succeeded.'}finally{$held.Dispose()}
Assert-True ([Convert]::ToBase64String($priorNative) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($nativePath))) 'Native IO failure damaged prior progress.'
Assert-True (@(Get-ChildItem -LiteralPath $nativeOutput -Filter '*.tmp').Count -eq 0) 'Native failure left a temporary file.'
Assert-True (-not [ProfileAnalysisProgressFixture]::TryWriteActivationProgress((Join-Path $TestRoot 'absent'),[ProfileAnalysisProgressFixture+ActivationProgressStage]::BeforeActivation,$null,0,$false,$false,0,0)) 'Missing native directory threw or succeeded.'
$undefinedStage=[Enum]::ToObject([ProfileAnalysisProgressFixture+ActivationProgressStage],999)
Assert-True (-not [ProfileAnalysisProgressFixture]::TryWriteActivationProgress($nativeOutput,$undefinedStage,$null,0,$false,$false,0,0)) 'Native helper accepted an undefined phase.'
Write-Output 'PASS: native pure checkpoint writer retains HRESULT/PID/identity/timing, uses fixed fields, and safely handles IO failures without invoking target APIs.'

# Verify exact call sites without executing the guest script.
$runnerText=[IO.File]::ReadAllText($runner)
foreach($phase in 'BeforeCompile','BeforeFileInventory','BeforeRegistryInventory','BeforeRegisterPackage','BeforeVerifyTarget','ActivateAndObservePackage','AfterRunRegistered','BeforePostFileInventory','BeforePostRegistryInventory','BeforePostNetworkInventory','FinalSavedReport'){
    Assert-True ($runnerText.Contains('Write-GuestCheckpoint -Phase '+$phase)) ('Missing runner boundary: '+$phase)
}
Assert-True ($nativeSource.IndexOf('ActivationProgressStage.BeforeActivation,null,false,false,timer') -lt $nativeSource.IndexOf('instance=Activator.CreateInstance')) 'Native pre-COM checkpoint moved after COM creation.'
Assert-True ($nativeSource.Contains('ActivationProgressStage.ActivationReturned,activationFailure.HResult') -and $nativeSource.Contains('ActivationProgressStage.ActivationReturned,error')) 'Native activation return/error checkpoint coverage is incomplete.'
$fullCompiled=$false
if($PSVersionTable.PSVersion.Major -eq 5){Add-Type -TypeDefinition $nativeSource -Language CSharp -ReferencedAssemblies System.Drawing,System.Core;$fullCompiled=$true}
[pscustomobject]@{Status='Passed';PowerShell=$PSVersionTable.PSVersion.ToString();FullNativeSourceCompiled=$fullCompiled;NativeTargetApisInvoked=$false;CheckpointFixturesOnly=$true}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $TestRoot 'result.json') -Encoding utf8
Write-Output 'PASS: exact runner boundary coverage; Windows PowerShell 5.1 also compiles the entire native runner without calling it.'
