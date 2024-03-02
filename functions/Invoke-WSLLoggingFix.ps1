function Invoke-WSLLoggingFix {
    <#
    .SYNOPSIS
    Stops all WSL processes and cleans up the RdClientAutoTrace directory if a specific GitHub issue is still open.

    .DESCRIPTION
    This function checks the status of a specified GitHub issue. If the issue is open, it proceeds to shut down all WSL instances, stop the LxssManager service, delete the RdClientAutoTrace directory, and create a dummy file to prevent future logging. Requires administrative privileges to run.

    .PARAMETER RepoOwner
    The owner of the GitHub repository.

    .PARAMETER RepoName
    The name of the GitHub repository.

    .PARAMETER IssueNumber
    The number of the GitHub issue to check.

    .EXAMPLE
    Invoke-WSLLoggingFix -RepoOwner 'microsoft' -RepoName 'WSL' -IssueNumber 10216

    Checks the status of GitHub issue #10216. If open, applies the workaround to stop WSL processes and clean the RdClientAutoTrace directory.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RepoOwner,

        [Parameter(Mandatory = $true)]
        [string]$RepoName,

        [Parameter(Mandatory = $true)]
        [int]$IssueNumber
    )

    # Function to check the status of a GitHub issue
    function Check-GitHubIssueFixed {
        param (
            [string]$RepoOwner,
            [string]$RepoName,
            [int]$IssueNumber
        )

        $issueApiUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/issues/$IssueNumber"

        try {
            $issue = Invoke-RestMethod -Uri $issueApiUrl -Headers @{Accept = 'application/vnd.github.v3+json' }
            return $issue.state -eq 'closed'
        }
        catch {
            Write-Warning "Failed to check GitHub issue status. Error: $_"
            return $false
        }
    }

    # Ensure the function is running with administrative privileges
    if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error 'This function requires administrative privileges. Please run PowerShell as an administrator.'
        return
    }

    # Check if the GitHub issue is fixed
    $issueFixed = Check-GitHubIssueFixed -RepoOwner $RepoOwner -RepoName $RepoName -IssueNumber $IssueNumber

    if (-not $issueFixed) {
        Write-Host 'The GitHub issue is still open. Applying the workaround...'

        # Shutdown all instances of WSL
        wsl --shutdown

        # Stop the LxssManager service
        Get-Service LxssManager | Stop-Service -Force -ErrorAction Stop

        # Define the target directory and file paths
        $tempPath = [System.Environment]::ExpandEnvironmentVariables('%temp%\DiagOutputDir')
        $targetDir = Join-Path -Path $tempPath -ChildPath 'RdClientAutoTrace'
        $dummyFile = Join-Path -Path $tempPath -ChildPath 'RdClientAutoTrace.txt'

        # Delete the RdClientAutoTrace directory if it exists
        if (Test-Path -Path $targetDir) {
            Remove-Item -Path $targetDir -Recurse -Force -ErrorAction Stop
        }

        # Ensure the DiagOutputDir directory exists
        if (-not (Test-Path -Path $tempPath)) {
            New-Item -ItemType Directory -Path $tempPath | Out-Null
        }

        # Create a dummy RdClientAutoTrace file
        New-Item -ItemType File -Path $dummyFile | Out-Null

        # Rename the dummy file to RdClientAutoTrace (without .txt extension)
        Rename-Item -Path $dummyFile -NewName ($dummyFile -replace '\.txt$', '') -ErrorAction Stop

        Write-Host 'WSL processes stopped and RdClientAutoTrace directory handled.'
    }
    else {
        Write-Host 'The GitHub issue has been resolved. No need to apply the workaround.'
    }
}
