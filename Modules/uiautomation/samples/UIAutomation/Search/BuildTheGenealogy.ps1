# this is deprecated since 0.8.0

Import-Module $global:uiautomationModule;
Import-Module $global:tmxModule;

[UIAutomation.Mode]::Profile = [UIAutomation.Modes]::Presentation;
Clear-Host;

# here we are searching for all the element whose names start with 'a'
Start-Process calc -Passthru | Get-UIAWindow | Search-UIAControl -Name A* | `
   ForEach-Object { Write-Host "===========================================================";
  Write-Host "@{Name='$($_.Current.Name)'; AutomaitonId='$($_.Current.AutomaitonId); ControlType='$($_.Current.ControlType.ProgrammaticName)'}"; $_ | Get-UIAControlAncestors | `
     ForEach-Object { Write-Host "@{Name='$($_.Current.Name)'; AutomaitonId='$($_.Current.AutomaitonId); ControlType='$($_.Current.ControlType.ProgrammaticName)'}"; } };
