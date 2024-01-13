function Restore-WinMgmt {
  [CmdletBinding()]
  param(

  )
  if (-not (Get-Disk -ErrorAction SilentlyContinue)) {
    # all commands below must be run in cmd as admin
    $commands = @'
    sc config winmgmt start= disabled
    net stop winmgmt
    Winmgmt /salvagerepository %windir%\System32\wbem
    Winmgmt /resetrepository %windir%\
    sc config winmgmt start= auto
'@
    $scriptBlock = [scriptblock]::Create($commands)
    Start-Process 'cmd' -ArgumentList '/c', $scriptBlock -Verb RunAs -Wait
  }
  Write-Output 'WinMgmt has been restored.'
}

