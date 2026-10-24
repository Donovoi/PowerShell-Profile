# Tests the actual guest token-inspection helper against only this test process.
# No target activation, impersonation, privilege changes, or VM operations occur.
#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$runner=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestRunner.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) 'Guest runner parse failed.'
$native=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class ProfileAnalysisGuestJob')},$true))
Assert-True ($native.Count -eq 1) 'Exact native guest source was not found.'
$nativeSource=$native[0].Value
$start=$nativeSource.IndexOf(' public sealed class ProcessIdentityInspection ')
$end=$nativeSource.IndexOf(' [ComImport,',$start)
Assert-True ($start -ge 0 -and $end -gt $start) 'Actual identity-helper boundary changed.'
$helper=$nativeSource.Substring($start,$end-$start)
$openToken=@($nativeSource -split '\r?\n'|Where-Object {$_ -match '^ \[DllImport\("advapi32.dll",SetLastError=true\)\] static extern bool OpenProcessToken\('})
$closeHandle=@($nativeSource -split '\r?\n'|Where-Object {$_ -match '^ \[DllImport\("kernel32.dll"[^\]]*\)\] static extern bool CloseHandle\('})
Assert-True ($openToken.Count -eq 1 -and $closeHandle.Count -eq 1) 'Exact handle API declarations were not found.'
Assert-True ($helper -notmatch 'AdjustTokenPrivileges|SetThreadToken|Impersonate|LogonUser|ActivateApplication|CreateProcess') 'Identity helper unexpectedly includes a mutating or target API.'
$source='using System;using System.ComponentModel;using System.Runtime.InteropServices;public static class ProfileAnalysisTokenInspectionFixture {'+$openToken[0]+"`n"+$closeHandle[0]+"`n"+$helper+'}'
Add-Type -TypeDefinition $source -Language CSharp
Assert-True ([ProfileAnalysisTokenInspectionFixture]::ProcessIdentityTokenAccess -eq 10) 'Token rights are not exactly QUERY plus DUPLICATE.'

$before=[Security.Principal.WindowsIdentity]::GetCurrent()
try{
    $expectedSid=$before.User.Value
    $expectedAdministrator=([Security.Principal.WindowsPrincipal]::new($before)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $expectedGroup=@($before.Groups|Where-Object Value -eq 'S-1-5-32-544').Count -ne 0
    # -1 is GetCurrentProcess's pseudo-handle; no other process can be selected.
    $inspection=[ProfileAnalysisTokenInspectionFixture]::InspectProcessIdentity([IntPtr](-1))
    Assert-True ($inspection.Sid -ceq $expectedSid -and $inspection.Administrator -eq $expectedAdministrator -and $inspection.AdministratorGroupMember -eq $expectedGroup) 'Actual current-process token inspection disagrees with the current identity.'
    $after=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{
        Assert-True ($after.User.Value -ceq $expectedSid -and $after.ImpersonationLevel -eq $before.ImpersonationLevel -and ([Security.Principal.WindowsPrincipal]::new($after)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -eq $expectedAdministrator) 'Inspection changed identity, impersonation state or administrator status.'
    }finally{$after.Dispose()}
}finally{$before.Dispose()}

$failure=$null
try{$null=[ProfileAnalysisTokenInspectionFixture]::InspectProcessIdentity([IntPtr]::Zero)}catch{$failure=$_.Exception.GetBaseException()}
Assert-True ($failure -is [ComponentModel.Win32Exception] -and $failure.NativeErrorCode -ne 0 -and $failure.Data['Operation'] -ceq 'OpenProcessToken(QUERY|DUPLICATE)') 'Token-open failure lost its original native error or fixed operation label.'
Assert-True ($nativeSource.Contains('ProcessIdentityInspection inspectedIdentity=InspectProcessIdentity(root);') -and $nativeSource.Contains('if(result.RootUserSid!=expectedSid || result.RootAdministrator)throw') -and $nativeSource.Contains('if(inspectedIdentity.AdministratorGroupMember)throw')) 'Registered execution does not retain its standard-user identity gates.'
$compiledFull=$false
if($PSVersionTable.PSVersion.Major -eq 5){Add-Type -TypeDefinition $nativeSource -Language CSharp -ReferencedAssemblies System.Drawing,System.Core;$compiledFull=$true}
[pscustomobject]@{Status='Passed';PowerShell=$PSVersionTable.PSVersion.ToString();ActualHelperCompiled=$true;FullNativeSourceCompiled=$compiledFull;OnlyCurrentProcessInspected=$true;IdentityUnchanged=$true;NoImpersonationOrElevation=$true;InvalidHandleDiagnosticPreserved=$true;TargetActivation=$false;VmOperations=$false}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $TestRoot 'result.json') -Encoding utf8
Write-Output 'PASS: actual guest helper queries only this process with QUERY|DUPLICATE, matches its current identity, preserves native diagnostics, and leaves identity/administrator state unchanged.'
