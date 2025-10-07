<#
.SYNOPSIS
    Retrieves the value of an environment variable from a specified scope.

.DESCRIPTION
    Gets the value of an environment variable from User, Machine, or Process scope.
    Supports variable expansion (preserving or expanding embedded variables like %PATH%).
    Provides direct registry access for User and Machine scopes for reliability.

.PARAMETER Name
    The name of the environment variable to retrieve (e.g., 'PATH', 'TEMP', 'USERNAME').

.PARAMETER Scope
    The scope from which to retrieve the environment variable.
    Valid values:
    - User: Current user environment variables
    - Machine: System-wide environment variables
    - Process: Current process environment variables

.PARAMETER PreserveVariables
    If specified, returns the raw variable value without expanding embedded variables.
    For example, if PATH contains '%SystemRoot%\System32', with PreserveVariables it returns
    the literal string, without it returns 'C:\Windows\System32'.
    Default is $false (variables are expanded).

.PARAMETER ignoredArguments
    Allows splatting with additional parameters that will be ignored.

.EXAMPLE
    Get-EnvironmentVariable -Name 'PATH' -Scope User
    
    Returns the PATH environment variable for the current user.

.EXAMPLE
    Get-EnvironmentVariable -Name 'TEMP' -Scope Process
    
    Returns the TEMP directory for the current process.

.EXAMPLE
    Get-EnvironmentVariable -Name 'PSModulePath' -Scope Machine
    
    Returns the system-wide PowerShell module path.

.EXAMPLE
    Get-EnvironmentVariable -Name 'PATH' -Scope User -PreserveVariables
    
    Returns the raw PATH value without expanding variables like %SystemRoot%.

.OUTPUTS
    System.String
    
    The value of the environment variable, or empty string if not found.

.NOTES
    Machine scope requires administrator privileges for write access.
    Uses direct registry access for User and Machine scopes.
    Registry keys:
    - User: HKCU:\Environment
    - Machine: HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment
#>
function Get-EnvironmentVariable {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [System.EnvironmentVariableTarget] $Scope,

        [Parameter(Mandatory = $false)]
        [switch] $PreserveVariables = $false,

        [parameter(ValueFromRemainingArguments = $true)]
        [Object[]] $ignoredArguments
    )

    [string] $MACHINE_ENVIRONMENT_REGISTRY_KEY_NAME = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment\'
    [Microsoft.Win32.RegistryKey] $win32RegistryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($MACHINE_ENVIRONMENT_REGISTRY_KEY_NAME)
    if ($Scope -eq [System.EnvironmentVariableTarget]::User) {
        [string] $USER_ENVIRONMENT_REGISTRY_KEY_NAME = 'Environment'
        [Microsoft.Win32.RegistryKey] $win32RegistryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($USER_ENVIRONMENT_REGISTRY_KEY_NAME)
    }
    elseif ($Scope -eq [System.EnvironmentVariableTarget]::Process) {
        return [Environment]::GetEnvironmentVariable($Name, $Scope)
    }

    [Microsoft.Win32.RegistryValueOptions] $registryValueOptions = [Microsoft.Win32.RegistryValueOptions]::None
    if ($PreserveVariables) {
        Write-Verbose 'Choosing not to expand environment names'
        $registryValueOptions = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    }

    [string] $environmentVariableValue = [string]::Empty

    try {
        if ($null -ne $win32RegistryKey) {
            $environmentVariableValue = $win32RegistryKey.GetValue($Name, [string]::Empty, $registryValueOptions)
        }
    }
    catch {
        Write-Debug "Unable to retrieve the $Name environment variable. Details: $_"
    }
    finally {
        if ($null -ne $win32RegistryKey) {
            $win32RegistryKey.Close()
        }
    }

    if ($null -eq $environmentVariableValue -or $environmentVariableValue -eq '') {
        $environmentVariableValue = [Environment]::GetEnvironmentVariable($Name, $Scope)
    }

    return $environmentVariableValue
}