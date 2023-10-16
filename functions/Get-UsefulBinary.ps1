<#
.SYNOPSIS
   A function to download, extract, and copy binaries from specified GitHub repositories to a local directory.

.DESCRIPTION
   This function utilizes the Get-LatestGitHubRelease function to download binaries from specified GitHub repositories. 
   It checks for self-contained binaries, copies them to a specified directory, refreshes the console, and validates the operation.

.PARAMETER PackageNames
   An array of package names to be downloaded.

.PARAMETER OwnerRepo
   Specifies the GitHub repository in the format 'owner/repository'.

.PARAMETER Interactive
   A switch to enable interactive mode for user input.

.EXAMPLE
   Get-UsefulBinary -PackageNames @('pkg1', 'pkg2') -OwnerRepo 'owner/repo'

#>
function Get-UsefulBinary {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string[]] $PackageNames,

        [Parameter(Mandatory = $false)]
        [string] $OwnerRepo,

        [Parameter(Mandatory = $false)]
        [switch] $Interactive
    )
    
    $XWAYS = "Path_To_Your_Directory"

    function InteractiveMode {
        do {
            $OwnerRepo = Read-Host "Enter Owner/Repo"
            $PackageName = Read-Host "Enter Package Name"
            $PackageNames += $PackageName

            # Verify GitHub account and release exists
            # Display green tick or keep looping
            $valid = Test-GitHubRepo -OwnerRepo $OwnerRepo -PackageName $PackageName
            if ($valid) {
                Write-Host "$OwnerRepo - $PackageName " -NoNewline
                Write-Host "✓" -ForegroundColor Green
            }
            else {
                Write-Host "Invalid entry or repository/package not found. Try again."
            }

            $userInput = Read-Host "Press 'q' to quit or any other key to enter another repo/package"
        } while ($userInput -ne 'q')
    }

    function Test-GitHubRepo {
        param(
            [string] $OwnerRepo,
            [string] $PackageName
        )
        # logic to check GitHub repo and package
        # return $true if valid, $false otherwise
    }

    function Main {
        foreach ($PackageName in $PackageNames) {
            $downloadPath = Get-LatestGitHubRelease -OwnerRepository $OwnerRepo -AssetName $PackageName -DownloadPathDirectory "$XWAYS\Chocolatey apps\Chocolatey\bin" -ExtractZip

            # logic to check for self-contained binaries and copy to destination
            # Refresh console, validate operation, and display success or verbose error

            # ...

        }
    }

    begin {
        if ($Interactive) {
            InteractiveMode
        }
    } process {
        Main
    } end {
        Write-Host "Done!"
    }
}

