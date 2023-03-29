Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton -n 1 | Invoke-UIAButtonClick;
Show-UIAExecutionPlan;
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton | Invoke-UIAButtonClick;
