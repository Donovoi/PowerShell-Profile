<#
.SYNOPSIS
This function retrieves a specified button from a base automation element.

.DESCRIPTION
The Get-AutomationButton function retrieves a specified button from a base automation element. 
It uses the FlaUI library to interact with the UI Automation framework.

.PARAMETER BaseAutomationElement
The base automation element from where the button should be retrieved.

.PARAMETER Name
The name of the button to be retrieved.

.EXAMPLE
$button = Get-AutomationButton -BaseAutomationElement $myElement -Name "MyButton"

This will retrieve the button named "MyButton" from the $myElement automation element.
#>
function Get-AutomationButton {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = 'The base automation element')]
        [FlaUI.Core.AutomationElements.AutomationElement] $BaseAutomationElement,
        [Parameter(Mandatory = $true, HelpMessage = 'The name of the button to get')]
        [string] $Name
    )

    try {
        Write-Information "Retrieving button $Name from automation element"
        return $BaseAutomationElement.FindFirstDescendant($btnCondition.And($cf.ByName($Name)))
    }
    catch {
        Write-Error "An error occurred: $_"
        Write-Error "Error details: $($_.Exception)"
    }
}