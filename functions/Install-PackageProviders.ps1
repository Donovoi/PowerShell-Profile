<#
.SYNOPSIS
    Bootstraps and configures all package providers and repositories required
    for reliable package management in both Windows PowerShell and PowerShell (Core).

.DESCRIPTION
    Install-PackageProviders performs the following actions:
      â€¢ Dynamically installs any missing helper cmdlets (e.g. Write-Logg).
      â€¢ Removes deprecated versions of the PackageManagement module.
      â€¢ Ensures the AnyPackage module is available and imported on PS 7+.
      â€¢ Bootstraps the NuGet and PowerShellGet package providers if absent.
      â€¢ Registers the public NuGet feed and marks it as trusted.
      â€¢ Trusts all existing package sources and the PSGallery repository.

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
        # -- TLS 1.2 for all outbound calls -----------------------------------------
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 
        }
        catch {
            Write-Logg -Message 'Failed to set TLS 1.2 for outbound calls.' -Level Error
            Write-Logg -Message "$_.Exception.Message" -Level Error
            return
        }

        # -- (A) Ensure newest PackageManagement is installed, remove the old one first ----------
        $packageManagementModule = Get-Module -Name PackageManagement -ListAvailable -ErrorAction SilentlyContinue | Out-Null
        if ($packageManagementModule) {
            Remove-Module PackageManagement -Force -ErrorAction SilentlyContinue -Confirm:$false | Out-Null
            Uninstall-Module PackageManagement -AllVersions -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-Logg -Message "Removed old PackageManagement module: $($packageManagementModule.Version)" -Level Verbose
        }

        # -- (D) Bring in AnyPackage for PS 7+ --------------------------------------
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            if (-not (Get-Module -ListAvailable AnyPackage)) {
                Install-PSResource AnyPackage -TrustRepository -AcceptLicense -SkipDependencyCheck -Quiet -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            }
            Import-Module AnyPackage -Force -ErrorAction SilentlyContinue | Out-Null
        }
        if ((Get-PSRepository PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue - | Out-Null
        }

        # Install the NuGet provider if not present
        if (-not (Get-PSResource -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PSResource AnyPackage.NuGet -ErrorAction SilentlyContinue -TrustRepository -Quiet -AcceptLicense | Out-Null
            Write-Logg -Message 'Installed NuGet package provider.' -Level Verbose
        }
        Import-Module AnyPackage.NuGet

    }
    catch {
        Write-Logg -Message 'An error occurred while setting up package providers:' -Level Error
        Write-Logg -Message "$_.Exception.Message" -Level Error
    }
}