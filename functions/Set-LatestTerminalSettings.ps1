<#
.SYNOPSIS
Downloads the latest version of the settings.json file from GitHub and updates the local settings.json file if the version on GitHub is newer.

.DESCRIPTION
This function downloads the latest version of the settings.json file from GitHub and updates the local settings.json file if the version on GitHub is newer. The function takes the path to the local settings.json file as a parameter.

.PARAMETER SettingsPath
The path to the local settings.json file.

.EXAMPLE
Set-LatestTerminalSettings -SettingsPath '$ENV:USERPROFILE\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
Downloads the latest version of the settings.json file from GitHub and updates the local settings.json file if the version on GitHub is newer.

.NOTES
Noted
#>
function Set-LatestTerminalSettings {
    [CmdletBinding()]
    param(
        [Parameter(
            Mandatory = $true,
            Position = 0,
            HelpMessage = 'The path to the settings.json file.'
        )]
        [ValidateScript({ Test-Path $_ })]
        [string]$SettingsPath
    )

    # Get the local settings.json file.
    $localSettings = Get-Content -Path $SettingsPath | ConvertFrom-Json

    # Check if the version key exists in the local settings.json file.
    if ($localSettings.PSObject.Properties.Name -contains 'version') {
        # The version key exists. Get the version number.
        $localVersion = $localSettings.version
    }
    else {
        # The version key doesn't exist. Set the version number to 0.
        $localVersion = 0
    }

    # Get the version number from the settings.json file on GitHub.
    $githubSettings = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/Non%20PowerShell%20Tools/settings.json' | ConvertFrom-Json
    $githubVersion = $githubSettings.version

    if ($localVersion -lt $githubVersion) {
        try {
            # Download the latest version of the settings.json file from GitHub
            $githubSettings = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/Non%20PowerShell%20Tools/settings.json'
            
            # Check the response status code
            if ($githubSettings.StatusCode -eq 200) {
                # Successful download, overwrite the local settings.json file
                $githubSettings.Content | Set-Content -Path $SettingsPath -Encoding UTF8
                
                Write-Output 'The local settings.json file has been updated with the latest version from GitHub.'
            }
            else {
                Write-Error 'Failed to download the latest version of settings.json from GitHub.'
                throw
            }
        }
        catch {
            Write-Error "An error occurred while updating the settings.json file:`n$($_.Exception.Message)"
        }
        
    }
    else {
        Write-Output 'The local settings.json file is already up to date.'
    }
}
