#requires -Version 5.1
# Extract trusted functions only. No runner entry point, target, VM or registry API is invoked.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
Import-Module Microsoft.PowerShell.Management,Microsoft.PowerShell.Utility -ErrorAction Stop
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$TestRoot=(Get-Item -LiteralPath $TestRoot).FullName
function Assert-Inventory([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$asset=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestRunner.ps1'
$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($asset,[ref]$null,[ref]$parseErrors)
Assert-Inventory ($parseErrors.Count -eq 0) 'The trusted runner does not parse.'
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GuestFileInventory'},$true)
Assert-Inventory ($null -ne $definition) 'The trusted file inventory helper is missing.'
. ([scriptblock]::Create($definition.Extent.Text))
$knownHash='2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824'
$fixtureRoot=Join-Path $TestRoot 'known-files';$null=[IO.Directory]::CreateDirectory($fixtureRoot)
$knownPath=Join-Path $fixtureRoot 'known bytes [1].txt'
[IO.File]::WriteAllBytes($knownPath,[Text.Encoding]::ASCII.GetBytes('hello'))
$actual=Get-GuestFileInventory -Root $fixtureRoot
Assert-Inventory ($actual.Status -ceq 'Completed' -and $actual.Complete -and -not $actual.Truncated -and -not $actual.TimeBudgetExceeded -and $actual.TimeBudgetSeconds -eq 120 -and $actual.DurationMilliseconds -is [long] -and $actual.DurationMilliseconds -ge 0) 'A complete real-file inventory lost its fixed cooperative time budget or duration.'
Assert-Inventory ($actual.Files.Count -eq 1 -and $actual.Files[0].Path -ceq $knownPath -and $actual.Files[0].Bytes -eq 5 -and $actual.Files[0].SHA256 -ceq $knownHash -and $actual.ErrorCount -eq 0) 'A complete real-file inventory changed known bytes, names or hash coverage.'

# Replace only the monotonic clock construction in the extracted helper. Reader
# fixtures advance that clock deterministically; no sleeps or slow real I/O occur.
& {
    $clockExpression='[Diagnostics.Stopwatch]::StartNew()'
    Assert-Inventory ([regex]::Matches($definition.Extent.Text,[regex]::Escape($clockExpression)).Count -eq 1) 'The inventory clock boundary changed.'
    $controlled=$definition.Extent.Text.Replace($clockExpression,'(New-FixtureInventoryClock)')
    . ([scriptblock]::Create($controlled))
    $rootPath='C:\InventoryFixture\Root'
    $knownTime=[datetime]'2026-01-02T03:04:05Z'
    function New-FixtureInventoryClock {
        $captured=$state
        $clock=[pscustomobject]@{}
        $clock|Add-Member ScriptProperty ElapsedMilliseconds {$captured.Milliseconds}.GetNewClosure()
        $clock|Add-Member ScriptMethod Stop {$captured.ClockStopped=$true}.GetNewClosure()
        return $clock
    }
    function Get-Item {
        [CmdletBinding()]
        param([string]$LiteralPath,[switch]$Force)
        Assert-Inventory ($LiteralPath -ceq $rootPath -and $Force) 'The inventory inspected an unrelated root.'
        $state.RootCalls++
        if($state.Case -eq 'root-slow'){$state.Milliseconds=120001L}
        if($state.Case -eq 'root-failure-slow'){$state.Milliseconds=120001L;throw [UnauthorizedAccessException]::new('Fixture root read denied.')}
        [pscustomobject]@{FullName=$rootPath;PSIsContainer=$true;Attributes=[IO.FileAttributes]::Directory}
    }
    function Get-ChildItem {
        [CmdletBinding()]
        param([string]$LiteralPath,[switch]$Force)
        Assert-Inventory ($LiteralPath -ceq $rootPath -and $Force) 'The inventory enumerated an unrelated directory.'
        $state.EnumerationCalls++
        try{
            if($state.Case -eq 'enumeration-failure-slow'){$state.Milliseconds=120001L;throw [UnauthorizedAccessException]::new('Fixture directory enumeration denied.')}
            $count=if($state.Case -eq 'entry-limit'){5001}elseif($state.Case -eq 'fast'){1}else{3}
            foreach($index in 1..$count){
                if(($state.Case -eq 'enumeration-boundary' -and $index -eq 1) -or ($state.Case -eq 'streaming-boundary' -and $index -eq 2)){$state.Milliseconds=120000L}
                $state.Emitted++
                [pscustomobject]@{FullName=($rootPath+'\file-'+$index+'.bin');PSIsContainer=$false;Attributes=[IO.FileAttributes]::Normal;Length=if($state.Case -eq 'entry-limit'){2MB}else{5};LastWriteTimeUtc=$knownTime}
            }
        }finally{$state.EnumerationDisposed=$true}
    }
    function Get-FileHash {
        [CmdletBinding()]
        param([string]$LiteralPath,[string]$Algorithm)
        Assert-Inventory ($LiteralPath.StartsWith($rootPath+'\',[StringComparison]::Ordinal) -and $Algorithm -ceq 'SHA256') 'The inventory hashed an unrelated path or changed its algorithm.'
        $state.HashCalls++
        if($state.Case -in 'hash-slow','hash-failure-slow'){$state.Milliseconds=120001L}
        if($state.Case -eq 'hash-failure-slow'){throw [UnauthorizedAccessException]::new('Fixture file hash denied.')}
        [pscustomobject]@{Hash=$knownHash}
    }
    foreach($case in 'fast','already-expired','root-slow','root-failure-slow','enumeration-boundary','streaming-boundary','hash-slow','hash-failure-slow','enumeration-failure-slow','entry-limit'){
        $state=@{Case=$case;Milliseconds=if($case -eq 'already-expired'){120000L}else{0L};RootCalls=0;EnumerationCalls=0;Emitted=0;HashCalls=0;EnumerationDisposed=$false;ClockStopped=$false}
        $result=Get-GuestFileInventory -Root $rootPath
        Assert-Inventory ($state.ClockStopped -and $result.TimeBudgetSeconds -eq 120 -and $result.DurationMilliseconds -eq $state.Milliseconds -and $result.DurationMilliseconds -is [long]) ('Inventory elapsed evidence was not retained for '+$case)
        if($case -eq 'fast'){
            Assert-Inventory ($result.Status -ceq 'Completed' -and $result.Complete -and -not $result.TimeBudgetExceeded -and $result.Files.Count -eq 1 -and $state.HashCalls -eq 1) 'A fast successful scan was falsely truncated.'
        }elseif($case -eq 'entry-limit'){
            Assert-Inventory ($result.Status -ceq 'Partial' -and -not $result.Complete -and $result.Truncated -and -not $result.TimeBudgetExceeded -and $result.Visited -eq 5000 -and $result.Files.Count -eq 5000 -and $state.Emitted -eq 5001 -and $state.HashCalls -eq 0 -and $result.ErrorCount -eq 0) 'The entry-count cap was lost or misreported as time exhaustion or a read failure.'
        }else{
            Assert-Inventory ($result.Status -ceq 'Partial' -and -not $result.Complete -and $result.Truncated -and $result.TimeBudgetExceeded) ('Expired cooperative quota was falsely complete for '+$case)
            $expectedErrors=if($case -like '*failure*'){1}else{0}
            Assert-Inventory ($result.ErrorCount -eq $expectedErrors -and $result.Errors.Count -eq $expectedErrors) 'Quota cancellation was confused with a real read failure.'
            switch($case){
                'already-expired' {Assert-Inventory ($state.RootCalls -eq 0 -and $state.EnumerationCalls -eq 0 -and $state.HashCalls -eq 0) 'An expired quota initiated filesystem operations.'}
                'root-slow' {Assert-Inventory ($state.RootCalls -eq 1 -and $state.EnumerationCalls -eq 0 -and $result.Files.Count -eq 0) 'A slow root inspection initiated later enumeration.'}
                'root-failure-slow' {Assert-Inventory ($state.EnumerationCalls -eq 0 -and $result.Errors[0].Operation -ceq 'InspectRoot') 'A slow root error was lost or followed by more reads.'}
                'enumeration-boundary' {Assert-Inventory ($state.Emitted -eq 1 -and $state.HashCalls -eq 0 -and $result.Visited -eq 0) 'The exact deadline boundary initiated hashing or continued enumeration.'}
                'streaming-boundary' {Assert-Inventory ($state.Emitted -eq 2 -and $state.HashCalls -eq 1 -and $result.Files.Count -eq 1 -and $result.Files[0].SHA256 -ceq $knownHash) 'The directory was eagerly materialized or completed evidence was lost at the deadline.'}
                'hash-slow' {Assert-Inventory ($state.Emitted -eq 1 -and $state.HashCalls -eq 1 -and $result.Files.Count -eq 1 -and $result.Files[0].SHA256 -ceq $knownHash) 'A completed slow hash was discarded or followed by more work.'}
                'hash-failure-slow' {Assert-Inventory ($state.Emitted -eq 1 -and $state.HashCalls -eq 1 -and $result.Files.Count -eq 1 -and $result.Files[0].HashError -ceq 'Fixture file hash denied.' -and $result.Errors[0].Operation -ceq 'HashFile') 'A native hash failure was masked by quota cancellation.'}
                'enumeration-failure-slow' {Assert-Inventory ($state.HashCalls -eq 0 -and $result.Errors[0].Operation -ceq 'EnumerateDirectory') 'A slow enumeration error lost its real failure or quota evidence.'}
            }
        }
        if($state.EnumerationCalls){Assert-Inventory $state.EnumerationDisposed 'Stopping inventory did not unwind its streaming directory producer.'}
        if($case -eq 'hash-slow'){$script:timedInventoryFixture=$result}
    }
}
Write-Output 'PASS: known-file hashing and deterministic elapsed-clock fixtures verify a fixed 120-second cooperative quota, streaming cancellation, entry limits, preserved completed rows and distinct native read failures without sleeps.'

# Execute the actual finalization body with inert inventory/network boundaries.
# A partial timed inventory must not erase a primary activation error or prevent
# final runtime.json; a previously complete run must become Partial instead.
$outer=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Finally})
Assert-Inventory ($outer.Count -eq 1) 'The runner finalization boundary changed.'
$finallyText=$outer[0].Finally.Extent.Text
$finalization=[scriptblock]::Create($finallyText.Substring(1,$finallyText.Length-2))
foreach($name in 'Invoke-GuestInventoryWorker','Get-GuestInventoryWorkerState'){
    $helper=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true)
    Assert-Inventory ($null -ne $helper) ('The trusted worker helper is missing: '+$name)
    $source=$helper.Extent.Text
    if($name -eq 'Invoke-GuestInventoryWorker'){$source=$source.Replace('function Invoke-GuestInventoryWorker {','function Invoke-GuestInventoryWorkerActual {')}
    . ([scriptblock]::Create($source))
}
foreach($initialStatus in 'Failed','Completed'){
    & {
        param($status)
        $target=$knownPath;$ExpectedSHA256=$knownHash
        $OwnedRunner=$false;$script:ProfileAnalysisInventoryWorkers=[Collections.Generic.List[object]]::new()
        $output=Join-Path $TestRoot ('finalization-'+$status);$null=[IO.Directory]::CreateDirectory($output)
        $record=[ordered]@{Status=$status;Error=if($status -eq 'Failed'){'Fixture primary registered-process access denied.'}else{$null};ErrorDetails=if($status -eq 'Failed'){@{HResult=-2147024891;NativeErrorCode=5;Operation='InspectRegisteredProcess'}}else{$null};FileInventoryBefore=@{Status='Completed';Complete=$true};RegistryInventoryBefore=@{Status='Completed';Complete=$true};NetworkInventoryBefore=@{Status='Completed';Complete=$true};Limitations=@()}
        $phases=New-Object 'Collections.Generic.List[string]'
        function Write-GuestCheckpoint {param([string]$Phase,[switch]$Finished)$phases.Add($Phase)}
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:timedInventoryFixture|ConvertTo-Json -Depth 6 -Compress)))
        Set-Item Function:\Get-GuestFileInventory -Value ([scriptblock]::Create('param($RecordSink,$ProgressState) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('''+$encoded+'''))|ConvertFrom-Json'))
        function Get-GuestRegistryInventory {param($RecordSink,$ProgressState)[pscustomobject]@{Status='Completed';Complete=$true;Values=@();VisitedKeys=0;Truncated=$false;Errors=@();ErrorCount=0;ErrorsTruncated=$false}}
        function Get-GuestNetworkInventory {param($RecordSink,$ProgressState)[pscustomobject]@{Status='Completed';Complete=$true;Connections=@();Truncated=$false;Errors=@();ErrorCount=0}}
        function Invoke-GuestInventoryWorker {
            param([string]$Kind,[int]$TimeoutSeconds)
            $expected=if($Kind -eq 'File'){120}else{30}
            Assert-Inventory ($Kind -in 'File','Registry','Network' -and $TimeoutSeconds -eq $expected) 'The actual finalizer changed its collection deadlines.'
            Invoke-GuestInventoryWorkerActual -Kind $Kind -TimeoutSeconds 5
        }
        $null=& $finalization
        $persisted=Get-Content -LiteralPath (Join-Path $output 'runtime.json') -Raw|ConvertFrom-Json
        Assert-Inventory ($persisted.FileInventoryAfter.Status -ceq 'Partial' -and -not $persisted.FileInventoryAfter.Complete -and $persisted.FileInventoryAfter.TimeBudgetExceeded -and $persisted.FileInventoryAfter.TimeBudgetSeconds -eq 120 -and $persisted.FileInventoryAfter.DurationMilliseconds -eq 120001 -and $persisted.TargetUnchanged -and $persisted.FinishedUtc -and $phases[-1] -ceq 'FinalSavedReport') 'Time-quota finalization lost summary coverage, target verification or final runtime persistence.'
        if($status -eq 'Failed'){
            Assert-Inventory ($persisted.Status -ceq 'Failed' -and $persisted.Error -ceq 'Fixture primary registered-process access denied.' -and $persisted.ErrorDetails.HResult -eq -2147024891 -and $persisted.ErrorDetails.NativeErrorCode -eq 5 -and $persisted.ErrorDetails.Operation -ceq 'InspectRegisteredProcess') 'Partial file inventory replaced the primary native activation error.'
        }else{Assert-Inventory ($persisted.Status -ceq 'Partial' -and -not $persisted.Error) 'An incomplete inventory was reported as a complete run or invented a target error.'}
        $files=Get-Content -LiteralPath (Join-Path $output 'files-after.json') -Raw|ConvertFrom-Json
        Assert-Inventory ($files.Files.Count -eq 1 -and $files.Files[0].SHA256 -ceq $knownHash -and $files.TimeBudgetExceeded) 'Finalization discarded independently retained partial file evidence.'
        Assert-Inventory ($files.Worker.Status -ceq 'Completed' -and -not $files.Worker.TimedOut -and $persisted.RegistryInventoryAfter.Complete -and $persisted.NetworkInventoryAfter.Complete -and $persisted.InventoryWorkerState.TotalCount -eq 3 -and $persisted.InventoryWorkerState.PendingCount -eq 0 -and $persisted.InventoryWorkerState.RetainedCount -eq 0 -and $persisted.InventoryWorkerState.TerminationMethod -ceq 'CompletedWorkersDisposed') 'Actual finalization lost completed worker disposal, confused cooperative coverage with hard timeout, or ran an unbounded provider.'
        Assert-Inventory (-not $OwnedRunner) 'The isolated finalizer fixture changed runner ownership.'
    } $initialStatus
}
Write-Output 'PASS: actual runner finalization saves partial inventory and final runtime evidence, preserves a primary native error, and marks otherwise successful incomplete observation Partial. No target, VM or registry API was invoked.'

# Evaluate the actual scheduler assignments and polling loop, without task COM
# creation or package preparation. The fake clock crosses each computed deadline
# in half-second steps and fails quickly if the loop ceases to enforce its bound.
$controllerPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestController.ps1'
$controllerErrors=$null
$controllerAst=[Management.Automation.Language.Parser]::ParseFile($controllerPath,[ref]$null,[ref]$controllerErrors)
Assert-Inventory ($controllerErrors.Count -eq 0) 'The controller does not parse.'
$assignments=@($controllerAst.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst]},$true))
$allowanceStatement=@($assignments|Where-Object {$_.Left -is [Management.Automation.Language.VariableExpressionAst] -and $_.Left.VariablePath.UserPath -ceq 'runnerPreparationAllowance'})
$evidenceStatement=@($assignments|Where-Object {$_.Left.Extent.Text -ceq '$observation.RunnerPreparationAllowanceSeconds'})
$settingsStatement=@($assignments|Where-Object {$_.Left.Extent.Text -ceq '$definition.Settings.ExecutionTimeLimit'})
Assert-Inventory ($allowanceStatement.Count -eq 1 -and $evidenceStatement.Count -eq 1 -and $settingsStatement.Count -eq 1) 'The shared scheduler allowance or its evidence assignment is missing or ambiguous.'
$loops=@($controllerAst.FindAll({param($node)$node -is [Management.Automation.Language.WhileStatementAst]},$true)|Where-Object {
    $null -ne $_.Body.Find({param($node)$node -is [Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -ceq 'runnerPreparationAllowance'},$true)
})
Assert-Inventory ($loops.Count -eq 1) 'The controller poll loop does not consume the scheduler allowance variable.'
$scheduledBudget=[scriptblock]::Create(($allowanceStatement[0].Extent.Text,$evidenceStatement[0].Extent.Text,$settingsStatement[0].Extent.Text -join "`r`n"))
$pollLoop=[scriptblock]::Create($loops[0].Extent.Text)
foreach($hasPayload in $false,$true){
    foreach($targetSeconds in 1,120,600){
        & {
            param($payloadPresent,$seconds)
            $configuration=[pscustomobject]@{TimeoutSeconds=$seconds;PayloadManifestSHA256=if($payloadPresent){'A'*64}else{$null}}
            $definition=[pscustomobject]@{Settings=[pscustomobject]@{ExecutionTimeLimit=$null}}
            $observation=[ordered]@{RunnerStarted=$true;RunnerExitCode=$null}
            . $scheduledBudget
            $expectedAllowance=if($payloadPresent){600}else{300}
            $actualScheduledSeconds=[Xml.XmlConvert]::ToTimeSpan($definition.Settings.ExecutionTimeLimit).TotalSeconds
            Assert-Inventory ($runnerPreparationAllowance -eq $expectedAllowance -and $observation.RunnerPreparationAllowanceSeconds -eq $expectedAllowance -and $actualScheduledSeconds -eq ($seconds+$expectedAllowance)) 'Actual task settings or reported preparation allowance disagree with payload600/standalone300.'
            foreach($startOffset in 0.0,0.001){
                $loopState=@{Elapsed=($actualScheduledSeconds+$startOffset);TaskReads=0;SleepCalls=0}
                $taskName='FixtureBoundedInventoryTask';$before=[datetime]'2000-01-01'
                $fakeTask=[pscustomobject]@{State=4;LastRunTime=[datetime]'2026-01-01';LastTaskResult=267009}
                $folder=[pscustomobject]@{}
                $folder|Add-Member ScriptMethod GetTask {
                    param($name)
                    if($name -cne 'FixtureBoundedInventoryTask'){throw 'Unexpected task lookup in deadline fixture.'}
                    $loopState.TaskReads++
                    return $fakeTask
                }.GetNewClosure()
                $timer=[pscustomobject]@{}
                $timer|Add-Member ScriptProperty Elapsed {[pscustomobject]@{TotalSeconds=$loopState.Elapsed}}.GetNewClosure()
                function Start-Sleep {
                    param([int]$Milliseconds)
                    Assert-Inventory ($Milliseconds -eq 500) 'Controller polling changed its half-second interval.'
                    $loopState.SleepCalls++
                    if($loopState.SleepCalls -gt 3){throw 'Fixture loop failed to enforce its deadline.'}
                    $loopState.Elapsed+=0.5
                }
                function Write-ControllerProgress {param([string]$Phase)throw ('Unexpected startup transition in an already-started fixture: '+$Phase)}
                $failure=$null
                try{& $pollLoop}catch{$failure=$_.Exception.GetBaseException()}
                $expectedSleeps=if($startOffset -eq 0){1}else{0}
                Assert-Inventory ($null -ne $failure -and $failure.Message -ceq 'The trusted guest runner exceeded its preparation, target, and observation deadline.' -and $loopState.SleepCalls -eq $expectedSleeps -and $loopState.TaskReads -eq ($expectedSleeps+1) -and $observation.RunnerStarted -and $null -eq $observation.RunnerExitCode) 'Actual polling did not enforce the same computed scheduler deadline without inventing target completion.'
            }
        } $hasPayload $targetSeconds
    }
}
Write-Output 'PASS: actual scheduler assignments and polling loops share payload600/standalone300 preparation allowances at 1, default120 and maximum600 observation seconds, including exact-boundary and expired clocks. No scheduler or deployment API was invoked.'
