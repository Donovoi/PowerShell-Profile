function Install-NugetDeps {
    [CmdletBinding()]
    param(
        [bool]$SaveLocally,
        [bool]$InstallDefaultNugetPackage,
        [hashtable]$NugetPackage,
        [string]$LocalNugetDirectory
    )

    try {

        # (1) Import required cmdlets if missing
        $neededcmdlets = @(
            'Write-Logg'
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
                    New-Module -Name $moduleName -ScriptBlock $scriptBlock | Import-Module -Force -Global
                    Write-Verbose "Imported $cmd as dynamic module: $moduleName"
                }
                elseif ($scriptBlock -is [System.Management.Automation.PSModuleInfo]) {
                    # If a module info was returned, it's already imported
                    Write-Verbose "Module for $cmd was already imported: $($scriptBlock.Name)"
                }
                elseif ($scriptBlock -is [System.IO.FileInfo]) {
                    # If a file path was returned, import it
                    Import-Module -Name $scriptBlock.FullName -Force -Global
                    Write-Verbose "Imported $cmd from file: $($scriptBlock.FullName)"
                }
                else {
                    Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
                }
            }
        }
        # Build final list of packages to install
        $deps = @{}

        # Default NuGet packages
        $defaultPackages = @{
            'Interop.UIAutomationClient' = '10.19041.0'
            'FlaUI.Core'                 = '4.0.0'
            'FlaUI.UIA3'                 = '4.0.0'
            'HtmlAgilityPack'            = '1.12.0'
        }

        # Gather default packages if requested
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
            $count = 0
            $total = $deps.Count

            foreach ($entry in $deps.GetEnumerator()) {
                $count++
                $percent = [int](($count / $total) * 100)
                $dep = $entry.Value.Name
                $version = $entry.Value.Version

                Write-Progress -Activity 'Installing NuGet Packages' -Status "Installing $dep ($count of $total)`n" -PercentComplete $percent

                if ($percent -eq 100) {
                    Clear-Host
                }

                # Check if exact package name + version is installed
                $installed = Get-Package -Name $dep -RequiredVersion $version -ProviderName NuGet -ErrorAction SilentlyContinue

                if ($SaveLocally -and (-not [string]::IsNullOrEmpty($LocalNugetDirectory))) {
                    $LocalNugetPackage = Join-Path -Path $LocalNugetDirectory -ChildPath "$dep.$version"
                    if (Test-Path -Path $LocalNugetPackage -PathType Container) {
                        $installed = $true
                    }
                }
                elseif ($SaveLocally) {
                    # If SaveLocally was used but no directory is provided, user might want an error or warning
                    Write-Logg -Message 'LocalNugetDirectory is empty, but -SaveLocally was specified. Exiting script...' -Level Error
                    throw
                }

                if ($installed) {
                    Write-Logg -Message "Package '$dep' version '$version' is already installed. Skipping..." -Level Verbose
                    continue
                }
                else {
                    Write-Logg -Message "Package '$dep' version '$version' not found locally. Installing..." -Level Verbose
                    Add-NuGetDependencies -NugetPackage @{$dep = @{ Name = $dep; Version = $version } } -SaveLocally:$SaveLocally -LocalNugetDirectory:$LocalNugetDirectory
                    continue
                }
            }
        }
        else {
            Write-Logg -Message 'No NuGet packages to install.' -Level Verbose
        }
    }
    catch {
        Write-Logg "An error occurred while installing NuGet packages: $_" -level Error
        throw
    }
}