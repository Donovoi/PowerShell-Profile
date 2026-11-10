function Invoke-ValidatedDownload {
    <#
    .SYNOPSIS
    Stages, verifies and publishes one HTTP(S) download.
    .DESCRIPTION
    Shared native/aria2/RPC implementation. -Force permits replacement only after
    verification. Empty files require -AllowEmpty. RPC owns a private loopback
    process with a random secret. Remote errors are redacted to protect headers.
    Reports live progress without adding text to the success stream. Cancellation
    stops the owned transport and removes its unpublished staging files.
    TimeoutSeconds defaults to 0 (no total deadline). Positive values are an
    explicit total time limit, reported as a timeout rather than user cancellation.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][uri]$URL,
        [Parameter(Mandatory)][string]$OutFile,
        [ValidateSet('Native','Aria2','RPC')][string]$Transport = 'Native',
        [string]$Aria2cExePath,
        [Collections.IDictionary]$Headers,
        [string]$Token,
        [string]$LoadCookiesFromFile,
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
        [string]$UserAgent = 'PowerShell-Profile',
        [ValidateSet('debug','info','notice','warn','error')][string]$AriaConsoleLogLevel = 'error',
        [switch]$LogToFile,
        [switch]$Force,
        [switch]$AllowEmpty,
        [ValidateRange(0,86400)][int]$TimeoutSeconds = 0,
        [ValidateRange(-1,[long]::MaxValue)][long]$ExpectedLength = -1,
        [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSHA256
    )
    $ErrorActionPreference = 'Stop'
    if (-not $URL.IsAbsoluteUri -or $URL.Scheme -notin 'http','https') { throw 'Only absolute HTTP(S) URLs are supported.' }
    if ($URL.UserInfo) { throw 'Pass authentication in headers, not URL user information.' }
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) {
        $loader = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path -LiteralPath $loader) { . $loader }
        else { . ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -ErrorAction Stop))) }
    }
    Initialize-CmdletDependencies -RequiredCmdlets @('Get-FinalOutputPath') -PreferLocal -ErrorAction Stop
    $destination = Get-FinalOutputPath -BasePath $OutFile -Force:$Force
    $requestHeaders = @{}
    if ($Headers) { foreach ($key in $Headers.Keys) { $requestHeaders[[string]$key] = [string]$Headers[$key] } }
    if ($Token) {
        if ($URL.Host -notin 'github.com','api.github.com') { throw 'Token is restricted to GitHub hosts; use Headers for other services.' }
        $requestHeaders.Authorization = "Bearer $Token"
        if (-not $requestHeaders.ContainsKey('Accept')) { $requestHeaders.Accept = 'application/octet-stream' }
    }
    foreach ($key in $requestHeaders.Keys) {
        if ($key -match '[:\s]' -or $requestHeaders[$key] -match '[\r\n]') { throw 'Invalid HTTP header.' }
    }
    if ($LoadCookiesFromFile) {
        $LoadCookiesFromFile = (Get-Item -LiteralPath $LoadCookiesFromFile -ErrorAction Stop).FullName
        if ($Transport -eq 'Native') { throw 'Native cookies require -WebSession; use aria2 for Netscape cookie files.' }
    }
    if (-not $PSCmdlet.ShouldProcess($destination, "Download and verify using $Transport")) { return }
    $parent = [IO.Path]::GetDirectoryName($destination)
    $null = [IO.Directory]::CreateDirectory($parent)
    $stage = [IO.Path]::Combine($parent, '.download-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($stage)
    $partial = [IO.Path]::Combine($stage, 'payload')
    $configPath = [IO.Path]::Combine($stage, 'aria2.conf')
    $logPath = [IO.Path]::Combine($stage, 'aria2.log')
    $ownedProcess = $null
    $failureReason = 'transport or verification error'
    $processStarted = $false
    $stdoutTask = $null; $stderrTask = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $progressId = Get-Random -Minimum 1 -Maximum ([int]::MaxValue)
    $activity = 'Downloading ' + [IO.Path]::GetFileName($destination)
    $downloadCommand = $PSCmdlet
    function Show-DownloadProgress([long]$Completed, [long]$Total, [double]$Speed) {
        $progress = @{ Id = $progressId; Activity = $activity; PercentComplete = -1 }
        $progress.Status = '{0:N1} MiB downloaded' -f ($Completed / 1MB)
        if ($Total -gt 0) {
            $progress.PercentComplete = [int][Math]::Min(100, [Math]::Floor(100.0 * $Completed / $Total))
            $progress.Status = '{0}% - {1:N1} / {2:N1} MiB' -f $progress.PercentComplete, ($Completed / 1MB), ($Total / 1MB)
            if ($Speed -gt 0) { $progress.SecondsRemaining = [int][Math]::Min([double][int]::MaxValue, [Math]::Max(0.0, ($Total - $Completed) / $Speed)) }
        }
        if ($Speed -gt 0) { $progress.Status += ' - {0:N2} MiB/s' -f ($Speed / 1MB) }
        Write-Progress @progress
    }
    function Wait-DownloadTask([Threading.Tasks.Task]$Task, [switch]$ReportProgress) {
        # GetResult/WaitForExit on an unfinished operation delays Ctrl+C. Yield to
        # PowerShell regularly so pipeline stop can enter our finally blocks.
        while (-not $Task.IsCompleted) {
            if ($downloadCommand.Stopping) { throw [Management.Automation.PipelineStoppedException]::new() }
            if ($ReportProgress) {
                $completed = $outputStream.Position
                Show-DownloadProgress $completed $ExpectedLength ($completed / [Math]::Max(0.001, $timer.Elapsed.TotalSeconds))
            }
            Start-Sleep -Milliseconds 100
        }
        if ($downloadCommand.Stopping) { throw [Management.Automation.PipelineStoppedException]::new() }
    }
    try {
        Write-Progress -Id $progressId -Activity $activity -Status 'Connecting...'
        if ($Transport -eq 'Native') {
            $handler = [Net.Http.HttpClientHandler]::new()
            if ($WebSession) { $handler.CookieContainer = $WebSession.Cookies; $handler.Credentials = $WebSession.Credentials }
            $client = [Net.Http.HttpClient]::new($handler)
            $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $URL)
            $cancellation = [Threading.CancellationTokenSource]::new()
            if ($TimeoutSeconds -gt 0) { $cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds)) }
            $response = $null; $outputStream = $null; $inputStream = $null
            try {
                foreach ($key in $requestHeaders.Keys) {
                    if (-not $request.Headers.TryAddWithoutValidation($key, [string]$requestHeaders[$key])) { throw 'Unsupported request header.' }
                }
                if ($UserAgent -and -not $requestHeaders.ContainsKey('User-Agent')) { $null = $request.Headers.TryAddWithoutValidation('User-Agent', $UserAgent) }
                $responseTask = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token)
                Wait-DownloadTask $responseTask
                $response = $responseTask.GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) { $failureReason = 'HTTP status {0}' -f [int]$response.StatusCode }
                $null = $response.EnsureSuccessStatusCode()
                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $outputStream = [IO.File]::Open($partial, 'CreateNew', 'Write', 'None')
                if ($ExpectedLength -lt 0 -and $null -ne $response.Content.Headers.ContentLength) { $ExpectedLength = $response.Content.Headers.ContentLength }
                $copyTask = $inputStream.CopyToAsync($outputStream, 81920, $cancellation.Token)
                Wait-DownloadTask $copyTask -ReportProgress
                $null = $copyTask.GetAwaiter().GetResult()
            }
            catch [OperationCanceledException] {
                if ($cancellation.IsCancellationRequested -and -not $downloadCommand.Stopping) {
                    throw [TimeoutException]::new("Download exceeded -TimeoutSeconds $TimeoutSeconds; no replacement was published. Use 0 for no total deadline.")
                }
                throw
            }
            finally {
                $cancellation.Cancel()
                if ($inputStream) { $inputStream.Dispose() }
                if ($response) { $response.Dispose() }
                if ($outputStream) { $outputStream.Dispose() }
                $request.Dispose(); $client.Dispose(); $cancellation.Dispose()
            }
        }
        else {
            $executable = (Get-Command -Name $Aria2cExePath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
            $options = [Collections.Generic.List[string]]::new()
            foreach ($line in @('enable-rpc=false','auto-file-renaming=false','allow-overwrite=false',
                'continue=false','max-tries=3','retry-wait=1','connect-timeout=10','timeout=30',
                'file-allocation=none','follow-torrent=false','follow-metalink=false',
                'check-certificate=true','summary-interval=1','human-readable=false',
                'show-console-readout=true','enable-color=false','truncate-console-readout=false',
                "stop-with-process=$PID", "console-log-level=$AriaConsoleLogLevel",
                "dir=$stage",'out=payload',"user-agent=$UserAgent")) { $options.Add($line) }
            foreach ($key in $requestHeaders.Keys) { $options.Add(('header={0}: {1}' -f $key, $requestHeaders[$key])) }
            if ($LoadCookiesFromFile) { $options.Add("load-cookies=$LoadCookiesFromFile") }
            # Authenticated calls never persist aria2 debug logs.
            if ($LogToFile -and -not $requestHeaders.ContainsKey('Authorization') -and -not $LoadCookiesFromFile) {
                $options.Add("log=$logPath"); $options.Add('log-level=warn')
            }
            if ($Transport -eq 'RPC') {
                $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
                $listener.Start()
                try { $port = $listener.LocalEndpoint.Port } finally { $listener.Stop() }
                $secretBytes = [byte[]]::new(32)
                [Security.Cryptography.RandomNumberGenerator]::Fill($secretBytes)
                $rpcSecret = [Convert]::ToBase64String($secretBytes)
                foreach ($line in @('enable-rpc=true','rpc-listen-all=false','rpc-allow-origin-all=false',
                    "rpc-listen-port=$port","rpc-secret=$rpcSecret")) { $options.Add($line) }
            }
            foreach ($line in $options) { if ($line -match '[\r\n]') { throw 'Invalid aria2 option value.' } }
            # Create the credential-bearing config with a protected DACL from its first byte.
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try {
                $security = [Security.AccessControl.FileSecurity]::new()
                $security.SetOwner($identity.User)
                $security.SetAccessRuleProtection($true, $false)
                $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity.User, 'FullControl', 'Allow'))
                $configStream = [IO.FileSystemAclExtensions]::Create([IO.FileInfo]::new($configPath), [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $security)
            }
            finally { $identity.Dispose() }
            $configWriter = [IO.StreamWriter]::new($configStream, [Text.UTF8Encoding]::new($false))
            try { foreach ($line in $options) { $configWriter.WriteLine($line) } }
            finally { $configWriter.Dispose() }
            $startInfo = [Diagnostics.ProcessStartInfo]::new($executable)
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.ArgumentList.Add("--conf-path=$configPath")
            if ($Transport -eq 'Aria2') {
                $startInfo.ArgumentList.Add('--')
                $startInfo.ArgumentList.Add($URL.AbsoluteUri)
            }
            $ownedProcess = [Diagnostics.Process]::new()
            $ownedProcess.StartInfo = $startInfo
            $processStarted = $ownedProcess.Start()
            # Drain continuously; never display remote diagnostics containing URLs
            # or credentials, and never accumulate an entire download's logs.
            $stderrTask = $ownedProcess.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            if ($Transport -eq 'Aria2') {
                $stdoutTask = $ownedProcess.StandardOutput.ReadLineAsync()
                while ($null -ne $stdoutTask -or -not $ownedProcess.HasExited) {
                    if ($downloadCommand.Stopping) { throw [Management.Automation.PipelineStoppedException]::new() }
                    if ($TimeoutSeconds -gt 0 -and $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                        throw [TimeoutException]::new("Download exceeded -TimeoutSeconds $TimeoutSeconds; no replacement was published. Use 0 for no total deadline.")
                    }
                    if ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
                        $line = $stdoutTask.GetAwaiter().GetResult()
                        if ($null -eq $line) { $stdoutTask = $null; continue }
                        if ($line -match '\[#([0-9a-f]+)\s+(?<done>\d+)B/(?<total>\d+)B.*?\bDL:(?<speed>\d+)B') {
                            Show-DownloadProgress ([long]$Matches.done) ([long]$Matches.total) ([double]$Matches.speed)
                        }
                        $stdoutTask = $ownedProcess.StandardOutput.ReadLineAsync()
                    }
                    else { Start-Sleep -Milliseconds 100 }
                }
                if ($ownedProcess.ExitCode -ne 0) { $failureReason = "aria2 exit code $($ownedProcess.ExitCode)"; throw $failureReason }
            }
            else {
                $stdoutTask = $ownedProcess.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
                function Invoke-DownloadRpc([string]$Method, [object[]]$Arguments = @()) {
                    # Keep each RPC request bounded even without a download deadline.
                    $remaining = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds - $timer.Elapsed.TotalSeconds } else { 5.0 }
                    if ($remaining -le 0) {
                        throw [TimeoutException]::new("Download exceeded -TimeoutSeconds $TimeoutSeconds; no replacement was published. Use 0 for no total deadline.")
                    }
                    if ($ownedProcess.HasExited) { throw 'Owned aria2 process exited.' }
                    $body = @{ jsonrpc = '2.0'; id = [guid]::NewGuid().ToString('N'); method = "aria2.$Method"; params = @("token:$rpcSecret") + $Arguments } | ConvertTo-Json -Depth 8 -Compress
                    $response = Invoke-RestMethod -Uri "http://127.0.0.1:$port/jsonrpc" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec ([int][Math]::Max(1,[Math]::Min(5,[Math]::Ceiling($remaining)))) -ErrorAction Stop
                    if ($response.error) { throw "aria2 RPC error code $($response.error.code)." }
                    $response.result
                }
                $ready = $false
                $startupSeconds = if ($TimeoutSeconds -gt 0) { [Math]::Min(10, $TimeoutSeconds) } else { 10 }
                while (-not $ready -and $timer.Elapsed.TotalSeconds -lt $startupSeconds) {
                    try { $null = Invoke-DownloadRpc getVersion; $ready = $true }
                    catch [Management.Automation.PipelineStoppedException] { throw }
                    catch [OperationCanceledException] { throw }
                    catch [TimeoutException] { throw }
                    catch { if ($downloadCommand.Stopping -or $ownedProcess.HasExited) { throw }; Start-Sleep -Milliseconds 100 }
                }
                if (-not $ready) {
                    if ($TimeoutSeconds -gt 0 -and $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                        throw [TimeoutException]::new("Download exceeded -TimeoutSeconds $TimeoutSeconds; no replacement was published. Use 0 for no total deadline.")
                    }
                    $failureReason = 'aria2 RPC startup timed out'; throw $failureReason
                }
                $gid = Invoke-DownloadRpc addUri @(@($URL.AbsoluteUri), @{ dir = $stage; out = 'payload' })
                do {
                    $status = Invoke-DownloadRpc tellStatus @($gid)
                    Show-DownloadProgress ([long]$status.completedLength) ([long]$status.totalLength) ([double]$status.downloadSpeed)
                    if ($status.status -in 'error','removed') { $failureReason = 'aria2 download error code {0}' -f [int]$status.errorCode; throw $failureReason }
                    if ($status.status -eq 'complete') { break }
                    Start-Sleep -Milliseconds 200
                } while ($true)
                if ([long]$status.completedLength -ne [long]$status.totalLength) { throw 'RPC completion length mismatch.' }
                if ($ExpectedLength -lt 0) { $ExpectedLength = [long]$status.totalLength }
            }
        }
        $file = Get-Item -LiteralPath $partial -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Length -eq 0 -and -not $AllowEmpty)) { throw 'Download produced no file content.' }
        if ($ExpectedLength -ge 0 -and $file.Length -ne $ExpectedLength) { throw 'Downloaded length differs from the expected length.' }
        if ($ExpectedSHA256 -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $ExpectedSHA256) { throw 'Downloaded SHA256 differs from the expected hash.' }
        if ($downloadCommand.Stopping) { throw [Management.Automation.PipelineStoppedException]::new() }
        [IO.File]::Move($partial, $destination, [bool]$Force)
        $destination
    }
    catch [Management.Automation.PipelineStoppedException] { throw }
    catch [OperationCanceledException] { throw }
    catch [TimeoutException] { throw }
    catch {
        if ($downloadCommand.Stopping) { throw }
        $failure = [InvalidOperationException]::new("Download failed using ${Transport}: $failureReason. No replacement was published. Check availability, authentication and expected size/hash.")
        $failure.Data['DownloadFailureReason'] = $failureReason
        throw $failure
    }
    finally {
        if ($ownedProcess) {
            try {
                if ($processStarted -and -not $ownedProcess.HasExited) { $ownedProcess.Kill($true); $null = $ownedProcess.WaitForExit(5000) }
                # EOF/cancellation can fault a pending read during teardown.
                try { if ($stdoutTask) { $null = $stdoutTask.Wait(1000) } } catch { $null = $_ } # Teardown read failure is expected.
                try { if ($stderrTask) { $null = $stderrTask.Wait(1000) } } catch { $null = $_ }
            } finally { $ownedProcess.Dispose() }
        }
        foreach ($temporary in @($configPath, $partial, ($partial + '.aria2'))) {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
        if ([IO.File]::Exists($logPath)) { Write-Verbose "aria2 diagnostics retained at $logPath" }
        if ([IO.Directory]::Exists($stage) -and [IO.Directory]::GetFileSystemEntries($stage).Length -eq 0) { [IO.Directory]::Delete($stage) }
        Write-Progress -Id $progressId -Activity $activity -Completed
    }
}
