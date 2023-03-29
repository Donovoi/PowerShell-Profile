
function Start-AsAdmin {
  [CmdletBinding()]
  param(
    [Parameter()]
    [switch]
    $WindowsPowerShell
  )
  $ErrorActionPreference = 'Continue'
  #Get current user context
  $CurrentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
  $StartPowershellVersion = 'pwsh'

  #Check user running the script is member of Administrator Group
  if ($CurrentUser.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host 'Script is already running with Administrator privileges!'
  }
  else {
    if ($windowsPowerShell) {
      $StartPowershellVersion = 'PowerShell.exe'
    }
    #Create a new Elevated process to Start PowerShell
    Start-Process -FilePath $StartPowershellVersion -ArgumentList " -ExecutionPolicy Bypass -noexit $($OriginalCommand)" -Passthru -Verb 'runas' -Verbose

    # Specify the current script path and name as a parameter
    #$ElevatedProcess.Arguments = "& '" + $script:MyInvocation.MyCommand.Path + "'" + "-NoProfile -ExecutionPolicy Bypass -NoExit"

    #Set the Process to elevated
    #$ElevatedProcess.Verb = "runas"

    #Start the new elevated process
    #[System.Diagnostics.Process]::Start($ElevatedProcess)

    #Exit from the current, unelevated, process
    exit

  }
}
