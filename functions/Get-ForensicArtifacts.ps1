function Get-ForensicArtifacts {
    <#
    .SYNOPSIS
    Retrieves and optionally collects Windows forensic artifacts from the ForensicArtifacts repository.

    .DESCRIPTION
    This function downloads forensic artifact definitions from the ForensicArtifacts GitHub repository,
    processes them according to the specified parameters, and optionally collects the actual artifacts
    from the local system. Supports privilege elevation and comprehensive error handling.

    .PARAMETER CollectionPath
    The path where collected artifacts will be stored. If not specified and collection is enabled,
    a default path in the temp directory will be used.

    .PARAMETER CollectArtifacts
    Switch to enable actual collection of artifacts from the file system and registry.

    .PARAMETER ArtifactFilter
    A        }
    }
}of strings to filter artifacts by name. Only artifacts containing these strings will be processed.

    .PARAMETER ExpandPaths
    Switch to expand environment variables and path patterns in the output.

    .PARAMETER ElevateToSystem
    Switch to attempt elevation to SYSTEM privileges before collecting artifacts.

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
    This function requires internet connectivity to download artifact definitions.
    Administrative privileges are recommended for comprehensive artifact collection.
    SYSTEM privileges provide access to the most protected artifacts.

    .LINK
    https://github.com/ForensicArtifacts/artifacts
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param (
        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Path where collected artifacts will be stored'
        )]
        [ValidateScript({
                if ($_ -and -not [string]::IsNullOrWhiteSpace($_)) {
                    $parentDir = Split-Path $_ -Parent
                    if (-not (Test-Path $parentDir -PathType Container)) {
                        throw "Parent directory of collection path '$parentDir' must exist"
                    }
                }
                $true
            })]
        [string]$CollectionPath,

        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Enable collection of artifacts from the file system'
        )]
        [switch]$CollectArtifacts,

        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Filter artifacts by name patterns'
        )]
        [ValidateNotNull()]
        [string[]]$ArtifactFilter = @(),

        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Expand environment variables in paths'
        )]
        [switch]$ExpandPaths,

        [Parameter(
            Mandatory = $false,
            HelpMessage = 'Attempt to elevate to SYSTEM privileges'
        )]
        [switch]$ElevateToSystem
    )

    # Constants for better maintainability
    $ARTIFACTS_SOURCE_URL = 'https://raw.githubusercontent.com/ForensicArtifacts/artifacts/main/artifacts/data/windows.yaml'
    $CLEANUP_DELAY_SECONDS = 30
    $TEMP_SCRIPT_PREFIX = 'ForensicCollection_'
    $COLLECTION_DIR_PREFIX = 'ForensicArtifacts_'

    # Initialize script-level variables for caching
    if (-not $script:RawCopyDownloadAttempted) {
        $script:RawCopyDownloadAttempted = $false
    }
    if (-not $script:CachedForensicTools) {
        $script:CachedForensicTools = $null
    }

    # Check and install missing dependencies
    try {
        # Check for ConvertFrom-Yaml
        if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
            Write-Verbose 'ConvertFrom-Yaml not found. Installing powershell-yaml module...'
            if (Get-Command Install-Module -ErrorAction SilentlyContinue) {
                Install-Module -Name powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
                Import-Module powershell-yaml -Force
            }
            else {
                Write-Warning 'Install-Module not available. Please install powershell-yaml module manually.'
            }
        }

        # Check for Install-Cmdlet function
        if (-not (Get-Command Install-Cmdlet -ErrorAction SilentlyContinue)) {
            $installCmdletPath = Join-Path $PSScriptRoot 'Install-Cmdlet.ps1'
            if (Test-Path $installCmdletPath) {
                . $installCmdletPath
                Write-Verbose 'Imported Install-Cmdlet function'
            }
            else {
                Write-Verbose "Install-Cmdlet not found at: $installCmdletPath"
            }
        }

        # Use Install-Cmdlet to get any missing forensic-related functions
        if (Get-Command Install-Cmdlet -ErrorAction SilentlyContinue) {
            $missingCmdlets = @()

            # Check for Get-SYSTEM
            if (-not (Get-Command Get-SYSTEM -ErrorAction SilentlyContinue)) {
                $missingCmdlets += 'Get-SYSTEM'
            }

            if ($missingCmdlets.Count -gt 0) {
                Write-Verbose "Installing missing cmdlets: $($missingCmdlets -join ', ')"
                Install-Cmdlet -RepositoryCmdlets $missingCmdlets -PreferLocal
            }
        }
    }
    catch {
        Write-Verbose "Non-critical error installing dependencies: $($_.Exception.Message)"
    }

    # Validation and initialization
    if ($CollectArtifacts -and -not $CollectionPath) {
        $CollectionPath = Join-Path $env:TEMP "$COLLECTION_DIR_PREFIX$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        Write-Verbose "Auto-generated collection path: $CollectionPath"
    }

    # Early validation to fail fast
    if ($ArtifactFilter) {
        foreach ($filter in $ArtifactFilter) {
            if ([string]::IsNullOrWhiteSpace($filter)) {
                Write-Warning 'Empty filter detected and will be ignored'
            }
        }
        $ArtifactFilter = $ArtifactFilter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    # Check current privilege level and elevate if needed
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = ([Security.Principal.WindowsPrincipal]$currentUser).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $isSystem = $currentUser.IsSystem

    Write-Verbose "Current user: $($currentUser.Name)"
    Write-Verbose "Is Administrator: $isAdmin"
    Write-Verbose "Is SYSTEM: $isSystem"

    # If collecting artifacts and not running as SYSTEM, try to elevate
    if ($CollectArtifacts -and $ElevateToSystem -and -not $isSystem) {
        if (-not $isAdmin) {
            Write-Warning 'Administrative privileges required for SYSTEM elevation. Please run as administrator first.'
            return
        }

        Write-Information 'Elevating to SYSTEM privileges for forensic collection...' -InformationAction Continue

        # Check if Get-SYSTEM function is available
        if (-not (Get-Command Get-SYSTEM -ErrorAction SilentlyContinue)) {
            # Try to import it from the functions directory
            $getSystemPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'functions\Get-SYSTEM.ps1'
            if (Test-Path $getSystemPath) {
                . $getSystemPath
            }
            else {
                Write-Warning 'Get-SYSTEM function not found. Please ensure Get-SYSTEM.ps1 is available.'
                Write-Information 'Continuing with current privileges...' -InformationAction Continue
            }
        }

        # If Get-SYSTEM is available and we're not already SYSTEM, elevate
        if ((Get-Command Get-SYSTEM -ErrorAction SilentlyContinue) -and -not $isSystem) {
            try {
                # Build the command to run in the elevated context
                $filterString = if ($ArtifactFilter) {
                    "@('" + ($ArtifactFilter -join "','") + "')"
                }
                else {
                    '@()'
                }

                # Get the current script path more reliably
                $currentScriptPath = if ($MyInvocation.MyCommand.Path) {
                    $MyInvocation.MyCommand.Path
                }
                elseif ($PSCommandPath) {
                    $PSCommandPath
                }
                else {
                    # Fallback: try to find the script in the functions directory
                    $functionsDir = Split-Path $PSScriptRoot -Parent | Join-Path -ChildPath 'functions'
                    Join-Path $functionsDir 'Get-ForensicArtifacts.ps1'
                }

                Write-Verbose "Using script path for elevation: $currentScriptPath"

                # Try to read the current script content for embedding
                $scriptContent = $null
                if (Test-Path $currentScriptPath) {
                    try {
                        $scriptContent = Get-Content $currentScriptPath -Raw
                        Write-Verbose 'Successfully read script content for embedding'
                    }
                    catch {
                        Write-Verbose "Could not read script content: $($_.Exception.Message)"
                    }
                }

                # Build the elevated script - embed the function if possible, otherwise dot-source
                if ($scriptContent) {
                    $scriptBlock = @"
# Check for and install dependencies in elevated context
if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    try {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
        Import-Module powershell-yaml -Force
    } catch {
        Write-Warning "Failed to install powershell-yaml: `$_"
    }
}

# Embedded forensic artifacts function
$scriptContent

# Execute the function
Get-ForensicArtifacts -CollectionPath '$CollectionPath' -CollectArtifacts -ArtifactFilter $filterString -Verbose
"@
                }
                else {
                    # Fallback to dot-sourcing if we can't embed
                    if (-not (Test-Path $currentScriptPath)) {
                        throw "Cannot locate the current script file for elevation: $currentScriptPath"
                    }

                    $scriptBlock = @"
# Check for and install dependencies in elevated context
if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    try {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
        Import-Module powershell-yaml -Force
    } catch {
        Write-Warning "Failed to install powershell-yaml: `$_"
    }
}

# Import the forensic artifacts function
. '$currentScriptPath'
Get-ForensicArtifacts -CollectionPath '$CollectionPath' -CollectArtifacts -ArtifactFilter $filterString -Verbose
"@
                }

                Write-Verbose 'Executing forensic collection as SYSTEM...'
                $tempScript = Join-Path $env:TEMP "$TEMP_SCRIPT_PREFIX$(Get-Date -Format 'yyyyMMddHHmmss').ps1"
                $scriptBlock | Out-File -FilePath $tempScript -Encoding UTF8

                # Launch as SYSTEM with appropriate PowerShell version
                $preferPwsh = Get-Command pwsh -ErrorAction SilentlyContinue
                if ($preferPwsh) {
                    $systemArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
                    Write-Verbose 'Using PowerShell 7+ (pwsh) for SYSTEM elevation'
                }
                else {
                    $systemArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`""
                    Write-Verbose 'Using Windows PowerShell 5.1 for SYSTEM elevation'
                }

                Write-Verbose "Starting SYSTEM process with arguments: $systemArgs"

                # Call Get-SYSTEM with appropriate PowerShell path
                if ($preferPwsh) {
                    $systemProcess = Get-SYSTEM -PowerShellArgs $systemArgs -PowerShellPath $preferPwsh.Source
                }
                else {
                    $systemProcess = Get-SYSTEM -PowerShellArgs $systemArgs
                }

                if ($systemProcess) {
                    Write-Information "Forensic collection started in SYSTEM context (PID: $($systemProcess.Id))" -InformationAction Continue
                    Write-Information "Collection path: $CollectionPath" -InformationAction Continue
                    Write-Information 'Monitor the collection process and check the collection path when complete.' -InformationAction Continue
                    Write-Information "Temporary script: $tempScript (will be cleaned up automatically)" -InformationAction Continue

                    # Clean up temp script after a delay using proper parameter binding
                    $cleanupScript = {
                        param([string]$ScriptPath, [int]$DelaySeconds)
                        Start-Sleep -Seconds $DelaySeconds
                        if (Test-Path $ScriptPath) {
                            Remove-Item $ScriptPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                    $cleanup = Start-Job -ScriptBlock $cleanupScript -ArgumentList $tempScript, $CLEANUP_DELAY_SECONDS
                    $cleanup | Out-Null

                    return $systemProcess
                }
                else {
                    Write-Warning 'Failed to elevate to SYSTEM. Continuing with current privileges.'
                    # Clean up the temp script since elevation failed
                    if (Test-Path $tempScript) {
                        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            catch {
                Write-Warning "Failed to elevate to SYSTEM: $($_.Exception.Message). Continuing with current privileges."
                # Clean up any temp script that might have been created
                if ($tempScript -and (Test-Path $tempScript)) {
                    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # Helper function to expand environment variables and Windows path patterns
    function Expand-ForensicPath {
        param([string]$Path)

        Write-Verbose "EXPAND DEBUG: Starting Expand-ForensicPath with: '$Path'"

        if ([string]::IsNullOrEmpty($Path)) {
            Write-Verbose 'EXPAND DEBUG: Path is null or empty, returning null'
            return $null
        }

        # Handle Windows environment variables
        $expandedPath = $Path -replace '%%environ_systemroot%%', $env:SystemRoot
        $expandedPath = $expandedPath -replace '%%environ_systemdrive%%', $env:SystemDrive
        $expandedPath = $expandedPath -replace '%%environ_programfiles%%', $env:ProgramFiles
        $expandedPath = $expandedPath -replace '%%environ_programfilesx86%%', ${env:ProgramFiles(x86)}
        $expandedPath = $expandedPath -replace '%%environ_allusersprofile%%', $env:ALLUSERSPROFILE
        $expandedPath = $expandedPath -replace '%%environ_temp%%', $env:TEMP
        $expandedPath = $expandedPath -replace '%%environ_windir%%', $env:WINDIR
        $expandedPath = $expandedPath -replace '%%environ_commonprogramfiles%%', $env:CommonProgramFiles
        $expandedPath = $expandedPath -replace '%%environ_commonprogramfilesx86%%', ${env:CommonProgramFiles(x86)}

        # Handle user profile paths - these need to be expanded for all users potentially
        $expandedPath = $expandedPath -replace '%%users\.homedir%%', $env:USERPROFILE
        $expandedPath = $expandedPath -replace '%%users\.appdata%%', $env:APPDATA
        $expandedPath = $expandedPath -replace '%%users\.localappdata%%', $env:LOCALAPPDATA
        $expandedPath = $expandedPath -replace '%%users\.temp%%', $env:TEMP
        $expandedPath = $expandedPath -replace '%%users\.desktop%%', ([Environment]::GetFolderPath('Desktop'))

        # Handle user-specific variables that need to be expanded for the current user or all users
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($expandedPath -match '%%users\.username%%') {
            $expandedPath = $expandedPath -replace '%%users\.username%%', $currentUser.Name.Split('\')[-1]
            Write-Verbose "EXPAND DEBUG: Replaced %%users.username%% with: $($currentUser.Name.Split('\')[-1])"
        }
        if ($expandedPath -match '%%users\.sid%%') {
            $expandedPath = $expandedPath -replace '%%users\.sid%%', $currentUser.User.Value
            Write-Verbose "EXPAND DEBUG: Replaced %%users.sid%% with: $($currentUser.User.Value)"
        }

        # Handle URL encoding and special characters
        $expandedPath = $expandedPath -replace '%4', ':'  # URL encoding for colon
        $expandedPath = $expandedPath -replace '%20', ' ' # URL encoding for space

        # Handle standard Windows environment variables format
        $expandedPath = [Environment]::ExpandEnvironmentVariables($expandedPath)

        Write-Verbose "EXPAND DEBUG: Final expanded path: '$expandedPath'"
        return $expandedPath
    }

    # Helper function to download and install forensic tools if needed
    function Install-ForensicTool {
        param([string]$ToolsDirectory)

        # Use a script-level variable to track if we've already attempted download
        if (-not $script:RawCopyDownloadAttempted) {
            $script:RawCopyDownloadAttempted = $true

            $installed = $false

            # Create tools directory if it doesn't exist
            if (-not (Test-Path $ToolsDirectory)) {
                try {
                    New-Item -Path $ToolsDirectory -ItemType Directory -Force | Out-Null
                    Write-Verbose "Created forensic tools directory: $ToolsDirectory"
                }
                catch {
                    Write-Verbose "Could not create tools directory: $($_.Exception.Message)"
                    return $false
                }
            }

            # Download RawCopy if not available
            $rawcopyPath = Join-Path $ToolsDirectory 'rawcopy.exe'
            if (-not (Test-Path $rawcopyPath)) {
                try {
                    Write-Verbose "Downloading RawCopy forensic tool (one-time attempt)..."
                    # Try to download RawCopy with timeout
                    Invoke-WebRequest -Uri 'https://github.com/jschicht/RawCopy/releases/latest/download/RawCopy.exe' -OutFile $rawcopyPath -TimeoutSec 10 -ErrorAction Stop

                    if (Test-Path $rawcopyPath) {
                        Write-Verbose "Successfully downloaded RawCopy to: $rawcopyPath"
                        $installed = $true
                    }
                }
                catch {
                    Write-Verbose "Could not download RawCopy: $($_.Exception.Message)"
                    Write-Verbose 'You can manually download RawCopy from: https://github.com/jschicht/RawCopy'
                }
            }

            return $installed
        }
        else {
            # Already attempted download, just check if file exists now
            $rawcopyPath = Join-Path $ToolsDirectory 'rawcopy.exe'
            return (Test-Path $rawcopyPath)
        }
    }

    # Helper function to get forensic copy tools
    function Get-ForensicCopyTool {
        # Use cached tools if already detected
        if ($script:CachedForensicTools) {
            return $script:CachedForensicTools
        }

        $tools = @()

        # First, try to install forensic tools if we have the capability (only once)
        $toolsDir = Join-Path $PSScriptRoot '..\Non PowerShell Tools\bin'
        Install-ForensicTool -ToolsDirectory $toolsDir | Out-Null

        # Check for rawcopy (most common forensic copy tool)
        $rawcopyPaths = @(
            'rawcopy.exe',
            'rawcopy64.exe',
            (Join-Path $env:ProgramFiles 'RawCopy\rawcopy.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'RawCopy\rawcopy.exe'),
            (Join-Path $PSScriptRoot '..\Non PowerShell Tools\rawcopy.exe'),
            (Join-Path $PSScriptRoot '..\Non PowerShell Tools\bin\rawcopy.exe')
        )

        foreach ($path in $rawcopyPaths) {
            if (Get-Command $path -ErrorAction SilentlyContinue) {
                $tools += @{
                    Name = 'rawcopy'
                    Path = (Get-Command $path).Source
                    Args = '/FileNamePath:"{0}" /OutputPath:"{1}"'
                }
                break
            }
        }

        # Check for hobocopy (another forensic copy tool)
        $hobocopyPaths = @(
            'hobocopy.exe',
            (Join-Path $env:ProgramFiles 'HoboCopy\hobocopy.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'HoboCopy\hobocopy.exe'),
            (Join-Path $PSScriptRoot '..\Non PowerShell Tools\hobocopy.exe')
        )

        foreach ($path in $hobocopyPaths) {
            if (Get-Command $path -ErrorAction SilentlyContinue) {
                $tools += @{
                    Name = 'hobocopy'
                    Path = (Get-Command $path).Source
                    Args = '"{0}" "{1}" /y'
                }
                break
            }
        }

        # Check for xcopy with specific flags for locked files
        if (Get-Command xcopy -ErrorAction SilentlyContinue) {
            $tools += @{
                Name = 'xcopy'
                Path = 'xcopy'
                Args = '"{0}" "{1}" /H /R /Y /C'
            }
        }

        # Check for robocopy (built into Windows, supports backup mode)
        if (Get-Command robocopy -ErrorAction SilentlyContinue) {
            $tools += @{
                Name = 'robocopy'
                Path = 'robocopy'
                Args = '"{0}" "{1}" /B /COPY:DAT /R:3 /W:1'
            }
        }

        # Cache the tools for subsequent calls
        $script:CachedForensicTools = $tools

        return $tools
    }

    # Helper function to copy locked files using forensic tools
    function Copy-LockedFile {
        param(
            [string]$SourceFile,
            [string]$DestinationFile,
            [array]$ForensicTools
        )

        Write-Verbose "FORENSIC COPY: Attempting to copy locked file: $SourceFile"

        # Ensure destination directory exists
        $destDir = Split-Path $DestinationFile -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -Path $destDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        # Check if we're running with administrative privileges for advanced forensic methods
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = ([Security.Principal.WindowsPrincipal]$currentUser).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if ($isAdmin) {
            Write-Verbose "FORENSIC COPY: Running with administrative privileges - enhanced forensic methods available"
        }
        else {
            Write-Verbose "FORENSIC COPY: Running without administrative privileges - limited to basic copy methods"
        }

        # Try RawCopy PowerShell implementation first for NTFS files (requires admin)
        if ($isAdmin) {
            try {
                Write-Verbose "FORENSIC COPY: Attempting RawCopy PowerShell implementation for NTFS file: $SourceFile"
                
                # Check if Invoke-RawyCopy is available
                $rawCopyScript = Join-Path $PSScriptRoot 'Invoke-RawyCopy.ps1'
                if (Test-Path $rawCopyScript) {
                    Write-Verbose "FORENSIC COPY: Found RawCopy script at: $rawCopyScript"
                    
                    # Try to execute RawCopy in a separate PowerShell process to avoid parameter conflicts
                    $rawCopyCommand = "& '$rawCopyScript' -Path '$SourceFile' -Destination '$DestinationFile' -Overwrite -BufferSizeKB 64"
                    
                    try {
                        # Execute RawCopy using PowerShell 7 in a separate process
                        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
                        $processInfo.FileName = 'pwsh'
                        $processInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$rawCopyCommand`""
                        $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
                        $processInfo.UseShellExecute = $false
                        $processInfo.RedirectStandardOutput = $true
                        $processInfo.RedirectStandardError = $true
                        $process = [System.Diagnostics.Process]::Start($processInfo)
                        
                        # Wait with timeout (60 seconds for RawCopy operations)
                        if ($process.WaitForExit(60000)) {
                            $output = $process.StandardOutput.ReadToEnd()
                            $error = $process.StandardError.ReadToEnd()
                            
                            if ($process.ExitCode -eq 0 -and (Test-Path $DestinationFile)) {
                                Write-Verbose "FORENSIC COPY: Successfully copied locked file using RawCopy PowerShell implementation: $SourceFile"
                                $process.Dispose()
                                return $true
                            }
                            else {
                                Write-Verbose "FORENSIC COPY: RawCopy process failed with exit code $($process.ExitCode)"
                                if ($error) {
                                    Write-Verbose "FORENSIC COPY: RawCopy error output: $error"
                                }
                            }
                        }
                        else {
                            # Process timed out, kill it
                            Write-Verbose "FORENSIC COPY: RawCopy timed out for $SourceFile, terminating process"
                            if (-not $process.HasExited) {
                                try {
                                    $process.Kill()
                                }
                                catch {
                                    Write-Verbose "Could not kill RawCopy process: $($_.Exception.Message)"
                                }
                            }
                        }
                        $process.Dispose()
                    }
                    catch {
                        Write-Verbose "FORENSIC COPY: Failed to execute RawCopy process: $($_.Exception.Message)"
                    }
                }
                else {
                    Write-Verbose "FORENSIC COPY: Invoke-RawyCopy.ps1 not found at: $rawCopyScript"
                }
            }
            catch {
                Write-Verbose "FORENSIC COPY: RawCopy PowerShell implementation failed for $SourceFile : $($_.Exception.Message)"
            }
        }

        foreach ($tool in $ForensicTools) {
            try {
                Write-Verbose "FORENSIC COPY: Trying $($tool.Name) for locked file: $SourceFile"

                switch ($tool.Name) {
                    'rawcopy' {
                        # RawCopy syntax: rawcopy /FileNamePath:source /OutputPath:destination
                        $arguments = $tool.Args -f $SourceFile, $DestinationFile
                        $process = Start-Process -FilePath $tool.Path -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                        if ($process.ExitCode -eq 0 -and (Test-Path $DestinationFile)) {
                            Write-Verbose "FORENSIC COPY: Successfully copied locked file using rawcopy: $SourceFile"
                            return $true
                        }
                    }
                    'hobocopy' {
                        # HoboCopy syntax: hobocopy source destination /y
                        $sourceDir = Split-Path $SourceFile -Parent
                        $fileName = Split-Path $SourceFile -Leaf
                        $arguments = $tool.Args -f $sourceDir, $destDir
                        $process = Start-Process -FilePath $tool.Path -ArgumentList "$arguments `"$fileName`"" -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                        if ($process.ExitCode -eq 0) {
                            $tempFile = Join-Path $destDir $fileName
                            if (Test-Path $tempFile) {
                                if ($tempFile -ne $DestinationFile) {
                                    Move-Item -Path $tempFile -Destination $DestinationFile -Force -ErrorAction SilentlyContinue
                                }
                                Write-Verbose "FORENSIC COPY: Successfully copied locked file using hobocopy: $SourceFile"
                                return $true
                            }
                        }
                    }
                    'xcopy' {
                        # XCopy with flags for hidden, read-only, and continuing on errors
                        $arguments = $tool.Args -f $SourceFile, $DestinationFile
                        # Add timeout to prevent hanging
                        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
                        $processInfo.FileName = $tool.Path
                        $processInfo.Arguments = $arguments
                        $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
                        $processInfo.UseShellExecute = $false
                        $process = [System.Diagnostics.Process]::Start($processInfo)

                        # Wait with timeout (30 seconds)
                        if ($process.WaitForExit(30000)) {
                            if ($process.ExitCode -eq 0 -and (Test-Path $DestinationFile)) {
                                Write-Verbose "FORENSIC COPY: Successfully copied locked file using xcopy: $SourceFile"
                                $process.Dispose()
                                return $true
                            }
                            elseif ($process.ExitCode -eq 4) {
                                # Exit code 4 means some files could not be copied, but others were successful
                                if (Test-Path $DestinationFile) {
                                    Write-Verbose "FORENSIC COPY: Partially successful copy using xcopy (some access denied): $SourceFile"
                                    $process.Dispose()
                                    return $true
                                }
                            }
                        } else {
                            # Process timed out, kill it
                            Write-Verbose "FORENSIC COPY: xcopy timed out for $SourceFile, terminating process"
                            if (-not $process.HasExited) {
                                try {
                                    $process.Kill()
                                }
                                catch {
                                    Write-Verbose "Could not kill xcopy process: $($_.Exception.Message)"
                                }
                            }
                        }
                        $process.Dispose()
                    }
                }
            }
            catch {
                Write-Verbose "FORENSIC COPY: $($tool.Name) failed for $SourceFile : $($_.Exception.Message)"
                continue
            }
        }

        # Try Windows native robocopy as another option
        try {
            Write-Verbose "FORENSIC COPY: Attempting robocopy for locked file: $SourceFile"
            $sourceDir = Split-Path $SourceFile -Parent
            $fileName = Split-Path $SourceFile -Leaf
            $destDir = Split-Path $DestinationFile -Parent

            # Robocopy with backup mode (/B) for locked files with timeout
            $robocopyArgs = "`"$sourceDir`" `"$destDir`" `"$fileName`" /B /COPY:DAT /R:1 /W:1 /NP /NDL"

            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = 'robocopy'
            $processInfo.Arguments = $robocopyArgs
            $processInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $processInfo.UseShellExecute = $false
            $process = [System.Diagnostics.Process]::Start($processInfo)

            # Wait with timeout (20 seconds)
            if ($process.WaitForExit(20000)) {
                # Robocopy exit codes: 0-7 are success, 8+ are errors
                if ($process.ExitCode -le 7) {
                    $destFile = Join-Path $destDir $fileName
                    if (Test-Path $destFile) {
                        if ($destFile -ne $DestinationFile) {
                            Move-Item -Path $destFile -Destination $DestinationFile -Force -ErrorAction SilentlyContinue
                        }
                        Write-Verbose "FORENSIC COPY: Successfully copied locked file using robocopy backup mode: $SourceFile"
                        $process.Dispose()
                        return $true
                    }
                }
            } else {
                # Process timed out, kill it
                Write-Verbose "FORENSIC COPY: robocopy timed out for $SourceFile, terminating process"
                if (-not $process.HasExited) {
                    try {
                        $process.Kill()
                    }
                    catch {
                        Write-Verbose "Could not kill robocopy process: $($_.Exception.Message)"
                    }
                }
            }
            $process.Dispose()
        }
        catch {
            Write-Verbose "FORENSIC COPY: Robocopy backup mode failed for $SourceFile : $($_.Exception.Message)"
        }

        # Try PowerShell with special file access methods
        try {
            Write-Verbose "FORENSIC COPY: Attempting PowerShell raw file access for: $SourceFile"

            # Create a shadow copy to access locked files
            $shadowCopyResult = Get-CimInstance -ClassName Win32_ShadowCopy | Sort-Object InstallDate -Descending | Select-Object -First 1
            if ($shadowCopyResult) {
                Write-Verbose 'FORENSIC COPY: Found shadow copy, attempting to access file through shadow copy'
                $shadowPath = $shadowCopyResult.DeviceObject + '\' + $SourceFile.Substring(3)
                if (Test-Path $shadowPath) {
                    Copy-Item -Path $shadowPath -Destination $DestinationFile -Force -ErrorAction Stop
                    Write-Verbose "FORENSIC COPY: Successfully copied locked file using shadow copy: $SourceFile"
                    return $true
                }
            }
        }
        catch {
            Write-Verbose "FORENSIC COPY: Shadow copy method failed for $SourceFile : $($_.Exception.Message)"
        }

        # If all forensic tools fail, try PowerShell native methods with special flags
        try {
            # Try using .NET FileStream with more permissive flags
            Write-Verbose "FORENSIC COPY: Attempting .NET FileStream copy for: $SourceFile"
            $sourceStream = [System.IO.File]::OpenRead($SourceFile)
            $destStream = [System.IO.File]::Create($DestinationFile)
            $sourceStream.CopyTo($destStream)
            $sourceStream.Close()
            $destStream.Close()

            if (Test-Path $DestinationFile) {
                Write-Verbose "FORENSIC COPY: Successfully copied locked file using .NET FileStream: $SourceFile"
                return $true
            }
        }
        catch {
            Write-Verbose "FORENSIC COPY: .NET FileStream also failed for $SourceFile : $($_.Exception.Message)"
        }

        # Final attempt: Create a note about the locked file for manual intervention
        try {
            $lockInfoFile = $DestinationFile + '.locked_file_info.txt'
            $lockInfo = @"
LOCKED FILE DETECTED
====================
Original Path: $SourceFile
Attempted Collection: $(Get-Date)
Status: File is locked and could not be copied using forensic tools

This file requires manual collection using specialized forensic tools or
creating a disk image for offline analysis.

Recommended Actions:
1. Create a forensic disk image using tools like FTK Imager or dd
2. Use specialized forensic acquisition tools with raw disk access
3. Boot from a forensic live CD/USB to access the file
4. Use Volume Shadow Copy Service (VSS) if available

Tools to try manually:
- FTK Imager
- X-Ways Forensics
- KAPE with raw disk access
- Windows Forensic Toolkit (WinFE)
"@
            $lockInfo | Out-File -FilePath $lockInfoFile -Encoding UTF8
            Write-Verbose "FORENSIC COPY: Created lock info file for manual intervention: $lockInfoFile"
        }
        catch {
            Write-Verbose "FORENSIC COPY: Could not create lock info file: $($_.Exception.Message)"
        }

        Write-Verbose "FORENSIC COPY: All copy methods failed for locked file: $SourceFile"
        return $false
    }

    # Helper function to collect artifacts from specified paths
    function Copy-ForensicArtifact {
        param(
            [string]$SourcePath,
            [string]$DestinationRoot,
            [string]$ArtifactName
        )

        $success = $false
        $forensicTools = Get-ForensicCopyTool
        Write-Verbose "COPY DEBUG: Starting Copy-ForensicArtifact for '$ArtifactName' from '$SourcePath'"
        Write-Verbose "COPY DEBUG: Available forensic tools: $($forensicTools.Name -join ', ')"

        try {
            $expandedSource = Expand-ForensicPath -Path $SourcePath
            Write-Verbose "COPY DEBUG: Expand-ForensicPath returned: '$expandedSource'"
            if ([string]::IsNullOrEmpty($expandedSource)) {
                Write-Verbose 'COPY DEBUG: Expanded source is null or empty, returning false'
                return $false
            }

            Write-Verbose "COPY DEBUG: Processing path: $expandedSource for artifact: $ArtifactName"

            # Create artifact-specific subdirectory
            $artifactDir = Join-Path $DestinationRoot $ArtifactName.Replace(' ', '_')
            Write-Verbose "COPY DEBUG: Artifact directory will be: '$artifactDir'"
            if (-not (Test-Path $artifactDir)) {
                New-Item -Path $artifactDir -ItemType Directory -Force | Out-Null
                Write-Verbose "COPY DEBUG: Created artifact directory: '$artifactDir'"
            }
            else {
                Write-Verbose "COPY DEBUG: Artifact directory already exists: '$artifactDir'"
            }

            # Handle registry paths - support both short and long forms
            if ($expandedSource -match '^HK(EY_)?(LOCAL_MACHINE|CURRENT_USER|CLASSES_ROOT|USERS|CURRENT_CONFIG|LM|CU|CR|U|CC)\\') {
                Write-Verbose "Registry path detected: $expandedSource"
                $regFileName = "registry_$(($expandedSource -replace '[\\/:*?"<>|]', '_')).reg"
                $regFile = Join-Path $artifactDir $regFileName
                try {
                    # Export registry key - remove wildcard patterns first
                    $regPath = $expandedSource -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\'
                    $regPath = $regPath -replace '^HKCU\\', 'HKEY_CURRENT_USER\'
                    $regPath = $regPath -replace '^HKCR\\', 'HKEY_CLASSES_ROOT\'
                    $regPath = $regPath -replace '^HKU\\', 'HKEY_USERS\'
                    $regPath = $regPath -replace '^HKCC\\', 'HKEY_CURRENT_CONFIG\'

                    # Remove wildcard patterns that reg.exe doesn't understand
                    $regPath = $regPath -replace '\\?\*$', ''  # Remove trailing \* or *

                    Write-Verbose "Registry export: Attempting to export '$regPath' to '$regFile'"

                    $regExportResult = Start-Process -FilePath 'reg' -ArgumentList 'export', "`"$regPath`"", "`"$regFile`"", '/y' -Wait -PassThru -WindowStyle Hidden
                    if ($regExportResult.ExitCode -eq 0 -and (Test-Path $regFile)) {
                        Write-Verbose "Successfully exported registry: $regPath"
                        $success = $true
                    }
                    else {
                        Write-Verbose "Registry export failed or key doesn't exist: $regPath"
                        # Try to check if the key exists using Get-ItemProperty
                        try {
                            $keyExists = Test-Path "Registry::$regPath" -ErrorAction SilentlyContinue
                            if (-not $keyExists) {
                                Write-Verbose "Registry key does not exist: $regPath"
                            }
                        }
                        catch {
                            Write-Verbose "Cannot access registry key: $regPath"
                        }
                    }
                }
                catch {
                    Write-Warning "Failed to export registry path: $expandedSource - $($_.Exception.Message)"
                }
                return $success
            }

            # Handle file system paths with better error handling
            try {
                # Handle recursive patterns (**) by converting them to -Recurse
                if ($expandedSource.Contains('**')) {
                    Write-Verbose "COPY DEBUG: Handling recursive pattern: $expandedSource"
                    $basePath = $expandedSource -replace '\\?\*\*.*$', ''
                    $pattern = $expandedSource -replace '^.*\\?\*\*\\?', ''

                    Write-Verbose "COPY DEBUG: Base path: '$basePath', Pattern: '$pattern'"

                    if (Test-Path $basePath -PathType Container -ErrorAction SilentlyContinue) {
                        $items = @()
                        if ([string]::IsNullOrEmpty($pattern) -or $pattern -eq '**') {
                            # Get all files recursively
                            $items = Get-ChildItem -Path $basePath -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }
                        }
                        else {
                            # Get files matching pattern recursively
                            $items = Get-ChildItem -Path $basePath -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
                                (-not $_.PSIsContainer) -and ($_.Name -like $pattern)
                            }
                        }

                        Write-Verbose "COPY DEBUG: Found $($items.Count) items matching recursive pattern"

                        foreach ($item in $items) {
                            try {
                                # Preserve directory structure
                                $relativePath = $item.FullName.Substring($basePath.Length).TrimStart('\')
                                $destItem = Join-Path $artifactDir $relativePath
                                $destDir = Split-Path $destItem -Parent

                                if (-not (Test-Path $destDir)) {
                                    New-Item -Path $destDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                                }

                                Copy-Item -Path $item.FullName -Destination $destItem -Force -ErrorAction SilentlyContinue
                                Write-Verbose "COPY DEBUG: Copied recursive item: $($item.FullName) -> $destItem"
                                $success = $true
                            }
                            catch {
                                Write-Verbose "COPY DEBUG: Standard copy failed for recursive item '$($item.FullName)': $($_.Exception.Message)"
                                # For locked files, try forensic copy tools
                                if ($_.Exception.Message -like '*being used by another process*' -or
                                    $_.Exception.Message -like '*Access*denied*' -or
                                    $_.Exception.Message -like '*cannot access the file*') {
                                    Write-Verbose "COPY DEBUG: Recursive item appears to be locked, attempting forensic copy: $($item.FullName)"
                                    if ($forensicTools.Count -gt 0) {
                                        $relativePath = $item.FullName.Substring($basePath.Length).TrimStart('\')
                                        $destItem = Join-Path $artifactDir $relativePath
                                        $destDir = Split-Path $destItem -Parent

                                        if (-not (Test-Path $destDir)) {
                                            New-Item -Path $destDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                                        }

                                        $forensicSuccess = Copy-LockedFile -SourceFile $item.FullName -DestinationFile $destItem -ForensicTools $forensicTools
                                        if ($forensicSuccess) {
                                            $success = $true
                                            Write-Verbose "FORENSIC COPY: Successfully copied locked recursive item: $($item.FullName)"
                                        }
                                        else {
                                            Write-Verbose "FORENSIC COPY: All forensic copy methods failed for recursive item: $($item.FullName)"
                                        }
                                    }
                                    else {
                                        Write-Verbose "COPY DEBUG: No forensic tools available for locked recursive item: $($item.FullName)"
                                    }
                                }
                                else {
                                    Write-Verbose "COPY DEBUG: Failed to copy recursive item: $($item.FullName) - $($_.Exception.Message)"
                                }
                            }
                        }

                        if ($items.Count -eq 0) {
                            Write-Verbose "COPY DEBUG: No files found in recursive path: $basePath"
                        }
                    }
                    else {
                        Write-Verbose "COPY DEBUG: Base path does not exist for recursive pattern: $basePath"
                    }
                }
                elseif (Test-Path $expandedSource -PathType Leaf -ErrorAction SilentlyContinue) {
                    # Single file
                    $fileName = Split-Path $expandedSource -Leaf
                    $destFile = Join-Path $artifactDir $fileName
                    try {
                        Copy-Item -Path $expandedSource -Destination $destFile -Force -ErrorAction Stop
                        Write-Verbose "Copied file: $expandedSource -> $destFile"
                        $success = $true
                    }
                    catch {
                        Write-Verbose "COPY DEBUG: Standard copy failed for '$expandedSource': $($_.Exception.Message)"
                        # For locked files, try forensic copy tools
                        if ($_.Exception.Message -like '*being used by another process*' -or
                            $_.Exception.Message -like '*Access*denied*' -or
                            $_.Exception.Message -like '*cannot access the file*') {
                            Write-Verbose "COPY DEBUG: File appears to be locked, attempting forensic copy: $expandedSource"
                            if ($forensicTools.Count -gt 0) {
                                $forensicSuccess = Copy-LockedFile -SourceFile $expandedSource -DestinationFile $destFile -ForensicTools $forensicTools
                                if ($forensicSuccess) {
                                    $success = $true
                                    Write-Verbose "FORENSIC COPY: Successfully copied locked file: $expandedSource"
                                }
                                else {
                                    Write-Verbose "FORENSIC COPY: All forensic copy methods failed for: $expandedSource"
                                }
                            }
                            else {
                                Write-Verbose "COPY DEBUG: No forensic tools available for locked file: $expandedSource"
                            }
                        }
                    }
                }
                elseif (Test-Path $expandedSource -PathType Container -ErrorAction SilentlyContinue) {
                    # Directory
                    $dirName = Split-Path $expandedSource -Leaf
                    $destDir = Join-Path $artifactDir $dirName
                    try {
                        Copy-Item -Path $expandedSource -Destination $destDir -Recurse -Force -ErrorAction Stop
                        Write-Verbose "Copied directory: $expandedSource -> $destDir"
                        $success = $true
                    }
                    catch {
                        Write-Verbose "COPY DEBUG: Failed to copy directory '$expandedSource': $($_.Exception.Message)"
                        # For access denied errors, try to note that the directory exists but is protected
                        if ($_.Exception.Message -like '*Access*denied*' -or $_.Exception.Message -like '*UnauthorizedAccess*') {
                            Write-Verbose "COPY DEBUG: Access denied for directory: $expandedSource - directory exists but requires higher privileges"
                        }
                    }
                }
                else {
                    # Path with wildcards or pattern matching
                    $parentPath = Split-Path $expandedSource -Parent
                    $fileName = Split-Path $expandedSource -Leaf

                    Write-Verbose "COPY DEBUG: Pattern matching - Parent: '$parentPath', File: '$fileName'"

                    if (Test-Path $parentPath -ErrorAction SilentlyContinue) {
                        $items = @()

                        try {
                            # Try with filter first
                            $items = Get-ChildItem -Path $parentPath -Filter $fileName -Force -ErrorAction SilentlyContinue
                            if (-not $items) {
                                # Try direct path if filter failed
                                $items = Get-ChildItem -Path $expandedSource -Force -ErrorAction SilentlyContinue
                            }
                        }
                        catch {
                            Write-Verbose "COPY DEBUG: Error getting items from '$parentPath' with filter '$fileName': $($_.Exception.Message)"
                            # Try alternative approach without filter
                            try {
                                $allItems = Get-ChildItem -Path $parentPath -Force -ErrorAction SilentlyContinue
                                $items = $allItems | Where-Object { $_.Name -like $fileName }
                            }
                            catch {
                                Write-Verbose "COPY DEBUG: Alternative approach also failed: $($_.Exception.Message)"
                            }
                        }

                        Write-Verbose "COPY DEBUG: Found $($items.Count) items matching pattern"

                        foreach ($item in $items) {
                            try {
                                $destItem = Join-Path $artifactDir $item.Name
                                if ($item.PSIsContainer) {
                                    Copy-Item -Path $item.FullName -Destination $destItem -Recurse -Force -ErrorAction SilentlyContinue
                                    Write-Verbose "COPY DEBUG: Copied directory: $($item.FullName) -> $destItem"
                                }
                                else {
                                    Copy-Item -Path $item.FullName -Destination $destItem -Force -ErrorAction SilentlyContinue
                                    Write-Verbose "COPY DEBUG: Copied file: $($item.FullName) -> $destItem"
                                }
                                $success = $true
                            }
                            catch {
                                Write-Verbose "COPY DEBUG: Standard copy failed for '$($item.FullName)': $($_.Exception.Message)"
                                # For locked files, try forensic copy tools
                                if ((-not $item.PSIsContainer) -and
                                    ($_.Exception.Message -like '*being used by another process*' -or
                                    $_.Exception.Message -like '*Access*denied*' -or
                                    $_.Exception.Message -like '*cannot access the file*')) {
                                    Write-Verbose "COPY DEBUG: File appears to be locked, attempting forensic copy: $($item.FullName)"
                                    if ($forensicTools.Count -gt 0) {
                                        $destItem = Join-Path $artifactDir $item.Name
                                        $forensicSuccess = Copy-LockedFile -SourceFile $item.FullName -DestinationFile $destItem -ForensicTools $forensicTools
                                        if ($forensicSuccess) {
                                            $success = $true
                                            Write-Verbose "FORENSIC COPY: Successfully copied locked file: $($item.FullName)"
                                        }
                                        else {
                                            Write-Verbose "FORENSIC COPY: All forensic copy methods failed for: $($item.FullName)"
                                        }
                                    }
                                    else {
                                        Write-Verbose "COPY DEBUG: No forensic tools available for locked file: $($item.FullName)"
                                    }
                                }
                                else {
                                    # For access denied errors on directories or other errors, just note them
                                    if ($_.Exception.Message -like '*Access*denied*' -or $_.Exception.Message -like '*UnauthorizedAccess*') {
                                        Write-Verbose "COPY DEBUG: Access denied for: $($item.FullName) - file exists but requires higher privileges"
                                    }
                                }
                            }
                        }

                        if ($items.Count -eq 0) {
                            Write-Verbose "COPY DEBUG: No files found matching pattern: $expandedSource"
                        }
                    }
                    else {
                        Write-Verbose "COPY DEBUG: Parent path does not exist: $parentPath"
                    }
                }
            }
            catch {
                Write-Verbose "Error accessing path '$expandedSource': $($_.Exception.Message)"
            }

            # Clean up empty directories
            if (-not $success) {
                try {
                    $dirContents = Get-ChildItem -Path $artifactDir -ErrorAction SilentlyContinue
                    if (-not $dirContents) {
                        Remove-Item -Path $artifactDir -Force -ErrorAction SilentlyContinue
                        Write-Verbose "Removed empty directory: $artifactDir"
                    }
                }
                catch {
                    Write-Verbose "Could not clean up empty directory: $($_.Exception.Message)"
                }
            }
        }
        catch {
            Write-Warning "Error processing artifact '$ArtifactName' at path '$SourcePath': $($_.Exception.Message)"
        }

        return $success
    }

    $WindowsArtifacts = Invoke-RestMethod -Uri $ARTIFACTS_SOURCE_URL
    $obj = ConvertFrom-Yaml -AllDocuments $WindowsArtifacts -Verbose

    # Initialize collection if requested
    if ($CollectArtifacts -and [string]::IsNullOrEmpty($CollectionPath)) {
        $CollectionPath = Join-Path $env:TEMP "ForensicArtifacts_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    }

    if ($CollectArtifacts) {
        Write-Verbose "Forensic artifact collection enabled. Destination: $CollectionPath"
        if (-not (Test-Path $CollectionPath)) {
            New-Item -Path $CollectionPath -ItemType Directory -Force | Out-Null
        }
    }

    foreach ($Artifact in $obj) {
        # Apply artifact filter if specified
        if ($ArtifactFilter -and $ArtifactFilter.Count -gt 0) {
            $match = $false
            foreach ($filter in $ArtifactFilter) {
                if ($Artifact.name -like "*$filter*") {
                    $match = $true
                    break
                }
            }
            if (-not $match) {
                continue
            }
        }

        $artifactType = $Artifact.sources.type
        $pathKeyValuePairs = $Artifact.sources.attributes.key_value_pairs
        $registryKeys = $Artifact.sources.attributes.keys
        $paths = $Artifact.sources.attributes.paths
        $pathOnly = $null  # Initialize $pathOnly as $null
        $expandedPaths = @()  # Store expanded paths for collection

        if ($artifactType -eq 'REGISTRY_VALUE' -and $null -ne $pathKeyValuePairs -and $pathKeyValuePairs.Count -gt 0) {
            # Iterate through key_value_pairs to find the registry path
            foreach ($pair in $pathKeyValuePairs) {
                if ($pair['registry_path'] -or $pair['path']) {
                    $regPath = $pair['registry_path'] ? $pair['registry_path'] : $pair['path']
                    $pathOnly = $regPath
                    if ($ExpandPaths -or $CollectArtifacts) {
                        $expandedPaths += $regPath
                    }
                    break  # Exit the loop once the registry path is found
                }
            }
        }
        elseif ($artifactType -eq 'REGISTRY_KEY' -and $null -ne $registryKeys -and $registryKeys.Count -gt 0) {
            # Handle REGISTRY_KEY type artifacts - extract paths from 'keys' attribute
            Write-Verbose "REGISTRY_KEY DEBUG: Processing REGISTRY_KEY artifact '$($Artifact.name)' with $($registryKeys.Count) keys"
            foreach ($key in $registryKeys) {
                Write-Verbose "REGISTRY_KEY DEBUG: Processing key: $key"
                if ($key) {
                    $pathOnly = if ($pathOnly) {
                        "$pathOnly`n$key"
                    }
                    else {
                        $key
                    }
                    if ($ExpandPaths -or $CollectArtifacts) {
                        $expandedPaths += $key
                        Write-Verbose "REGISTRY_KEY DEBUG: Added to expandedPaths: $key"
                    }
                }
            }
            Write-Verbose "REGISTRY_KEY DEBUG: Final pathOnly: '$pathOnly'"
            Write-Verbose "REGISTRY_KEY DEBUG: Final expandedPaths count: $($expandedPaths.Count)"
        }
        elseif ($null -ne $paths -and $paths.Count -gt 0) {
            # Handle file system paths
            if ($ExpandPaths -or $CollectArtifacts) {
                foreach ($path in $paths) {
                    $expandedPath = Expand-ForensicPath -Path $path
                    if ($expandedPath) {
                        $expandedPaths += $expandedPath
                    }
                }
                if ($ExpandPaths) {
                    $pathOnly = ($expandedPaths -join "`n")
                }
                else {
                    $pathOnly = ($paths -join "`n")
                }
            }
            else {
                $pathOnly = ($paths -join "`n")
            }
        }

        # Collect artifacts if requested
        if ($CollectArtifacts -and $expandedPaths.Count -gt 0) {
            Write-Progress -Activity 'Collecting Forensic Artifacts' -Status "Processing: $($Artifact.name)" -PercentComplete -1
            Write-Verbose "COLLECTION DEBUG: Starting collection for '$($Artifact.name)' with $($expandedPaths.Count) paths"
            $collectionSuccess = $false
            foreach ($artifactPath in $expandedPaths) {
                Write-Verbose "COLLECTION DEBUG: Attempting to collect path: $artifactPath"
                $result = Copy-ForensicArtifact -SourcePath $artifactPath -DestinationRoot $CollectionPath -ArtifactName $Artifact.name
                Write-Verbose "COLLECTION DEBUG: Copy-ForensicArtifact returned: $result for path: $artifactPath"
                if ($result) {
                    $collectionSuccess = $true
                }
            }

            # If no artifacts were collected for this item, note it in verbose output
            if (-not $collectionSuccess) {
                Write-Verbose "COLLECTION DEBUG: No artifacts collected for: $($Artifact.name) - paths may not exist or be accessible"
            }
            else {
                Write-Verbose "COLLECTION DEBUG: Successfully collected artifacts for: $($Artifact.name)"
            }
        }

        # Create a readable attributes object by directly converting the attributes
        $displayAttributes = $null
        if ($Artifact.sources.attributes) {
            # Use JSON conversion to properly serialize and deserialize the complex objects
            try {
                $attributesJson = $Artifact.sources.attributes | ConvertTo-Json -Depth 10 -Compress
                $tempAttributes = $attributesJson | ConvertFrom-Json

                # Force array expansion by creating a new hashtable with properly formatted values
                $attributeProperties = [ordered]@{}
                foreach ($property in $tempAttributes.PSObject.Properties) {
                    $value = $property.Value
                    if ($value -is [array] -and $value.Count -gt 0) {
                        # Convert arrays to comma-separated strings for better display
                        $attributeProperties[$property.Name] = ($value -join ', ')
                    }
                    elseif ($value -is [array] -and $value.Count -eq 0) {
                        $attributeProperties[$property.Name] = @()
                    }
                    else {
                        $attributeProperties[$property.Name] = $value
                    }
                }
                $displayAttributes = [PSCustomObject]$attributeProperties
            }
            catch {
                # Fallback: manual conversion if JSON fails
                $attributeProperties = [ordered]@{}
                foreach ($property in $Artifact.sources.attributes.PSObject.Properties) {
                    $propertyName = $property.Name
                    $propertyValue = $property.Value

                    if ($propertyValue -is [System.Collections.IEnumerable] -and $propertyValue -isnot [string]) {
                        # Convert to array and join for display
                        $expandedArray = @($propertyValue | ForEach-Object { $_ })
                        if ($expandedArray.Count -gt 0) {
                            $attributeProperties[$propertyName] = ($expandedArray -join ', ')
                        }
                        else {
                            $attributeProperties[$propertyName] = @()
                        }
                    }
                    else {
                        $attributeProperties[$propertyName] = $propertyValue
                    }
                }
                $displayAttributes = [PSCustomObject]$attributeProperties
            }
        }

        $Artifacts = [pscustomobject][ordered]@{
            Name          = $Artifact.name
            Description   = $Artifact.doc
            References    = $Artifact.urls
            Attributes    = $displayAttributes
            Path          = $pathOnly
            ExpandedPaths = if ($ExpandPaths -or $CollectArtifacts) {
                $expandedPaths
            }
            else {
                $null
            }
            ArtifactType  = $artifactType
        }

        # Return the object instead of custom formatting
        $Artifacts
    }

    # Display completion message if artifacts were collected
    if ($CollectArtifacts) {
        Write-Progress -Activity 'Collecting Forensic Artifacts' -Completed
        Write-Information 'Forensic artifact collection completed!' -InformationAction Continue
        Write-Information "Artifacts saved to: $CollectionPath" -InformationAction Continue
        Write-Information "Total artifacts processed: $(($obj | Measure-Object).Count)" -InformationAction Continue

        # Get collection statistics
        $collectedDirs = Get-ChildItem -Path $CollectionPath -Directory -ErrorAction SilentlyContinue
        $successfulCollections = @()
        $emptyCollections = @()

        foreach ($dir in $collectedDirs) {
            $contents = Get-ChildItem -Path $dir.FullName -Recurse -ErrorAction SilentlyContinue
            if ($contents) {
                $fileCount = ($contents | Where-Object { -not $_.PSIsContainer } | Measure-Object).Count
                $successfulCollections += "$($dir.Name) ($fileCount files)"
            }
            else {
                $emptyCollections += $dir.Name
            }
        }

        # Create a summary report
        $summaryFile = Join-Path $CollectionPath 'collection_summary.txt'
        $privilegeInfo = if ($isSystem) {
            'SYSTEM'
        }
        elseif ($isAdmin) {
            'Administrator'
        }
        else {
            'Standard User'
        }
        $summary = @"
Forensic Artifact Collection Summary
====================================
Collection Time: $(Get-Date)
Collection Path: $CollectionPath
Privilege Level: $privilegeInfo
Total Artifacts Processed: $(($obj | Measure-Object).Count)
Filters Applied: $($ArtifactFilter -join ', ')
Successful Collections: $($successfulCollections.Count)
Empty Collections: $($emptyCollections.Count)

Artifacts Successfully Collected:
$(if ($successfulCollections.Count -gt 0) { $successfulCollections | ForEach-Object { "✓ $_" } | Out-String } else { 'None' })

Artifacts with No Files Found:
$(if ($emptyCollections.Count -gt 0) { $emptyCollections | ForEach-Object { "✗ $_" } | Out-String } else { 'None' })

Collection Notes:
- Empty collections may indicate artifacts don't exist on this system
- Some artifacts may require elevated permissions to access
- Registry artifacts are exported as .reg files
- File system artifacts are copied preserving directory structure
- Running as $privilegeInfo provides access to system-level artifacts
"@
        $summary | Out-File -FilePath $summaryFile -Encoding UTF8
        Write-Information "Summary report created: $summaryFile" -InformationAction Continue
        Write-Information "Successfully collected: $($successfulCollections.Count) artifacts" -InformationAction Continue
        Write-Information "Empty collections: $($emptyCollections.Count) artifacts" -InformationAction Continue

        # Clean up empty directories if requested
        foreach ($emptyDir in $emptyCollections) {
            $emptyDirPath = Join-Path $CollectionPath $emptyDir
            try {
                Remove-Item -Path $emptyDirPath -Force -ErrorAction SilentlyContinue
                Write-Verbose "Removed empty collection directory: $emptyDir"
            }
            catch {
                Write-Verbose "Could not remove empty directory: $emptyDir"
            }
        }
    }
}