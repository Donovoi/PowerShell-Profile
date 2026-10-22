function Invoke-ValidatedDownload {
    <#
    .SYNOPSIS
    Stages, verifies and publishes one HTTP(S) download.
    .DESCRIPTION
    Shared native/aria2/RPC implementation. -Force permits replacement only after
    verification. Empty files require -AllowEmpty. RPC owns a private loopback
    process with a random secret. Remote errors are redacted to protect headers.
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
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 600,
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
    Initialize-CmdletDependencies -RequiredCmdlets @('Get-FinalOutputPath','Invoke-Process') -PreferLocal -ErrorAction Stop
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
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Transport -eq 'Native') {
            $parameters = @{ Uri = $URL; OutFile = $partial; Headers = $requestHeaders; TimeoutSec = $TimeoutSeconds; ErrorAction = 'Stop' }
            if ($WebSession) { $parameters.WebSession = $WebSession }
            if ($UserAgent) { $parameters.UserAgent = $UserAgent }
            $null = Invoke-WebRequest @parameters
        }
        else {
            $executable = (Get-Command -Name $Aria2cExePath -CommandType Application -ErrorAction Stop).Source
            $options = [Collections.Generic.List[string]]::new()
            foreach ($line in @('enable-rpc=false','auto-file-renaming=false','allow-overwrite=false',
                'continue=false','max-tries=3','retry-wait=1','connect-timeout=10','timeout=30',
                'file-allocation=none','follow-torrent=false','follow-metalink=false',
                'check-certificate=true','summary-interval=0',"console-log-level=$AriaConsoleLogLevel",
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
            [IO.File]::WriteAllLines($configPath, $options, [Text.UTF8Encoding]::new($false))
            if ($Transport -eq 'Aria2') {
                $result = Invoke-Process -FilePath $executable -ArgumentList @("--conf-path=$configPath", '--', $URL.AbsoluteUri) -PassThru -IgnoreExitCode -TimeoutSeconds $TimeoutSeconds
                if ($result.ExitCode -ne 0) { throw "aria2 exited with code $($result.ExitCode)." }
            }
            else {
                $startInfo = [Diagnostics.ProcessStartInfo]::new($executable)
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $startInfo.ArgumentList.Add("--conf-path=$configPath")
                $ownedProcess = [Diagnostics.Process]::Start($startInfo)
                $stdoutTask = $ownedProcess.StandardOutput.ReadToEndAsync()
                $stderrTask = $ownedProcess.StandardError.ReadToEndAsync()
                function Invoke-DownloadRpc([string]$Method, [object[]]$Arguments = @()) {
                    $remaining = $TimeoutSeconds - $timer.Elapsed.TotalSeconds
                    if ($remaining -le 0) { throw 'RPC download timed out.' }
                    if ($ownedProcess.HasExited) { throw 'Owned aria2 process exited.' }
                    $body = @{ jsonrpc = '2.0'; id = [guid]::NewGuid().ToString('N'); method = "aria2.$Method"; params = @("token:$rpcSecret") + $Arguments } | ConvertTo-Json -Depth 8 -Compress
                    $response = Invoke-RestMethod -Uri "http://127.0.0.1:$port/jsonrpc" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec ([int][Math]::Max(1,[Math]::Min(5,[Math]::Ceiling($remaining)))) -ErrorAction Stop
                    if ($response.error) { throw "aria2 RPC error code $($response.error.code)." }
                    $response.result
                }
                $ready = $false
                while (-not $ready -and $timer.Elapsed.TotalSeconds -lt [Math]::Min(10, $TimeoutSeconds)) {
                    try { $null = Invoke-DownloadRpc getVersion; $ready = $true }
                    catch { if ($ownedProcess.HasExited) { throw }; Start-Sleep -Milliseconds 100 }
                }
                if (-not $ready) { throw 'Owned aria2 RPC instance did not become ready.' }
                $gid = Invoke-DownloadRpc addUri @(@($URL.AbsoluteUri), @{ dir = $stage; out = 'payload' })
                do {
                    $status = Invoke-DownloadRpc tellStatus @($gid)
                    if ($status.status -in 'error','removed') { throw "aria2 download failed: $($status.status)." }
                    if ($status.status -eq 'complete') { break }
                    Start-Sleep -Milliseconds 100
                } while ($true)
                if ([long]$status.completedLength -ne [long]$status.totalLength) { throw 'RPC completion length mismatch.' }
                if ($ExpectedLength -lt 0) { $ExpectedLength = [long]$status.totalLength }
            }
        }
        $file = Get-Item -LiteralPath $partial -ErrorAction Stop
        if ($file.PSIsContainer -or ($file.Length -eq 0 -and -not $AllowEmpty)) { throw 'Download produced no file content.' }
        if ($ExpectedLength -ge 0 -and $file.Length -ne $ExpectedLength) { throw 'Downloaded length differs from the expected length.' }
        if ($ExpectedSHA256 -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $ExpectedSHA256) { throw 'Downloaded SHA256 differs from the expected hash.' }
        [IO.File]::Move($partial, $destination, [bool]$Force)
        $destination
    }
    catch {
        throw "Download failed using $Transport; no replacement was published. Check availability, authentication, expected size/hash and timeout."
    }
    finally {
        if ($ownedProcess) {
            try {
                if (-not $ownedProcess.HasExited) { $ownedProcess.Kill($true); $null = $ownedProcess.WaitForExit(5000) }
                if ($stdoutTask) { $null = $stdoutTask.Wait(5000) }
                if ($stderrTask) { $null = $stderrTask.Wait(5000) }
            } finally { $ownedProcess.Dispose() }
        }
        foreach ($temporary in @($configPath, $partial, ($partial + '.aria2'))) {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
        if ([IO.File]::Exists($logPath)) { Write-Verbose "aria2 diagnostics retained at $logPath" }
        if ([IO.Directory]::Exists($stage) -and [IO.Directory]::GetFileSystemEntries($stage).Length -eq 0) { [IO.Directory]::Delete($stage) }
    }
}
