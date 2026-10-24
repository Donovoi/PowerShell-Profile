#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot,[string]$ArchiveDirectory)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'Firmware tool resolution behavior tests require Windows.'}
$TestRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new TestRoot.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/ExecutableAnalysis/Invoke-AnalysisTool.ps1')
. (Join-Path $repo 'scripts/ExecutableAnalysis/Resolve-AnalysisFirmwareTools.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Exception([scriptblock]$Action,[string]$Pattern){$message=$null;try{& $Action|Out-Null}catch{$message=$_.Exception.Message};Assert-True ($message -match $Pattern) ('Expected '+$Pattern+'; actual: '+$message)}
# All resolver behavior cases are offline. Downloads are forbidden unless a
# later case explicitly substitutes a local archive source.
$script:downloadCalls=0
function Save-AnalysisFirmwareDownload {param($Uri,$Destination)$script:downloadCalls++;throw 'Unexpected network request in offline behavior tests.'}
$pathBefore=$env:PATH
$cache=Join-Path $TestRoot 'no-install'
$missing=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $cache -NoInstall
Assert-True ($missing.Status -eq 'Unavailable' -and -not $missing.BIOSUtilities -and -not (Test-Path -LiteralPath $cache) -and $script:downloadCalls -eq 0) 'NoInstall created a cache or attempted downloads.'
$nativeInvoker=(Get-Command Invoke-AnalysisTool).ScriptBlock
$script:versionCalls=0
function Invoke-AnalysisTool {param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds,$MaxLogBytes)$script:versionCalls++;throw 'Forbidden alias/shim execution.'}
function Get-Command {
    [CmdletBinding()]param([string[]]$Name,[object]$CommandType,[switch]$All)
    [pscustomobject]@{Source='C:\Users\example\AppData\Local\Microsoft\WindowsApps\python.exe'}
    [pscustomobject]@{Source='C:\fake\python.bat'}
    [pscustomobject]@{Source='C:\fake\python.cmd'}
}
try{
    $aliases=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $cache -NoInstall
    Assert-True (-not $aliases.Python -and $script:versionCalls -eq 0 -and ($aliases.Limitations -join ' ') -match 'Python 3.10\+') 'Windows Store alias or shell shim was executed.'
}finally{Remove-Item Function:Get-Command;Set-Item Function:Invoke-AnalysisTool $nativeInvoker}
$script:pythonFixture=[Environment]::ProcessPath
$script:fixtureVersion='3.9.9'
$script:fixtureArguments=@()
function Get-Command {[CmdletBinding()]param([string[]]$Name,[object]$CommandType,[switch]$All)[pscustomobject]@{Source=$script:pythonFixture}}
function Invoke-AnalysisTool {
    param($FilePath,$ArgumentList,$LogPath,$WorkingDirectory,$TimeoutSeconds,$MaxLogBytes)
    $script:fixtureArguments=$ArgumentList
    $stdout=$LogPath+'.stdout';[IO.File]::WriteAllText($stdout,$script:fixtureVersion)
    [pscustomobject]@{Status='Completed';StandardOutputPath=$stdout}
}
try{
    $old=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $cache -NoInstall
    Assert-True (-not $old.Versions.Python -and ($old.Limitations -join ' ') -match 'Python 3.10\+') 'Python below 3.10 was accepted.'
    $script:fixtureVersion='3.10.0'
    $current=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $cache -NoInstall
    Assert-True ($current.Versions.Python -eq '3.10.0' -and ($script:fixtureArguments[0..2] -join ' ') -eq '-B -I -S') 'Python 3.10 was rejected or probed without isolated flags.'
}finally{Remove-Item Function:Get-Command;Set-Item Function:Invoke-AnalysisTool $nativeInvoker}
Write-Output 'PASS: NoInstall does not install/download, and Windows Store aliases and shell shims are not executed.'

function New-ArchiveFixture {
    param([string]$Name,[string[]]$Entries,[switch]$Link)
    $path=Join-Path $TestRoot $Name
    $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
    try{
        foreach($name in $Entries){
            $entry=$zip.CreateEntry($name)
            if($Link){$entry.ExternalAttributes=-1577123840}
            $output=$entry.Open();try{$output.WriteByte(42)}finally{$output.Dispose()}
        }
    }finally{$zip.Dispose()}
    return $path
}
$index=0
foreach($name in @('../outside.py','/absolute.py','C:/drive.py','dir\..\outside.py','dir/NUL.txt','dir/trailing.','dir//empty.py')){
    $index++;$archive=New-ArchiveFixture ('unsafe-'+$index+'.zip') @($name)
    Assert-Exception {Get-AnalysisFirmwareArchivePlan -ArchivePath $archive -Root payload} 'Unsafe archive path'
}
$duplicate=New-ArchiveFixture 'duplicate.zip' @('module.py','MODULE.py')
Assert-Exception {Get-AnalysisFirmwareArchivePlan -ArchivePath $duplicate -Root payload} 'Duplicate archive path'
$link=New-ArchiveFixture 'link.zip' @('linked.py') -Link
Assert-Exception {Get-AnalysisFirmwareArchivePlan -ArchivePath $link -Root payload} 'link/reparse'
Assert-Exception {Get-AnalysisFirmwareArchivePlan -ArchivePath $duplicate -Root '../outside'} 'Unsafe archive destination'
$incomplete=Join-Path $TestRoot 'incomplete'
$null=[IO.Directory]::CreateDirectory((Join-Path $incomplete 'payload'))
$marker=Join-Path $incomplete 'payload/keep.bin';[IO.File]::WriteAllBytes($marker,[byte[]]@(1,2,3))
$partial=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $incomplete
Assert-True ($partial.Status -eq 'Unavailable' -and -not $partial.UEFIExtract -and (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath (Join-Path $incomplete 'manifest.json')) -and $script:downloadCalls -eq 0) 'Incomplete cache was reset, marked ready, or caused a download.'
$locked=Join-Path $TestRoot 'locked';$null=[IO.Directory]::CreateDirectory($locked)
$held=[IO.File]::Open((Join-Path $locked 'cache.lock'),'OpenOrCreate','ReadWrite','None')
try{$busy=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $locked;Assert-True (($busy.Limitations -join ' ') -match 'lock is unavailable' -and -not $busy.BIOSUtilities) 'Concurrent cache lock was ignored.'}finally{$held.Dispose()}
$linkTarget=Join-Path $TestRoot 'junction-target';$null=[IO.Directory]::CreateDirectory($linkTarget)
$junction=Join-Path $TestRoot 'junction-cache';$null=New-Item -ItemType Junction -Path $junction -Target $linkTarget
$linked=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $junction
Assert-True (($linked.Limitations -join ' ') -match 'Reparse-point' -and -not (Test-Path -LiteralPath (Join-Path $linkTarget 'cache.lock'))) 'Reparse cache root was traversed or modified.'
Write-Output 'PASS: archive traversal/drive/device/duplicate/link paths, incomplete installs, concurrent locks and reparse caches fail closed.'

if($ArchiveDirectory){
    $ArchiveDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArchiveDirectory)
    $specs=@(Get-AnalysisFirmwarePackageSpec)
    foreach($spec in $specs){Assert-True ((Get-FileHash -LiteralPath (Join-Path $ArchiveDirectory $spec.File) -Algorithm SHA256).Hash -eq $spec.SHA256) ('Pinned fixture archive mismatch: '+$spec.File)}
    $offline=Join-Path $TestRoot 'offline-complete'
    $offlineArchives=Join-Path $offline 'archives';$null=[IO.Directory]::CreateDirectory($offlineArchives)
    foreach($spec in $specs){[IO.File]::Copy((Join-Path $ArchiveDirectory $spec.File),(Join-Path $offlineArchives $spec.File))}
    $resolved=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $offline
    Assert-True ($resolved.Status -eq 'Completed' -and $resolved.Python -and $resolved.BIOSUtilities -and $resolved.UEFIExtract -and $resolved.IFRExtractor -and $resolved.PythonDependencies -and $resolved.ManifestPath) ('Offline pinned installation failed: '+($resolved.Limitations -join ' '))
    $manifestBytes=[IO.File]::ReadAllBytes($resolved.ManifestPath)
    $reused=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $offline -NoInstall
    Assert-True ($reused.Status -eq 'Completed' -and $reused.ManifestPath -eq $resolved.ManifestPath -and $script:downloadCalls -eq 0) ('Verified cache did not reuse offline: '+($reused.Limitations -join ' '))
    $pythonPaths=@($resolved.PythonDependencies,$resolved.BIOSUtilities)|ConvertTo-Json -Compress
    $code='import sys;sys.path[:0]='+$pythonPaths+';from biosutilities.dell_pfs_extract import DellPfsExtract;import pefile;from dissect.util.compression import lznt1;print("ISOLATED_IMPORT_OK")'
    $probe=Invoke-AnalysisTool -FilePath $resolved.Python -ArgumentList @('-B','-I','-S','-c',$code) -LogPath (Join-Path $TestRoot 'isolated-imports') -WorkingDirectory $TestRoot -TimeoutSeconds 20 -MaxLogBytes 1MB
    Assert-True ($probe.Status -eq 'Completed' -and [IO.File]::ReadAllText($probe.StandardOutputPath).Trim() -eq 'ISOLATED_IMPORT_OK') 'Pinned pure Python packages failed isolated -B -I -S import.'
    $afterImports=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $offline -NoInstall
    Assert-True ($afterImports.Status -eq 'Completed') 'Isolated imports added untracked files or modified the verified cache.'
    $exeBytes=[IO.File]::ReadAllBytes($resolved.UEFIExtract)
    [IO.File]::WriteAllBytes($resolved.UEFIExtract,[byte[]]@(77,90,0))
    $changed=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $offline -NoInstall
    Assert-True ($changed.Status -eq 'Unavailable' -and -not $changed.UEFIExtract -and (Get-Item -LiteralPath $resolved.UEFIExtract).Length -eq 3 -and ($changed.Limitations -join ' ') -match 'hash mismatch') 'Changed native tool was accepted or replaced.'
    [IO.File]::WriteAllBytes($resolved.UEFIExtract,$exeBytes)
    $pyFile=Join-Path $resolved.PythonDependencies 'pefile.py';$pyBytes=[IO.File]::ReadAllBytes($pyFile)
    [IO.File]::WriteAllText($pyFile,'raise RuntimeError("tampered fixture")')
    $manifest=Get-Content -LiteralPath $resolved.ManifestPath -Raw|ConvertFrom-Json
    $entry=$manifest.Files|Where-Object RelativePath -EQ 'python-dependencies/pefile.py'
    $entry.Length=(Get-Item -LiteralPath $pyFile).Length;$entry.SHA256=(Get-FileHash -LiteralPath $pyFile).Hash
    [IO.File]::WriteAllText($resolved.ManifestPath,($manifest|ConvertTo-Json -Depth 6))
    $forged=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $offline -NoInstall
    Assert-True ($forged.Status -eq 'Unavailable' -and -not $forged.BIOSUtilities -and ($forged.Limitations -join ' ') -match 'hash mismatch') 'Changing both library and manifest bypassed pinned archive validation.'
    [IO.File]::WriteAllBytes($pyFile,$pyBytes);[IO.File]::WriteAllBytes($resolved.ManifestPath,$manifestBytes)
    $extra=Join-Path $resolved.PythonDependencies 'unexpected.py';[IO.File]::WriteAllText($extra,'')
    $injected=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $offline -NoInstall
    Assert-True ($injected.Status -eq 'Unavailable' -and -not $injected.PythonDependencies -and (Test-Path -LiteralPath $extra) -and ($injected.Limitations -join ' ') -match 'Unexpected payload file') 'Unexpected Python file was accepted or deleted.'
    $badCache=Join-Path $TestRoot 'bad-archive';$null=[IO.Directory]::CreateDirectory((Join-Path $badCache 'archives'))
    $badArchive=Join-Path $badCache ('archives/'+$specs[0].File);[IO.File]::WriteAllText($badArchive,'corrupt archive')
    $bad=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $badCache
    Assert-True ($bad.Status -eq 'Unavailable' -and -not $bad.UEFIExtract -and [IO.File]::ReadAllText($badArchive) -eq 'corrupt archive' -and -not (Test-Path -LiteralPath (Join-Path $badCache 'manifest.json'))) 'Bad cached archive was replaced or marked ready.'
    $script:fixtureArchives=$ArchiveDirectory
    function Save-AnalysisFirmwareDownload {
        param($Uri,$Destination)
        $script:downloadCalls++
        $spec=Get-AnalysisFirmwarePackageSpec|Where-Object Uri -EQ $Uri
        if(-not $spec){throw 'Unpinned download URI requested.'}
        [IO.File]::Copy((Join-Path $script:fixtureArchives $spec.File),$Destination)
    }
    $downloadCache=Join-Path $TestRoot 'download-substitution'
    $downloaded=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $downloadCache
    Assert-True ($downloaded.Status -eq 'Completed' -and $script:downloadCalls -eq 5) 'Pinned download/extraction flow failed with offline archive substitution.'
    $payloadJunction=Join-Path $downloadCache 'payload/biosutilities/unexpected-junction'
    $null=New-Item -ItemType Junction -Path $payloadJunction -Target $linkTarget
    $reparse=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $downloadCache -NoInstall
    Assert-True ($reparse.Status -eq 'Unavailable' -and ($reparse.Limitations -join ' ') -match 'Reparse-point payload' -and (Test-Path -LiteralPath $payloadJunction)) 'Nested payload junction was accepted or removed.'
    function Save-AnalysisFirmwareDownload {param($Uri,$Destination)$script:downloadCalls++;[IO.File]::WriteAllText($Destination,'wrong download bytes')}
    $failedCache=Join-Path $TestRoot 'failed-download'
    $failed=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $failedCache
    $failedDownloads=@(Get-ChildItem -LiteralPath (Join-Path $failedCache 'archives') -File)
    Assert-True ($failed.Status -eq 'Unavailable' -and ($failed.Limitations -join ' ') -match 'checksum/size mismatch' -and $failedDownloads.Count -eq 1 -and [IO.File]::ReadAllText($failedDownloads[0].FullName) -eq 'wrong download bytes' -and -not (Test-Path -LiteralPath (Join-Path $failedCache 'manifest.json'))) 'Bad download was accepted, deleted or marked ready.'
    $again=Resolve-AnalysisFirmwareTool -LogDirectory $TestRoot -CacheRoot $failedCache
    Assert-True ($again.Status -eq 'Unavailable' -and $script:downloadCalls -eq 6 -and ($again.Limitations -join ' ') -match 'Incomplete firmware cache') 'Failed installation was retried over its preserved partial state.'
    Write-Output 'PASS: all five real pinned archives install/reuse offline, isolated imports work, native/library/manifest/extra-file corruption is preserved and refused, and pinned download substitution succeeds.'
}
Assert-True ($env:PATH -ceq $pathBefore) 'Resolver changed PATH.'
Write-Output 'PASS: firmware resolver left PATH unchanged; no firmware target was executed.'
