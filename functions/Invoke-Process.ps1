function Invoke-Process {
    <#
    .SYNOPSIS
    Runs a native executable synchronously and captures both output streams.
    .DESCRIPTION
    ArgumentList contains one element per native argument; do not prequote values.
    Both streams drain asynchronously to prevent pipe deadlocks. By default stdout
    lines enter the success stream and stderr is information tagged StandardError.
    PassThru returns one result object with Id, ExitCode, StandardOutput and
    StandardError instead. Nonzero exit codes throw unless IgnoreExitCode is set.
    TimeoutSeconds bounds the run and terminates its process tree on timeout.
    .PARAMETER NoNewWindow
    Compatibility switch. Execution always uses redirected pipes without a window.
    .PARAMETER Wait
    Compatibility switch. This command always waits for completion.
    .EXAMPLE
    Invoke-Process git -ArgumentList @('-C', 'C:\My Repo', 'status', '--short')
    .EXAMPLE
    $result = Invoke-Process pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 7') -PassThru -IgnoreExitCode
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string], [pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)] [ValidateNotNullOrEmpty()] [string]$FilePath,
        [Parameter(Position = 1)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [hashtable]$Environment,
        [ValidateRange(0, 2147483)] [int]$TimeoutSeconds = 0,
        [switch]$PassThru,
        [switch]$IgnoreExitCode,
        [switch]$NoNewWindow,
        [switch]$Wait,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError
    )
    if ($NoNewWindow -or $Wait) { Write-Verbose 'Invoke-Process always waits and uses redirected pipes without a window.' }
    if (-not $PSCmdlet.ShouldProcess($FilePath, 'Run executable')) { return }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkingDirectory)
    }
    else { $startInfo.WorkingDirectory = $PWD.ProviderPath }
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    if ($Environment) {
        foreach ($key in $Environment.Keys) {
            if ($null -eq $Environment[$key]) { $null = $startInfo.Environment.Remove($key) }
            else { $startInfo.Environment[$key] = [string]$Environment[$key] }
        }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($TimeoutSeconds -gt 0) {
            if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                throw [TimeoutException]::new("Process '$FilePath' exceeded $TimeoutSeconds seconds.")
            }
        }
        else { $process.WaitForExit() }
        if ($TimeoutSeconds -gt 0) {
            foreach ($task in @($stdoutTask, $stderrTask)) {
                $remaining = [Math]::Max(0, $TimeoutSeconds * 1000 - [int]$clock.ElapsedMilliseconds)
                if (-not $task.Wait($remaining)) {
                    throw [TimeoutException]::new("Process '$FilePath' exceeded $TimeoutSeconds seconds while draining output.")
                }
            }
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $result = [pscustomobject]@{
            PSTypeName = 'PowerShellProfile.ProcessResult'
            Id = $process.Id
            ExitCode = $process.ExitCode
            StandardOutput = $stdout
            StandardError = $stderr
        }
        if ($RedirectStandardOutput) {
            [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RedirectStandardOutput), $stdout)
        }
        if ($RedirectStandardError) {
            [IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RedirectStandardError), $stderr)
        }
        if ($result.ExitCode -ne 0 -and -not $IgnoreExitCode) {
            $errorRecord = [Management.Automation.ErrorRecord]::new(
                [InvalidOperationException]::new("Process '$FilePath' exited with code $($result.ExitCode). $stderr"),
                'NativeProcessFailed', [Management.Automation.ErrorCategory]::InvalidResult, $result)
            $PSCmdlet.ThrowTerminatingError($errorRecord)
        }
        if ($PassThru) { return $result }
        if ($stderr.Length -and -not $RedirectStandardError) { Write-Information -MessageData $stderr -Tags StandardError -InformationAction Continue }
        if ($stdout.Length -and -not $RedirectStandardOutput) {
            $reader = [IO.StringReader]::new($stdout)
            try { while ($null -ne ($line = $reader.ReadLine())) { $line } }
            finally { $reader.Dispose() }
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $null = $process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}
