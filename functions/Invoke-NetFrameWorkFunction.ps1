<#
.SYNOPSIS
Invokes a .NET Framework function within a PowerShell 5.1 session from PowerShell 7.

.DESCRIPTION
The Invoke-NetFrameWorkFunction cmdlet allows you to run a script block that contains .NET Framework-specific functionality within a PowerShell 5.1 session. This is particularly useful when running PowerShell 7, which is based on .NET Core and may not support certain .NET Framework features. The function creates a temporary PowerShell 5.1 session, invokes the script block with the provided arguments, and then returns the output.

.PARAMETER FunctionBlock
The script block containing the .NET Framework function to be executed. This parameter is mandatory.

.PARAMETER Arguments
A hashtable containing the arguments to be passed to the FunctionBlock script block. The keys should match the parameter names expected by the script block. This parameter is mandatory.

.EXAMPLE
# Define the script block directly, not as a string
$scriptBlock = {
    param($message)
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show($message)
}

# Ensure that the arguments hashtable keys match the script block's parameters
$functionargs = @{
    message = 'Hello from .NET Framework!'
}

# Invoke the function with the script block and the arguments
Invoke-NetFrameWorkFunction -FunctionBlock $scriptBlock -Arguments $functionargs

This example shows how to display a message box using the .NET Framework's Windows Presentation Foundation (WPF) from within PowerShell 7 by invoking the function in a PowerShell 5.1 session.

.INPUTS
None. You cannot pipe input to this function.

.OUTPUTS
The output of the FunctionBlock script block is returned. If the script block does not return anything, nothing is returned by this function.

.NOTES
This function requires both PowerShell 5.1 and PowerShell 7 to be installed on the system. It creates a temporary PowerShell 5.1 session to execute the .NET Framework code and then removes the session once the execution is complete.

.LINK
https://docs.microsoft.com/en-us/powershell/scripting/overview?view=powershell-7.1

#>
function Invoke-NetFrameWorkFunction {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$FunctionBlock,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments
    )

    $PS5Session = New-PSSession -UseWindowsPowerShell -Name 'PS5Session'
    $FunctionOutput = Invoke-Command -ScriptBlock {
        try {
            $argus = $using:Arguments
            $argumentList = $argus.GetEnumerator() | ForEach-Object { $_.Value }
            # Explicitly cast the script block before invoking
            $scriptBlockToInvoke = [scriptblock]::Create($using:FunctionBlock)
            $output = Invoke-Command -ScriptBlock $scriptBlockToInvoke -ArgumentList $argumentList
            return $output
        }
        catch {
            Write-Error "Failed to invoke .NET function: $_"
        }
        finally {
            Remove-PSSession -Session $PS5Session
        }
    } -ArgumentList $FunctionBlock, $Arguments -Session $PS5Session

    return $FunctionOutput
}

