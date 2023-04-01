####################################################################################################
# Script name: MenuClosedOpenedEvents.ps1
# Description: demonstrates how to work with MenuOpenedEvent and MenuClosedEvent
# Copyright:   http://SoftwareTestingUsingPowerShell.com, 2012
####################################################################################################

Set-StrictMode -Version Latest;
Import-Module $global:uiautomationModule;

[string]$appName = "calc";
Start-Process $appName -Passthru | `
   Get-UIAWindow | `
   Register-UIAMenuClosedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "calc menu closed: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); };
[UIAutomation.CurrentData]::CurrentWindow | `
   Register-UIAMenuOpenedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "calc menu opened: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); }

$appName = "notepad";
Start-Process $appName -Passthru | `
   Get-UIAWindow | `
   Register-UIAMenuClosedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "notepad menu closed: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); };
[UIAutomation.CurrentData]::CurrentWindow | `
   Register-UIAMenuOpenedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "notepad menu opened: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); }

$appName = "SharpDevelop";
Get-UIAWindow -pn $appName | `
   Register-UIAMenuClosedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "SharpDevelop menu closed: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); };
[UIAutomation.CurrentData]::CurrentWindow | `
   Register-UIAMenuOpenedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "SharpDevelop menu opened: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); }

$appName = "TEMP";
Start-Process explorer -ArgumentList $Env:TEMP | `
   Get-UIAWindow | `
   Register-UIAMenuClosedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "TEMP menu closed: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); };
[UIAutomation.CurrentData]::CurrentWindow | `
   Register-UIAMenuOpenedEvent `
   -EventAction { param($src,$e)
  [System.Windows.Forms.MessageBox]::show(`
       "TEMP menu opened: Current:" + `
       $src.Current.Name + " " + `
       $src.Current.AutomationId + " Cached:" + `
       $src.Cached.Name + " " + `
       $src.Cached.AutomationId + " " + `
       $e.EventId); }


