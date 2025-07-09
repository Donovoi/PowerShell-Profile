<#
.SYNOPSIS
    Installs NuGet packages (optionally using a local cache) and finishes with a deep console clear.
.DESCRIPTION
    • Uses Write‑Progress inside the dependency loop and marks it Completed only once at the end.
    • Adds Clear‑Deep helper that wipes viewport *and* scroll‑back using ANSI + .NET while staying PSScriptAnalyzer‑clean (no Write‑Host or Console.Write).
    • Removes all in‑loop clear logic that interfered with progress‑bar repainting.
    • Optional -FlushKeys to discard stray keystrokes after long operations.
    • Compatible with Win‑ConHost, Windows Terminal, VS Code, SSH, Linux/macOS.
.NOTES
    Requires helper cmdlets Write‑Logg, Install‑Cmdlet, Install‑PackageProviders, Add‑NuGetDependencies.
#>

#region Console helpers
function Clear-Deep {
    <#
        .SYNOPSIS
            Clears the console viewport **and** scroll‑back buffer.
        .PARAMETER FlushKeys
            Also purge any buffered keyboard input (recommended after long‑running loops).
    #>
    [CmdletBinding()]
    param([switch]$FlushKeys)

    # Remove any lingering progress bar first
    Write-Progress -Activity ' ' -Completed

    # Fast viewport wipe via .NET
    [Console]::Clear()

    # ANSI VT: ESC[3J = erase scroll‑back, ESC[H = cursor home.
    # Use Write-Information to stay within PSAvoidUsingWriteHost rule.
    $esc = [char]27
    Write-Information "$esc[3J$esc[H" -InformationAction Continue

    if ($FlushKeys) {
        $host.UI.RawUI.FlushInputBuffer()
    }
}

# Muscle‑memory alias (override cls / clear‑host if you like)
Set-Alias cls Clear-Deep
#endregion

function Install-NugetDeps {
    [CmdletBinding()]
    param(
        [switch]$SaveLocally = $false,
        [switch]$InstallDefaultNugetPackage = $false,
        [hashtable]$NugetPackage,
        [string]$LocalNugetDirectory
    )

    try {
        #--------------------------------------------------------------------#
        # 1. Ensure helper cmdlets are available                             #
        #--------------------------------------------------------------------#
        $neededcmdlets = @('Write-Logg', 'Install-PackageProviders')
        foreach ($cmd in $neededcmdlets) {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                    $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                    $sb = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                    New-Module -Name 'InstallCmdlet' -ScriptBlock $sb | Import-Module
                }
                $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -PreferLocal -Force

                switch ($scriptBlock.GetType().Name) {
                    'ScriptBlock' {
                        New-Module -Name "Dynamic_$cmd" -ScriptBlock $scriptBlock | Import-Module -Global -Force
                    }
                    'PSModuleInfo' {
                    }
                    'FileInfo' {
                        Import-Module $scriptBlock.FullName -Global -Force
                    }
                    default {
                        Write-Warning "Could not import $cmd`: unexpected return type."
                    }
                }
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

        if ($InstallDefaultNugetPackage) {
            foreach ($p in $defaultPackages.GetEnumerator()) {
                $deps[$p.Key] = @{ Name = $p.Key; Version = $p.Value }
            }
        }
        if ($NugetPackage) {
            foreach ($p in $NugetPackage.GetEnumerator()) {
                $deps[$p.Key] = @{ Name = $p.Key; Version = $p.Value }
            }
        }

        #--------------------------------------------------------------------#
        # 3. Install each dependency                                         #
        #--------------------------------------------------------------------#
        if ($deps.Count -gt 0) {
            Write-Logg -Message 'Installing NuGet dependencies …' -Level Verbose
            $i = 0
            $total = $deps.Count

            foreach ($entry in $deps.GetEnumerator()) {
                $i++
                $percent = [int](($i / $total) * 100)
                $dep = $entry.Value.Name
                $version = $entry.Value.Version

                Write-Progress -Activity 'Installing NuGet Packages' `
                    -Status "Installing $dep ($i of $total)" `
                    -PercentComplete $percent

                # Ensure NuGet provider is present
                Install-PackageProviders

                # Check if already installed (locally or system-wide)
                $installed = Get-Package -Name $dep -RequiredVersion $version -Provider NuGet -ErrorAction SilentlyContinue

                if ($SaveLocally -and $LocalNugetDirectory) {
                    $localPath = Join-Path $LocalNugetDirectory "$dep.$version"
                    if (Test-Path $localPath -PathType Container) {
                        $installed = $true
                    }
                }
                elseif ($SaveLocally) {
                    Write-Logg -Message 'LocalNugetDirectory is empty but -SaveLocally specified.' -Level Error
                    throw
                }

                if ($installed) {
                    Write-Logg -Message "Package '$dep' $version already installed - skipping." -Level Verbose
                    continue
                }

                # Install / download package
                Add-NuGetDependencies -NugetPackage @{ $dep = @{ Name = $dep; Version = $version } } `
                    -SaveLocally:$SaveLocally `
                    -LocalNugetDirectory:$LocalNugetDirectory
            }

            #----------------------------------------------------------------
            # 4. Finish: close progress bar and deep-clear console          #
            #----------------------------------------------------------------
            Write-Progress -Activity 'Installing NuGet Packages' -Completed
            Clear-Deep -FlushKeys
        }
        else {
            Write-Logg -Message 'No NuGet packages to install.' -Level Verbose
        }
    }
    catch {
        Write-Logg "An error occurred while installing NuGet packages: $_" -Level Error
        throw
    }
}