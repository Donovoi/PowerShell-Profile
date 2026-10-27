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
Assert-True ($record.Limitations.Count -eq 1 -and $record.Limitations[0] -match 'Runtime execution was not requested') 'Basic analysis included unrelated generic limitations.'
$reportLimits=([regex]::Match((Get-Content -LiteralPath $first.ReportPath -Raw),'(?s)## Limits and unknowns\r?\n(.*?)(?=\r?\nFull commands|\z)')).Groups[1].Value
Assert-True ($reportLimits -notmatch 'Encryption|decompiled code|Go build|Rust compiler|firmware|first 16 MiB') 'Basic report disclosed capabilities or limits that did not apply.'
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
$noisy=Join-Path $TestRoot 'noisy-encoded.bin'
[IO.File]::WriteAllText($noisy,(('////////////////' + "`n")*1000)+'SGVsbG8gZXZpZGVuY2U=')
$noisyFolder=Join-Path $TestRoot 'noisy-decode';$null=[IO.Directory]::CreateDirectory($noisyFolder)
$noisyOutput=@(Export-AnalysisString $noisy $noisyFolder -Verbose 4>&1)
$noiseSummary=@($noisyOutput|Where-Object {$_ -isnot [System.Management.Automation.VerboseRecord]})
Assert-True (@($noisyOutput|Where-Object {$_ -is [System.Management.Automation.VerboseRecord]}).Count -eq 1) 'Rejected decoding candidates flooded verbose output.'
Assert-True ($noiseSummary.Count -eq 1 -and $noiseSummary[0].DecodeAttempts -eq 1001 -and $noiseSummary[0].RejectedUtf8 -eq 1000) 'Decoding rejection coverage was lost.'
$noisyDecoded=Get-Content -LiteralPath (Join-Path $noisyFolder 'decoded-candidates.json') -Raw|ConvertFrom-Json
Assert-True ($noisyDecoded.Count -eq 1 -and $noisyDecoded[0].Text -eq 'Hello evidence') 'Rejected candidates prevented recovery of valid text.'
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
    function Invoke-ExecutableAnalysisVm { param($InputPath,$OutputPath,$VirtualMachineName,$TimeoutSeconds,[switch]$VirtualDisplay,$MaxAddressSpaceMB) $calls.Add(@{Kind='Linux';Name=$VirtualMachineName;Input=$InputPath;Seconds=$TimeoutSeconds;VirtualDisplay=[bool]$VirtualDisplay;MaxAddressSpaceMB=$MaxAddressSpaceMB});[pscustomobject]@{Status='Complete'} }
    function Invoke-ExecutableAnalysisWindowsVm { param($InputPath,$OutputPath,$VirtualMachineName,$TimeoutSeconds,$ExpectedInputSHA256,$ApplicationRoot,$MaxPackageBytes,$MaxPackageFiles,$LaunchMode,$PackageArchivePath,$PackageLicensePath) $calls.Add(@{Kind='Windows';Name=$VirtualMachineName;Input=$InputPath;Seconds=$TimeoutSeconds;ExpectedSHA256=$ExpectedInputSHA256;Root=$ApplicationRoot;MaxPackageBytes=$MaxPackageBytes;MaxPackageFiles=$MaxPackageFiles;LaunchMode=$LaunchMode;PackageArchivePath=$PackageArchivePath;PackageLicensePath=$PackageLicensePath});[pscustomobject]@{Status='Completed';GuestResult=@{Execution=@{ExitCode=7;Reason='Completed'}}} }
    $standalone=Join-Path $TestRoot 'pwsh.exe'
    Copy-Item -LiteralPath (Join-Path $PSHOME 'pwsh.exe') -Destination $standalone
    $linux=Invoke-ExecutableAnalysis (Join-Path $TestRoot 'elf') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -RuntimeSeconds 7 -LinuxVirtualDisplay -LinuxMaxAddressSpaceMB 65536
    $linuxReport=Get-Content -LiteralPath $linux.JsonPath -Raw|ConvertFrom-Json
    Assert-True ($linuxReport.Limitations.Count -eq 0 -and (Get-Content -LiteralPath $linux.ReportPath -Raw) -notmatch '## Limits and unknowns') 'An empty limits section or irrelevant static/decryption caveat was emitted for a runtime-observed basic run.'
    Assert-True ($linux.Status -eq 'CompletedWithLimitations' -and $calls.Count -eq 2 -and $calls[0].Kind -eq 'InitializeLinux' -and $calls[1].Name -eq 'Profile-Analysis-Linux' -and $calls[1].Seconds -eq 7 -and $calls[1].VirtualDisplay -and $calls[1].MaxAddressSpaceMB -eq 65536) 'Linux runtime routing, display/budget request or initialization failed.'
    $windows=Invoke-ExecutableAnalysis $standalone -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -WindowsIsoPath 'fixture-media.iso'
    Assert-True ($windows.Status -eq 'CompletedWithLimitations' -and $calls[2].Kind -eq 'InitializeWindows' -and $calls[2].IsoPath -eq 'fixture-media.iso' -and $calls[3].Name -eq 'Profile-Analysis-Windows') 'Windows runtime routing or ISO forwarding failed.'
    Assert-True ((Get-Content -LiteralPath $windows.ReportPath -Raw) -match 'Target exit code: 7; reason: Completed') 'Runtime report concealed the target exit code.'
    $null=Invoke-ExecutableAnalysis $standalone -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -NoInstall -VirtualMachineName 'Owned-Custom-VM'
    Assert-True ($calls.Count -eq 5 -and $calls[4].Name -eq 'Owned-Custom-VM' -and $calls[4].Input -like '*analysis-*\input\pwsh.exe') 'NoInstall, explicit VM selection or retained-copy handoff failed.'
    Assert-True ($calls[4].ExpectedSHA256 -eq (Get-FileHash -LiteralPath $standalone).Hash) 'Standalone runtime lost the preserved input identity.'
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
    $packageResult=Invoke-ExecutableAnalysis (Join-Path $packaged 'entry.exe') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -MaxRuntimePackageBytes 4MB -MaxRuntimePackageFiles 17
    Assert-True ($packageResult.Status -eq 'Partial' -and @($packageResult.Stages|Where-Object {$_.Name -eq 'Runtime' -and $_.Status -eq 'Completed'}).Count -eq 1 -and $calls.Count -eq 7 -and $calls[5].Kind -eq 'InitializeWindows' -and $calls[6].Input -eq (Join-Path $packaged 'entry.exe') -and $calls[6].ExpectedSHA256 -eq (Get-FileHash -LiteralPath $standalone).Hash -and $calls[6].MaxPackageBytes -eq 4MB -and $calls[6].MaxPackageFiles -eq 17) 'Packaged runtime lost the original layout source, its identity, explicit package budgets, or honest BasicOnly coverage.'
    $packageContext=Get-Content -LiteralPath (Join-Path $packageResult.OutputDirectory 'basic/application-context.json') -Raw|ConvertFrom-Json
    Assert-True ($packageContext.Detected -and $packageContext.EntryPoints[0].DeclaredPath -eq 'entry.exe' -and $packageContext.EntryPoints[0].SelectedInput) 'PE application context or declared entry point was lost.'
    $explicit=Join-Path $TestRoot 'explicit-layout';$null=[IO.Directory]::CreateDirectory($explicit)
    Copy-Item -LiteralPath $standalone -Destination (Join-Path $explicit 'entry.exe')
    $explicitResult=Invoke-ExecutableAnalysis (Join-Path $explicit 'entry.exe') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -NoInstall -WindowsApplicationRoot $explicit
    Assert-True ($explicitResult.Status -eq 'CompletedWithLimitations' -and $calls.Count -eq 8 -and $calls[7].Input -eq (Join-Path $explicit 'entry.exe') -and $calls[7].Root -eq $explicit) 'Explicit application layout did not preserve the original source/root or bypass initialization under NoInstall.'
    $linked=Join-Path $TestRoot 'linked-source'
    $null=New-Item -ItemType Junction -Path $linked -Target $packaged
    $unverified=Invoke-ExecutableAnalysis (Join-Path $linked 'entry.exe') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic
    $unverifiedContext=Get-Content -LiteralPath (Join-Path $unverified.OutputDirectory 'basic/application-context.json') -Raw|ConvertFrom-Json
    Assert-True ($unverifiedContext.Status -eq 'Partial' -and -not $unverifiedContext.Detected -and $calls.Count -eq 8 -and @($unverified.Stages|Where-Object { $_.Name -eq 'Runtime' -and $_.Status -eq 'Unsupported' }).Count -eq 1) 'Unverifiable adjacent context was accepted as a standalone runtime target.'
    Assert-True ($calls[6].LaunchMode -eq 'DesktopLayout') 'Desktop layout is no longer the default Windows launch mode.'
    $registered=Invoke-ExecutableAnalysis (Join-Path $packaged 'entry.exe') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -NoInstall -WindowsLaunchMode RegisteredPackage
    Assert-True ($registered.Status -eq 'Partial' -and $calls.Count -eq 9 -and $calls[8].LaunchMode -eq 'RegisteredPackage' -and $calls[8].Input -eq (Join-Path $packaged 'entry.exe') -and $calls[8].ExpectedSHA256 -eq (Get-FileHash -LiteralPath $standalone).Hash) 'Registered package mode lost its original input/hash or initialized despite NoInstall.'
    $archivePath=Join-Path $TestRoot 'signed [original].msix';$licensePath=Join-Path $TestRoot 'vendor [license].xml'
    $licensed=Invoke-ExecutableAnalysis (Join-Path $packaged 'entry.exe') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -NoInstall -WindowsLaunchMode RegisteredPackage -WindowsPackageArchivePath $archivePath -WindowsPackageLicensePath $licensePath
    Assert-True ($licensed.Status -eq 'Partial' -and $calls.Count -eq 10 -and $calls[9].PackageArchivePath -ceq $archivePath -and $calls[9].PackageLicensePath -ceq $licensePath -and $calls[9].Input -ceq (Join-Path $packaged 'entry.exe')) 'Licensed package inputs lost literal routing or their selected executable.'
    foreach($invalid in @(@{WindowsPackageArchivePath=$archivePath;Dynamic=$true;WindowsLaunchMode='RegisteredPackage'},@{WindowsPackageArchivePath=$archivePath;WindowsPackageLicensePath=$licensePath;Dynamic=$true},@{WindowsPackageArchivePath=$archivePath;WindowsPackageLicensePath=$licensePath;WindowsLaunchMode='RegisteredPackage'})){
        $failure=$null;try{Invoke-ExecutableAnalysis (Join-Path $packaged 'entry.exe') -OutputDirectory $TestRoot -BasicOnly -SkipAI @invalid}catch{$failure=$_}
        Assert-True ($null -ne $failure -and $calls.Count -eq 10) 'Invalid paired licensed input reached a VM helper.'
    }
    # Exercise the real context detector and payload builder across the mocked VM
    # boundary: detected companions must survive the actual archive, not just routing.
    . (Join-Path $repo 'scripts/ExecutableAnalysis/New-AnalysisWindowsPayload.ps1')
    $layoutCases=@('package.json','owl-shell-runtime.json','owl-electron-app.json','owl-app.ini','resources/package.json','resources/owl-shell-runtime.json','resources/owl-electron-app.json','resources/owl-app.ini','resources/app.asar.unpacked/sidecar.bin','AppxManifest.xml')
    foreach($marker in $layoutCases){
        $fixtureRoot=Join-Path $TestRoot ('metadata-layout-'+[guid]::NewGuid().ToString('N'))
        $nestedPackage=$marker -eq 'AppxManifest.xml'
        $entry=Join-Path $fixtureRoot $(if($nestedPackage){'app/entry.exe'}else{'entry.exe'})
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($entry))
        Copy-Item -LiteralPath $standalone -Destination $entry
        $companion=Join-Path $fixtureRoot $marker
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($companion))
        $markerContent=if($nestedPackage){'<Package><Identity Name="Fixture.App" Version="1.0.0.0"/><Applications><Application Id="App" Executable="app/entry.exe"/></Applications></Package>'}else{'fixture companion; never executed'}
        [IO.File]::WriteAllText($companion,$markerContent)
        $before=$calls.Count
        $routed=Invoke-ExecutableAnalysis $entry -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic
        Assert-True ($calls.Count -eq $before+2 -and $calls[$before].Kind -eq 'InitializeWindows') ('Detected layout was not routed to Windows: '+$marker)
        $call=$calls[$before+1]
        Assert-True ($call.Input -eq $entry -and $call.Root -eq $fixtureRoot -and $call.ExpectedSHA256 -eq (Get-FileHash -LiteralPath $entry).Hash) ('Detected layout lost its complete root or input identity: '+$marker)
        Assert-True (@($routed.Stages|Where-Object {$_.Name -eq 'Runtime' -and $_.Status -eq 'Completed'}).Count -eq 1) ('Detected layout lost the VM result: '+$marker)
        $payload=New-AnalysisWindowsPayload -InputPath $call.Input -ApplicationRoot $call.Root -OutputDirectory (Join-Path $routed.OutputDirectory 'verified-payload') -MaxPackageBytes $call.MaxPackageBytes -MaxPackageFiles $call.MaxPackageFiles
        Assert-True ($payload.Files.Count -eq 2 -and $payload.SourceSHA256 -eq $call.ExpectedSHA256) ('Payload omitted or changed a detected companion: '+$marker)
        $zip=[IO.Compression.ZipFile]::OpenRead($payload.ArchivePath)
        try{
            Assert-True ($zip.Entries.Count -eq 2 -and $null -ne $zip.GetEntry($marker)) ('Archive omitted detected metadata: '+$marker)
            foreach($file in $payload.Files){
                $stream=$zip.GetEntry($file.Path).Open();$sha=[Security.Cryptography.SHA256]::Create()
                try{$archiveHash=[Convert]::ToHexString($sha.ComputeHash($stream))}finally{$sha.Dispose();$stream.Dispose()}
                Assert-True ($archiveHash -eq $file.SHA256 -and $archiveHash -eq (Get-FileHash -LiteralPath (Join-Path $fixtureRoot $file.Path)).Hash) ('Archived layout bytes differ: '+$marker)
            }
        }finally{$zip.Dispose()}
    }
    $null=Invoke-ExecutableAnalysis (Join-Path $TestRoot 'elf') -OutputDirectory $TestRoot -BasicOnly -SkipAI -Dynamic -NoInstall
    Assert-True ($calls[$calls.Count-1].Kind -eq 'Linux' -and $calls[$calls.Count-1].MaxAddressSpaceMB -eq 1024) 'Default Linux address-space budget changed.'
    foreach($invalidBudget in @(0,127,131073)) {
        Assert-Throws {Invoke-ExecutableAnalysis (Join-Path $TestRoot 'elf') -OutputDirectory $TestRoot -LinuxMaxAddressSpaceMB $invalidBudget} 'LinuxMaxAddressSpaceMB'
    }
}
Write-Host 'PASS: OS-specific runtime routing, provisioning, NoInstall, explicit VM names and unsupported formats (VM helpers mocked).'

& {
    # Exercise the actual orchestrator with its installer/process/decompiler boundaries
    # replaced. The fixture never runs the selected PE, a provider or an installer.
    $script:analysisFixtureAssets=Join-Path $repo 'scripts/ExecutableAnalysis'
    . (Join-Path $script:analysisFixtureAssets 'Get-AnalysisApplicationContext.ps1')
    . (Join-Path $script:analysisFixtureAssets 'Get-AnalysisFirmwareContext.ps1')
    $source=[IO.File]::ReadAllText((Join-Path $repo 'functions/Invoke-ExecutableAnalysis.ps1'))
    $source=$source.Replace("`$assets=Join-Path (Split-Path `$PSScriptRoot -Parent) 'scripts/ExecutableAnalysis'",'$assets=$script:analysisFixtureAssets')
    $source=$source.Replace('. $helperPath','# Actual pure helpers are already imported; mock external boundaries below.')
    . ([scriptblock]::Create($source))
    function Resolve-AnalysisTool { param($LogDirectory,$ReaScriptPath,$NoInstall,$Managed,$Native,$Wasm,$Java) [pscustomobject]@{ReaScript='fixture-rea.mjs';Node='fixture-node.exe';Ghidra='fixture-ghidra';Limitations=@()} }
    function Invoke-AnalysisTool {
        param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds,$Environment)
        if($ArgumentList[0] -like '*evidence-server.mjs'){@{function_count=0;functions=@()}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $WorkingDirectory 'functions.json');return [pscustomobject]@{Status='Completed'}}
        $config=Get-Content -LiteralPath $ArgumentList[1] -Raw|ConvertFrom-Json
        if($ArgumentList[0] -like '*pdb-context.mjs'){
            Assert-True ($config.cacheDirectory -ceq (Join-Path $TestRoot 'fresh symbol cache') -and $config.proxy -ceq 'socks5h://127.0.0.1:19050' -and $config.downloadTimeoutSeconds -eq 42 -and $TimeoutSeconds -eq 102 -and $config.allowDownload -eq (-not [bool]$script:nativeFixture.NoDownload)) 'Symbol cache, proxy, offline option or download/process deadlines were not forwarded.'
            $context=@{Status='NoRsdsReference';Reference=$null;Loaded=$false;Limitations=@();Source='Download';Download=@{Status='Validated'};CachePath=Join-Path $config.cacheDirectory 'fixture.pdb'}
            if($script:nativeFixture.Pdb){$context.Status='Matched';$context.Reference=@{Name='fixture.pdb';Guid='fixture';Age=1};$context.RetainedPath=Join-Path $WorkingDirectory 'fixture.pdb';[IO.File]::WriteAllText($context.RetainedPath,'inert symbol fixture')}
            $context|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $WorkingDirectory 'basic/pdb-context.json');return [pscustomobject]@{Status='Completed'}
        }
        Assert-True ($config.timeoutSeconds -eq 601 -and $config.archiveIntegrityPolicy -eq 'record-and-continue' -and $config.maxJavaScriptHeapMB -eq 2048 -and $config.maxTotalEvidenceBytes -eq 2GB) 'Requested timeout or explicit integrity policy was not forwarded.'
        @{Status=$script:nativeFixture.Status;InputUnchanged=$true;InputSHA256Before=(Get-FileHash -LiteralPath $config.inputPath).Hash;Coverage=@{DecompiledFunctions=$script:nativeFixture.Count};Limitations=@()}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $config.outputDirectory 'rea-result.json')
        [pscustomobject]@{Status='Completed'}
    }
    function Invoke-AnalysisGhidra {
        param($InputPath,$OutputDirectory,$GhidraPath,$AssetDirectory,$LogDirectory,$MaxFunctions,$TimeoutSeconds,$PdbPath,$TerminalSitesPath)
        $fallbackCalls.Add($InputPath)
        Assert-True ($InputPath -like '*analysis-*\input\pwsh.exe' -and $MaxFunctions -eq 80 -and $TimeoutSeconds -eq 601) 'Fallback did not use retained input and caller budgets.'
        if($script:nativeFixture.Pdb){Assert-True ($PdbPath -like '*analysis-*\fixture.pdb' -and (Test-Path -LiteralPath $PdbPath)) 'Matched PDB was not forwarded to the owned import.'}
        [pscustomobject]@{Status='Partial';InputUnchanged=$true;Manifest=@{Coverage=@{DecompiledFunctions=80;Complete=$false};Pdb=@{Loaded=[bool]$script:nativeFixture.Pdb};TerminalFlow=@{Complete=$true;TotalSites=0;ResolvedSites=0;UnresolvedSites=0;BaselineSitesRequested=0};Limitations=@()}}
    }
    foreach($case in @(@{Status='Partial';Count=0;Fallback=$true;NoDownload=$true},@{Status='Failed';Count=0;Fallback=$true},@{Status='Partial';Count=1;Fallback=$true},@{Status='Succeeded';Count=2;Fallback=$true;Pdb=$true})){
        $script:nativeFixture=$case;$fallbackCalls=[Collections.Generic.List[string]]::new()
        $result=Invoke-ExecutableAnalysis (Join-Path $TestRoot 'pwsh.exe') -OutputDirectory $TestRoot -SkipAI -NoInstall -TimeoutSeconds 601 -MaxFunctions 80 -ArchiveIntegrityPolicy RecordAndContinue -MaxJavaScriptHeapMB 2048 -MaxProviderEvidenceBytes 2GB -SymbolCacheDirectory (Join-Path $TestRoot 'fresh symbol cache') -SymbolProxy 'socks5h://127.0.0.1:19050' -PdbDownloadTimeoutSeconds 42 -NoSymbolDownload:([bool]$case.NoDownload)
        Assert-True (($fallbackCalls.Count -eq 1) -eq $case.Fallback) 'Native PE recovery did not inspect symbols/terminal flow after retaining REA evidence.'
        if($case.Pdb){Assert-True ($result.PdbLoaded -eq $true -and $result.PdbSource -eq 'Download' -and $result.PdbDownloadStatus -eq 'Validated' -and $result.PdbCachePath -ceq (Join-Path (Join-Path $TestRoot 'fresh symbol cache') 'fixture.pdb') -and (Test-Path -LiteralPath $result.PdbContextPath) -and $result.TerminalFlowUnresolved -eq 0) 'Automatic symbol/flow/download results were not exposed on the command result.'}
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
$skillFixture=Join-Path $TestRoot 'ambient skills [fixture]'
foreach($name in @('review-one','nested/review-two')){$folder=Join-Path $skillFixture $name;$null=[IO.Directory]::CreateDirectory($folder);[IO.File]::WriteAllText((Join-Path $folder 'SKILL.md'),'Inert local instruction fixture.')}
$skillConfig=Get-AnalysisReviewSkillConfig -WorkingDirectory $TestRoot -SkillRoots @($skillFixture)
Assert-True ($skillConfig.StartsWith('skills.config=[') -and ([regex]::Matches($skillConfig,'enabled=false')).Count -eq 2 -and $skillConfig.Contains(((Join-Path $skillFixture 'nested/review-two/SKILL.md')|ConvertTo-Json -Compress))) 'Nested local skill paths were not disabled by exact per-child overrides.'
# Provider failure and missing web retrieval must not become a successful research stage.
function Invoke-AnalysisTool {
    param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds,$InputText)
    $output=$ArgumentList[[array]::IndexOf($ArgumentList,'-o')+1]
    [IO.File]::WriteAllText($output,'This is a synthetic fixture response with no retrieved source.')
    [IO.File]::WriteAllText($LogPath+'.stdout','{"type":"item.completed","item":{"type":"error","message":"provider unavailable"}}')
    [IO.File]::WriteAllText($LogPath+'.stderr','')
    Assert-True ($ArgumentList -contains '--ignore-user-config' -and $ArgumentList -contains 'shell_tool' -and $ArgumentList -contains 'plugins' -and $ArgumentList -contains 'project_root_markers=[]') 'AI execution capability boundaries were dropped.'
    Assert-True (@($ArgumentList|Where-Object {$_ -like 'skills.config=[[]*'}).Count -eq 1 -and $ArgumentList -contains 'skill_search' -and $ArgumentList -contains 'skill_mcp_dependency_install' -and $ArgumentList -notcontains 'skip_host_skill_discovery') 'MCP-only reviews inherited unavailable host skills or unstable feature flags.'
    [pscustomobject]@{Status='Completed';ExitCode=0;StandardOutputPath=$LogPath+'.stdout';StandardErrorPath=$LogPath+'.stderr'}
}
$round=Invoke-AnalysisRound -Name 'mock-research' -Prompt 'fixture' -OutputDirectory $TestRoot -CodexPath 'fixture' -Research
Assert-True ($round.Status -eq 'Partial' -and $round.WebSearches -eq 0 -and $round.ToolErrors.Count -eq 2) 'Research with provider failure or no retrieval falsely passed.'
Write-Host 'PASS: AI provider errors and unverified research remain partial, even with exit zero and a final message.'

& {
    $script:fixtureEvidenceEvents=''
    function Invoke-AnalysisTool {
        param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds,$InputText)
        Assert-True (($ArgumentList -join ' ') -match 'analysis_evidence' -and ($ArgumentList -join ' ') -match 'required=true' -and $ArgumentList -contains 'shell_tool') 'Scoped review tools or execution boundaries were lost.'
        Assert-True (@($ArgumentList|Where-Object {$_ -like 'skills.config=[[]*'}).Count -eq 1 -and $ArgumentList -contains 'skill_search' -and $ArgumentList -contains 'skill_mcp_dependency_install') 'Evidence reviews inherited unavailable ambient skills.'
        $output=$ArgumentList[[array]::IndexOf($ArgumentList,'-o')+1]
        'Fixture findings from a real-looking tool event; this fixture never calls a model.'|Set-Content -LiteralPath $output
        $script:fixtureEvidenceEvents|Set-Content -LiteralPath ($LogPath+'.stdout')
        [pscustomobject]@{Status='Completed';StandardOutputPath=$LogPath+'.stdout';StandardErrorPath=$LogPath+'.stderr'}
    }
    $round=Invoke-AnalysisRound -Name 'missing-tools' -Prompt 'fixture' -OutputDirectory $TestRoot -CodexPath 'fixture' -EvidenceDirectory $TestRoot
    Assert-True ($round.Status -eq 'Partial' -and $round.SuccessfulEvidenceToolCalls -eq 0) 'An excerpt-only response passed as tool-assisted review.'
    '{"function_count":2}'|Set-Content -LiteralPath (Join-Path $TestRoot 'functions.json')
    $script:fixtureEvidenceEvents='{"type":"item.completed","item":{"type":"mcp_tool_call","server":"analysis_evidence","tool":"analysis_summary","arguments":{},"status":"completed","result":{}}}'
    $round=Invoke-AnalysisRound -Name 'summary-only' -Prompt 'fixture' -OutputDirectory $TestRoot -CodexPath 'fixture' -EvidenceDirectory $TestRoot
    Assert-True ($round.Status -eq 'Partial' -and $round.CodeInspectionCalls -eq 0) 'A summary-only response passed despite available function bodies.'
    $script:fixtureEvidenceEvents='{"type":"item.completed","item":{"type":"mcp_tool_call","server":"analysis_evidence","tool":"read_function","arguments":{"query":"entry"},"status":"completed","result":{"structured_content":{"path":"rea/rea-code/entry.c","offset":0,"next_offset":null}}}}'
    $round=Invoke-AnalysisRound -Name 'recorded-tools' -Prompt 'fixture' -OutputDirectory $TestRoot -CodexPath 'fixture' -EvidenceDirectory $TestRoot
    Assert-True ($round.Status -eq 'Completed' -and $round.SuccessfulEvidenceToolCalls -eq 1 -and $round.CodeInspectionCalls -eq 1 -and $round.EvidenceToolCalls[0].ReadPath -eq 'rea/rea-code/entry.c') 'Actual tool events were not retained with their artifact path.'
}
Write-Host 'PASS: tool-assisted review requires successful evidence calls and records actual artifact reads.'

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
foreach($folder in 'basic','runtime','logs','code','rea','firmware','application/rea-1/rea-raw'){$null=[IO.Directory]::CreateDirectory((Join-Path $selection $folder))}
foreach($name in 'basic/identity.json','basic/application-context.json','runtime/runtime.json','runtime/stdout.txt','runtime/strace.log','logs/ilspy.command.json','rea/rea-result.json','rea/code-reference-gaps.json','firmware/numeric-validation.json','firmware/form-navigation.json','application/rea-1/rea-raw/006-analyze_javascript_application.json'){[IO.File]::WriteAllText((Join-Path $selection $name),'fixture')}
foreach($index in 1..55){[IO.File]::WriteAllText((Join-Path $selection "code/function-$index.c"),'return 42;')}
foreach($archiveRoot in 'rea','application/rea-1'){
    $extracted=Join-Path $selection ($archiveRoot+'/rea-extracted')
    $null=[IO.Directory]::CreateDirectory($extracted)
    [IO.File]::WriteAllText((Join-Path $extracted 'package.json'),'{"name":"root-app","main":"bootstrap.js"}')
    foreach($index in 1..45){
        $dependency=Join-Path $extracted ("node_modules/dependency-$index")
        $null=[IO.Directory]::CreateDirectory($dependency)
        [IO.File]::WriteAllText((Join-Path $dependency 'package.json'),'{"name":"dependency"}')
    }
}
$selected=@(Select-AnalysisEvidenceFile -RunDirectory $selection)
Assert-True ($selected.Count -eq 40) 'AI evidence file budget was lost.'
foreach($name in 'identity.json','application-context.json','runtime.json','stdout.txt','strace.log','ilspy.command.json','rea-result.json','code-reference-gaps.json','numeric-validation.json','form-navigation.json','006-analyze_javascript_application.json'){Assert-True ($selected.Name -contains $name) ('Code volume crowded out required evidence: '+$name)}
foreach($archiveRoot in 'rea','application/rea-1'){
    Assert-True ($selected.FullName -contains (Join-Path $selection ($archiveRoot+'/rea-extracted/package.json'))) 'Dependency manifests crowded out the application root manifest.'
}
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

& {
    # Build the actual Ghidra invocation with only process discovery/execution mocked.
    # No provider or target executable runs in this fixture.
    . (Join-Path $repo 'scripts/ExecutableAnalysis/Invoke-AnalysisGhidra.ps1')
    function Get-Command { param($Name,$CommandType,$ErrorAction) [pscustomobject]@{Source='fixture-java.exe'} }
    function Invoke-AnalysisTool {
        param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds)
        $ghidraCalls.Add([pscustomobject]@{Arguments=$ArgumentList;TimeoutSeconds=$TimeoutSeconds})
        if($ArgumentList -contains 'LaunchSupport'){
            $vmargs=Join-Path $WorkingDirectory 'fixture-vmargs.txt'
            [IO.File]::WriteAllText($vmargs,'-Dfixture=true')
            return [pscustomobject]@{Status='Completed';StandardOutputPath=$vmargs}
        }
        if($ghidraCase.Manifest){
            $null=[IO.Directory]::CreateDirectory($fixtureOutput)
            [IO.File]::WriteAllText((Join-Path $fixtureOutput 'retained.c'),'/* retained static fixture */')
            $record=@{Status='Succeeded';ExecutableSHA256=if($ghidraCase.BadHash){'0'*64}else{(Get-FileHash -LiteralPath $fixtureInput).Hash};Coverage=@{Complete=$true;DecompiledFunctions=1}}
            if(-not $ghidraCase.UnknownAnalysis){$record.AutoAnalysis=@{TimedOut=[bool]$ghidraCase.AnalysisTimedOut}}
            $record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $fixtureOutput 'ghidra-result.json')
        }
        [pscustomobject]@{Status=$ghidraCase.ProcessStatus;ExitCode=if($ghidraCase.ProcessStatus -eq 'Completed'){0}else{1}}
    }
    $cases=@(
        @{Budget=10;Manifest=$true;ProcessStatus='Completed';Expected='Succeeded'},
        @{Budget=60;Manifest=$true;ProcessStatus='Completed';AnalysisTimedOut=$true;Expected='Partial'},
        @{Budget=1800;Manifest=$true;ProcessStatus='Timeout';Expected='Partial'},
        @{Budget=60;Manifest=$true;ProcessStatus='Completed';UnknownAnalysis=$true;Expected='Partial'},
        @{Budget=60;Manifest=$true;ProcessStatus='Failed';Expected='Failed'},
        @{Budget=60;Manifest=$true;ProcessStatus='Timeout';BadHash=$true;Expected='Failed'},
        @{Budget=60;Manifest=$false;ProcessStatus='Timeout';Expected='Failed'}
    )
    $caseIndex=0
    foreach($ghidraCase in $cases){
        $caseIndex++
        $fixtureRoot=Join-Path $TestRoot ('ghidra-budget-'+$caseIndex)
        $null=[IO.Directory]::CreateDirectory($fixtureRoot)
        $fixtureInput=Join-Path $fixtureRoot 'inert.bin';[IO.File]::WriteAllText($fixtureInput,'not executable')
        $fixtureOutput=Join-Path $fixtureRoot 'output'
        $ghidraCalls=[Collections.Generic.List[object]]::new()
        $beforeDeadline=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $result=Invoke-AnalysisGhidra -InputPath $fixtureInput -OutputDirectory $fixtureOutput -GhidraPath $fixtureRoot -AssetDirectory $fixtureRoot -LogDirectory $fixtureRoot -MaxFunctions 19 -TimeoutSeconds $ghidraCase.Budget
        Assert-True ($ghidraCalls.Count -eq 2 -and $result.Status -eq $ghidraCase.Expected) 'Ghidra process/analysis timeout or identity qualification was incorrect.'
        $argv=$ghidraCalls[1].Arguments
        $post=[Array]::IndexOf($argv,'ExportProgram.java')
        $analysis=[int]$argv[[Array]::IndexOf($argv,'-analysisTimeoutPerFile')+1]
        $export=[int]$argv[$post+4]
        $deadline=[long]$argv[$post+5]
        Assert-True ($argv[$post+1] -ceq $fixtureOutput -and $argv[$post+2] -eq '19' -and $argv[$post+3] -eq '60') 'Ghidra exporter path/function limits changed.'
        Assert-True ($analysis -ge 1 -and $export -ge 1 -and $analysis+$export+$result.Budgets.ImportAndFinalizationReserveSeconds -le $ghidraCalls[1].TimeoutSeconds -and $ghidraCalls[1].TimeoutSeconds -le $ghidraCase.Budget) 'Ghidra phase budgets exceed the shared process budget.'
        Assert-True ($deadline -gt $beforeDeadline -and $deadline -le $beforeDeadline+$ghidraCase.Budget*1000) 'Ghidra export deadline escapes the overall budget.'
        if($ghidraCase.Manifest){Assert-True (Test-Path -LiteralPath (Join-Path $fixtureOutput 'retained.c')) 'Ghidra discarded retained partial code.'}
        if($result.Manifest -and $result.Status -ne 'Succeeded'){Assert-True (-not $result.Manifest.Coverage.Complete) 'Interrupted or incomplete auto-analysis claimed complete coverage.'}
    }
}
Write-Host 'PASS: Ghidra analysis/export share a bounded deadline; interrupted exports retain evidence with honest coverage and input identity.'
