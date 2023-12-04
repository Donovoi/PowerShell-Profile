<#
.SYNOPSIS
This function retrieves a specified textbox from a base automation element.

.DESCRIPTION
The Get-AutomationTextBox function retrieves a specified textbox from a base automation element.
It uses the FlaUI library to interact with the UI Automation framework.

.PARAMETER BaseAutomationElement
The base automation element from where the textbox should be retrieved.

.PARAMETER Name
The name of the textbox to be retrieved.

.EXAMPLE
$textbox = Get-AutomationTextBox -BaseAutomationElement $myElement -Name "MyTextBox"

This will retrieve the textbox named "MyTextBox" from the $myElement automation element.
#>
function Get-AutomationTextBox {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The base automation element')]
        [FlaUI.Core.AutomationElements.AutomationElement] $BaseAutomationElement,
        [Parameter(Mandatory = $true, HelpMessage = 'The name of the textbox to get')]
        [string] $Name
    )

    try {
        Write-Information "Retrieving textbox $Name from automation element"
        $fae = $mw.FindFirstDescendant($cf.ByName($Name)).FrameworkAutomationElement
        return [FlaUI.Core.AutomationElements.TextBox]::new($fae)
    }
    catch {
        Write-Error "An error occurred: $_"
        Write-Error "Error details: $($_.Exception)"
    }
}