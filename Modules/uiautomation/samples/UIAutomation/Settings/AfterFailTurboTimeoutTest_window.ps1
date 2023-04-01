Import-Module C:\Projects\PS\STUPS\UIAutomationSpy\bin\Release35\UIAutomation.dll
Start-Process calc -Passthru | Get-UIAWindow;
[UIAutomation.Preferences]::Timeout
[UIAutomation.Preferences]::AfterFailTurboTimeout
Get-UIAWindow -Name calc1
[UIAutomation.Preferences]::Timeout
[UIAutomation.Preferences]::AfterFailTurboTimeout
Get-UIAWindow -Name calc*
[UIAutomation.Preferences]::Timeout
[UIAutomation.Preferences]::AfterFailTurboTimeout


