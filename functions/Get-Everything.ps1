<#
.SYNOPSIS
    This is a PowerShell Cmdlet that uses voidtools' Everything to get a list of all files in a folder and its subfolders.
.DESCRIPTION
    Either given a directory, or given a query using Everything syntax, this function will return a list of all files in a folder and its subfolders.
.NOTES
    Information or caveats about the function e.g. 'This function is not supported in Linux'
.LINK
    Specify a URI to a help page, this will show when Get-Help -Online is used.
.EXAMPLE
    Test-MyTestFunction -Verbose
    Explanation of the function or its result. You can include multiple examples with additional .EXAMPLE lines
#>



function Get-Everything {
    [CmdletBinding()]
    param (
        # Everything executable path
        [Parameter(Mandatory = $true)]
        [ParameterType]
        $EverythingEXE
    )
    
    begin {
        # we need to check if the Everything executable is present
    }
    
    process {
        Start-Process -FilePath  ".\Non PowerShell Tools\everything portable\es.exe" -ArgumentList "-full-path-and-name -export-csv OUTPUT.csv folder: D:\ -no-header" -Wait -NoNewWindow


        [string[]]$FilePathsArray = Get-Content .\OUTPUT.csv -ReadCount 0
    
    }
    
    end {
        
    }
}