<#
.SYNOPSIS
Automatically updates Windows using the KBUpdate module and schedules a task for the same.

.DESCRIPTION
The function checks if KBUpdate and BurntToast modules are installed, installs them if they aren't, 
and schedules a task to update Windows every hour. 

.PARAMETER None

.EXAMPLE
Update-Windows

.NOTES
Make sure to run PowerShell as an administrator to allow scheduled task registration and updates.

.LINK
https://github.com/potatoqualitee/kbupdate
#>
function Update-Windows {
    [CmdletBinding()]
    param()

    # Check if the kbupdate and BurntToast modules are installed
    foreach ($module in @('kbupdate', 'BurntToast')) {
        if (-Not (Get-Module -ListAvailable -Name $module)) {
            Install-Module -Name $module -Force -SkipPublisherCheck
            Import-Module $module
        }
    }

    # Check if the scheduled task already exists
    $task = Get-ScheduledTask -TaskName "WindowsUpdateWithKB" -ErrorAction SilentlyContinue

    if (!$task) {
        # Create a new scheduled task
        $action = New-ScheduledTaskAction -Execute 'powershell' -Argument 'Update-Windows'
        $trigger = New-ScheduledTaskTrigger -Daily -At '00:00'
        $settings = New-ScheduledTaskSettingsSet -DontStopOnIdleEnd
        $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount

        $task = Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "WindowsUpdateWithKB" -Settings $settings -Principal $principal

    }

    # Fetch available updates
    $updates = Get-KbUpdate

    # Loop through each update and install it
    foreach ($update in $updates) {
        try {
            Install-KbUpdate -KbId $update.KbId -Force

            if ($update.IsRebootRequired) {
                $Toast = New-BTNotification -Text "Windows Update", "A reboot is required to complete the update process."
                Submit-BTNotification -Notification $Toast
            }
        }
        catch {
            Write-Error "Failed to install update $($update.KbId): $_"
        }
    }
}
