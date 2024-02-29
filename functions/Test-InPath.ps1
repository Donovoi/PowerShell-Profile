<#
.SYNOPSIS
    Checks if an executable file is in the system's PATH environment variable.

.DESCRIPTION
    This function checks if a specified executable file is present in the system's PATH environment variable.
    It returns a Boolean value indicating whether the executable is found in the PATH or not.

.PARAMETER ExeName
    Specifies the name of the executable file to check.

.EXAMPLE
    Test-ExeInPath -ExeName "your_executable.exe"

    Checks if "your_executable.exe" is in the PATH.

    # Example usage
    $exeName = "your_executable.exe"
    if (Test-ExeInPath -ExeName $exeName) {
        Write-Host "$exeName is in the PATH."
    } else {
        Write-Host "$exeName is not in the PATH."
    }


.INPUTS
    None. You cannot pipe objects to Test-ExeInPath.

.OUTPUTS
    [bool] True if the executable is found in the PATH, False otherwise.

.NOTES
    Author: [triangles]
    Version: 1.0
    Date: [Date?]

#>
function Test-ExeInPath {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $ExeName
    )

    # Error handling
    try {
        # Get directories from PATH environment variable
        $pathDirs = $env:Path -split ';'

        # Check if the executable exists in any of the directories
        foreach ($dir in $pathDirs) {
            $exePath = Join-Path -Path $dir -ChildPath $ExeName
            if (Test-Path -Path $exePath -PathType Leaf) {
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

