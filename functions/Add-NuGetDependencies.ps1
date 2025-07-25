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
        $FileScriptBlock = ''
        # (1) Import required cmdlets if missing
        $neededcmdlets = @(
            'Add-FileToAppDomain',
            'Write-Logg',
            'Write-InformationColored'
        )
        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
                }
                Write-Verbose "Importing cmdlet: $cmd"
                $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -PreferLocal -Force

                # Check if the returned value is a ScriptBlock and import it properly
                if ($scriptBlock -is [scriptblock]) {
                    $moduleName = "Dynamic_$cmd"
                    New-Module -Name $moduleName -ScriptBlock $scriptBlock | Import-Module -Force
                    Write-Verbose "Imported $cmd as dynamic module: $moduleName"
                }
                elseif ($scriptBlock -is [System.Management.Automation.PSModuleInfo]) {
                    # If a module info was returned, it's already imported
                    Write-Verbose "Module for $cmd was already imported: $($scriptBlock.Name)"
                }
                elseif ($($scriptBlock | Get-Item) -is [System.IO.FileInfo]) {
                    # If a file path was returned, import it
                    $FileScriptBlock += $(Get-Content -Path $scriptBlock -Raw) + "`n"
                    Write-Verbose "Imported $cmd from file: $scriptBlock"
                }
                else {
                    Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
                    Write-Warning "Returned: $($scriptBlock)"
                }
            }
        }
        $finalFileScriptBlock = [scriptblock]::Create($FileScriptBlock.ToString() + "`nExport-ModuleMember -Function * -Alias *")
        New-Module -Name 'cmdletCollection' -ScriptBlock $finalFileScriptBlock | Import-Module -Force

        $TempWorkDir = $null
        $InstalledDependencies = @{}

        $CurrentFileName = Split-Path $PWD -Leaf
        $memstream = [IO.MemoryStream]::new([byte[]][char[]]$CurrentFileName)
        $CurrentFileNameHash = (Get-FileHash -InputStream $memstream -Algorithm SHA256).Hash

        if ($SaveLocally) {
            $TempWorkDir = if (Test-Path -Path $LocalNugetDirectory -ErrorAction SilentlyContinue) {
                $LocalNugetDirectory
            }
            else {
                Write-Logg -Message "LocalNugetDirectory '$LocalNugetDirectory' does not exist. Creating it." -Level VERBOSE
                New-Item -Path $LocalNugetDirectory -ItemType Directory -Force | Out-Null
                $LocalNugetDirectory
            }
            Write-Logg -Message "Local destination directory set to $TempWorkDir" -Level VERBOSE
        }
        else {
            $TempWorkDir = Join-Path "$($env:TEMP)" "$CurrentFileNameHash"
            if (Test-Path -Path "$TempWorkDir" -PathType Container) {
                Write-Logg -Message "Temporary directory already exists at $TempWorkDir" -Level VERBOSE
            }
            else {
                # Create the temporary directory
                Write-Logg -Message "Creating temporary directory at $TempWorkDir" -Level VERBOSE
                New-Item -Path "$TempWorkDir" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
            }
        }

        $dllBasePath = ''
        $dllFullPath = ''
        $BasePath = ''

        foreach ($package in $NugetPackage.GetEnumerator()) {
            $dep = $package.Key
            $version = $package.Value


            if (-not [string]::IsNullOrEmpty($LocalNugetDirectory)) {
                $TempWorkDir = $LocalNugetDirectory
            }

            $destinationPath = Join-Path "$TempWorkDir" "$dep.$version"


            # Check if module is already downloaded locally
            if (Test-Path -Path "$destinationPath" -PathType Container -ErrorAction SilentlyContinue) {
                # Attempt to load the DLL(s)
                $BasePath = "$destinationPath"

                if (-not (Test-Path -Path "$BasePath\lib" -PathType Container)) {
                    $dllFullPath = Get-ChildItem -Path $destinationPath -Include '*.dll' -Recurse | Select-Object -First 1
                    if ($dllFullPath) {
                        $BasePath = Split-Path -Path $dllFullPath -Parent -ErrorAction SilentlyContinue
                    }
                    else {
                        Write-Logg -Message "No DLL found in $destinationPath" -Level Warning

                    }
                }
                else {
                    # Retrieve .NET release key
                    $releaseKey = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release

                    $netVersion = Get-NetFrameworkVersion -releaseKey $releaseKey
                    Write-Logg -message "Latest .NET Framework Version Detected: $netVersion" -Level VERBOSE

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

                    $folder = $frameworkMap[$netVersion]
                    if ($folder) {
                        $dllBasePath = Join-Path -Path $BasePath -ChildPath "lib\$folder"
                        if (Test-Path -Path $dllBasePath) {
                            Write-Logg -Message "Loading DLL from: $dllBasePath" -Level VERBOSE
                        }
                        else {
                            Write-Logg -Message "DLL not found at: $dllBasePath" -Level VERBOSE
                        }
                    }
                    else {
                        Write-Logg -Message "No corresponding DLL found for .NET Framework version: $netVersion" -Level Error
                    }
                }

                if ([string]::IsNullOrWhiteSpace($dllBasePath)) {
                    $dllBasePath = $BasePath
                }

                $DLLSplit = (Get-ChildItem -Path $dllBasePath -Include '*.dll' -Recurse | Select-Object -First 1).Name
                $DLLFolder = (Get-ChildItem -Path $dllBasePath -Include '*.dll' -Recurse | Select-Object -First 1).Directory
                if (-not $dllFolder) {
                    Write-Logg -Message "No DLL found in $dllBasePath" -Level Warning
                }
                else {
                    Write-Logg -Message "Adding file $DLLSplit to application domain" -Level VERBOSE
                    Add-FileToAppDomain -BasePath $DLLFolder -File $DLLSplit -ErrorAction SilentlyContinue
                    continue
                }
            }

            # If not found locally or new version
            if (-not (Test-Path -Path "$destinationPath" -PathType Container) -or (-not $InstalledDependencies.ContainsKey($dep) -or $InstalledDependencies[$dep] -ne $version)) {

                Write-Logg -Message "Installing package $dep version $version" -Level VERBOSE
                if (-not (Test-Path -Path "$destinationPath" -PathType Container)) {
                    New-Item -Path "$destinationPath" -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                }
                AnyPackage\Save-Package -Name $dep -Version $version -Path "$destinationPath" -TrustSource -ErrorAction SilentlyContinue | Out-Null
                AnyPackage\Install-Package -Path "$destinationPath" -ErrorAction SilentlyContinue | Out-Null
                Write-Logg -Message "[+] Installed package ${dep} with version ${version} into folder ${TempWorkDir}" -Level VERBOSE

                $InstalledDependencies[$dep] = $version
            }

            $BasePath = Join-Path "$destinationPath" -ChildPath 'lib'
            if (-not (Test-Path -Path "$BasePath" -PathType Container)) {
                Write-Logg -Message "The lib folder does not exist in $BasePath. Downloading using Nuget.exe" -Level VERBOSE
                function Get-NugetPackage {
                    param (
                        [Parameter(Mandatory = $true)] [string]$PackageName,
                        [Parameter(Mandatory = $true)] [string]$Version,
                        [Parameter(Mandatory = $true)] [string]$DestinationPath
                    )

                    $nugetExe = "$ENV:TEMP\nuget.exe"
                    if (-not (Test-Path -Path $nugetExe)) {
                        Write-Logg -Message 'Downloading NuGet.exe...' -Level VERBOSE
                        Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile $nugetExe
                    }

                    $packageFile = "$PackageName.$Version.nupkg"
                    if (-not (Test-Path -Path $packageFile)) {
                        Write-Logg -Message "Downloading $PackageName $Version..." -Level VERBOSE
                        Start-Process -FilePath $nugetExe -ArgumentList "install $PackageName -Version $Version -OutputDirectory $DestinationPath -Verbosity quiet -NonInteractive" -NoNewWindow -Wait
                    }

                    $packageDir = Join-Path -Path '.' -ChildPath $PackageName
                    $libDir = Join-Path -Path $packageDir -ChildPath 'lib/netstandard2.0'
                    if (Test-Path -Path $libDir) {
                        Write-Logg -Message "Extracting $PackageName $Version..." -Level VERBOSE
                        if (-not (Test-Path -Path $DestinationPath -PathType Container)) {
                            New-Item -Path $DestinationPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                        Copy-Item -Path "$libDir\*" -Destination $DestinationPath -Recurse -Force
                    }
                    else {
                        Write-Logg -Message "Failed to find the lib directory in the NuGet package $PackageName $Version" -level Warning

                        try {
                            Write-logg -Message 'Trying a manual install of the package by creating a temporary dotnet project' -level Warning
                            if (-not [string]::IsNullOrEmpty($LocalModulesDirectory)) {
                                $tempDir = New-Item -Force -Type Directory -Path $LocalModulesDirectory
                            }
                            else {
                                $tempDir = New-Item -Force -Type Directory ([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "$PackageName" + 'Temp'))
                            }
                            Push-Location $tempDir.FullName

                            try {
                                dotnet new classlib --framework netstandard2.0 -n ($PackageName + 'TempProject') --force | Out-Null
                                Set-Location (Join-Path $tempDir.FullName ($PackageName + 'TempProject'))
                                dotnet add package $PackageName | Out-Null
                                dotnet publish -c Release | Out-Null

                                $publishDir = Join-Path (Get-Location).Path 'bin\Release\netstandard2.0\publish'
                                $assemblies = Get-ChildItem -Path $publishDir -Filter *.dll
                                foreach ($assembly in $assemblies) {
                                    Write-Logg -Message "Adding assembly $($assembly.Name) to the application domain" -Level VERBOSE
                                    Add-FileToAppDomain -BasePath $publishDir -File $assembly.Name
                                }
                                Write-Logg -Message "Successfully installed the package $PackageName $Version" -Level VERBOSE
                            }
                            finally {
                                Pop-Location
                                if ([string]::IsNullOrEmpty($LocalModulesDirectory)) {
                                    Remove-Item -LiteralPath $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
                                }
                            }
                        }
                        catch {
                            Write-Logg -Message "Failed to install the package $PackageName $Version" -level Error
                        }
                    }
                }

                Get-NugetPackage -PackageName $dep -Version $version -DestinationPath $destinationPath
            }

            $dotnetfolders = if (-not (Get-ChildItem -Path "$destinationPath\lib" -Directory -ErrorAction SilentlyContinue)) {
                Write-Logg -Message "No lib directory found in $destinationPath" -Level WARNING
                # sometimes the folder is in two levels down, so we check both
                $destinationPathFolderName = Split-Path $destinationPath -Leaf
                $nestedlibfolders = Get-ChildItem -Path "$destinationPath\$destinationPathFolderName\lib"
                if ($nestedlibfolders) {
                    Write-Logg -Message "Found nested lib directory in $destinationPath\$destinationPathFolderName\lib" -Level VERBOSE
                    $nestedlibfolders
                }
                else {
                    Write-Logg -Message "No nested lib directory found in $destinationPath" -Level Error
                    throw
                }
            }
            else {
                Get-ChildItem -Path "$destinationPath\lib" -Directory -ErrorAction Stop
            }
            $versionFolders = $dotnetfolders | ForEach-Object {
                if (($_.Name -match 'net(.+|\d+)\.\d+') -and ($_.Name -notmatch 'android|mac|linux|ios') ) {
                    [PSCustomObject]@{
                        Name     = $_.Name
                        Version  = [version]($matches[0] -split 'net|coreapp|standard|-windows' | Select-Object -Last 1)
                        FullName = $_.FullName
                    }
                }
            }

            if ($versionFolders) {
                $sortedFolders = $versionFolders | Sort-Object -Property Version -Descending
            }
            else {
                Write-Logg -Message "No version folders found for $dep" -Level Error
                throw
            }

            $BasePath = $sortedFolders | Select-Object -First 1 -ExpandProperty FullName
            $dllBasePath = Get-ChildItem -Path $BasePath -Filter '*.dll' | Select-Object -First 1

            $DLLSplit = Split-Path -Path $dllBasePath -Leaf
            Write-Logg -Message "Adding file $DLLSplit to application domain" -Level VERBOSE
            Add-FileToAppDomain -BasePath $BasePath -File $DLLSplit
        }
    }
    catch {
        Write-Logg -Message "An error occurred: $_" -Level ERROR
        Write-Logg -Message "Error details: $($_.Exception)" -Level ERROR
        throw
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