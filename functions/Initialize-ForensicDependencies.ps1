function Initialize-ForensicDependencies {
    <#
    .SYNOPSIS
    Initializes and validates dependencies required for forensic artifact collection.

    .DESCRIPTION
    Checks for and installs required PowerShell modules and functions needed for forensic operations.
    This includes powershell-yaml for YAML parsing and various forensic collection utilities.

    .EXAMPLE
    Initialize-ForensicDependencies

    Checks and installs all required dependencies for forensic operations.

    .NOTES
    This function is designed to be called once at the beginning of forensic operations.
    It uses script-level caching to avoid repeated dependency checks.
    #>
    [CmdletBinding()]
    param()

    if ($script:DependenciesInitialized) {
        Write-Verbose 'Dependencies already initialized, skipping check'
        return
    }

    try {
        # Check for YAML parsing capability
        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
            Write-Verbose 'Installing powershell-yaml module...'
            if (Get-Command Install-Module -ErrorAction SilentlyContinue) {
                Install-Module -Name powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
                Import-Module powershell-yaml -Force
                Write-Verbose 'Successfully installed powershell-yaml module'
            }
            else {
                throw 'Install-Module not available. Please install powershell-yaml module manually.'
            }
        }

        # Check for custom forensic functions
        Write-Verbose 'Checking for required forensic functions...'
        $requiredFunctions = @(
            'Install-Dependencies'     # For installing dependencies
            'Get-LatestGitHubRelease'  # For downloading aria2c if needed
            'Invoke-AriaDownload'
            'Get-FileDetailsFromResponse'
            'Get-OutputFilename'
            'Test-InPath'
            'Invoke-AriaRPCDownload'
            'Get-SYSTEM'
            'Invoke-RawCopy'
        )

        foreach ($cmd in $requiredFunctions) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose "Importing cmdlet: $cmd"
            $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -Force

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
            elseif ([System.IO.FileInfo]$scriptBlock -is [System.IO.FileInfo]) {
                # If a file path was returned, import it
                Import-Module -Name $scriptBlock -Force -Global
                Write-Verbose "Imported $cmd from file: $scriptBlock"
            }
            else {
                Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
            }

        }

        $script:DependenciesInitialized = $true
        Write-Verbose 'Dependency initialization completed successfully'
    }
    catch {
        Write-Error "Failed to initialize dependencies: $($_.Exception.Message)" -ErrorAction Stop
    }
}

function Initialize-ForensicCollection {
    <#
    .SYNOPSIS
    Initializes the forensic collection environment and handles privilege elevation.

    .DESCRIPTION
    Sets up the collection directory, validates permissions, and handles SYSTEM privilege elevation
    if requested. Returns a configuration object with collection settings.

    .PARAMETER CollectionPath
    Optional collection path. If not provided, generates a timestamped path in temp directory.

    .PARAMETER ElevateToSystem
    Whether to attempt elevation to SYSTEM privileges.

    .EXAMPLE
    $config = Initialize-ForensicCollection -CollectionPath "C:\Investigation" -ElevateToSystem

    .OUTPUTS
    PSCustomObject with Success, CollectionPath, and Message properties.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$CollectionPath,
        [switch]$ElevateToSystem
    )

    try {
        # Generate collection path if not provided
        if (-not $CollectionPath) {
            $CollectionPath = Join-Path $env:TEMP "$script:CollectionDirPrefix$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        }

        # Check current privilege level
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = ([Security.Principal.WindowsPrincipal]$currentUser).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $isSystem = $currentUser.IsSystem

        Write-Verbose "Current user: $($currentUser.Name) | Admin: $isAdmin | SYSTEM: $isSystem"

        # Handle SYSTEM elevation if requested
        if ($ElevateToSystem -and -not $isSystem) {
            if (-not $isAdmin) {
                return [PSCustomObject]@{
                    Success        = $false
                    CollectionPath = $null
                    Message        = 'Administrative privileges required for SYSTEM elevation'
                }
            }

            if (Get-Command Get-SYSTEM -ErrorAction SilentlyContinue) {
                Write-Information 'Attempting elevation to SYSTEM privileges...' -InformationAction Continue
                $elevationResult = Start-ForensicSystemElevation -CollectionPath $CollectionPath
                if ($elevationResult.Success) {
                    return $elevationResult
                }
                Write-Warning 'SYSTEM elevation failed, continuing with current privileges'
            }
            else {
                Write-Warning 'Get-SYSTEM function not available, continuing with current privileges'
            }
        }

        # Create collection directory
        if (-not (Test-Path $CollectionPath)) {
            New-Item -Path $CollectionPath -ItemType Directory -Force | Out-Null
            Write-Verbose "Created collection directory: $CollectionPath"
        }

        return [PSCustomObject]@{
            Success        = $true
            CollectionPath = $CollectionPath
            Message        = 'Collection initialized successfully'
        }
    }
    catch {
        return [PSCustomObject]@{
            Success        = $false
            CollectionPath = $null
            Message        = $_.Exception.Message
        }
    }
}

function Get-ForensicArtifactsData {
    <#
    .SYNOPSIS
    Downloads and parses forensic artifact definitions from the remote repository.

    .DESCRIPTION
    Retrieves the Windows artifacts YAML file from the ForensicArtifacts GitHub repository
    and converts it to PowerShell objects for processing.

    .PARAMETER SourceUrl
    URL of the YAML artifacts file to download.

    .EXAMPLE
    $artifacts = Get-ForensicArtifactsData -SourceUrl $url

    .OUTPUTS
    Array of artifact definition objects.
    #>
    [CmdletBinding()]
    [OutputType([Object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceUrl
    )

    try {
        Write-Verbose "Downloading artifacts from: $SourceUrl"
        $yamlContent = Invoke-RestMethod -Uri $SourceUrl -ErrorAction Stop

        Write-Verbose 'Parsing YAML content...'
        $artifacts = ConvertFrom-Yaml -AllDocuments $yamlContent

        Write-Verbose "Successfully parsed $($artifacts.Count) artifact definitions"
        return $artifacts
    }
    catch {
        Write-Error "Failed to download or parse artifacts data: $($_.Exception.Message)" -ErrorAction Stop
    }
}

function Test-ArtifactFilter {
    <#
    .SYNOPSIS
    Tests whether an artifact matches the specified filter criteria.

    .DESCRIPTION
    Evaluates artifact names against filter patterns to determine if the artifact
    should be included in processing.

    .PARAMETER Artifact
    The artifact object to test.

    .PARAMETER Filter
    Array of filter strings to match against.

    .EXAMPLE
    $match = Test-ArtifactFilter -Artifact $artifact -Filter @("Browser", "Registry")

    .OUTPUTS
    Boolean indicating whether the artifact matches the filter.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Artifact,

        [string[]]$Filter = @()
    )

    # If no filter specified, include all artifacts
    if (-not $Filter -or $Filter.Count -eq 0) {
        return $true
    }

    # Clean and validate filters
    $validFilters = $Filter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not $validFilters) {
        return $true
    }

    # Test artifact name against each filter
    foreach ($filterPattern in $validFilters) {
        if ($Artifact.name -like "*$filterPattern*") {
            Write-Verbose "Artifact '$($Artifact.name)' matches filter '$filterPattern'"
            return $true
        }
    }

    Write-Verbose "Artifact '$($Artifact.name)' does not match any filters"
    return $false
}
