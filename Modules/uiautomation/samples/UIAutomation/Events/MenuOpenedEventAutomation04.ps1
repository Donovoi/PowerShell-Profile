####################################################################################################
# Script name: MenuOpenedEventAutomation03.ps1
# Description: demonstrates how to wait for an event being raised
# Copyright:   http://SoftwareTestingUsingPowerShell.com, 2012
####################################################################################################

Set-StrictMode -Version Latest;
Import-Module $global:uiautomationModule;

Start-Process calc -Passthru | `
   Get-UIAWindow | `
   Register-UIAMenuOpenedEvent -EventAction {; };
(Wait-UIAEventRaised -Name View).Cached;
