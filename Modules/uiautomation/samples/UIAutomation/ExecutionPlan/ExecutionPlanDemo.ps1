Import-Module C:\Projects\PS\STUPS\UIAutomation\bin\Release35\UIAutomation.dll;
# ipmo [path]\UIAutomation.dll

Show-UIAExecutionPlan -Max 100;
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton; Get-UIAMenuItem;

