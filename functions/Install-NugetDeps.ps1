<#
.SYNOPSIS
    Installs NuGet packages (optionally using a local cache) and finishes with a deep console clear.
.DESCRIPTION
    - Uses Write-Progress inside the dependency loop and marks it Completed only once at the end.
    - Adds Clear-Deep helper that wipes viewport *and* scroll-back using ANSI + .NET while staying PSScriptAnalyzer-clean (no Write-Host or Console.Write).
    - Removes all in-loop clear logic that interfered with progress-bar repainting.
    - Optional -FlushKeys to discard stray keystrokes after long operations.
    - Compatible with Win-ConHost, Windows Terminal, VS Code, SSH, Linux/macOS.
.NOTES
    Requires helper cmdlets Write-Logg, Install-Cmdlet, Install-PackageProviders, Add-NuGetDependencies.
#>

function Install-NugetDeps {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [switch]$SaveLocally = $false,
        [switch]$InstallDefaultNugetPackage = $false,
        [hashtable]$NugetPackage,
        [string]$LocalNugetDirectory
    )

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
        
        #--------------------------------------------------------------------#
        # 1. Ensure helper cmdlets are available                             #
        #--------------------------------------------------------------------#
        # Load all required cmdlets (replaces 90+ lines of boilerplate)
        Initialize-CmdletDependencies -RequiredCmdlets @(
            'Write-Logg',
            'Install-PackageProviders',
            'Add-NuGetDependencies'
        ) -PreferLocal -Force

        # make sure $LocalNugetDirectory points to an absolute path and create it if necessary
        if ($SaveLocally -and $LocalNugetDirectory) {
            if (-not (Test-Path -Path $LocalNugetDirectory -PathType Container) -and ($LocalNugetDirectory.Contains(':\') -or $LocalNugetDirectory.Contains(':/'))) {
                New-Item -Path $LocalNugetDirectory -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            }
            elseif (Test-Path -Path $LocalNugetDirectory -PathType Container) {
                Write-Logg -Message "LocalNugetDirectory '$LocalNugetDirectory' is a valid path." -Level VERBOSE
            }
            else {
                Write-Logg -Message "LocalNugetDirectory '$LocalNugetDirectory' is not a valid path." -Level Error
            }
        }
        #--------------------------------------------------------------------#
        # 2. Build dependency table                                          #
        #--------------------------------------------------------------------#
        $deps = @{}
        $defaultPackages = @{
            'Interop.UIAutomationClient' = '10.19041.0'
            'FlaUI.Core'                 = '4.0.0'
            'FlaUI.UIA3'                 = '4.0.0'
            'HtmlAgilityPack'            = '1.12.0'
        }

        if ($NugetPackage) {
            foreach ($p in $NugetPackage.GetEnumerator()) {
                $deps.Add($p.Key, $p.Value)
            }
        }
        # Also add the default package if they dont exist in the hashtable
        if ($InstallDefaultNugetPackage -and $NugetPackage) {
            foreach ($p in $defaultPackages.GetEnumerator()) {
                if (-not $deps.ContainsKey($p.Key)) {
                    $deps.Add($p.Key, $p.Value)
                }
            }
        }
        #--------------------------------------------------------------------#
        # 3. Install each dependency                                         #
        #--------------------------------------------------------------------#
        if ($deps.Count -gt 0) {
            Write-Logg -Message 'Installing NuGet dependencies...' -Level VERBOSE
            $i = 0
            $total = $deps.Count

            foreach ($entry in $deps.GetEnumerator()) {
                $i++
                $percent = [int](($i / $total) * 100)
                $dep = $entry.Key
                $version = $entry.Value

                # Write-Progress -Activity 'Installing NuGet Packages' `
                #     -Status "Installing $dep ($i of $total)" `
                #     -PercentComplete $percent

                # Ensure NuGet provider is present
                Install-PackageProviders

                $installed = $false


                if ($SaveLocally -and $LocalNugetDirectory) {
                    $localPath = Join-Path $LocalNugetDirectory "$dep.$version"
                    if (Test-Path $localPath -PathType Container) {
                        $installed = $true
                    }
                    else {
                        $installed = $false
                    }
                }
                elseif ($SaveLocally) {
                    Write-Logg -Message 'LocalNugetDirectory is empty but -SaveLocally specified.' -Level Error
                    throw
                }

                if ($installed) {
                    Write-Logg -Message "Package '$dep' $version already installed - skipping." -Level VERBOSE
                    continue
                }

                # Install / download package
                Add-NuGetDependencies -NugetPackage @{ $dep = $version } `
                    -SaveLocally:$SaveLocally `
                    -LocalNugetDirectory:$LocalNugetDirectory
            }

            #----------------------------------------------------------------
            # 4. Finish: close progress bar and deep-clear console          #
            #----------------------------------------------------------------
            Write-Progress -Activity 'Installing NuGet Packages' -Completed
        }
        else {
            Write-Logg -Message 'No NuGet packages to install.' -Level VERBOSE
        }
    }
    catch {
        Write-Logg "An error occurred while installing NuGet packages: $_" -Level Error
        throw
    }
}