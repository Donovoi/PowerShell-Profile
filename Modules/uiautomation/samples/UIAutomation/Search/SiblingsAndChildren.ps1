Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton -Name 1 | Get-UIAControlNextSibling | Read-UIAControlName;
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton -Name 1 | Get-UIAControlNextSibling | Get-UIAControlNextSibling | Read-UIAControlName;
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton -Name 1 | Get-UIAControlNextSibling | Get-UIAControlPreviousSibling | Read-UIAControlName;
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton -Name 1 | Get-UIAControlPreviousSibling | Read-UIAControlName;

Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton -Name 1 | Get-UIAControlParent | Get-UIAControlFirstChild | Read-UIAControlName;
Start-Process calc -Passthru | Get-UIAWindow | Get-UIAButton -Name 1 | Get-UIAControlParent | Get-UIAControlLastChild | Read-UIAControlName;

