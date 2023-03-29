####################################################################################################
# Script name: WindowOpenedEvent.ps1
# Description: demonstrates how to work with WindowOpenedEvent
# Copyright:   http://SoftwareTestingUsingPowerShell.com, 2012
####################################################################################################

Set-StrictMode -Version Latest;
Import-Module $global:uiautomationModule;

[string]$appName = "services.msc";

# you need to run a PowerShell console as Administrator

Start-Process $appName -Passthru | `
   Get-UIAWindow | `
   Register-UIAWindowOpenedEvent -EventAction { param($src,$e) [System.Windows.Forms.MessageBox]::show("A new window is open: $($src.Cached.Name)"); };
Get-UIAMenuItem -Name File | `
   Invoke-UIAMenuItemClick | `
   Get-UIAMenuItem -Name Opt* | `
   Invoke-UIAMenuItemClick;

