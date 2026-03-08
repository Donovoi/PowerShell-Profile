function Invoke-Tiny11Live {
    <#
    .SYNOPSIS
    Applies tiny11-style cleanup changes to the current Windows installation.

    .DESCRIPTION
    Invoke-Tiny11Live removes selected provisioned and installed Appx packages,
    applies tiny11-style registry changes, disables selected telemetry-related
    scheduled tasks, and can optionally restart the computer when finished.

    This function is intended for use on a live Windows installation and must
    be run from an elevated PowerShell session. It does not modify the current
    execution policy or relaunch itself in a second console window; instead it
    follows normal advanced-function behavior and supports PowerShell's
    -WhatIf and -Confirm semantics.

    .PARAMETER Force
    Skips the additional interactive confirmation prompt before changes are
    applied. This does not bypass PowerShell's built-in -WhatIf or -Confirm
    behavior.

    .PARAMETER Restart
    Restarts the computer automatically after the cleanup completes.

    .PARAMETER SkipTranscript
    Skips transcript logging.

    .PARAMETER TranscriptPath
    Path to the transcript log file. By default, a timestamped log file is
    created next to this function file.

    .PARAMETER PassThru
    Returns a summary object describing the work performed.

    .EXAMPLE
    Invoke-Tiny11Live -WhatIf

    Shows what would happen without making changes.

    .EXAMPLE
    Invoke-Tiny11Live -Force -Verbose

    Applies the cleanup without the extra ShouldContinue prompt and emits
    verbose progress details.

    .EXAMPLE
    Invoke-Tiny11Live -Restart -Confirm:$false

    Applies the cleanup and then restarts the computer without confirmation
    prompts.

    .EXAMPLE
    Invoke-Tiny11Live -PassThru | Format-List *

    Applies the cleanup and returns a summary object.

    .OUTPUTS
    [pscustomobject] when -PassThru is specified.

    .NOTES
    Author: Based on tiny11maker.ps1 by ntdevlabs
    Date: 2026-03-09

    Run this function from an elevated PowerShell session.
    A restart is strongly recommended after the cleanup completes.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$Restart,

        [Parameter()]
        [switch]$SkipTranscript,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$TranscriptPath = (Join-Path -Path $PSScriptRoot -ChildPath ('tiny11cleanup_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))),

        [Parameter()]
        [switch]$PassThru
    )

    Set-StrictMode -Version 3.0

    function Write-Tiny11Message {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [AllowEmptyString()]
            [string]$Message
        )

        Write-Information $Message -InformationAction Continue
    }

    function Write-Tiny11Section {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Message
        )

        Write-Tiny11Message -Message "===== $Message ====="
    }

    function Add-Tiny11Error {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Message
        )

        $summary.Errors.Add($Message)
        Write-Warning $Message
    }

    function Test-Tiny11IsWindows {
        [CmdletBinding()]
        param()

        return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    }

    function Test-Tiny11Administrator {
        [CmdletBinding()]
        param()

        $windowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $windowsPrincipal = [System.Security.Principal.WindowsPrincipal]::new($windowsIdentity)
        return $windowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function ConvertTo-Tiny11RegistryPath {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        if ($Path -match '^[A-Za-z]+:\\') {
            return $Path
        }

        switch -Regex ($Path) {
            '^HKLM\\' {
                return ('HKLM:\' + $Path.Substring(5))
            }
            '^HKCU\\' {
                return ('HKCU:\' + $Path.Substring(5))
            }
            default {
                throw "Unsupported registry path format: '$Path'."
            }
        }
    }

    function Set-Tiny11RegistryValue {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Path,

            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,

            [Parameter(Mandatory)]
            [ValidateSet('REG_SZ', 'REG_DWORD', 'REG_BINARY', 'REG_MULTI_SZ', 'REG_EXPAND_SZ', 'REG_QWORD')]
            [string]$Type,

            [Parameter(Mandatory)]
            [AllowNull()]
            [object]$Value
        )

        try {
            $resolvedPath = ConvertTo-Tiny11RegistryPath -Path $Path
            if (-not (Test-Path -LiteralPath $resolvedPath)) {
                New-Item -Path $resolvedPath -Force -ErrorAction Stop | Out-Null
            }

            $propertyType = switch ($Type) {
                'REG_SZ' {
                    'String' 
                }
                'REG_DWORD' {
                    'DWord' 
                }
                'REG_BINARY' {
                    'Binary' 
                }
                'REG_MULTI_SZ' {
                    'MultiString' 
                }
                'REG_EXPAND_SZ' {
                    'ExpandString' 
                }
                'REG_QWORD' {
                    'QWord' 
                }
            }

            $propertyValue = switch ($Type) {
                'REG_BINARY' {
                    if ($Value -isnot [byte[]]) {
                        throw 'Value for REG_BINARY must be a byte array.'
                    }

                    [byte[]]$Value
                }
                'REG_MULTI_SZ' {
                    if ($Value -is [string]) {
                        @($Value)
                    }
                    else {
                        [string[]]$Value
                    }
                }
                default {
                    $Value
                }
            }

            New-ItemProperty -Path $resolvedPath -Name $Name -PropertyType $propertyType -Value $propertyValue -Force -ErrorAction Stop | Out-Null
            $summary.RegistryValuesSet++
            Write-Verbose "Set registry value: $resolvedPath\$Name"
        }
        catch {
            Add-Tiny11Error -Message "Failed to set registry value '$Path\$Name': $($_.Exception.Message)"
        }
    }

    function Remove-Tiny11RegistryKey {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        try {
            $resolvedPath = ConvertTo-Tiny11RegistryPath -Path $Path
            if (-not (Test-Path -LiteralPath $resolvedPath)) {
                Write-Verbose "Registry key not present: $resolvedPath"
                return
            }

            Remove-Item -LiteralPath $resolvedPath -Recurse -Force -ErrorAction Stop
            $summary.RegistryKeysRemoved++
            Write-Verbose "Removed registry key: $resolvedPath"
        }
        catch {
            Add-Tiny11Error -Message "Failed to remove registry key '$Path': $($_.Exception.Message)"
        }
    }

    function Test-Tiny11PackagePrefixMatch {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [AllowNull()]
            [AllowEmptyString()]
            [string]$Name,

            [Parameter(Mandatory)]
            [string[]]$PackagePrefixes
        )

        if ([string]::IsNullOrEmpty($Name)) {
            return $false
        }

        foreach ($packagePrefix in $PackagePrefixes) {
            if ($Name -like "*$packagePrefix*") {
                return $true
            }
        }

        return $false
    }

    function Remove-Tiny11AppxPackages {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string[]]$PackagePrefixes
        )

        Write-Tiny11Section -Message 'Removing Provisioned AppX Packages'

        try {
            $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction Stop
            $matchingProvisionedPackages = $provisionedPackages | Where-Object {
                Test-Tiny11PackagePrefixMatch -Name $_.DisplayName -PackagePrefixes $PackagePrefixes
            }

            foreach ($package in $matchingProvisionedPackages) {
                try {
                    Write-Tiny11Message -Message "Removing provisioned package: $($package.DisplayName)"
                    $package | Remove-AppxProvisionedPackage -Online -ErrorAction Stop | Out-Null
                    $summary.ProvisionedPackagesRemoved++
                }
                catch {
                    Add-Tiny11Error -Message "Failed to remove provisioned package '$($package.DisplayName)': $($_.Exception.Message)"
                }
            }
        }
        catch {
            Add-Tiny11Error -Message "Error enumerating provisioned AppX packages: $($_.Exception.Message)"
        }

        Write-Tiny11Message -Message 'Removing installed AppX packages for all users...'

        try {
            $installedPackages = Get-AppxPackage -AllUsers -ErrorAction Stop
            $matchingInstalledPackages = $installedPackages | Where-Object {
                Test-Tiny11PackagePrefixMatch -Name $_.Name -PackagePrefixes $PackagePrefixes
            }

            foreach ($package in $matchingInstalledPackages) {
                try {
                    Write-Tiny11Message -Message "Removing installed package: $($package.Name)"
                    Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                    $summary.InstalledPackagesRemoved++
                }
                catch {
                    Add-Tiny11Error -Message "Failed to remove installed package '$($package.Name)': $($_.Exception.Message)"
                }
            }
        }
        catch {
            Add-Tiny11Error -Message "Error enumerating installed AppX packages: $($_.Exception.Message)"
        }
    }

    function Disable-Tiny11TelemetryScheduledTasks {
        [CmdletBinding()]
        param()

        Write-Tiny11Section -Message 'Disabling Telemetry Scheduled Tasks'

        $schtasksPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\schtasks.exe'
        if (-not (Test-Path -LiteralPath $schtasksPath)) {
            Add-Tiny11Error -Message "schtasks.exe was not found at '$schtasksPath'."
            return
        }

        $scheduledTasks = @(
            '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
            '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
            '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
            '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
            '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
        )

        foreach ($scheduledTask in $scheduledTasks) {
            & $schtasksPath /Query /TN $scheduledTask 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Verbose "Scheduled task not found: $scheduledTask"
                continue
            }

            Write-Tiny11Message -Message "Disabling: $scheduledTask"
            & $schtasksPath /Change /TN $scheduledTask /Disable 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $summary.ScheduledTasksDisabled++
            }
            else {
                Add-Tiny11Error -Message "Failed to disable scheduled task '$scheduledTask'."
            }
        }
    }

    $summary = [ordered]@{
        ComputerName               = $env:COMPUTERNAME
        StartTime                  = Get-Date
        EndTime                    = $null
        Duration                   = $null
        TranscriptPath             = if ($SkipTranscript) {
            $null 
        }
        else {
            $TranscriptPath 
        }
        ProvisionedPackagesRemoved = 0
        InstalledPackagesRemoved   = 0
        RegistryValuesSet          = 0
        RegistryKeysRemoved        = 0
        ScheduledTasksDisabled     = 0
        RestartRequested           = [bool]$Restart
        RestartTriggered           = $false
        Errors                     = [System.Collections.Generic.List[string]]::new()
    }

    if (-not (Test-Tiny11IsWindows)) {
        throw 'Invoke-Tiny11Live is supported only on Windows.'
    }

    if (-not (Test-Tiny11Administrator)) {
        throw 'Invoke-Tiny11Live must be run from an elevated PowerShell session.'
    }

    $targetComputer = if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        'local computer' 
    }
    else {
        $env:COMPUTERNAME 
    }
    if (-not $PSCmdlet.ShouldProcess($targetComputer, 'Apply tiny11 live cleanup changes')) {
        return
    }

    if (-not $Force) {
        $queryMessage = 'This will remove selected built-in applications, update registry policy settings, and disable telemetry-related scheduled tasks on the current Windows installation.'
        $caption = 'Continue with Tiny11 live cleanup?'
        if (-not $PSCmdlet.ShouldContinue($queryMessage, $caption)) {
            Write-Tiny11Message -Message 'Operation cancelled.'
            return
        }
    }

    $transcriptStarted = $false

    $packagePrefixes = @(
        'AppUp.IntelManagementandSecurityStatus',
        'Clipchamp.Clipchamp',
        'DolbyLaboratories.DolbyAccess',
        'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.BingWeather',
        'Microsoft.Copilot',
        'Microsoft.Windows.CrossDevice',
        'Microsoft.GamingApp',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.Microsoft3DViewer',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes',
        'Microsoft.MixedReality.Portal',
        'Microsoft.MSPaint',
        'Microsoft.Office.OneNote',
        'Microsoft.OfficePushNotificationUtility',
        'Microsoft.OutlookForWindows',
        'Microsoft.Paint',
        'Microsoft.People',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.SkypeApp',
        'Microsoft.StartExperiencesApp',
        'Microsoft.Todos',
        'Microsoft.Wallet',
        'Microsoft.Windows.DevHome',
        'Microsoft.Windows.Copilot',
        'Microsoft.Windows.Teams',
        'Microsoft.WindowsAlarms',
        'Microsoft.WindowsCamera',
        'microsoft.windowscommunicationsapps',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsMaps',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.WindowsTerminal',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.YourPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'MicrosoftCorporationII.MicrosoftFamily',
        'MicrosoftCorporationII.QuickAssist',
        'MSTeams',
        'MicrosoftTeams',
        'Microsoft.549981C3F5F10'
    )

    $registrySections = [ordered]@{
        'Bypassing system requirements'                  = @(
            @{ Path = 'HKCU\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKLM\SYSTEM\Setup\LabConfig'; Name = 'BypassCPUCheck'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SYSTEM\Setup\LabConfig'; Name = 'BypassRAMCheck'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SYSTEM\Setup\LabConfig'; Name = 'BypassSecureBootCheck'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SYSTEM\Setup\LabConfig'; Name = 'BypassStorageCheck'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SYSTEM\Setup\LabConfig'; Name = 'BypassTPMCheck'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SYSTEM\Setup\MoSetup'; Name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; Type = 'REG_DWORD'; Value = 1 }
        )
        'Disabling Sponsored Apps'                       = @(
            @{ Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OemPreInstalledAppsEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'ContentDeliveryAllowed'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'ConfigureStartPins'; Type = 'REG_SZ'; Value = '{"pinnedList": [{}]}' },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'FeatureManagementEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEverEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContentEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-310093Enabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338393Enabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353694Enabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\PushToInstall'; Name = 'DisablePushToInstall'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\MRT'; Name = 'DontOfferThroughWUAU'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableConsumerAccountStateContent'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent'; Type = 'REG_DWORD'; Value = 1 }
        )
        'Enabling Local Accounts on OOBE'                = @(
            @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'BypassNRO'; Type = 'REG_DWORD'; Value = 1 }
        )
        'Disabling Reserved Storage'                     = @(
            @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'; Name = 'ShippedWithReserves'; Type = 'REG_DWORD'; Value = 0 }
        )
        'Disabling BitLocker Device Encryption'          = @(
            @{ Path = 'HKLM\SYSTEM\CurrentControlSet\Control\BitLocker'; Name = 'PreventDeviceEncryption'; Type = 'REG_DWORD'; Value = 1 }
        )
        'Disabling Chat icon'                            = @(
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat'; Name = 'ChatIcon'; Type = 'REG_DWORD'; Value = 3 },
            @{ Path = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarMn'; Type = 'REG_DWORD'; Value = 0 }
        )
        'Disabling OneDrive folder backup'               = @(
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC'; Type = 'REG_DWORD'; Value = 1 }
        )
        'Disabling Telemetry'                            = @(
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name = 'HasAccepted'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Input\TIPC'; Name = 'Enabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKCU\Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKCU\Software\Microsoft\Personalization\Settings'; Name = 'AcceptedPrivacyPolicy'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKLM\SYSTEM\CurrentControlSet\Services\dmwappushservice'; Name = 'Start'; Type = 'REG_DWORD'; Value = 4 }
        )
        'Preventing installation of DevHome and Outlook' = @(
            @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate'; Name = 'workCompleted'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate'; Name = 'workCompleted'; Type = 'REG_DWORD'; Value = 1 }
        )
        'Disabling Copilot'                              = @(
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Type = 'REG_DWORD'; Value = 1 },
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'; Name = 'HubsSidebarEnabled'; Type = 'REG_DWORD'; Value = 0 },
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'REG_DWORD'; Value = 1 }
        )
        'Preventing installation of Teams'               = @(
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Teams'; Name = 'DisableInstallation'; Type = 'REG_DWORD'; Value = 1 }
        )
        'Preventing installation of New Outlook'         = @(
            @{ Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Mail'; Name = 'PreventRun'; Type = 'REG_DWORD'; Value = 1 }
        )
    }

    $registryRemovalSections = [ordered]@{
        'Removing content delivery subscription keys'          = @(
            'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
        )
        'Removing Edge related registries'                     = @(
            'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
            'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'
        )
        'Removing OOBE scheduler keys for Outlook and DevHome' = @(
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate',
            'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'
        )
    }

    try {
        if (-not $SkipTranscript) {
            $transcriptDirectory = Split-Path -Path $TranscriptPath -Parent
            if ($transcriptDirectory -and -not (Test-Path -LiteralPath $transcriptDirectory)) {
                New-Item -Path $transcriptDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            try {
                Start-Transcript -Path $TranscriptPath -ErrorAction Stop | Out-Null
                $transcriptStarted = $true
            }
            catch {
                Add-Tiny11Error -Message "Failed to start transcript at '$TranscriptPath': $($_.Exception.Message)"
            }
        }

        Write-Tiny11Message -Message '=========================================='
        Write-Tiny11Message -Message '   Tiny11 Live Cleanup                    '
        Write-Tiny11Message -Message '=========================================='
        Write-Tiny11Message -Message ''
        Write-Warning 'This function will remove bloatware and apply optimizations to your current Windows installation.'
        Write-Warning 'A system restart is recommended after completion.'
        if (-not $SkipTranscript) {
            Write-Tiny11Message -Message "Transcript log: $TranscriptPath"
        }
        Write-Tiny11Message -Message ''
        Write-Tiny11Message -Message 'Starting cleanup process...'
        Write-Tiny11Message -Message ''

        Remove-Tiny11AppxPackages -PackagePrefixes $packagePrefixes

        Write-Tiny11Section -Message 'Applying Registry Tweaks'
        foreach ($registrySection in $registrySections.GetEnumerator()) {
            Write-Tiny11Message -Message "$($registrySection.Key)..."
            foreach ($registryOperation in $registrySection.Value) {
                Set-Tiny11RegistryValue -Path $registryOperation.Path -Name $registryOperation.Name -Type $registryOperation.Type -Value $registryOperation.Value
            }
        }

        foreach ($registryRemovalSection in $registryRemovalSections.GetEnumerator()) {
            Write-Tiny11Message -Message "$($registryRemovalSection.Key)..."
            foreach ($registryPath in $registryRemovalSection.Value) {
                Remove-Tiny11RegistryKey -Path $registryPath
            }
        }

        Disable-Tiny11TelemetryScheduledTasks

        Write-Tiny11Message -Message ''
        Write-Tiny11Message -Message '=========================================='
        Write-Tiny11Message -Message '   Cleanup Complete!                     '
        Write-Tiny11Message -Message '=========================================='
        Write-Tiny11Message -Message ''
        Write-Tiny11Message -Message 'The tiny11 cleanup has been applied to your Windows installation.'
        if (-not $SkipTranscript) {
            Write-Tiny11Message -Message "Log file saved to: $TranscriptPath"
        }
        Write-Warning 'IMPORTANT: A system restart is strongly recommended.'
    }
    finally {
        $summary.EndTime = Get-Date
        $summary.Duration = [string](New-TimeSpan -Start $summary.StartTime -End $summary.EndTime)

        if ($transcriptStarted) {
            try {
                Stop-Transcript | Out-Null
            }
            catch {
                Add-Tiny11Error -Message "Failed to stop transcript cleanly: $($_.Exception.Message)"
            }
        }
    }

    if ($Restart) {
        try {
            $summary.RestartTriggered = $true
            Write-Warning 'Restarting the computer now...'
            Restart-Computer -Force -ErrorAction Stop
        }
        catch {
            $summary.RestartTriggered = $false
            Add-Tiny11Error -Message "Failed to restart the computer automatically: $($_.Exception.Message)"
        }
    }

    if ($PassThru) {
        [pscustomobject]@{
            ComputerName               = $summary.ComputerName
            StartTime                  = $summary.StartTime
            EndTime                    = $summary.EndTime
            Duration                   = $summary.Duration
            TranscriptPath             = $summary.TranscriptPath
            ProvisionedPackagesRemoved = $summary.ProvisionedPackagesRemoved
            InstalledPackagesRemoved   = $summary.InstalledPackagesRemoved
            RegistryValuesSet          = $summary.RegistryValuesSet
            RegistryKeysRemoved        = $summary.RegistryKeysRemoved
            ScheduledTasksDisabled     = $summary.ScheduledTasksDisabled
            RestartRequested           = $summary.RestartRequested
            RestartTriggered           = $summary.RestartTriggered
            Errors                     = $summary.Errors.ToArray()
        }
    }
}
