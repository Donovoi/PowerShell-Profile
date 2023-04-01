####################################################################################################
# Script name: start.ps1
# Description: initializes the necessary modules: UIAutomationl.dll and TMX.dll
# Copyright:   http://SoftwareTestingUsingPowerShell.com, 2012
####################################################################################################

Set-StrictMode -Version Latest;
Import-Module $global:uiautomationModule;

Start-Process calc -Passthru | Get-UIAWindow | Get-UIAMenuItem -Name Vi* | ConvertTo-UIASearchCriteria
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAMenuItem -Name Vi* | ConvertTo-UIASearchCriteria -Full
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAMenuItem -Name Vi* | ConvertTo-UIASearchCriteria -Include controltype,class
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAMenuItem -Name Vi* | ConvertTo-UIASearchCriteria -Exclude controltype,class

