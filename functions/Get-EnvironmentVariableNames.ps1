<#
.SYNOPSIS
    Retrieves the names of all environment variables in a specified scope.

.DESCRIPTION
    Enumerates all environment variable names from the specified scope (User, Machine, or Process).
    Does not return the values, only the variable names.
    Useful for discovering what environment variables exist before querying their values.

.PARAMETER Scope
    The scope from which to retrieve environment variable names.
    Valid values:
    - 'User': Current user environment variables (HKCU:\Environment)
    - 'Machine': System-wide environment variables (HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment)
    - 'Process': Current process environment variables (Env: drive)

.EXAMPLE
    Get-EnvironmentVariableNames -Scope User
    
    Returns all environment variable names for the current user.

.EXAMPLE
    Get-EnvironmentVariableNames -Scope Machine
    
    Returns all system-wide environment variable names.

.EXAMPLE
    Get-EnvironmentVariableNames -Scope Process
    
    Returns all environment variable names in the current process.

.EXAMPLE
    $userVars = Get-EnvironmentVariableNames -Scope User
    foreach ($var in $userVars) {
        $value = [Environment]::GetEnvironmentVariable($var, 'User')
        Write-Host "$var = $value"
    }
    
    Lists all user environment variables with their values.

.OUTPUTS
    System.String[]
    
    Array of environment variable names.

.NOTES
    Machine scope requires administrator privileges to access.
    User scope accesses HKCU (current user hive).
    Process scope returns all variables currently in the process environment.
#>
function Get-EnvironmentVariableNames([System.EnvironmentVariableTarget] $Scope) {
    [OutputType([string[]])]
    switch ($Scope) {
        'User' {
            Get-Item 'HKCU:\Environment' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Property
        }
        'Machine' {
            Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' | Select-Object -ExpandProperty Property
        }
        'Process' {
            Get-ChildItem Env:\ | Select-Object -ExpandProperty Key
        }
        default {
            throw "Unsupported environment scope: $Scope"
        }
    }
}