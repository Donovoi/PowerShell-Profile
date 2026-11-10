#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'Use a new fixture directory.' }
$null = [IO.Directory]::CreateDirectory($TestRoot)
$functions = [IO.Path]::GetFullPath("$PSScriptRoot/../functions")
$aria = (Get-Command aria2c.exe -CommandType Application -ErrorAction Stop).Source
function Assert($Condition, $Message) {
    if (-not $Condition) {
        if ($active) {
            Write-Host ('Fixture warnings: ' + ($active.PowerShell.Streams.Warning -join '; '))
            Write-Host ('Fixture errors: ' + ($active.PowerShell.Streams.Error -join '; '))
        }
        throw $Message
    }
}
function New-DownloadPipeline($Mode, $Endpoint, $Directory, [switch]$Next, [int]$TimeoutSeconds = -1) {
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript({
        param($Functions, $Aria, $Mode, $Urls, $Directory, $TimeoutSeconds)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'Continue'
        foreach ($name in 'Initialize-CmdletDependencies','Get-FinalOutputPath','Get-OutputFilename','Invoke-ValidatedDownload','Get-FileDownload','Get-LatestGitHubRelease') {
            . (Join-Path $Functions "$name.ps1")
        }
        $parameters = @{ URL = $Urls; DestinationDirectory = $Directory; Force = $true; aria2cExe = $Aria }
        if ($TimeoutSeconds -ge 0) { $parameters.TimeoutSeconds = $TimeoutSeconds }
        if ($Mode -ne 'Native') { $parameters.UseAria2 = $true }
        if ($Mode -eq 'Aria2') { $parameters.NoRPCMode = $true }
        Get-FileDownload @parameters
    }).AddArgument($functions).AddArgument($aria).AddArgument($Mode)
    $urls = @("$base/$Endpoint/$Mode.bin")
    if ($Next) { $urls += "$base/next/$Mode.bin" }
    $null = $ps.AddArgument($urls).AddArgument($Directory).AddArgument($TimeoutSeconds)
    $handle = $ps.BeginInvoke()
    @{ PowerShell = $ps; Handle = $handle }
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds = 15) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($watch.Elapsed.TotalSeconds -ge $Seconds) { throw 'Timed out waiting for fixture condition.' }
        Start-Sleep -Milliseconds 50
    }
}
function Get-FixtureAria($Directory) {
    @(Get-CimInstance Win32_Process -Filter "Name='aria2c.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Directory) })
}
$info = [Diagnostics.ProcessStartInfo]::new((Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
$info.UseShellExecute = $false; $info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
$info.ArgumentList.Add("$PSScriptRoot/fixtures/download_progress_server.py")
$info.ArgumentList.Add($TestRoot)
$server = [Diagnostics.Process]::Start($info)
$stdout = $server.StandardOutput.ReadToEndAsync(); $stderr = $server.StandardError.ReadToEndAsync()
$active = $null
try {
    Wait-Until { [IO.File]::Exists("$TestRoot/port") -or $server.HasExited }
    Assert (-not $server.HasExited) 'HTTP fixture failed to start.'
    $base = 'http://127.0.0.1:' + [IO.File]::ReadAllText("$TestRoot/port")
    foreach ($mode in 'Aria2','RPC','Native') {
        $directory = Join-Path $TestRoot "complete-$mode"
        $active = New-DownloadPipeline $mode 'stream' $directory
        $ps = $active.PowerShell
        Wait-Until { @($ps.Streams.Progress | Where-Object { $_.PercentComplete -gt 0 -and $_.PercentComplete -lt 100 }).Count -ge 2 -or $active.Handle.IsCompleted }
        $progress = @($ps.Streams.Progress | Where-Object { $_.PercentComplete -gt 0 -and $_.PercentComplete -lt 100 })
        Assert ($progress.Count -ge 2 -and -not $active.Handle.IsCompleted) "$mode did not report live progress before completion."
        Assert (@($progress | Where-Object StatusDescription -Match 'MiB/s').Count -gt 0) "$mode speed missing."
        Wait-Until { $active.Handle.IsCompleted }
        $result = @($ps.EndInvoke($active.Handle))
        Assert ($ps.Streams.Error.Count -eq 0 -and $result.Count -eq 1) "$mode polluted the path output or failed."
        Assert ($ps.Streams.Warning.Count -eq 0) "$mode success unexpectedly used fallback."
        Assert ([IO.FileInfo]::new($result[0]).Length -eq 4MB) "$mode downloaded wrong length."
        $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes(('x' * 4MB))))
        Assert ((Get-FileHash -LiteralPath $result[0]).Hash -eq $expectedHash) "$mode downloaded wrong bytes."
        Assert (@($ps.Streams.Progress | Where-Object RecordType -EQ Completed).Count -gt 0) "$mode did not clear progress."
        Assert ((Get-FixtureAria $directory).Count -eq 0) "$mode leaked aria2 after success."
        $ps.Dispose(); $active = $null
        Write-Host "PASS: $mode default deadline disabled, live progress, speed, exact bytes, clean output and process cleanup"
    }
    # PowerShell.Stop() uses the same pipeline-stop mechanism as console Ctrl+C.
    foreach ($endpoint in 'cancel','stall') {
        foreach ($mode in 'Aria2','RPC','Native') {
            $directory = Join-Path $TestRoot "$endpoint-$mode"
            $null = [IO.Directory]::CreateDirectory($directory)
            $destination = Join-Path $directory "$mode.bin"
            [IO.File]::WriteAllText($destination, 'preserve existing file')
            $active = New-DownloadPipeline $mode $endpoint $directory -Next
            $ps = $active.PowerShell
            Wait-Until { [IO.File]::Exists("$TestRoot/requests.jsonl") -and [IO.File]::ReadAllText("$TestRoot/requests.jsonl").Contains("/$endpoint/$mode.bin") }
            if ($endpoint -eq 'cancel') {
                Wait-Until { @($ps.Streams.Progress | Where-Object StatusDescription -Match 'MiB/s').Count -gt 0 }
            }
            $ownedIds = @(Get-FixtureAria $directory | Select-Object -ExpandProperty ProcessId)
            if ($mode -ne 'Native') { Assert ($ownedIds.Count -eq 1) "$mode fixture process was not identified. Found $($ownedIds.Count)." }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $stop = $ps.BeginStop($null, $null)
            Assert ($stop.AsyncWaitHandle.WaitOne(3000)) "$mode cancellation took more than three seconds during $endpoint."
            $ps.EndStop($stop)
            try { $null = $ps.EndInvoke($active.Handle) } catch [Management.Automation.PipelineStoppedException] {}
            Assert ([IO.File]::ReadAllText($destination) -eq 'preserve existing file') "$mode cancellation published a partial file."
            Assert (@(Get-ChildItem -LiteralPath $directory -Force -Directory -Filter '.download-*').Count -eq 0) "$mode cancellation left staging/config files."
            foreach ($processId in $ownedIds) { Assert (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "$mode cancellation left aria2 running." }
            Start-Sleep -Milliseconds 250
            $requests = Get-Content -LiteralPath "$TestRoot/requests.jsonl" | ConvertFrom-Json
            Assert (@($requests | Where-Object path -EQ "/$endpoint/$mode.bin").Count -eq 1) "$mode cancellation retried the request."
            Assert (@($requests | Where-Object path -LIKE '/next/*').Count -eq 0) "$mode cancellation advanced to the next URL."
            Assert ($ps.Streams.Warning.Count -eq 0) "$mode cancellation triggered fallback."
            Write-Host "PASS: $mode cancellation during $endpoint in $([Math]::Round($watch.Elapsed.TotalSeconds,2))s; no child, retry, next URL or partial replacement"
            $ps.Dispose(); $active = $null
        }
    }
    foreach ($mode in 'Aria2','RPC') {
        $active = New-DownloadPipeline $mode 'unknown' (Join-Path $TestRoot "unknown-$mode") -TimeoutSeconds 0
        $ps = $active.PowerShell
        Wait-Until { @($ps.Streams.Progress | Where-Object StatusDescription -Match 'MiB/s').Count -gt 0 -or $active.Handle.IsCompleted }
        Assert (@($ps.Streams.Progress | Where-Object { $_.PercentComplete -eq -1 -and $_.StatusDescription -match 'MiB/s' }).Count -gt 0) "$mode unknown-length progress missing."
        Wait-Until { $active.Handle.IsCompleted }
        $result = @($ps.EndInvoke($active.Handle))
        Assert ($result.Count -eq 1 -and [IO.FileInfo]::new($result[0]).Length -eq 4MB) "$mode unknown-length download failed."
        $ps.Dispose(); $active = $null
        Write-Host "PASS: $mode unknown-length download and progress"
    }
    foreach ($endpoint in 'timeout-body','stall/timeout-headers') {
        foreach ($mode in 'Aria2','RPC','Native') {
            $directory = Join-Path $TestRoot ($endpoint.Replace('/', '-') + '-' + $mode)
            $null = [IO.Directory]::CreateDirectory($directory)
            $destination = Join-Path $directory "$mode.bin"
            [IO.File]::WriteAllText($destination, 'preserve existing file')
            $active = New-DownloadPipeline $mode $endpoint $directory -TimeoutSeconds 1 -Next
            $ps = $active.PowerShell
            Wait-Until { $active.Handle.IsCompleted } -Seconds 5
            $failure = $null
            try { $null = $ps.EndInvoke($active.Handle) } catch { $failure = $_ }
            Assert ($null -ne $failure -and $failure.Exception.ToString() -match 'exceeded -TimeoutSeconds 1') "$mode did not report an explicit timeout during $endpoint."
            Assert ($failure.Exception.ToString() -notmatch 'operation was canceled') "$mode misreported timeout as user cancellation."
            Assert ($ps.Streams.Warning.Count -eq 0) "$mode timeout restarted via fallback."
            Assert ([IO.File]::ReadAllText($destination) -eq 'preserve existing file') "$mode timeout replaced an existing file."
            Assert (@(Get-ChildItem -LiteralPath $directory -Force -Directory -Filter '.download-*').Count -eq 0) "$mode timeout leaked staging/config files."
            Assert ((Get-FixtureAria $directory).Count -eq 0) "$mode timeout leaked aria2."
            $requests = Get-Content -LiteralPath "$TestRoot/requests.jsonl" | ConvertFrom-Json
            Assert (@($requests | Where-Object path -EQ "/$endpoint/$mode.bin").Count -eq 1) "$mode timeout retried the request."
            Assert (@($requests | Where-Object path -LIKE '/next/*').Count -eq 0) "$mode timeout advanced to the next URL."
            $ps.Dispose(); $active = $null
            Write-Host "PASS: $mode explicit timeout during $endpoint; clear error, no restart, no replacement, no leaked process"
        }
    }
    foreach ($mode in 'Aria2','RPC') {
        $directory = Join-Path $TestRoot "failure-$mode"
        $active = New-DownloadPipeline $mode 'missing' $directory
        $ps = $active.PowerShell
        Wait-Until { $active.Handle.IsCompleted }
        $failure = $null
        try { $null = $ps.EndInvoke($active.Handle) } catch { $failure = $_ }
        Assert ($null -ne $failure -and $failure.Exception.ToString() -match 'HTTP status 404') "$mode native failure lost HTTP status."
        Assert ($ps.Streams.Warning.Count -eq 1 -and $ps.Streams.Warning[0].Message -match 'aria2 (exit code|download error code) 3') "$mode fallback warning lost aria2 error code."
        Assert ((Get-FixtureAria $directory).Count -eq 0) "$mode failure leaked aria2."
        $ps.Dispose(); $active = $null
        Write-Host "PASS: $mode aria2 failure code and native HTTP status preserved"
    }
}
finally {
    if ($active) { $active.PowerShell.Stop(); $active.PowerShell.Dispose() }
    if (-not $server.HasExited) { $server.Kill($true); $null = $server.WaitForExit(5000) }
    [IO.File]::WriteAllText("$TestRoot/server.stderr.log", $stderr.GetAwaiter().GetResult())
    $server.Dispose()
}
