<#
.SYNOPSIS
    Gets the latest version of the Windows Terminal settings.json file from GitHub and updates it locally.
.DESCRIPTION
    This function checks the version number of the local settings.json
    file against the version number of the settings.json file on GitHub.
    If the local version is older, the function downloads the latest version from GitHub and updates the local file.
.PARAMETER settingsPathPattern
    The path pattern to the settings.json file.
    The default value is "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_*_8wekyb3d8bbwe\LocalState\settings.json".
.EXAMPLE
    Get-LatestTerminalSettings
    This example gets the latest version of the Windows Terminal settings.json file from GitHub and updates it locally.
.EXAMPLE
    Get-LatestTerminalSettings -settingsPathPattern
    "$ENV:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
    This example gets the latest version of the Windows Terminal settings.json file
    from GitHub and updates it locally using the specified path pattern.
#>
function Get-LatestTerminalSettings {
    [CmdletBinding()]
    param(
        [Parameter(
            Mandatory = $false,
            Position = 0,
            HelpMessage = 'The path pattern to the settings.json file.'
        )]
        [string]$settingsPathPattern = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_*_8wekyb3d8bbwe\LocalState\settings.json"
    )

    # Get the paths to the settings.json files.
    $settingsPaths = Get-ChildItem -Path $settingsPathPattern

    foreach ($settingsPath in $settingsPaths) {
        # Check if the scheduled task exists.
        $taskExists = Get-ScheduledTask -TaskName 'UpdateTerminalSettings' -ErrorAction SilentlyContinue

        if (-not $taskExists) {
            # The scheduled task doesn't exist. Create it.

            $xmlPath = Join-Path -Path $($PROFILE | Split-Path -Parent) -ChildPath '.\Non PowerShell Tools\' -AdditionalChildPath task.xml -Resolve
            $filewatcherscript = Join-Path -Path $($PROFILE | Split-Path -Parent) -ChildPath '.\functions\Start-FileWatcher.ps1' -Resolve
            if (-not(Test-Path -Path $xmlPath)) {
                Write-Error "XML file not found at '$xmlPath'." -ErrorAction Stop
            }
            # Load the XML file.
            [xml]$taskXml = Get-Content -Path $xmlPath

            # Change the username.
            $taskXml.Task.RegistrationInfo.Author = $ENV:USERNAME
            $taskXml.Task.Triggers.LogonTrigger.UserId = $ENV:USERNAME

            # Change the script path.
            $taskXml.Task.Actions.Exec.Command = 'pwsh.exe'
            $taskXml.Task.Actions.Exec.Arguments = "-File `"$($filewatcherscript)`""

            # Save the modified XML to a new file.
            $taskXml.OuterXml | Set-Content -Path "$ENV:TEMP\modified_task.xml" -Force

            # Register the task.
            Register-ScheduledTask -Xml (Get-Content -Path "$ENV:TEMP\modified_task.xml" | Out-String) -TaskName 'SillyBugger'
            Write-Output "Created scheduled task 'UpdateTerminalSettings'."
        }

        # Get the local settings.json file.
        $localSettings = Get-Content -Path $settingsPath | ConvertFrom-Json

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
            # The local settings.json file is older. Call Set-LatestTerminalSettings to update it.
            Set-LatestTerminalSettings -settingsPath $settingsPath.FullName
        }
        elseif ($localVersion -eq $githubVersion) {
            # The local settings.json file is up to date.
            Write-Output "The local settings.json file is up to date."
        }
        elseif (($localVersion -gt $githubVersion) -or ([string]::IsNullOrWhiteSpace($githubVersion))) {
            # The local settings.json file is newer than the version on GitHub.
            Write-Output "The local settings.json file is newer than the version on GitHub."
            Set-TerminalSettings -settingsPath $settingsPath.FullName -ToUpload
        }
        else {
            Write-Ascii -Text "Something went wrong."
            Write-Ascii -Text "We are not supposed to be here"
        }
    }
}
