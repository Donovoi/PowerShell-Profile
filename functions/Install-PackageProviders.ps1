<#
.SYNOPSIS
    Bootstraps and configures all package providers and repositories required
    for reliable package management in both Windows PowerShell and PowerShell (Core).

.DESCRIPTION
    Install-PackageProviders performs the following actions:
      - Dynamically installs any missing helper cmdlets (e.g. Write-Logg).
      - Removes deprecated versions of the PackageManagement module.
      - Ensures the AnyPackage module is available and imported on PS 7+.
      - Bootstraps the NuGet and PowerShellGet package providers if absent.
      - Registers the public NuGet feed and marks it as trusted.
      - Trusts all existing package sources and the PSGallery repository.

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
    [OutputType([void])]
    param(

        try {
            # Load shared dependency loader if not already available
            if (-not (Get-Command -Name 'Initialize-CmdletDependencies' -ErrorAction SilentlyContinue)) {
                $initScript = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
                if (Test-Path $initScript) {
                    . $initScript
                }
                else {
                    Write-Warning "Initialize-CmdletDependencies.ps1 not found in $PSScriptRoot"
                    Write-Warning 'Falling back to direct download'
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/cmdlets/Initialize-CmdletDependencies.ps1'
                    $scriptBlock = [scriptblock]::Create($method)
                    . $scriptBlock
                }
            }
        
            # (1) Import required cmdlets if missing
            # Load all required cmdlets (replaces 60+ lines of boilerplate)
            Initialize-CmdletDependencies -RequiredCmdlets @('Write-Logg') -PreferLocal -Force

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
                Write-Logg -Message "Removed old PackageManagement module: $($packageManagementModule.Version)" -Level VERBOSE
            }

            # -- (D) Bring in AnyPackage for PS 7+ --------------------------------------
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                if (-not (Get-Module -ListAvailable AnyPackage)) {
                    Install-PSResource AnyPackage -TrustRepository -AcceptLicense -SkipDependencyCheck -Quiet -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
                }
                Import-Module AnyPackage -Force -ErrorAction SilentlyContinue | Out-Null
            }
            if ((Get-PSRepository PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
                Set-PSRepository PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
            }

            # Install the NuGet provider if not present
            if (-not (Get-PSResource -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PSResource AnyPackage.NuGet -Reinstall -ErrorAction SilentlyContinue -TrustRepository -Quiet -AcceptLicense | Out-Null
                Write-Logg -Message 'Installed NuGet package provider.' -Level VERBOSE
            }
            Import-Module AnyPackage.NuGet

        }
        catch {
            Write-Logg -Message 'An error occurred while setting up package providers:' -Level Error
            Write-Logg -Message "$_.Exception.Message" -Level Error
        }
    }