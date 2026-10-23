#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot,[string]$FFmpegFixturePath)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'Use a new fixture directory.' }
$null = [IO.Directory]::CreateDirectory($TestRoot)
foreach ($name in 'Initialize-CmdletDependencies','Get-FinalOutputPath','Get-OutputFilename','Invoke-Process','Invoke-ValidatedDownload','Get-FileDownload','Get-LatestGitHubRelease','Invoke-AriaDownload','Invoke-AriaRPCDownload','ConvertTo-Aria2cCookies','Extract-ZipFile','Get-FFmpeg') { . "$PSScriptRoot/../functions/$name.ps1" }
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock]$Body) { $failed=$false; try { & $Body | Out-Null } catch { $failed=$true }; Assert $failed 'Expected a terminating failure' }
$aria = (Get-Command aria2c.exe -CommandType Application -ErrorAction Stop).Source
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$probe.Start(); $port=$probe.LocalEndpoint.Port; $probe.Stop()
$server = Start-Job -ArgumentList $TestRoot,$port -ScriptBlock {
    param($Root,$Port)
    $listener=[Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Start()
    [IO.File]::WriteAllText("$Root/ready",'ready')
    try {
        while ($listener.IsListening) {
            $context=$listener.GetContext()
            $request=$context.Request
            $record=@{Path=$request.Url.AbsolutePath;Authorization=$request.Headers['Authorization'];Custom=$request.Headers['X-Fixture'];Cookie=$request.Headers['Cookie']}
            [IO.File]::AppendAllText("$Root/requests.jsonl",(($record|ConvertTo-Json -Compress)+[Environment]::NewLine))
            $response=$context.Response
            $bytes=[Text.Encoding]::UTF8.GetBytes('download fixture bytes')
            switch ($request.Url.AbsolutePath) {
                '/empty.bin' { $bytes=[byte[]]::new(0) }
                '/missing.bin' { $response.StatusCode=404 }
                '/slow.bin' { Start-Sleep -Seconds 2 }
                '/asset' { $response.Headers.Add('Content-Disposition','attachment; filename="../../named file.bin"') }
                '/ffmpeg.zip' { $bytes=[IO.File]::ReadAllBytes("$Root/ffmpeg.zip") }
            }
            $response.ContentLength64=$bytes.Length
            try { if ($request.HttpMethod -ne 'HEAD') { $response.OutputStream.Write($bytes) } } catch {} finally { $response.Close() }
            if ($request.Url.AbsolutePath -eq '/__stop') { break }
        }
    } finally { $listener.Close() }
}
try {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists("$TestRoot/ready") -and $timer.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
    Assert ([IO.File]::Exists("$TestRoot/ready")) 'Fixture server did not start'
    $base="http://127.0.0.1:$port"
    $headers=@{Authorization='Bearer fixture-secret';'X-Fixture'='two headers'}
    $before=@(Get-Process aria2c -ErrorAction SilentlyContinue).Id
    foreach ($transport in 'Native','Aria2','RPC') {
        $path=Join-Path $TestRoot "$transport.bin"
        $result=Invoke-ValidatedDownload -URL "$base/bytes.bin" -OutFile $path -Transport $transport -Aria2cExePath $aria -Headers $headers -ExpectedLength 22 -TimeoutSeconds 15
        Assert (@($result).Count -eq 1 -and $result -eq $path -and [IO.File]::ReadAllText($path) -eq 'download fixture bytes') "$transport did not produce exact bytes/path"
        Assert-Fails { Invoke-ValidatedDownload -URL "$base/bytes.bin" -OutFile $path -Transport $transport -Aria2cExePath $aria }
        Assert-Fails { Invoke-ValidatedDownload -URL "$base/missing.bin" -OutFile $path -Transport $transport -Aria2cExePath $aria -Force -TimeoutSeconds 10 }
        Assert ([IO.File]::ReadAllText($path) -eq 'download fixture bytes') "$transport failure damaged old file"
        Assert-Fails { Invoke-ValidatedDownload -URL "$base/empty.bin" -OutFile "$TestRoot/empty-$transport.bin" -Transport $transport -Aria2cExePath $aria -TimeoutSeconds 10 }
        $null=Invoke-ValidatedDownload -URL "$base/empty.bin" -OutFile "$TestRoot/empty-$transport.bin" -Transport $transport -Aria2cExePath $aria -AllowEmpty -ExpectedLength 0 -TimeoutSeconds 10
        Assert ([IO.FileInfo]::new("$TestRoot/empty-$transport.bin").Length -eq 0) 'Explicit empty file failed'
    }
    $after=@(Get-Process aria2c -ErrorAction SilentlyContinue).Id
    Assert (@($after | Where-Object {$_ -notin $before}).Count -eq 0) 'RPC process leaked'
    $records=Get-Content -LiteralPath "$TestRoot/requests.jsonl" | ConvertFrom-Json
    Assert (@($records | Where-Object { $_.Authorization -eq 'Bearer fixture-secret' -and $_.Custom -eq 'two headers' }).Count -ge 3) 'Headers missing in one transport'
    Assert (@(Get-ChildItem -LiteralPath $TestRoot -Filter aria2.conf -Recurse -Force).Count -eq 0) 'Credential config leaked'
    Write-Host 'PASS: real native/aria2/RPC bytes, headers, completion, empty-file and failure-preservation checks'

    $null=Invoke-ValidatedDownload -URL "$base/bytes.bin" -OutFile "$TestRoot/whatif/file" -WhatIf
    Assert (-not [IO.Directory]::Exists("$TestRoot/whatif")) 'WhatIf wrote a directory'
    Assert-Fails { Invoke-ValidatedDownload -URL "$base/bytes.bin" -OutFile "$TestRoot/hash.bin" -ExpectedSHA256 ('0'*64) }
    Assert (-not [IO.File]::Exists("$TestRoot/hash.bin")) 'Bad hash was published'
    Assert-Fails { Invoke-ValidatedDownload -URL "$base/bytes.bin" -OutFile "$TestRoot/size.bin" -ExpectedLength 1 }
    Assert-Fails { Invoke-AriaRPCDownload -URL "$base/slow.bin" -OutFile "$TestRoot/timeout.bin" -Aria2cExePath $aria -TimeoutSeconds 1 }
    Start-Sleep -Seconds 2
    Assert (-not [IO.File]::Exists("$TestRoot/timeout.bin")) 'Timed-out RPC was published'
    $names=@("$base/one.bin","$base/two.bin") | Get-FileDownload -DestinationDirectory "$TestRoot/multiple" -ForceNativeDownload
    Assert ($names.Count -eq 2 -and [IO.File]::Exists($names[0]) -and [IO.File]::Exists($names[1])) 'Pipeline dropped results'
    $named=Get-OutputFilename -Url "$base/asset" -DestDir $TestRoot -HeadersToUse $headers
    Assert ($named -eq "$TestRoot\named file.bin") 'Header filename escaped or was lost'
    Assert-Fails { Get-FinalOutputPath -BasePath "$TestRoot/Native.bin" }
    Assert ((Get-FinalOutputPath -BasePath "$TestRoot/Native.bin" -Force) -eq "$TestRoot\Native.bin") 'Force path resolution failed'
    Write-Host 'PASS: timeout, hash/length rejection, pipeline results, header filename and overwrite policy'

    $realDownload=${function:Invoke-ValidatedDownload}
    $script:transports=[Collections.Generic.List[string]]::new()
    function Invoke-ValidatedDownload {
        [CmdletBinding()] param($URL,$OutFile,$Headers,$Force,$AllowEmpty,$TimeoutSeconds,$ExpectedLength,$AriaConsoleLogLevel,$LogToFile,$Transport='Native',$Aria2cExePath,[switch]$Confirm)
        $script:transports.Add($Transport)
        if ($Transport -eq 'Aria2' -and $script:transports.Count -eq 1) { throw 'Simulated first transport failure' }
        & $realDownload @PSBoundParameters
    }
    $fallback=@(Get-FileDownload -URL @("$base/a.bin","$base/b.bin") -DestinationDirectory "$TestRoot/fallback" -UseAria2 -NoRPCMode -aria2cExe $aria)
    Assert ($fallback.Count -eq 2 -and ($script:transports -join ',') -eq 'Aria2,Native,Aria2') 'Fallback state leaked between URLs'
    Set-Item Function:Invoke-ValidatedDownload $realDownload
    Write-Host 'PASS: per-URL fallback resets before the next URL'

    $cookies=[Net.CookieContainer]::new()
    $cookie=[Net.Cookie]::new('session','fixture','/','.example.test')
    $cookie.HttpOnly=$true; $cookie.Secure=$true; $cookie.Expires=[datetime]::Parse('2030-01-01T00:00:00Z').ToUniversalTime()
    $cookies.Add($cookie)
    $cookiePath=ConvertTo-Aria2cCookies -Cookies $cookies -CookieFilePath "$TestRoot/cookies.txt" -Domain example.test
    $fields=([IO.File]::ReadAllLines($cookiePath)[1]).Split("`t")
    Assert ($fields.Count -eq 7 -and $fields[0] -eq '#HttpOnly_.example.test' -and $fields[1] -eq 'TRUE' -and $fields[3] -eq 'TRUE' -and $fields[4] -eq '1893456000') 'Netscape cookie layout or epoch incorrect'
    Write-Host 'PASS: Netscape flags, HttpOnly prefix, tabs and Unix expiration'

    $realFileDownload=${function:Get-FileDownload}
    function Invoke-RestMethod {
        [CmdletBinding()] param($Uri,$Headers,$TimeoutSec)
        Assert ($Headers.Authorization -eq 'Bearer fixture-token') 'Metadata token missing'
        [pscustomobject]@{tag_name='v1';published_at='2026-01-01';draft=$false;prerelease=$false;assets=@([pscustomobject]@{name='asset.zip';url='https://api.github.com/repos/test/repo/releases/assets/1';browser_download_url='https://github.com/test/repo/releases/download/v1/asset.zip';size=22;digest=('sha256:'+'a'*64)})}
    }
    function Get-FileDownload {
        [CmdletBinding()] param($URL,$DestinationDirectory,$FileName,$Headers,$GitHub,$IsPrivateRepo,$UseAria2,$NoRPCMode,$Force,$TimeoutSeconds,$ExpectedLength,$AllowEmpty,$Token,$ExpectedSHA256,[switch]$Confirm)
        Assert ($URL -like 'https://api.github.com/*' -and $Headers.Authorization -eq 'Bearer fixture-token' -and $Headers.Accept -eq 'application/octet-stream' -and $Token -eq 'fixture-token') 'Private asset authentication lost'
        Assert ($FileName -eq 'asset.zip' -and $ExpectedLength -eq 22 -and $ExpectedSHA256 -eq ('a'*64)) 'Asset name/size/hash not forwarded'
        'fixture-result'
    }
    Assert ((Get-LatestGitHubRelease -OwnerRepository test/repo -Token fixture-token -PrivateRepo -AssetName asset.zip) -eq 'fixture-result') 'Release download result lost'
    Remove-Item Function:Invoke-RestMethod
    Set-Item Function:Get-FileDownload $realFileDownload
    Write-Host 'PASS: private release uses authenticated asset API and forwards name/size/hash'

    $zip=[IO.Compression.ZipFile]::Open("$TestRoot/ffmpeg.zip",'Create')
    $entry=$zip.CreateEntry('ffmpeg-release/bin/ffmpeg.exe',[IO.Compression.CompressionLevel]::NoCompression)
    $entryStream=$entry.Open()
    try {
        if($FFmpegFixturePath){
            $binaryStream=[IO.File]::OpenRead($FFmpegFixturePath)
            try{$binaryStream.CopyTo($entryStream)}finally{$binaryStream.Dispose()}
        }else{$entryStream.Write([Text.Encoding]::UTF8.GetBytes('fake executable bytes'))}
    }finally{$entryStream.Dispose();$zip.Dispose()}
    $realProcess=${function:Invoke-Process}
    function Invoke-Process {
        [CmdletBinding()] param($FilePath,$ArgumentList,[switch]$PassThru,$TimeoutSeconds)
        if($FFmpegFixturePath){return (& $realProcess @PSBoundParameters)}
        Assert ([IO.File]::ReadAllText($FilePath) -eq 'fake executable bytes' -and $ArgumentList[0] -eq '-version') 'FFmpeg version check not executed on the extracted file'
        [pscustomobject]@{StandardOutput='ffmpeg version fixture';ExitCode=0}
    }
    $ffmpeg=Get-FFmpeg -Url "$base/ffmpeg.zip" -LocalDependencies -LocalPath "$TestRoot/local"
    Assert ($ffmpeg -eq "$TestRoot\local\ffmpeg\bin\ffmpeg.exe") 'FFmpeg layout or returned path incorrect'
    if($FFmpegFixturePath){Assert ((Get-FileHash -LiteralPath $ffmpeg).Hash -eq (Get-FileHash -LiteralPath $FFmpegFixturePath).Hash) 'Real FFmpeg changed during download/extraction'}
    else{Assert ([IO.File]::ReadAllText($ffmpeg) -eq 'fake executable bytes') 'FFmpeg extraction changed bytes'}
    Assert ((Get-FFmpeg -DestinationPath $ffmpeg) -eq $ffmpeg) 'Existing FFmpeg validation failed'
    Assert-Fails { Get-FFmpeg -Url "$base/ffmpeg.7z" -DestinationPath "$TestRoot/unsupported.exe" }
    Set-Item Function:Invoke-Process $realProcess
    Write-Host 'PASS: FFmpeg archive layout, executable validation hook, existing installation and unsupported archive rejection'
}
finally {
    try { $null=Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri "http://127.0.0.1:$port/__stop" -TimeoutSec 5 -ErrorAction Stop } catch {}
    $null=Wait-Job $server -Timeout 10
    if ($server.State -eq 'Running') { throw 'Fixture HTTP job did not stop; inspect the retained job.' }
    Remove-Job $server -Force
}
