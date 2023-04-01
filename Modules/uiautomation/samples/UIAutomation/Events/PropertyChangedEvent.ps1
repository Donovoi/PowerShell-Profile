Set-StrictMode -Version Latest;
Import-Module $global:uiautomationModule;
Import-Module $global:tmxModule;

Start-Process calc -Passthru | `
   Get-UIAWindow | `
   Get-UIAControlDescendants -ControlType Text | `
   ForEach-Object { $_ | Register-UIAPropertyChangedEvent `
     -EventAction `
     { # write to a file
    param($src,$e)
    # report everything
    "sdfsadf" >> "$env:Temp\sample_value_changed_report.txt";
    "'$($src.Current.Name)' has its value changed" >> "$env:Temp\sample_value_changed_report.txt";
    if ($src.Current.Name.Length -eq 0) {
      "===================================" >> "$env:Temp\sample_value_changed_report.txt";
      "Oh, this is what we are waiting for!" >> "$env:Temp\sample_value_changed_report.txt";
      "AutomaitonId = $($src.Current.AutomaitonId)" >> "$env:Temp\sample_value_changed_report.txt";
      "ControlType = $($src.Current.ControlType.ProgrammaticName)" >> "$env:Temp\sample_value_changed_report.txt";
      "ClassName = $($src.Current.ClassName)" >> "$env:Temp\sample_value_changed_report.txt";
      "-----------------------------------" >> "$env:Temp\sample_value_changed_report.txt";
    }
  },
  { # display a message box
    param($src,$e)
    # report only what happened under the menu item hierarchy
    #					if ($src.Current.ControlType.ProgrammaticName -eq 'ControlType.Text') {
    [System.Windows.Forms.MessageBox]::show($src.Current.Name + "`t" + `
         $src.Current.AutomationId + "`r`n" + `
         $e + "`r`n" + `
         $src.Current.controlType.ProgrammaticName);
    #					}
  };
}

