<#
.SYNOPSIS
    Checks if an executable file is in the system's PATH environment variable.

.DESCRIPTION
    This function checks if a specified executable file is present in the system's PATH environment variable.
    It returns a Boolean value indicating whether the executable is found in the PATH or not.

.PARAMETER ExeName
    Specifies the name of the executable file to check.

.EXAMPLE
    Test-InPath -ExeName "your_executable.exe"

    Checks if "your_executable.exe" is in the PATH.

    # Example usage
    $exeName = "your_executable.exe"
    if (Test-InPath -ExeName $exeName) {
        Write-Host "$exeName is in the PATH."
    } else {
        Write-Host "$exeName is not in the PATH."
    }


.INPUTS
    None. You cannot pipe objects to Test-InPath.

.OUTPUTS
    [bool] True if the executable is found in the PATH, False otherwise.

.NOTES
    Author: [triangles]
    Version: 1.0
    Date: [Date?]

#>
function Test-InPath {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $ExeName
    )

    # Error handling
    try {
        # Get directories from PATH environment variable
        $pathDirs = $ENV:PATH -split ';'

        # Check if the executable exists in any of the directories
        foreach ($dir in $pathDirs) {
            if ([string]::IsNullOrEmpty($dir)) {
                continue
            }
            $exePath = Join-Path -Path $dir -ChildPath $ExeName
            if (Test-Path -Path $exePath -ErrorAction SilentlyContinue) {
                return $true
            }
        }

        return $false
    }
    catch {
        Write-Error "An error occurred while checking if the executable is in the PATH: $_"
        return $false
    }
}