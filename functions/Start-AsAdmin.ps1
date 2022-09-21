function Start-AsAdmin {
    [CmdletBinding()]
    param (
        [Parameter()]
        [switch]
        $WindowsPowerShell
    )
    Import-Module $PSScriptRoot/Get-ParentFunction.ps1
    # Verify Running as Admin
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')
    #if (-not $isAdmin) {
    Write-Output '-- Restarting as Administrator'
    $callingcmdlet =$(Get-ParentFunction -Scope 2).FunctionName
    if ($WindowsPowerShell) {
        Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$callingcmdlet`"" -Verb RunAs -WindowStyle Normal
    } else {
        Start-Process -FilePath pwsh.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    }

    #exit
    #}
}