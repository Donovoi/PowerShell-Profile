# this is deprecated since 0.8.0

Import-Module $global:uiautomationModule;
Import-Module $global:tmxModule;

[UIAutomation.Mode]::Profile = [UIAutomation.Modes]::Presentation;
Clear-Host;

# here we are searching for all the element whose names start with 'a'
Start-Process calc -Passthru | Get-UIAWindow | Search-UIAControl -Name A*;

# here we get only button(s)
Start-Process calc -Passthru | Get-UIAWindow | Search-UIAControl -ControlType button -Name A*;

# this code should return the same as the first code snippet, 
# because there are only two types of controls whose names start with 'a'
Start-Process calc -Passthru | Get-UIAWindow | Search-UIAControl -ControlType button,menubar -Name A*;
