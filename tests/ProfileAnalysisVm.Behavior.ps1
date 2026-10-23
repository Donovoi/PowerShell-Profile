#requires -Version 7.0
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'TestRoot must be new.' }
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'functions/Initialize-ExecutableAnalysisVm.ps1')
. (Join-Path $repo 'functions/Invoke-ExecutableAnalysisVm.ps1')
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws { param([scriptblock]$Action, [string]$Message) $thrown=$false; try { & $Action } catch { $thrown=$true }; Assert-True $thrown $Message }

# Unsupported inputs must be rejected before any VM lookup, output creation, or execution.
$output = Join-Path $TestRoot 'must-not-exist'
foreach ($case in @(
    @{ Name='windows.exe'; Bytes=[byte[]](0x4d,0x5a,0,0) },
    @{ Name='macos'; Bytes=[byte[]](0xcf,0xfa,0xed,0xfe) },
    @{ Name='empty'; Bytes=[byte[]]@() },
    @{ Name='script.ps1'; Bytes=[Text.Encoding]::UTF8.GetBytes('throw "This input must never run"') }
)) {
    $path = Join-Path $TestRoot $case.Name
    [IO.File]::WriteAllBytes($path,$case.Bytes)
    $result = Invoke-ExecutableAnalysisVm -InputPath $path -OutputPath $output -VirtualMachineName 'No-Such-Test-VM'
    Assert-True ($result.Status -eq 'Unsupported') "Unsupported format $($case.Name) was accepted."
    Assert-True ($result.TargetSHA256 -eq (Get-FileHash -LiteralPath $path).Hash) 'Unsupported result lost source hash.'
    Assert-True (-not (Test-Path -LiteralPath $output)) 'Unsupported input created output or touched a VM.'
}
$header = [byte[]]::new(64)
$header[0]=0x7f; $header[1]=0x45; $header[2]=0x4c; $header[3]=0x46; $header[4]=2; $header[5]=1; $header[16]=2; $header[18]=183
$path = Join-Path $TestRoot 'arm64-elf'
[IO.File]::WriteAllBytes($path,$header)
Assert-True ((Invoke-ExecutableAnalysisVm -InputPath $path -OutputPath $output).Status -eq 'Unsupported') 'ARM64 was incorrectly claimed executable on x86-64.'
$header[18]=62; $header[16]=1
[IO.File]::WriteAllBytes($path,$header)
Assert-True ((Invoke-ExecutableAnalysisVm -InputPath $path -OutputPath $output).Status -eq 'Unsupported') 'A relocatable ELF object was accepted for execution.'
Assert-Throws { Invoke-ExecutableAnalysisVm -InputPath $TestRoot -OutputPath $output } 'Directory input was accepted.'
Assert-Throws { Invoke-ExecutableAnalysisVm -InputPath $path -OutputPath $output -TimeoutSeconds 0 } 'An unbounded timeout was accepted.'
Write-Host 'PASS: unsupported formats, architectures, objects, paths and invalid time limits fail before any execution'

# Exercise the actual nested isolation validator without requiring VirtualBox in CI.
$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'functions/Invoke-ExecutableAnalysisVm.ps1'), [ref]$tokens, [ref]$errors)
$validator = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-AnalysisVmIsolation'}, $true)
Assert-True ($null -ne $validator) 'Isolation validator is unavailable.'
. ([scriptblock]::Create($validator.Extent.Text))
$manifest = [pscustomobject]@{ VirtualMachineId='fixture-owned-vm'; StoragePath=$TestRoot }
$valid = @{ UUID='fixture-owned-vm'; clipboard='disabled'; draganddrop='disabled'; clipboard_file_transfers='off' }
foreach($key in @('usb','ehci','xhci','vrde','audio_in','audio_out','nested-hw-virt','teleporterenabled')) { $valid[$key]='off' }
foreach($adapter in 1..8) { $valid["nic$adapter"]='none' }
foreach($port in 1..4) { $valid["uart$port"]='off' }
$valid['SATA-0-0']=Join-Path $TestRoot 'owned.vdi'
Assert-AnalysisVmIsolation -Settings $valid
foreach($fault in @(
    @{ Key='nic1'; Value='nat' }, @{ Key='nic8'; Value='hostonly' },
    @{ Key='usb'; Value='on' }, @{ Key='clipboard'; Value='bidirectional' },
    @{ Key='draganddrop'; Value='bidirectional' }, @{ Key='uart1'; Value='0x03f8,4' },
    @{ Key='SharedFolderNameMachineMapping1'; Value='Host Files' },
    @{ Key='UUID'; Value='unrelated-vm' },
    @{ Key='SATA-1-0'; Value=(Join-Path $TestRoot 'host-content.iso') },
    @{ Key='SATA-0-0'; Value=(Join-Path (Split-Path $TestRoot -Parent) 'outside.vdi') }
)) {
    $broken=$valid.Clone(); $broken[$fault.Key]=$fault.Value
    Assert-Throws { Assert-AnalysisVmIsolation -Settings $broken } "Isolation accepted unsafe $($fault.Key)."
}
$unknown=$valid.Clone(); $unknown.Remove('nic7')
Assert-Throws { Assert-AnalysisVmIsolation -Settings $unknown } 'Unknown NIC state was accepted.'
Write-Host 'PASS: actual isolation validator rejects network, host integration, shared folder, identity and storage boundary failures'

$lockDefinition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Enter-AnalysisVmLock'}, $true)
Assert-True ($null -ne $lockDefinition) 'Exclusive runtime lock is unavailable.'
. ([scriptblock]::Create($lockDefinition.Extent.Text))
$firstLock = Enter-AnalysisVmLock -StoragePath $TestRoot
try { Assert-Throws { Enter-AnalysisVmLock -StoragePath $TestRoot } 'A concurrent runtime operation acquired the same VM lock.' }
finally { $firstLock.Dispose() }
$nextLock = Enter-AnalysisVmLock -StoragePath $TestRoot
$nextLock.Dispose()
Write-Host 'PASS: real exclusive file lock rejects contention and can be acquired again after release'

$command=Get-Command Invoke-ExecutableAnalysisVm
Assert-True ($command.Parameters.ContainsKey('WhatIf') -and $command.Parameters.ContainsKey('Confirm')) 'Runtime operation lacks ShouldProcess support.'
$command=Get-Command Initialize-ExecutableAnalysisVm
Assert-True ($command.Parameters.ContainsKey('WhatIf')) 'VM creation lacks ShouldProcess support.'
Write-Host 'PASS: VM lifecycle entry points expose PowerShell preview and confirmation parameters'
