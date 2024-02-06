<#
.SYNOPSIS
    # This is an advanced function to install wsa and google play, and google translate, with all languages on an offline system, this will need an online system in order to download the required files.
# The goal is to be declarative and idempotent, so it can be run multiple times without causing any issues.
.DESCRIPTION
    Long description
.EXAMPLE
    Example of how to use this cmdlet
.EXAMPLE
    Another example of how to use this cmdlet
#>
function Get-WSASetup {
    [CmdletBinding()]
    [OutputType([type])]
    param(
        [Parameter(Mandatory = $false)]
        [string]
        $InstallFolder = 'C:\WSA'
    )
    # load my Install-cmdlet function into memory so we can install other cmdlets
    if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
        $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
        $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
        New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
    }
    $cmdlets = @('Write-Logg', 'Install-Dependencies')

    Write-Verbose -Message "Importing cmdlets: $cmdlets"
    $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $cmdlets
    $Cmdletstoinvoke | Import-Module -Force

    Write-Logg -Message 'Starting the WSA setup' -Level Info

    # Install winget powershell module
    if (-not (Get-Command -Name 'Install-WinGetPackage' -ErrorAction SilentlyContinue)) {
        Write-Logg -Message 'Installing winget PowerShell Module' -Level Info
        Install-Dependencies -InstallDefaultPSModules -InstallDefaultNugetPackages -AddDefaultAssemblies
    }

    #  check if git is installed, if not install it
    if (-not (Test-Path -Path 'C:\Program Files\Git\cmd\git.exe')) {
        Write-Output 'Git is not installed, installing it now'
        Install-WinGetPackage -Name 'Git' -Source 'Microsoft' -Force
    }
    if (-not(Get-Command -Name 'git' -ErrorAction SilentlyContinue)) {
        # We may need to refresh the environment variables
        Write-Log -Message 'Git is not in the path, adding it now' -Level Info
        $env:Path += ';C:\Program Files\Git\cmd'

        if (-not(Get-Command -Name 'git' -ErrorAction SilentlyContinue)) {
            Write-logg -Message 'Git is still not in the path, please start a new PowerShell Window' -Level Error
            exit
        }

    }
    # Install Ubuntu on WSL
    Write-Logg -Message 'Installing Ubuntu on WSL' -Level Info
    Get-WinGetPackage -Id 'Canonical.Ubuntu.2204' -Force
    Install-WinGetPackage -Id 'Canonical.Ubuntu.2204' -Mode Silent -Location $InstallFolder -Version '2204.1.7.0' -Force
    $wslubuntulatestpackage = Find-WinGetPackage -Name Ubuntu | Where-Object -FilterScript { $_.Id -like 'Can*' } | Sort-Object -Property $_.Version -Descending | Select-Object -First 1
    $wslubuntulatestpackage | Install-WinGetPackage -Mode Silent -Location $InstallFolder -Force
    # wsl --install -d Ubuntu --web-download -o


    # Following the instructions from https://github.com/LSPosed/MagiskOnWSALocal#
    # Install location is $InstallFolder
    if (-not (Test-Path -Path $InstallFolder)) {
        Write-Logg -Message "Creating the install folder: $InstallFolder" -Level Info
        New-Item -Path $InstallFolder -ItemType Directory -Force
    }
    Write-Logg -Message "Cloning the MagiskOnWSALocal repository to $InstallFolder" -Level Info
    git clone 'https://github.com/LSPosed/MagiskOnWSALocal.git' --depth 1 $InstallFolder
    
    <#
    Next steps:
    Run cd MagiskOnWSALocal.

Run ./scripts/run.sh.

Select the WSA version and its architecture (mostly x64).

Select the version of Magisk.

Choose which brand of GApps you want to install:

MindTheGapps

There is no other variant we can choose.

Select the root solution (none means no root).

If you are running the script for the first time, it will take some time to complete. After the script completes, two new folders named output and download will be generated in the MagiskOnWSALocal folder. Go to the output folder. While running the ./run.sh script in the step 3, if you selected Yes for Do you want to compress the output? then in output folder you will see a compressed file called WSA-with-magisk-stable-MindTheGapps_2207.40000.8.0_x64_Release-Nightlyor else there will be folder with the WSA-with-magisk-stable-MindTheGapps_2207.40000.8.0_x64_Release-Nightly. If there is a folder open it and skip to step 10. NOTE: The name of compressed file or the folder generated in the output folder may be different for you. It will be dependent on the choices made when executing ./run.sh.

Extract the compressed file and open the folder created after the extraction of the file.

Here look for file Run.bat and run it.

If you previously have a MagiskOnWSA installation, it will automatically uninstall the previous one while preserving all user data and install the new one, so don't worry about your data.
If you have an official WSA installation, you should uninstall it first. (In case you want to preserve your data, you can backup %LOCALAPPDATA%\Packages\MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe\LocalCache\userdata.vhdx before uninstallation and restore it after installation.)
If the popup windows disappear without asking administrative permission and WSA is not installed successfully, you should manually run Install.ps1 as Administrator:
Press Win+x and select Windows Terminal (Admin).
Input cd "{X:\path\to\your\extracted\folder}" and press enter, and remember to replace {X:\path\to\your\extracted\folder} including the {}, for example cd "D:\wsa"
Input PowerShell.exe -ExecutionPolicy Bypass -File .\Install.ps1 and press Enter.
The script will run and WSA will be installed.
If this workaround does not work, your PC is not supported for WSA.
Magisk/Play Store will be launched. Enjoy by installing LSPosed-Zygisk with Zygisk enabled or Riru and LSPosed-Riru.
    #>

    Push-Location -Path "$InstallFolder\MagiskOnWSALocal"
    Write-Logg -Message 'Running the MagiskOnWSALocal setup' -Level Info
    .\scripts\run.sh
}