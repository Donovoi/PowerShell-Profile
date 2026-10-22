#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $TestRoot) { throw 'Use a new fixture directory.' }
$null=[IO.Directory]::CreateDirectory($TestRoot)
. "$PSScriptRoot/../functions/Set-StoredSecret.ps1"
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message } }
$script:installed=@(); $script:stored=@(); $script:unlockFails=$false; $script:writeFails=$false
$script:vaults=@([pscustomobject]@{Name='fixture';ModuleName='Microsoft.PowerShell.SecretStore';IsDefault=$true})
function Get-Module { [CmdletBinding()] param($Name,[switch]$ListAvailable) }
function Install-Module { [CmdletBinding()] param($Name,$Scope,[switch]$Force) Assert ($Scope -eq 'CurrentUser') 'Install scope changed'; $script:installed += $Name }
function Import-Module { [CmdletBinding()] param($Name) }
function Get-SecretVault { [CmdletBinding()] param() $script:vaults }
function Unlock-SecretStore { [CmdletBinding()] param($Password) if($script:unlockFails){ throw 'fixture-secret-value' } }
function Set-SecretStoreConfiguration { throw 'Authentication policy must not be changed' }
function Register-SecretVault { throw 'Vault registration must be explicit' }
function Set-Secret {
    [CmdletBinding()] param($Name,$Secret,$Vault)
    if($script:writeFails){ throw 'fixture-secret-value' }
    $script:stored += [pscustomobject]@{Name=$Name;Secret=$Secret;Vault=$Vault}
}
$secure=ConvertTo-SecureString 'fixture-secret-value' -AsPlainText -Force
$credential=[pscredential]::new('fixture-user',$secure)
$null=Set-StoredSecret -Secret $secure -SecretName preview -WhatIf
Assert ($script:installed.Count -eq 0 -and $script:stored.Count -eq 0) 'WhatIf installed or wrote'
foreach($secret in @($secure,$credential,'fixture-secret-value',[byte[]]@(1,2),@{Key=$secure})) {
    $result=Set-StoredSecret -Secret $secret -SecretName fixture -SecurePassword $secure
    Assert ($result -eq 'fixture' -and [object]::ReferenceEquals($script:stored[-1].Secret,$secret)) 'Secret type/reference was changed'
}
Assert ($script:installed -contains 'Microsoft.PowerShell.SecretManagement') 'Automatic dependency install missing'
$script:unlockFails=$true
$count=$script:stored.Count
try { Set-StoredSecret -Secret $secure -SecretName fixture -SecurePassword $secure; throw 'Expected unlock failure' }
catch { Assert ($_.Exception.Message -match 'unlock failed' -and $_.Exception.Message -notmatch 'fixture-secret-value') 'Unlock failure was not safely propagated' }
Assert ($script:stored.Count -eq $count) 'Stored after failed unlock'
$script:unlockFails=$false; $script:writeFails=$true
try { Set-StoredSecret -Secret $secure -SecretName fixture; throw 'Expected storage failure' }
catch { Assert ($_.Exception.Message -match 'could not be stored' -and $_.Exception.Message -notmatch 'fixture-secret-value') 'Storage error exposed a secret' }
$script:writeFails=$false; $script:vaults=@()
try { Set-StoredSecret -Secret $secure -SecretName fixture; throw 'Expected missing vault failure' }
catch { Assert ($_.Exception.Message -match 'explicitly register') 'Missing vault was silently created' }
$script:vaults=@([pscustomobject]@{Name='custom';ModuleName='Custom';IsDefault=$true})
$null=Set-StoredSecret -Secret $credential -SecretName custom -Vault custom
Assert ($script:stored[-1].Vault -eq 'custom') 'Explicit custom vault ignored'
Write-Host 'PASS: types preserved, CurrentUser automatic install, WhatIf, locked/missing/custom vaults, redacted errors and unchanged policy.'
