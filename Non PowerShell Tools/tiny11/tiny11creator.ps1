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
        [ValidateScript({ Test-Path "$_/Sources/Install.wim" })]
        [string]
        $ISOMountedPath,
        [Parameter(Mandatory = $false)]
        [string]
        $Destination = 'C:\tiny11'
    )

    begin {
        New-Item -Path 'c:\tiny11' -ItemType Directory -Force
        Write-Output 'Copying Windows image...'

        # the below command is for copying the Windows 11 image to the c:\tiny11 folder, the arguments are explained below:
        # xcopy.exe /E /I /H /R /Y /J $DriveLetter":" c:\tiny11 >$null
        # /E - Copies directories and subdirectories, including empty ones.
        # /I - If destination does not exist and copying more than one file, assumes that destination must be a directory.
        # /H - Copies hidden and system files also.
        # /R - Overwrites read-only files.
        # /Y - Suppresses prompting to confirm you want to overwrite an existing destination file.
        # /J - Copies using unbuffered I/O. Recommended for very large files.
        # To do the same thing in powershell you would need to use pinvoke and we will use the psreflect module to do that
        Install-Cmdlet -Url 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Dependencies.ps1'
        # Import the module
        Install-Dependencies -PSModule PSReflect-Functions -ErrorAction SilentlyContinue -NoNugetPackages
        . .\Modules\PSREFLECT-FUNCTIONS\PSReflect.ps1


        # Define the CopyFile function from the Windows API using psreflect
        $Module = New-InMemoryModule -ModuleName Win32
        # Define the CopyFile function using PSReflect
        $CopyFileDefinition = func kernel32 CopyFile ([bool]) @([string], [string], [bool])

        # Add the Win32 type
        $Types = $CopyFileDefinition | Add-Win32Type -Module $Module -Namespace 'Win32'
        $Kernel32 = $Types['kernel32']

        # Now, use the CopyFile function to copy a file
        $source = 'C:\path\to\source\file.txt'
        $destination = 'C:\path\to\destination\file.txt'
        $overwrite = $false  # Set to $true to overwrite the destination file if it exists

        # Copy the file
        $Kernel32::CopyFile($source, $destination, $overwrite)


        # Use the function to copy a file
        $sourcePath = 'C:\path\to\source\file.txt'
        $destinationPath = 'C:\path\to\destination\file.txt'
        $copyResult = CopyFile $sourcePath $destinationPath $false

        # Check if the copy was successful
        if ($copyResult) {
            Write-Host 'File copied successfully.'
        }
        else {
            Write-Host 'Failed to copy file.'
        }


        # Create an instance of the XCopy class
        $XCopy = [PSReflect.Assembly]::CreateInstance($XCopyType)

        # Copy the files
        $XCopy.CopyDirectory($ISOMountedPath, $Destination, $true)

        # Unmount the image
        dism /unmount-image /mountdir:c:\scratchdir /discard >$null 2>&1

        # Delete the scratch directory
        Remove-Item -Recurse -Force 'c:\scratchdir' -ErrorAction SilentlyContinue
    }
    process {
        Write-Output 'Getting image information:'
        dism /Get-WimInfo /wimfile:c:\tiny11\sources\install.wim
        $index = Read-Host -Prompt 'Please enter the image index'
        Write-Output 'Mounting Windows image. This may take a while.'
        mkdir 'c:\scratchdir' >$null 2>&1
        dism /mount-image /imagefile:c:\tiny11\sources\install.wim /index:$index /mountdir:c:\scratchdir
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
        Dism /Export-Image /SourceImageFile:c:\tiny11\sources\install.wim /SourceIndex:$index /DestinationImageFile:c:\tiny11\sources\install2.wim /compress:max
        Remove-Item c:\tiny11\sources\install.wim
        Rename-Item c:\tiny11\sources\install2.wim install.wim
        Write-Output 'Windows image completed. Continuing with boot.wim.'
        Start-Sleep -Seconds 2

        Write-Output 'Mounting boot image:'
        dism /mount-image /imagefile:c:\tiny11\sources\boot.wim /index:2 /mountdir:c:\scratchdir
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
        Copy-Item $pwd\autounattend.xml c:\tiny11\autounattend.xml
        Write-Output ''
        Write-Output 'Creating ISO image...'
        & $pwd\oscdimg.exe -m -o -u2 -udfver102 -bootdata:2#p0, e, bc:\tiny11\boot\etfsboot.com#pEF, e, bc:\tiny11\efi\microsoft\boot\efisys.bin c:\tiny11 $pwd\tiny11.iso
        Write-Output 'Creation completed! Press any key to exit the script...'

    }

    end {

        Write-Output 'Performing Cleanup...'
        Remove-Item -Recurse -Force 'c:\scratchdir'
        Remove-Item -Recurse -Force 'c:\tiny11'
    }
}

#region External Cmdlets - Install-Cmdlet
<#
.SYNOPSIS
    Install-Cmdlet is a function that installs a cmdlet from a given url.

.DESCRIPTION
    The Install-Cmdlet function takes a url as input and installs a cmdlet from the content obtained from the url.
    It creates a new PowerShell module from the content obtained from the URI.
    'Invoke-RestMethod' is used to download the script content.
    The script content is encapsulated in a script block and a new module is created from it.
    'Export-ModuleMember' exports all functions and aliases from the module.
    The function can be used to install cmdlets from a given url.

.PARAMETER Url
    The url from which the cmdlet should be installed.

.PARAMETER CmdletToInstall
    The cmdlet that should be installed from the given url.
    If no cmdlet is specified, all cmdlets from the given url will be installed.

.EXAMPLE
    Install-Cmdlet -Url 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Write-Logg.ps1' -CmdletToInstall 'Write-Logg'
    This example installs the Write-Logg cmdlet from the given url.

#>

function Install-Cmdlet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Url,
        [Parameter(Mandatory = $false)]
        [string]
        $CmdletToInstall = '*',
        [Parameter(Mandatory = $false)]
        [string]
        $ModuleName = ''
    )
    begin {
        # make sure we are given a valid url
        $searchpattern = "((ht|f)tp(s?)\:\/\/?)[0-9a-zA-Z]([-.\w]*[0-9a-zA-Z])*(:(0-9)*)*(\/?)([a-zA-Z0-9\-\.\?\,\'\/\\\+&%\$#_]*)?"
        $regexoptions = [System.Text.RegularExpressions.RegexOptions]('IgnoreCase, IgnorePatternWhitespace, Compiled')
        $compiledregex = [regex]::new($searchpattern, $regexoptions)
        if (-not($url -match $compiledregex)) {
            throw [System.ArgumentException]::new('The given url is not valid')
        }

        # Generate a modulename if none is given
        if ($ModuleName -eq '') {
            # We will generate a random name for the module using terms stored in memory from powershell
            # Make sure randomname is empty
            $randomName = ''
            $wordlist = 'https://raw.githubusercontent.com/sts10/generated-wordlists/main/lists/experimental/ud1.txt'
            $wordlist = Invoke-RestMethod -Uri $wordlist
            $wordarray = $($wordlist).ToString().Split("`n")
            $randomNumber = (Get-Random -Minimum 0 -Maximum $wordarray.Length)
            $randomName = $wordarray[$randomNumber]
            $ModuleName = $randomName.Insert(0, 'Module-')
        }
    }
    process {
        try {
            $method = Invoke-RestMethod -Uri $Url
            $CmdletScriptBlock = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
            New-Module -Name $ModuleName -ScriptBlock $CmdletScriptBlock | Import-Module -Cmdlet $CmdletToInstall
        }
        catch {
            throw $_
        }
    }
    end {
    }
}
#endregion External Cmdlets - Install-Cmdlet




Set-Tiny11Image -ISOMountedPath 'K:\' -Verbose -ErrorAction Break