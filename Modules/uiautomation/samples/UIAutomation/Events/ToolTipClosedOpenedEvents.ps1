####################################################################################################
# Script name: ToolTipClosedOpenedEvents.ps1
# Description: demonstrates how to work with ToolTipOpenedEvent and ToolTipClosedEvent
# Copyright:   http://SoftwareTestingUsingPowerShell.com, 2012
####################################################################################################

Set-StrictMode -Version Latest;
Import-Module $global:uiautomationModule;

[string]$appName = "calc";
Start-Process $appName -Passthru | `
   Get-UIAWindow | `
   Register-UIAToolTipClosedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "calc ToolTip closed: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); };
[UIAutomation.CurrentData]::CurrentWindow | `
   Register-UIAToolTipOpenedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "calc ToolTip opened: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); }

$appName = "notepad";
Start-Process $appName -Passthru | `
   Get-UIAWindow | `
   Register-UIAToolTipClosedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "notepad ToolTip closed: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); };
[UIAutomation.CurrentData]::CurrentWindow | `
   Register-UIAToolTipOpenedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "notepad ToolTip opened: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); }

$appName = "SharpDevelop";
Get-UIAWindow -pn $appName | `
   Register-UIAToolTipClosedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "SharpDevelop ToolTip closed: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); };
[UIAutomation.CurrentData]::CurrentWindow | `
   Register-UIAToolTipOpenedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "SharpDevelop ToolTip opened: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); }

$appName = "TEMP";
Start-Process explorer -ArgumentList $Env:TEMP | `
   Get-UIAWindow | `
   Register-UIAToolTipClosedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "TEMP ToolTip closed: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); };
[UIAutomation.CurrentData]::CurrentWindow | `
   Register-UIAToolTipOpenedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "TEMP ToolTip opened: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); }


