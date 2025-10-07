<#
.SYNOPSIS
Converts a short (8.3) file/directory path to a long path.

.DESCRIPTION
The Get-LongName function converts a short (8.3 format) file or directory path to its long path equivalent using the GetLongPathName function from kernel32.dll.

.PARAMETER ShortName
Specifies the short name path to be converted.

.EXAMPLE
Get-LongName -ShortName "C:\PROGRA~1"

This command converts the short name path "C:\PROGRA~1" to its long path equivalent.

.NOTES
File Name : Get-LongName.ps1
Author    : YourName
Prerequisite : PowerShell V3
#>

function Get-LongName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$ShortName
    )
    begin {
        # Add the LongPath class only once at the beginning
        Add-Type @'
        using System;
        using System.Runtime.InteropServices;
        public class LongPath {
            [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
            public static extern uint GetLongPathName(string lpszShortPath, [Out] System.Text.StringBuilder lpszLongPath, uint cchBuffer);
        }
'@
    }

    process {
        try {
            $longNameBuilder = New-Object System.Text.StringBuilder(255)
            $result = [LongPath]::GetLongPathName($ShortName, $longNameBuilder, $longNameBuilder.Capacity)

            if ($result -eq 0) {
                throw "Failed to resolve long name for path '$ShortName'."
            }

            $longName = $longNameBuilder.ToString()
            return $longName
        }
        catch {
            Write-Error -Message $_.Exception.Message
        }
    }
}