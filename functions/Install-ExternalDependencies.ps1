<#
.SYNOPSIS
Installs external dependencies.

.DESCRIPTION
This function installs external dependencies required by the script. It can install NuGet packages and PowerShell modules.

.PARAMETER RemoveAllModules
Specifies whether to remove all existing modules before installation.

.PARAMETER PSModules
An array of PowerShell modules to install.

.PARAMETER NugetPackages
An array of NuGet packages to install.

.PARAMETER NoPSModules
If set, skips installing PowerShell modules.

.PARAMETER NoNugetPackages
If set, skips installing NuGet packages.

.PARAMETER InstallDefaultPSModules
If set, installs default PowerShell modules.

.PARAMETER InstallDefaultNugetPackages
If set, installs default NuGet packages.

.PARAMETER LocalModulesDirectory
Specifies the directory where to save the PowerShell modules locally. If null or empty, modules will be saved to the default directory.
#>
function Install-ExternalDependencies {
    [CmdletBinding()]
    param(
        [switch]$RemoveAllModules,
        [string[]]$PSModules,
        [string[]]$NugetPackages,
        [switch]$NoPSModules,
        [switch]$NoNugetPackages,
        [switch]$InstallDefaultPSModules,
        [switch]$InstallDefaultNugetPackages,
        [string]$LocalModulesDirectory
    )

    # Run as admin
    RunAsAdmin

    # Setup package providers
    SetupPackageProviders

    # Install NuGet dependencies
    if (-not $NoNugetPackages ) {
        InstallNugetDeps $InstallDefaultNugetPackages $NugetPackages
    }

    # Install PowerShell modules
    if (-not $NoPSModules) {
        Install-PSModules -InstallDefaultPSModules:$InstallDefaultPSModules -PSModules:$PSModules -RemoveAllModules:$RemoveAllModules -LocalModulesDirectory:$LocalModulesDirectory  
    }

    # refresh environment variables
    Update-SessionEnvironment
    
}


function RunAsAdmin {
    # Check if the current user is an administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    # If not an admin, relaunch the script as an admin
    if (-not $isAdmin) {
        $scriptPath = $myinvocation.mycommand.definition
        $arguments = "& '$scriptPath'"
        Start-Process -FilePath 'powershell' -Verb 'RunAs' -ArgumentList $arguments
        exit
    }
}

function SetupPackageProviders {
    try {
        # Ensure NuGet package provider is installed and registered
        if (-not(Get-Module -Name 'PackageManagement' -ListAvailable -ErrorAction SilentlyContinue)) {
            # Define the URL for the latest PackageManagement nupkg
            $nugetUrl = "https://www.powershellgallery.com/api/v2/package/PackageManagement"

            # Define the download path
            $downloadPath = Join-Path $env:TEMP "PackageManagement.zip"

            # Download the nupkg file
            Invoke-WebRequest -Uri $nugetUrl -OutFile $downloadPath

            # Define the extraction path
            $extractPath = Join-Path $env:TEMP "PackageManagement"

            # Create the extraction directory if it doesn't exist
            if (Test-Path $extractPath) {
                Remove-Item -Path $extractPath -Recurse -Force
            }
            New-Item -Path $extractPath -ItemType Directory

            # Extract the nupkg (it's just a zip file)
            Expand-Archive -Path $downloadPath -DestinationPath $extractPath -Force

            # Find the DLL path
            $dllPath = Get-ChildItem -Path $extractPath -Recurse -Filter "PackageManagement.dll" | Select-Object -First 1 -ExpandProperty FullName

            # Import the module
            Import-Module $dllPath

            # Test to see if it's working
            Get-Command -Module PackageManagement

            # Clean up
            Remove-Item -Path $downloadPath
            Remove-Item -Path $extractPath -Recurse


        }
        Find-PackageProvider -Name 'Nuget' -ForceBootstrap -IncludeDependencies -ErrorAction SilentlyContinue | Out-Null
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Confirm:$false -ErrorAction SilentlyContinue -RequiredVersion 2.8.5.208 | Out-Null
            Import-PackageProvider -Name nuget -RequiredVersion 2.8.5.208 -ErrorAction SilentlyContinue | Out-Null
            Register-PackageSource -Name 'NuGet' -Location 'https://www.nuget.org/api/v2' -ProviderName NuGet -Trusted -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    
        # Ensure PowerShellGet package provider is installed
        if (-not (Get-PackageProvider -Name PowerShellGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name PowerShellGet -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    
        # Trust all package sources
        Get-PackageSource | ForEach-Object {
            Set-PackageSource -Name $_.Name -Trusted -Force -ErrorAction SilentlyContinue | Out-Null
        }
    
        # Trust PSGallery repository
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
    
        # Ensure Pansies module is installed for logging
        if (-not (Get-Module -Name 'Pansies' -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-Module -Name 'Pansies' -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
        }
        Import-Module -Name 'Pansies' -Force -Global -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Host "An error occurred while setting up package providers: $_"
    }
}    

function AddAssemblies ([bool]$UseDefault, [string[]]$CustomAssemblies) {
    # Initialize the list of assemblies to add
    $assembliesToAdd = if ($UseDefault) {
        @(
            'PresentationFramework',
            'PresentationCore',
            'WindowsBase',
            'System.Windows.Forms',
            'System.Drawing',
            'System.Data',
            'System.Data.DataSetExtensions',
            'System.Xml'
        )
    }
    else {
        $CustomAssemblies
    }
    
    # Add each assembly
    foreach ($assembly in $assembliesToAdd) {
        try {
            Add-Type -AssemblyName $assembly -ErrorAction Stop
            Write-Host "Successfully added assembly: $assembly"
        }
        catch {
            Write-Host "Failed to add assembly: $assembly. Error: $_"
        }
    }
}
    

function InstallNugetDeps ([bool]$InstallDefault, [string[]]$NugetPackages) {
    try {
        # Determine which NuGet packages are needed based on the InstallDefault flag
        $deps = if ($InstallDefault) {
            @{
                'Interop.UIAutomationClient' = '10.19041.0'
                'FlaUI.Core'                 = '4.0.0'
                'FlaUI.UIA3'                 = '4.0.0'
                'HtmlAgilityPack'            = '1.11.50'
            }
        }
        else {
            $NugetPackages
        }
    
        # Log the installation process (assumes you have a custom logging function)
        Write-Host "Installing NuGet dependencies"
    
        # Install NuGet packages
        Add-NuGetDependencies -NugetPackages $deps
    }
    catch {
        # Log any errors that occur during the installation
        Write-Host "An error occurred while installing NuGet packages: $_"
    }
}
    

function Install-PSModules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [bool]$InstallDefaultPSModules,

        [Parameter(Mandatory = $false)]
        [string[]]$PSModules,

        [Parameter(Mandatory = $false)]
        [bool]$RemoveAllModules,

        [Parameter(Mandatory = $false)]
        [string]$LocalModulesDirectory
    )

    begin {
        # Not yet used
    }

    process {
        try {
            # Determine which modules are needed based on the InstallDefaultPSModules flag
            $neededModules = if ($InstallDefaultPSModules) {
                @(
                    'Microsoft.PowerShell.ConsoleGuiTools',
                    'ImportExcel',
                    'PSWriteColor',
                    'JWTDetails',
                    '7zip4powershell',
                    'PSEverything',
                    'PSFramework',
                    'Crescendo',
                    'Microsoft.WinGet.Client',
                    'Microsoft.PowerShell.SecretManagement',
                    'Microsoft.PowerShell.SecretStore'
                )
            }
            else {
                $PSModules
            }

            # Uninstall modules if RemoveAllModules flag is set
            if ($RemoveAllModules) {
                $installedModules = Get-Module -ListAvailable
                $installedModules | ForEach-Object {
                    if ($_.Name -in $neededModules) {
                        Write-Host "Removing module $($_.Name)"
                        Remove-Module -Name $_.Name -Force -Confirm:$false -ErrorAction SilentlyContinue
                        Uninstall-Module -Name $_.Name -Force -AllVersions -ErrorAction SilentlyContinue
                        if ($null -ne $_.InstalledLocation) {
                            Remove-Item $_.InstalledLocation -Recurse -Force -ErrorAction SilentlyContinue
                        }
                        else {
                            Write-Host "InstalledLocation is empty for module $($_.Name). Skipping removal."
                        }
                        
                    }
                }
            }

            # Install and import modules
            $neededModules.ForEach({
                    try {
                        # Check if the module is already installed
                        if (-not (Get-Module -Name $_ -ListAvailable)) {
                            Write-Host "Installing module $_"
                
                            # Save the module locally only if LocalModulesDirectory is not null or empty
                            if (-not([string]::IsNullOrEmpty($LocalModulesDirectory))) {
                                Save-Module -Name $_ -Path "$PWD/PowerShellScriptsAndResources/Modules" -Force -ErrorAction SilentlyContinue
                            }

                            # Install module
                            Install-Module -Name $_ -Force -Confirm:$false -ErrorAction SilentlyContinue -Scope CurrentUser
                        }
                        else {
                            Write-Host "Module $_ already installed"
                        }

                        # Import modules from local directory if LocalModulesDirectory is not null or empty
                        if ([string]::IsNullOrEmpty($LocalModulesDirectory)) {
                            # Import module by name
                            Import-Module -Name $_ -Force -Global -ErrorAction SilentlyContinue
                        }
                        else {
                            # Import all saved modules from local directory
                            $modulesToImport = Get-ChildItem -Path "$PWD/PowerShellScriptsAndResources/Modules" -Include '*.psm1', '*.psd1' -Recurse
                            Import-Module -Name $modulesToImport -Force -Global -ErrorAction SilentlyContinue
                        }
                    }
                    catch {
                        Write-Host "An error occurred while processing module $_`: $($_.Exception)"
                    }
                })
        }
        catch {
            if ($_.Exception.Message -match '.ps1xml') {
                Write-Host "Caught a global error related to a missing .ps1xml file. Deleting and reinstalling affected module."
                $moduleDir = Split-Path (Split-Path $_.Exception.TargetObject -Parent) -Parent
                Remove-Item $moduleDir -Recurse -Force
                Install-Module -Name (Split-Path $moduleDir -Leaf) -Force
            }
            else {
                Write-Host "An unexpected global error occurred: $_"
            }
        }
    }

    end {
        # Not yet used
    }
}

function Update-SessionEnvironment {    
    $refreshEnv = $false
    $invocation = $MyInvocation
    if ($invocation.InvocationName -eq 'refreshenv') {
        $refreshEnv = $true
    }

    if ($refreshEnv) {
        Write-Output 'Refreshing environment variables from the registry for powershell.exe. Please wait...'
    }
    else {
        Write-Verbose 'Refreshing environment variables from the registry.'
    }

    $userName = $env:USERNAME
    $architecture = $env:PROCESSOR_ARCHITECTURE
    $psModulePath = $env:PSModulePath

    #ordering is important here, $user should override $machine...
    $ScopeList = 'Process', 'Machine'
    if ('SYSTEM', "${env:COMPUTERNAME}`$" -notcontains $userName) {
        # but only if not running as the SYSTEM/machine in which case user can be ignored.
        $ScopeList += 'User'
    }
    foreach ($Scope in $ScopeList) {
        Get-EnvironmentVariableNames -Scope $Scope |
            ForEach-Object {
                Set-Item "Env:$_" -Value (Get-EnvironmentVariable -Scope $Scope -Name $_)
            }
    }

    #Path gets special treatment b/c it munges the two together
    $paths = 'Machine', 'User' |
        ForEach-Object {
    (Get-EnvironmentVariable -Name 'PATH' -Scope $_) -split ';'
        } |
            Select-Object -Unique
    $Env:PATH = $paths -join ';'

    # PSModulePath is almost always updated by process, so we want to preserve it.
    $env:PSModulePath = $psModulePath

    # reset user and architecture
    if ($userName) {
        $env:USERNAME = $userName
    }
    if ($architecture) {
        $env:PROCESSOR_ARCHITECTURE = $architecture
    }

    if ($refreshEnv) {
        Write-Output 'Finished'
    }
}

function Get-EnvironmentVariable {

    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][System.EnvironmentVariableTarget] $Scope,
        [Parameter(Mandatory = $false)][switch] $PreserveVariables = $false,
        [parameter(ValueFromRemainingArguments = $true)][Object[]] $ignoredArguments
    )

    [string] $MACHINE_ENVIRONMENT_REGISTRY_KEY_NAME = "SYSTEM\CurrentControlSet\Control\Session Manager\Environment\"
    [Microsoft.Win32.RegistryKey] $win32RegistryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($MACHINE_ENVIRONMENT_REGISTRY_KEY_NAME)
    if ($Scope -eq [System.EnvironmentVariableTarget]::User) {
        [string] $USER_ENVIRONMENT_REGISTRY_KEY_NAME = "Environment"
        [Microsoft.Win32.RegistryKey] $win32RegistryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($USER_ENVIRONMENT_REGISTRY_KEY_NAME)
    }
    elseif ($Scope -eq [System.EnvironmentVariableTarget]::Process) {
        return [Environment]::GetEnvironmentVariable($Name, $Scope)
    }

    [Microsoft.Win32.RegistryValueOptions] $registryValueOptions = [Microsoft.Win32.RegistryValueOptions]::None

    if ($PreserveVariables) {
        Write-Verbose "Choosing not to expand environment names"
        $registryValueOptions = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    }

    [string] $environmentVariableValue = [string]::Empty

    try {
        #Write-Verbose "Getting environment variable $Name"
        if ($null -ne $win32RegistryKey) {
            # Some versions of Windows do not have HKCU:\Environment
            $environmentVariableValue = $win32RegistryKey.GetValue($Name, [string]::Empty, $registryValueOptions)
        }
    }
    catch {
        Write-Debug "Unable to retrieve the $Name environment variable. Details: $_"
    }
    finally {
        if ($null -ne $win32RegistryKey) {
            $win32RegistryKey.Close()
        }
    }

    if ($null -eq $environmentVariableValue -or $environmentVariableValue -eq '') {
        $environmentVariableValue = [Environment]::GetEnvironmentVariable($Name, $Scope)
    }

    return $environmentVariableValue
}

function Get-EnvironmentVariableNames([System.EnvironmentVariableTarget] $Scope) {

    # HKCU:\Environment may not exist in all Windows OSes (such as Server Core).
    switch ($Scope) {
        'User' {
            Get-Item 'HKCU:\Environment' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Property
        }
        'Machine' {
            Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' | Select-Object -ExpandProperty Property
        }
        'Process' {
            Get-ChildItem Env:\ | Select-Object -ExpandProperty Key
        }
        default {
            throw "Unsupported environment scope: $Scope"
        }
    }
}


