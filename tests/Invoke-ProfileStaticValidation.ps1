#requires -Version 7.0
[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$baseline=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'StaticAnalysis.Baseline.json') -Raw|ConvertFrom-Json
if(-not(Get-Module PSScriptAnalyzer)){Import-Module PSScriptAnalyzer -RequiredVersion $baseline.AnalyzerVersion -ErrorAction Stop}
if((Get-Module PSScriptAnalyzer).Version.ToString() -ne $baseline.AnalyzerVersion){throw 'Use the PSScriptAnalyzer version recorded in the baseline.'}
$records=foreach($file in $baseline.Files){
    if(-not(Test-Path -LiteralPath (Join-Path $repo $file))){throw "Missing analysis target: $file"}
    Invoke-ScriptAnalyzer -Path (Join-Path $repo $file) -Settings (Join-Path $repo 'Non PowerShell Tools/PSScriptAnalyzerSettings.psd1')|ForEach-Object {
        [pscustomobject]@{File=$file;RuleName=$_.RuleName;Severity=$_.Severity.ToString();Line=$_.Line;Message=$_.Message}
    }
}
$unexpected=[Collections.Generic.List[object]]::new()
foreach($group in @($records|Where-Object Severity -In 'Warning','Error'|Group-Object File,RuleName,Message)){
    $entry=$group.Group[0]
    $allowed=@($baseline.AllowedWarnings|Where-Object {$_.File -eq $entry.File -and $_.RuleName -eq $entry.RuleName -and $_.Message -eq $entry.Message})
    if($entry.Severity -eq 'Error' -or $allowed.Count -ne 1 -or $group.Count -gt $allowed[0].Count){foreach($item in $group.Group){$unexpected.Add($item)}}
}
$record=[pscustomobject]@{AnalyzerVersion=$baseline.AnalyzerVersion;Files=$baseline.Files.Count;Errors=@($records|Where-Object Severity -EQ 'Error').Count;Warnings=@($records|Where-Object Severity -EQ 'Warning').Count;Unexpected=$unexpected.ToArray();Results=$records}
if($OutputPath){$record|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $OutputPath -Encoding utf8}
if($unexpected.Count){$unexpected|Format-Table File,Line,RuleName -AutoSize|Out-String|Write-Host;throw 'Static validation found new warnings or errors.'}
Write-Host "PASS: $($baseline.Files.Count) production files; no errors or warnings beyond the reviewed compatibility baseline."
