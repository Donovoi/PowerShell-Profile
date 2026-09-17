#requires -Version 7.0
<#
Run with pwsh -NoProfile -File ./tests/Restart-WindowsThumbnailWorker.Behavior.ps1.
All process inspection/termination inside the tested function is mocked. No real worker is stopped.
#>
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run these behavior checks on Windows.' }
. (Join-Path $PSScriptRoot '../functions/Restart-WindowsThumbnailWorker.ps1')
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try { $script:testSid = $identity.User.Value } finally { $identity.Dispose() }
$caller = Microsoft.PowerShell.Management\Get-Process -Id $PID
try { $script:testSession = $caller.SessionId } finally { $caller.Dispose() }
$script:systemDllhost = [IO.Path]::Combine([Environment]::GetFolderPath('Windows'), 'System32', 'dllhost.exe')
$script:otherDllhost = [IO.Path]::Combine([Environment]::GetFolderPath('Windows'), 'SysWOW64', 'dllhost.exe')
$script:thumbnailGuid = '{AB8902B4-09CA-4BB6-B78D-A8F59079A8D5}'

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function New-Worker([int]$Number = 70001) {
    [pscustomobject]@{
        ProcessId = $Number; Name = 'dllhost.exe'; SessionId = $script:testSession
        ExecutablePath = $script:systemDllhost
        CommandLine = '"' + $script:systemDllhost + '" /Processid:' + $script:thumbnailGuid
        CreationDate = [datetime]'2026-01-02T03:04:05Z'
        Sid = $script:testSid; OwnerReturnValue = 0
    }
}
function Reset-Fixture {
    $script:workers = @(); $script:current = @{}; $script:stopCalls = @()
    $script:queryCalls = @(); $script:disposed = @(); $script:ownerCalls = @()
    $script:startTimeChange = $false; $script:stopFails = $false; $script:waitSucceeds = $true
}
function Set-Workers($Workers) {
    $script:workers = @($Workers)
    foreach ($worker in $script:workers) { $script:current[$worker.ProcessId] = $worker }
}
function Get-CimInstance {
    [CmdletBinding()] param($ClassName, $Filter)
    Assert-Test ($ClassName -eq 'Win32_Process') 'Only the process class may be queried.'
    $script:queryCalls += $Filter
    if ($Filter -eq "Name = 'dllhost.exe' AND SessionId = $script:testSession") { return $script:workers }
    if ($Filter -match '^ProcessId = (\d+)$') { return $script:current[[int]$Matches[1]] }
    throw "Unexpected process query: $Filter"
}
function Invoke-CimMethod {
    [CmdletBinding(SupportsShouldProcess)] param($InputObject, $MethodName)
    Assert-Test ($MethodName -eq 'GetOwnerSid') 'Only read-only owner queries are allowed.'
    Assert-Test ($PSBoundParameters.ContainsKey('WhatIf') -and -not $PSBoundParameters['WhatIf']) 'Read-only ownership verification must also run during WhatIf.'
    Assert-Test ($PSBoundParameters.ContainsKey('Confirm') -and -not $PSBoundParameters['Confirm']) 'Read-only ownership verification must not prompt.'
    $script:ownerCalls += $InputObject.ProcessId
    [pscustomobject]@{ ReturnValue = $InputObject.OwnerReturnValue; Sid = $InputObject.Sid }
}
function Get-Process {
    [CmdletBinding()] param([int]$Id)
    if ($Id -eq $PID) {
        $result = [pscustomobject]@{ SessionId = $script:testSession }
        $result | Add-Member ScriptMethod Dispose {}
        return $result
    }
    $worker = $script:current[$Id]
    Assert-Test ($null -ne $worker) 'Unexpected native process lookup.'
    $start = $worker.CreationDate
    if ($script:startTimeChange) { $start = $start.AddSeconds(1) }
    $result = [pscustomobject]@{
        Id = $Id; Handle = [intptr]42; HasExited = $false
        Path = $worker.ExecutablePath; StartTime = $start; SessionId = $worker.SessionId
    }
    $result | Add-Member ScriptMethod WaitForExit {
        param($Milliseconds)
        Assert-Test ($Milliseconds -eq 5000) 'Exit verification must be bounded.'
        return $script:waitSucceeds
    }
    $result | Add-Member ScriptMethod Dispose { $script:disposed += $this.Id }
    return $result
}
function Stop-Process {
    [CmdletBinding(SupportsShouldProcess)] param($InputObject, [switch]$Force)
    Assert-Test ($Force.IsPresent) 'Worker termination must always be forced.'
    Assert-Test ($PSBoundParameters.ContainsKey('Confirm') -and -not $PSBoundParameters['Confirm']) 'Do not prompt again inside the approved operation.'
    $script:stopCalls += $InputObject.Id
    if ($script:stopFails) { throw [UnauthorizedAccessException]::new('Access denied fixture.') }
}

Reset-Fixture
$valid = New-Worker
$unrelated = New-Worker 70002; $unrelated.CommandLine = 'dllhost.exe /Processid:{DFB65C4C-B34F-435D-AFE9-A86218684AA8}'
$impostor = New-Worker 70003; $impostor.ExecutablePath = 'C:\Temp\dllhost.exe'
$otherSession = New-Worker 70004; $otherSession.SessionId++
$otherUser = New-Worker 70005; $otherUser.Sid = 'S-1-5-18'
$substring = New-Worker 70006; $substring.CommandLine = 'dllhost.exe /Processid:' + $script:thumbnailGuid + '-suffix'
$missing = New-Worker 70007; $missing.CommandLine = $null
Set-Workers @($valid, $unrelated, $impostor, $otherSession, $otherUser, $substring, $missing)
$result = @(Restart-WindowsThumbnailWorker -Confirm:$false)
Assert-Test ($script:stopCalls.Count -eq 1 -and $script:stopCalls[0] -eq 70001) 'Only the intended user/session/COM worker may be stopped.'
Assert-Test ($result.Count -eq 1 -and $result[0].Status -eq 'StoppedRestartOnDemand') 'Successful termination must be reported accurately.'
Assert-Test ($script:disposed -contains 70001) 'Native process objects must be released.'

Reset-Fixture
$quoted = New-Worker; $quoted.ExecutablePath = $script:otherDllhost
$quoted.CommandLine = 'dllhost.exe "/PROCESSID:' + $script:thumbnailGuid.ToLowerInvariant() + '"'
Set-Workers @($quoted)
$result = @(Restart-WindowsThumbnailWorker -Confirm:$false)
Assert-Test ($script:stopCalls.Count -eq 1) 'Handle quoted/case-insensitive COM arguments and the Windows SysWOW64 host.'

Reset-Fixture
Set-Workers @((New-Worker))
$result = @(Restart-WindowsThumbnailWorker -WhatIf)
Assert-Test ($script:stopCalls.Count -eq 0 -and $script:queryCalls.Count -eq 1 -and $script:disposed.Count -eq 0) 'WhatIf must not open termination handles or stop processes.'
Assert-Test ($result.Count -eq 0) 'WhatIf must not report a successful restart.'

Reset-Fixture
$result = @(Restart-WindowsThumbnailWorker)
Assert-Test ($result.Count -eq 1 -and $result[0].Status -eq 'NoWorkerRunning' -and $null -eq $result[0].ProcessId) 'No worker should be a harmless, explicit result.'
Assert-Test ($script:stopCalls.Count -eq 0) 'No worker must mean no termination.'

Reset-Fixture
Set-Workers @((New-Worker))
$script:current[70001] = $null
$result = @(Restart-WindowsThumbnailWorker -Confirm:$false)
Assert-Test ($script:stopCalls.Count -eq 0 -and $result[0].Status -eq 'AlreadyExited') 'An exited worker must not cause a stale PID kill.'

foreach ($scenario in @('ChangedCimCreation', 'ChangedNativeCreation', 'OwnerUnreadable', 'StopFailure', 'ExitTimeout')) {
    Reset-Fixture
    Set-Workers @((New-Worker))
    switch ($scenario) {
        'ChangedCimCreation' { $replacement = New-Worker; $replacement.CreationDate = $replacement.CreationDate.AddSeconds(1); $script:current[70001] = $replacement }
        'ChangedNativeCreation' { $script:startTimeChange = $true }
        'OwnerUnreadable' { $script:workers[0].OwnerReturnValue = 2 }
        'StopFailure' { $script:stopFails = $true }
        'ExitTimeout' { $script:waitSucceeds = $false }
    }
    $capturedErrors = @()
    $result = @(Restart-WindowsThumbnailWorker -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable capturedErrors)
    Assert-Test ($result.Count -eq 0 -and $capturedErrors.Count -gt 0) "$scenario must produce an error and no false success."
    if ($scenario -in @('ChangedCimCreation', 'ChangedNativeCreation', 'OwnerUnreadable')) {
        Assert-Test ($script:stopCalls.Count -eq 0) "$scenario must fail closed before termination."
    }
}
'PASS: force-by-default, scoped targeting, WhatIf, absence, exit races, PID reuse, owner failures, stop failures, and timeout handling.'
