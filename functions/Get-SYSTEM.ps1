function Get-SYSTEM {
  [CmdletBinding()]
  param (
    [Parameter(Position = 0)]
    [ValidateNotNull()]
    [string]$PowerShellArgs = '-NoExit',

    [Parameter(Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$PowerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  )

  <#
  .SYNOPSIS
    Starts a new PowerShell process with SYSTEM privileges.

  .DESCRIPTION
    This function launches a new PowerShell instance running with SYSTEM level privileges
    using the NtObjectManager module.

  .PARAMETER PowerShellArgs
    Arguments to pass to the PowerShell process. Default is "-NoExit" which keeps the window open.

  .PARAMETER PowerShellPath
    Full path to the PowerShell executable. Defaults to the system PowerShell path.

  .EXAMPLE
    Get-SYSTEM
    # Starts a new PowerShell window running as SYSTEM

  .EXAMPLE
    Get-SYSTEM -PowerShellArgs "-NoProfile -Command Get-Process"
    # Runs a specific command as SYSTEM

  .NOTES
    Requires administrative privileges and the NtObjectManager module.
  #>

  begin {
    # Check if running as administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
      # Restart as administrator
      Write-Verbose 'Not running as administrator. Restarting with elevated privileges...'
      $arguments = "& {Start-Process PowerShell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"' -Verb RunAs}"
      Start-Process PowerShell -ArgumentList $arguments -Verb RunAs
      return
    }

    # Check if NtObjectManager module is installed, install if not
    if (-not (Get-Module -ListAvailable -Name NtObjectManager)) {
      try {
        Write-Verbose 'NtObjectManager module not found. Installing...'
        Install-Module -Name NtObjectManager -Force -Scope CurrentUser -ErrorAction Stop
      }
      catch {
        throw "Failed to install NtObjectManager module: $_"
      }
    }

    # Import the module
    try {
      Import-Module NtObjectManager -ErrorAction Stop
    }
    catch {
      throw "Failed to import NtObjectManager module: $_"
    }
  }

  process {

    $systemToken = $null
    try {
      # Get a SYSTEM token
      Write-Verbose 'Acquiring SYSTEM token...'
      $systemToken = Get-NtToken -Service System -WithTcb

      # Create a new process with the SYSTEM token
      $config = New-Object NtCoreLib.Win32.Process.Win32ProcessConfig
      $config.ApplicationName = $PowerShellPath
      $config.CommandLine = "$(Split-Path $PowerShellPath -Leaf) $PowerShellArgs"
      $config.Token = $systemToken

      # Create the process
      Write-Verbose 'Creating process as SYSTEM...'
      $process = $config.Create()

      # Return process information
      Write-Verbose "Process created with PID: $($process.Id)"
      return $process
    }
    catch {
      throw "Failed to create SYSTEM process: $_"
    }
    finally {
      # Dispose the token when done
      if ($null -ne $systemToken) {
        $systemToken.Dispose()
        Write-Verbose 'SYSTEM token disposed'
      }
    }

  }
}