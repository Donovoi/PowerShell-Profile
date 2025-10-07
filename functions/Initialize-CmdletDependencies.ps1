function Initialize-CmdletDependencies {
    <#
    .SYNOPSIS
        Loads required cmdlets from the Cmdlets folder.
    
    .DESCRIPTION
        This function loads specified cmdlets if they are not already available in the session.
        It searches for cmdlet files in the same directory as the calling script.
    
    .PARAMETER RequiredCmdlets
        Array of cmdlet names to load (without .ps1 extension).
    
    .PARAMETER PreferLocal
        If specified, prefers loading from local files over already-loaded functions.
    
    .PARAMETER Force
        If specified, forces reload of cmdlets even if already loaded.
    
    .EXAMPLE
        Initialize-CmdletDependencies -RequiredCmdlets @('Write-Logg', 'Get-FileDownload')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredCmdlets,
        
        [switch]$PreferLocal,
        
        [switch]$Force
    )
    
    try {
        # Determine the Cmdlets folder path using call stack
        $callStack = Get-PSCallStack -ErrorAction SilentlyContinue | Where-Object ScriptName -ErrorAction SilentlyContinue | Select-Object -First 1 -ErrorAction SilentlyContinue
        
        if ($callStack -and $callStack.ScriptName) {
            # Get the directory of the calling script
            $callerDir = Split-Path -Path $callStack.ScriptName -Parent
            # If we're in the Cmdlets folder, use it; otherwise try to find it
            if ($callerDir -like '*\Cmdlets') {
                $cmdletsFolder = $callerDir
            }
            else {
                # Try to find Cmdlets folder relative to caller
                $cmdletsFolder = Join-Path (Split-Path $callerDir -Parent) 'Cmdlets' -ErrorAction SilentlyContinue
                if (-not (Test-Path $cmdletsFolder -ErrorAction SilentlyContinue)) {
                    $cmdletsFolder = Join-Path $callerDir 'Cmdlets' -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            # Fallback: assume we're being called from within Cmdlets folder
            $cmdletsFolder = $PSScriptRoot
            if (-not $cmdletsFolder) {
                $cmdletsFolder = $PWD.Path
            }
        }
        
        Write-Verbose "Initialize-CmdletDependencies: Using cmdlets folder: $cmdletsFolder"
        
        foreach ($cmdletName in $RequiredCmdlets) {
            # Skip if already loaded and not forcing reload
            if (-not $Force -and (Get-Command -Name $cmdletName -ErrorAction SilentlyContinue)) {
                Write-Verbose "Cmdlet '$cmdletName' already loaded, skipping"
                continue
            }
            
            # Build the expected file path
            $cmdletFile = Join-Path $cmdletsFolder "$cmdletName.ps1"
            
            if (Test-Path $cmdletFile -ErrorAction SilentlyContinue) {
                Write-Verbose "Loading cmdlet from: $cmdletFile"
                try {
                    . $cmdletFile
                    Write-Verbose "Successfully loaded cmdlet: $cmdletName"
                }
                catch {
                    Write-Warning "Failed to load cmdlet '$cmdletName' from '$cmdletFile': $($_.Exception.Message)"
                }
            }
            else {
                Write-Warning "Cmdlet file not found: $cmdletFile"
            }
        }
    }
    catch {
        Write-Warning "Initialize-CmdletDependencies failed: $($_.Exception.Message)"
    }
}
function Initialize-CmdletDependencies {
    <#
    .SYNOPSIS
        Loads required cmdlets for PowerShell scripts with automatic download and retry logic.
    
    .DESCRIPTION
        This function handles the loading of required cmdlets with robust error handling and retry mechanisms.
        It eliminates code duplication across cmdlet files by providing a single, reusable implementation
        of the cmdlet loading pattern.
        
        The function:
        - Checks if cmdlets are already loaded
        - Downloads Install-Cmdlet infrastructure if needed (with retry)
        - Downloads and imports missing cmdlets (with retry)
        - Handles both ScriptBlock and File-based cmdlet returns
        - Creates dynamic modules for proper cmdlet isolation
    
    .PARAMETER RequiredCmdlets
        An array of cmdlet names that need to be loaded for the calling script.
    
    .PARAMETER MaxRetries
        Maximum number of retry attempts for downloading cmdlets. Default is 20.
    
    .PARAMETER RetryDelaySeconds
        Number of seconds to wait between retry attempts. Default is 5.
    
    .PARAMETER RepositoryUrl
        The base GitHub repository URL for downloading cmdlets.
        Default is 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions'
    
    .PARAMETER PreferLocal
        Switch to prefer locally cached cmdlets over downloading.
    
    .PARAMETER Force
        Force re-download of cmdlets even if they exist.
    
    .EXAMPLE
        Initialize-CmdletDependencies -RequiredCmdlets @('Install-Dependencies', 'Write-Logg')
        
        Loads the Install-Dependencies and Write-Logg cmdlets, downloading them if necessary.
    
    .EXAMPLE
        Initialize-CmdletDependencies -RequiredCmdlets @('Get-FileDownload') -MaxRetries 10 -RetryDelaySeconds 3
        
        Loads Get-FileDownload with custom retry settings (10 attempts, 3 second delays).
    
    .NOTES
        This function is designed to be used at the beginning of cmdlet files to eliminate
        the 80+ lines of boilerplate code that was previously duplicated across multiple files.
        
        Before: Each cmdlet had ~80 lines of duplicate loading code
        After: Each cmdlet uses 1-5 lines to call this function
        
        Eliminates approximately 800-1000 lines of code duplication across the cmdlets folder.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]$RequiredCmdlets,
        
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$MaxRetries = 20,
        
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 60)]
        [int]$RetryDelaySeconds = 5,
        
        [Parameter(Mandatory = $false)]
        [string]$RepositoryUrl = 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions',
        
        [Parameter(Mandatory = $false)]
        [switch]$PreferLocal,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    begin {
        Write-Verbose "Initializing cmdlet dependencies: $($RequiredCmdlets -join ', ')"
        
        # Accumulator for file-based scriptblocks
        $FileScriptBlock = ''
    }
    
    process {
        # Filter to only cmdlets that aren't already loaded (unless Force is specified)
        $missingCmdlets = if ($Force) {
            $RequiredCmdlets
        }
        else {
            $RequiredCmdlets | Where-Object { 
                -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) 
            }
        }
        
        if (-not $missingCmdlets) {
            Write-Verbose 'All required cmdlets are already loaded'
            return
        }
        
        Write-Verbose "Missing cmdlets detected: $($missingCmdlets -join ', ')"
        
        # Step 1: Ensure Install-Cmdlet infrastructure is available
        if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
            Write-Verbose 'Install-Cmdlet not found, downloading from repository...'
            
            $maxRetryAttempts = $MaxRetries
            $retryCount = 0
            $success = $false
            $method = $null
            
            while (-not $success -and $retryCount -lt $maxRetryAttempts) {
                try {
                    $retryCount++
                    if ($retryCount -gt 1) {
                        Write-Verbose "Retrying Install-Cmdlet download (attempt $retryCount of $maxRetryAttempts)..."
                        Start-Sleep -Seconds $RetryDelaySeconds
                    }
                    
                    Write-Verbose "Downloading Install-Cmdlet.ps1 (attempt $retryCount)..."
                    $installCmdletUrl = "$RepositoryUrl/Install-Cmdlet.ps1"
                    $method = Invoke-RestMethod -Uri $installCmdletUrl -ErrorAction Stop
                    $success = $true
                    Write-Verbose 'Successfully downloaded Install-Cmdlet.ps1'
                }
                catch {
                    $errorMsg = $_.Exception.Message
                    Write-Warning "Failed to download Install-Cmdlet.ps1 (attempt $retryCount): $errorMsg"
                    
                    if ($retryCount -eq $maxRetryAttempts) {
                        $criticalError = "CRITICAL ERROR: Failed to download Install-Cmdlet.ps1 after $maxRetryAttempts attempts. " +
                        'Please check your internet connection and repository access. ' +
                        "Repository URL: $RepositoryUrl"
                        Write-Error $criticalError
                        throw $criticalError
                    }
                }
            }
            
            # Create and import Install-Cmdlet module
            $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
            $installCmdletModule = New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring
            $installCmdletModule | Import-Module -Force
            Write-Verbose 'Install-Cmdlet module created and imported'
        }
        
        # Step 2: Download and import each missing cmdlet
        foreach ($cmd in $missingCmdlets) {
            Write-Verbose "Processing cmdlet: $cmd"
            
            $maxCmdletRetries = $MaxRetries
            $cmdletRetryCount = 0
            $cmdletSuccess = $false
            $scriptBlock = $null
            
            while (-not $cmdletSuccess -and $cmdletRetryCount -lt $maxCmdletRetries) {
                try {
                    $cmdletRetryCount++
                    if ($cmdletRetryCount -gt 1) {
                        Write-Verbose "Retrying cmdlet '$cmd' download (attempt $cmdletRetryCount of $maxCmdletRetries)..."
                        Start-Sleep -Seconds $RetryDelaySeconds
                    }
                    
                    Write-Verbose "Downloading cmdlet: $cmd (attempt $cmdletRetryCount)..."
                    
                    # Build Install-Cmdlet parameters
                    $installParams = @{
                        RepositoryCmdlets = $cmd
                    }
                    if ($PreferLocal) {
                        $installParams['PreferLocal'] = $true 
                    }
                    if ($Force) {
                        $installParams['Force'] = $true 
                    }
                    
                    $scriptBlock = Install-Cmdlet @installParams
                    $cmdletSuccess = $true
                    Write-Verbose "Successfully downloaded cmdlet: $cmd"
                }
                catch {
                    $errorMsg = $_.Exception.Message
                    Write-Warning "Failed to download cmdlet '$cmd' (attempt $cmdletRetryCount): $errorMsg"
                    
                    if ($cmdletRetryCount -eq $maxCmdletRetries) {
                        $criticalError = "CRITICAL ERROR: Failed to download required cmdlet '$cmd' after $maxCmdletRetries attempts. " +
                        'This cmdlet is required for proper script functionality. ' +
                        "Repository URL: $RepositoryUrl/$cmd.ps1"
                        Write-Error $criticalError
                        throw $criticalError
                    }
                }
            }
            
            # Step 3: Import the cmdlet based on its return type
            if ($scriptBlock -is [scriptblock]) {
                # ScriptBlock return - create dynamic module
                $moduleName = "Dynamic_$cmd"
                $dynamicModule = New-Module -Name $moduleName -ScriptBlock $scriptBlock
                $dynamicModule | Import-Module -Force
                Write-Verbose "Imported $cmd as dynamic module: $moduleName"
            }
            elseif ($scriptBlock -is [System.Management.Automation.PSModuleInfo]) {
                # Module already imported
                Write-Verbose "Module for $cmd was already imported: $($scriptBlock.Name)"
            }
            elseif ($scriptBlock -and (Test-Path -Path $scriptBlock -ErrorAction SilentlyContinue)) {
                # File path return - accumulate content for batch import
                $FileScriptBlock += $(Get-Content -Path $scriptBlock -Raw -ErrorAction Stop) + "`n"
                Write-Verbose "Added $cmd from file to import queue: $scriptBlock"
            }
            else {
                $warningMsg = "Unexpected return type from Install-Cmdlet for '$cmd'. " +
                "Type: $($scriptBlock.GetType().FullName), Value: $scriptBlock"
                Write-Warning $warningMsg
            }
        }
    }
    
    end {
        # Import any file-based cmdlets as a single module
        if (-not [string]::IsNullOrWhiteSpace($FileScriptBlock)) {
            Write-Verbose 'Importing file-based cmdlets as cmdletCollection module'
            
            try {
                $finalFileScriptBlock = [scriptblock]::Create(
                    $FileScriptBlock.ToString() + "`nExport-ModuleMember -Function * -Alias *"
                )
                $collectionModule = New-Module -Name 'cmdletCollection' -ScriptBlock $finalFileScriptBlock
                $collectionModule | Import-Module -Force
                Write-Verbose 'Successfully imported cmdletCollection module'
            }
            catch {
                Write-Error "Failed to import cmdletCollection module: $($_.Exception.Message)"
                throw
            }
        }
        
        Write-Verbose 'Cmdlet dependency initialization complete'
    }
}
