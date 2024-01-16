function Update-PSProfile {
  [CmdletBinding()]
  param(
    $parentpathprofile = $(Get-Item $PROFILE).Directory.FullName
  )
  Start-AsAdmin
  Write-Logg -Message "Script is running as $($MyInvocation.MyCommand.Name)" -Level INFO
IEX (iwr https://gist.githubusercontent.com/Donovoi/5fd319a97c37f987a5bcb8362fe8b7c5/raw)
    # Get the current PowerShell process ID
    $currentProcessId = $PID

    # Start a new elevated instance of wt.exe
    $windowsterminallocation = if (-not(Test-Path -Path "$ENV:USERPROFILE\AppData\Local\Microsoft\WindowsApps\wt.exe")) {
      $(Resolve-Path -Path "C:\Program Files\WindowsApps\Microsoft.WindowsTerminalPreview*\wt.exe").Path
    }
    else {
      "$ENV:USERPROFILE\AppData\Local\Microsoft\WindowsApps\wt.exe"
    }
    Start-Process -FilePath $windowsterminallocation -Verb RunAs
}
