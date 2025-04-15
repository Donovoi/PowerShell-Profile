<#
.SYNOPSIS
    Installs PowerShell cmdlets from URLs or locally with robust error handling and configuration options.

.DESCRIPTION
    The Install-Cmdlet function is an advanced PowerShell function that provides multiple methods for
    installing and importing cmdlets:

    1. Download from URLs directly into memory (creating a dynamic module)
    2. Download from URLs and save locally (for future use)
    3. Import existing cmdlets from a local repository

    The function supports batch operations, allowing multiple cmdlets to be installed at once.
    It implements robust error handling, validates URLs for security, and cleans content to
    ensure compatibility across different PowerShell versions.

.PARAMETER Urls
    Specifies one or more URLs from which to download PowerShell cmdlets.
    These URLs should point directly to .ps1 files containing valid PowerShell functions.
    This parameter is mandatory when using the 'Url' parameter set.

.PARAMETER CmdletNames
    Specifies which cmdlets to install from the provided URLs.
    By default, all cmdlets found in the URLs will be installed.
    This parameter is optional when using the 'Url' parameter set.

.PARAMETER ModuleName
    Specifies the name for the in-memory module when installing cmdlets from URLs.
    The default value is 'InMemoryModule'.

.PARAMETER RepositoryCmdlets
    Specifies the names of cmdlets to install from the repository.
    These cmdlets will be downloaded from the GitHub repository or loaded from local storage.
    This parameter is mandatory when using the 'RepositoryCmdlets' parameter set.

.PARAMETER PreferLocal
    When specified, the function will first check if the requested cmdlets exist locally
    before attempting to download them. If they exist locally, they will be imported directly.
    This helps reduce network usage and improves performance for previously downloaded cmdlets.

.PARAMETER LocalModuleFolder
    Specifies the folder path where cmdlets will be saved when downloading.
    This folder also serves as the location to check when using -PreferLocal.
    Default: "$PSScriptRoot\PowerShellScriptsAndResources\Modules\cmdletCollection\"

.PARAMETER ContainsClass
    Indicates that the cmdlets being installed contain PowerShell classes.
    This affects how the cmdlets are imported to ensure proper class loading.

.PARAMETER Force
    When specified, forces re-downloading of cmdlets even if they already exist locally.
    Use this parameter to refresh local copies with the latest versions from the repository.

.PARAMETER TimeoutSeconds
    Specifies the timeout in seconds for web requests when downloading cmdlets.
    The default is 30 seconds. Increase this value for slower connections.

.PARAMETER RequireHttps
    When specified, enforces that all URLs must use HTTPS protocol for security.
    This helps prevent downloading content from insecure sources.

.PARAMETER GitHubRepositoryUrl
    Specifies the base URL for the GitHub repository where cmdlets are stored.
    Default: "https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/"

.INPUTS
    System.String
    You can pipe cmdlet names to Install-Cmdlet via the RepositoryCmdlets parameter.

.OUTPUTS
    System.Management.Automation.PSModuleInfo or System.IO.FileInfo
    Returns the imported in-memory module object or the path to the local module file.

.EXAMPLE
    Install-Cmdlet -Urls 'https://example.com/Get-SystemInfo.ps1' -ModuleName 'AdminTools'

    Downloads the Get-SystemInfo.ps1 script from the specified URL and creates an in-memory
    module named 'AdminTools' containing the cmdlet.

.EXAMPLE
    Install-Cmdlet -RepositoryCmdlets 'Get-FileEncoding', 'ConvertTo-Jpeg' -PreferLocal

    Imports the Get-FileEncoding and ConvertTo-Jpeg cmdlets from the local module folder if they exist.
    If they don't exist locally, downloads them from the GitHub repository and saves them locally
    before importing.

.EXAMPLE
    Install-Cmdlet -RepositoryCmdlets 'Get-SystemInfo' -Force -Verbose

    Forces re-downloading of the Get-SystemInfo cmdlet from the GitHub repository even if it
    already exists locally, and provides verbose output during the operation.

.EXAMPLE
    'Get-FileEncoding' | Install-Cmdlet -PreferLocal

    Imports the Get-FileEncoding cmdlet from the local module folder if it exists.
    Demonstrates how cmdlet names can be piped to the function.

.NOTES
    Author: [Your Name]
    Last Updated: $(Get-Date -Format "yyyy-MM-dd")

    For security reasons, consider using the -RequireHttps switch to ensure all downloads
    occur over secure connections.

.LINK
    https://github.com/Donovoi/PowerShell-Profile
#>
function Install-Cmdlet {
    [CmdletBinding(
        DefaultParameterSetName = 'RepositoryCmdlets',
        SupportsShouldProcess = $true,
        ConfirmImpact = 'Medium'
    )]
    [OutputType([System.Management.Automation.PSModuleInfo], [System.IO.FileInfo])]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'Url', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [Alias('Url', 'Uri')]
        [string[]]$Urls,

        [Parameter(Mandatory = $false, ParameterSetName = 'Url', Position = 1)]
        [ValidateNotNullOrEmpty()]
        [Alias('Cmdlet', 'CmdletToInstall')]
        [string[]]$CmdletNames = '*',

        [Parameter(Mandatory = $false, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleName = 'InMemoryModule',

        [Parameter(
            Mandatory = $true,
            ParameterSetName = 'RepositoryCmdlets',
            Position = 0,
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true
        )]
        [ValidateNotNullOrEmpty()]
        [Alias('Donovoicmdlets', 'CmdletName')]
        [string[]]$RepositoryCmdlets,

        [Parameter(Mandatory = $false)]
        [switch]$PreferLocal,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$LocalModuleFolder = "$ENV:USERPROFILE\PowerShellScriptsAndResources\Modules\cmdletCollection\",

        [Parameter(Mandatory = $false)]
        [switch]$ContainsClass,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 30,

        [Parameter(Mandatory = $false)]
        [switch]$RequireHttps,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$GitHubRepositoryUrl = 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/'
    )    begin {
        # Initialize helper functions to follow Single Responsibility Principle
        function Initialize-LocalModuleEnvironment {
            [CmdletBinding()]
            [OutputType([System.IO.FileInfo])]
            param (
                [Parameter(Mandatory = $true)]
                [ValidateNotNullOrEmpty()]
                [string]$ModuleFolderPath
            )

            try {
                Write-Verbose "Initializing local module environment at: $ModuleFolderPath"

                # Ensure the module folder exists
                if (-not (Test-Path -Path $ModuleFolderPath)) {
                    if ($PSCmdlet.ShouldProcess($ModuleFolderPath, 'Create module directory')) {
                        $null = New-Item -Path $ModuleFolderPath -ItemType Directory -Force
                        Write-Verbose "Created module directory: $ModuleFolderPath"
                    }
                }

                # Create or update the module manifest file
                $moduleFilePath = Join-Path -Path $ModuleFolderPath -ChildPath 'cmdletCollection.psm1'

                if ($PSCmdlet.ShouldProcess($moduleFilePath, 'Create or update module manifest file')) {
                    # Modern module loader that handles dot-sourcing all PS1 files
                    $moduleContent = @'
# Auto-generated module file for cmdlet collection
# This module dot-sources all PS1 files in the same directory
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem -Path $ScriptPath -Filter "*.ps1" | ForEach-Object {
    try {
        . $_.FullName
        Write-Verbose "Imported: $($_.Name)"
    }
    catch {
        Write-Error "Failed to import: $($_.Name) - $_"
    }
}
# Export all functions and aliases for module users
Export-ModuleMember -Function * -Alias *
'@
                    Set-Content -Path $moduleFilePath -Value $moduleContent -Force -Encoding UTF8
                    Write-Verbose "Created/Updated module manifest file: $moduleFilePath"

                    # Create module manifest if it doesn't exist
                    $manifestPath = Join-Path -Path $ModuleFolderPath -ChildPath 'cmdletCollection.psd1'
                    if (-not (Test-Path -Path $manifestPath)) {
                        $manifestParams = @{
                            Path              = $manifestPath
                            RootModule        = 'cmdletCollection.psm1'
                            ModuleVersion     = '1.0.0'
                            Author            = 'Auto-generated'
                            Description       = 'Collection of installed PowerShell cmdlets'
                            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
                        }

                        try {
                            New-ModuleManifest @manifestParams
                            Write-Verbose "Created module manifest: $manifestPath"
                        }
                        catch {
                            Write-Warning "Failed to create module manifest. Continuing without it: $_"
                        }
                    }

                    return Get-Item -Path $moduleFilePath
                }
            }
            catch {
                Write-Error "Failed to initialize module environment: $_"
                throw
            }
        }

        function Test-ValidUrl {
            [CmdletBinding()]
            [OutputType([bool])]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Url,

                [Parameter(Mandatory = $false)]
                [switch]$RequireHttps
            )

            try {
                # Basic URL validation
                $validUrlPattern = '^(https?):\/\/[-A-Za-z0-9+&@#\/%?=~_|!:,.;]+[-A-Za-z0-9+&@#\/%=~_|]$'
                $isValidUrl = $Url -match $validUrlPattern

                # Additional HTTPS validation if required
                if ($isValidUrl -and $RequireHttps -and -not $Url.StartsWith('https://')) {
                    Write-Warning "URL security issue: $Url does not use HTTPS protocol"
                    return $false
                }

                return $isValidUrl
            }
            catch {
                Write-Error "Error validating URL '$Url': $_"
                return $false
            }
        }

        function Get-CleanScriptContent {
            [CmdletBinding()]
            [OutputType([string])]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Content
            )

            try {
                # Remove BOM and zero-width characters
                $cleanContent = $Content -replace ([char]0xFEFF), '' -replace ([char]0x200B), ''

                # Check if the content is valid PowerShell
                try {
                    $null = [System.Management.Automation.Language.Parser]::ParseInput($cleanContent, [ref]$null, [ref]$null)
                    Write-Verbose 'PowerShell code validation passed'
                }
                catch {
                    Write-Warning "Downloaded content may not be valid PowerShell code: $_"
                    # Continue anyway, as the error might be benign
                }

                return $cleanContent
            }
            catch {
                Write-Error "Error cleaning script content: $_"
                return $Content # Return original if cleaning fails
            }
        }

        function Save-CmdletToLocalFolder {
            [CmdletBinding(SupportsShouldProcess = $true)]
            [OutputType([bool])]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Content,

                [Parameter(Mandatory = $true)]
                [string]$CmdletName,

                [Parameter(Mandatory = $true)]
                [string]$OutputFolder
            )

            try {
                $outputPath = Join-Path -Path $OutputFolder -ChildPath "$CmdletName.ps1"

                if ($PSCmdlet.ShouldProcess($outputPath, 'Save cmdlet to file')) {
                    # Write content in a BOM-less way
                    $cleanContent = Get-CleanScriptContent -Content $Content

                    # First write the content
                    $cleanContent | Out-File -FilePath $outputPath -Force -Encoding UTF8

                    # Then read and rewrite to ensure no BOM
                    $rawContent = Get-Content -Path $outputPath -Raw
                    $cleanContent = Get-CleanScriptContent -Content $rawContent
                    [System.IO.File]::WriteAllText($outputPath, $cleanContent)

                    Write-Verbose "Successfully saved cmdlet '$CmdletName' to: $outputPath"
                    return $true
                }

                return $false
            }
            catch {
                Write-Error "Failed to save cmdlet '$CmdletName' to disk: $_"
                return $false
            }
        }

        # Initialize variables used across the process block
        $cmdletsToDownload = [System.Collections.Generic.List[string]]::new()
        $combinedScriptContent = [System.Text.StringBuilder]::new()
        $result = $null

        # Normalize parameter naming
        if ($PSCmdlet.ParameterSetName -eq 'RepositoryCmdlets') {
            $cmdletsToProcess = $RepositoryCmdlets
        }
        else {
            $cmdletsToProcess = $CmdletNames
        }
    }    process {
        try {
            Write-Verbose "Starting Install-Cmdlet in parameter set: $($PSCmdlet.ParameterSetName)"

            # Force will be handled per cmdlet in the individual processing sections
            # rather than deleting the entire module folder at once

            # Ensure local module folder exists if needed
            if ($PreferLocal -or ($PSCmdlet.ParameterSetName -eq 'RepositoryCmdlets')) {
                $moduleFile = Initialize-LocalModuleEnvironment -ModuleFolderPath $LocalModuleFolder
                Write-Verbose "Local module environment initialized: $moduleFile"
            }

            # Handle different parameter sets
            switch ($PSCmdlet.ParameterSetName) {
                'RepositoryCmdlets' {
                    Write-Verbose "Processing repository cmdlets: $($RepositoryCmdlets -join ', ')"

                    foreach ($cmdletName in $RepositoryCmdlets) {
                        $localCmdletPath = Join-Path -Path $LocalModuleFolder -ChildPath "$cmdletName.ps1"
                        $cmdletExistsLocally = Test-Path -Path $localCmdletPath

                        # Determine if we need to download this cmdlet
                        if (-not $cmdletExistsLocally -or $Force) {
                            if ($cmdletExistsLocally -and $Force) {
                                Write-Verbose "Forcing re-download of cmdlet: $cmdletName"
                                if ($PSCmdlet.ShouldProcess($localCmdletPath, 'Remove existing cmdlet file for forced re-download')) {
                                    Remove-Item -Path $localCmdletPath -Force
                                }
                            }
                            else {
                                Write-Verbose "Cmdlet not found locally, will download: $cmdletName"
                            }

                            $cmdletsToDownload.Add($cmdletName)
                        }
                        elseif ($PreferLocal) {
                            Write-Verbose "Using existing local cmdlet: $cmdletName"
                            if ($PSCmdlet.ShouldProcess($localCmdletPath, 'Import local cmdlet')) {
                                try {
                                    $importParams = @{
                                        Path        = $localCmdletPath
                                        Force       = $true
                                        ErrorAction = 'Stop'
                                    }

                                    if (-not $result) {
                                        $importParams['PassThru'] = $true
                                        $result = Import-Module @importParams
                                    }
                                    else {
                                        Import-Module @importParams
                                    }

                                    Write-Verbose "Successfully imported cmdlet from: $localCmdletPath"
                                }
                                catch {
                                    Write-Error "Failed to import cmdlet '$cmdletName' from local path: $_"
                                }
                            }
                        }
                    }

                    # Generate URLs for cmdlets that need downloading
                    if ($cmdletsToDownload.Count -gt 0) {
                        $urlsToProcess = @()
                        foreach ($cmdlet in $cmdletsToDownload) {
                            $url = "${GitHubRepositoryUrl}${cmdlet}.ps1"
                            $urlsToProcess += $url
                        }

                        Write-Verbose "Will download $($cmdletsToDownload.Count) cmdlets from repository"

                        # Process the generated URLs
                        foreach ($url in $urlsToProcess) {
                            if (-not (Test-ValidUrl -Url $url -RequireHttps:$RequireHttps)) {
                                Write-Error "Invalid URL: $url"
                                continue
                            }

                            $cmdletName = ($url.Split('/')[-1]).Split('.')[0]
                            Write-Verbose "Processing URL: $url for cmdlet: $cmdletName"

                            if ($PSCmdlet.ShouldProcess($url, 'Download cmdlet content')) {
                                try {
                                    $webRequestParams = @{
                                        Uri         = $url
                                        ErrorAction = 'Stop'
                                        TimeoutSec  = $TimeoutSeconds
                                    }

                                    $response = Invoke-RestMethod @webRequestParams
                                    $cleanContent = Get-CleanScriptContent -Content $response

                                    if ($PreferLocal) {
                                        # Save to disk for future use
                                        $saved = Save-CmdletToLocalFolder -Content $cleanContent -CmdletName $cmdletName -OutputFolder $LocalModuleFolder
                                        if ($saved) {
                                            Write-Verbose "Saved cmdlet to disk: $cmdletName"
                                        }
                                    }
                                    else {
                                        # Append to our in-memory collection
                                        $null = $combinedScriptContent.AppendLine($cleanContent)
                                    }
                                }
                                catch {
                                    Write-Error "Failed to download cmdlet from $url`: $_"
                                }
                            }
                        }
                    }
                }

                'Url' {
                    Write-Verbose "Processing direct URLs: $($Urls -join ', ')"

                    foreach ($url in $Urls) {
                        if (-not (Test-ValidUrl -Url $url -RequireHttps:$RequireHttps)) {
                            Write-Error "Invalid URL: $url"
                            continue
                        }

                        $cmdletName = ($url.Split('/')[-1]).Split('.')[0]
                        Write-Verbose "Processing URL: $url for cmdlet: $cmdletName"

                        if ($PSCmdlet.ShouldProcess($url, 'Download cmdlet content')) {
                            try {
                                $webRequestParams = @{
                                    Uri         = $url
                                    ErrorAction = 'Stop'
                                    TimeoutSec  = $TimeoutSeconds
                                }

                                $response = Invoke-RestMethod @webRequestParams
                                $cleanContent = Get-CleanScriptContent -Content $response

                                if ($PreferLocal) {
                                    # Save to disk for future use
                                    $saved = Save-CmdletToLocalFolder -Content $cleanContent -CmdletName $cmdletName -OutputFolder $LocalModuleFolder
                                    if ($saved) {
                                        Write-Verbose "Saved cmdlet to disk: $cmdletName"
                                    }
                                }

                                # Always add to in-memory collection for URL mode
                                $null = $combinedScriptContent.AppendLine($cleanContent)
                            }
                            catch {
                                Write-Error "Failed to download cmdlet from $url`: $_"
                            }
                        }
                    }
                }
            }

            # Create in-memory module if needed
            if ($combinedScriptContent.Length -gt 0 -and -not $PreferLocal) {
                Write-Verbose "Creating in-memory module: $ModuleName"

                if ($PSCmdlet.ShouldProcess('Memory', "Create in-memory module '$ModuleName'")) {
                    try {
                        $finalScript = $combinedScriptContent.ToString()
                        $scriptBlock = [scriptblock]::Create($finalScript)

                        $moduleParams = @{
                            Name        = $ModuleName
                            ScriptBlock = $scriptBlock
                        }

                        $result = New-Module @moduleParams | Import-Module -Global -Force -PassThru
                        Write-Verbose "Successfully created in-memory module: $ModuleName"
                    }
                    catch {
                        Write-Error "Failed to create in-memory module: $_"
                    }
                }
            }
            elseif ($PreferLocal -and $cmdletsToDownload.Count -gt 0) {
                # If we downloaded any cmdlets locally, import the module file
                Write-Verbose 'Importing local module collection'

                if ($PSCmdlet.ShouldProcess($moduleFile, 'Import module collection')) {
                    try {
                        $result = Import-Module -Name $moduleFile.FullName -Force -Global -PassThru
                        Write-Verbose "Successfully imported local module collection: $($moduleFile.FullName)"
                    }
                    catch {
                        Write-Error "Failed to import local module collection: $_"
                    }
                }
            }
        }
        catch {
            Write-Error "Failed to install cmdlets: $_"
            throw
        }
    }    end {
        # Return results
        if ($PreferLocal) {
            # When PreferLocal is specified, return the full path(s) to the script file(s)
            $paths = @()
            if ($RepositoryCmdlets) {
                foreach ($cmdletName in $RepositoryCmdlets) {
                    $cmdletPath = Join-Path -Path $LocalModuleFolder -ChildPath "$cmdletName.ps1"
                    if (Test-Path -Path $cmdletPath) {
                        $paths += $cmdletPath
                    } else {
                        Write-Warning "Cmdlet file not found: $cmdletPath"
                    }
                }
            }
            if ($Urls) {
                foreach ($url in $Urls) {
                    $cmdletName = ($url.Split('/')[-1]).Split('.')[0]
                    $cmdletPath = Join-Path -Path $LocalModuleFolder -ChildPath "$cmdletName.ps1"
                    if (Test-Path -Path $cmdletPath) {
                        $paths += $cmdletPath
                    } else {
                        Write-Warning "Cmdlet file not found: $cmdletPath"
                    }
                }
            }
            if ($paths.Count -eq 1) {
                return $paths[0]
            } elseif ($paths.Count -gt 1) {
                return $paths
            } else {
                Write-Warning "No cmdlet content found to return path(s)"
                return $null
            }
        }
        elseif ($result) {
            Write-Verbose "Returning module result: $($result.Name)"
            return $result
        }
        else {
            Write-Warning 'No result to return. Check for errors.'
            return $null
        }
    }
}