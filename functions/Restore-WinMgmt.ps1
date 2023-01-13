function Restore-WinMgmt {
    [CmdletBinding()]
    param (
		
    )
    if (-not (get-disk)) {
        sc config winmgmt start= disabled
        net stop winmgmt
        Winmgmt /salvagerepository %windir%\System32\wbem
        Winmgmt /resetrepository %windir%\
        sc config winmgmt start= auto
    }
}