Import-Module C:\Projects\PS\STUPS\UIA\UIAutomation\bin\Release35\UIAutomation.dll

Start-Process calc -Passthru | Get-UIAWindow | Test-UIAControlState -SearchCriteria @{ controlType = "button"; Name = "3" }
Stop-Process -Name calc

Start-Process calc -Passthru | Get-UIAWindow | Get-UIAMenuItem help | Invoke-UIAMenuItemExpand | Get-UIAMenuItem -Name *about* | Invoke-UIAMenuItemClick;
Get-UIAWindow -pn calc -WithControl @{ controlType = "button"; Name = "9" }
Get-UIAWindow -pn calc -WithControl @{ controlType = "button"; Name = "OK" }
Stop-Process -Name calc


