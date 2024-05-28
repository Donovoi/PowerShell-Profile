function Update-USBTools {
  [CmdletBinding()]
  param (
    
  )

  $neededcmdlets = @('Write-Logg', 'Get-Properties', 'Show-TUIMenu', 'Update-DotNetSDK', 'Update-VisualStudio', 'Get-KapeAndTools', 'Get-GitPull', 'Update-PowerShell', 'Get-LatestSIV', 'Update-VScode', 'Update-VcRedist')
  $neededcmdlets | ForEach-Object {
    if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
      if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
        $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
        $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
        New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
      }
      Write-Verbose -Message "Importing cmdlet: $_"
      $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
      $Cmdletstoinvoke | Import-Module -Force
    }
  }

  #  define the menuitem class
  <#
.SYNOPSIS
    Represents a menu item with a display name and an associated action.

.DESCRIPTION
    The MenuItem class is used to create menu items for the terminal GUI. Each menu item has a name that is displayed in the GUI and an action that is a script block, which gets executed when the menu item is selected.

.PARAMETER Name
    The display name of the menu item.

.PARAMETER Action
    The script block that contains the action to be executed when this menu item is selected.

.EXAMPLE
    $menuItem = [MenuItem]::new('Option 1', { Write-Host 'You selected option 1' })

    This creates a new menu item with the display name 'Option 1' and an action that writes a message to the host when invoked.

.NOTES
    This class is intended to be used with the Show-TUIMenu function which handles the GUI representation and interaction.
#>

  class MenuItem {
    [string]$Name
    [scriptblock]$Action

    MenuItem([string]$Name, [scriptblock]$Action) {
      $this.Name = $Name
      $this.Action = $Action
    }

    [void]Invoke() {
      # foreach action seperated by ; we will execute it in a new window
      $this.Action -split ';' | ForEach-Object {
        Start-Process -FilePath 'pwsh.exe' -ArgumentList "-NoExit -Command $_"
      }
    }
  }
  $menuItem0 = [MenuItem]::new('All', { chocolatey upgrade all --ignore-dependencies; winget install JanDeDobbeleer.OhMyPosh -s winget --force --accept-source-agreements --accept-package-agreements; Update-VisualStudio; Update-VSCode; Get-KapeAndTools; Get-GitPull; Update-PowerShell; Get-LatestSIV; winget source reset --disable-interactivity --force; winget source update --disable-interactivity; winget upgrade --all --include-unknown --wait -h --force --accept-source-agreements --accept-package-agreements; DISM /Online /Cleanup-Image /RestoreHealth; sfc /scannow; Update-DotNetSDK })
  $menuItem1 = [MenuItem]::new('UpgradeChocolatey', { chocolatey upgrade all --ignore-dependencies })
  $menuItem2 = [MenuItem]::new('InstallOhMyPosh', { winget install JanDeDobbeleer.OhMyPosh -s winget --force --accept-source-agreements --accept-package-agreements })
  $menuItem3 = [MenuItem]::new('UpdateVisualStudio', { Update-VisualStudio })
  $menuItem4 = [MenuItem]::new('UpdateVSCode', { Update-VSCode })
  $menuItem5 = [MenuItem]::new('GetKapeAndTools', { Get-KapeAndTools })
  $menuItem6 = [MenuItem]::new('GetGitPull', { Get-GitPull })
  $menuItem7 = [MenuItem]::new('UpdatePowerShell', { Update-PowerShell })
  $menuItem8 = [MenuItem]::new('GetLatestSIV', { Get-LatestSIV })
  $menuItem9 = [MenuItem]::new('ResetWingetSource', { winget source reset --disable-interactivity --force })
  $menuItem10 = [MenuItem]::new('UpdateWingetSource', { winget source update --disable-interactivity })
  $menuItem11 = [MenuItem]::new('UpgradeWinget', { winget upgrade --all --include-unknown --wait -h --force --accept-source-agreements --accept-package-agreements })
  $menuItem12 = [MenuItem]::new('SystemImageCleanup', { DISM /Online /Cleanup-Image /RestoreHealth; sfc /scannow })
  $menuItem13 = [MenuItem]::new('UpdateDotNetSDK', { Update-DotNetSDK })
  $menuItem14 = [MenuItem]::new('Exit', { [Terminal.Gui.Application]::RequestStop(); [Terminal.Gui.Application]::Shutdown(); exit })
  Show-TUIMenu -MenuItems @($menuItem0, $menuItem1, $menuItem2, $menuItem3, $menuItem4, $menuItem5, $menuItem6, $menuItem7, $menuItem8, $menuItem9, $menuItem10, $menuItem11, $menuItem12, $menuItem13, $menuItem14) -ErrorAction break
}