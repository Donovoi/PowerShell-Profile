<#
.SYNOPSIS
    Refreshes environment variables in the current PowerShell session from the Windows registry.

.DESCRIPTION
    The Update-SessionEnvironment function (also aliased as 'refreshenv') refreshes all environment
    variables in the current PowerShell session by reading values from the Windows registry.
    
    This is particularly useful after:
    - Installing new software that modifies PATH or other environment variables
    - Making changes to environment variables via System Properties
    - Installing PowerShell modules that add to PSModulePath
    - Running installers that update system configuration
    
    The function:
    - Reads environment variables from Machine and User registry scopes
    - Merges PATH entries from both scopes (removing duplicates)
    - Updates all environment variables in the current session
    - Preserves PSModulePath, USERNAME, and PROCESSOR_ARCHITECTURE
    - Handles both interactive 'refreshenv' calls and programmatic usage
    
    Unlike starting a new PowerShell session, this updates the current session immediately.

.EXAMPLE
    Update-SessionEnvironment
    
    Refreshes all environment variables from the registry into the current session.

.EXAMPLE
    refreshenv
    
    If invoked with the alias 'refreshenv', displays a message with progress.
    This matches Chocolatey's refreshenv command behavior.

.EXAMPLE
    Install-Package SomeApp
    Update-SessionEnvironment
    SomeApp.exe --version
    
    After installing software that adds to PATH, refresh environment so the new executable is available.

.EXAMPLE
    [Environment]::SetEnvironmentVariable('MY_VAR', 'NewValue', 'User')
    Update-SessionEnvironment
    $env:MY_VAR  # Now shows 'NewValue'
    
    After changing an environment variable programmatically, refresh to see the change in current session.

.OUTPUTS
    None. Environment variables in the current session are updated in-place.
    Verbose messages are written via Write-Logg.

.NOTES
    - Also works when invoked as 'refreshenv' (checks $MyInvocation.InvocationName)
    - Reads from registry scopes: Process, Machine, and User (if not SYSTEM account)
    - PATH is specially handled: merged from Machine and User, deduplicated
    - Preserves PSModulePath, USERNAME, and PROCESSOR_ARCHITECTURE from before refresh
    - Does NOT require Administrator privileges (reads registry, doesn't write)
    - Requires Write-Logg, Write-InformationColored, Get-EnvironmentVariable, Get-EnvironmentVariableNames cmdlets
    - User scope is skipped when running as SYSTEM or COMPUTER$ account
    - Order matters: Process, then Machine, then User (User variables override Machine variables)
#>
function Update-SessionEnvironment {
    [OutputType([void])]
    # Load shared dependency loader if not already available
    if (-not (Get-Command -Name 'Initialize-CmdletDependencies' -ErrorAction SilentlyContinue)) {
        $initScript = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path $initScript) {
            . $initScript
        }
        else {
            Write-Warning "Initialize-CmdletDependencies.ps1 not found in $PSScriptRoot"
            Write-Warning 'Falling back to direct download'
            $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/cmdlets/Initialize-CmdletDependencies.ps1'
            $scriptBlock = [scriptblock]::Create($method)
            . $scriptBlock
        }
    }
    
    # (1) Import required cmdlets if missing
    # Load all required cmdlets (replaces 40+ lines of boilerplate)
    Initialize-CmdletDependencies -RequiredCmdlets @(
        'Write-Logg',
        'Write-InformationColored',
        'Get-EnvironmentVariable',
        'Get-EnvironmentVariableNames'
    ) -PreferLocal -Force
    $refreshEnv = $false
    $invocation = $MyInvocation

    if ($invocation.InvocationName -eq 'refreshenv') {
        $refreshEnv = $true
    }

    if ($refreshEnv) {
        Write-Logg -Message 'Refreshing environment variables from the registry for powershell.exe. Please wait...'
    }
    else {
        Write-Verbose 'Refreshing environment variables from the registry.'
    }

    $userName = $env:USERNAME
    $architecture = $env:PROCESSOR_ARCHITECTURE
    $psModulePath = $env:PSModulePath

    # ordering is important, user should override machine...
    $ScopeList = 'Process', 'Machine'
    if ('SYSTEM', "${env:COMPUTERNAME}`$" -notcontains $userName) {
        $ScopeList += 'User'
    }
    foreach ($Scope in $ScopeList) {
        Get-EnvironmentVariableNames -Scope $Scope |
            ForEach-Object {
                Set-Item "Env:$_" -Value (Get-EnvironmentVariable -Scope $Scope -Name $_)
            }
    }

    # unify PATH
    $paths = 'Machine', 'User' | ForEach-Object {
        (Get-EnvironmentVariable -Name 'PATH' -Scope $_) -split ';'
    } | Select-Object -Unique

    $Env:PATH = $paths -join ';'

    # preserve the PSModulePath
    $env:PSModulePath = $psModulePath

    # reset user and architecture
    if ($userName) {
        $env:USERNAME = $userName
    }
    if ($architecture) {
        $env:PROCESSOR_ARCHITECTURE = $architecture
    }

    if ($refreshEnv) {
        Write-Logg -Message 'Finished' -Level VERBOSE
    }
}