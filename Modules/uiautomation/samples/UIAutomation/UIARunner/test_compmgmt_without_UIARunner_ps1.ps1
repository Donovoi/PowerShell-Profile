Import-Module .\UIAutomation.dll;
Import-Module .\TMX.dll;

Start-Process compmgmt.msc -Passthru | Get-UIAWindow | Get-UIATree | Get-UIATreeItem -n 'Shared Folders' | Invoke-UIATreeItemExpand | Get-UIATreeItem -n Shares | Invoke-UIAControlClick;

