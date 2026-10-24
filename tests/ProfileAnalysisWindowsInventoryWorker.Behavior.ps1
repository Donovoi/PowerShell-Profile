#requires -Version 5.1
# Native-blocking fixtures run only in child PowerShell processes created here.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Management,Microsoft.PowerShell.Utility -ErrorAction Stop
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$TestRoot=(Get-Item -LiteralPath $TestRoot).FullName
function Assert-Worker([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$asset=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestRunner.ps1'
$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($asset,[ref]$null,[ref]$errors)
Assert-Worker ($errors.Count -eq 0) 'The trusted runner does not parse.'
foreach($name in 'Invoke-GuestInventoryWorker','Get-GuestInventoryWorkerState'){
    $definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
    Assert-Worker ($null -ne $definition) ('Missing trusted worker helper: '+$name)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$collectorBody=@'
param([Collections.Concurrent.ConcurrentQueue[object]]$RecordSink,[Collections.Concurrent.ConcurrentDictionary[string,object]]$ProgressState)
$kind='__KIND__';$behavior='__BEHAVIOR__'
$field=@{File='Files';Registry='Values';Network='Connections'}[$kind]
$envelopeKind=@{File='File';Registry='RegistryValue';Network='Connection'}[$kind]
$row=switch($kind){
 File {[pscustomobject]@{Path='C:\Fixture\retained.bin';Bytes=5;ModifiedUtc='2026-01-02T03:04:05Z';SHA256=('A'*64);HashError=$null}}
 Registry {[pscustomobject]@{Key='HKCU\Software\Fixture';Name='Retained';Kind='String';Value='known primitive value';Truncated=$false}}
 Network {[pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=12345;RemoteAddress='127.0.0.1';RemotePort=1;State='Closed';OwningProcess=1;Truncated=$false}}
}
$RecordSink.Enqueue([pscustomobject]@{Kind=$envelopeKind;Data=$row})
$ProgressState['Scope']='Fixture only';$ProgressState['RowsPublished']=1;$ProgressState['ErrorCount']=0
if($behavior -ne 'NoResult'){
 $ProgressState['CurrentOperation']='Operation-'+$kind+'-'+('O'*700)
 $ProgressState['CurrentPath']='C:\Fixture\'+('P'*1400)
}
$ProgressState['Visited']=1;$ProgressState['VisitedKeys']=1;$ProgressState['VisitedConnections']=1
# An optimistic racing state must never override a hard timeout.
$ProgressState['Status']='Completed';$ProgressState['Complete']=$true
if($behavior -eq 'Blocked'){[Threading.Thread]::Sleep(60000)}
if($behavior -eq 'Failed'){
 $failure=[InvalidOperationException]::new('Fixture collector failure.')
 $failure.Data['Private']='DO-NOT-SERIALIZE-PRIVATE-EXCEPTION-DATA'
 throw $failure
}
if($behavior -eq 'NoResult'){return}
$result=[ordered]@{Status=if($behavior -eq 'Partial'){'Partial'}else{'Completed'};Complete=($behavior -ne 'Partial');Truncated=($behavior -eq 'Partial');DataTruncated=$false;Scope='Fixture only';Errors=@();ErrorCount=0;ErrorsTruncated=$false;DurationMilliseconds=0}
$result[$field]=@($row)
[pscustomobject]$result
'@
$collectorFactory=@'
function Set-FixtureCollector {
    param([ValidateSet('File','Registry','Network')][string]$Kind,[ValidateSet('Completed','Partial','Blocked','Failed','NoResult')][string]$Behavior)
    $name=@{File='Get-GuestFileInventory';Registry='Get-GuestRegistryInventory';Network='Get-GuestNetworkInventory'}[$Kind]
    $body=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__COLLECTOR_BODY__'))
    $body=$body.Replace('__KIND__',$Kind).Replace('__BEHAVIOR__',$Behavior)
    Set-Item -Path ('Function:script:'+$name) -Value ([scriptblock]::Create($body))
}
'@
$collectorFactory=$collectorFactory.Replace('__COLLECTOR_BODY__',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($collectorBody)))
. ([scriptblock]::Create($collectorFactory))
foreach($kind in 'File','Registry','Network'){
    foreach($behavior in 'Completed','Partial'){
        Set-FixtureCollector -Kind $kind -Behavior $behavior
        $result=Invoke-GuestInventoryWorker -Kind $kind -TimeoutSeconds 10
        $field=@{File='Files';Registry='Values';Network='Connections'}[$kind]
        Assert-Worker ($result.Status -ceq $behavior -and $result.Complete -eq ($behavior -eq 'Completed') -and $result.$field.Count -eq 1 -and $result.Worker.Status -ceq 'Completed' -and -not $result.Worker.TimedOut -and -not $result.Worker.StopRequested -and -not $result.Worker.PendingAtReturn -and -not $result.Worker.RetainedUntilRunnerExit) 'A completed worker lost its result, duplicated queued rows or confused collector coverage with worker completion.'
        Assert-Worker ($result.Worker.LastOperation.Length -eq 512 -and $result.Worker.LastOperation.StartsWith('Operation-'+$kind+'-') -and $result.Worker.LastPath.Length -eq 1024 -and $result.Worker.LastPath.StartsWith('C:\Fixture\')) 'Completed worker operation/path diagnostics were lost or exceeded their fixed bounds.'
    }
}
$lifecycle=Get-GuestInventoryWorkerState
Assert-Worker ($lifecycle.TotalCount -eq 6 -and $lifecycle.PendingCount -eq 0 -and $lifecycle.RetainedCount -eq 0 -and $lifecycle.StopRequestedCount -eq 0) 'Completed workers were not disposed or lifecycle inspection changed their state.'
foreach($invalid in @(@{Kind='File';TimeoutSeconds=0},@{Kind='File';TimeoutSeconds=121},@{Kind='Other';TimeoutSeconds=1})){
    $failure=$null;try{Invoke-GuestInventoryWorker @invalid}catch{$failure=$_}
    Assert-Worker ($null -ne $failure -and (Get-GuestInventoryWorkerState).TotalCount -eq 6) 'Invalid worker limits or kinds reached a runspace.'
}
Write-Output 'PASS: actual in-process workers preserve completed/partial kind results, dispose completed workers and reject invalid limits without invoking target or platform collection APIs.'

$childTemplate=@'
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Management,Microsoft.PowerShell.Utility -ErrorAction Stop
$asset=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ASSET__'))
$root=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ROOT__'))
$mode='__MODE__'
$factory=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__FACTORY__'))
. ([scriptblock]::Create($factory))
$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($asset,[ref]$null,[ref]$errors)
if($errors){throw 'Child runner parse failed.'}
foreach($name in 'Invoke-GuestInventoryWorker','Get-GuestInventoryWorkerState'){
 $definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
 if($null -eq $definition){throw 'Child worker helper is missing.'}
 . ([scriptblock]::Create($definition.Extent.Text))
}
foreach($kind in 'File','Registry','Network'){Set-FixtureCollector -Kind $kind -Behavior Blocked}
$ownedProcess=$PID
$OwnedRunner=$mode -ne 'Unowned'
if($mode -eq 'HelperOnly'){
 $elapsed=[Diagnostics.Stopwatch]::StartNew()
 $result=Invoke-GuestInventoryWorker -Kind File -TimeoutSeconds 1
 Set-FixtureCollector -Kind Registry -Behavior Failed
 $failed=Invoke-GuestInventoryWorker -Kind Registry -TimeoutSeconds 10
 Set-FixtureCollector -Kind Network -Behavior NoResult
 $empty=Invoke-GuestInventoryWorker -Kind Network -TimeoutSeconds 10
 $stateBefore=Get-GuestInventoryWorkerState;$stateAfter=Get-GuestInventoryWorkerState
 @{PID=$PID;Result=$result;Failed=$failed;Empty=$empty;Lifecycle=$stateAfter;StopCountBefore=$stateBefore.StopRequestedCount;Returned=$true;ElapsedMilliseconds=$elapsed.ElapsedMilliseconds}|ConvertTo-Json -Depth 10 -Compress|Set-Content -LiteralPath (Join-Path $root 'helper-returned.json') -Encoding utf8
 [Environment]::Exit(0)
}
# Narrow only the test deadline; execute the actual wrapper and finalization.
Set-Item -Path Function:Invoke-FixtureActualInventoryWorker -Value ${function:Invoke-GuestInventoryWorker}
function Invoke-GuestInventoryWorker {
 param([string]$Kind,[int]$TimeoutSeconds)
 $expected=if($Kind -eq 'File'){120}else{30}
 if($TimeoutSeconds -ne $expected){throw 'Production collector allowance changed.'}
 Invoke-FixtureActualInventoryWorker -Kind $Kind -TimeoutSeconds 1
}
function Write-GuestCheckpoint {
 param([string]$Phase,[switch]$Finished)
 @{Phase=$Phase;Finished=[bool]$Finished;PID=$PID}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $root 'checkpoint.json') -Encoding utf8
}
$output=Join-Path $root 'output';$null=[IO.Directory]::CreateDirectory($output)
$target=Join-Path $root 'known.bin';[IO.File]::WriteAllBytes($target,[Text.Encoding]::ASCII.GetBytes('hello'))
$ExpectedSHA256='2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824'
$record=[ordered]@{Status='Failed';Error='Fixture primary access denied.';ErrorDetails=@{HResult=-2147024891;NativeErrorCode=5;Operation='InspectRegisteredProcess'};FileInventoryBefore=@{Status='Completed';Complete=$true};RegistryInventoryBefore=@{Status='Completed';Complete=$true};NetworkInventoryBefore=@{Status='Completed';Complete=$true};Limitations=@();FixtureOwnerPID=$ownedProcess}
if($mode -eq 'ReportFailure'){$null=[IO.Directory]::CreateDirectory((Join-Path $output 'runtime.json'))}
$outer=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Finally})
if($outer.Count -ne 1){throw 'Child finalization boundary changed.'}
$finallyText=$outer[0].Finally.Extent.Text
$body=[scriptblock]::Create($finallyText.Substring(1,$finallyText.Length-2))
. $body
@{PID=$PID;Returned=$true;Lifecycle=(Get-GuestInventoryWorkerState)}|ConvertTo-Json -Depth 5 -Compress|Set-Content -LiteralPath (Join-Path $root 'after-finalization.json') -Encoding utf8
# Only this test-created child exits here; Unowned production code must return.
[Environment]::Exit(0)
'@
$currentExecutable=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
foreach($mode in 'HelperOnly','Owned','Unowned','ReportFailure'){
    $childRoot=Join-Path $TestRoot ('child-'+$mode);$null=[IO.Directory]::CreateDirectory($childRoot)
    $childSource=$childTemplate.Replace('__ASSET__',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($asset))).Replace('__ROOT__',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($childRoot))).Replace('__MODE__',$mode).Replace('__FACTORY__',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($collectorFactory)))
    $childPath=Join-Path $childRoot 'fixture.ps1';[IO.File]::WriteAllText($childPath,$childSource,[Text.UTF8Encoding]::new($false))
    $invocation="& '"+$childPath.Replace("'","''")+"'"
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$currentExecutable;$start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation));$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $elapsed=[Diagnostics.Stopwatch]::StartNew();$killed=$false;$started=$false
    try{
        $started=$process.Start();Assert-Worker $started 'The isolated worker child did not start.'
        $ownedChildId=$process.Id
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(20000)){
            if(-not $process.HasExited){$process.Kill();$killed=$true}
            $null=$process.WaitForExit(5000)
        }
        Assert-Worker ($process.HasExited -and -not $killed -and $elapsed.Elapsed.TotalSeconds -lt 25) ('Blocked native worker prevented bounded report/exit for '+$mode+'. Only the exact owned child was terminated.')
        $outText=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $childRoot 'stdout.txt'),$outText.Substring(0,[Math]::Min(4096,$outText.Length)),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $childRoot 'stderr.txt'),$errorText.Substring(0,[Math]::Min(4096,$errorText.Length)),[Text.UTF8Encoding]::new($false))
        $expectedExit=if($mode -eq 'ReportFailure'){1}else{0}
        Assert-Worker ($process.ExitCode -eq $expectedExit) ('Unexpected isolated child exit for '+$mode+': '+$errorText.Substring(0,[Math]::Min(512,$errorText.Length)))
        if($mode -eq 'HelperOnly'){
            $proof=Get-Content -LiteralPath (Join-Path $childRoot 'helper-returned.json') -Raw|ConvertFrom-Json
            Assert-Worker ($proof.PID -eq $ownedChildId -and $proof.Returned -and $proof.Result.Status -ceq 'Partial' -and -not $proof.Result.Complete -and $proof.Result.Truncated -and $proof.Result.Files.Count -eq 1 -and $proof.Result.Worker.Status -ceq 'TimedOut' -and $proof.Result.Worker.TimedOut -and $proof.Result.Worker.TimeoutSeconds -eq 1 -and $proof.Result.Worker.StopRequested -and $proof.Result.Worker.RetainedUntilRunnerExit) 'A blocked native worker did not return bounded partial evidence or the helper exited its caller.'
            Assert-Worker ($proof.Lifecycle.PendingCount -ge 1 -and $proof.Lifecycle.RetainedCount -ge 1 -and $proof.Lifecycle.StopRequestedCount -eq $proof.StopCountBefore) 'Lifecycle inspection waited for blocked work or requested cancellation repeatedly.'
            Assert-Worker ($proof.Failed.Worker.Status -ceq 'Failed' -and -not $proof.Failed.Complete -and $proof.Failed.Values.Count -eq 1 -and $proof.Failed.CollectionError -ceq 'Fixture collector failure.' -and $proof.Empty.Worker.Status -ceq 'Failed' -and -not $proof.Empty.Complete -and $proof.Empty.Connections.Count -eq 1) 'Collector failure or missing terminal result lost published rows or claimed success.'
            foreach($workerProof in $proof.Result.Worker,$proof.Failed.Worker){Assert-Worker ($workerProof.LastOperation.Length -eq 512 -and $workerProof.LastOperation.StartsWith('Operation-') -and $workerProof.LastPath.Length -eq 1024 -and $workerProof.LastPath.StartsWith('C:\Fixture\')) 'Timed-out or failed worker lost its bounded blocked operation/path evidence.'}
            Assert-Worker ($proof.Empty.Worker.LastOperation -ceq '' -and $proof.Empty.Worker.LastPath -ceq '') 'Absent worker progress keys invented operation/path evidence or prevented failure retention.'
            Assert-Worker (-not (Get-Content -LiteralPath (Join-Path $childRoot 'helper-returned.json') -Raw).Contains('DO-NOT-SERIALIZE-PRIVATE-EXCEPTION-DATA')) 'Worker diagnostics serialized private exception Data.'
        }elseif($mode -eq 'ReportFailure'){
            Assert-Worker (-not(Test-Path -LiteralPath (Join-Path $childRoot 'after-finalization.json')) -and -not(Test-Path -LiteralPath (Join-Path $childRoot 'output/runtime.json') -PathType Leaf)) 'Failed final report persistence returned success or reached the post-finalization sentinel.'
        }else{
            $runtime=Get-Content -LiteralPath (Join-Path $childRoot 'output/runtime.json') -Raw|ConvertFrom-Json
            Assert-Worker ($runtime.FixtureOwnerPID -eq $ownedChildId -and $runtime.Status -ceq 'Failed' -and $runtime.Error -ceq 'Fixture primary access denied.' -and $runtime.ErrorDetails.HResult -eq -2147024891 -and $runtime.ErrorDetails.NativeErrorCode -eq 5 -and $runtime.TargetUnchanged -and $runtime.FinishedUtc) 'Actual finalization lost primary failure or final report persistence before process exit.'
            foreach($entry in @(@('files-after.json','Files'),@('registry-after.json','Values'),@('network-after.json','Connections'))){
                $inventory=Get-Content -LiteralPath (Join-Path $childRoot ('output/'+$entry[0])) -Raw|ConvertFrom-Json
                Assert-Worker ($inventory.Status -ceq 'Partial' -and -not $inventory.Complete -and $inventory.Truncated -and @($inventory.($entry[1])).Count -eq 1 -and $inventory.Worker.Status -ceq 'TimedOut') 'A hard collector timeout lost published partial rows or trusted racing complete state.'
                Assert-Worker ($inventory.Worker.LastOperation.Length -eq 512 -and $inventory.Worker.LastPath.Length -eq 1024) 'Finalized partial artifacts omitted bounded last-operation/path diagnostics.'
            }
            $checkpoint=Get-Content -LiteralPath (Join-Path $childRoot 'checkpoint.json') -Raw|ConvertFrom-Json
            Assert-Worker ($checkpoint.Phase -ceq 'FinalSavedReport' -and $checkpoint.Finished) 'The dedicated process exited before the final persisted-report checkpoint.'
            Assert-Worker ((Test-Path -LiteralPath (Join-Path $childRoot 'after-finalization.json')) -eq ($mode -eq 'Unowned')) 'Terminal process exit ignored dedicated runner ownership or did not happen after report persistence.'
        }
        @{Mode=$mode;PID=$ownedChildId;ExitCode=$process.ExitCode;ElapsedMilliseconds=$elapsed.ElapsedMilliseconds;NativeFixtureSleepMilliseconds=60000;KilledByHarness=$killed}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $childRoot 'process-proof.json') -Encoding utf8
    }finally{
        if($started -and -not $process.HasExited){$process.Kill();$null=$process.WaitForExit(5000)}
        $process.Dispose()
    }
}
Write-Output 'PASS: real blocked native calls return partial rows before completion, final reports preserve primary errors, and only an explicitly owned runner exits after persistence; unowned callers return and failed persistence exits nonzero. Exact child processes only; no target or VM actions.'
