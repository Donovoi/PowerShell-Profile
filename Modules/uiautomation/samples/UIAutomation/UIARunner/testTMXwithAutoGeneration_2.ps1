Import-Module C:\Projects\PS\UIAutomation.Old\UIAutomationSpy\bin\Release35\TMX.dll
Import-Module C:\Projects\PS\UIAutomation.Old\UIAutomationSpy\bin\Release35\UIAutomation.dll
[UIAutomation.Preferences]::EveryCmdletAsTestResult = $true
[UIAutomation.Preferences]::OnSuccessDelay = 0;
Start-Process calc -Passthru | Get-UIAWindow -Verbose | Get-UIAButton -Name 1 -Verbose | Invoke-UIAButtonClick;
Search-TMXTestResult

