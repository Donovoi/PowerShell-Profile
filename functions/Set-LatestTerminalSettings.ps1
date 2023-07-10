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
        [string[]]$SettingsPaths,

        # Parameter help description
        [Parameter(Mandatory = $false)]
        [switch]
        $ToUpload
    )
    foreach ($SettingsPath in $SettingsPaths) {
        # Get the local settings.json file.
        $localSettings = Get-Content -Path $SettingsPath | ConvertFrom-Json


        if ($ToUpload) {
            # Upload the settings.json file to GitHub.
            $repositoryOwner = 'Donovoi'
            $repositoryName = 'PowerShell-Profile'
            $filePath = $SettingsPath
            $branchName = 'main'  
            $commitMessage = 'Upload settings.json'
            $destinationFilePath = 'main/Non PowerShell Tools/settings.json'  
            
            # Read the file content
            $fileContent = Get-Content -Path $filePath -Raw
            
            # Create the API URL
            $url = "https://api.github.com/repos/$repositoryOwner/$repositoryName/contents/$destinationFilePath"
            
            # Create the request body
            $body = @{
                message = $commitMessage
                content = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($fileContent))
                branch  = $branchName
            }
            
            # Convert the body to JSON
            $jsonBody = $body | ConvertTo-Json
            
            # Create the headers
            $headers = @{
                'Authorization' = 'Bearer YourPersonalAccessToken'  # Replace with your personal access token
                'Content-Type'  = 'application/json'
            }
            
            # Send the POST request to GitHub API to create the file
            $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $jsonBody
            
            # Output the response
            $response       
        }

        # get the local version number from the settings.json file
        $localVersion = $localSettings.version

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
}
