<#
.SYNOPSIS
    Short description
.DESCRIPTION
    Long description
.EXAMPLE
    Example of how to use this cmdlet
.EXAMPLE
    Another example of how to use this cmdlet
#>
function Get-CSWin32Assembly {
    [CmdletBinding()]
    [OutputType([type])]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $parameter_name
    )

    begin {
        Install-Module Cobalt -Force
        # make sure we have the requirements for the source generation in .net
        winget install Microsoft.DotNet.SDK.Preview
    }

    process {

    }

    end {
    }
}