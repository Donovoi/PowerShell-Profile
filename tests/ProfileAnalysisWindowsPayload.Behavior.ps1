#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$TestRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new TestRoot.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/ExecutableAnalysis/New-AnalysisWindowsPayload.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Exception([scriptblock]$Action,[string]$Pattern){$message=$null;try{& $Action}catch{$message=$_.Exception.Message};Assert-True ($message -match $Pattern) ('Expected refusal: '+$Pattern+'; actual: '+$message)}
function New-FixtureFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Creates disposable known-byte fixtures beneath the new TestRoot.')]
    [CmdletBinding()][OutputType([string])]param([string]$Path,[byte[]]$Bytes)
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllBytes($Path,$Bytes);return $Path
}
function Assert-PayloadArchive($Result){
    Assert-True ($Result.Status -eq 'Completed') 'Payload did not complete.'
    Assert-True ((Get-FileHash -LiteralPath $Result.ArchivePath).Hash -eq $Result.ArchiveSHA256) 'Archive hash differs.'
    $manifest=Get-Content -LiteralPath $Result.ManifestPath -Raw|ConvertFrom-Json
    Assert-True ($manifest.Status -eq 'Completed' -and $manifest.Schema -eq 'PowerShellProfile.WindowsPayload.v1') 'Persisted manifest status/schema differs.'
    Assert-True ($manifest.SourceSHA256 -eq (Get-FileHash -LiteralPath $Result.SourcePath).Hash) 'Input identity differs.'
    $zip=[IO.Compression.ZipFile]::OpenRead($Result.ArchivePath)
    try{
        Assert-True ($zip.Entries.Count -eq $Result.Files.Count) 'ZIP inventory differs from manifest.'
        foreach($file in $Result.Files){
            $entry=$zip.GetEntry($file.Path);Assert-True ($null -ne $entry) ('Exact relative filename lost: '+$file.Path)
            $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
            try{$hash=[Convert]::ToHexString($sha.ComputeHash($stream))}finally{$sha.Dispose();$stream.Dispose()}
            Assert-True ($hash -eq $file.SHA256 -and $entry.Length -eq $file.Bytes) ('ZIP bytes differ: '+$file.Path)
            Assert-True ($entry.CompressedLength -eq $entry.Length) 'Payload was compressed.'
            $source=Join-Path $Result.SourceRoot ($file.Path -replace '/', [IO.Path]::DirectorySeparatorChar)
            Assert-True ((Get-FileHash -LiteralPath $source).Hash -eq $file.SHA256) 'Original file hash differs.'
        }
    }finally{$zip.Dispose()}
}

$standalone=New-FixtureFile (Join-Path $TestRoot 'standalone/app [1] & literal.exe') ([byte[]]@(77,90,0,1,2,3))
$null=New-FixtureFile (Join-Path ([IO.Path]::GetDirectoryName($standalone)) 'unrelated.txt') ([byte[]]@(99))
$noOutput=Join-Path $TestRoot 'whatif'
$null=New-AnalysisWindowsPayload $standalone $noOutput -WhatIf
Assert-True (-not(Test-Path -LiteralPath $noOutput)) 'WhatIf created output.'
$output=Join-Path ([IO.Path]::GetDirectoryName($standalone)) 'analysis-output'
$single=New-AnalysisWindowsPayload $standalone $output
Assert-True ($single.Mode -eq 'SingleFile' -and $single.RootKind -eq 'Standalone' -and $single.Files.Count -eq 1) 'Standalone input copied adjacent files.'
Assert-True ($single.EntryPoint -ceq 'app [1] & literal.exe' -and $single.WorkingDirectory -ceq '') 'Executable filename or working directory changed.'
Assert-PayloadArchive $single
$archiveHash=$single.ArchiveSHA256
Assert-Exception {New-AnalysisWindowsPayload $standalone $output} 'overwrite'
Assert-True ((Get-FileHash -LiteralPath $single.ArchivePath).Hash -eq $archiveHash) 'Repeated call overwrote archive.'
Assert-Exception {New-AnalysisWindowsPayload $standalone (Join-Path $TestRoot 'tiny') -MaxPackageBytes 1} 'byte limit'
Assert-True (-not(Test-Path -LiteralPath (Join-Path $TestRoot 'tiny'))) 'Inventory limit failure wrote output.'
Write-Output 'PASS: standalone exact bytes/names, adjacent output, no unrelated files, WhatIf, no overwrite and byte limit.'

$electronRoot=Join-Path $TestRoot 'electron'
$electron=New-FixtureFile (Join-Path $electronRoot 'app.exe') ([byte[]]@(77,90,1))
$null=New-FixtureFile (Join-Path $electronRoot 'resources/app.asar') ([byte[]](0..32))
$null=New-FixtureFile (Join-Path $electronRoot 'resources/app.asar.unpacked/native.node') ([byte[]](7..21))
$null=New-FixtureFile (Join-Path $electronRoot 'runtime.dll') ([byte[]]@(8,9))
$null=[IO.Directory]::CreateDirectory((Join-Path $electronRoot 'empty/cache'))
$layout=New-AnalysisWindowsPayload $electron (Join-Path $TestRoot 'electron-output')
Assert-True ($layout.RootKind -eq 'Electron' -and $layout.Mode -eq 'DesktopLayout' -and $layout.Files.Count -eq 4) 'Electron package layout was incomplete.'
Assert-True ($layout.Directories -contains 'empty' -and $layout.Directories -contains 'empty/cache' -and ($layout.PreservationLimitations -join ' ') -match 'ACLs.*registration') 'Empty directories or unpreserved Windows state were omitted.'
Assert-PayloadArchive $layout
if($IsWindows){
    $caseInput=New-AnalysisWindowsPayload $electron.ToUpperInvariant() (Join-Path $TestRoot 'electron-case-output')
    Assert-True ($caseInput.EntryPoint -ceq 'app.exe') 'Caller casing renamed the preserved executable or lost its inventory match.'
    Assert-PayloadArchive $caseInput
    $caseSingle=New-AnalysisWindowsPayload $standalone.ToUpperInvariant() (Join-Path $TestRoot 'standalone-case-output')
    Assert-True ($caseSingle.EntryPoint -ceq 'app [1] & literal.exe') 'Caller casing renamed the standalone executable.'
    Assert-PayloadArchive $caseSingle
}
Assert-Exception {New-AnalysisWindowsPayload $electron (Join-Path $electronRoot 'output')} 'overlap'
Assert-Exception {New-AnalysisWindowsPayload $electron $TestRoot} 'overlap'
Assert-Exception {New-AnalysisWindowsPayload $electron (Join-Path $TestRoot 'files-budget') -MaxPackageFiles 2} 'file limit'
Write-Output 'PASS: automatic Electron layout preserves ASAR, unpacked files and runtime dependencies; overlap and file bounds fail closed.'

$packageRoot=Join-Path $TestRoot 'package'
$packageExe=New-FixtureFile (Join-Path $packageRoot 'app/selected.exe') ([byte[]]@(77,90,4,5))
$null=New-FixtureFile (Join-Path $packageRoot 'service.exe') ([byte[]]@(77,90,6))
$appx='<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:desktop6="http://schemas.microsoft.com/appx/manifest/desktop/windows10/6"><Identity Name="Known.Package" Publisher="CN=Fixture" Version="1.2.3.4" ProcessorArchitecture="x64"/><Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26300.0"/></Dependencies><Applications><Application Id="KnownApp" Executable="app/selected.exe" EntryPoint="Windows.FullTrustApplication"><Extensions><desktop6:Extension Category="windows.service" Executable="service.exe"><desktop6:Service Name="KnownService" Startup="manual" StartAccount="localSystem"/></desktop6:Extension></Extensions></Application></Applications></Package>'
$manifestFile=New-FixtureFile (Join-Path $packageRoot 'AppxManifest.xml') ([Text.Encoding]::UTF8.GetBytes($appx))
$package=New-AnalysisWindowsPayload $packageExe (Join-Path $TestRoot 'package-output')
Assert-True ($package.RootKind -eq 'AppxDirectory' -and $package.SourceRoot -eq $packageRoot -and $package.EntryPoint -ceq 'app/selected.exe' -and $package.WorkingDirectory -ceq 'app') 'Immediate-parent package/entrypoint resolution failed.'
Assert-True ($package.Package.Identity.Name -eq 'Known.Package' -and $package.Package.MinOSVersion -eq '10.0.19041.0' -and $package.Package.Applications[0].Id -eq 'KnownApp' -and $package.Package.Services[0].Name -eq 'KnownService' -and -not $package.Package.RegistrationPerformed) 'Package declarations were lost or registration was claimed.'
Assert-PayloadArchive $package
$explicit=New-AnalysisWindowsPayload $packageExe (Join-Path $TestRoot 'explicit-output') -ApplicationRoot $packageRoot
Assert-True ($explicit.RootKind -eq 'Explicit' -and $explicit.Package.Identity.Name -eq 'Known.Package') 'Explicit application root did not preserve metadata.'
Assert-PayloadArchive $explicit
Assert-Exception {New-AnalysisWindowsPayload $standalone (Join-Path $TestRoot 'wrong-root') -ApplicationRoot $packageRoot} 'inside ApplicationRoot'
foreach($badPath in '../escape.exe','C:\outside.exe','app/selected.exe:stream','app/CON.exe','app/trailing.','app/trailing '){
    [IO.File]::WriteAllText($manifestFile,$appx.Replace('app/selected.exe',$badPath))
    Assert-Exception {New-AnalysisWindowsPayload $packageExe (Join-Path $TestRoot 'invalid-manifest-path')} 'relative Windows|Ambiguous|reserved'
}
[IO.File]::WriteAllText($manifestFile,'<!DOCTYPE Package [<!ENTITY secret SYSTEM "file:///unrelated">]>'+ $appx)
Assert-Exception {New-AnalysisWindowsPayload $packageExe (Join-Path $TestRoot 'dtd-output')} 'DTD'
[IO.File]::WriteAllBytes($manifestFile,[byte[]]::new(1MB+1))
Assert-Exception {New-AnalysisWindowsPayload $packageExe (Join-Path $TestRoot 'metadata-budget')} '1 MiB'
[IO.File]::WriteAllText($manifestFile,$appx.Replace('service.exe','missing.exe'))
Assert-Exception {New-AnalysisWindowsPayload $packageExe (Join-Path $TestRoot 'missing-declared')} 'missing'
[IO.File]::WriteAllText($manifestFile,$appx)
Write-Output 'PASS: Appx identity, OS and service declarations, exact entrypoint, explicit roots, DTD and unsafe/missing declared paths.'

$reverified=Test-AnalysisWindowsPayloadSource -Payload $layout
Assert-True ($reverified.Status -eq 'Completed' -and $reverified.FilesVerified -eq $layout.Files.Count -and $reverified.DirectoriesVerified -eq $layout.Directories.Count) 'Reusable source verification lost layout coverage.'
$runtimeDependency=Join-Path $electronRoot 'runtime.dll';$originalDependency=[IO.File]::ReadAllBytes($runtimeDependency)
try{
    [IO.File]::WriteAllBytes($runtimeDependency,[byte[]]@(0,0))
    Assert-Exception {Test-AnalysisWindowsPayloadSource -Payload $layout} 'Source changed'
}finally{[IO.File]::WriteAllBytes($runtimeDependency,$originalDependency)}
$lateDirectory=Join-Path $electronRoot 'after-preservation'
$null=[IO.Directory]::CreateDirectory($lateDirectory)
try{Assert-Exception {Test-AnalysisWindowsPayloadSource -Payload $layout} 'Source layout changed'}finally{[IO.Directory]::Delete($lateDirectory)}
$null=New-FixtureFile (Join-Path ([IO.Path]::GetDirectoryName($standalone)) 'new-unrelated.txt') ([byte[]]@(88))
$singleReverified=Test-AnalysisWindowsPayloadSource -Payload $single
Assert-True ($singleReverified.Status -eq 'Completed' -and $singleReverified.FilesVerified -eq 1 -and $singleReverified.DirectoriesVerified -eq 0) 'Single-file verification expanded into unrelated parent contents.'
$withoutDirectories=$layout|ConvertTo-Json -Depth 12|ConvertFrom-Json;$withoutDirectories.PSObject.Properties.Remove('Directories')
Assert-Exception {Test-AnalysisWindowsPayloadSource -Payload $withoutDirectories} 'no complete directory inventory'
Assert-True ((Get-FileHash -LiteralPath $layout.ArchivePath).Hash -eq $layout.ArchiveSHA256) 'Source revalidation recopied or changed the preserved archive.'
Write-Output 'PASS: reusable source verification detects changed bytes and layout names without recopying; single-file scope stays narrow.'

$locked=New-FixtureFile (Join-Path $TestRoot 'locked/app.exe') ([byte[]]@(77,90,1,2))
$lockStream=[IO.File]::Open($locked,'Open','ReadWrite','None')
$failedOutput=Join-Path $TestRoot 'locked-output'
try{Assert-Exception {New-AnalysisWindowsPayload $locked $failedOutput} 'being used|process cannot access|permission'}finally{$lockStream.Dispose()}
$failed=Get-Content -LiteralPath (Join-Path $failedOutput 'payload-manifest.json') -Raw|ConvertFrom-Json
Assert-True ($failed.Status -eq 'Failed' -and $failed.Error -and -not $failed.ArchiveSHA256) 'Unreadable source was falsely reported complete.'
Write-Output 'PASS: locked/unreadable input fails closed with explicit failed output evidence.'

foreach($mutationKind in 'AddFile','AddDirectory','RemoveDirectory'){
    & {
        param($Kind)
        $mutationRoot=Join-Path $TestRoot ('mutation-'+$Kind)
        $mutationInput=New-FixtureFile (Join-Path $mutationRoot 'app.exe') ([byte[]]@(77,90,4))
        $existingDirectory=Join-Path $mutationRoot 'known-empty';$null=[IO.Directory]::CreateDirectory($existingDirectory)
        $mutationOutput=Join-Path $TestRoot ('mutation-output-'+$Kind)
        $mutationState=@{Triggered=$false}
        # Mutate only the disposable source when the ZIP exists: inventory has
        # completed, but the first source stream has not opened. No timing race.
        $originalPathGuard=(Get-Command Assert-AnalysisWindowsPayloadRegularPath).ScriptBlock
        function Assert-AnalysisWindowsPayloadRegularPath {
            param([string]$LiteralPath)
            & $originalPathGuard $LiteralPath
            if(-not $mutationState.Triggered -and $LiteralPath -eq $mutationInput -and (Test-Path -LiteralPath (Join-Path $mutationOutput 'payload.zip'))){
                $mutationState.Triggered=$true
                if($Kind -eq 'AddFile'){[IO.File]::WriteAllBytes((Join-Path $mutationRoot 'late.bin'),[byte[]]@(17))}
                elseif($Kind -eq 'AddDirectory'){$null=[IO.Directory]::CreateDirectory((Join-Path $mutationRoot 'late-empty'))}
                else{[IO.Directory]::Delete($existingDirectory)}
            }
        }
        Assert-Exception {New-AnalysisWindowsPayload $mutationInput $mutationOutput -ApplicationRoot $mutationRoot} 'Source layout changed'
        Assert-True $mutationState.Triggered 'The deterministic inventory mutation seam was not reached.'
        $failure=Get-Content -LiteralPath (Join-Path $mutationOutput 'payload-manifest.json') -Raw|ConvertFrom-Json
        Assert-True ($failure.Status -eq 'Failed') 'Changed directory inventory was reported complete.'
    } $mutationKind
}
Write-Output 'PASS: deterministic additions/removal after initial inventory fail the final complete file/directory-set comparison.'

$deepRoot=Join-Path $TestRoot 'deep'
$deepExe=New-FixtureFile (Join-Path $deepRoot 'app.exe') ([byte[]]@(77,90,1))
$deep=$deepRoot
foreach($index in 1..64){$deep=Join-Path $deep 'a'}
$null=New-FixtureFile (Join-Path $deep 'x') ([byte[]]@(1))
Assert-Exception {New-AnalysisWindowsPayload $deepExe (Join-Path $TestRoot 'deep-output') -ApplicationRoot $deepRoot} 'depth'
Assert-Exception {New-AnalysisWindowsPayload $standalone (Join-Path $TestRoot 'ambiguous-output.')} 'Ambiguous'
Write-Output 'PASS: directory-depth bound and ambiguous destination names are rejected.'

$outside=Join-Path $TestRoot 'outside';$null=[IO.Directory]::CreateDirectory($outside)
$null=New-FixtureFile (Join-Path $outside 'external.bin') ([byte[]]@(99))
$linkedRoot=Join-Path $TestRoot 'linked';$linkedExe=New-FixtureFile (Join-Path $linkedRoot 'app.exe') ([byte[]]@(77,90,2))
$link=Join-Path $linkedRoot 'escape'
$linkAvailable=$false
try{$null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $link -Target $outside;$linkAvailable=$true}catch{Write-Output ('SKIP: link creation unavailable: '+$_.Exception.Message)}
if($linkAvailable){
    Assert-Exception {New-AnalysisWindowsPayload $linkedExe (Join-Path $TestRoot 'linked-output') -ApplicationRoot $linkedRoot} 'Reparse'
    Assert-Exception {New-AnalysisWindowsPayload $standalone (Join-Path $link 'destination')} 'Reparse'
    $linkedExeParent=Join-Path $TestRoot 'source-link'
    $null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $linkedExeParent -Target ([IO.Path]::GetDirectoryName($standalone))
    Assert-Exception {New-AnalysisWindowsPayload (Join-Path $linkedExeParent 'app [1] & literal.exe') (Join-Path $TestRoot 'linked-source-output')} 'Reparse'
    Write-Output 'PASS: source links, source ancestor links and destination ancestor links cannot cross payload boundaries.'
}

# Compare the optimized metadata boundary with the prior provider behavior on
# real inert paths, while asserting the intended acceptance independently.
function Assert-ProviderReferencePath([string]$LiteralPath){
    $ancestors=[Collections.Generic.Stack[string]]::new()
    $volume=[IO.Path]::GetPathRoot($LiteralPath)
    $relative=$LiteralPath.Substring($volume.Length).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if($relative){Assert-AnalysisWindowsPayloadRelativePath $relative -IgnoreDepth}
    $cursor=[IO.Path]::GetFullPath($LiteralPath)
    while($cursor){$ancestors.Push($cursor);$parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent}
    while($ancestors.Count){
        $item=$null;$cursor=$ancestors.Pop()
        try{$item=Microsoft.PowerShell.Management\Get-Item -LiteralPath $cursor -Force -ErrorAction Stop}
        catch{if($_.CategoryInfo.Category -ne 'ObjectNotFound'){throw}}
        if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse-point path refused: $cursor"}
    }
}
$pathCases=[Collections.Generic.List[object]]::new()
foreach($path in $standalone,$electronRoot,(Join-Path $electronRoot 'missing-file'),(Join-Path $electronRoot 'missing-parent/child'),(Join-Path $electron 'child')){
    $pathCases.Add([pscustomobject]@{Path=$path;Accepted=$true})
}
foreach($relative in 'NUL/file','file:stream','trailing.','trailing ','../escape'){
    $pathCases.Add([pscustomobject]@{Path=Join-Path $electronRoot $relative;Accepted=$false})
}
if($linkAvailable){
    foreach($path in $link,(Join-Path $link 'external.bin'),(Join-Path $link 'missing-child')){$pathCases.Add([pscustomobject]@{Path=$path;Accepted=$false})}
    $brokenTarget=Join-Path $TestRoot 'broken-link-target';$null=[IO.Directory]::CreateDirectory($brokenTarget)
    $brokenLink=Join-Path $TestRoot 'broken-link';$null=New-Item -ItemType $(if($IsWindows){'Junction'}else{'SymbolicLink'}) -Path $brokenLink -Target $brokenTarget
    [IO.Directory]::Delete($brokenTarget)
    foreach($path in $brokenLink,(Join-Path $brokenLink 'missing-child')){$pathCases.Add([pscustomobject]@{Path=$path;Accepted=$false})}
}
foreach($case in $pathCases){
    foreach($guard in 'Assert-ProviderReferencePath','Assert-AnalysisWindowsPayloadRegularPath'){
        $accepted=$true;try{& $guard $case.Path}catch{$accepted=$false}
        Assert-True ($accepted -eq $case.Accepted) ("Path boundary changed for $guard : "+$case.Path)
    }
}
Assert-Exception {Get-AnalysisWindowsPayloadFileHash (Join-Path $electronRoot 'missing-file')} 'not find|does not exist|cannot find'
# Exercise the actual production catch clauses, substituting only the native
# metadata read so access and non-missing I/O failures can be deterministic.
$metadataTry=(Get-Command Assert-AnalysisWindowsPayloadRegularPath).ScriptBlock.Ast.Find({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text -match '\[IO\.File\]::GetAttributes'},$true)
Assert-True ($null -ne $metadataTry) 'The native metadata read/catch boundary was not found.'
$faultTry=$metadataTry.Extent.Text.Replace($metadataTry.Body.Extent.Text,'{throw $InjectedMetadataFailure}')
$faultBoundary=[scriptblock]::Create("param([Exception]`$InjectedMetadataFailure)`nforeach(`$attempt in 1){$faultTry}")
foreach($missing in [IO.FileNotFoundException]::new('fixture missing file'),[IO.DirectoryNotFoundException]::new('fixture missing directory')){& $faultBoundary $missing}
foreach($failure in [UnauthorizedAccessException]::new('fixture access denied'),[IO.IOException]::new('fixture I/O failure'),[IO.PathTooLongException]::new('fixture path too long')){
    $caught=$null;try{& $faultBoundary $failure}catch{$caught=$_.Exception}
    Assert-True ([object]::ReferenceEquals($caught,$failure)) 'Native metadata error was swallowed or replaced.'
}
Write-Output 'PASS: native path checks retain provider acceptance, broken-link/ancestor refusal, missing-path handling and original access/I/O failures.'

if($IsWindows){
    $longRoot=Join-Path $TestRoot 'long-package'
    $longExe=New-FixtureFile (Join-Path $longRoot 'app.exe') ([byte[]]@(77,90,7))
    $longDirectory=$longRoot
    foreach($index in 1..24){$longDirectory=Join-Path $longDirectory ('segment'+$index.ToString('00'))}
    $null=New-FixtureFile (Join-Path $longDirectory 'known.bin') ([byte[]](0..63))
    Assert-ProviderReferencePath (Join-Path $longDirectory 'known.bin')
    Assert-AnalysisWindowsPayloadRegularPath (Join-Path $longDirectory 'known.bin')
    $longPayload=New-AnalysisWindowsPayload $longExe (Join-Path $TestRoot 'long-payload') -ApplicationRoot $longRoot
    Assert-PayloadArchive $longPayload
    $guestProbe=@'
param([string]$RepositoryRoot,[string]$PayloadDirectory,[string]$LongPayloadDirectory,[string]$WorkRoot,[string]$ResultPath)
$ErrorActionPreference='Stop'
. (Join-Path $RepositoryRoot 'scripts/ExecutableAnalysis/Expand-AnalysisWindowsPayload.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$null=[IO.Directory]::CreateDirectory($WorkRoot)
$passed=[Collections.Generic.List[string]]::new()
function Assert-Condition([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Refusal([scriptblock]$Action,[string]$Pattern,[string]$Name){
    $message=$null;try{$null=& $Action}catch{$message=$_.Exception.Message}
    Assert-Condition ($message -match $Pattern) ('Expected refusal '+$Name+': '+$message);$passed.Add($Name)
}
function Get-KnownHash([string]$Path){
    $stream=[IO.File]::OpenRead($Path);$sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')}finally{$sha.Dispose();$stream.Dispose()}
}
function Save-TestManifest($Value,[string]$Name){
    $path=Join-Path $WorkRoot ($Name+'.json');$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $path -Encoding utf8;return $path
}
$manifestPath=Join-Path $PayloadDirectory 'payload-manifest.json'
$archivePath=Join-Path $PayloadDirectory 'payload.zip'
$manifestHash=Get-KnownHash $manifestPath
$original=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
$extracted=Expand-AnalysisWindowsPayload -ManifestPath $manifestPath -ExpectedManifestSHA256 $manifestHash -ArchivePath $archivePath -OutputDirectory (Join-Path $WorkRoot 'roundtrip')
Assert-Condition ($extracted.Status -eq 'Completed' -and $extracted.FilesVerified -eq $original.Files.Count -and $extracted.BytesVerified -eq $original.TotalBytes) 'Guest roundtrip totals differ.'
foreach($file in $original.Files){Assert-Condition ((Get-KnownHash (Join-Path $extracted.Root $file.Path)) -eq $file.SHA256) 'Guest roundtrip file hash differs.'}
foreach($directory in $original.Directories){Assert-Condition ([IO.Directory]::Exists((Join-Path $extracted.Root $directory))) 'Guest empty directory missing.'}
$passed.Add('RoundtripWithEmptyDirectories')
$changed=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;$changed.Status='Failed';$changedPath=Save-TestManifest $changed 'altered-manifest'
Assert-Refusal {Expand-AnalysisWindowsPayload $changedPath $manifestHash $archivePath (Join-Path $WorkRoot 'bad-manifest')} 'manifest hash' 'AlteredManifestHash'
$changedArchive=Join-Path $WorkRoot 'altered-archive.zip';$bytes=[IO.File]::ReadAllBytes($archivePath);$bytes[0]=$bytes[0] -bxor 1;[IO.File]::WriteAllBytes($changedArchive,$bytes)
Assert-Refusal {Expand-AnalysisWindowsPayload $manifestPath $manifestHash $changedArchive (Join-Path $WorkRoot 'bad-archive')} 'archive hash' 'AlteredArchiveHash'
$changed=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;$changed.EntryPoint='missing.exe';$changedPath=Save-TestManifest $changed 'entrypoint'
Assert-Refusal {Expand-AnalysisWindowsPayload $changedPath (Get-KnownHash $changedPath) $archivePath (Join-Path $WorkRoot 'bad-entrypoint')} 'entry point' 'EntryPointMismatch'
$changed=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;$changed.Files[0].Path='../escaped.exe';$changedPath=Save-TestManifest $changed 'traversal'
Assert-Refusal {Expand-AnalysisWindowsPayload $changedPath (Get-KnownHash $changedPath) $archivePath (Join-Path $WorkRoot 'bad-traversal')} 'Unsafe|Invalid' 'PathTraversal'
Assert-Condition (-not(Test-Path -LiteralPath (Join-Path $WorkRoot 'escaped.exe'))) 'Traversal wrote outside output.'
$changed=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;$changed.Directories=@('../escape');$changedPath=Save-TestManifest $changed 'directory-traversal'
Assert-Refusal {Expand-AnalysisWindowsPayload $changedPath (Get-KnownHash $changedPath) $archivePath (Join-Path $WorkRoot 'bad-directory-traversal')} 'Unsafe|Invalid' 'DirectoryTraversal'
foreach($case in @('missing','extra','duplicate','corrupt-member')){
    $testArchive=Join-Path $WorkRoot ($case+'.zip');Copy-Item -LiteralPath $archivePath -Destination $testArchive
    $zip=[IO.Compression.ZipFile]::Open($testArchive,[IO.Compression.ZipArchiveMode]::Update)
    try{
        if($case -eq 'missing'){$zip.GetEntry($original.Files[0].Path).Delete()}
        elseif($case -eq 'extra'){$null=$zip.CreateEntry('extra.bin',[IO.Compression.CompressionLevel]::NoCompression)}
        elseif($case -eq 'duplicate'){$zip.GetEntry($original.Files[1].Path).Delete();$null=$zip.CreateEntry($original.Files[0].Path,[IO.Compression.CompressionLevel]::NoCompression)}
        else{
            $row=$original.Files[0];$zip.GetEntry($row.Path).Delete();$entry=$zip.CreateEntry($row.Path,[IO.Compression.CompressionLevel]::NoCompression);$stream=$entry.Open()
            try{$data=New-Object byte[] ([int]$row.Bytes);$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
        }
    }finally{$zip.Dispose()}
    $changed=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;$changed.ArchiveSHA256=Get-KnownHash $testArchive;$changedPath=Save-TestManifest $changed $case
    $pattern=if($case -eq 'corrupt-member'){'SHA256'}elseif($case -eq 'duplicate'){'duplicate|length'}else{'entry count'}
    Assert-Refusal {Expand-AnalysisWindowsPayload $changedPath (Get-KnownHash $changedPath) $testArchive (Join-Path $WorkRoot ('bad-'+$case))} $pattern $case
}
$longManifestPath=Join-Path $LongPayloadDirectory 'payload-manifest.json';$longManifest=Get-Content -LiteralPath $longManifestPath -Raw|ConvertFrom-Json
$long=Expand-AnalysisWindowsPayload $longManifestPath (Get-KnownHash $longManifestPath) (Join-Path $LongPayloadDirectory 'payload.zip') (Join-Path $WorkRoot 'extended-roundtrip')
$longRow=$longManifest.Files|Sort-Object { $_.Path.Length } -Descending|Select-Object -First 1
$longFull=Join-Path $long.Root ($longRow.Path.Replace('/','\'))
Assert-Condition ($longFull.Length -gt 260) 'Extended-path fixture did not exceed MAX_PATH.'
Assert-Condition ((Get-KnownHash ('\\?\'+$longFull)) -eq $longRow.SHA256) 'Extended-path extracted hash differs.'
$passed.Add('ExtendedPathRoundtrip')
@{Status='Passed';PowerShellVersion=$PSVersionTable.PSVersion.ToString();PSEdition=$PSVersionTable.PSEdition;PassedCases=$passed.ToArray();LongPathCharacters=$longFull.Length}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ResultPath -Encoding utf8
'PASS: guest expansion known bytes, integrity refusals, ZIP inventory and extended paths.'
'@ -replace "`r?`n","`r`n"
    $probePath=Join-Path $TestRoot 'Invoke-GuestPayloadProbe.ps1';[IO.File]::WriteAllText($probePath,$guestProbe,[Text.UTF8Encoding]::new($false))
    $modernResult=Join-Path $TestRoot 'guest-pwsh-result.json'
    & $probePath -RepositoryRoot $repo -PayloadDirectory (Split-Path $layout.ManifestPath -Parent) -LongPayloadDirectory (Split-Path $longPayload.ManifestPath -Parent) -WorkRoot (Join-Path $TestRoot 'guest-pwsh') -ResultPath $modernResult
    $legacyExe=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $legacyResult=Join-Path $TestRoot 'guest-ps51-result.json';$legacyLog=Join-Path $TestRoot 'guest-ps51.log'
    & $legacyExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probePath -RepositoryRoot $repo -PayloadDirectory (Split-Path $layout.ManifestPath -Parent) -LongPayloadDirectory (Split-Path $longPayload.ManifestPath -Parent) -WorkRoot (Join-Path $TestRoot 'guest-ps51') -ResultPath $legacyResult *> $legacyLog
    if($LASTEXITCODE -ne 0){throw ('Windows PowerShell guest probe failed. '+(Get-Content -LiteralPath $legacyLog -Tail 12|Out-String))}
    $legacy=Get-Content -LiteralPath $legacyResult -Raw|ConvertFrom-Json
    Assert-True ($legacy.Status -eq 'Passed' -and $legacy.PowerShellVersion -like '5.1.*' -and $legacy.PSEdition -eq 'Desktop' -and $legacy.PassedCases.Count -eq 11) 'Windows PowerShell 5.1 did not execute all guest payload checks.'
    Write-Output 'PASS: actual guest extractor under PowerShell 7 and Windows PowerShell 5.1; known bytes, empty directories, corruption/path/ZIP refusal, and paths longer than 260 characters.'
}
