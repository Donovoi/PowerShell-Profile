#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$TestRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
$repo=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new TestRoot.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
. (Join-Path $repo 'functions/Invoke-ExecutableAnalysis.ps1')
. (Join-Path $repo 'scripts/ExecutableAnalysis/Invoke-AnalysisTool.ps1')
. (Join-Path $repo 'scripts/ExecutableAnalysis/Get-AnalysisIdentity.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Throws([scriptblock]$Body,[string]$Pattern){try{& $Body;throw 'Expected exception'}catch{if($_.Exception.Message -notmatch $Pattern){throw}}}
$target=Join-Path $TestRoot 'test [literal] & fixture.bin'
$bytes=[Text.Encoding]::ASCII.GetBytes('Header marker SGVsbG8gZXZpZGVuY2U= another-string')+[byte[]]@(0,1,2)+[Text.Encoding]::Unicode.GetBytes('UNICODE_MARKER')
[IO.File]::WriteAllBytes($target,$bytes)
$hash=(Get-FileHash -LiteralPath $target).Hash
$preview=Join-Path $TestRoot 'no-whatif-files'
Invoke-ExecutableAnalysis -Path $target -OutputDirectory $preview -WhatIf
Assert-True (-not(Test-Path -LiteralPath $preview)) 'WhatIf created outputs.'
Assert-Throws {Invoke-ExecutableAnalysis -Path $TestRoot -BasicOnly -SkipAI} 'one filesystem file'
$empty=Join-Path $TestRoot 'empty';[IO.File]::WriteAllBytes($empty,[byte[]]@())
Assert-Throws {Invoke-ExecutableAnalysis -Path $empty -BasicOnly -SkipAI} 'empty input'
$first=Invoke-ExecutableAnalysis -Path $target -OutputDirectory $TestRoot -BasicOnly -SkipAI -NoInstall
$second=Invoke-ExecutableAnalysis -Path $target -OutputDirectory $TestRoot -BasicOnly -SkipAI -NoInstall
Assert-True ($first.Status -eq 'CompletedWithLimitations') ('Basic run failed: '+(Get-Content -LiteralPath $first.JsonPath -Raw))
Assert-True ($first.SourceUnchanged -and (Get-FileHash -LiteralPath $target).Hash -eq $hash) 'Input changed.'
Assert-True ($first.OutputDirectory -ne $second.OutputDirectory) 'Repeated run reused its output.'
$record=Get-Content -LiteralPath $first.JsonPath -Raw|ConvertFrom-Json
foreach($artifact in $record.Artifacts){Assert-True ((Get-FileHash -LiteralPath (Join-Path $first.OutputDirectory $artifact.Path)).Hash -eq $artifact.SHA256) 'Artifact hash mismatch.'}
$strings=Get-Content -LiteralPath (Join-Path $first.OutputDirectory 'basic/strings.json') -Raw|ConvertFrom-Json
Assert-True (@($strings|Where-Object Text -EQ 'UNICODE_MARKER').Count -eq 1) 'UTF-16 extraction failed.'
Push-Location -LiteralPath $TestRoot
try{$default=Invoke-ExecutableAnalysis $target -BasicOnly -SkipAI -NoInstall;Assert-True ((Split-Path $default.OutputDirectory -Parent) -eq $TestRoot) 'Default output is not current directory.'}finally{Pop-Location}
Write-Host 'PASS: literal input, WhatIf, preservation, unique/default output, hashes, UTF-16 and explicit skipped stages.'

$encoded=Join-Path $TestRoot 'encoded.bin';[IO.File]::WriteAllText($encoded,'SGVsbG8gZXZpZGVuY2U=')
$decodeFolder=Join-Path $TestRoot 'decode';$null=[IO.Directory]::CreateDirectory($decodeFolder)
$null=Export-AnalysisString $encoded $decodeFolder
$decoded=Get-Content -LiteralPath (Join-Path $decodeFolder 'decoded-candidates.json') -Raw|ConvertFrom-Json
Assert-True ($decoded[0].Text -eq 'Hello evidence') 'Base64 decoding changed content.'
foreach($case in @(
    @{Name='elf';Bytes=[byte[]]@(0x7f,69,76,70,2,1,1,0,0,0,0,0,0,0,0,0,2,0,62,0);Format='ELF'},
    @{Name='wasm';Bytes=[byte[]]@(0,97,115,109,1,0,0,0);Format='WASM'},
    @{Name='fat';Bytes=[byte[]]@(0xca,0xfe,0xba,0xbe,0,0,0,2);Format='MachO'},
    @{Name='class';Bytes=[byte[]]@(0xca,0xfe,0xba,0xbe,0,0,0,61);Format='JavaClass'}
)){
    $file=Join-Path $TestRoot $case.Name;[IO.File]::WriteAllBytes($file,$case.Bytes)
    Assert-True ((Get-AnalysisIdentity $file).Format -eq $case.Format) ('Wrong magic classification: '+$case.Name)
}
Write-Host 'PASS: format identification and decoding candidates (not decryption claims).'

& {
    $calls=[Collections.Generic.List[object]]::new()
    function Initialize-ExecutableAnalysisVm { param($VirtualMachineName) $calls.Add(@{Kind='InitializeLinux';Name=$VirtualMachineName}) }
    function Initialize-ExecutableAnalysisWindowsVm { param($VirtualMachineName,$IsoPath) $calls.Add(@{Kind='InitializeWindows';Name=$VirtualMachineName;IsoPath=$IsoPath}) }
    function Invoke-ExecutableAnalysisVm { param($InputPath,$OutputPath,$VirtualMachineName,$TimeoutSeconds) $calls.Add(@{Kind='Linux';Name=$VirtualMachineName;Input=$InputPath;Seconds=$TimeoutSeconds});[pscustomobject]@{Status='Complete'} }
    function Invoke-ExecutableAnalysisWindowsVm { param($InputPath,$OutputPath,$VirtualMachineName,$TimeoutSeconds) $calls.Add(@{Kind='Windows';Name=$VirtualMachineName;Input=$InputPath;Seconds=$TimeoutSeconds});[pscustomobject]@{Status='Completed';GuestResult=@{Execution=@{ExitCode=7;Reason='Completed'}}} }
    $standalone=Join-Path $TestRoot 'pwsh.exe'
    Copy-Item -LiteralPath (Join-Path $PSHOME 'pwsh.exe') -Destination $standalone
    $linux=Invoke-ExecutableAnalysis (Join-Path $TestRoot 'elf') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -RuntimeSeconds 7
    Assert-True ($linux.Status -eq 'CompletedWithLimitations' -and $calls.Count -eq 2 -and $calls[0].Kind -eq 'InitializeLinux' -and $calls[1].Name -eq 'Profile-Analysis-Linux' -and $calls[1].Seconds -eq 7) 'Linux runtime routing or initialization failed.'
    $windows=Invoke-ExecutableAnalysis $standalone -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -WindowsIsoPath 'fixture-media.iso'
    Assert-True ($windows.Status -eq 'CompletedWithLimitations' -and $calls[2].Kind -eq 'InitializeWindows' -and $calls[2].IsoPath -eq 'fixture-media.iso' -and $calls[3].Name -eq 'Profile-Analysis-Windows') 'Windows runtime routing or ISO forwarding failed.'
    Assert-True ((Get-Content -LiteralPath $windows.ReportPath -Raw) -match 'Target exit code: 7; reason: Completed') 'Runtime report concealed the target exit code.'
    $null=Invoke-ExecutableAnalysis $standalone -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -NoInstall -VirtualMachineName 'Owned-Custom-VM'
    Assert-True ($calls.Count -eq 5 -and $calls[4].Name -eq 'Owned-Custom-VM' -and $calls[4].Input -like '*analysis-*\input\pwsh.exe') 'NoInstall, explicit VM selection or retained-copy handoff failed.'
    $unsupported=Invoke-ExecutableAnalysis (Join-Path $TestRoot 'wasm') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic
    Assert-True ($unsupported.Status -eq 'Partial' -and $calls.Count -eq 5 -and @($unsupported.Stages|Where-Object Status -EQ 'Unsupported').Count -eq 1) 'Unsupported runtime format invoked a VM or appeared complete.'
    $dll=Join-Path $TestRoot 'header-only-library.dll'
    $dllBytes=[byte[]]::new(128);$dllBytes[0]=0x4d;$dllBytes[1]=0x5a;$dllBytes[60]=64;$dllBytes[64]=0x50;$dllBytes[65]=0x45;$dllBytes[68]=0x64;$dllBytes[69]=0x86;$dllBytes[86]=2;$dllBytes[87]=0x20
    [IO.File]::WriteAllBytes($dll,$dllBytes)
    $unsupportedDll=Invoke-ExecutableAnalysis $dll -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic
    Assert-True ($unsupportedDll.Status -eq 'Partial' -and $calls.Count -eq 5 -and @($unsupportedDll.Stages|Where-Object Status -EQ 'Unsupported').Count -eq 1) 'A DLL initialized or invoked a VM without an execution harness.'
    $packaged=Join-Path $TestRoot 'packaged-app'
    $null=[IO.Directory]::CreateDirectory((Join-Path $packaged 'resources'))
    Copy-Item -LiteralPath $standalone -Destination (Join-Path $packaged 'entry.exe')
    [IO.File]::WriteAllText((Join-Path $packaged 'resources/app.asar'),'fixture archive; never executed')
    [IO.File]::WriteAllText((Join-Path $packaged 'AppxManifest.xml'),'<Package><Applications><Application Id="App" Executable="entry.exe"/></Applications></Package>')
    $packageResult=Invoke-ExecutableAnalysis (Join-Path $packaged 'entry.exe') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic
    Assert-True ($packageResult.Status -eq 'Partial' -and $calls.Count -eq 5 -and @($packageResult.Stages|Where-Object { $_.Name -eq 'Runtime' -and $_.Status -eq 'Unsupported' }).Count -eq 1) 'Packaged application initialized or invoked the single-file runtime adapter.'
    $packageContext=Get-Content -LiteralPath (Join-Path $packageResult.OutputDirectory 'basic/application-context.json') -Raw|ConvertFrom-Json
    Assert-True ($packageContext.Detected -and $packageContext.EntryPoints[0].DeclaredPath -eq 'entry.exe' -and $packageContext.EntryPoints[0].SelectedInput) 'PE application context or declared entry point was lost.'
    $linked=Join-Path $TestRoot 'linked-source'
    $null=New-Item -ItemType Junction -Path $linked -Target $packaged
    $unverified=Invoke-ExecutableAnalysis (Join-Path $linked 'entry.exe') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic
    $unverifiedContext=Get-Content -LiteralPath (Join-Path $unverified.OutputDirectory 'basic/application-context.json') -Raw|ConvertFrom-Json
    Assert-True ($unverifiedContext.Status -eq 'Partial' -and -not $unverifiedContext.Detected -and $calls.Count -eq 5 -and @($unverified.Stages|Where-Object { $_.Name -eq 'Runtime' -and $_.Status -eq 'Unsupported' }).Count -eq 1) 'Unverifiable adjacent context was accepted as a standalone runtime target.'
}
Write-Host 'PASS: OS-specific runtime routing, provisioning, NoInstall, explicit VM names and unsupported formats (VM helpers mocked).'

& {
    # Exercise the actual orchestrator with its installer/process/decompiler boundaries
    # replaced. The fixture never runs the selected PE, a provider or an installer.
    $script:analysisFixtureAssets=Join-Path $repo 'scripts/ExecutableAnalysis'
    . (Join-Path $script:analysisFixtureAssets 'Get-AnalysisApplicationContext.ps1')
    $source=[IO.File]::ReadAllText((Join-Path $repo 'functions/Invoke-ExecutableAnalysis.ps1'))
    $source=$source.Replace("`$assets=Join-Path (Split-Path `$PSScriptRoot -Parent) 'scripts/ExecutableAnalysis'",'$assets=$script:analysisFixtureAssets')
    $source=$source.Replace('. $helperPath','# Actual pure helpers are already imported; mock external boundaries below.')
    . ([scriptblock]::Create($source))
    function Resolve-AnalysisTool { param($LogDirectory,$ReaScriptPath,$NoInstall,$Managed,$Native,$Wasm,$Java) [pscustomobject]@{ReaScript='fixture-rea.mjs';Node='fixture-node.exe';Ghidra='fixture-ghidra';Limitations=@()} }
    function Invoke-AnalysisTool {
        param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds,$Environment)
        $config=Get-Content -LiteralPath $ArgumentList[1] -Raw|ConvertFrom-Json
        Assert-True ($config.timeoutSeconds -eq 601 -and $config.archiveIntegrityPolicy -eq 'record-and-continue' -and $config.maxJavaScriptHeapMB -eq 2048 -and $config.maxTotalEvidenceBytes -eq 2GB) 'Requested timeout or explicit integrity policy was not forwarded.'
        @{Status=$script:nativeFixture.Status;InputUnchanged=$true;InputSHA256Before=(Get-FileHash -LiteralPath $config.inputPath).Hash;Coverage=@{DecompiledFunctions=$script:nativeFixture.Count};Limitations=@()}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $config.outputDirectory 'rea-result.json')
        [pscustomobject]@{Status='Completed'}
    }
    function Invoke-AnalysisGhidra {
        param($InputPath,$OutputDirectory,$GhidraPath,$AssetDirectory,$LogDirectory,$MaxFunctions,$TimeoutSeconds)
        $fallbackCalls.Add($InputPath)
        Assert-True ($InputPath -like '*analysis-*\input\pwsh.exe' -and $MaxFunctions -eq 80 -and $TimeoutSeconds -eq 601) 'Fallback did not use retained input and caller budgets.'
        [pscustomobject]@{Status='Partial';Manifest=@{Coverage=@{DecompiledFunctions=80;Complete=$false}}}
    }
    foreach($case in @(@{Status='Partial';Count=0;Fallback=$true},@{Status='Failed';Count=0;Fallback=$true},@{Status='Partial';Count=1;Fallback=$false},@{Status='Succeeded';Count=2;Fallback=$false})){
        $script:nativeFixture=$case;$fallbackCalls=[Collections.Generic.List[string]]::new()
        $result=Invoke-ExecutableAnalysis (Join-Path $TestRoot 'pwsh.exe') -OutputDirectory $TestRoot -SkipAI -NoInstall -TimeoutSeconds 601 -MaxFunctions 80 -ArchiveIntegrityPolicy RecordAndContinue -MaxJavaScriptHeapMB 2048 -MaxProviderEvidenceBytes 2GB
        Assert-True (($fallbackCalls.Count -eq 1) -eq $case.Fallback) 'Direct Ghidra fallback policy did not match failed/partial REA code recovery.'
        Assert-True ($result.SourceUnchanged -and @($result.Stages|Where-Object Name -EQ 'REA').Count -eq 1) 'Fallback lost source identity or original REA evidence.'
        Assert-True (@($result.Stages|Where-Object Name -EQ 'Orchestration').Count -eq 0) 'Mocked fallback orchestration failed.'
    }
}
Write-Host 'PASS: native fallback recovers only missing REA code, preserves provider evidence, and honors explicit time/integrity budgets.'

$child=Join-Path $TestRoot 'child.ps1'
[IO.File]::WriteAllText($child,'param([string]$Value) [Console]::Out.Write($Value); [Console]::Error.Write("stderr"); exit 7')
$literal='spaces [brackets] & $notcode; "quotes"'
$process=Invoke-AnalysisTool (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-File',$child,$literal) -LogPath (Join-Path $TestRoot 'arguments') -WorkingDirectory $TestRoot -TimeoutSeconds 10
Assert-True ($process.Status -eq 'Failed' -and $process.ExitCode -eq 7) 'Nonzero native result lost.'
Assert-True ([IO.File]::ReadAllText($process.StandardOutputPath) -ceq $literal) 'Argument boundaries changed.'
Assert-True ([IO.File]::ReadAllText($process.StandardErrorPath) -eq 'stderr') 'Stderr lost.'
$timeout=Invoke-AnalysisTool (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-Command','Start-Sleep -Seconds 15') -LogPath (Join-Path $TestRoot 'timeout') -WorkingDirectory $TestRoot -TimeoutSeconds 1
Assert-True ($timeout.Status -eq 'Timeout' -and $timeout.Seconds -lt 10) 'Timeout did not bound execution.'
Write-Host 'PASS: native argument boundaries, stdout/stderr, nonzero exits and owned-process timeout.'

$flood=Invoke-AnalysisTool (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-Command','for($i=0;$i -lt 10000;$i++){[Console]::Out.Write("x"*4096);[Console]::Error.Write("y"*4096)}') -LogPath (Join-Path $TestRoot 'output-limit') -WorkingDirectory $TestRoot -TimeoutSeconds 10 -MaxLogBytes 1048576
Assert-True ($flood.Status -eq 'OutputLimit') 'Output flooding did not fail at the byte limit.'
$totalLogBytes=(Get-Item -LiteralPath $flood.StandardOutputPath).Length+(Get-Item -LiteralPath $flood.StandardErrorPath).Length
Assert-True ($totalLogBytes -le 1048576) 'Retained output exceeded the combined byte limit.'
$longString=Join-Path $TestRoot 'long-string.bin';[IO.File]::WriteAllText($longString,('x'*10000))
$longFolder=Join-Path $TestRoot 'long-string';$null=[IO.Directory]::CreateDirectory($longFolder)
$longCoverage=Export-AnalysisString $longString $longFolder
Assert-True ($longCoverage.Truncated -and $longCoverage.TruncatedStrings -eq 1) 'Long string truncation was not disclosed.'
. (Join-Path $repo 'scripts/ExecutableAnalysis/Resolve-AnalysisTools.ps1')
& {
    function Get-Command { param($Name,$CommandType,$ErrorAction) if($Name -eq 'ilspycmd'){[pscustomobject]@{Source='fixture-ilspy.exe'}} }
    function Invoke-AnalysisTool { param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds) [IO.File]::WriteAllText($LogPath+'.stdout','ilspycmd: fixture');[pscustomobject]@{Status='Completed';StandardOutputPath=$LogPath+'.stdout'} }
    $resolved=Resolve-AnalysisTool -LogDirectory $TestRoot -NoInstall -Managed
    Assert-True ($resolved.ILSpy -eq 'fixture-ilspy.exe' -and -not $resolved.Node) 'Missing Node suppressed the independent managed decompiler.'
}
Write-Host 'PASS: strict combined output budget, explicit string truncation and independent provider resolution.'

. (Join-Path $repo 'scripts/ExecutableAnalysis/Invoke-AnalysisRound.ps1')
# Provider failure and missing web retrieval must not become a successful research stage.
function Invoke-AnalysisTool {
    param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds,$InputText)
    $output=$ArgumentList[[array]::IndexOf($ArgumentList,'-o')+1]
    [IO.File]::WriteAllText($output,'This is a synthetic fixture response with no retrieved source.')
    [IO.File]::WriteAllText($LogPath+'.stdout','{"type":"item.completed","item":{"type":"error","message":"provider unavailable"}}')
    [IO.File]::WriteAllText($LogPath+'.stderr','')
    Assert-True ($ArgumentList -contains '--ignore-user-config' -and $ArgumentList -contains 'shell_tool' -and $ArgumentList -contains 'plugins' -and $ArgumentList -contains 'project_root_markers=[]') 'AI execution capability boundaries were dropped.'
    [pscustomobject]@{Status='Completed';ExitCode=0;StandardOutputPath=$LogPath+'.stdout';StandardErrorPath=$LogPath+'.stderr'}
}
$round=Invoke-AnalysisRound -Name 'mock-research' -Prompt 'fixture' -OutputDirectory $TestRoot -CodexPath 'fixture' -Research
Assert-True ($round.Status -eq 'Partial' -and $round.WebSearches -eq 0 -and $round.ToolErrors.Count -eq 2) 'Research with provider failure or no retrieval falsely passed.'
Write-Host 'PASS: AI provider errors and unverified research remain partial, even with exit zero and a final message.'

foreach($case in @(
    @{Process='Completed';Manifest='Succeeded';Expected='Succeeded'},
    @{Process='Timeout';Manifest='Succeeded';Expected='Partial'},
    @{Process='OutputLimit';Manifest='Succeeded';Expected='Partial'},
    @{Process='Failed';Manifest='Succeeded';Expected='Partial'},
    @{Process='Completed';Manifest='Partial';Expected='Partial'},
    @{Process='Completed';Manifest='Unexpected';Expected='Failed'}
)) {
    $manifest=[pscustomobject]@{Status=$case.Manifest;InputUnchanged=$true;InputSHA256Before=('aa'*32);InputSHA256After=('aa'*32)}
    $status=Get-AnalysisProviderStatus -Process ([pscustomobject]@{Status=$case.Process}) -Manifest $manifest -ExpectedSHA256 ('AA'*32)
    Assert-True ($status -eq $case.Expected) ('Provider process/manifest disagreement was mishandled: '+$case.Process+'/'+$case.Manifest)
}
$manifest.Status='Succeeded';$manifest.InputSHA256After='wrong'
Assert-True ((Get-AnalysisProviderStatus -Process ([pscustomobject]@{Status='Completed'}) -Manifest $manifest -ExpectedSHA256 ('AA'*32)) -eq 'Failed') 'Provider identity mismatch was ignored.'
Write-Host 'PASS: successful provider manifests cannot override failed processes or mismatched input identity.'

$selection=Join-Path $TestRoot 'evidence-selection'
foreach($folder in 'basic','runtime','logs','code','rea','application/rea-1/rea-raw'){$null=[IO.Directory]::CreateDirectory((Join-Path $selection $folder))}
foreach($name in 'basic/identity.json','basic/application-context.json','runtime/runtime.json','runtime/stdout.txt','runtime/strace.log','logs/ilspy.command.json','rea/rea-result.json','application/rea-1/rea-raw/006-analyze_javascript_application.json'){[IO.File]::WriteAllText((Join-Path $selection $name),'fixture')}
foreach($index in 1..55){[IO.File]::WriteAllText((Join-Path $selection "code/function-$index.c"),'return 42;')}
$selected=@(Select-AnalysisEvidenceFile -RunDirectory $selection)
Assert-True ($selected.Count -eq 40) 'AI evidence file budget was lost.'
foreach($name in 'identity.json','application-context.json','runtime.json','stdout.txt','strace.log','ilspy.command.json','rea-result.json','006-analyze_javascript_application.json'){Assert-True ($selected.Name -contains $name) ('Code volume crowded out required evidence: '+$name)}
Write-Host 'PASS: large decompilations retain runtime observations, identity and invocation provenance in the AI review sample.'

& {
    $resolverRoot=Join-Path $TestRoot 'codex resolver [fixture]'
    $null=[IO.Directory]::CreateDirectory($resolverRoot)
    $broken=Join-Path $resolverRoot 'broken.exe'; [IO.File]::WriteAllText($broken,'fixture')
    $working=Join-Path $resolverRoot 'working.exe'; [IO.File]::WriteAllText($working,'fixture')
    $missing=Join-Path $resolverRoot 'missing.exe'
    $shim=Join-Path $resolverRoot 'codex.cmd'; [IO.File]::WriteAllText($shim,'@echo fixture')
    $sources=@($broken,$missing,$shim,$working)
    $probes=[Collections.Generic.List[string]]::new()
    $oldPath=$env:PATH
    function Get-ChildItem { param($LiteralPath,[switch]$Directory) @() }
    function Get-Command { [CmdletBinding()]param($Name,$CommandType,[switch]$All) foreach($item in $sources){[pscustomobject]@{Source=$item}} }
    function Invoke-AnalysisTool {
        param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds)
        $probes.Add($FilePath)
        if($FilePath -eq $broken){throw 'Synthetic invalid executable.'}
        if([IO.Path]::GetExtension($FilePath) -in '.cmd','.bat','.ps1'){throw 'Resolver tried to execute a shell launcher.'}
        [IO.File]::WriteAllText($LogPath+'.stdout','codex-cli 0.163.0')
        [pscustomobject]@{Status='Completed';StandardOutputPath=$LogPath+'.stdout'}
    }
    $logs=Join-Path $resolverRoot 'first';$null=[IO.Directory]::CreateDirectory($logs)
    $resolved=Resolve-AnalysisCodex -LogDirectory $logs
    Assert-True ($resolved.Source -eq $working -and $probes.Count -eq 2 -and $probes[0] -eq $broken) 'A broken/missing candidate prevented a valid native fallback.'
    $diagnostics=Get-Content -LiteralPath $resolved.DiagnosticsPath -Raw|ConvertFrom-Json
    Assert-True (@($diagnostics|Where-Object Status -EQ 'Failed').Count -eq 1 -and @($diagnostics|Where-Object Status -EQ 'Skipped').Count -eq 1) 'Candidate failures or refused shell launcher diagnostics were lost.'

    $sources=@($broken,$missing,$shim)
    $logs=Join-Path $resolverRoot 'none';$null=[IO.Directory]::CreateDirectory($logs)
    Assert-True ($null -eq (Resolve-AnalysisCodex -LogDirectory $logs)) 'Unusable Codex candidates should leave AI unavailable without aborting other providers.'

    # Mirror the official npm launcher layout; no package manager or host PATH mutation.
    $npmRoot=Join-Path $resolverRoot 'node_modules/@openai/codex'
    $nativeRoot=Join-Path $resolverRoot 'node_modules/@openai/codex-win32-x64'
    $native=Join-Path $nativeRoot 'vendor/x86_64-pc-windows-msvc/bin/codex.exe'
    $null=[IO.Directory]::CreateDirectory($npmRoot)
    $null=[IO.Directory]::CreateDirectory((Split-Path $native -Parent))
    [IO.File]::WriteAllText((Join-Path $npmRoot 'package.json'),'{"name":"@openai/codex"}')
    [IO.File]::WriteAllText((Join-Path $nativeRoot 'package.json'),'{"name":"@openai/codex-win32-x64"}')
    [IO.File]::WriteAllText($native,'fixture')
    $sources=@($shim);$probes.Clear()
    $logs=Join-Path $resolverRoot 'npm';$null=[IO.Directory]::CreateDirectory($logs)
    $resolved=Resolve-AnalysisCodex -LogDirectory $logs
    Assert-True ($resolved.Source -eq $native -and $probes.Count -eq 1 -and $env:PATH -eq $oldPath) 'Official npm native executable discovery failed or changed PATH.'
}
Write-Host 'PASS: failed/missing Codex candidates remain isolated, shell shims are not executed and npm native binaries are discovered without changing PATH.'

& {
    . (Join-Path $repo 'scripts/ExecutableAnalysis/Invoke-AnalysisTool.ps1')
    $sentinel=Join-Path $TestRoot 'shell-must-not-run.txt'
    foreach($extension in '.cmd','.bat','.ps1') {
        $file=Join-Path $TestRoot ('refused-launcher'+$extension)
        [IO.File]::WriteAllText($file,"@echo executed > `"$sentinel`"")
        Assert-Throws { Invoke-AnalysisTool $file @('literal&echo.METACHAR') -LogPath (Join-Path $TestRoot ('refused-'+$extension.TrimStart('.'))) -WorkingDirectory $TestRoot } 'native|shell|launcher'
    }
    Assert-True (-not(Test-Path -LiteralPath $sentinel)) 'An unsafe shell launcher was executed.'
}
Write-Host 'PASS: shell launchers are refused before execution and cannot reinterpret caller arguments.'
