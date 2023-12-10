<#
.SYNOPSIS
    Short description
.DESCRIPTION
    Long description
.EXAMPLE
    Example of how to use this cmdlet
.EXAMPLE
    Another example of how to use this cmdlet
#>
function Set-Tiny11Image {
    [CmdletBinding()]
    [OutputType([type])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path "$_" })]
        [string]
        $UnmountedISOPath,
        [Parameter(Mandatory = $false)]
        [string]
        $Destination = 'C:\tiny11'
    )

    begin {
        # Mount the ISO
        $DriveLetter = Mount-DiskImage -ImagePath $UnmountedISOPath -PassThru | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -ExpandProperty DriveLetter
        if (-not $DriveLetter) {
            Write-Output 'Failed to mount the ISO. Please try again.'
            exit
        }
        Write-Output "ISO mounted to $DriveLetter`:"

        # Create the destination folder
        New-Item -Path $Destination -ItemType Directory -Force
        Write-Output 'Copying Windows image...'

        # the below command is for copying the Windows 11 image to the c:\tiny11 folder, the arguments are explained below:
        # xcopy.exe /E /I /H /R /Y /J $DriveLetter":" c:\tiny11 >$null
        # /E - Copies directories and subdirectories, including empty ones.
        # /I - If destination does not exist and copying more than one file, assumes that destination must be a directory.
        # /H - Copies hidden and system files also.
        # /R - Overwrites read-only files.
        # /Y - Suppresses prompting to confirm you want to overwrite an existing destination file.
        # /J - Copies using unbuffered I/O. Recommended for very large files.
        # robocopy version is below:
        #robocopy.exe $DriveLetter":\" c:\tiny11 /E /COPYALL /R:0 /W:0 /MT:8 /J /NP /NFL /NDL /NJH /NJS /NC /NS /NP /LOG+:c:\tiny11\robocopy.log
        # the robocopy arguments are explained below:
        # /E - Copies directories and subdirectories, including empty ones.
        # /COPYALL - Copies all file information (equivalent to /COPY:DATSOU).
        # /R:0 - Specifies the number of retries on failed copies. The default value of N is 1,000,000 (one million retries).
        # /W:0 - Specifies the wait time between retries, in seconds. The default value of N is 30 (wait time 30 seconds).
        # /MT:8 - Creates multi-threaded copies with N threads. N must be an integer between 1 and 128. The default value for N is 8.
        # /J - Copies using unbuffered I/O. Recommended for very large files.
        # /NP - Specifies that the progress of the copying operation (the number of files or directories copied so far) will not be displayed.
        # /NFL - Specifies that file names are not to be logged.
        # /NDL - Specifies that directory names are not to be logged.
        # /NJH - Specifies that there is no job header.
        # /NJS - Specifies that there is no job summary.
        # /NC - Specifies that file classes are not to be logged.
        # /NS - Specifies that file sizes are not to be logged.
        # /NP - Specifies that the progress of the copying operation (the number of files or directories copied so far) will not be displayed.
        # /LOG+:c:\tiny11\robocopy.log - Specifies that the results of the copying operation are to be logged, appending the output to the existing log file.
        xcopy.exe /E /I /H /R /Y /J $DriveLetter":" $Destination >$null
        # Delete the old scratch directory
        Remove-Item -Recurse -Force 'c:\scratchdir' -ErrorAction SilentlyContinue
    }
    process {
        Write-Output 'Getting image information:'
        dism /Get-WimInfo /wimfile:$Destination\sources\install.wim
        $index = Read-Host -Prompt 'Please enter the image index'
        Write-Output 'Mounting Windows image. This may take a while.'
        mkdir 'c:\scratchdir' >$null 2>&1
        dism /mount-image /imagefile:$Destination\sources\install.wim /index:10 /mountdir:c:\scratchdir
        Write-Output 'Mounting complete! Performing removal of applications...'
        $appxfind = 'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GamingApp', `
            'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub', `
            'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop', `
            'Microsoft.Todos', 'Microsoft.WindowsAlarms', 'microsoft.windowscommunicationsapps', `
            'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.WindowsSoundRecorder', `
            'Microsoft.Xbox.TCUI', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay', `
            'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.YourPhone', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', `
            'MicrosoftCorporationII.MicrosoftFamily', 'MicrosoftCorporationII.QuickAssist', 'MicrosoftTeams', `
            'Microsoft.549981C3F5F10'
        $appxlist = dism /image:c:\scratchdir /Get-ProvisionedAppxPackages | Select-String -Pattern 'PackageName : ' -CaseSensitive -SimpleMatch
        $appxlist = $appxlist -split 'PackageName : ' | Where-Object { $_ }

        foreach ( $appxlookup in $appxfind ) {
            Write-Output "Finding $appxlookup ..."
            $appxremove = $appxlist | Select-String -Pattern $appxlookup -CaseSensitive -SimpleMatch
            foreach ( $appx in $appxremove ) {
                Write-Output "Removing $appx"
                dism /image:c:\scratchdir /Remove-ProvisionedAppxPackage /PackageName:$appx >$null
            }
            if ( -not ( $appxremove ) ) {
                Write-Output "$appxlookup was not found!"
            }
        }

        Write-Output 'Removing of system apps complete! Now proceeding to removal of system packages...'
        Start-Sleep -Seconds 1

        $packagefind = 'Microsoft-Windows-InternetExplorer-Optional-Package', 'Microsoft-Windows-Kernel-LA57-FoD-Package', `
            'Microsoft-Windows-LanguageFeatures-Handwriting', 'Microsoft-Windows-LanguageFeatures-OCR', `
            'Microsoft-Windows-LanguageFeatures-Speech', 'Microsoft-Windows-LanguageFeatures-TextToSpeech', `
            'Microsoft-Windows-MediaPlayer-Package', 'Microsoft-Windows-TabletPCMath-Package', `
            'Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package'
        $packagelist = dism /image:c:\scratchdir /Get-Packages /Format:List | Select-String -Pattern 'Package Identity : ' -CaseSensitive -SimpleMatch
        $packagelist = $packagelist -split 'Package Identity : ' | Where-Object { $_ }

        foreach ( $packagelookup in $packagefind ) {
            Write-Output "Finding $packagelookup ..."
            $packageremove = $packagelist | Select-String -Pattern $packagelookup -CaseSensitive -SimpleMatch
            foreach ( $package in $packageremove ) {
                Write-Output "Removing $package"
                dism /image:c:\scratchdir /Remove-Package /PackageName:$package >$null
            }
            if ( -not ( $packageremove ) ) {
                Write-Output "$packagelookup was not found!"
            }
        }

        Write-Output 'Removing Edge:'
        Remove-Item -Recurse -Force 'C:\scratchdir\Program Files (x86)\Microsoft\Edge'
        Remove-Item -Recurse -Force 'C:\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate'
        Write-Output 'Removing OneDrive:'
        takeown /f C:\scratchdir\Windows\System32\OneDriveSetup.exe
        icacls C:\scratchdir\Windows\System32\OneDriveSetup.exe /grant Administrators:F /T /C
        Remove-Item -Force 'C:\scratchdir\Windows\System32\OneDriveSetup.exe'
        Write-Output 'Removal complete!'
        Start-Sleep -Seconds 2

        Write-Output 'Loading registry...'
        reg load HKLM\zCOMPONENTS 'c:\scratchdir\Windows\System32\config\COMPONENTS' >$null
        reg load HKLM\zDEFAULT 'c:\scratchdir\Windows\System32\config\default' >$null
        reg load HKLM\zNTUSER 'c:\scratchdir\Users\Default\ntuser.dat' >$null
        reg load HKLM\zSOFTWARE 'c:\scratchdir\Windows\System32\config\SOFTWARE' >$null
        reg load HKLM\zSYSTEM 'c:\scratchdir\Windows\System32\config\SYSTEM' >$null
        Write-Output 'Bypassing system requirements(on the system image):'
        Reg add 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV1' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV2' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV1' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV2' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassCPUCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassRAMCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassSecureBootCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassStorageCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassTPMCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\MoSetup' /v 'AllowUpgradesWithUnsupportedTPMOrCPU' /t REG_DWORD /d '1' /f >$null 2>&1
        Write-Output 'Disabling Teams:'
        Reg add 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Communications' /v 'ConfigureChatAutoInstall' /t REG_DWORD /d '0' /f >$null 2>&1
        Write-Output 'Disabling Sponsored Apps:'
        Reg add 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'OemPreInstalledAppsEnabled' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'PreInstalledAppsEnabled' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SilentInstalledAppsEnabled' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' /v 'DisableWindowsConsumerFeatures' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' /v 'ConfigureStartPins' /t REG_SZ /d '{\'pinnedList\": [{}]}" /f >$null 2>&1
        Write-Output 'Enabling Local Accounts on OOBE:'
        Reg add 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' /v 'BypassNRO' /t REG_DWORD /d '1' /f >$null 2>&1
        Copy-Item $pwd\autounattend.xml c:\scratchdir\Windows\System32\Sysprep\autounattend.xml
        Write-Output 'Disabling Reserved Storage:'
        Reg add 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' /v 'ShippedWithReserves' /t REG_DWORD /d '0' /f >$null 2>&1
        Write-Output 'Disabling Chat icon:'
        Reg add 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' /v 'ChatIcon' /t REG_DWORD /d '3' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v 'TaskbarMn' /t REG_DWORD /d '0' /f >$null 2>&1
        Write-Output 'Tweaking complete!'
        Write-Output 'Unmounting Registry...'
        reg unload HKLM\zCOMPONENTS >$null 2>&1
        reg unload HKLM\zDRIVERS >$null 2>&1
        reg unload HKLM\zDEFAULT >$null 2>&1
        reg unload HKLM\zNTUSER >$null 2>&1
        reg unload HKLM\zSCHEMA >$null 2>&1
        reg unload HKLM\zSOFTWARE >$null 2>&1
        reg unload HKLM\zSYSTEM >$null 2>&1
        Write-Output 'Cleaning up image...'
        dism /image:c:\scratchdir /Cleanup-Image /StartComponentCleanup /ResetBase
        Write-Output 'Cleanup complete.'
        Write-Output 'Unmounting image...'
        dism /unmount-image /mountdir:c:\scratchdir /commit
        Write-Output 'Exporting image...'
        Dism /Export-Image /SourceImageFile:$Destination\sources\install.wim /SourceIndex:$index /DestinationImageFile:$Destination\sources\install2.wim /compress:max
        Remove-Item $Destination\sources\install.wim
        Rename-Item $Destination\sources\install2.wim install.wim
        Write-Output 'Windows image completed. Continuing with boot.wim.'
        Start-Sleep -Seconds 2

        Write-Output 'Mounting boot image:'
        dism /mount-image /imagefile:$Destination\sources\boot.wim /index:2 /mountdir:c:\scratchdir
        Write-Output 'Loading registry...'
        reg load HKLM\zCOMPONENTS 'c:\scratchdir\Windows\System32\config\COMPONENTS' >$null
        reg load HKLM\zDEFAULT 'c:\scratchdir\Windows\System32\config\default' >$null
        reg load HKLM\zNTUSER 'c:\scratchdir\Users\Default\ntuser.dat' >$null
        reg load HKLM\zSOFTWARE 'c:\scratchdir\Windows\System32\config\SOFTWARE' >$null
        reg load HKLM\zSYSTEM 'c:\scratchdir\Windows\System32\config\SYSTEM' >$null
        Write-Output 'Bypassing system requirements(on the setup image):'
        Reg add 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV1' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV2' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV1' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV2' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassCPUCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassRAMCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassSecureBootCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassStorageCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassTPMCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\MoSetup' /v 'AllowUpgradesWithUnsupportedTPMOrCPU' /t REG_DWORD /d '1' /f >$null 2>&1
        Write-Output 'Tweaking complete!'
        Write-Output 'Unmounting Registry...'
        reg unload HKLM\zCOMPONENTS >$null 2>&1
        reg unload HKLM\zDRIVERS >$null 2>&1
        reg unload HKLM\zDEFAULT >$null 2>&1
        reg unload HKLM\zNTUSER >$null 2>&1
        reg unload HKLM\zSCHEMA >$null 2>&1
        reg unload HKLM\zSOFTWARE >$null 2>&1
        reg unload HKLM\zSYSTEM >$null 2>&1
        Write-Output 'Unmounting image...'
        dism /unmount-image /mountdir:c:\scratchdir /commit

        Write-Output 'the tiny11 image is now completed. Proceeding with the making of the ISO...'
        Write-Output 'Copying unattended file for bypassing MS account on OOBE...'
        Copy-Item $pwd\autounattend.xml $Destination\autounattend.xml
        Write-Output ''
        Write-Output 'Creating ISO image...'
        cmd.exe /c "oscdimg.exe -m -n -o -d 'c:\tiny11' 'C:\Users\torro\tintiny11.iso'"
        Write-Output 'Creation completed! Press any key to exit the script...'

    }

    end {

        Write-Output 'Performing Cleanup...'
        Remove-Item -Recurse -Force 'c:\scratchdir'
        Remove-Item -Recurse -Force $Destination
    }
}
Push-Location '.\Non PowerShell Tools\tiny11'
Set-Tiny11Image -UnmountedISOPath "$env:USERPROFILE\Desktop\25997.iso" -Verbose -ErrorAction continue