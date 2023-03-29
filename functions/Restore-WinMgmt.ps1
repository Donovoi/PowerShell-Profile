function Restore-WinMgmt {
  [CmdletBinding()]
  param(

  )
  if (-not (Get-Disk)) {
    Set-Content config winmgmt start= disabled
    net stop winmgmt
    Winmgmt /salvagerepository %windir%\System32\wbem
    Winmgmt /resetrepository %windir%\
    Set-Content config Winmgmt start= auto
  }
}
