#requires -Version 7.0

function Restart-WindowsThumbnailWorker {
    <#
    .SYNOPSIS
    Force-recycles the current user's Windows thumbnail worker.
    .DESCRIPTION
    Stops only Windows dllhost.exe processes hosting the thumbnail-cache COM class
    in the current user's session. Termination is always forced; no Force switch
    or administrator elevation is required for the user's own workers.

    Windows starts a replacement on the next thumbnail request. Refresh the
    thumbnail view in Everything or File Explorer if necessary. This function
    does not launch dllhost.exe manually, restart Explorer or Everything, delete
    thumbnail caches, change thumbnail settings, or alter any media files.

    Checks the executable path, COM class, session, owner SID, and process creation
    time before stopping a worker. Other COM surrogates and other users' processes
    are left alone. A stop failure produces an error, not a success result.
    .OUTPUTS
    WindowsThumbnailWorker.RestartResult
    One result per verified worker, or NoWorkerRunning when none is found.
    StoppedRestartOnDemand means termination was verified; it does not claim that
    a replacement is already running or that a faulty thumbnail provider is fixed.
    .NOTES
    Requires PowerShell 7 on Windows. Dot-sourcing only defines this function;
    importing or reloading the profile performs no process or filesystem work.
    Honors the standard WhatIf, Confirm, Verbose, and ErrorAction parameters.
    .EXAMPLE
    Restart-WindowsThumbnailWorker

    Force-stop this user's thumbnail workers. Windows restarts them on demand.
    .EXAMPLE
    Restart-WindowsThumbnailWorker -WhatIf

    Show which workers would be stopped without changing any processes.
    .LINK
    https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process
    .LINK
    https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/stop-process
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('WindowsThumbnailWorker.RestartResult')]
    param()

    if (-not $IsWindows) {
        throw [PlatformNotSupportedException]::new('This command requires Windows.')
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $ownerSid = $identity.User.Value }
    finally { $identity.Dispose() }
    $callerProcess = Get-Process -Id $PID -ErrorAction Stop
    try { $sessionId = $callerProcess.SessionId }
    finally { $callerProcess.Dispose() }

    $windowsDirectory = [Environment]::GetFolderPath('Windows')
    $allowedExecutables = @(
        [IO.Path]::Combine($windowsDirectory, 'System32', 'dllhost.exe')
        [IO.Path]::Combine($windowsDirectory, 'SysWOW64', 'dllhost.exe')
    )
    # Match a whole argument, not a GUID mentioned elsewhere in the command line.
    $thumbnailArgument = '(?i)(?:^|\s)"?/Processid:\{AB8902B4-09CA-4BB6-B78D-A8F59079A8D5\}"?(?=\s|$)'
    $isThumbnailWorker = {
        param($Process)
        $null -ne $Process -and
        $Process.Name -ieq 'dllhost.exe' -and
        $Process.SessionId -eq $sessionId -and
        $Process.ExecutablePath -in $allowedExecutables -and
        $Process.CommandLine -match $thumbnailArgument -and
        $Process.CreationDate -is [datetime]
    }

    $workers = Get-CimInstance -ClassName Win32_Process -Filter (
        "Name = 'dllhost.exe' AND SessionId = $sessionId"
    ) -ErrorAction Stop
    $matchedCount = 0
    $inspectionFailed = $false

    foreach ($worker in $workers) {
        if (-not (& $isThumbnailWorker $worker)) { continue }
        $process = $null
        try {
            # GetOwnerSid is read-only; it must still run during a WhatIf preview.
            $owner = Invoke-CimMethod -InputObject $worker -MethodName GetOwnerSid -WhatIf:$false -Confirm:$false -ErrorAction Stop
            if ($owner.ReturnValue -ne 0) {
                throw [InvalidOperationException]::new("Cannot verify owner of process $($worker.ProcessId): code $($owner.ReturnValue).")
            }
            if ($owner.Sid -ne $ownerSid) { continue }
            $matchedCount++

            if (-not $PSCmdlet.ShouldProcess(
                "Windows thumbnail worker PID $($worker.ProcessId), session $sessionId",
                'Force-stop; Windows restarts it on the next thumbnail request'
            )) { continue }

            # Re-query after confirmation; the original PID may have exited or been reused.
            $current = Get-CimInstance -ClassName Win32_Process -Filter (
                "ProcessId = $($worker.ProcessId)"
            ) -ErrorAction Stop
            if ($null -eq $current) {
                $status = 'AlreadyExited'
            }
            elseif (-not (& $isThumbnailWorker $current) -or
                $current.CreationDate -ne $worker.CreationDate) {
                throw [InvalidOperationException]::new("Process $($worker.ProcessId) changed identity; it was not stopped.")
            }
            else {
                $process = Get-Process -Id $current.ProcessId -ErrorAction Stop
                # Acquire a process handle and compare its creation time to the CIM snapshot.
                $null = $process.Handle
                if ($process.HasExited) {
                    $status = 'AlreadyExited'
                }
                elseif ($process.SessionId -ne $sessionId -or
                    $process.Path -notin $allowedExecutables -or
                    [Math]::Abs(($process.StartTime.ToUniversalTime() -
                        $current.CreationDate.ToUniversalTime()).TotalMilliseconds) -ge 1) {
                    throw [InvalidOperationException]::new("Process $($worker.ProcessId) changed identity; it was not stopped.")
                }
                else {
                    Stop-Process -InputObject $process -Force -Confirm:$false -ErrorAction Stop
                    if (-not $process.WaitForExit(5000)) {
                        throw [TimeoutException]::new("Thumbnail worker $($worker.ProcessId) did not exit within five seconds.")
                    }
                    $status = 'StoppedRestartOnDemand'
                }
            }

            [pscustomobject]@{
                PSTypeName = 'WindowsThumbnailWorker.RestartResult'
                ProcessId  = [int]$worker.ProcessId
                SessionId  = $sessionId
                Status     = $status
            }
        }
        catch {
            $inspectionFailed = $true
            $PSCmdlet.WriteError([Management.Automation.ErrorRecord]::new(
                $_.Exception, 'ThumbnailWorkerRestartFailed',
                [Management.Automation.ErrorCategory]::InvalidOperation, $worker.ProcessId
            ))
        }
        finally {
            if ($null -ne $process) { $process.Dispose() }
        }
    }

    if ($matchedCount -eq 0 -and -not $inspectionFailed) {
        Write-Verbose 'No verified thumbnail worker is running for this user and session. Windows starts one when needed.'
        [pscustomobject]@{
            PSTypeName = 'WindowsThumbnailWorker.RestartResult'
            ProcessId  = $null
            SessionId  = $sessionId
            Status     = 'NoWorkerRunning'
        }
    }
}
