<#
.SYNOPSIS
    Download and import PowerShell cmdlets into an in-memory module or local cache.

.DESCRIPTION
    This function provides two modes for downloading and importing PowerShell cmdlets:

    • URL mode: Download .ps1 files from specific URLs and create an in-memory module
    • Repository mode: Download cmdlets by name from a GitHub repository and create an in-memory module

    By default, cmdlets are loaded into a temporary in-memory module that can be easily unloaded.
    Use -PreferLocal to save cmdlets to disk and import from the local cache instead.

.PARAMETER Urls
    Array of URLs pointing to .ps1 files to download and import. Used in URL mode.

.PARAMETER ModuleName
    Name for the in-memory module when not using -PreferLocal. Default is 'InMemoryModule'.

.PARAMETER RepositoryCmdlets
    Array of cmdlet names to download from the GitHub repository. Used in Repository mode.
    The function will construct URLs using the GitHubRepositoryUrl parameter.

.PARAMETER PreferLocal
    Switch to enable local caching mode. When specified:
    - Checks for existing cmdlets in LocalModuleFolder first
    - Downloads missing cmdlets and saves them to disk
    - Imports from the local cache folder instead of creating an in-memory module

.PARAMETER LocalModuleFolder
    Path to the local cache folder for storing downloaded cmdlets.
    Default: "$ENV:USERPROFILE\PowerShellScriptsAndResources\Modules\cmdletCollection\"

.PARAMETER Force
    When used with -PreferLocal, forces re-download of existing cmdlets.
    Has no effect when -PreferLocal is not specified.

.PARAMETER TimeoutSeconds
    Timeout in seconds for web requests. Valid range: 5-300. Default: 30.

.PARAMETER RequireHttps
    Switch to enforce HTTPS-only URLs for security.

.PARAMETER GitHubRepositoryUrl
    Base URL for the GitHub repository in Repository mode.
    Default: 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/'

.OUTPUTS
    System.Management.Automation.PSModuleInfo
        When -PreferLocal is not specified, returns the in-memory module object.

    System.IO.FileInfo
        When -PreferLocal is specified, returns the paths to downloaded .ps1 files.

.EXAMPLE
    Install-Cmdlet -RepositoryCmdlets 'Get-FileDownload', 'Format-Bytes'

    Downloads the specified cmdlets from the repository and creates an in-memory module.

.EXAMPLE
    Install-Cmdlet -Urls 'https://example.com/MyFunction.ps1' -ModuleName 'MyCustomModule'

    Downloads the script from the URL and imports it into an in-memory module named 'MyCustomModule'.

.EXAMPLE
    Install-Cmdlet -RepositoryCmdlets 'Get-FileDownload' -PreferLocal

    Downloads the cmdlet to the local cache folder and imports from disk.

.EXAMPLE
    Install-Cmdlet -RepositoryCmdlets 'Get-FileDownload' -PreferLocal -Force

    Forces re-download of the cmdlet even if it exists locally, then imports from disk.

.NOTES
    - Default behavior creates temporary in-memory modules that don't persist between sessions
    - Use -PreferLocal for persistent cmdlet storage and faster subsequent loads
    - The function includes script validation and BOM/encoding cleanup
    - Supports WhatIf and Confirm parameters for safe operation
#>
function Install-Cmdlet {
    [CmdletBinding(SupportsShouldProcess = $true,
        ConfirmImpact = 'Medium',
        DefaultParameterSetName = 'Repository')]
    [OutputType([System.Management.Automation.PSModuleInfo],  # when -PreferLocal:$false
        [System.IO.FileInfo])]                         # when -PreferLocal:$true
    param(
        # ------- PARAMETER-SET: Url ----------------------------------------
        [Parameter(Mandatory, ParameterSetName = 'Url', Position = 0)]
        [Alias('Url', 'Uri')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Urls,

        [Parameter(ParameterSetName = 'Url', Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleName = 'InMemoryModule',

        # ------- PARAMETER-SET: Repository ---------------------------------
        [Parameter(Mandatory,
            ParameterSetName = 'Repository',
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true)]
        [Alias('CmdletName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$RepositoryCmdlets,

        # ------- Common switches / settings --------------------------------
        [switch]$PreferLocal,
        [ValidateScript({
                if ([string]::IsNullOrWhiteSpace($_)) {
                    throw 'LocalModuleFolder cannot be empty'
                }
                if (-not [System.IO.Path]::IsPathRooted($_)) {
                    throw 'LocalModuleFolder must be an absolute path'
                }
                $true
            })]
        [string]$LocalModuleFolder =
        "$ENV:USERPROFILE\PowerShellScriptsAndResources\Modules\cmdletCollection\",
        [switch]$Force,
        [ValidateRange(5, 300)][int]$TimeoutSeconds = 30,
        [switch]$RequireHttps,
        [ValidateNotNullOrEmpty()]
        [string]$GitHubRepositoryUrl =
        'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/'
    )

    # ------------------------------------------------------------------ #
    #  BEGIN – helper functions & one-time setup                         #
    # ------------------------------------------------------------------ #
    begin {
        # -- Helper: validate URL format + enforce https (optional) ------
        function Test-ValidUrl {
            param(
                [string]$Url,
                [switch]$RequireHttps
            )
            $pattern = '^(https?):\/\/[-\w+&@#/%?=~_|!:,.;]+[-\w+&@#/%=~_|]$'
            if ($Url -notmatch $pattern) {
                return $false
            }
            if ($RequireHttps -and -not $Url.StartsWith('https://')) {
                return $false
            }
            return $true
        }

        # -- Helper: strip BOM / zero-width chars; quick AST check -------
        function Get-CleanScriptContent {
            param([string]$Content)

            $clean = $Content `
                -replace ([char]0xFEFF), '' `
                -replace ([char]0x200B), ''

            try {
                [System.Management.Automation.Language.Parser]::ParseInput(
                    $clean, [ref]$null, [ref]$null) | Out-Null
            }
            catch {
                Write-Verbose 'Code parsed with non-fatal errors.'
            }
            return $clean
        }

        # -- Helper: create cache folder & preview-safe manifest ---------
        function Initialize-LocalModuleEnvironment {
            param([string]$Folder)

            try {
                if (-not (Test-Path $Folder)) {
                    New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null
                }

                # Autoloader .psm1
                $psm1 = Join-Path $Folder 'cmdletCollection.psm1'
                if (-not (Test-Path $psm1)) {
                    @'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem $here -Filter "*.ps1" | ForEach-Object { . $_.FullName }
Export-ModuleMember -Function * -Alias *
'@ | Set-Content -Path $psm1 -Encoding UTF8 -ErrorAction Stop
                }

                # Manifest .psd1
                $psd1 = Join-Path $Folder 'cmdletCollection.psd1'
                if (-not (Test-Path $psd1)) {
                    $v = $PSVersionTable.PSVersion
                    $ver = '{0}.{1}.{2}' -f $v.Major, $v.Minor, $v.Build
                    New-ModuleManifest -Path $psd1 `
                        -RootModule 'cmdletCollection.psm1' `
                        -ModuleVersion '1.0.0' `
                        -Author 'Auto-generated' `
                        -Description 'Cached cmdlet collection' `
                        -PowerShellVersion $ver.Trim('.') `
                        -ErrorAction Stop
                }
                return (Get-Item $psm1 -ErrorAction Stop)
            }
            catch {
                throw "Failed to initialize local module environment in '$Folder': $($_.Exception.Message)"
            }
        }

        # -- Helper: save script to cache, UTF-8 no BOM ------------------
        function Save-CmdletToLocalFolder {
            param(
                [string]$Code,
                [string]$Name,
                [string]$Folder
            )
            try {
                $path = Join-Path $Folder "$Name.ps1"
                $clean = Get-CleanScriptContent $Code

                if ([string]::IsNullOrWhiteSpace($clean)) {
                    throw 'Script content is empty or invalid after cleaning'
                }

                [IO.File]::WriteAllText($path, $clean)   # UTF-8 w/o BOM

                if (-not (Test-Path $path)) {
                    throw 'File was not created successfully'
                }

                return $path
            }
            catch {
                throw "Failed to save cmdlet '$Name' to '$Folder': $($_.Exception.Message)"
            }
        }

        # -- Helper: sanitize cmdlet name to prevent path traversal -------
        function Test-SafeCmdletName {
            param([string]$Name)

            if ([string]::IsNullOrWhiteSpace($Name)) {
                return $false
            }

            # Check for path traversal attempts
            if ($Name -match '\.\.[\\/]|[\\/]\.\.') {
                return $false
            }

            # Check for invalid filename characters
            $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
            foreach ($char in $invalidChars) {
                if ($Name.Contains($char)) {
                    return $false
                }
            }

            # Must be a valid PowerShell identifier pattern
            if ($Name -notmatch '^[A-Za-z][\w-]*$') {
                return $false
            }

            return $true
        }

        # One-time init objects
        $needsDownload = [System.Collections.Generic.List[string]]::new()
        $sbInMemory = [System.Text.StringBuilder]::new()
        $importResult = $null

        # Input validation
        try {
            # Validate LocalModuleFolder path
            if (-not [System.IO.Path]::IsPathRooted($LocalModuleFolder)) {
                throw "LocalModuleFolder must be an absolute path: $LocalModuleFolder"
            }

            # Validate GitHubRepositoryUrl
            if (-not (Test-ValidUrl $GitHubRepositoryUrl -RequireHttps:$RequireHttps)) {
                throw "Invalid GitHubRepositoryUrl: $GitHubRepositoryUrl"
            }

            # Validate cmdlet names (Repository mode)
            if ($PSCmdlet.ParameterSetName -eq 'Repository') {
                foreach ($cmdletName in $RepositoryCmdlets) {
                    if (-not (Test-SafeCmdletName $cmdletName)) {
                        throw "Invalid cmdlet name '$cmdletName'. Names must be valid PowerShell identifiers without path traversal characters."
                    }
                }
            }

            # Validate URLs (URL mode)
            if ($PSCmdlet.ParameterSetName -eq 'Url') {
                foreach ($url in $Urls) {
                    if (-not (Test-ValidUrl $url -RequireHttps:$RequireHttps)) {
                        throw "Invalid URL: $url"
                    }
                }
            }

            # Validate ModuleName
            if (-not (Test-SafeCmdletName $ModuleName)) {
                throw "Invalid ModuleName '$ModuleName'. Must be a valid PowerShell identifier."
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        # Pre-create cache folder if needed
        if ($PreferLocal -or $PSCmdlet.ParameterSetName -eq 'Repository') {
            try {
                $psm1File = Initialize-LocalModuleEnvironment $LocalModuleFolder
                Write-Verbose "Initialized local module environment at '$LocalModuleFolder'"
            }
            catch {
                $PSCmdlet.ThrowTerminatingError((New-Object System.Management.Automation.ErrorRecord(
                            (New-Object System.InvalidOperationException("Failed to initialize local module environment: $($_.Exception.Message)", $_.Exception)),
                            'ModuleInitializationFailed',
                            [System.Management.Automation.ErrorCategory]::InvalidOperation,
                            $LocalModuleFolder
                        )))
            }
        }
    } # end begin

    # ------------------------------------------------------------------ #
    #  PROCESS – handle each pipeline input                              #
    # ------------------------------------------------------------------ #
    process {
        if (-not $PSCmdlet.ShouldProcess('Input data', 'Install cmdlet(s)')) {
            return
        }

        switch ($PSCmdlet.ParameterSetName) {

            # ----- REPOSITORY MODE -------------------------------------
            'Repository' {
                foreach ($name in $RepositoryCmdlets) {
                    if ($PreferLocal) {
                        $localPath = Join-Path $LocalModuleFolder "$name.ps1"
                        $exists = Test-Path $localPath

                        if (!$exists) {
                            $needsDownload.Add($name)
                        }
                        elseif ($Force) {
                            Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                            $needsDownload.Add($name)
                        }
                    }
                    else {
                        # In-memory mode: always download
                        $needsDownload.Add($name)
                    }
                }

                foreach ($item in $needsDownload) {
                    $url = "$GitHubRepositoryUrl$item.ps1"
                    if (-not (Test-ValidUrl $url -RequireHttps:$RequireHttps)) {
                        Write-Warning "Bad URL skipped: $url"
                        continue
                    }

                    try {
                        Write-Verbose "Downloading cmdlet '$item' from '$url'"
                        $code = Invoke-RestMethod $url -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                        $clean = Get-CleanScriptContent $code

                        if ($PreferLocal) {
                            Save-CmdletToLocalFolder -Code $clean -Name $item -Folder $LocalModuleFolder | Out-Null
                            Write-Verbose "Saved '$item' to local cache"
                        }
                        else {
                            $null = $sbInMemory.AppendLine($clean)
                            Write-Verbose "Added '$item' to in-memory module"
                        }
                    }
                    catch {
                        Write-Warning "Failed to download cmdlet '$item' from '$url': $($_.Exception.Message)" -ErrorAction Continue
                        continue
                    }
                }
            } # end Repository

            # ----- URL MODE -------------------------------------------
            'Url' {
                foreach ($u in $Urls) {
                    if (-not (Test-ValidUrl $u -RequireHttps:$RequireHttps)) {
                        Write-Warning "Bad URL skipped: $u"
                        continue
                    }

                    $name = ([IO.Path]::GetFileNameWithoutExtension($u))

                    try {
                        Write-Verbose "Downloading script '$name' from '$u'"
                        $code = Invoke-RestMethod $u -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                        $clean = Get-CleanScriptContent $code

                        if ($PreferLocal) {
                            $localPath = Join-Path $LocalModuleFolder "$name.ps1"
                            if ($Force -and $(Test-Path $localPath -ErrorAction SilentlyContinue)) {
                                Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                            }
                            Save-CmdletToLocalFolder -Code $clean -Name $name -Folder $LocalModuleFolder | Out-Null
                            Write-Verbose "Saved '$name' to local cache"
                        }
                        else {
                            $null = $sbInMemory.AppendLine($clean)
                            Write-Verbose "Added '$name' to in-memory module"
                        }
                    }
                    catch {
                        Write-Error "Failed to download script '$name' from '$u': $($_.Exception.Message)" -ErrorAction Continue
                        continue
                    }
                }
            } # end Url
        }

        # Build a dynamic module if we have memory-only code
        if (($sbInMemory.Length -gt 0) -and (-not $PreferLocal)) {
            try {
                Write-Verbose "Creating in-memory module '$ModuleName' with $($sbInMemory.Length) characters of code"
                $scriptContent = $sbInMemory.ToString().Trim()

                if ([string]::IsNullOrWhiteSpace($scriptContent)) {
                    Write-Warning 'No valid script content found for in-memory module'
                    return
                }

                $modSB = [scriptblock]::Create($scriptContent)
                $importResult = New-Module -Name $ModuleName -ScriptBlock $modSB -ErrorAction Stop |
                    Import-Module -Force -Global -PassThru -ErrorAction Stop
                Write-Verbose "Successfully created and imported in-memory module '$ModuleName'"
            }
            catch {
                Write-Error "Failed to create in-memory module '$ModuleName': $($_.Exception.Message)" -ErrorAction Stop
            }
        }
        # Or re-import cache loader if we just wrote new scripts
        elseif ($PreferLocal -and $needsDownload.Count -gt 0) {
            try {
                if ($null -eq $psm1File -or -not (Test-Path $psm1File.FullName)) {
                    throw 'Module file not found or not properly initialized'
                }

                Write-Verbose "Importing local module from '$($psm1File.FullName)'"
                $importResult = Import-Module $psm1File.FullName -Force -Global -PassThru -ErrorAction Stop
                Write-Verbose "Successfully imported local module '$($importResult.Name)'"
            }
            catch {
                Write-Error "Failed to import local module from '$($psm1File.FullName)': $($_.Exception.Message)" -ErrorAction Stop
            }
        }
    } # end process

    # ------------------------------------------------------------------ #
    #  END – final output                                                #
    # ------------------------------------------------------------------ #
    end {
        if ($PreferLocal) {
            # Build list of expected cmdlet names based on parameter set
            $expectedNames = switch ($PSCmdlet.ParameterSetName) {
                'Repository' {
                    $RepositoryCmdlets
                }
                'Url' {
                    $Urls | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) }
                }
            }

            $localPaths = Get-ChildItem $LocalModuleFolder -Filter '*.ps1' |
                Where-Object { $_.BaseName -in $expectedNames } |
                    Select-Object -ExpandProperty FullName
            return $localPaths
        }
        else {
            return $importResult
        }
    }
} # end function Install-Cmdlet