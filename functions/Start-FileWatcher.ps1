<#
.SYNOPSIS
Starts a file watcher to monitor changes in the settings.json file.

.DESCRIPTION
This function starts a FileSystemWatcher to monitor changes in the settings.json file.
Whenever the file is modified, the function will increment the version number in the file.

.PARAMETER SettingsPath
The path to the settings.json file.

.EXAMPLE
Start-FileWatcher -SettingsPath "C:\Path\to\settings.json"

This example starts the file watcher to monitor changes in the settings.json file located at "C:\Path\to\settings.json".

#>
function Start-FileWatcher {
    [CmdletBinding()]
    param (
        [Parameter(
            Mandatory = $true,
            Position = 0,
            HelpMessage = 'The path to the settings.json file.'
        )]
        [ValidateScript({ Test-Path $_ })]
        [string]$SettingsPath
    )

    try {
        # Create a FileSystemWatcher to monitor the settings.json file.
        $watcher = New-Object System.IO.FileSystemWatcher -ErrorAction Stop
        $watcher.Path = [System.IO.Path]::GetDirectoryName($SettingsPath)
        $watcher.Filter = [System.IO.Path]::GetFileName($SettingsPath)
        $watcher.EnableRaisingEvents = $true

        # Define the event handler for the Changed event.
        $changedHandler = {
            try {
                # Read the settings.json file.
                $settings = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json -ErrorAction Stop

                # Check if the version key exists.
                if ($settings.PSObject.Properties.Name -contains 'version') {
                    # Increment the version number.
                    $settings.version++
                }
                else {
                    # The version key doesn't exist. Add it.
                    $settings | Add-Member -Type NoteProperty -Name version -Value 1
                }

                # Save the settings.json file.
                $settings | ConvertTo-Json -Depth 4 | Set-Content -Path $SettingsPath -Encoding UTF8 -ErrorAction Stop
            }
            catch {
                Write-Warning "An error occurred while processing the settings.json file:`n$($_.Exception.Message)"
            }
        }

        # Register the event handler.
        $eventSubscription = Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $changedHandler -ErrorAction Stop

        # Keep the script running indefinitely.
        do {
            Start-Sleep -Seconds 1
        } while ($true)
    }
    catch {
        Write-Error "An error occurred while setting up the file watcher:`n$($_.Exception.Message)"
    }
    finally {
        # Clean up resources.
        if ($null -ne $watcher) {
            $watcher.Dispose()
        }
        if ($null -ne $eventSubscription) {
            Unregister-Event -SubscriptionId $eventSubscription.Id
        }
    }
}
