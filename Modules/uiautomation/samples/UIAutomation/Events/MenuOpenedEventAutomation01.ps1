####################################################################################################
# Script name: MenuOpenedEventAutomation01.ps1
# Description: demonstrates how to be informed that a menu is opened
# Copyright:   http://SoftwareTestingUsingPowerShell.com, 2012
####################################################################################################

Set-StrictMode -Version Latest;
Import-Module $global:uiautomationModule;

Start-Process calc -Passthru | `
   Get-UIAWindow | `
   Register-UIAMenuOpenedEvent `
   -EventAction { [System.Windows.Forms.MessageBox]::show("menu opened"); };
Get-UIAMenuItem -Name Vi* | Invoke-UIAMenuItemExpand;
