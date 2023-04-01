Import-Module C:\Projects\PS\STUPS\UIA\UIAutomation\bin\Release35\UIAutomation.dll;
Import-Module C:\Projects\PS\STUPS\TMX\TMX\bin\Release35\TMX.dll;

[TMX.Logger]::LogPath = "C:\1\logger_test.txt";
[UIAutomation.Preferences]::AutoLog = $true;

Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton 1 | Invoke-UIAButtonClick;

Start-Process calc -Passthru | Get-UIAWindow -Verbose | Get-UIAButton 1 -Verbose | Invoke-UIAButtonClick -Verbose;

& C:\Projects\PS\STUPS\samples\UIAutomation\Wizard\AddPrinterManually.ps1

