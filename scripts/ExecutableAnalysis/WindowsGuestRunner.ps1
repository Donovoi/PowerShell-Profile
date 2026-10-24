# This trusted script is copied into the dedicated guest during provisioning.
# Never run this script against an input on the host.
#requires -Version 5.1
param(
    [switch]$OwnedRunner,
    [ValidateRange(1,600)][int]$TimeoutSeconds=120,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSHA256,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$PayloadManifestSHA256,
    [ValidateSet('DesktopLayout','RegisteredPackage')][string]$LaunchMode='DesktopLayout',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{2,255}$')][string]$ExpectedPackageFullName,
    [ValidateRange(128,8192)][int]$MaxProcessMemoryMB=1024,
    [ValidateRange(128,16384)][int]$MaxJobMemoryMB=4096
)
$ErrorActionPreference='Stop'
if(-not $OwnedRunner){throw 'This asset must run in the dedicated controller-created runner process.'}
function Get-GuestExceptionDetail {
    param([Parameter(Mandatory)][Exception]$Exception)
    $cause=$Exception.GetBaseException()
    $nativeCode=if($cause -is [ComponentModel.Win32Exception]){$cause.NativeErrorCode}else{$null}
    [pscustomobject]@{
        ExceptionType=$cause.GetType().FullName;Message=$cause.Message;WrapperMessage=$Exception.Message
        HResult=$cause.HResult;HResultHex=('0x{0:X8}' -f $cause.HResult)
        NativeErrorCode=$nativeCode
        NativeErrorMessage=if($null -ne $nativeCode){[ComponentModel.Win32Exception]::new($nativeCode).Message}else{$null}
        Operation=$cause.Data['Operation']
    }
}
function Write-GuestCheckpoint {
    <#.SYNOPSIS
    Writes bounded diagnostic progress without changing the runtime outcome.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock','',Justification='Best-effort diagnostic writes and temporary-file cleanup must never replace the primary runtime failure.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Collections.IDictionary]$Record=$record,
        [string]$OutputDirectory=$output,
        [switch]$Finished
    )
    $temporary=$null;$temporaryCreated=$false
    try{
        if($null -eq $Record){return}
        if($null -eq $Record.CheckpointDiagnostics){$Record.CheckpointDiagnostics=[ordered]@{Attempts=0;WriteFailures=0;LastWriteFailed=$false;LastWriteHResult=$null;LastFailureUtc=$null;HistoryTruncated=$false}}
        $diagnostics=$Record.CheckpointDiagnostics
        $diagnostics.Attempts=[Math]::Min([long]$diagnostics.Attempts+1,[int]::MaxValue)
        $allowed=@('Started','BeforeNetworkInventory','BeforeCompile','BeforeFileInventory','BeforeRegistryInventory','BeforeRegisterPackage','BeforeVerifyTarget','ActivateAndObservePackage','AfterRunRegistered','LaunchAndObserveJob','AfterRunJob','BeforePostTargetVerification','BeforePostFileInventory','BeforePostRegistryInventory','BeforePostNetworkInventory','BeforeSaveReport','FinalSavedReport')
        if($Phase -cnotin $allowed -or ($Finished -and $Phase -cne 'FinalSavedReport')){throw 'Invalid trusted checkpoint phase.'}
        $now=[DateTime]::UtcNow.ToString('o')
        $history=@($Record.CheckpointHistory|Where-Object {$null -ne $_})+@([pscustomobject]@{Phase=$Phase;Utc=$now})
        if($history.Count -gt 32){$history=@($history|Select-Object -Last 32);$diagnostics.HistoryTruncated=$true}
        $Record.CheckpointHistory=$history
        $runnerHash=[string]$Record.RunnerSHA256;if($runnerHash -notmatch '^[A-Fa-f0-9]{64}$'){$runnerHash=$null}
        $started=[string]$Record.StartedUtc;if($started.Length -gt 40){$started=$null}
        $execution=$null
        if($null -ne $Record.Execution){
            $reason=[string]$Record.Execution.Reason;$reason=$reason.Substring(0,[Math]::Min(128,$reason.Length))
            $execution=[ordered]@{RootProcessId=[long]$Record.Execution.RootProcessId;ExitCode=[long]$Record.Execution.ExitCode;Reason=$reason;DurationMilliseconds=[long]$Record.Execution.DurationMilliseconds;ProcessCount=@($Record.Execution.Processes).Count;WindowCount=@($Record.Execution.Windows).Count;JobAssigned=[bool]$Record.Execution.JobAssigned;JobClosed=[bool]$Record.Execution.JobClosed;ActivationProgressWriteFailures=[int]$Record.Execution.ActivationProgressWriteFailures}
        }
        $inventories=[ordered]@{}
        foreach($name in 'FileInventoryBefore','FileInventoryAfter','RegistryInventoryBefore','RegistryInventoryAfter'){
            $inventory=$Record.$name
            if($null -ne $inventory){
                $status=[string]$inventory.Status;$status=$status.Substring(0,[Math]::Min(32,$status.Length))
                $inventories[$name]=[ordered]@{Status=$status;Complete=($inventory.Complete -eq $true);ErrorCount=[long]$inventory.ErrorCount;Truncated=[bool]$inventory.Truncated;ErrorsTruncated=[bool]$inventory.ErrorsTruncated;TimeBudgetSeconds=[int]$inventory.TimeBudgetSeconds;TimeBudgetExceeded=[bool]$inventory.TimeBudgetExceeded;DurationMilliseconds=[long]$inventory.DurationMilliseconds}
            }
        }
        $errorText=[string]$Record.Error;$errorText=$errorText.Substring(0,[Math]::Min(1024,$errorText.Length))
        $diagnostics.LastWriteFailed=$false
        $progress=[ordered]@{Schema='PowerShellProfile.WindowsRuntimeProgress.v1';Status=if($Finished){'Finished'}else{'InProgress'};DiagnosticOnly=$true;Phase=$Phase;StartedUtc=$started;UpdatedUtc=$now;RunnerSHA256=$runnerHash;Execution=$execution;Inventories=$inventories;Error=$errorText;ErrorHResult=if($Record.ErrorDetails){[long]$Record.ErrorDetails.HResult}else{$null};ErrorScriptLine=if($Record.ErrorContext){[int]$Record.ErrorContext.ScriptLineNumber}else{$null};Phases=$history;CheckpointDiagnostics=$diagnostics}
        $errorOperation=if($Record.ErrorDetails){[string]$Record.ErrorDetails.Operation}else{''}
        $errorType=if($Record.ErrorDetails){[string]$Record.ErrorDetails.ExceptionType}else{''}
        $progress.ErrorOperation=$errorOperation.Substring(0,[Math]::Min(128,$errorOperation.Length))
        $progress.ErrorExceptionType=$errorType.Substring(0,[Math]::Min(128,$errorType.Length))
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($progress|ConvertTo-Json -Depth 8 -Compress))
        if($bytes.Length -gt 16384){throw 'Checkpoint exceeds its fixed byte limit.'}
        if(-not [IO.Directory]::Exists($OutputDirectory) -or ([IO.File]::GetAttributes($OutputDirectory) -band [IO.FileAttributes]::ReparsePoint)){throw 'Checkpoint directory is absent or redirected.'}
        $destination=Join-Path $OutputDirectory 'runtime-progress.json'
        if([IO.File]::Exists($destination) -and ([IO.File]::GetAttributes($destination) -band [IO.FileAttributes]::ReparsePoint)){throw 'Checkpoint destination is redirected.'}
        $temporary=Join-Path $OutputDirectory ('runtime-progress.'+[Guid]::NewGuid().ToString('N')+'.tmp')
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$temporaryCreated=$true
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush()}finally{$stream.Dispose()}
        if([IO.File]::Exists($destination)){[IO.File]::Replace($temporary,$destination,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$destination)}
        $temporaryCreated=$false
    }catch{
        # A diagnostic write must never replace an activation/inventory failure.
        try{if($null -ne $Record -and $null -ne $Record.CheckpointDiagnostics){$Record.CheckpointDiagnostics.WriteFailures=[Math]::Min([long]$Record.CheckpointDiagnostics.WriteFailures+1,[int]::MaxValue);$Record.CheckpointDiagnostics.LastWriteFailed=$true;$Record.CheckpointDiagnostics.LastWriteHResult=$_.Exception.HResult;$Record.CheckpointDiagnostics.LastFailureUtc=[DateTime]::UtcNow.ToString('o')}}catch{}
    }finally{if($temporaryCreated -and $temporary){try{[IO.File]::Delete($temporary)}catch{}}}
}
$target='C:\ProfileAnalysis\Work\target.exe'
$output='C:\ProfileAnalysis\Results'
$record=[ordered]@{SchemaVersion=1;Status='Failed';StartedUtc=[DateTime]::UtcNow.ToString('o');GuestUser=[Security.Principal.WindowsIdentity]::GetCurrent().Name;IsAdministrator=$null;ExpectedSHA256=$ExpectedSHA256;TargetSHA256=$null;TargetUnchanged=$null;Execution=$null;Validation=@{};Limitations=@('Execution is offline and without arguments or GUI interaction.','Process polling can miss very short-lived processes.','File observations cover the guest work and temporary directories, not every system volume.','Registry observations cover bounded HKCU Software values, not every registry hive.','Connection snapshots do not trace every failed network API call; no external network adapter is present.','A disposable VM is a containment measure, not a guarantee against hypervisor escape.')}
$record.Budgets=[ordered]@{TimeoutSeconds=$TimeoutSeconds;MaximumActiveProcesses=32;MaximumProcessMemoryBytes=([long]$MaxProcessMemoryMB*1MB);MaximumJobMemoryBytes=([long]$MaxJobMemoryMB*1MB);CombinedOutputThresholdBytes=8388608;PollingIntervalMilliseconds=100;OutputThresholdIsPolled=$true;FileInventoryEntryLimit=5000;FileInventoryTimeBudgetSeconds=120;FileInventoryTimeBudgetIsCooperative=$true;FileInventoryWorkerWaitSeconds=120;RegistryInventoryWorkerWaitSeconds=30;NetworkInventoryWorkerWaitSeconds=30;RegistryKeyLimit=2000;RegistryValueLimit=5000}
if($LaunchMode -eq 'DesktopLayout'){$record.Limitations+='Process creation or memory allocation can fail at the configured job limits. The polled output threshold can be exceeded between observations.'}
$record.Limitations+='Inventory workers have bounded waits: 120 seconds for files and 30 seconds each for registry and connection snapshots. Timed-out workers retain bounded partial rows; the dedicated runner exits after saving its final report to terminate blocked native calls. Snapshot formatting and mandatory identity checks remain subject to the whole-VM watchdog.'

function Get-GuestInventoryWorkerState {
    [CmdletBinding()]
    param()
    $variable=Get-Variable -Name ProfileAnalysisInventoryWorkers -Scope Script -ErrorAction SilentlyContinue
    $workers=if($variable){@($variable.Value.ToArray())}else{@()}
    $pending=0;$retained=0;$stopped=0
    foreach($worker in $workers){
        if($worker.StopRequested){$stopped++}
        if(-not $worker.Disposed){
            $retained++
            if(-not $worker.Async -or -not $worker.Async.IsCompleted -or ($worker.StopAsync -and -not $worker.StopAsync.IsCompleted)){$pending++}
        }
    }
    [pscustomobject]@{TotalCount=$workers.Count;PendingCount=$pending;RetainedCount=$retained;StopRequestedCount=$stopped;TerminationMethod=if($retained){'OwnedRunnerProcessExitAfterReport'}else{'CompletedWorkersDisposed'}}
}

function Invoke-GuestInventoryWorker {
    <#.SYNOPSIS
    Bounds inventory waits independently of blocked filesystem, registry or CIM calls.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('File','Registry','Network')][string]$Kind,[ValidateRange(1,120)][int]$TimeoutSeconds=30)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $functionName=@{File='Get-GuestFileInventory';Registry='Get-GuestRegistryInventory';Network='Get-GuestNetworkInventory'}[$Kind]
    $definition=(Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).Definition
    $queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $state=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $pipeline=[PowerShell]::Create()
    $worker=[pscustomobject]@{Kind=$Kind;PowerShell=$pipeline;Async=$null;StopAsync=$null;StopRequested=$false;Disposed=$false}
    $variable=Get-Variable -Name ProfileAnalysisInventoryWorkers -Scope Script -ErrorAction SilentlyContinue
    if(-not $variable){$script:ProfileAnalysisInventoryWorkers=[Collections.Generic.List[object]]::new()}
    $script:ProfileAnalysisInventoryWorkers.Add($worker)
    $timedOut=$false;$failureText=$null;$result=$null;$workerStatus='Failed'
    try{
        # Definitions come only from the trusted runner. No target text, credentials
        # or mutable parent report is passed into the independent runspace.
        $workerText='param($RecordSink,$ProgressState)'+[Environment]::NewLine+"`$ErrorActionPreference='Stop'"+[Environment]::NewLine+'function '+$functionName+' {'+[Environment]::NewLine+$definition+[Environment]::NewLine+'}'+[Environment]::NewLine+$functionName+' -RecordSink $RecordSink -ProgressState $ProgressState'
        $null=$pipeline.AddScript($workerText).AddParameter('RecordSink',$queue).AddParameter('ProgressState',$state)
        $worker.Async=$pipeline.BeginInvoke()
        $remaining=[Math]::Max(0,[int]($TimeoutSeconds*1000-$timer.ElapsedMilliseconds))
        $finished=$worker.Async.IsCompleted -or $worker.Async.AsyncWaitHandle.WaitOne($remaining)
        if(-not $finished){
            $timedOut=$true;$workerStatus='TimedOut'
            $failureText='Inventory worker exceeded its elapsed-time allowance; retained rows are incomplete.'
        }else{
            $items=$pipeline.EndInvoke($worker.Async)
            if($items.Count -ne 1 -or $null -eq $items[0] -or $items[0].Status -notin 'Completed','Partial' -or $items[0].Complete -isnot [bool]){throw 'Inventory worker returned no unique coverage result.'}
            $result=$items[0];$workerStatus='Completed'
            $pipeline.Dispose();$worker.Disposed=$true
        }
    }catch{
        $workerStatus='Failed'
        $message=[string]$_.Exception.GetBaseException().Message
        $failureText=$message.Substring(0,[Math]::Min(1024,$message.Length))
    }
    if(-not $worker.Disposed){
        # Never EndInvoke, EndStop, Close or Dispose an unfinished native call.
        # The owning runner exits only after persisting its final report.
        try{$worker.StopAsync=$pipeline.BeginStop($null,$null);$worker.StopRequested=$true}
        catch{$worker|Add-Member -NotePropertyName StopRequestHResult -NotePropertyValue $_.Exception.GetBaseException().HResult}
    }
    if($workerStatus -ne 'Completed'){
        # Take one finite snapshot. A racing completion cannot turn a timeout
        # into complete coverage. Collectors enforce row and text caps at source.
        $envelopes=$queue.ToArray()
        $maximum=if($Kind -eq 'Network'){320}else{5064}
        if($envelopes.Count -gt $maximum){$envelopes=@($envelopes|Select-Object -First $maximum);$failureText='Inventory worker exceeded its retained-row cap.'}
        $snapshot=@{}
        foreach($entry in $state.ToArray()){
            if($entry.Value -is [string]){$snapshot[$entry.Key]=$entry.Value.Substring(0,[Math]::Min(2048,$entry.Value.Length))}
            elseif($entry.Value -is [bool] -or $entry.Value -is [int] -or $entry.Value -is [long]){$snapshot[$entry.Key]=$entry.Value}
        }
        $errors=@($envelopes|Where-Object Kind -EQ 'Error'|Select-Object -First 64|ForEach-Object Data)
        $errorCount=[Math]::Max([long]$snapshot.ErrorCount,$errors.Count)
        $summary=[ordered]@{Status='Partial';Complete=$false;Truncated=$true;DataTruncated=[bool]$snapshot.DataTruncated;Errors=$errors;ErrorCount=$errorCount;ErrorsTruncated=($errorCount -gt $errors.Count);Scope=@([string]$snapshot.Scope);DurationMilliseconds=[long]$timer.ElapsedMilliseconds;CollectionError=$failureText}
        switch($Kind){
            File {
                $summary.Files=@($envelopes|Where-Object Kind -EQ 'File'|Select-Object -First 5000|ForEach-Object Data)
                $summary.Visited=[long]$snapshot.Visited;$summary.ReparsePointsSkipped=[long]$snapshot.ReparsePointsSkipped
                $summary.TimeBudgetSeconds=120;$summary.TimeBudgetExceeded=[bool]$snapshot.TimeBudgetExceeded
            }
            Registry {$summary.Values=@($envelopes|Where-Object Kind -EQ 'RegistryValue'|Select-Object -First 5000|ForEach-Object Data);$summary.VisitedKeys=[long]$snapshot.VisitedKeys}
            Network {$summary.Connections=@($envelopes|Where-Object Kind -EQ 'Connection'|Select-Object -First 256|ForEach-Object Data);$summary.VisitedConnections=[long]$snapshot.VisitedConnections}
        }
        $result=[pscustomobject]$summary
    }
    $timer.Stop()
    $lastOperation='';$lastPath=''
    if($state.ContainsKey('CurrentOperation')){$value=[string]$state['CurrentOperation'];$lastOperation=$value.Substring(0,[Math]::Min(512,$value.Length))}
    if($state.ContainsKey('CurrentPath')){$value=[string]$state['CurrentPath'];$lastPath=$value.Substring(0,[Math]::Min(1024,$value.Length))}
    $proof=[pscustomobject]@{Status=$workerStatus;TimedOut=$timedOut;TimeoutSeconds=$TimeoutSeconds;DurationMilliseconds=[long]$timer.ElapsedMilliseconds;StopRequested=$worker.StopRequested;PendingAtReturn=(-not $worker.Disposed -and (-not $worker.Async -or -not $worker.Async.IsCompleted -or ($worker.StopAsync -and -not $worker.StopAsync.IsCompleted)));RetainedUntilRunnerExit=(-not $worker.Disposed);DeadlineScope='Worker execution and startup wait; bounded snapshot formatting follows.'}
    $proof|Add-Member -NotePropertyName LastOperation -NotePropertyValue $lastOperation
    $proof|Add-Member -NotePropertyName LastPath -NotePropertyValue $lastPath
    $result|Add-Member -NotePropertyName Worker -NotePropertyValue $proof
    $result
}

function Get-GuestFileInventory {
    [CmdletBinding()]
    param(
        [ValidateCount(1,8)][string[]]$Root=@('C:\ProfileAnalysis\Work',$env:TEMP),
        [Collections.Concurrent.ConcurrentQueue[object]]$RecordSink,
        [Collections.Concurrent.ConcurrentDictionary[string,object]]$ProgressState
    )
    $rows=New-Object 'Collections.Generic.List[object]'
    $stack=New-Object 'Collections.Generic.Stack[string]'
    $inventoryErrors=New-Object 'Collections.Generic.List[object]'
    $timer=[Diagnostics.Stopwatch]::StartNew();$timeBudgetSeconds=120
    $stopSignal=[OperationCanceledException]::new('Inventory cooperative limit reached.')
    $errorBudget=@{Total=0;Visited=0;TimeBudgetExceeded=$false;EntryLimitReached=$false;ReparseSkipped=0;DataTruncated=$false;Characters=0}
    $sink=$RecordSink
    $publish={param([string]$Kind,[object]$Data)
        if($null -ne $sink){if($sink.Count -lt 5064){$sink.Enqueue([pscustomobject]@{Kind=$Kind;Data=$Data})}else{$errorBudget.DataTruncated=$true}}
    }
    $progress={param([string]$Operation,[string]$Path)
        if($null -ne $ProgressState){
            $ProgressState['Status']='InProgress';$ProgressState['Complete']=$false
            $ProgressState['Scope']=($Root -join ';').Substring(0,[Math]::Min(1024,($Root -join ';').Length))
            $ProgressState['CurrentOperation']=$Operation;$ProgressState['CurrentPath']=$Path.Substring(0,[Math]::Min(1024,$Path.Length))
            $ProgressState['Visited']=$errorBudget.Visited;$ProgressState['ErrorCount']=$errorBudget.Total
            $ProgressState['RowsPublished']=$rows.Count;$ProgressState['ErrorsPublished']=$inventoryErrors.Count
            $ProgressState['ErrorsTruncated']=($errorBudget.Total -gt $inventoryErrors.Count)
            $ProgressState['DataTruncated']=$errorBudget.DataTruncated;$ProgressState['Truncated']=($errorBudget.EntryLimitReached -or $errorBudget.TimeBudgetExceeded -or $errorBudget.DataTruncated)
            $ProgressState['ReparsePointsSkipped']=$errorBudget.ReparseSkipped;$ProgressState['Characters']=$errorBudget.Characters
            $ProgressState['TimeBudgetSeconds']=$timeBudgetSeconds;$ProgressState['TimeBudgetExceeded']=$errorBudget.TimeBudgetExceeded
            $ProgressState['DurationMilliseconds']=[long]$timer.ElapsedMilliseconds
        }
    }
    $addError={
        param([string]$Path,[string]$Operation,[Management.Automation.ErrorRecord]$Failure)
        $errorBudget.Total++
        if($inventoryErrors.Count -lt 64){
            $message=[string]$Failure.Exception.GetBaseException().Message
            $identifier=[string]$Failure.FullyQualifiedErrorId
            $row=[pscustomobject]@{Path=$Path.Substring(0,[Math]::Min(1024,$Path.Length));Operation=$Operation;Message=$message.Substring(0,[Math]::Min(1024,$message.Length));FullyQualifiedErrorId=$identifier.Substring(0,[Math]::Min(512,$identifier.Length))}
            $inventoryErrors.Add($row);& $publish 'Error' $row
        }
        & $progress $Operation $Path
    }
    & $progress 'Starting' ''
    foreach($directory in $Root){
        if($timer.ElapsedMilliseconds -ge 120000){$errorBudget.TimeBudgetExceeded=$true;break}
        try{
            & $progress 'InspectRoot' $directory
            $item=Get-Item -LiteralPath $directory -Force -ErrorAction Stop
            if($timer.ElapsedMilliseconds -ge 120000){$errorBudget.TimeBudgetExceeded=$true;break}
            if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'An inventory root must be a regular directory.'}
            $stack.Push($item.FullName)
        }catch{& $addError -Path $directory -Operation 'InspectRoot' -Failure $_}
    }
    while($stack.Count -gt 0 -and $errorBudget.Visited -lt 5000 -and -not $errorBudget.TimeBudgetExceeded) {
        if($timer.ElapsedMilliseconds -ge 120000){$errorBudget.TimeBudgetExceeded=$true;break}
        $directory=$stack.Pop()
        try{
            & $progress 'EnumerateDirectory' $directory
            Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop|ForEach-Object {
                $entry=$_
                if($timer.ElapsedMilliseconds -ge 120000){$errorBudget.TimeBudgetExceeded=$true;throw $stopSignal}
                if($errorBudget.Visited -ge 5000){$errorBudget.EntryLimitReached=$true;throw $stopSignal}
                $errorBudget.Visited++
                if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){$errorBudget.ReparseSkipped++}
                elseif($entry.PSIsContainer){$stack.Push($entry.FullName)}
                else{
                    $hash=$null;$hashError=$null
                    if($entry.Length -le 1MB){
                        & $progress 'HashFile' $entry.FullName
                        try{$hash=(Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256 -ErrorAction Stop).Hash}
                        catch{$message=[string]$_.Exception.GetBaseException().Message;$hashError=$message.Substring(0,[Math]::Min(1024,$message.Length));& $addError -Path $entry.FullName -Operation 'HashFile' -Failure $_}
                    }
                    $path=[string]$entry.FullName;$pathTruncated=$path.Length -gt 1024
                    if($pathTruncated){$path=$path.Substring(0,1024);$errorBudget.DataTruncated=$true}
                    $rowCharacters=$path.Length+([string]$hashError).Length+128
                    if($errorBudget.Characters+$rowCharacters -gt 2097152){$errorBudget.EntryLimitReached=$true;$errorBudget.DataTruncated=$true;throw $stopSignal}
                    $errorBudget.Characters+=$rowCharacters
                    $row=[pscustomobject]@{Path=$path;PathTruncated=$pathTruncated;Bytes=[long]$entry.Length;ModifiedUtc=$entry.LastWriteTimeUtc.ToString('o');SHA256=$hash;HashError=$hashError}
                    $rows.Add($row);& $publish 'File' $row
                }
                & $progress 'EnumerateDirectory' $directory
                if($timer.ElapsedMilliseconds -ge 120000){$errorBudget.TimeBudgetExceeded=$true;throw $stopSignal}
            }
        }catch{
            if(-not [object]::ReferenceEquals($_.Exception.GetBaseException(),$stopSignal)){& $addError -Path $directory -Operation 'EnumerateDirectory' -Failure $_}
        }
        if($errorBudget.EntryLimitReached){break}
    }
    if($timer.ElapsedMilliseconds -ge 120000){$errorBudget.TimeBudgetExceeded=$true}
    $timer.Stop()
    $truncated=$errorBudget.EntryLimitReached -or $stack.Count -gt 0 -or $errorBudget.TimeBudgetExceeded -or $errorBudget.DataTruncated
    $complete=-not $truncated -and $errorBudget.Total -eq 0
    & $progress 'Finished' ''
    if($null -ne $ProgressState){$ProgressState['Status']=if($complete){'Completed'}else{'Partial'};$ProgressState['Truncated']=$truncated;$ProgressState['Complete']=$complete}
    [pscustomobject]@{Status=if($complete){'Completed'}else{'Partial'};Complete=$complete;Files=$rows.ToArray();Visited=$errorBudget.Visited;Truncated=$truncated;DataTruncated=$errorBudget.DataTruncated;Scope=$Root;Errors=$inventoryErrors.ToArray();ErrorCount=$errorBudget.Total;ErrorsTruncated=($errorBudget.Total -gt $inventoryErrors.Count);ReparsePointsSkipped=$errorBudget.ReparseSkipped;TimeBudgetSeconds=$timeBudgetSeconds;TimeBudgetExceeded=$errorBudget.TimeBudgetExceeded;DurationMilliseconds=[long]$timer.ElapsedMilliseconds}
}

function Get-GuestRegistryInventory {
    [CmdletBinding()]
    param(
        [Collections.Concurrent.ConcurrentQueue[object]]$RecordSink,
        [Collections.Concurrent.ConcurrentDictionary[string,object]]$ProgressState
    )
    $rows=New-Object 'Collections.Generic.List[object]'
    $inventoryErrors=New-Object 'Collections.Generic.List[object]'
    $stack=New-Object 'Collections.Generic.Stack[string]';$stack.Push('Software')
    $visited=0;$characters=0
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $budget=@{ErrorCount=0;Characters=0;DataTruncated=$false;KeyLimitReached=$false;ValueLimitReached=$false}
    $sink=$RecordSink
    $publish={param([string]$Kind,[object]$Data)
        if($null -ne $sink){if($sink.Count -lt 5064){$sink.Enqueue([pscustomobject]@{Kind=$Kind;Data=$Data})}else{$budget.DataTruncated=$true}}
    }
    $progress={param([string]$Operation,[string]$Path)
        if($null -ne $ProgressState){
            $ProgressState['Status']='InProgress';$ProgressState['Complete']=$false;$ProgressState['Scope']='HKCU\Software'
            $ProgressState['CurrentOperation']=$Operation;$ProgressState['CurrentPath']=$Path.Substring(0,[Math]::Min(1024,$Path.Length))
            $ProgressState['VisitedKeys']=$visited;$ProgressState['ErrorCount']=$budget.ErrorCount
            $ProgressState['RowsPublished']=$rows.Count;$ProgressState['ErrorsPublished']=$inventoryErrors.Count
            $ProgressState['ErrorsTruncated']=($budget.ErrorCount -gt $inventoryErrors.Count)
            $ProgressState['DataTruncated']=$budget.DataTruncated;$ProgressState['Truncated']=($budget.DataTruncated -or $budget.KeyLimitReached -or $budget.ValueLimitReached)
            $ProgressState['Characters']=$budget.Characters;$ProgressState['DurationMilliseconds']=[long]$timer.ElapsedMilliseconds
        }
    }
    & $progress 'Starting' ''
    while($stack.Count -gt 0 -and $visited -lt 2000 -and $rows.Count -lt 5000 -and $characters -lt 262144) {
        $name=$stack.Pop();$visited++;$key=$null
        try {
            & $progress 'OpenRegistryKey' ('HKCU\'+$name)
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($name,$false)
            if($null -eq $key){continue}
            & $progress 'EnumerateRegistryKeys' ('HKCU\'+$name)
            foreach($child in $key.GetSubKeyNames()){
                if($visited+$stack.Count -ge 2000){$budget.KeyLimitReached=$true;break}
                $stack.Push($name+'\'+$child)
            }
            & $progress 'EnumerateRegistryValues' ('HKCU\'+$name)
            foreach($valueName in $key.GetValueNames()) {
                if($rows.Count -ge 5000 -or $characters -ge 262144){$budget.ValueLimitReached=$true;break}
                & $progress 'ReadRegistryValue' ('HKCU\'+$name+'\'+$valueName)
                $value=$key.GetValue($valueName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $valueTruncated=$false
                if($value -is [byte[]]){
                    $bytesToEncode=[Math]::Min(3072,$value.Length)
                    $text=[Convert]::ToBase64String($value,0,$bytesToEncode);$valueTruncated=$value.Length -gt $bytesToEncode
                }elseif($value -is [string[]]){
                    $builder=[Text.StringBuilder]::new(4096)
                    for($index=0;$index -lt $value.Length;$index++){
                        if($index -gt 0){if($builder.Length -ge 4096){$valueTruncated=$true;break};[void]$builder.Append("`n")}
                        $part=[string]$value[$index];$take=[Math]::Min($part.Length,4096-$builder.Length)
                        [void]$builder.Append($part,0,$take)
                        if($take -lt $part.Length){$valueTruncated=$true;break}
                    }
                    $text=$builder.ToString()
                }else{$text=[string]$value;if($text.Length -gt 4096){$text=$text.Substring(0,4096);$valueTruncated=$true}}
                $remaining=262144-$characters
                if($text.Length -gt $remaining){$text=$text.Substring(0,$remaining);$valueTruncated=$true;$budget.ValueLimitReached=$true}
                $characters+=$text.Length
                $keyPath='HKCU\'+$name;$displayName=[string]$valueName
                $keyTruncated=$keyPath.Length -gt 1024;$nameTruncated=$displayName.Length -gt 512
                if($keyTruncated){$keyPath=$keyPath.Substring(0,1024)}
                if($nameTruncated){$displayName=$displayName.Substring(0,512)}
                if($keyTruncated -or $nameTruncated -or $valueTruncated){$budget.DataTruncated=$true}
                $rowCharacters=$keyPath.Length+$displayName.Length+$text.Length+64
                if($budget.Characters+$rowCharacters -gt 2097152){$budget.DataTruncated=$true;$budget.ValueLimitReached=$true;break}
                & $progress 'ReadRegistryValueKind' ('HKCU\'+$name+'\'+$valueName)
                $kind=[string]$key.GetValueKind($valueName)
                $row=[pscustomobject]@{Key=$keyPath;KeyTruncated=$keyTruncated;Name=$displayName;NameTruncated=$nameTruncated;Kind=$kind;Value=$text;Truncated=$valueTruncated}
                $budget.Characters+=$rowCharacters;$rows.Add($row);& $publish 'RegistryValue' $row
                & $progress 'EnumerateRegistryValues' ('HKCU\'+$name)
            }
        } catch {
            $budget.ErrorCount++
            if($inventoryErrors.Count -lt 64){
                $message=[string]$_.Exception.GetBaseException().Message;$identifier=[string]$_.FullyQualifiedErrorId;$path='HKCU\'+$name
                $row=[pscustomobject]@{Path=$path.Substring(0,[Math]::Min(1024,$path.Length));Operation='ReadRegistry';Message=$message.Substring(0,[Math]::Min(1024,$message.Length));FullyQualifiedErrorId=$identifier.Substring(0,[Math]::Min(512,$identifier.Length))}
                $inventoryErrors.Add($row);& $publish 'Error' $row
            }
            & $progress 'ReadRegistryError' ('HKCU\'+$name)
        } finally {if($key){& $progress 'CloseRegistryKey' ('HKCU\'+$name);$key.Dispose()}}
        if($budget.ValueLimitReached){break}
    }
    $timer.Stop()
    $truncated=$stack.Count -gt 0 -or $rows.Count -ge 5000 -or $characters -ge 262144 -or $budget.KeyLimitReached -or $budget.ValueLimitReached -or $budget.DataTruncated
    $complete=-not $truncated -and $budget.ErrorCount -eq 0
    & $progress 'Finished' ''
    if($null -ne $ProgressState){$ProgressState['Status']=if($complete){'Completed'}else{'Partial'};$ProgressState['Truncated']=$truncated;$ProgressState['Complete']=$complete}
    [pscustomobject]@{Status=if($complete){'Completed'}else{'Partial'};Complete=$complete;Values=$rows.ToArray();VisitedKeys=$visited;Truncated=$truncated;DataTruncated=$budget.DataTruncated;Scope='HKCU\Software';Errors=$inventoryErrors.ToArray();ErrorCount=$budget.ErrorCount;ErrorsTruncated=($budget.ErrorCount -gt $inventoryErrors.Count);DurationMilliseconds=[long]$timer.ElapsedMilliseconds}
}

function Get-GuestNetworkInventory {
    [CmdletBinding()]
    param(
        [Collections.Concurrent.ConcurrentQueue[object]]$RecordSink,
        [Collections.Concurrent.ConcurrentDictionary[string,object]]$ProgressState
    )
    $rows=New-Object 'Collections.Generic.List[object]'
    $inventoryErrors=New-Object 'Collections.Generic.List[object]'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $budget=@{Visited=0;ErrorCount=0;Characters=0;Truncated=$false;DataTruncated=$false}
    $stopSignal=[OperationCanceledException]::new('Connection inventory limit reached.')
    $sink=$RecordSink
    $publish={param([string]$Kind,[object]$Data)
        if($null -ne $sink){if($sink.Count -lt 320){$sink.Enqueue([pscustomobject]@{Kind=$Kind;Data=$Data})}else{$budget.DataTruncated=$true}}
    }
    $progress={param([string]$Operation)
        if($null -ne $ProgressState){
            $ProgressState['Status']='InProgress';$ProgressState['Complete']=$false;$ProgressState['Scope']='TCP connection snapshot'
            $ProgressState['CurrentOperation']=$Operation;$ProgressState['CurrentPath']=''
            $ProgressState['VisitedConnections']=$budget.Visited;$ProgressState['ErrorCount']=$budget.ErrorCount
            $ProgressState['RowsPublished']=$rows.Count;$ProgressState['ErrorsPublished']=$inventoryErrors.Count
            $ProgressState['ErrorsTruncated']=($budget.ErrorCount -gt $inventoryErrors.Count)
            $ProgressState['DataTruncated']=$budget.DataTruncated;$ProgressState['Truncated']=($budget.Truncated -or $budget.DataTruncated)
            $ProgressState['Characters']=$budget.Characters;$ProgressState['DurationMilliseconds']=[long]$timer.ElapsedMilliseconds
        }
    }
    & $progress 'EnumerateConnections'
    try{
        Get-NetTCPConnection -ErrorAction Stop|ForEach-Object {
            $budget.Visited++
            if($rows.Count -ge 256){$budget.Truncated=$true;throw $stopSignal}
            $local=[string]$_.LocalAddress;$remote=[string]$_.RemoteAddress;$state=[string]$_.State
            $identityTruncated=$local.Length -gt 128 -or $remote.Length -gt 128 -or $state.Length -gt 64
            if($local.Length -gt 128){$local=$local.Substring(0,128)}
            if($remote.Length -gt 128){$remote=$remote.Substring(0,128)}
            if($state.Length -gt 64){$state=$state.Substring(0,64)}
            if($identityTruncated){$budget.DataTruncated=$true}
            $rowCharacters=$local.Length+$remote.Length+$state.Length+96
            if($budget.Characters+$rowCharacters -gt 524288){$budget.Truncated=$true;$budget.DataTruncated=$true;throw $stopSignal}
            $row=[pscustomobject]@{LocalAddress=$local;LocalPort=[uint16]$_.LocalPort;RemoteAddress=$remote;RemotePort=[uint16]$_.RemotePort;State=$state;OwningProcess=[uint32]$_.OwningProcess;Truncated=$identityTruncated}
            $budget.Characters+=$rowCharacters;$rows.Add($row);& $publish 'Connection' $row
            & $progress 'EnumerateConnections'
        }
    }catch{
        if(-not [object]::ReferenceEquals($_.Exception.GetBaseException(),$stopSignal)){
            $budget.ErrorCount++
            if($inventoryErrors.Count -lt 64){
                $message=[string]$_.Exception.GetBaseException().Message;$identifier=[string]$_.FullyQualifiedErrorId
                $row=[pscustomobject]@{Path='';Operation='EnumerateConnections';Message=$message.Substring(0,[Math]::Min(1024,$message.Length));FullyQualifiedErrorId=$identifier.Substring(0,[Math]::Min(512,$identifier.Length))}
                $inventoryErrors.Add($row);& $publish 'Error' $row
            }
        }
    }
    $timer.Stop();$truncated=$budget.Truncated -or $budget.DataTruncated;$complete=-not $truncated -and $budget.ErrorCount -eq 0
    & $progress 'Finished'
    if($null -ne $ProgressState){$ProgressState['Status']=if($complete){'Completed'}else{'Partial'};$ProgressState['Truncated']=$truncated;$ProgressState['Complete']=$complete}
    [pscustomobject]@{Status=if($complete){'Completed'}else{'Partial'};Complete=$complete;Connections=$rows.ToArray();VisitedConnections=$budget.Visited;Truncated=$truncated;DataTruncated=$budget.DataTruncated;Scope='TCP connection snapshot';Errors=$inventoryErrors.ToArray();ErrorCount=$budget.ErrorCount;ErrorsTruncated=($budget.ErrorCount -gt $inventoryErrors.Count);DurationMilliseconds=[long]$timer.ElapsedMilliseconds}
}

try {
    if($MaxJobMemoryMB -lt $MaxProcessMemoryMB){throw 'The job memory budget is smaller than its process budget.'}
    $record.RunnerSHA256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
    Write-GuestCheckpoint -Phase Started
    if($PayloadManifestSHA256){
        $payloadPath='C:\ProfileAnalysis\payload-manifest.json'
        if((Get-Item -LiteralPath $payloadPath -ErrorAction Stop).Length -gt 32MB -or (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256 -ErrorAction Stop).Hash -ne $PayloadManifestSHA256){throw 'The verified payload manifest changed before launch.'}
        $payload=Get-Content -LiteralPath $payloadPath -Raw -Encoding UTF8|ConvertFrom-Json
        $applicationRoot='C:\ProfileAnalysis\Work\Application\'
        $target=[IO.Path]::GetFullPath($applicationRoot+$payload.EntryPoint.Replace('/','\'))
        if(-not $target.StartsWith($applicationRoot,[StringComparison]::OrdinalIgnoreCase) -or $payload.SourceSHA256 -ne $ExpectedSHA256){throw 'The payload entry point is outside its verified root or has a different identity.'}
        $record.PayloadManifestSHA256=$PayloadManifestSHA256
        $record.LaunchMode=$LaunchMode;$record.PackageRegistration='NotRequested'
        if($LaunchMode -eq 'DesktopLayout'){$record.Limitations+='Desktop-layout execution preserves package files but does not register MSIX identity, extensions or packaged services.'}
    }else{$record.LaunchMode='SingleFile';$record.PackageRegistration='NotApplicable'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $record.IsAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($record.IsAdministrator){throw 'Target execution refuses an administrator token.'}
    $currentUserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Where-Object {$_.SID.Value -eq $currentUserSid}){throw 'Target execution refuses an account in Administrators, including a filtered administrator token.'}
    $record.Validation.AccountNotAdministrator=$true
    if(-not(Test-Path -LiteralPath ('Registry::HKEY_USERS\'+$currentUserSid))){throw 'The standard user registry profile was not loaded.'}
    $userSoftware=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software',$true)
    if($null -eq $userSoftware){throw 'The standard user HKCU Software hive is not writable.'}
    $userSoftware.Dispose();$record.Validation.UserProfileLoaded=$true
    $record.UserEnvironment=@{UserProfile=$env:USERPROFILE;AppData=$env:APPDATA;LocalAppData=$env:LOCALAPPDATA;Temp=$env:TEMP;UserName=$env:USERNAME;UserDomain=$env:USERDOMAIN;LoadedHiveSid=$currentUserSid;SessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;UserInteractive=[Environment]::UserInteractive}
    Write-GuestCheckpoint -Phase BeforeNetworkInventory
    $adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop|Select-Object Name,Status,HardwareInterface,InterfaceDescription)
    if(@($adapters|Where-Object HardwareInterface).Count){throw 'The guest has a hardware network adapter.'}
    $routes=@(Get-NetRoute -ErrorAction Stop|Select-Object -First 100 DestinationPrefix,InterfaceAlias,NextHop)
    if(@($routes|Where-Object DestinationPrefix -In '0.0.0.0/0','::/0').Count){throw 'The guest has a default network route.'}
    $record.Validation.NoNetworkAdapter=$true
    $networkBefore=Invoke-GuestInventoryWorker -Kind Network -TimeoutSeconds 30
    $networkBefore|Add-Member -NotePropertyName Adapters -NotePropertyValue $adapters
    $networkBefore|Add-Member -NotePropertyName Routes -NotePropertyValue $routes
    $networkBefore|ConvertTo-Json -Depth 6 -Compress|Set-Content -LiteralPath (Join-Path $output 'network-before.json') -Encoding utf8
    $record.NetworkInventoryBefore=$networkBefore|Select-Object Status,Complete,Truncated,ErrorCount,Worker
    $native=@'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ProfileAnalysisGuestJob {
 public enum ActivationProgressStage { BeforeActivation,ActivationReturned,IdentityVerified,ObservationCompleted }
 public static bool TryWriteActivationProgress(string output,ActivationProgressStage stage,int? error,uint rootProcessId,bool managerCreated,bool identityVerified,long elapsedMilliseconds,int previousWriteFailures){
  string temporary=null;bool created=false;
  try{
   if(!Enum.IsDefined(typeof(ActivationProgressStage),stage) || elapsedMilliseconds<0 || previousWriteFailures<0)return false;
   string status=stage==ActivationProgressStage.ObservationCompleted?"Finished":"InProgress";
   string json="{\"Schema\":\"PowerShellProfile.WindowsActivationProgress.v1\",\"Status\":\""+status+"\",\"DiagnosticOnly\":true,\"Phase\":\""+stage.ToString()+"\",\"UpdatedUtc\":\""+DateTime.UtcNow.ToString("o",System.Globalization.CultureInfo.InvariantCulture)+"\",\"ElapsedMilliseconds\":"+elapsedMilliseconds.ToString(System.Globalization.CultureInfo.InvariantCulture)+",\"HResult\":"+(error.HasValue?error.Value.ToString(System.Globalization.CultureInfo.InvariantCulture):"null")+",\"RootProcessId\":"+rootProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture)+",\"ActivationManagerCreated\":"+(managerCreated?"true":"false")+",\"IdentityVerified\":"+(identityVerified?"true":"false")+",\"PreviousWriteFailures\":"+previousWriteFailures.ToString(System.Globalization.CultureInfo.InvariantCulture)+"}";
   byte[] bytes=new UTF8Encoding(false).GetBytes(json);if(bytes.Length>8192)return false;
   if(!Directory.Exists(output) || (File.GetAttributes(output)&FileAttributes.ReparsePoint)!=0)return false;
   string destination=Path.Combine(output,"activation-progress.json");
   if(File.Exists(destination) && (File.GetAttributes(destination)&FileAttributes.ReparsePoint)!=0)return false;
   temporary=Path.Combine(output,"activation-progress."+Guid.NewGuid().ToString("N")+".tmp");
   using(FileStream stream=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)){created=true;stream.Write(bytes,0,bytes.Length);stream.Flush();}
   if(File.Exists(destination))File.Replace(temporary,destination,null);else File.Move(temporary,destination);
   created=false;return true;
  }catch{return false;}finally{if(created && temporary!=null){try{File.Delete(temporary);}catch{}}}
 }
 static void WriteActivationCheckpoint(Result result,string output,ActivationProgressStage stage,int? error,bool managerCreated,bool identityVerified,Stopwatch timer){
  if(!TryWriteActivationProgress(output,stage,error,result.RootProcessId,managerCreated,identityVerified,timer.ElapsedMilliseconds,result.ActivationProgressWriteFailures) && result.ActivationProgressWriteFailures<int.MaxValue)result.ActivationProgressWriteFailures++;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetLongPathName(string path,StringBuilder buffer,uint length);
 public static string ExpandExistingPath(string path){
  StringBuilder buffer=new StringBuilder(32768);uint length=GetLongPathName(path,buffer,(uint)buffer.Capacity);
  if(length==0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Resolve guest environment path");
  if(length>=buffer.Capacity)throw new IOException("The guest environment path exceeded its length limit.");
  return buffer.ToString();
 }
 [StructLayout(LayoutKind.Sequential)] struct Security { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup { public uint Size; public string Reserved; public string Desktop; public string Title; public uint X,Y,XSize,YSize,XChars,YChars,Fill,Flags; public ushort Show,ReservedSize; public IntPtr ReservedData,Input,Output,Error; }
 [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process,Thread; public uint ProcessId,ThreadId; }
 [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long ProcessTime,JobTime; public uint Flags; public UIntPtr MinimumWorking,MaximumWorking; public uint ActiveProcesses; public UIntPtr Affinity; public uint Priority,Scheduling; }
 [StructLayout(LayoutKind.Sequential)] struct Counters { public ulong ReadOps,WriteOps,OtherOps,ReadBytes,WriteBytes,OtherBytes; }
 [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits { public BasicLimits Basic; public Counters Io; public UIntPtr ProcessMemory,JobMemory,PeakProcessMemory,PeakJobMemory; }
 public const int MaximumObservedProcesses=128,MaximumObservedWindows=64,MaximumProcessNameCharacters=128,MaximumObservedImagePathCharacters=512,MaximumWindowTitleCharacters=256;
 public sealed class Observation { public int ProcessId; public string Name; public string ImagePath; public string FirstObservedUtc; public bool NameTruncated,ImagePathTruncated; }
 public sealed class WindowObservation { public int ProcessId; public long Handle; public string Title; public bool Visible; public int Left,Top,Width,Height; public string ObservedUtc; public bool TitleTruncated; }
 public sealed class Result { public uint RootProcessId; public uint ExitCode; public string Reason; public long DurationMilliseconds; public bool SuspendedBeforeAssignment; public bool JobAssigned; public bool JobClosed; public string RootPackageFullName; public string RootUserSid; public bool RootAdministrator; public string RootImagePath; public string Screenshot; public string ScreenshotScope; public string ScreenshotError; public int ActivationProgressWriteFailures; public bool ProcessObservationLimitReached,WindowObservationLimitReached; public List<Observation> Processes=new List<Observation>(); public List<WindowObservation> Windows=new List<WindowObservation>(); }
 static string ObservationText(string value,int maximum,out bool truncated){truncated=value!=null && value.Length>maximum;return truncated?value.Substring(0,maximum):value;}
 public static bool RecordProcessObservation(Result result,HashSet<int> seen,int id,string name,string imagePath){
  if(seen.Contains(id))return true;
  if(result.Processes.Count>=MaximumObservedProcesses){result.ProcessObservationLimitReached=true;result.Reason="ProcessInventoryLimit";return false;}
  Observation row=new Observation{ProcessId=id,FirstObservedUtc=DateTime.UtcNow.ToString("o")};
  row.Name=ObservationText(name,MaximumProcessNameCharacters,out row.NameTruncated);row.ImagePath=ObservationText(imagePath,MaximumObservedImagePathCharacters,out row.ImagePathTruncated);
  seen.Add(id);result.Processes.Add(row);return true;
 }
 public static bool RecordWindowObservation(Result result,HashSet<long> seen,int id,long handle,string title,int left,int top,int width,int height){
  if(seen.Contains(handle))return true;
  if(result.Windows.Count>=MaximumObservedWindows){result.WindowObservationLimitReached=true;result.Reason="WindowInventoryLimit";return false;}
  WindowObservation row=new WindowObservation{ProcessId=id,Handle=handle,Visible=true,Left=left,Top=top,Width=width,Height=height,ObservedUtc=DateTime.UtcNow.ToString("o")};
  row.Title=ObservationText(title,MaximumWindowTitleCharacters,out row.TitleTruncated);seen.Add(handle);result.Windows.Add(row);return true;
 }
 [StructLayout(LayoutKind.Sequential)] struct Rectangle { public int Left,Top,Right,Bottom; }
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window,out Rectangle rectangle);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint processId);
 [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window,IntPtr device,uint flags);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int id);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern int GetPackageFullName(IntPtr process,ref uint length,StringBuilder name);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder path,ref uint length);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
 public sealed class ProcessIdentityInspection { public string Sid;public bool Administrator;public bool AdministratorGroupMember; }
 public const uint ProcessIdentityTokenAccess=0x0008|0x0002; // TOKEN_QUERY | TOKEN_DUPLICATE
 public static ProcessIdentityInspection InspectProcessIdentity(IntPtr process){
  IntPtr token=IntPtr.Zero;string operation="OpenProcessToken(QUERY|DUPLICATE)";
  try{
   if(!OpenProcessToken(process,ProcessIdentityTokenAccess,out token))throw new Win32Exception(Marshal.GetLastWin32Error());
   operation="WindowsIdentity.CreateFromToken";
   using(var identity=new System.Security.Principal.WindowsIdentity(token)){
    ProcessIdentityInspection inspection=new ProcessIdentityInspection();
    operation="WindowsIdentity.User";inspection.Sid=identity.User.Value;
    // .NET Framework IsInRole duplicates primary tokens internally. QUERY alone
    // cannot satisfy DuplicateTokenEx, even for the same standard-user account.
    operation="WindowsPrincipal.IsInRole(Administrator)";
    inspection.Administrator=new System.Security.Principal.WindowsPrincipal(identity).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
    operation="WindowsIdentity.Groups";
    foreach(var group in identity.Groups){if(group.Value=="S-1-5-32-544")inspection.AdministratorGroupMember=true;}
    return inspection;
   }
  }catch(Exception failure){failure.GetBaseException().Data["Operation"]=operation;throw;}
  finally{if(token!=IntPtr.Zero)CloseHandle(token);}
 }
 [ComImport,Guid("2e941141-7f97-4756-ba1d-9decde894a3d"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface ActivationManager {
  [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)]string app,[MarshalAs(UnmanagedType.LPWStr)]string arguments,uint options,out uint processId);
  [PreserveSig] int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)]string app,IntPtr items,[MarshalAs(UnmanagedType.LPWStr)]string verb,out uint processId);
  [PreserveSig] int ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)]string app,IntPtr items,out uint processId);
 }
 static string PackageName(IntPtr process){
  uint length=0;int code=GetPackageFullName(process,ref length,null);if(code!=122 || length==0 || length>1024)return null;
  StringBuilder name=new StringBuilder((int)length);return GetPackageFullName(process,ref length,name)==0?name.ToString():null;
 }
 static bool MatchesPackage(int id,string package){IntPtr handle=OpenProcess(0x1000,false,id);if(handle==IntPtr.Zero)return false;try{return PackageName(handle)==package;}finally{CloseHandle(handle);}}
 static void SaveWindowImage(IntPtr handle,int expectedOwner,int width,int height,string output){
  int expired=0;
  var capture=System.Threading.Tasks.Task.Run(()=>{
   using(var bitmap=new System.Drawing.Bitmap(width,height))using(var graphics=System.Drawing.Graphics.FromImage(bitmap)){
    IntPtr device=graphics.GetHdc();bool captured;try{captured=PrintWindow(handle,device,2);}finally{graphics.ReleaseHdc(device);}
    if(!captured)throw new IOException("The verified target window could not be rendered for capture.");
    uint owner;GetWindowThreadProcessId(handle,out owner);
    if(owner!=(uint)expectedOwner || !IsWindowVisible(handle))throw new IOException("The screenshot window identity changed during capture.");
    if(Volatile.Read(ref expired)==0)bitmap.Save(Path.Combine(output,"window.png"),System.Drawing.Imaging.ImageFormat.Png);
   }
  });
  if(!capture.Wait(5000)){Interlocked.Exchange(ref expired,1);throw new TimeoutException("Window rendering exceeded the five-second capture deadline.");}
  capture.GetAwaiter().GetResult();
 }
 static void CaptureRegisteredWindow(Result result,string output,string package){
  foreach(WindowObservation window in result.Windows){
   IntPtr handle=new IntPtr(window.Handle);uint owner;Rectangle bounds;GetWindowThreadProcessId(handle,out owner);
   if(owner!=(uint)window.ProcessId || !MatchesPackage(window.ProcessId,package) || !IsWindowVisible(handle) || !GetWindowRect(handle,out bounds))continue;
   int width=bounds.Right-bounds.Left,height=bounds.Bottom-bounds.Top;if(width<200 || height<100 || width>1920 || height>1080)continue;
   try{SaveWindowImage(handle,window.ProcessId,width,height,output);result.Screenshot="window.png";
    result.ScreenshotScope="PrintWindow of a currently visible HWND with a reverified process package identity; pixels require visual verification.";
   }catch(Exception error){result.ScreenshotError=error.Message;}break;
  }
 }
 public static Result RunRegistered(string aumid,string package,string expectedSid,string output,int seconds){
  Result result=new Result();object instance=null;IntPtr root=IntPtr.Zero;Stopwatch timer=Stopwatch.StartNew();
  try{
   WriteActivationCheckpoint(result,output,ActivationProgressStage.BeforeActivation,null,false,false,timer);
   instance=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")));
   WriteActivationCheckpoint(result,output,ActivationProgressStage.BeforeActivation,null,true,false,timer);
   uint id=0;int error;
   try{error=((ActivationManager)instance).ActivateApplication(aumid,null,2,out id);}
   catch(Exception activationFailure){result.RootProcessId=id;WriteActivationCheckpoint(result,output,ActivationProgressStage.ActivationReturned,activationFailure.HResult,true,false,timer);throw;}
   result.RootProcessId=id;WriteActivationCheckpoint(result,output,ActivationProgressStage.ActivationReturned,error,true,false,timer);
   if(error<0){Exception failure=Marshal.GetExceptionForHR(error);failure.Data["Operation"]="IApplicationActivationManager.ActivateApplication";throw failure;}
   root=OpenProcess(0x1000,false,(int)id);Require(Valid(root),"Open activated package process");
   result.RootPackageFullName=PackageName(root);if(result.RootPackageFullName!=package)throw new InvalidOperationException("Activated process package identity differs from registered input.");
   StringBuilder image=new StringBuilder(32768);uint imageLength=(uint)image.Capacity;Require(QueryFullProcessImageName(root,0,image,ref imageLength),"Read activated process image");result.RootImagePath=image.ToString();
   ProcessIdentityInspection inspectedIdentity=InspectProcessIdentity(root);
   result.RootUserSid=inspectedIdentity.Sid;result.RootAdministrator=inspectedIdentity.Administrator;
   if(result.RootUserSid!=expectedSid || result.RootAdministrator)throw new InvalidOperationException("Activated process does not have the expected standard-user token.");
   if(inspectedIdentity.AdministratorGroupMember)throw new InvalidOperationException("Activated process has an Administrators group token.");
   WriteActivationCheckpoint(result,output,ActivationProgressStage.IdentityVerified,0,true,true,timer);
   HashSet<int> seen=new HashSet<int>();HashSet<long> windows=new HashSet<long>();result.Reason="ObservationDeadline";
   while(timer.Elapsed.TotalSeconds<seconds){
    uint exit;Require(GetExitCodeProcess(root,out exit),"Read activated process state");result.ExitCode=exit;
    int visited=0,remaining=0;foreach(Process current in Process.GetProcesses()){using(current){
     if(++visited>2000 || timer.Elapsed.TotalSeconds>=seconds || result.ProcessObservationLimitReached || result.WindowObservationLimitReached)continue;
     if(!MatchesPackage(current.Id,package))continue;
     remaining++;
     if(!seen.Contains(current.Id)){string name=null,imagePath=null;try{name=current.ProcessName;imagePath=current.MainModule.FileName;}catch{}if(!RecordProcessObservation(result,seen,current.Id,name,imagePath))continue;}
     try{IntPtr window=current.MainWindowHandle;Rectangle bounds;if(window!=IntPtr.Zero && IsWindowVisible(window) && GetWindowRect(window,out bounds)){
      RecordWindowObservation(result,windows,current.Id,window.ToInt64(),current.MainWindowTitle,bounds.Left,bounds.Top,bounds.Right-bounds.Left,bounds.Bottom-bounds.Top);
     }}catch{}
    }}
    if(result.ProcessObservationLimitReached || result.WindowObservationLimitReached)break;
    if(visited>2000){result.Reason="ProcessInventoryLimit";break;}
    if(timer.Elapsed.TotalSeconds>=seconds)break;
    if(exit!=259 && remaining==0){result.Reason="Completed";break;}
    Thread.Sleep(500);
   }
   // The observation loop has ended; the following capture remains a separate bounded operation.
   WriteActivationCheckpoint(result,output,ActivationProgressStage.ObservationCompleted,0,true,true,timer);
   if(Environment.UserInteractive && result.Reason!="Completed")CaptureRegisteredWindow(result,output,package);
   result.DurationMilliseconds=timer.ElapsedMilliseconds;return result;
  }finally{if(Valid(root))CloseHandle(root);if(instance!=null)Marshal.ReleaseComObject(instance);}
 }
 [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr security,string name);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int info,IntPtr buffer,uint length);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int info,IntPtr buffer,uint length,IntPtr returned);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint exitCode);
 [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref Startup startup,out ProcessInfo process);
 [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr CreateFile(string file,uint access,uint share,ref Security security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint exitCode);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr value,uint milliseconds);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 static void Require(bool success,string operation) {
  if(!success) { int code=Marshal.GetLastWin32Error(); var error=new Win32Exception(code); error.Data["Operation"]=operation; throw error; }
 }
 static bool Valid(IntPtr handle) { return handle!=IntPtr.Zero && handle!=new IntPtr(-1); }
 public static Result Run(string target,string directory,string output,int seconds,long processMemory,long jobMemory) {
  IntPtr job=IntPtr.Zero,stdout=IntPtr.Zero,stderr=IntPtr.Zero,stdin=IntPtr.Zero,buffer=IntPtr.Zero;
  ProcessInfo process=new ProcessInfo(); Result result=new Result(); Stopwatch timer=new Stopwatch();
  try {
   job=CreateJobObject(IntPtr.Zero,null);Require(Valid(job),"CreateJobObject");
   ExtendedLimits limits=new ExtendedLimits();limits.Basic.Flags=0x2000|0x100|0x200|0x8;limits.Basic.ActiveProcesses=32;
   limits.ProcessMemory=new UIntPtr((ulong)processMemory);limits.JobMemory=new UIntPtr((ulong)jobMemory);
   buffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ExtendedLimits)));Marshal.StructureToPtr(limits,buffer,false);
   Require(SetInformationJobObject(job,9,buffer,(uint)Marshal.SizeOf(typeof(ExtendedLimits))),"SetInformationJobObject");Marshal.FreeHGlobal(buffer);buffer=IntPtr.Zero;
   Security security=new Security();security.Length=Marshal.SizeOf(typeof(Security));security.Inherit=true;
   stdout=CreateFile(Path.Combine(output,"stdout.txt"),0x40000000,1,ref security,2,0x80,IntPtr.Zero);Require(Valid(stdout),"Create stdout");
   stderr=CreateFile(Path.Combine(output,"stderr.txt"),0x40000000,1,ref security,2,0x80,IntPtr.Zero);Require(Valid(stderr),"Create stderr");
   stdin=CreateFile("NUL",0x80000000,3,ref security,3,0x80,IntPtr.Zero);Require(Valid(stdin),"Create stdin");
   Startup startup=new Startup();startup.Size=(uint)Marshal.SizeOf(typeof(Startup));startup.Flags=0x101;startup.Show=5;startup.Input=stdin;startup.Output=stdout;startup.Error=stderr;
   Require(CreateProcess(target,new StringBuilder("\""+target+"\""),IntPtr.Zero,IntPtr.Zero,true,0x08000004,IntPtr.Zero,directory,ref startup,out process),"Create suspended target");
   result.RootProcessId=process.ProcessId;result.SuspendedBeforeAssignment=true;
   Require(AssignProcessToJobObject(job,process.Process),"Assign target before execution");result.JobAssigned=true;
   Require(ResumeThread(process.Thread)!=0xffffffff,"Resume target");timer.Start();result.Reason="Completed";
   buffer=Marshal.AllocHGlobal(8+IntPtr.Size*64);HashSet<int> seen=new HashSet<int>();HashSet<long> windows=new HashSet<long>();
   while(true) {
    Require(QueryInformationJobObject(job,3,buffer,(uint)(8+IntPtr.Size*64),IntPtr.Zero),"Query job process list");
    int count=Marshal.ReadInt32(buffer,4);
    for(int i=0;i<Math.Min(count,64);i++) {
     int id=Marshal.ReadIntPtr(buffer,8+i*IntPtr.Size).ToInt32();
     try { using(Process visible=Process.GetProcessById(id)){IntPtr window=visible.MainWindowHandle;Rectangle bounds;
      if(window!=IntPtr.Zero && IsWindowVisible(window) && GetWindowRect(window,out bounds)){
       if(!RecordWindowObservation(result,windows,id,window.ToInt64(),visible.MainWindowTitle,bounds.Left,bounds.Top,bounds.Right-bounds.Left,bounds.Bottom-bounds.Top))break;
      }
     }}catch{}
     if(seen.Contains(id))continue;
     string name=null,imagePath=null;
     try { using(Process current=Process.GetProcessById(id)){name=current.ProcessName;try{imagePath=current.MainModule.FileName;}catch{}} } catch {}
     if(!RecordProcessObservation(result,seen,id,name,imagePath))break;
    }
    if(result.ProcessObservationLimitReached || result.WindowObservationLimitReached)break;
    if(count==0)break;
    if(timer.ElapsedMilliseconds>seconds*1000L){result.Reason="Timeout";break;}
    if(new FileInfo(Path.Combine(output,"stdout.txt")).Length+new FileInfo(Path.Combine(output,"stderr.txt")).Length>8388608L){result.Reason="OutputLimit";break;}
    Thread.Sleep(100);
   }
   if(Environment.UserInteractive && result.Reason!="Completed"){
    foreach(WindowObservation window in result.Windows){
     IntPtr handle=new IntPtr(window.Handle);uint owner;Rectangle current;
     GetWindowThreadProcessId(handle,out owner);
     if(owner!=(uint)window.ProcessId || !IsWindowVisible(handle) || !GetWindowRect(handle,out current))continue;
     bool inJob=false;Require(QueryInformationJobObject(job,3,buffer,(uint)(8+IntPtr.Size*64),IntPtr.Zero),"Revalidate screenshot owner");
     for(int i=0;i<Math.Min(Marshal.ReadInt32(buffer,4),64);i++){if(Marshal.ReadIntPtr(buffer,8+i*IntPtr.Size).ToInt32()==window.ProcessId)inJob=true;}
     if(!inJob)continue;
     window.Left=current.Left;window.Top=current.Top;window.Width=current.Right-current.Left;window.Height=current.Bottom-current.Top;
     if(window.Width<200 || window.Height<100 || window.Width>1920 || window.Height>1080)continue;
     try{
      int width=window.Width,height=window.Height;
       SaveWindowImage(handle,window.ProcessId,width,height,output);result.Screenshot="window.png";
       result.ScreenshotScope="PrintWindow of a visible HWND whose process remained in the bounded job; pixels require visual verification.";
     }catch(Exception error){result.ScreenshotError=error.Message;}
     break;
    }
   }
   if(result.Reason!="Completed")Require(TerminateJobObject(job,124),"Terminate bounded job");
   WaitForSingleObject(process.Process,5000);uint exitCode;Require(GetExitCodeProcess(process.Process,out exitCode),"Get exit code");result.ExitCode=exitCode;
   result.DurationMilliseconds=timer.ElapsedMilliseconds;
  } finally {
   if(Valid(process.Process) && !result.JobAssigned)TerminateProcess(process.Process,125);
   if(Valid(job)){CloseHandle(job);result.JobClosed=true;}
   if(Valid(process.Thread))CloseHandle(process.Thread);if(Valid(process.Process))CloseHandle(process.Process);
   if(Valid(stdout))CloseHandle(stdout);if(Valid(stderr))CloseHandle(stderr);if(Valid(stdin))CloseHandle(stdin);if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);
  }
  return result;
 }
}
'@
    Write-GuestCheckpoint -Phase BeforeCompile
    Add-Type -TypeDefinition $native -Language CSharp -ReferencedAssemblies System.Drawing,System.Core
    $record.Budgets.MaximumObservedProcesses=[ProfileAnalysisGuestJob]::MaximumObservedProcesses
    $record.Budgets.MaximumObservedWindows=[ProfileAnalysisGuestJob]::MaximumObservedWindows
    $record.Budgets.MaximumProcessNameCharacters=[ProfileAnalysisGuestJob]::MaximumProcessNameCharacters
    $record.Budgets.MaximumObservedImagePathCharacters=[ProfileAnalysisGuestJob]::MaximumObservedImagePathCharacters
    $record.Budgets.MaximumWindowTitleCharacters=[ProfileAnalysisGuestJob]::MaximumWindowTitleCharacters
    $record.UserEnvironment.CanonicalUserProfile=[ProfileAnalysisGuestJob]::ExpandExistingPath($env:USERPROFILE)
    $record.UserEnvironment.CanonicalTemp=[ProfileAnalysisGuestJob]::ExpandExistingPath($env:TEMP)
    # Compile the trusted observer before the baseline so its temporary compiler
    # artifacts are not presented as changes caused by the supplied executable.
    Write-GuestCheckpoint -Phase BeforeFileInventory
    $fileBefore=Invoke-GuestInventoryWorker -Kind File -TimeoutSeconds 120
    $fileBefore|ConvertTo-Json -Depth 6 -Compress|Set-Content -LiteralPath (Join-Path $output 'files-before.json') -Encoding utf8
    $record.FileInventoryBefore=$fileBefore|Select-Object Status,Complete,ErrorCount,Truncated,ErrorsTruncated,TimeBudgetSeconds,TimeBudgetExceeded,DurationMilliseconds,DataTruncated,Worker
    Write-GuestCheckpoint -Phase BeforeRegistryInventory
    $registryBefore=Invoke-GuestInventoryWorker -Kind Registry -TimeoutSeconds 30
    $registryBefore|ConvertTo-Json -Depth 6 -Compress|Set-Content -LiteralPath (Join-Path $output 'registry-before.json') -Encoding utf8
    $record.RegistryInventoryBefore=$registryBefore|Select-Object Status,Complete,ErrorCount,Truncated,ErrorsTruncated,DataTruncated,Worker
    if($LaunchMode -eq 'RegisteredPackage'){
        if(-not $PayloadManifestSHA256 -or -not [Environment]::UserInteractive){throw 'Registered activation requires a preserved package and an interactive analysis-user session.'}
        Write-GuestCheckpoint -Phase BeforeRegisterPackage
        $registration=& 'C:\ProfileAnalysis\WindowsGuestPackage.ps1' -Mode Register -PayloadManifestSHA256 $PayloadManifestSHA256 -ExpectedPackageFullName $ExpectedPackageFullName
        if($registration.Status -ne 'Completed' -or $registration.RegisteredUserSid -ne $currentUserSid){throw 'Standard-user package registration was not verified.'}
        $record.PackageRegistration=$registration
        if([string]::IsNullOrWhiteSpace($registration.InstallLocation) -or -not [IO.Path]::IsPathRooted($registration.InstallLocation)){throw 'The registered package has no absolute installation location.'}
        $registeredRoot=[IO.Path]::GetFullPath($registration.InstallLocation).TrimEnd('\')+'\'
        $target=[IO.Path]::GetFullPath($registeredRoot+$payload.EntryPoint.Replace('/','\'))
        if(-not $target.StartsWith($registeredRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'The registered entry point escaped its Windows-managed package root.'}
        $record.RegisteredTargetPath=$target
        $record.ObservationBoundary='WholeVirtualMachine'
        $record.Limitations+='Registered activation and package services run outside the process Job. The host watchdog, offline VM resource limits and snapshot restore bound this mode; per-process Job memory limits do not apply.'
        $record.Limitations+='The before/after file and HKCU snapshots begin after machine package deployment. They exclude earlier registration changes and service startup activity, and do not trace system-wide service behavior.'
        $record.Budgets.PollingIntervalMilliseconds=500
        $record.Budgets.JobLimitsApplied=$false
        foreach($limit in 'MaximumActiveProcesses','MaximumProcessMemoryBytes','MaximumJobMemoryBytes','CombinedOutputThresholdBytes','OutputThresholdIsPolled'){$record.Budgets[$limit]=$null}
        Write-GuestCheckpoint -Phase BeforeVerifyTarget
        $record.TargetSHA256=(Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash
        if($record.TargetSHA256 -ne $ExpectedSHA256){throw 'Guest input SHA256 differs from the host snapshot.'}
        $record.Validation.HashMatched=$true
        Write-GuestCheckpoint -Phase ActivateAndObservePackage
        $record.Execution=[ProfileAnalysisGuestJob]::RunRegistered($registration.Aumid,$registration.PackageFullName,$currentUserSid,$output,$TimeoutSeconds)
        Write-GuestCheckpoint -Phase AfterRunRegistered
        $record.ActivatedImageSHA256=(Get-FileHash -LiteralPath $record.Execution.RootImagePath -Algorithm SHA256 -ErrorAction Stop).Hash
        if($record.ActivatedImageSHA256 -ne $ExpectedSHA256){throw 'Activated package image differs from the selected executable.'}
    }else{
        Write-GuestCheckpoint -Phase BeforeVerifyTarget
        $record.TargetSHA256=(Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash
        if($record.TargetSHA256 -ne $ExpectedSHA256){throw 'Guest input SHA256 differs from the host snapshot.'}
        $record.Validation.HashMatched=$true
        $record.ObservationBoundary='ProcessJobInsideOfflineVirtualMachine'
        Write-GuestCheckpoint -Phase LaunchAndObserveJob
        $record.Execution=[ProfileAnalysisGuestJob]::Run($target,[IO.Path]::GetDirectoryName($target),$output,$TimeoutSeconds,([long]$MaxProcessMemoryMB*1MB),([long]$MaxJobMemoryMB*1MB))
        Write-GuestCheckpoint -Phase AfterRunJob
    }
    $record.TargetOutcome=if($record.Execution.Reason -eq 'ObservationDeadline'){'RunningAtObservationLimit'}elseif($LaunchMode -eq 'RegisteredPackage' -and $record.Execution.Reason -ne 'Completed'){'ObservationIncomplete'}elseif($record.Execution.Reason -ne 'Completed'){'StoppedAtObservationLimit'}elseif($record.Execution.ExitCode -eq 0){'ExitedSuccessfully'}else{'ExitedWithError'}
    $record.Status=if($record.TargetOutcome -eq 'ExitedSuccessfully'){'Completed'}else{'Partial'}
    if($record.TargetOutcome -eq 'ExitedWithError'){$record.Limitations+=('The target exited with nonzero code '+$record.Execution.ExitCode+'; observation completion is not successful application startup.')}
} catch {
    $failure=$_;$record.Status='Failed'
    $message=[string]$failure.Exception.Message;$record.Error=$message.Substring(0,[Math]::Min(4096,$message.Length))
    $record.ErrorDetails=Get-GuestExceptionDetail -Exception $failure.Exception
    foreach($field in 'Message','WrapperMessage','NativeErrorMessage','Operation'){
        $detail=[string]$record.ErrorDetails.$field
        $record.ErrorDetails.$field=$detail.Substring(0,[Math]::Min(4096,$detail.Length))
    }
    # Deliberately exclude source lines, bound parameters and TargetObject, which
    # could contain command arguments or credential-bearing objects.
    $trace=[string]$failure.ScriptStackTrace;$identifier=[string]$failure.FullyQualifiedErrorId;$targetName=[string]$failure.CategoryInfo.TargetName
    $record.ErrorContext=[ordered]@{ScriptLineNumber=$failure.InvocationInfo.ScriptLineNumber;ScriptStackTrace=$trace.Substring(0,[Math]::Min(4096,$trace.Length));FullyQualifiedErrorId=$identifier.Substring(0,[Math]::Min(1024,$identifier.Length));TargetName=$targetName.Substring(0,[Math]::Min(1024,$targetName.Length))}
}
finally {
    $runtimeReportWritten=$false
    try{
        Write-GuestCheckpoint -Phase BeforePostTargetVerification
        try{$record.TargetUnchanged=(Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash -eq $ExpectedSHA256}catch{$record.TargetUnchanged=$false}
        Write-GuestCheckpoint -Phase BeforePostFileInventory
        try{
            $fileAfter=Invoke-GuestInventoryWorker -Kind File -TimeoutSeconds 120
            $fileAfter|ConvertTo-Json -Depth 6 -Compress|Set-Content -LiteralPath (Join-Path $output 'files-after.json') -Encoding utf8
            $record.FileInventoryAfter=$fileAfter|Select-Object Status,Complete,ErrorCount,Truncated,ErrorsTruncated,TimeBudgetSeconds,TimeBudgetExceeded,DurationMilliseconds,DataTruncated,Worker
        }catch{$record.FileInventoryAfter=@{Status='Failed';Complete=$false};$record.Limitations+=('Post-run file inventory failed: '+$_.Exception.Message)}
        if($record.FileInventoryBefore.Complete -ne $true -or $record.FileInventoryAfter.Complete -ne $true){
            $record.Limitations+='File snapshots are incomplete; the retained inventory records describe available coverage, read failures and elapsed-time quotas.'
            if($record.Status -eq 'Completed'){$record.Status='Partial'}
        }
        Write-GuestCheckpoint -Phase BeforePostRegistryInventory
        try{
            $registryAfter=Invoke-GuestInventoryWorker -Kind Registry -TimeoutSeconds 30
            $registryAfter|ConvertTo-Json -Depth 6 -Compress|Set-Content -LiteralPath (Join-Path $output 'registry-after.json') -Encoding utf8
            $record.RegistryInventoryAfter=$registryAfter|Select-Object Status,Complete,ErrorCount,Truncated,ErrorsTruncated,DataTruncated,Worker
        }catch{$record.RegistryInventoryAfter=@{Status='Failed';Complete=$false;ErrorCount=1};$record.Limitations+=('Post-run registry inventory failed: '+$_.Exception.Message)}
        Write-GuestCheckpoint -Phase BeforePostNetworkInventory
        try{
            $networkAfter=Invoke-GuestInventoryWorker -Kind Network -TimeoutSeconds 30
            $networkAfter|ConvertTo-Json -Depth 6 -Compress|Set-Content -LiteralPath (Join-Path $output 'network-after.json') -Encoding utf8
            $record.NetworkInventoryAfter=$networkAfter|Select-Object Status,Complete,Truncated,ErrorCount,Worker
        }catch{$record.NetworkInventoryAfter=@{Status='Failed';Complete=$false};$record.Limitations+=('Post-run connection inventory failed: '+$_.Exception.Message)}
        if($record.RegistryInventoryBefore.Complete -ne $true -or $record.RegistryInventoryAfter.Complete -ne $true -or $record.NetworkInventoryBefore.Complete -ne $true -or $record.NetworkInventoryAfter.Complete -ne $true){
            $record.Limitations+='Registry or connection snapshots are incomplete; worker deadlines and retained rows describe available coverage.'
            if($record.Status -eq 'Completed'){$record.Status='Partial'}
        }
        $record.InventoryWorkerState=Get-GuestInventoryWorkerState
        $record.FinishedUtc=[DateTime]::UtcNow.ToString('o')
        Write-GuestCheckpoint -Phase BeforeSaveReport
        $record|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $output 'runtime.json') -Encoding utf8
        $runtimeReportWritten=$true
        Write-GuestCheckpoint -Phase FinalSavedReport -Finished
        Write-Output ('PROFILE_ANALYSIS_RUNTIME='+$record.Status)
    }finally{
        # These workers belong only to this controller-created process. A blocked
        # native call must not prevent process exit after the final file is closed.
        $workerExitState=Get-GuestInventoryWorkerState
        if($OwnedRunner -and $workerExitState.RetainedCount -gt 0){
            [Console]::Out.Flush();[Console]::Error.Flush()
            [Environment]::Exit($(if($runtimeReportWritten){0}else{1}))
        }
    }
}
