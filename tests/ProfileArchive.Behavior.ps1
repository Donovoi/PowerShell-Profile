#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'Use a new fixture directory.' }
$null = [IO.Directory]::CreateDirectory($TestRoot)
. "$PSScriptRoot/../functions/Extract-ZIpFile.ps1"
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function New-Zip($Name, $Entries) {
    $path = Join-Path $TestRoot "$Name.zip"
    $zip = [IO.Compression.ZipFile]::Open($path, 'Create')
    try {
        foreach ($name in $Entries) {
            $entry = $zip.CreateEntry($name)
            if (-not $name.EndsWith('/')) {
                $writer = [IO.StreamWriter]::new($entry.Open())
                try { $writer.Write('fixture content') } finally { $writer.Dispose() }
            }
        }
    } finally { $zip.Dispose() }
    $path
}
$valid = New-Zip valid @('empty/', 'nested/file[1].txt')
$out = Join-Path $TestRoot 'valid'
Extract-ZipFile $valid $out -WhatIf
Assert (-not (Test-Path -LiteralPath $out)) 'WhatIf wrote output'
Extract-ZipFile $valid $out
Assert ([IO.File]::ReadAllText("$out/nested/file[1].txt") -eq 'fixture content') 'Incorrect extracted bytes'
Assert ([IO.Directory]::Exists("$out/empty")) 'Empty directory missing'
[IO.File]::WriteAllText("$out/nested/file[1].txt", 'old')
$failed = $false
try { Extract-ZipFile $valid $out } catch { $failed = $true }
Assert $failed 'Overwrite did not require Force'
Assert ([IO.File]::ReadAllText("$out/nested/file[1].txt") -eq 'old') 'Existing output damaged'
Extract-ZipFile $valid $out -Force
Assert ([IO.File]::ReadAllText("$out/nested/file[1].txt") -eq 'fixture content') 'Force did not replace output'
$index = 0
foreach ($bad in @('../escape', 'a/../../escape', '/rooted', 'C:\rooted', 'file:stream', 'NUL.txt', 'a./file', 'a/../b')) {
    $index++
    $zip = New-Zip "bad$index" @('first.txt', $bad)
    $target = Join-Path $TestRoot "bad$index"
    $failed = $false
    try { Extract-ZipFile $zip $target } catch { $failed = $true }
    Assert $failed "Unsafe entry accepted: $bad"
    Assert (-not (Test-Path -LiteralPath $target)) 'Validation wrote earlier entry'
}
foreach ($names in @(@('A.txt', 'a.txt'), @('a', 'a/b'))) {
    $index++; $zip = New-Zip "conflict$index" $names
    $failed = $false
    try { Extract-ZipFile $zip "$TestRoot/conflict$index" } catch { $failed = $true }
    Assert $failed 'Conflicting archive accepted'
}
$external = [IO.Directory]::CreateDirectory("$TestRoot/external")
$null = [IO.Directory]::CreateDirectory("$TestRoot/links")
$null = New-Item -ItemType Junction -Path "$TestRoot/links/nested" -Target $external.FullName
$failed = $false
try { Extract-ZipFile $valid "$TestRoot/links" } catch { $failed = $true }
Assert $failed 'Reparse parent accepted'
Assert (-not [IO.File]::Exists("$external/file[1].txt")) 'Escaped through junction'
$linkZip = New-Zip symlink @('link')
$zip = [IO.Compression.ZipFile]::Open($linkZip, 'Update')
$zip.Entries[0].ExternalAttributes = -1518338048
$zip.Dispose()
$failed = $false
try { Extract-ZipFile $linkZip "$TestRoot/symlink" } catch { $failed = $true }
Assert $failed 'Symbolic-link entry accepted'
Write-Host 'PASS: valid bytes, empty directories, WhatIf, overwrite, traversal/device/ADS, collisions, junction and symlink fixtures.'
