# All event APIs below are fixtures. No host event channel is queried or changed.
#requires -Version 5.1
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Throws([scriptblock]$Body,[string]$Pattern){try{& $Body;throw 'Expected exception'}catch{if($_.Exception.Message -notmatch $Pattern){throw}}}
$script:fixtureCalls=[Collections.Generic.List[object]]::new()
$script:channels=@('Microsoft-Windows-AppModel-Runtime/Admin','Microsoft-Windows-TWinUI/Operational','Microsoft-Windows-AppXDeploymentServer/Operational','Microsoft-Windows-Store/Operational','Application','System')
$script:fullName='Known.RuntimeFixture_1.2.3.4_x64__0123456789abc'
$script:familyName='Known.RuntimeFixture_0123456789abc'
function New-ActivationFixtureEvent {
    param([int]$Index,[switch]$MaximumText)
    $message=if($MaximumText){'M'*5000}else{'Unrelated time-window event.'}
    $xml=if($MaximumText){'X'*9000}else{'<Event><Data>Unrelated context</Data></Event>'}
    if(-not $MaximumText){
        switch($Index){
            0 {$message='Activation for '+$script:fullName+' and '+$script:familyName+'.';$xml='<Event />'}
            1 {$message='Activation '+$script:familyName+'!Main.App';$xml='<Event />'}
            2 {$message=$script:fullName+'_unrelated_suffix';$xml='<Event />'}
            3 {$message='Prefix'+$script:fullName;$xml='<Event />'}
            4 {$message=('M'*5000)+$script:fullName;$xml='<Event />'}
            5 {$message='Identity is in XML.';$xml='<Event><Data Name="PackageFullName">'+$script:fullName+'</Data></Event>'}
            6 {$message=$script:fullName;$xml='ThrowXml'}
        }
    }
    $event=[pscustomobject]@{Id=$Index;RecordId=1000+$Index;ProviderName=('P'*300);LevelDisplayName=('L'*200);TimeCreated=$script:expectedStart.AddSeconds(1);ActivityId=[guid]'12345678-1234-1234-1234-123456789abc';Message=$message;FixtureXml=$xml;CredentialMarker='MUST-NOT-SERIALIZE-EVENT-OBJECT'}
    $event|Add-Member ScriptMethod ToXml {if($this.FixtureXml -eq 'ThrowXml'){throw [Runtime.InteropServices.COMException]::new(('Known XML failure '+('E'*3000)),-2147024891)};return $this.FixtureXml}
    return $event
}
function Get-WinEvent {
    [CmdletBinding()]
    param([string]$ListLog,[hashtable]$FilterHashtable,[int]$MaxEvents)
    $isMetadata=$PSBoundParameters.ContainsKey('ListLog')
    $name=if($isMetadata){$ListLog}else{$FilterHashtable.LogName}
    Assert-True ($name -cin $script:channels -and $PSBoundParameters.ErrorAction -eq 'Stop') 'The collector queried an unapproved channel or lost terminating errors.'
    $script:fixtureCalls.Add([pscustomobject]@{LogName=$name;Metadata=$isMetadata;MaxEvents=$MaxEvents})
    $index=[array]::IndexOf($script:channels,$name)
    if($isMetadata){
        if($script:fixtureCase -eq 'unavailable' -or ($script:fixtureCase -eq 'mixed' -and $index -eq 2)){
            $cause=[Runtime.InteropServices.COMException]::new(('Known unavailable channel '+('U'*3000)),-2147024894)
            $cause.Data['CredentialMarker']='MUST-NOT-SERIALIZE-ERROR-DATA'
            $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new($cause,'FixtureUnavailable',[Management.Automation.ErrorCategory]::ObjectNotFound,'MUST-NOT-SERIALIZE-ERROR-TARGET'))
        }
        if($script:fixtureCase -eq 'missing-metadata'){return}
        if($script:fixtureCase -eq 'ambiguous-metadata'){return @([pscustomobject]@{IsEnabled=$true},[pscustomobject]@{IsEnabled=$true})}
        if($script:fixtureCase -eq 'disabled' -or ($script:fixtureCase -eq 'mixed' -and $index -eq 1)){return [pscustomobject]@{IsEnabled=$false}}
        if($script:fixtureCase -eq 'unknown-enabled' -or ($script:fixtureCase -eq 'mixed' -and $index -eq 3)){return [pscustomobject]@{IsEnabled=$null}}
        return [pscustomobject]@{IsEnabled=$true}
    }
    Assert-True ($FilterHashtable.Count -eq 3 -and $FilterHashtable.StartTime.Kind -eq [DateTimeKind]::Local -and $FilterHashtable.EndTime.Kind -eq [DateTimeKind]::Local -and $FilterHashtable.StartTime.ToUniversalTime() -eq $script:expectedStart -and $FilterHashtable.EndTime.ToUniversalTime() -ge $script:expectedStart -and $FilterHashtable.EndTime.ToUniversalTime() -le [datetime]::UtcNow -and $MaxEvents -eq 32) 'The collector lost its local-kind native query, equivalent UTC time window, or event-count cap.'
    if($script:fixtureCase -eq 'no-events' -or ($script:fixtureCase -eq 'mixed' -and $index -eq 3)){
        if($index%2 -eq 0){return}
        $cause=[InvalidOperationException]::new('Known no matching events.')
        $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new($cause,'NoMatchingEventsFound',[Management.Automation.ErrorCategory]::ObjectNotFound,$null))
    }
    if($script:fixtureCase -eq 'mixed' -and $index -eq 4){
        $cause=[Runtime.InteropServices.COMException]::new(('Known event read denied '+('D'*3000)),-2147024891)
        $cause.Data['Unrelated']='MUST-NOT-SERIALIZE-ERROR-DATA'
        $PSCmdlet.ThrowTerminatingError([Management.Automation.ErrorRecord]::new($cause,'FixtureReadDenied',[Management.Automation.ErrorCategory]::PermissionDenied,'MUST-NOT-SERIALIZE-ERROR-TARGET'))
    }
    foreach($item in 0..39){New-ActivationFixtureEvent -Index $item -MaximumText:($script:fixtureCase -eq 'caps')}
}

$helper=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestActivationDiagnostics.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) 'The activation diagnostic asset does not parse.'
. $helper
Assert-True ($script:fixtureCalls.Count -eq 0) 'Loading the function-only asset queried an event channel.'
$script:expectedStart=[datetime]::UtcNow.AddMinutes(-1)
$parameters=@{PackageFullName=$script:fullName;PackageFamilyName=$script:familyName;StartedUtc=$script:expectedStart}
foreach($invalidTime in ([datetime]::UtcNow.AddMinutes(-31)),([datetime]::UtcNow.AddMinutes(1))){
    $badParameters=$parameters.Clone();$badParameters.StartedUtc=$invalidTime
    Assert-Throws {Get-AnalysisWindowsActivationDiagnostic @badParameters} 'past start time no more than 30 minutes'
}
$badParameters=$parameters.Clone();$badParameters.PackageFamilyName='Different.Package_0123456789abc'
Assert-Throws {Get-AnalysisWindowsActivationDiagnostic @badParameters} 'identities|identity and family'
Assert-True ($script:fixtureCalls.Count -eq 0) 'Invalid input reached the event APIs.'

$script:fixtureCase='mixed'
$result=Get-AnalysisWindowsActivationDiagnostic @parameters
Assert-True ($result.Schema -ceq 'PowerShellProfile.WindowsActivationDiagnostics.v1' -and $result.Status -ceq 'Partial' -and $result.Channels.Count -eq 6) 'Mixed channel availability was not retained.'
Assert-True ($result.StartedUtc -ceq $script:expectedStart.ToString('o') -and $result.QueryDateTimeKind -ceq 'Local' -and $result.QueryTimeZone -ceq [TimeZoneInfo]::Local.Id) 'Local native query semantics changed the retained UTC time bounds or lost time-zone evidence.'
$enabled=$result.Channels[0];$disabled=$result.Channels[1];$unavailable=$result.Channels[2];$unknown=$result.Channels[3];$failed=$result.Channels[4]
Assert-True ($enabled.Enabled -is [bool] -and $enabled.Enabled -and $enabled.ReadStatus -ceq 'Completed' -and $enabled.EventCount -eq 32) 'Enabled channel collection exceeded its bound or lost status.'
Assert-True ($disabled.Enabled -is [bool] -and -not $disabled.Enabled -and $disabled.EnabledStatus -ceq 'Disabled' -and $disabled.ReadStatus -ceq 'NotAttempted' -and @($script:fixtureCalls|Where-Object {$_.LogName -eq $disabled.LogName -and -not $_.Metadata}).Count -eq 0) 'A disabled channel was read or enabled.'
Assert-True ($unavailable.Availability -ceq 'Unavailable' -and $null -eq $unavailable.Enabled -and $unavailable.ReadStatus -ceq 'NotAttempted' -and $unavailable.Error.HResult -eq -2147024894 -and $unavailable.Error.Message.Length -eq 2048 -and $unavailable.Error.MessageTruncated) 'Unavailable-channel native evidence was lost or unbounded.'
Assert-True ($null -eq $unknown.Enabled -and $unknown.EnabledStatus -ceq 'Unknown' -and $unknown.ReadStatus -ceq 'NoEvents') 'Unknown enabled status was falsely asserted or benign no-events was treated as failure.'
Assert-True ($failed.ReadStatus -ceq 'Failed' -and $failed.Error.HResult -eq -2147024891 -and $failed.Error.Message.Length -eq 2048 -and $failed.Error.MessageTruncated) 'Read failure lost its original native HRESULT or text bound.'
Assert-True ($enabled.Events[0].Attribution -ceq 'PackageIdentityMatched' -and 'PackageFullName' -cin $enabled.Events[0].IdentityMatches) 'Exact full-name identity was not classified.'
Assert-True ($enabled.Events[1].Attribution -ceq 'PackageIdentityMatched' -and $enabled.Events[1].IdentityMatches.Count -eq 1 -and $enabled.Events[1].IdentityMatches[0] -ceq 'PackageFamilyName') 'A family AUMID was not classified independently.'
foreach($index in 2,3,4){Assert-True ($enabled.Events[$index].Attribution -ceq 'TimeWindowContext' -and $enabled.Events[$index].IdentityMatches.Count -eq 0) 'An unrelated prefix/suffix or discarded identity was attributed to the package.'}
Assert-True ($enabled.Events[5].Attribution -ceq 'PackageIdentityMatched' -and $enabled.Events[5].IdentityMatches[0] -ceq 'PackageFullName') 'Retained XML identity evidence was ignored.'
Assert-True ($enabled.Events[6].Error.HResult -eq -2147024891 -and $enabled.Events[6].Error.Message.Length -eq 2048 -and $enabled.Events[6].Error.MessageTruncated -and $enabled.Events[6].Attribution -ceq 'PackageIdentityMatched') 'An XML reader failure hid its native cause or erased retained message identity.'
Assert-True ($enabled.IdentityMatchCount -eq 4 -and $enabled.TimeWindowContextCount -eq 28) 'Identity and time-only context counts do not cover the retained events.'
$json=$result|ConvertTo-Json -Depth 8
Assert-True (-not $json.Contains('MUST-NOT-SERIALIZE') -and -not $json.Contains('InvocationInfo') -and -not $json.Contains('SourceLine') -and -not $json.Contains('FixtureXml')) 'The report leaked an event object, exception Data, or invocation context.'
[IO.File]::WriteAllText((Join-Path $TestRoot 'mixed-channel-fixture.json'),$json,[Text.UTF8Encoding]::new($false))

foreach($case in 'no-events','disabled','unavailable','missing-metadata','ambiguous-metadata','unknown-enabled','caps'){
    $script:fixtureCase=$case;$script:fixtureCalls.Clear()
    $result=Get-AnalysisWindowsActivationDiagnostic @parameters
    Assert-True ($result.Channels.Count -eq 6) 'A channel result was dropped.'
    switch($case){
        'no-events' {Assert-True ($result.Status -ceq 'Completed' -and @($result.Channels|Where-Object {$_.ReadStatus -cne 'NoEvents' -or $_.EventCount -ne 0 -or $_.EventLimitReached -or $null -ne $_.Error}).Count -eq 0) 'Empty results and native no-match errors differ incorrectly.'}
        'disabled' {Assert-True (@($script:fixtureCalls|Where-Object {-not $_.Metadata}).Count -eq 0 -and @($result.Channels|Where-Object {$_.EnabledStatus -cne 'Disabled'}).Count -eq 0) 'Disabled channels were queried or lost their status.'}
        {$_ -in 'unavailable','missing-metadata','ambiguous-metadata'} {Assert-True ($result.Status -ceq 'Partial' -and @($script:fixtureCalls|Where-Object {-not $_.Metadata}).Count -eq 0 -and @($result.Channels|Where-Object {$_.Availability -cne 'Unavailable' -or -not $_.Error}).Count -eq 0) 'Missing/ambiguous/unavailable metadata was silently accepted.'}
        'unknown-enabled' {Assert-True (@($result.Channels|Where-Object {$null -ne $_.Enabled -or $_.EnabledStatus -cne 'Unknown' -or $_.EventCount -ne 32}).Count -eq 0) 'Unknown channel state was invented or prevented a read-only query.'}
        'caps' {
            Assert-True ($result.Status -ceq 'Completed') 'Bounded fixture events unexpectedly failed.'
            foreach($channel in $result.Channels){
                Assert-True ($channel.EventCount -eq 32 -and $channel.EventLimitReached -is [bool] -and $channel.EventLimitReached) 'Maximum event count or conservative limit-reached evidence was not retained independently per channel.'
                foreach($event in $channel.Events){Assert-True ($event.Message.Length -eq 4096 -and $event.MessageTruncated -and $event.Xml.Length -eq 8192 -and $event.XmlTruncated -and $event.ProviderName.Length -eq 256 -and $event.Level.Length -eq 128 -and $event.Attribution -ceq 'TimeWindowContext') 'A retained event text limit or neutral attribution changed.'}
            }
            Assert-True (($result|ConvertTo-Json -Depth 8).Length -lt 3MB) 'The fixed six-channel result exceeded its overall serialization bound.'
        }
    }
}
& {
    # Run the real controller catch/finally only. Its one fixed asset import is
    # replaced with a comment after checking its AST; every external call is fake.
    $controllerPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestController.ps1'
    $controllerAst=[Management.Automation.Language.Parser]::ParseFile($controllerPath,[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) 'The controller does not parse.'
    $entry=@($controllerAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Finally})
    Assert-True ($entry.Count -eq 1 -and $entry[0].CatchClauses.Count -eq 1) 'The controller catch/finally contract changed.'
    $imports=@($entry[0].Finally.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot},$true))
    Assert-True ($imports.Count -eq 1 -and $imports[0].GetCommandName() -ceq 'C:\ProfileAnalysis\Private\WindowsGuestActivationDiagnostics.ps1') 'The controller diagnostic import is not its fixed trusted private asset.'
    $finallySource=$entry[0].Finally.Extent.Text.Replace($imports[0].Extent.Text,'# Trusted import verified; use the fake collector below.')
    $controllerCleanup=[scriptblock]::Create('try { if($primaryExpected){throw $launchFailure} } '+$entry[0].CatchClauses[0].Extent.Text+' finally '+$finallySource)
    $launchFailure=[Runtime.InteropServices.COMException]::new('Known primary activation failure.',-2147023665)
    $collectorFailure=[Runtime.InteropServices.COMException]::new(('Known collector failure '+('C'*3000)),-2147024891)
    $writeFailure=[Runtime.InteropServices.COMException]::new(('Known private artifact write failure '+('W'*3000)),-2147024784)
    function Get-AnalysisWindowsActivationDiagnostic {
        param([string]$PackageFullName,[string]$PackageFamilyName,[datetime]$StartedUtc)
        $state.CollectorCalls++
        Assert-True ($PackageFullName -ceq $script:fullName -and $PackageFamilyName -ceq $script:familyName -and $StartedUtc.ToUniversalTime() -eq $script:expectedStart) 'Controller diagnostics received a changed package identity or start time.'
        if($state.Case -in 'collector-failure','collector-and-write-failure'){throw $collectorFailure}
        [pscustomobject]@{Status='Partial';Channels=@(1..6|ForEach-Object {[pscustomobject]@{Events=@([pscustomobject]@{Message=('Fixture detail '+('M'*12000))})}});FixtureDetail='PRIVATE-EVENT-DETAIL-ONLY'}
    }
    function Set-Content {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline)][string]$Value,[string]$LiteralPath,[string]$Encoding)
        process{
            Assert-True ($LiteralPath -cin @('C:\ProfileAnalysis\Private\activation-events.json','C:\ProfileAnalysis\Private\controller.json') -and $Encoding -eq 'utf8') 'Controller diagnostics wrote outside the exact private artifact paths.'
            if($LiteralPath -eq 'C:\ProfileAnalysis\Private\activation-events.json'){
                $state.ArtifactAttempts++
                if($state.Case -in 'artifact-write-failure','collector-and-write-failure'){throw $writeFailure}
            }
            $state.Writes.Add([pscustomobject]@{Path=$LiteralPath;Text=$Value})
        }
    }
    function Test-Path {param([string]$LiteralPath);Assert-True ($LiteralPath -ceq $configurationPath) 'Cleanup inspected an unrelated path.';return $state.CredentialExists}
    function Remove-Item {param([string]$LiteralPath,[switch]$Force);Assert-True ($LiteralPath -ceq $configurationPath -and $Force) 'Cleanup removed an unrelated path.';$state.CredentialExists=$false;$state.CredentialRemovals++}
    foreach($case in 'registered-primary','registered-success','nonregistered','pre-run','stage-failed','collector-failure','artifact-write-failure','collector-and-write-failure','cleanup-stop-failure'){
        $state=@{Case=$case;CollectorCalls=0;ArtifactAttempts=0;Writes=[Collections.Generic.List[object]]::new();TaskExists=$true;Stops=0;Deletes=0;CredentialExists=$true;CredentialRemovals=0}
        $primaryExpected=$case -ne 'registered-success'
        $configuration=[pscustomobject]@{LaunchMode=if($case -eq 'nonregistered'){'DesktopLayout'}else{'RegisteredPackage'}}
        $configurationPath='C:\ProfileAnalysis\Private\launch.json';$taskName='PowerShellProfile-ExecutableAnalysis';$taskCreated=$true
        $observation=[ordered]@{Status='Failed';Phases=@();Error=$null;HResult=$null;RunnerStarted=($case -ne 'pre-run');RunnerExitCode=if($primaryExpected){1}else{0};TaskRemoved=$false;PackageDeployment=[pscustomobject]@{Status=if($case -eq 'stage-failed'){'Failed'}else{'Completed'};PackageFullName=$script:fullName;PackageFamilyName=$script:familyName;FinishedUtc=$script:expectedStart.ToString('o')}}
        $task=[pscustomobject]@{Name=$taskName}
        $task|Add-Member ScriptMethod Stop {param($Flags);Assert-True ($Flags -eq 0) 'Task cleanup used unexpected flags.';$state.Stops++;if($state.Case -eq 'cleanup-stop-failure'){throw [Runtime.InteropServices.COMException]::new('Known stop failure.',-2147024891)}}
        $folder=[pscustomobject]@{}
        $folder|Add-Member ScriptMethod GetTask {param($Name);Assert-True ($Name -ceq $taskName) 'Cleanup selected another task.';return $task}
        $folder|Add-Member ScriptMethod DeleteTask {param($Name,$Flags);Assert-True ($Name -ceq $taskName -and $Flags -eq 0) 'Cleanup deleted another task.';$state.TaskExists=$false;$state.Deletes++}
        $folder|Add-Member ScriptMethod GetTasks {param($Flags);Assert-True ($Flags -eq 1) 'Cleanup did not include hidden tasks.';if($state.TaskExists){return $task}}
        $caught=$null
        try{& $controllerCleanup}catch{$caught=$_.Exception.GetBaseException()}
        Assert-True ($state.Stops -eq 1 -and $state.Deletes -eq 1 -and -not $state.TaskExists -and $observation.TaskRemoved -and -not $state.CredentialExists -and $state.CredentialRemovals -eq 1) ('Diagnostics interrupted owned task or private credential cleanup: '+$case)
        if($primaryExpected){Assert-True ([object]::ReferenceEquals($caught,$launchFailure) -and $observation.Error -ceq $launchFailure.Message -and $observation.HResult -eq $launchFailure.HResult -and $observation.Status -ceq 'Failed') ('Secondary work replaced the original launch error: '+$case)}
        else{Assert-True ($null -eq $caught -and $null -eq $observation.Error -and $observation.Status -ceq 'Completed') 'Optional partial diagnostics changed a successful controller result.'}
        $controllerWrites=@($state.Writes|Where-Object Path -EQ 'C:\ProfileAnalysis\Private\controller.json')
        Assert-True ($controllerWrites.Count -eq 1 -and $controllerWrites[0].Text.Length -lt 8192 -and -not $controllerWrites[0].Text.Contains('PRIVATE-EVENT-DETAIL-ONLY') -and -not $controllerWrites[0].Text.Contains('Fixture detail')) 'Controller summary embedded event details or lost its final report.'
        if($case -in 'nonregistered','pre-run','stage-failed'){
            Assert-True ($state.CollectorCalls -eq 0 -and $state.ArtifactAttempts -eq 0 -and -not $observation.Contains('ActivationDiagnostics')) ('An ineligible run collected activation diagnostics: '+$case)
        }else{
            Assert-True ($state.CollectorCalls -eq 1) 'Eligible activation diagnostics were not collected exactly once.'
            if($case -in 'collector-failure','artifact-write-failure','collector-and-write-failure'){
                $expectedDiagnosticCause=if($case -eq 'artifact-write-failure'){$writeFailure}else{$collectorFailure}
                Assert-True ($observation.ActivationDiagnostics.Status -ceq 'Failed' -and $observation.ActivationDiagnostics.Error -ceq $expectedDiagnosticCause.Message.Substring(0,2048) -and $observation.ActivationDiagnostics.HResult -eq $expectedDiagnosticCause.HResult) 'Controller diagnostics lost their bounded separate failure.'
                if($case -in 'artifact-write-failure','collector-and-write-failure'){Assert-True ($observation.ActivationDiagnostics.ArtifactWriteHResult -eq $writeFailure.HResult) 'Fallback artifact write failure was concealed.'}
                if($case -eq 'artifact-write-failure'){Assert-True ($state.ArtifactAttempts -eq 2) 'Initial and fallback artifact writes were not independently attempted.'}
            }else{
                Assert-True ($observation.ActivationDiagnostics.Count -eq 3 -and $observation.ActivationDiagnostics.Status -ceq 'Partial' -and $observation.ActivationDiagnostics.Artifact -ceq 'activation-events.json' -and $observation.ActivationDiagnostics.Channels -eq 6) ('Controller did not retain only the small diagnostic summary: '+$case+' '+($observation.ActivationDiagnostics|ConvertTo-Json -Compress))
                $artifactWrites=@($state.Writes|Where-Object Path -EQ 'C:\ProfileAnalysis\Private\activation-events.json')
                Assert-True ($artifactWrites.Count -eq 1 -and $artifactWrites[0].Text.Contains('PRIVATE-EVENT-DETAIL-ONLY') -and $artifactWrites[0].Text.Length -gt 64000) 'Detailed diagnostic evidence was not separated into its exact private artifact.'
            }
        }
    }
    Write-Output 'PASS: real controller catch/finally clauses use exact activation identity/time and private evidence, skip ineligible runs, retain a small summary, and preserve primary failures plus task/credential cleanup when collection or writes fail.'
}
Write-Output ('PASS: PowerShell '+$PSVersionTable.PSVersion+' fake-only activation diagnostics retain six channel states, exact time/count/text bounds, native failures and explicit package identity versus time-window context without host event access.')
