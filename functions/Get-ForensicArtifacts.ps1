function Get-ForensicArtifacts {
    <#
    .SYNOPSIS
    Retrieves and optionally collects Windows forensic artifacts from the ForensicArtifacts repository.

    .DESCRIPTION
    This function downloads forensic artifact definitions from the ForensicArtifacts GitHub repository,
    processes them according to specified parameters, and optionally collects artifacts from the local system.
    
    The function follows SOLID principles with modular design for maintainability and testability.
    It supports privilege elevation, comprehensive error handling, and provides detailed collection reports.

    .PARAMETER CollectionPath
    The path where collected artifacts will be stored. If not specified and collection is enabled,
    a default path in the temp directory will be used.

    .PARAMETER CollectArtifacts
    Switch to enable actual collection of artifacts from the file system and registry.

    .PARAMETER ArtifactFilter
    An array of strings to filter artifacts by name. Only artifacts containing these strings will be processed.

    .PARAMETER ExpandPaths
    Switch to expand environment variables and path patterns in the output.

    .PARAMETER ElevateToSystem
    Switch to attempt elevation to SYSTEM privileges before collecting artifacts.

    .PARAMETER ToolsPath
    Path where forensic tools will be downloaded and cached. Defaults to script directory.

    .PARAMETER SkipToolDownload
    Skip automatic download of forensic tools like RawCopy.

    .EXAMPLE
    Get-ForensicArtifacts
    
    Lists all available forensic artifacts without collecting them.

    .EXAMPLE
    Get-ForensicArtifacts -CollectArtifacts -CollectionPath "C:\Investigation" -Verbose
    
    Collects all forensic artifacts to the specified path with verbose output.

    .EXAMPLE
    Get-ForensicArtifacts -ArtifactFilter @("Browser", "Registry") -ExpandPaths
    
    Lists only browser and registry artifacts with expanded paths.

    .EXAMPLE
    Get-ForensicArtifacts -CollectArtifacts -ElevateToSystem -Verbose
    
    Collects artifacts with SYSTEM privileges for maximum access.

    .NOTES
    Author: PowerShell Profile Enhancement
    Version: 2.0.0
    
    This function requires internet connectivity to download artifact definitions.
    Administrative privileges are recommended for comprehensive artifact collection.
    SYSTEM privileges provide access to the most protected artifacts.

    .LINK
    https://github.com/ForensicArtifacts/artifacts

    .INPUTS
    None. This function does not accept pipeline input.

    .OUTPUTS
    System.Management.Automation.PSCustomObject[]
    Returns an array of forensic artifact objects with metadata and collection status.
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(
            ParameterSetName = 'Collect',
            HelpMessage = 'Path where collected artifacts will be stored'
        )]
        [ValidateScript({ 
                if ($_ -and -not [string]::IsNullOrWhiteSpace($_)) {
                    $parentDir = Split-Path $_ -Parent
                    if (-not (Test-Path $parentDir -PathType Container)) {
                        throw "Parent directory '$parentDir' must exist"
                    }
                }
                $true 
            })]
        [string]$CollectionPath,

        [Parameter(
            ParameterSetName = 'Collect',
            Mandatory,
            HelpMessage = 'Enable collection of artifacts from the file system'
        )]
        [switch]$CollectArtifacts,

        [Parameter(HelpMessage = 'Filter artifacts by name patterns')]
        [ValidateNotNull()]
        [string[]]$ArtifactFilter = @(),

        [Parameter(HelpMessage = 'Expand environment variables in paths')]
        [switch]$ExpandPaths,

        [Parameter(
            ParameterSetName = 'Collect',
            HelpMessage = 'Attempt to elevate to SYSTEM privileges'
        )]
        [switch]$ElevateToSystem,

        [Parameter(HelpMessage = 'Path where forensic tools will be stored')]
        [ValidateScript({ Test-Path (Split-Path $_ -Parent) -PathType Container })]
        [string]$ToolsPath = (Join-Path $PSScriptRoot 'Tools'),

        [Parameter(HelpMessage = 'Skip automatic download of forensic tools')]
        [switch]$SkipToolDownload
    )

    begin {
        # Initialize constants
        $script:ArtifactsSourceUrl = 'https://raw.githubusercontent.com/ForensicArtifacts/artifacts/main/artifacts/data/windows.yaml'
        $script:CollectionDirPrefix = 'ForensicArtifacts_'
        
        # Import needed cmdlets if not already available
        $neededcmdlets = @(
            'Install-Dependencies'     # For installing dependencies
            'Get-LatestGitHubRelease'  # For downloading aria2c if needed
            'Invoke-AriaDownload'
            'Get-FileDetailsFromResponse'
            'Get-OutputFilename'
            'Test-InPath'
            'Invoke-AriaRPCDownload'
            'Initialize-ForensicDependencies'
        )

        foreach ($cmd in $neededcmdlets) {
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
        # Validate and install dependencies
        Initialize-ForensicDependencies
        
        # Initialize collection configuration
        if ($CollectArtifacts) {
            $config = Initialize-ForensicCollection -CollectionPath $CollectionPath -ElevateToSystem:$ElevateToSystem
            if (-not $config.Success) {
                throw "Failed to initialize forensic collection: $($config.Message)"
            }
            $CollectionPath = $config.CollectionPath
        }
    }

    process {
        try {
            Write-Verbose 'Downloading forensic artifacts definitions...'
            $artifactsData = Get-ForensicArtifactsData -SourceUrl $script:ArtifactsSourceUrl
            
            Write-Verbose "Processing $($artifactsData.Count) artifact definitions..."
            $results = @()
            
            foreach ($artifact in $artifactsData) {
                if (Test-ArtifactFilter -Artifact $artifact -Filter $ArtifactFilter) {
                    $processedArtifact = ConvertTo-ForensicArtifact -ArtifactData $artifact -ExpandPaths:$ExpandPaths
                    
                    if ($CollectArtifacts) {
                        $collectionResult = Invoke-ForensicCollection -Artifact $processedArtifact -CollectionPath $CollectionPath -ToolsPath $ToolsPath -SkipToolDownload:$SkipToolDownload
                        $processedArtifact = $processedArtifact | Add-Member -NotePropertyName 'CollectionResult' -NotePropertyValue $collectionResult -PassThru
                    }
                    
                    $results += $processedArtifact
                }
            }
            
            if ($CollectArtifacts) {
                Write-ForensicCollectionReport -Results $results -CollectionPath $CollectionPath
            }
            
            return $results
        }
        catch {
            Write-Error "Failed to process forensic artifacts: $($_.Exception.Message)" -ErrorAction Stop
        }
    }

    end {
        if ($CollectArtifacts) {
            Write-Information "Forensic artifact collection completed. Results saved to: $CollectionPath" -InformationAction Continue
        }
    }
}
Get-ForensicArtifacts -CollectionPath 'C:\ForensicArtifacts' -CollectArtifacts -ExpandPaths -ElevateToSystem -Verbose -ErrorAction Break