# Compile and exercise pure recording logic only. No process/window/native API runs.
#requires -Version 5.1
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$runner=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestRunner.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) 'The guest runner does not parse.'
$native=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class ProfileAnalysisGuestJob')},$true))
Assert-True ($native.Count -eq 1) 'The exact native observer source was not found.'
$nativeSource=$native[0].Value
$start=$nativeSource.IndexOf(' public const int MaximumObservedProcesses=')
$end=$nativeSource.IndexOf(' [StructLayout(LayoutKind.Sequential)] struct Rectangle',$start)
Assert-True ($start -ge 0 -and $end -gt $start) 'The pure observation recorder boundary changed.'
$pureSource='using System;using System.Collections.Generic;public static class ProfileAnalysisObservationBoundsFixture {'+$nativeSource.Substring($start,$end-$start)+'}'
Add-Type -TypeDefinition $pureSource -Language CSharp
Assert-True ([regex]::Matches($nativeSource,'RecordProcessObservation\(result,seen,').Count -eq 2 -and [regex]::Matches($nativeSource,'RecordWindowObservation\(result,windows,').Count -eq 2) 'Both execution paths must use the shared bounded recorders.'
Assert-True ([regex]::Matches($nativeSource,'if\(result.ProcessObservationLimitReached \|\| result.WindowObservationLimitReached\)break;').Count -eq 2) 'Both observation loops must stop with their explicit partial limit reason.'

$result=[ProfileAnalysisObservationBoundsFixture+Result]::new()
$seen=[Collections.Generic.HashSet[int]]::new()
$windows=[Collections.Generic.HashSet[long]]::new()
$longText=([string][char]1)*4000
foreach($id in 1..128){Assert-True ([ProfileAnalysisObservationBoundsFixture]::RecordProcessObservation($result,$seen,$id,$longText,$longText)) 'An in-budget historical process was dropped.'}
Assert-True ($seen.Count -eq 128 -and $result.Processes.Count -eq 128 -and -not $result.ProcessObservationLimitReached) 'Reaching the exact process capacity falsely claimed omitted evidence.'
$first=$result.Processes[0]
Assert-True ($first.Name.Length -eq 128 -and $first.ImagePath.Length -eq 512 -and $first.NameTruncated -and $first.ImagePathTruncated -and $first.Name -ceq $longText.Substring(0,128) -and $first.ImagePath -ceq $longText.Substring(0,512)) 'Process text was not retained as a bounded exact prefix with truncation evidence.'
Assert-True ([ProfileAnalysisObservationBoundsFixture]::RecordProcessObservation($result,$seen,1,'changed','changed') -and $seen.Count -eq 128 -and [object]::ReferenceEquals($result.Processes[0],$first) -and $first.Name -ceq $longText.Substring(0,128)) 'Repeated process polling changed evidence or consumed historical capacity.'
foreach($id in 129..2000){Assert-True (-not [ProfileAnalysisObservationBoundsFixture]::RecordProcessObservation($result,$seen,$id,$longText,$longText)) 'Process churn exceeded the historical evidence cap.'}
Assert-True ($result.ProcessObservationLimitReached -and $result.Reason -ceq 'ProcessInventoryLimit' -and $seen.Count -eq 128 -and $result.Processes.Count -eq 128) 'Historical process overflow lost its partial reason or allowed an unbounded seen set.'

foreach($handle in 1..64){Assert-True ([ProfileAnalysisObservationBoundsFixture]::RecordWindowObservation($result,$windows,1,$handle,$longText,-2147483648,-2147483648,2147483647,2147483647)) 'An in-budget window was dropped.'}
Assert-True ($windows.Count -eq 64 -and $result.Windows.Count -eq 64 -and -not $result.WindowObservationLimitReached) 'Reaching the exact window capacity falsely claimed omitted evidence.'
$firstWindow=$result.Windows[0]
Assert-True ($firstWindow.Title.Length -eq 256 -and $firstWindow.TitleTruncated -and $firstWindow.Title -ceq $longText.Substring(0,256)) 'Window titles lost their text bound or truncation evidence.'
Assert-True ([ProfileAnalysisObservationBoundsFixture]::RecordWindowObservation($result,$windows,1,1,'changed',0,0,1,1) -and $windows.Count -eq 64 -and [object]::ReferenceEquals($result.Windows[0],$firstWindow)) 'Repeated window polling consumed capacity or changed prior evidence.'
foreach($handle in 65..2000){Assert-True (-not [ProfileAnalysisObservationBoundsFixture]::RecordWindowObservation($result,$windows,1,$handle,$longText,0,0,1,1)) 'Window churn exceeded the historical evidence cap.'}
Assert-True ($result.WindowObservationLimitReached -and $result.Reason -ceq 'WindowInventoryLimit' -and $windows.Count -eq 64 -and $result.Windows.Count -eq 64) 'Window overflow lost its explicit partial reason or allowed an unbounded seen set.'
$small=[ProfileAnalysisObservationBoundsFixture+Result]::new();$smallSeen=[Collections.Generic.HashSet[int]]::new();$smallWindows=[Collections.Generic.HashSet[long]]::new()
$nullTextRecorded=[ProfileAnalysisObservationBoundsFixture].GetMethod('RecordProcessObservation').Invoke($null,[object[]]@($small,$smallSeen,1,$null,$null))
Assert-True ($nullTextRecorded -and $null -eq $small.Processes[0].Name -and $null -eq $small.Processes[0].ImagePath -and -not $small.Processes[0].NameTruncated -and -not $small.Processes[0].ImagePathTruncated) 'Unavailable process text was invented or marked as truncated.'
Assert-True ([ProfileAnalysisObservationBoundsFixture]::RecordWindowObservation($small,$smallWindows,1,1,'Exact title',0,0,640,480) -and $small.Windows[0].Title -ceq 'Exact title' -and -not $small.Windows[0].TitleTruncated) 'An ordinary window title changed.'

# Control characters maximize JSON escaping; three-byte UTF-8 models a maximum
# native image-path buffer. Leave at least 256KiB for the rest of runtime.json.
$result.RootImagePath=([string][char]0x800)*32768
$serialized=$result|ConvertTo-Json -Depth 10
$executionBytes=[Text.Encoding]::UTF8.GetByteCount($serialized)
Assert-True ($executionBytes -lt 768KB) ('Bounded observations exceed their conservative serialization budget: '+$executionBytes)
$report=[ordered]@{Status='Partial';Execution=$result;Validation=@{HashMatched=$true};OtherFixtureMetadata=('M'*16384)}
$reportBytes=[Text.Encoding]::UTF8.GetByteCount(($report|ConvertTo-Json -Depth 10))
Assert-True ($reportBytes -lt 1MB) 'Representative runtime evidence exceeded the host report acceptance limit.'
$nativeCompiled=$false
if($PSVersionTable.PSEdition -eq 'Desktop'){
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ReferencedAssemblies System.Drawing,System.Core
    Assert-True ($null -ne [ProfileAnalysisGuestJob].GetMethod('Run') -and $null -ne [ProfileAnalysisGuestJob].GetMethod('RunRegistered')) 'The actual guest-runtime native entry points did not compile.'
    $nativeCompiled=$true
}
[ordered]@{Status='Passed';PowerShellVersion=$PSVersionTable.PSVersion.ToString();ProcessCount=$result.Processes.Count;WindowCount=$result.Windows.Count;WorstEscapedExecutionBytes=$executionBytes;RepresentativeReportBytes=$reportBytes;FullGuestNativeSourceCompiled=$nativeCompiled;NativeApisInvoked=$false}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $TestRoot 'observation-bounds.json') -Encoding utf8
Write-Output ('PASS: PowerShell '+$PSVersionTable.PSVersion+' pure native recording helpers cap historical PID/HWND churn, preserve ordinary evidence, flag truncated text/partial limits and retain bounded JSON without process or window API calls.')
