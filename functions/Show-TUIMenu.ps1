
<#
  .SYNOPSIS
      Displays a GUI menu with the provided menu items and handles user selection.

  .DESCRIPTION
      The Show-TUIMenu function initializes a terminal-based GUI application that displays a list of menu items. When a user selects a menu item, the associated action of that menu item is executed.

  .PARAMETER MenuItems
      An array of MenuItem objects that represent the menu items to be displayed. Each MenuItem object must have a Name and an Action.

  .EXAMPLE
      $menuItem1 = [MenuItem]::new('Authenticate', { Start-AZCloudAuthentication })
      $menuItem2 = [MenuItem]::new('Retrieve Files', { Get-RemoteFileList })
      $menuItem3 = [MenuItem]::new('Download Files', { Invoke-FileDownload })
      $menuItem4 = [MenuItem]::new('Exit', { [Terminal.Gui.Application]::RequestStop(); [Terminal.Gui.Application]::Shutdown(); exit })
      Show-TUIMenu -MenuItems @($menuItem1, $menuItem2, $menuItem3, $menuItem4)

      This example creates four menu items for various actions and displays them in a GUI menu. When the user selects an option, the corresponding action is executed.

  .INPUTS
      None. You cannot pipe objects to Show-TUIMenu.

  .OUTPUTS
      None. Show-TUIMenu does not generate any output.

  .NOTES
      This function requires the Microsoft.PowerShell.ConsoleGuiTools module to be installed as it utilizes the Terminal.Gui library.

  .COMPONENT
      GUI

  .ROLE
      User Interface

  #>
function Show-TUIMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MenuItem[]]$MenuItems
    )
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
            & $this.Action
        }
    }
    # Initialize Terminal.Gui
    $module = (Get-Module Microsoft.PowerShell.ConsoleGuiTools -List).ModuleBase
    Add-Type -Path (Join-Path $module 'Terminal.Gui.dll')
    [Terminal.Gui.Application]::Init()

    # Define the color scheme for the ListView
    $listViewColorScheme = [Terminal.Gui.ColorScheme]::new()
    $listViewColorScheme.Normal = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::Black, [Terminal.Gui.Color]::Gray)
    $listViewColorScheme.Focus = [Terminal.Gui.Attribute]::Make([Terminal.Gui.Color]::White, [Terminal.Gui.Color]::DarkGray)

    # Get the width and height of the terminal
    $terminalWidth = [Terminal.Gui.Application]::Current.Bounds.Width
    $terminalHeight = [Terminal.Gui.Application]::Current.Bounds.Height

    # Center the text in the menu
    $centeredMessages = $MenuItems.Name | ForEach-Object {
        $startPos = ($terminalWidth - $_.Length) / 2
        if ($startPos -lt 0) {
            $startPos = 0
        }
        ' ' * $startPos + $_
    }

    # Calculate the number of lines to add before the menu
    $linesBefore = [math]::Round(($terminalHeight - $centeredMessages.Count) / 2)
    if ($linesBefore -lt 0) {
        $linesBefore = 0
    }

    # Create window
    $window = [Terminal.Gui.Window]::new()
    $window.Title = 'rclone Menu'

    # Use the centered messages for the ListView
    $listview = [Terminal.Gui.ListView]::new($centeredMessages)
    $listview.AllowsMarking = $false
    $listview.X = 1
    $listview.Y = 1
    $listview.Width = $terminalWidth - 2
    $listview.Height = [math]::Min($terminalHeight, $centeredMessages.Count)

    $listview.Add_OpenSelectedItem({
            param([Terminal.Gui.ListViewItemEventArgs]$_event)
            # Find the selected MenuItem and invoke its action
            $selectedMenuItem = $MenuItems[$_event.Item]
            $selectedMenuItem.Invoke()
        })

    # Add the ListView to the window
    $window.Add($listview)

    # Add the window to the top-level views
    [Terminal.Gui.Application]::Top.Add($window)

    # Start the GUI application
    [Terminal.Gui.Application]::Run()
    # Clean up after the GUI has closed
    [Terminal.Gui.Application]::Shutdown()
}