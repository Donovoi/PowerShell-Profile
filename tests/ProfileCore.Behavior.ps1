#requires -Version 7.0
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($TestRoot)
if (Test-Path -LiteralPath $root) { throw 'Use a new disposable TestRoot.' }
$null = [IO.Directory]::CreateDirectory($root)
$repo = Split-Path $PSScriptRoot -Parent
$functions = Join-Path $repo 'functions'
$checks = [Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body; throw 'Expected an exception, but none was thrown.' }
    catch { if ($_.Exception.Message -notmatch $Pattern) { throw } }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $checks.Add($Name)
    Write-Host "PASS $Name"
}
foreach ($name in @('Initialize-CmdletDependencies','Install-Cmdlet','Write-Logg','Invoke-Process','Get-FileEncoding','Test-ByteOrderMark','Format-Bytes','Test-InPath','Test-IsAdministrator','Test-RunningAsElevated','Start-AsAdmin','Invoke-RunAsAdmin')) {
    . (Join-Path $functions "$name.ps1")
}

Test-Case 'Standalone bootstrap downloads and exports installer and dependency in a fresh session' {
    $child = Join-Path $root 'standalone-bootstrap.ps1'
    $code = @'
param([string]$SourceDirectory)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$global:ReviewSourceDirectory = $SourceDirectory
$global:ReviewDownloadCount = 0
function global:Invoke-RestMethod {
    [CmdletBinding()] param($Uri, $TimeoutSec)
    $global:ReviewDownloadCount++
    if ($TimeoutSec -ne 17 -or $Uri -notlike 'https://example.test/review/*') { throw 'Bootstrap lost repository or timeout options.' }
    if ($Uri -like '*/Install-Cmdlet.ps1') { return [IO.File]::ReadAllText((Join-Path $global:ReviewSourceDirectory 'Install-Cmdlet.ps1')) }
    if ($Uri -like '*/Get-ReviewRemote.ps1') { return 'function Get-ReviewRemote { 99 }' }
    throw "Unexpected download: $Uri"
}
. (Join-Path $SourceDirectory 'Initialize-CmdletDependencies.ps1')
& { Initialize-CmdletDependencies Get-ReviewRemote -NoLocalFallback -RepositoryUrl 'https://example.test/review' -TimeoutSeconds 17 -MaxRetries 1 }
if ((Get-ReviewRemote) -ne 99 -or $global:ReviewDownloadCount -ne 2 -or -not (Get-Command Install-Cmdlet -ErrorAction Ignore)) { throw 'Standalone bootstrap did not export usable commands.' }
'bootstrap passed'
'@
    [IO.File]::WriteAllText($child, $code)
    $result = Invoke-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',$child,$functions) -PassThru -TimeoutSeconds 15
    Assert-True ($result.StandardOutput.Trim() -eq 'bootstrap passed') 'Standalone bootstrap did not finish.'
}

Test-Case 'Local dependencies survive loader scope and preserve PSScriptRoot' {
    $sourceDirectory = Join-Path $root 'local source'
    $null = [IO.Directory]::CreateDirectory($sourceDirectory)
    Copy-Item -LiteralPath (Join-Path $functions 'Initialize-CmdletDependencies.ps1') -Destination $sourceDirectory
    [IO.File]::WriteAllText((Join-Path $sourceDirectory 'Get-ReviewLocal.ps1'), 'function Get-ReviewLocal { $PSScriptRoot }')
    & {
        . (Join-Path $sourceDirectory 'Initialize-CmdletDependencies.ps1')
        Initialize-CmdletDependencies Get-ReviewLocal -PreferLocal
    }
    Assert-True ((Get-ReviewLocal) -eq $sourceDirectory) 'Local dependency disappeared or lost its source directory.'
    function Invoke-RestMethod { throw 'Network must not be used for an already loaded command.' }
    Initialize-CmdletDependencies Get-ReviewLocal
    Assert-True ((Get-ReviewLocal) -eq $sourceDirectory) 'Already loaded dependency changed.'
}

Test-Case 'Cold and warm caches, pipeline inputs, URL cache and failed refresh' {
    $cache = Join-Path $root 'cache'
    $script:downloadCount = 0
    $script:badDownload = $false
    function Invoke-RestMethod {
        [CmdletBinding()] param($Uri, $TimeoutSec)
        $script:downloadCount++
        if ($script:badDownload) { return 'function Get-Broken {' }
        $name = [IO.Path]::GetFileNameWithoutExtension(([uri]$Uri).AbsolutePath)
        "function $name { '$name result' }"
    }
    $paths = @('Get-ReviewOne','Get-ReviewTwo' | Install-Cmdlet -PreferLocal -LocalModuleFolder $cache -GitHubRepositoryUrl 'https://example.test/functions')
    Assert-True ($paths.Count -eq 2 -and $script:downloadCount -eq 2) 'Pipeline commands were lost or downloaded repeatedly.'
    Assert-True ((Get-ReviewOne) -eq 'Get-ReviewOne result' -and (Get-ReviewTwo) -eq 'Get-ReviewTwo result') 'Cold cache commands unavailable.'
    # Remove the exported module so the next check proves a warm-cache import.
    Get-Module | Where-Object { $_.ExportedCommands.ContainsKey('Get-ReviewOne') } | Remove-Module -Force
    $null = Install-Cmdlet -RepositoryCmdlets Get-ReviewOne -PreferLocal -LocalModuleFolder $cache
    Assert-True ($script:downloadCount -eq 2 -and (Get-ReviewOne) -eq 'Get-ReviewOne result') 'Warm cache was not imported without a download.'
    $urlPaths = @(Install-Cmdlet -Urls 'https://example.test/Get-ReviewUrl.ps1?raw=1' -PreferLocal -LocalModuleFolder $cache)
    Assert-True ($urlPaths.Count -eq 1 -and (Get-ReviewUrl) -eq 'Get-ReviewUrl result') 'URL cache command not imported.'
    $oldBytes = [IO.File]::ReadAllText($paths[0])
    $script:badDownload = $true
    Assert-Throws { Install-Cmdlet -RepositoryCmdlets Get-ReviewOne -PreferLocal -LocalModuleFolder $cache -Force } 'Invalid script'
    Assert-True ([IO.File]::ReadAllText($paths[0]) -eq $oldBytes) 'Failed refresh destroyed valid cached code.'
    function Invoke-RestMethod { [CmdletBinding()] param($Uri,$TimeoutSec) throw 'Offline fixture' }
    Assert-Throws { Install-Cmdlet -RepositoryCmdlets Get-ReviewOne -PreferLocal -LocalModuleFolder $cache -Force } 'Offline fixture'
    Assert-True ([IO.File]::ReadAllText($paths[0]) -eq $oldBytes) 'Network failure changed the cache.'
}

Test-Case 'In-memory import, WhatIf, invalid input and terminating failures' {
    $script:networkCalls = 0
    function Invoke-RestMethod {
        [CmdletBinding()] param($Uri,$TimeoutSec)
        $script:networkCalls++
        'function Get-ReviewMemory { 42 }'
    }
    $module = Install-Cmdlet -RepositoryCmdlets Get-ReviewMemory -LocalModuleFolder (Join-Path $root 'unused-cache')
    Assert-True ($module -is [Management.Automation.PSModuleInfo] -and (Get-ReviewMemory) -eq 42) 'In-memory module did not export its command.'
    Assert-True (-not (Test-Path (Join-Path $root 'unused-cache'))) 'In-memory mode wrote a cache.'
    $whatIfCache = Join-Path $root 'whatif-cache'
    $null = Install-Cmdlet -RepositoryCmdlets Get-ReviewWhatIf -PreferLocal -LocalModuleFolder $whatIfCache -WhatIf
    Initialize-CmdletDependencies Get-ReviewWhatIf -NoLocalFallback -WhatIf
    Assert-True ($script:networkCalls -eq 1 -and -not (Test-Path $whatIfCache) -and -not (Get-Command Get-ReviewWhatIf -ErrorAction Ignore)) 'WhatIf caused installation side effects.'
    Assert-Throws { '../escape' | Install-Cmdlet -PreferLocal -LocalModuleFolder $whatIfCache } 'Invalid command name'
    Assert-Throws { Install-Cmdlet -Urls 'http://example.test/Get-Example.ps1' -RequireHttps } 'Invalid script URL'
    Assert-True ($script:networkCalls -eq 1) 'Invalid input reached the network.'
}

Test-Case 'Loader forwards custom repository, timeout and retries; missing export fails' {
    $script:loaderCalls = 0
    function Install-Cmdlet {
        [CmdletBinding(SupportsShouldProcess)] param($RepositoryCmdlets,$GitHubRepositoryUrl,$TimeoutSeconds,[switch]$PreferLocal,[switch]$Force,$LocalModuleFolder)
        $script:loaderCalls++
        Assert-True ($GitHubRepositoryUrl -eq 'https://example.test/custom' -and $TimeoutSeconds -eq 17) 'Loader dropped installation options.'
        if ($script:loaderCalls -lt 2) { throw 'Transient fixture failure' }
        function global:Get-ReviewRetry { 'ready' }
    }
    Initialize-CmdletDependencies Get-ReviewRetry -RepositoryUrl 'https://example.test/custom' -TimeoutSeconds 17 -MaxRetries 2 -RetryDelaySeconds 0
    Assert-True ($script:loaderCalls -eq 2 -and (Get-ReviewRetry) -eq 'ready') 'Retry did not produce a usable command.'
    function Install-Cmdlet { [CmdletBinding(SupportsShouldProcess)] param($RepositoryCmdlets,$GitHubRepositoryUrl,$TimeoutSeconds,[switch]$PreferLocal,[switch]$Force) throw 'Permanent fixture failure' }
    Assert-Throws { Initialize-CmdletDependencies Get-ReviewAbsent -MaxRetries 2 -RetryDelaySeconds 0 } 'Permanent fixture failure'
    function Install-Cmdlet { [CmdletBinding(SupportsShouldProcess)] param($RepositoryCmdlets,$GitHubRepositoryUrl,$TimeoutSeconds,[switch]$PreferLocal,[switch]$Force) }
    Assert-Throws { Initialize-CmdletDependencies Get-ReviewAbsent -MaxRetries 1 } 'without making'
}

Test-Case 'Plain and pipeline logging needs no downloads; compatibility and file opt-in' {
    function Initialize-CmdletDependencies { throw 'Plain logging must not resolve dependencies.' }
    function Invoke-RestMethod { throw 'Plain logging must not use the network.' }
    $logPath = Join-Path $root 'log [literal].txt'
    Write-Logg 'plain' -NoConsoleOutput -NoLogFile -ForegroundColor Yellow -LogFile $logPath
    Assert-True (-not (Test-Path -LiteralPath $logPath)) 'Logging wrote a file without opt-in.'
    'alpha','beta' | Write-Logg -NoConsoleOutput -LogToFile -LogFile $logPath
    $lines = @(Get-Content -LiteralPath $logPath)
    Assert-True ($lines.Count -eq 2 -and $lines[0] -match 'INFO: alpha$' -and $lines[1] -match 'INFO: beta$') 'Pipeline log output is not correct.'
    Write-Logg 'suppressed' -NoConsoleOutput -LogToFile -NoLogFile -LogFile $logPath
    Assert-True (@(Get-Content -LiteralPath $logPath).Count -eq 2) 'NoLogFile compatibility did not suppress file output.'
}

Test-Case 'Optional logging failures preserve basic output and disable unavailable popups' {
    function Initialize-CmdletDependencies { [CmdletBinding()] param($RequiredCmdlets,[switch]$PreferLocal) throw 'Offline optional dependency fixture' }
    function New-WPFMessageBox { throw 'An unavailable popup was still invoked.' }
    function Show-TUIConfirmationDialog { throw 'An unavailable popup was still invoked.' }
    $logPath = Join-Path $root 'fallback.log'
    Write-Logg 'fallback message' -WPFPopUpMessage -TUIPopUpMessage -LogToFile -LogFile $logPath -NoConsoleOutput -WarningAction SilentlyContinue
    Assert-True ((Get-Content -LiteralPath $logPath -Raw) -match 'INFO: fallback message') 'Optional dependency failure suppressed ordinary logging.'
    Write-Logg 'fallback colour' -Level LOLCAT -LogToFile -LogFile $logPath -NoConsoleOutput -WarningAction SilentlyContinue
    Assert-True ((Get-Content -LiteralPath $logPath -Raw) -match 'INFO: fallback colour') 'Missing colour dependency did not fall back to INFO.'
}

Test-Case 'All BOMs, short files, literal paths and explicit fallback' {
    $encodings = @([Text.UTF8Encoding]::new($true),[Text.UnicodeEncoding]::new($false,$true),[Text.UnicodeEncoding]::new($true,$true),[Text.UTF32Encoding]::new($false,$true),[Text.UTF32Encoding]::new($true,$true))
    foreach ($encoding in $encodings) {
        $path = Join-Path $root ("encoding [$($encoding.CodePage)].txt")
        [IO.File]::WriteAllBytes($path, [byte[]]($encoding.GetPreamble() + $encoding.GetBytes('Text Ω')))
        $found = Get-FileEncoding $path
        Assert-True ($found.CodePage -eq $encoding.CodePage) "Wrong encoding for code page $($encoding.CodePage)."
        Assert-True ((Test-ByteOrderMark $path).CodePage -eq $encoding.CodePage) 'BOM helper disagrees.'
    }
    foreach ($bytes in @([byte[]]@(),[byte[]]@(0xFF),[byte[]]@(0xEF,0xBB),[Text.Encoding]::UTF8.GetBytes('é'))) {
        $path = Join-Path $root 'short.txt'
        [IO.File]::WriteAllBytes($path,$bytes)
        Assert-True ((Test-ByteOrderMark $path) -eq $false) 'Partial signature mistaken for BOM.'
        Assert-True ($null -eq (Get-FileEncoding $path)) 'BOMless encoding was guessed.'
        Assert-True ((Get-FileEncoding $path -FallbackEncoding ([Text.Encoding]::UTF8)).CodePage -eq 65001) 'Explicit fallback ignored.'
    }
}

Test-Case 'Byte thresholds and Windows executable discovery' {
    Assert-True ((Format-Bytes 0) -match '^0[.,]00 B$') 'Zero formatting changed.'
    foreach ($case in @(@(1KB,'KB'),@(1MB,'MB'),@(1GB,'GB'),@(1TB,'TB'),@(1PB,'PB'))) {
        Assert-True ((Format-Bytes $case[0]) -match ("^1[.,]00 " + $case[1] + '$')) 'Exact binary threshold is wrong.'
    }
    Assert-Throws { Format-Bytes -1 } 'validat'
    Assert-Throws { Format-Bytes ([double]::NaN) } 'validat'
    Assert-True (Test-InPath pwsh) 'PATHEXT executable lookup failed.'
    function Get-ReviewNotAnExe { }
    Assert-True (-not (Test-InPath Get-ReviewNotAnExe)) 'Function was treated as an executable.'
}

Test-Case 'Native arguments, full stdout/stderr, trailing output and exit status' {
    $child = Join-Path $root "child's process.ps1"
    [IO.File]::WriteAllText($child, 'param([string]$First,[string]$Second,[string]$Third); [Console]::Out.Write((@($First,$Second,$Third) | ConvertTo-Json -Compress)); [Console]::Error.Write("complete stderr"); exit 7')
    $argsExpected = @('path with spaces', 'quote " inside', '')
    $result = Invoke-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList (@('-NoProfile','-File',$child) + $argsExpected) -PassThru -IgnoreExitCode
    $actual = @($result.StandardOutput | ConvertFrom-Json)
    Assert-True ($result.ExitCode -eq 7 -and $result.StandardError -eq 'complete stderr') 'Exit code or stderr lost.'
    Assert-True ($actual.Count -eq 3 -and $actual[0] -ceq $argsExpected[0] -and $actual[1] -ceq $argsExpected[1] -and $actual[2] -ceq '') 'Native argument boundaries were changed.'
    $single = @(Invoke-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-Command','[Console]::Write("whole line")'))
    Assert-True ($single.Count -eq 1 -and $single[0] -eq 'whole line') 'Single output line truncated.'
    Assert-Throws { Invoke-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-Command','exit 9') } 'exited with code 9'
}

Test-Case 'Native stream pressure, redirection, timeout and WhatIf' {
    $outPath = Join-Path $root 'stdout.txt'
    $errPath = Join-Path $root 'stderr.txt'
    $result = Invoke-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-Command','[Console]::Out.Write("x" * 100000); [Console]::Error.Write("y" * 100000)') -PassThru -TimeoutSeconds 15 -RedirectStandardOutput $outPath -RedirectStandardError $errPath
    Assert-True ($result.StandardOutput.Length -eq 100000 -and $result.StandardError.Length -eq 100000) 'Pipe pressure lost output or deadlocked.'
    Assert-True (([IO.File]::ReadAllText($outPath)).Length -eq 100000 -and ([IO.File]::ReadAllText($errPath)).Length -eq 100000) 'Redirected files were removed or incomplete.'
    $pidFile = Join-Path $root 'timed-process.txt'
    $code = '[IO.File]::WriteAllText(''' + $pidFile.Replace("'","''") + ''',[string]$PID); Start-Sleep 30'
    Assert-Throws { Invoke-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-Command',$code) -TimeoutSeconds 2 } 'exceeded 2 seconds'
    Assert-True (Test-Path -LiteralPath $pidFile) 'Timeout child never started.'
    Assert-True (-not (Get-Process -Id ([int][IO.File]::ReadAllText($pidFile)) -ErrorAction Ignore)) 'Timed-out child still running.'
    $missingOutput = Join-Path $root 'whatif-output.txt'
    Invoke-Process 'does-not-exist.exe' -RedirectStandardOutput $missingOutput -WhatIf
    Assert-True (-not (Test-Path $missingOutput)) 'Process WhatIf wrote output.'
}

Test-Case 'Elevation checks agree; elevation wrappers preserve paths and caller' {
    $one = Test-IsAdministrator
    $two = Test-RunningAsElevated
    Assert-True ($one -is [bool] -and $two -is [bool] -and $one -eq $two) 'Elevation checks disagree.'
    $target = Join-Path $root "elevation target's.ps1"
    $received = Join-Path $root 'elevation-arguments.json'
    [IO.File]::WriteAllText($target, 'param([string]$One,[string]$Two); @($One,$Two) | ConvertTo-Json -Compress | Set-Content -LiteralPath '''+$received.Replace("'","''")+'''')
    $script:launch = $null
    function Start-Process {
        [CmdletBinding()] param($FilePath,$ArgumentList,$Verb,$WorkingDirectory,$WindowStyle,[switch]$PassThru)
        $script:launch = $PSBoundParameters
        if ($PassThru) { [pscustomobject]@{ Id = 123 } }
    }
    $result = Invoke-RunAsAdmin -FilePath $target -ArgumentList @('first value','quote " $value ;') -PassThru
    Assert-True ($result.Id -eq 123 -and $script:launch.Verb -eq 'RunAs') 'Elevation wrapper lost PassThru or RunAs.'
    $encoded = $script:launch.ArgumentList[-1]
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
    # Execute the handoff payload unelevated against a harmless fixture.
    & ([scriptblock]::Create($decoded))
    $values = @(Get-Content -LiteralPath $received -Raw | ConvertFrom-Json)
    Assert-True ($values[0] -eq 'first value' -and $values[1] -ceq 'quote " $value ;') 'Elevation payload changed arguments.'
    $script:launch = $null
    Start-AsAdmin -FilePath $target -WhatIf
    Assert-True ($null -eq $script:launch) 'WhatIf triggered elevation.'
}
[pscustomobject]@{ Passed = $checks.Count; Checks = $checks; TestRoot = $root } | ConvertTo-Json -Depth 4
