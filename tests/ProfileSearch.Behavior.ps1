#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new fixture directory.'}
$null=[IO.Directory]::CreateDirectory("$TestRoot/source/nested/deep")
foreach($name in 'Initialize-CmdletDependencies','Find-FilesWithGlobPattern','Find-RustyFile','Find-FilesRust','Invoke-EverythingSearch'){. "$PSScriptRoot/../functions/$name.ps1"}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
foreach($name in 'top.log','nested/é space.log','nested/deep/other.txt','nested/long-name-more-than-sixteen.log'){
    [IO.File]::WriteAllText("$TestRoot/source/$name","ordinary line`nneedle café`n")
}
[IO.File]::WriteAllText("$TestRoot/Cargo.toml",'caller sentinel')
$source=Join-Path $TestRoot source
$all=@(Find-FilesWithGlobPattern -Path $source -GlobPattern '*.log')
Assert ($all.Count -eq 3) 'Filename glob omitted matches'
Assert (@(Find-FilesWithGlobPattern -Path $source -GlobPattern '**/*.log').Count -eq 3) '** did not match zero or more directories'
Assert (@(Find-FilesWithGlobPattern -Path $source -GlobPattern 'nested/*.log').Count -eq 2) 'Single-level relative glob incorrect'
Assert (@(Find-FilesWithGlobPattern -Path $source -GlobPattern 'nested/**/other.?xt').Count -eq 1) 'Nested glob incorrect'
Assert (@(Find-RustyFile -StartDir $source -Pattern '^é.*\.log$' -UseRegex $true).Count -eq 1) 'Unicode regex filename search failed'
Assert (@(Find-RustyFile -StartDir $source -Pattern '*.log' -UseRegex $false).Count -eq 3) 'Glob compatibility wrapper failed'
$matchesFound=@(Find-FilesRust -Directory $source -SearchTerm 'needle café')
Assert ($matchesFound.Count -eq 4 -and @($matchesFound|Where-Object LineNumber -NE 2).Count -eq 0) 'Content search lost line or Unicode information'
Assert ([IO.File]::ReadAllText("$TestRoot/Cargo.toml") -eq 'caller sentinel' -and -not [IO.Directory]::Exists("$TestRoot/target")) 'Search touched build files'
$null=New-Item -ItemType Junction -Path "$source/nested/loop" -Target $source
Assert (@(Find-FilesWithGlobPattern -Path $source -GlobPattern '*.log').Count -eq 3) 'Search followed a junction'
Write-Host 'PASS: Unicode, filename regex, relative/recursive globs, content lines and no build/junction side effects'

$tools=Join-Path $TestRoot tools
$null=[IO.Directory]::CreateDirectory($tools)
[IO.File]::WriteAllText("$tools/es.exe",'fixture')
[IO.File]::WriteAllText("$tools/Everything.exe",'fixture')
$script:started=@();$script:stopped=@();$script:failSearch=$false
function Start-Process {
    [CmdletBinding()] param($FilePath,$ArgumentList,$WindowStyle,$RedirectStandardOutput,$RedirectStandardError,[switch]$PassThru)
    Assert ($WindowStyle -eq 'Hidden' -and $ArgumentList[0] -eq '-instance' -and $ArgumentList[1] -like 'ProfileSearch-*') 'Everything launch was not isolated/hidden'
    $script:started+=,$ArgumentList
    $fake=[pscustomobject]@{Id=987654;HasExited=$false}
    $fake|Add-Member ScriptMethod WaitForExit {param($Timeout) $true}
    $fake|Add-Member ScriptMethod Dispose {}
    $fake
}
function Stop-Process { [CmdletBinding()] param($Id,[switch]$Force) Assert ($Id -eq 987654) 'Unowned process stopped'; $script:stopped+=$Id }
function Get-Process { throw 'Search must not enumerate/stop existing Everything processes' }
function Invoke-Process {
    [CmdletBinding(SupportsShouldProcess)] param($FilePath,$ArgumentList,[switch]$PassThru,[switch]$IgnoreExitCode,$TimeoutSeconds)
    if($script:failSearch){throw 'simulated CLI failure'}
    if($ArgumentList -contains '-reindex'){return [pscustomobject]@{ExitCode=0;StandardOutput='';StandardError=''}}
    Assert ($ArgumentList -contains '-path' -and $ArgumentList -contains $source) 'Search path or argument boundary lost'
    $script:exportFile=$ArgumentList[[Array]::IndexOf($ArgumentList,'-export-txt')+1]
    Assert ($ArgumentList -contains '-utf8-bom') 'Search must use UTF-8 file output'
    [IO.File]::WriteAllLines($script:exportFile,@($all[0],$all[1],$all[0]),[Text.UTF8Encoding]::new($true))
    [pscustomobject]@{ExitCode=0;StandardOutput='unused ANSI output';StandardError=''}
}
$result=@(Invoke-EverythingSearch -EverythingDirectory $tools -SearchInDirectory $source)
Assert ($result.Count -eq 2 -and $script:started.Count -eq 1 -and $script:stopped.Count -eq 1) 'Owned search result/cleanup failed'
Assert (@(Compare-Object $result @($all[0],$all[1])).Count -eq 0 -and -not [IO.File]::Exists($script:exportFile)) 'Unicode result or temporary output cleanup failed'
$script:failSearch=$true
$failed=$false;try{Invoke-EverythingSearch -EverythingDirectory $tools -SearchInDirectory $source}catch{$failed=$true}
Assert ($failed -and $script:stopped.Count -eq 2) 'Failed CLI did not clean up its own process'
$script:failSearch=$false
$null=Invoke-EverythingSearch -EverythingDirectory $tools -SearchInDirectory $source -InstanceName existing
Assert ($script:started.Count -eq 2 -and $script:stopped.Count -eq 2) 'Existing instance was started or stopped'
Write-Host 'PASS: Everything exact process ownership, failure cleanup, arguments and existing-instance preservation'
