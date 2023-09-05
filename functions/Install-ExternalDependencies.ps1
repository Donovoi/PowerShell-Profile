<#
.SYNOPSIS
Installs external dependencies.

.DESCRIPTION
This function installs external dependencies required by the script.

.PARAMETER RemoveAllModules
Specifies whether to remove all existing modules before installation. By default, this is not enabled.
#>
function Install-ExternalDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [switch]$RemoveAllModules
    )

    try {
        # Auto-elevate permissions if we are not running as admin
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
            $arguments = "& '" + $myinvocation.mycommand.definition + "'"
            Start-Process powershell -Verb runAs -ArgumentList $arguments
            return
        }

        # Fix up the package providers
        # Install NuGet package provider if not already installed ( we basically pre install it everytime to do it silently)
        Find-PackageProvider -Name 'Nuget' -ForceBootstrap -IncludeDependencies -ErrorAction SilentlyContinue | Out-Null
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue | Out-Null) -or (-not (Get-PackageSource -ProviderName Nuget | Out-Null))) {
            Install-PackageProvider -Name NuGet -Force -Confirm:$false -ErrorAction SilentlyContinue -RequiredVersion 2.8.5.208 | Out-Null
            Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue | Out-Null
            Import-PackageProvider -Name nuget -RequiredVersion 2.8.5.208 -ErrorAction SilentlyContinue | Out-Null
            Register-PackageSource -Name 'NuGet' -Location 'https://www.nuget.org/api/v2' -ProviderName NuGet -Trusted -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }

        # Install PowerShellGet package provider if not already installed
        if (-not (Get-PackageProvider -Name PowerShellGet -ErrorAction SilentlyContinue | Out-Null)) {
            Install-PackageProvider -Name PowerShellGet -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }

        # trust all the things
        $packageSources = Get-PackageSource | Out-Null
        $packageSources | ForEach-Object {
            Set-PackageSource -Name $_.Name -Trusted -Force -ErrorAction SilentlyContinue | Out-Null
        }


        #Set Providers as trusted
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null


        # Load assemblies
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Data
        Add-Type -AssemblyName System.Data.DataSetExtensions
        Add-Type -AssemblyName System.Xml

        # Define dependencies
        $deps = @{
            'Interop.UIAutomationClient' = '10.19041.0'
            'FlaUI.Core'                 = '4.0.0'
            'FlaUI.UIA3'                 = '4.0.0'
            'HtmlAgilityPack'            = '1.11.50'
        }

        # Add NuGet dependencies
        Add-NuGetDependencies -NugetPackages $deps

        # Install modules
        # Create the module directory if it doesn't exist
        if (-not (Test-Path -Path "$PWD/PowerShellScriptsAndResources/Modules")) {
            New-Item -Path "$PWD/PowerShellScriptsAndResources/Modules" -ItemType Directory -Force
        }

        $neededmodules = @(
            'Microsoft.PowerShell.ConsoleGuiTools',
            'ImportExcel',
            'PSWriteColor',            
            'JWTDetails',
            '7zip4powershell',
            'PSEverything',
            'PSFramework',
            'Crescendo',
            'Microsoft.WinGet.Client'
        )

        if ($RemoveAllModules) {
            foreach ($module in $neededmodules) {
                $modulePath = Get-Module -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $module } -ErrorAction SilentlyContinue | Select-Object -Property Path
                Uninstall-Module -Name $module -Force -AllVersions -ErrorAction SilentlyContinue
                if ($null -ne $modulePath) {
                    Remove-Item (Split-Path (Split-Path $modulePath.Path -Parent -ErrorAction SilentlyContinue) -Parent -ErrorAction SilentlyContinue) -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        # for the write-log function we need to have pansies installed
        if (-not(Get-Module -Name 'Pansies' -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-Module -Name 'Pansies' -Force -Scope CurrentUser -ErrorAction SilentlyContinue
        }
        Import-Module -Name 'Pansies' -Force -Global -ErrorAction SilentlyContinue

        # Save modules locally then import them
        foreach ($module in $neededmodules) {
            if (-not (Get-Module -Name $module -ListAvailable) -and (-not (Get-ChildItem -Path "$PWD/PowerShellScriptsAndResources/Modules" -Filter "*$module*" -Recurse -ErrorAction SilentlyContinue))) {
                Write-Log -Message "Installing module $module" -Level VERBOSE
                # First save the module locally if we do not have the latest version
                Save-Module -Name $module -Path "$PWD/PowerShellScriptsAndResources/Modules" -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Log -Message "Module $module already installed" -Level VERBOSE
            }
            Import-Module -Name 'Pansies' -Force -Global -ErrorAction SilentlyContinue
            $ModulesToImport = Get-ChildItem -Path "$PWD/PowerShellScriptsAndResources/Modules" -Include '*.psm1', '*.psd1' -Recurse
            Import-Module -Name $ModulesToImport -Force -Global -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log -Message "An error occurred: $_" -Level ERROR
        Write-Log -Message "Error details: $($_.Exception)" -Level ERROR
    }
}