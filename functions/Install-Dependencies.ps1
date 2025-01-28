function Install-Dependencies {
    [CmdletBinding()]
    param(
        [switch]$RemoveAllModules,
        [string[]]$PSModule,
        [hashtable]$NugetPackage,
        [switch]$NoPSModules,
        [switch]$NoNugetPackage,
        [switch]$InstallDefaultPSModules,
        [switch]$InstallDefaultNugetPackage,
        [switch]$AddDefaultAssemblies,
        [string[]]$AddCustomAssemblies,
        [string]$LocalModulesDirectory,
        [switch]$SaveLocally
    )

    # Run as admin
    RunAsAdmin

    # Import the required cmdlets
    $neededcmdlets = @('Get-FileDownload', 'Add-FileToAppDomain', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Write-InformationColored')
    $neededcmdlets | ForEach-Object {
        if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose -Message "Importing cmdlet: $_"
            $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
            $Cmdletstoinvoke | Import-Module -Force
        }
    }

    # Setup package providers
    Install-PackageProviders

    # Install NuGet dependencies
    if (-not $NoNugetPackage ) {
        $null = Install-NugetDeps -InstallDefaultNugetPackage:$InstallDefaultNugetPackage -NugetPackage:$NugetPackage -SaveLocally:$SaveLocally -LocalModulesDirectory:$LocalModulesDirectory
        # refresh environment variables
        Update-SessionEnvironment
    }

    # Add assemblies
    if ($AddDefaultAssemblies -or $AddCustomAssemblies) {
        $null = Add-Assemblies -UseDefault:$AddDefaultAssemblies -CustomAssemblies:$AddCustomAssemblies
        # refresh environment variables
        Update-SessionEnvironment
    }

    # Install PowerShell modules
    if (-not $NoPSModules) {
        $null = Install-PSModule -InstallDefaultPSModules:$InstallDefaultPSModules -PSModule:$PSModule -RemoveAllModules:$RemoveAllModules -LocalModulesDirectory:$LocalModulesDirectory
        # refresh environment variables
        Update-SessionEnvironment
    }

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

function Install-PackageProviders {
    [CmdletBinding()]
    param (

    )
    try {
        # Ensure NuGet package provider is installed and registered
        if (-not(Get-Module -Name 'PackageManagement' -ListAvailable -ErrorAction SilentlyContinue)) {
            # Define the URL for the latest PackageManagement nupkg
            $nugetUrl = 'https://www.powershellgallery.com/api/v2/package/PackageManagement'

            # Define the download path
            $downloadPath = Join-Path $env:TEMP 'PackageManagement.zip'

            # Download the nupkg file
            Invoke-WebRequest -Uri $nugetUrl -OutFile $downloadPath

            # Define the extraction path
            $extractPath = Join-Path $env:TEMP 'PackageManagement'

            # Create the extraction directory if it doesn't exist
            if (Test-Path $extractPath) {
                Remove-Item -Path $extractPath -Recurse -Force
            }
            New-Item -Path $extractPath -ItemType Directory

            # Extract the nupkg (it's just a zip file)
            Expand-Archive -Path $downloadPath -DestinationPath $extractPath -Force

            # Find the DLL path
            $dllBasePath = Get-ChildItem -Path $extractPath -Recurse -Filter 'PackageManagement.dll' | Select-Object -First 1 -ExpandProperty FullName

            # Import the module
            Import-Module $dllBasePath

            # Test to see if it's working
            Get-Command -Module PackageManagement

            # Clean up
            Remove-Item -Path $downloadPath
            Remove-Item -Path $extractPath -Recurse
        }
        else {
            # if (-not(Get-Module -Name 'Pansies' -ListAvailable -ErrorAction SilentlyContinue)) {
            #     Write-Verbose 'Panises module not installed, installing now'
            #     Install-Module -Name 'Pansies' -Force -Scope CurrentUser -ErrorAction SilentlyContinue -AllowClobber
            # }
        }

        # check if the NuGet package provider is installed
        if (-not(Get-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue) ) {
            Find-PackageProvider -Name 'NuGet' -ForceBootstrap -IncludeDependencies -ErrorAction SilentlyContinue | Out-Null
            Install-PackageProvider -Name 'NuGet' -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Import-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue | Out-Null
            Register-PackageSource -Name 'NuGet' -Location 'https://www.nuget.org/api/v2' -ProviderName 'NuGet' -Trusted -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }


        # Ensure PowerShellGet package provider is installed
        if (-not (Get-PackageProvider -Name PowerShellGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name PowerShellGet -Force -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Trust all package sources
        $null = Get-PackageSource | ForEach-Object {
            if ($_.Trusted -eq $false) {
                Set-PackageSource -Name $_.Name -Trusted -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }

        # Trust PSGallery repository if it is not already trusted
        if (-not(Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue | Where-Object -FilterScript { $_.InstallationPolicy -eq 'Trusted' } -ErrorAction SilentlyContinue)) {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
        }

        # Ensure AnyPackage module is installed
        if (-not(Get-Module -ListAvailable AnyPackage -ErrorAction SilentlyContinue)) {
            # PowerShellGet version 2
            Install-Module AnyPackage -AllowClobber -Force -SkipPublisherCheck | Out-Null
        }
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            if (-not(Get-PSResource -Name AnyPackage -ErrorAction SilentlyContinue)) {
                # PowerShellGet version 3
                Install-PSResource AnyPackage | Out-Null
            }
        }

        # # Ensure Pansies module is installed for logging
        # if (-not (Get-Module -Name 'Pansies' -ListAvailable -ErrorAction SilentlyContinue)) {
        #     Install-Module -Name 'Pansies' -Force -Scope CurrentUser -AllowClobber -ErrorAction SilentlyContinue
        # }

    }
    catch {
        Write-Error 'An error occurred while setting up package providers:'
        Write-Error $_.Exception.Message
    }
}

function Add-Assemblies ([bool]$UseDefault, [string[]]$CustomAssemblies) {
    # Initialize the list of assemblies to add
    $assembliesToAdd = @()
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
    if ($CustomAssemblies) {
        $assembliesToAdd += $CustomAssemblies
    }


    # Add each assembly
    foreach ($assembly in $assembliesToAdd) {
        try {
            Add-Type -AssemblyName $assembly -ErrorAction Stop
            Write-Logg -Message "Successfully added assembly: $assembly" -Level Verbose
        }
        catch {
            Write-Logg -Message "Failed to add assembly: $assembly. Error: $_" -Level Verbose
        }
    }
}


function Install-NugetDeps {
    [CmdletBinding()]
    param (
        [bool]$SaveLocally,
        [bool]$InstallDefaultNugetPackage,
        [hashtable]$NugetPackage,
        [string]$LocalModulesDirectory
    )

    try {
        # Build final list of packages to install
        $deps = @{}

        # Define default NuGet packages
        $defaultPackages = @{
            'Interop.UIAutomationClient' = '10.19041.0'
            'FlaUI.Core'                 = '4.0.0'
            'FlaUI.UIA3'                 = '4.0.0'
            'HtmlAgilityPack'            = '1.11.50'
        }

        # Gather any default packages
        if ($InstallDefaultNugetPackage) {
            foreach ($package in $defaultPackages.GetEnumerator()) {
                $deps[$package.Key] = @{
                    Name    = $package.Key
                    Version = $package.Value
                }
            }
        }

        # Gather additional packages
        if ($NugetPackage) {
            foreach ($package in $NugetPackage.GetEnumerator()) {
                $deps[$package.Key] = @{
                    Name    = $package.Key
                    Version = $package.Value
                }
            }
        }

        if ($deps.Count -gt 0) {
            Write-Logg -Message 'Installing NuGet dependencies' -Level Verbose

            # Show a progress bar over the NuGet deps
            $count = 0
            $total = $deps.Count

            foreach ($entry in $deps.GetEnumerator()) {
                $count++

                # Compute the percentage
                $percent = [int](($count / $total) * 100)

                $dep = $entry.Value.Name
                $version = $entry.Value.Version

                Write-Progress `
                    -Activity 'Installing NuGet Packages' `
                    -Status "Installing $dep ($count of $total)" `
                    -PercentComplete $percent

                # Check if the exact package name and version is already installed
                $installed = Get-Package -Name $dep `
                    -RequiredVersion $version `
                    -ProviderName NuGet `
                    -ErrorAction SilentlyContinue
        
                if ($installed) {
                    Write-Logg -Message "Package '$dep' version '$version' is already installed. Skipping..." -Level Verbose
                }
                else {
                    Write-Logg -Message "Package '$dep' version '$version' not found locally. Installing..." -Level Verbose
                    Add-NuGetDependencies -NugetPackage @{$dep = @{ Name = $dep; Version = $version } } -SaveLocally:$SaveLocally -LocalNugetDirectory:$LocalModulesDirectory
                }
            }
        }
        else {
            Write-Logg -Message 'No NuGet packages to install.' -Level Verbose
        }
    }
    catch {
        Write-Logg "An error occurred while installing NuGet packages: $_" -level Error
    }
}


function Install-PSModule {
    [CmdletBinding()]
    param(
        [bool]$InstallDefaultPSModules,
        [string[]]$PSModule,
        [bool]$RemoveAllModules,
        [string]$LocalModulesDirectory
    )

    process {
        try {
            # Build a module list
            $ModulesToBeInstalled = @()
            if ($InstallDefaultPSModules) {
                $ModulesToBeInstalled = @(
                    # Just an example – fill in your default modules here
                    'PSReadLine'
                )
            }
            elseif ($PSModule) {
                $ModulesToBeInstalled = $PSModule
            }

            # -- Show a progress bar for "Installing PS Modules" --
            if ($ModulesToBeInstalled.Count -gt 0) {
                $count = 0
                $total = $ModulesToBeInstalled.Count
                foreach ($moduleName in $ModulesToBeInstalled) {
                    $count++

                    # Compute the percentage
                    $percent = [int](($count / $total) * 100)

                    # Write progress for each module
                    Write-Progress `
                        -Activity 'Installing PowerShell modules' `
                        -Status "Installing '$moduleName' ($count of $total)" `
                        -PercentComplete $percent

                    # Perform the install
                    if (-not (Get-Module -Name $moduleName -ListAvailable -ErrorAction SilentlyContinue)) {
                        Write-Logg -Message "Installing module $moduleName" -Level Verbose
                        Install-Module -Name $moduleName -Force -Confirm:$false -ErrorAction SilentlyContinue -Scope CurrentUser -AllowClobber -SkipPublisherCheck -WarningAction SilentlyContinue
                    }

                    # Import the module
                    Import-Module -Name $moduleName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
            }
            else {
                Write-Verbose 'No modules to install.'
            }
        }
        catch {
            Write-Error "An error occurred in Install-PSModule: $_"
        }
    }
}

function Update-SessionEnvironment {
    $refreshEnv = $false
    $invocation = $MyInvocation
    if ($invocation.InvocationName -eq 'refreshenv') {
        $refreshEnv = $true
    }

    if ($refreshEnv) {
        Write-Logg -Message 'Refreshing environment variables from the registry for powershell.exe. Please wait...'
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
        Write-Logg -Message 'Finished' -Level Verbose
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

    [string] $MACHINE_ENVIRONMENT_REGISTRY_KEY_NAME = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment\'
    [Microsoft.Win32.RegistryKey] $win32RegistryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($MACHINE_ENVIRONMENT_REGISTRY_KEY_NAME)
    if ($Scope -eq [System.EnvironmentVariableTarget]::User) {
        [string] $USER_ENVIRONMENT_REGISTRY_KEY_NAME = 'Environment'
        [Microsoft.Win32.RegistryKey] $win32RegistryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($USER_ENVIRONMENT_REGISTRY_KEY_NAME)
    }
    elseif ($Scope -eq [System.EnvironmentVariableTarget]::Process) {
        return [Environment]::GetEnvironmentVariable($Name, $Scope)
    }

    [Microsoft.Win32.RegistryValueOptions] $registryValueOptions = [Microsoft.Win32.RegistryValueOptions]::None

    if ($PreserveVariables) {
        Write-Verbose 'Choosing not to expand environment names'
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

<#
.SYNOPSIS
Adds NuGet dependencies to the project.

.DESCRIPTION
This function adds NuGet dependencies to the project by installing the specified packages and saving them locally.

.PARAMETER NugetPackage
The NuGet packages to load. This should be a hashtable with the package names as keys and the package versions as values.

.PARAMETER SaveLocally
Specifies if the packages should be saved locally. By default, this is not enabled.
#>
function Add-NuGetDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'The NuGet packages to load.')]
        [hashtable]$NugetPackage,

        [Parameter(Mandatory = $false, HelpMessage = 'Specify if the packages should be saved locally.')]
        [switch]$SaveLocally,

        [Parameter(Mandatory = $false, HelpMessage = 'The local directory to save the packages to.')]
        [string]$LocalNugetDirectory
    )

    try {
        $TempWorkDir = $null
        $InstalledDependencies = @{}

        $CurrentFileName = Split-Path $PWD -Leaf
        $memstream = [IO.MemoryStream]::new([byte[]][char[]]$CurrentFileName)
        $CurrentFileNameHash = (Get-FileHash -InputStream $memstream -Algorithm SHA256).Hash

        if ($SaveLocally) {
            $TempWorkDir = Join-Path (Join-Path -Path $($LocalNugetDirectory ? $LocalNugetDirectory : $PWD) -ChildPath 'PowershellscriptsandResources/NugetPackages') 'NugetPackage'
            Write-Logg -Message "Local destination directory set to $TempWorkDir" -Level VERBOSE
        }
        else {
            # Get a unique temporary directory to store all the NuGet packages we need later
            $TempWorkDir = Join-Path "$($env:TEMP)" "$CurrentFileNameHash"
            Write-Logg -Message "Creating temporary directory at $TempWorkDir" -Level VERBOSE
        }

        if (Test-Path -Path "$TempWorkDir" -PathType Container) {
            # empty the directory
            Remove-Item -Path "$TempWorkDir" -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -Path "$TempWorkDir" -ItemType Directory -ErrorAction SilentlyContinue

        foreach ($package in $NugetPackage.GetEnumerator()) {
            $version = $package.Value.Version
            $dep = $package.Value.Name
            #  first if $LocalNugetDirectory is not null or empty
            if (-not [string]::IsNullOrEmpty($LocalNugetDirectory)) {
                $TempWorkDir = $LocalNugetDirectory
            }
            $destinationPath = Join-Path "$TempWorkDir" "${dep}.${version}"
            $dllBasePath = ''
            # check if module is already downloaded locally
            if (Test-Path -Path "$destinationPath" -PathType Container -ErrorAction SilentlyContinue) {
                # Add all the DLLs to the application domain
                $BasePath = "$destinationPath"
                # Test if lib folder exists
                if (-not (Test-Path -Path "$BasePath\lib" -PathType Container)) {
                    # new basepath is equal to the destination path
                    $dllFullPath = Get-ChildItem -Path $destinationPath -Include '*.dll' -Recurse | Select-Object -First 1
                    $BasePath = Split-Path -Path $dllFullPath -Parent
                }
                else {

                    # Retrieve the Release value from the registry
                    $releaseKey = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release

                    # Function to determine the .NET Framework version based on the Release key
                    function Get-NetFrameworkVersion {
                        param ($releaseKey)
                        switch ($releaseKey) {
                            { $_ -ge 533320 } {
                                return '4.8.1' 
                            }
                            { $_ -ge 528040 } {
                                return '4.8' 
                            }
                            { $_ -ge 461808 } {
                                return '4.7.2' 
                            }
                            { $_ -ge 461308 } {
                                return '4.7.1' 
                            }
                            { $_ -ge 460798 } {
                                return '4.7' 
                            }
                            { $_ -ge 394802 } {
                                return '4.6.2' 
                            }
                            { $_ -ge 394254 } {
                                return '4.6.1' 
                            }
                            { $_ -ge 393295 } {
                                return '4.6' 
                            }
                            { $_ -ge 379893 } {
                                return '4.5.2' 
                            }
                            { $_ -ge 378675 } {
                                return '4.5.1' 
                            }
                            { $_ -ge 378389 } {
                                return '4.5' 
                            }
                            default {
                                return 'Version 4.5 or later not detected' 
                            }
                        }
                    }

                    $netVersion = Get-NetFrameworkVersion -releaseKey $releaseKey
                    Write-logg -message "Latest .NET Framework Version Detected: $netVersion" -level Verbose

                    # Map .NET Framework versions to their corresponding folder names
                    $frameworkMap = @{
                        '4.8.1' = 'net45'
                        '4.8'   = 'net45'
                        '4.7.2' = 'net45'
                        '4.7.1' = 'net45'
                        '4.7'   = 'net45'
                        '4.6.2' = 'net45'
                        '4.6.1' = 'net45'
                        '4.6'   = 'net45'
                        '4.5.2' = 'net45'
                        '4.5.1' = 'net45'
                        '4.5'   = 'net45'
                        '4.0'   = 'net40'
                        '3.5'   = 'net35'
                    }

                    # Determine the folder corresponding to the detected .NET version
                    $folder = $frameworkMap[$netVersion]

                    if ($folder) {
                        # Construct the full path to the DLL
                        $dllBasePath = Join-Path -Path $basePath -ChildPath "lib\$folder"

                        # Load the DLL into the PowerShell session
                        if (Test-Path -Path $dllBasePath) {
                            Write-Logg -Message "Loading DLL from: $dllBasePath" -Level Verbose
                        }
                        else {
                            Write-Logg -Message "DLL not found at: $dllBasePath" -Level Verbose
                        }
                    }
                    else {
                        Write-Logg -Message "No corresponding DLL found for .NET Framework version: $netVersion" -Level Error
                    }
                }
                if (([string]::IsNullOrWhiteSpace($dllBasePath))) {
                    $dllBasePath = $BasePath ? $BasePath : ''
                }

                $DLLSplit = $(Get-ChildItem -Path $dllBasePath -Include '*.dll' -Recurse | Select-Object -First 1).Name
                $DLLFolder = $(Get-ChildItem -Path $dllBasePath -Include '*.dll' -Recurse | Select-Object -First 1).Directory
                Write-Logg -Message "Adding file $DLLSplit to application domain" -Level VERBOSE
                $null = Add-FileToAppDomain -BasePath $DLLFolder -File $DLLSplit -ErrorAction SilentlyContinue
                continue
            }

            if (-not (Test-Path -Path "$destinationPath" -PathType Container) -or (-not $InstalledDependencies.ContainsKey($dep) -or $InstalledDependencies[$dep] -ne $version)) {
                Write-Logg -Message "Installing package $dep version $version" -Level VERBOSE
                $null = Install-Package -Name $dep -RequiredVersion $version -Destination "$TempWorkDir" -ProviderName NuGet -Source Nuget -Force -ErrorAction SilentlyContinue | Out-Null
                Write-Logg -Message "[+] Installed package ${dep} with version ${version} into folder ${TempWorkDir}" -Level VERBOSE

                # Update the installed dependencies hashtable
                $InstalledDependencies[$dep] = $version
            }

            # Define the base path
            $BasePath = Join-Path "$destinationPath" -ChildPath 'lib'

            # if lib folder does not exist, they will need to use the nuget.exe to extract the dlls
            if (-not (Test-Path -Path "$BasePath" -PathType Container)) {
                Write-Logg -Message "The lib folder does not exist in $BasePath. Downloading using Nuget.exe" -Level VERBOSE
                function Get-NugetPackage {
                    param (
                        [Parameter(Mandatory = $true)]
                        [string]$PackageName,

                        [Parameter(Mandatory = $true)]
                        [string]$Version,

                        [Parameter(Mandatory = $true)]
                        [string]$DestinationPath
                    )

                    $nugetExe = 'nuget.exe'
                    if (-not (Test-Path -Path $nugetExe)) {
                        Write-Logg -Message 'Downloading NuGet.exe...' -level Verbose
                        Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $nugetExe
                    }

                    $packageFile = "$PackageName.$Version.nupkg"
                    if (-not (Test-Path -Path $packageFile)) {
                        Write-Logg -Message "Downloading $PackageName $Version..." -level Verbose
                        #& $nugetExe install $PackageName -Version $Version -OutputDirectory . -ExcludeVersion
                        #change the above line to the start-process instead
                        $null = Start-Process -FilePath $nugetExe -ArgumentList "install $PackageName -Version $Version -OutputDirectory . -ExcludeVersion" -NoNewWindow -Wait
                    }

                    $packageDir = Join-Path -Path '.' -ChildPath $PackageName
                    $libDir = Join-Path -Path $packageDir -ChildPath 'lib/netstandard2.0'

                    if (Test-Path -Path $libDir) {
                        Write-Logg -Message "Extracting $PackageName $Version..." -level Verbose
                        # make sure destination path exists
                        if (-not (Test-Path -Path $DestinationPath -PathType Container)) {
                            New-Item -Path $DestinationPath -ItemType Directory -Force -ErrorAction SilentlyContinue
                        }
                        Copy-Item -Path "$libDir\*" -Destination $DestinationPath -Recurse -Force
                    }
                    else {

                        Write-Logg -Message "Failed to find the lib directory in the NuGet package $PackageName $Version" -level Warning
                        try {
                            Write-logg -Message 'Trying a manual install of the package by creating a temporary dotnet project' -level Warning
                            # Define temporary directory for the project
                            if (-not [string]::IsNullOrEmpty($LocalModulesDirectory)) {
                                $tempDir = New-Item -Force -Type Directory -Path $LocalModulesDirectory
                            }
                            else {
                                $tempDir = New-Item -Force -Type Directory ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "$PackageName" + 'Temp'))

                            }
                            Push-Location $tempDir.FullName

                            try {
                                # Create a new .NET Standard class library project
                                $null = dotnet new classlib --framework netstandard2.0 -n $("$PackageName" + 'Temp' + 'Project') --force

                                # Navigate into the project directory
                                Set-Location (Join-Path $tempDir.FullName $("$PackageName" + 'Temp' + 'Project'))

                                # Add the Silk.NET.Windowing package
                                $null = dotnet add package $PackageName

                                # Publish the project to generate the DLLs
                                $null = dotnet publish -c Release

                                # Load the generated DLLs into PowerShell
                                $publishDir = Join-Path (Get-Location).Path 'bin\Release\netstandard2.0\publish'
                                $assemblies = Get-ChildItem -Path $publishDir -Filter *.dll
                                $assemblies | ForEach-Object {
                                    $assemblyName = $_.Name
                                    $assemblyPath = $_.FullName
                                    Write-Logg -Message "Adding assembly $assemblyName to the application domain" -Level Verbose
                                    Add-FileToAppDomain -BasePath $publishDir -File $assemblyName
                                }

                                Write-Logg -Message "Successfully installed the package $PackageName $Version" -Level Verbose
                            }
                            finally {
                                # Clean up: Remove the temporary directory if it is not specified
                                Pop-Location
                                if ( [string]::IsNullOrEmpty($LocalModulesDirectory)) {
                                    Remove-Item -LiteralPath $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                                }
                            }
                            continue
                        }
                        catch {
                            Write-Logg -Message "Failed to install the package $PackageName $Version" -level Error
                            continue

                        }
                    }
                }
                Get-NugetPackage -PackageName $dep -Version $version -DestinationPath $destinationPath
                continue
            }

            # Get all directories in the base path
            $dotnetfolders = Get-ChildItem -Path "$destinationPath\lib" -Directory

            # Extract and process version numbers from folder names
            $versionFolders = $dotnetfolders | ForEach-Object {
                if (($_.Name -match 'net(.+|\d+)\.\d+') -and ($_.Name -notmatch 'android|mac|linux|ios') ) {
                    [PSCustomObject]@{
                        Name     = $_.Name
                        Version  = [version]$($matches[0] -split 'net|coreapp|standard' | Select-Object -Last 1)
                        FullName = $_.FullName
                    }
                }
            }

            # Sort folders by their version numbers in descending order
            if ($versionFolders) {
                $sortedFolders = $versionFolders | Sort-Object -Property Version -Descending
            }
            else {
                Write-Logg -Message "No version folders found for $dep" -Level Error
                throw
            }

            # Output the sorted folder names
            $BasePath = $($sortedFolders | Select-Object -First 1 -Property FullName).FullName
            $dllBasePath = Get-ChildItem -Path $BasePath -Filter '*.dll' | Select-Object -First 1
            $DLLSplit = Split-Path -Path $dllBasePath -Leaf
            Write-Logg -Message "Adding file $DLLSplit to application domain" -Level VERBOSE
            Add-FileToAppDomain -BasePath $BasePath -File $DLLSplit
        }
    }
    catch {
        Write-Logg -Message "An error occurred: $_" -Level ERROR
        Write-Logg -Message "Error details: $($_.Exception)" -Level ERROR
    }
    finally {
        if ($TempWorkDir -and (Test-Path -Path "$TempWorkDir" -PathType Container)) {
            if ($SaveLocally) {
                Write-Logg -Message "Packages saved locally to $TempWorkDir" -Level VERBOSE
            }
            else {
                Write-Logg -Message "Cleaning up temporary directory at $TempWorkDir" -Level VERBOSE
                Remove-Item -Path "$TempWorkDir" -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}