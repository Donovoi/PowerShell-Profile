function Start-AsAdmin {
  [CmdletBinding()]
  param
  (
    [string]$Filepath = $script:MyInvocation.MyCommand.path,

    [switch]$WindowsPowerShell
  )
  $ErrorActionPreference = 'Continue'
  # Get the ID and security principal of the current user account
  $myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent();
  $myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal ($myWindowsID);

  # Get the security principal for the administrator role
  $adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator;

  # Check to see if we are currently running as an administrator
  if ($myWindowsPrincipal.IsInRole($adminRole)) {
    # We are running as an administrator, so change the title and background colour to indicate this
    $Host.UI.RawUI.WindowTitle = $myInvocation.MyCommand.Definition + "(Elevated)";
    $Host.UI.RawUI.BackgroundColor = "DarkBlue";
    Clear-Host;
  }
  else {
    # We are not running as an administrator, so relaunch as administrator

    # Create a new process object that starts pwsh by default unless the -WindowsPowerShell switch is used
    if ($WindowsPowerShell) {
      $NewProcess = New-Object System.Diagnostics.ProcessStartInfo powershell;
    }
    else {
      $NewProcess = New-Object System.Diagnostics.ProcessStartInfo pwsh;
    }

    # Specify the current script path and name as a parameter with added scope and support for scripts with spaces in it's path
    $newProcess.Arguments = "-File '" + $script:MyInvocation.MyCommand.path + "'"

    # Indicate that the process should be elevated
    $newProcess.Verb = "runas";

    # Start the new process
    [System.Diagnostics.Process]::Start($newProcess);

    # Exit from the current, unelevated, process
    exit;
  }
}

