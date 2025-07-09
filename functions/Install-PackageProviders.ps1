<#
.SYNOPSIS
    Bootstraps and configures all package providers and repositories required
    for reliable package management in both Windows PowerShell and PowerShell (Core).

.DESCRIPTION
    Install-PackageProviders performs the following actions:
      • Dynamically installs any missing helper cmdlets (e.g. Write-Logg).  
      • Removes deprecated versions of the PackageManagement module.  
      • Ensures the AnyPackage module is available and imported on PS 7+.  
      • Bootstraps the NuGet and PowerShellGet package providers if absent.  
      • Registers the public NuGet feed and marks it as trusted.  
      • Trusts all existing package sources and the PSGallery repository.

    The function is designed for use in a profile to guarantee a consistent
    package-management environment across sessions and machines.

.PARAMETER (none)
    This cmdlet does not accept any parameters.

.INPUTS
    None. You cannot pipe objects to this cmdlet.

.OUTPUTS
    None. The cmdlet writes only verbose, warning, or error messages.

.EXAMPLE
    PS> Install-PackageProviders
    Runs the cmdlet with default behaviour, installing and configuring all
    required providers and sources.

.NOTES
    Author   : toor
    Requires : PowerShell 5.1 or later
    Version  : 1.0
    Updated  : <add-date>
    Link     : https://learn.microsoft.com/powershell/module/packagemanagement
#>

function Install-PackageProviders {
    [CmdletBinding()]
    param ()

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

        #Remove deprecated module
        Remove-Module -Name 'PackageManagement' -ErrorAction SilentlyContinue | Out-Null

        # Ensure AnyPackage module is installed
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            if (-not(Get-PSResource -Name AnyPackage -ErrorAction SilentlyContinue)) {
                Install-PSResource AnyPackage -TrustRepository -Quiet -AcceptLicense -Confirm:$false | Out-Null
            }
            if (-not (Get-Module -Name AnyPackage -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-Module AnyPackage -Force -Confirm:$false -AllowClobber -SkipPublisherCheck -AcceptLicense -ErrorAction SilentlyContinue | Out-Null
            }
            Import-Module AnyPackage -Force -ErrorAction SilentlyContinue | Out-Null
        }

        # Check if the NuGet package provider is installed
        if (-not(Get-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue)) {
            Find-PackageProvider -Name 'NuGet' -ForceBootstrap -IncludeDependencies -ErrorAction SilentlyContinue | Out-Null
            Install-PackageProvider -Name 'NuGet' -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Import-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue | Out-Null
            Register-PackageSource -Name 'NuGet' -Location 'https://api.nuget.org/v3/index.json' `
                -Provider 'NuGet' -ForceBootstrap -Trusted -Force -Confirm:$false `
                -ErrorAction SilentlyContinue | Out-Null
        }

        # Ensure PowerShellGet package provider is installed
        if (-not (Get-PackageProvider -Name PowerShellGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name PowerShellGet -Force -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Trust all package sources
        Get-PackageSource | ForEach-Object {
            if (-not $_.Trusted) {
                Set-PackageSource -Name $_.Name -Trusted -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }

        # Trust PSGallery
        $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($psGallery -and $psGallery.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {
        Write-Logg -Message 'An error occurred while setting up package providers:' -Level Error
        Write-Logg -Message "$_.Exception.Message" -Level Error
    }
}