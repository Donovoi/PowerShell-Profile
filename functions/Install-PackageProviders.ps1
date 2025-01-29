function Install-PackageProviders {
    [CmdletBinding()]
    param ()

    try {
        # (1) Import required cmdlets if missing
        $neededcmdlets = @(
            'Write-Logg'
        
        )
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
        # Ensure NuGet package provider is installed and registered
        if (-not(Get-Module -Name 'PackageManagement' -ListAvailable -ErrorAction SilentlyContinue)) {
            # Define the URL for the latest PackageManagement nupkg
            $nugetUrl = 'https://www.powershellgallery.com/api/v2/package/PackageManagement'
            $downloadPath = Join-Path $env:TEMP 'PackageManagement.zip'
            $extractPath = Join-Path $env:TEMP 'PackageManagement'

            # Download the nupkg file
            Invoke-WebRequest -Uri $nugetUrl -OutFile $downloadPath

            # Clean up existing extraction path
            if (Test-Path $extractPath) {
                Remove-Item -Path $extractPath -Recurse -Force
            }
            New-Item -Path $extractPath -ItemType Directory | Out-Null

            # Extract the nupkg (zip file)
            Expand-Archive -Path $downloadPath -DestinationPath $extractPath -Force

            # Find the DLL path
            $dllBasePath = Get-ChildItem -Path $extractPath -Recurse -Filter 'PackageManagement.dll' |
                Select-Object -First 1 -ExpandProperty FullName

            Import-Module $dllBasePath

            # Test to see if it's working
            Get-Command -Module PackageManagement | Out-Null

            # Clean up
            Remove-Item -Path $downloadPath -ErrorAction SilentlyContinue
            Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Check if the NuGet package provider is installed
        if (-not(Get-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue)) {
            Find-PackageProvider -Name 'NuGet' -ForceBootstrap -IncludeDependencies -ErrorAction SilentlyContinue | Out-Null
            Install-PackageProvider -Name 'NuGet' -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Import-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue | Out-Null
            Register-PackageSource -Name 'NuGet' -Location 'https://www.nuget.org/api/v2' `
                -ProviderName 'NuGet' -Trusted -Force -Confirm:$false `
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

        # Ensure AnyPackage module is installed
        if (-not(Get-Module -ListAvailable AnyPackage -ErrorAction SilentlyContinue)) {
            # For PSv5/5.1
            Install-Module AnyPackage -AllowClobber -Force -SkipPublisherCheck | Out-Null
        }
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            if (-not(Get-PSResource -Name AnyPackage -ErrorAction SilentlyContinue)) {
                Install-PSResource AnyPackage | Out-Null
            }
        }
    }
    catch {
        Write-Logg -Message 'An error occurred while setting up package providers:' -Level Error
        Write-Logg -Message "$_.Exception.Message" -Level Error
    }
}