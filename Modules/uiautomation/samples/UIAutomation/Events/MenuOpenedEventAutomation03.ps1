####################################################################################################
# Script name: MenuOpenedEventAutomation03.ps1
# Description: demonstrates how to wait for an event being raised
# Copyright:   http://SoftwareTestingUsingPowerShell.com, 2012
####################################################################################################

Set-StrictMode -Version Latest;
Import-Module $global:uiautomationModule;

Start-Process calc -Passthru | `
   Get-UIAWindow | `
   Register-UIAMenuOpenedEvent `
   -EventAction { `
     param($src,$e)
  [System.Windows.Forms.MessageBox]::show("menu opened: Name='" + $src.Cached.Name + "'; AutomationId='" + $src.Cached.AutomatioId + "'"); };
(Wait-UIAEventRaised -Name View).Cached;

