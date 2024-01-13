function Restore-WinMgmt {
  [CmdletBinding()]
  param(
    [switch]$Force
  )
  #requires -RunAsAdministrator
  if ((-not (Get-Disk -ErrorAction SilentlyContinue)) -or ($Force -eq $true)) {
    # all commands below must be run in cmd as admin
    $commands = @(
      'sc config winmgmt start= disabled',
      'net stop winmgmt',
      'Winmgmt /salvagerepository %windir%\System32\wbem',
      'Winmgmt /resetrepository %windir%',
      'sc config winmgmt start= auto'
    )

    # Execute each command using cmd.exe /c
    foreach ($command in $commands) {
      Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $command" -NoNewWindow -Wait
    }

    Write-Output 'WinMgmt has been restored.'
  }
  Write-Warning 'WinMgmt is running correctly And -Force has not been used. Nothing to do.'
}

