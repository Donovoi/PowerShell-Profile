Import-Module C:\Projects\ps\STUPS\UIA\UIAutomation\bin\Release35\UIAutomation.dll
[UIAutomation.Preferences]::AutoLog

[UIAutomation.Preferences]::AutoLog = $true
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton -n [1-3] | Invoke-UIAButtonClick;



