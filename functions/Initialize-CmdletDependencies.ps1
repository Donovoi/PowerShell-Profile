#Requires -Version 5.1

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
        
        SECURITY NOTE: This function downloads and executes code from a remote repository.
        Ensure you trust the repository source before use.
    
    .PARAMETER RequiredCmdlets
        An array of cmdlet names that need to be loaded for the calling script.
    
    .PARAMETER MaxRetries
        Maximum number of retry attempts for downloading cmdlets. Default is 20.
    
    .PARAMETER RetryDelaySeconds
        Number of seconds to wait between retry attempts. Default is 5.
    
    .PARAMETER RepositoryUrl
        The base GitHub repository URL for downloading cmdlets.
        Default is 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions'
    
    .PARAMETER TimeoutSeconds
        Timeout in seconds for web requests. Default is 30.
    
    .PARAMETER PreferLocal
        Switch to prefer locally cached cmdlets over downloading.
    
    .PARAMETER Force
        Force re-download of cmdlets even if they exist.
    
    .PARAMETER NoLocalFallback
        If specified, will not attempt to load from local Cmdlets folder.
    
    .EXAMPLE
        Initialize-CmdletDependencies -RequiredCmdlets @('Install-Dependencies', 'Write-Logg')
        
        Loads the Install-Dependencies and Write-Logg cmdlets, downloading them if necessary.
    
    .EXAMPLE
        Initialize-CmdletDependencies -RequiredCmdlets @('Get-FileDownload') -MaxRetries 10 -RetryDelaySeconds 3
        
        Loads Get-FileDownload with custom retry settings (10 attempts, 3 second delays).
    
    .EXAMPLE
        Initialize-CmdletDependencies -RequiredCmdlets @('Write-Logg') -PreferLocal
        
        Attempts to load from local Cmdlets folder before downloading.
    
    .NOTES
        This function is designed to be used at the beginning of cmdlet files to eliminate
        the 80+ lines of boilerplate code that was previously duplicated across multiple files.
        
        Before: Each cmdlet had ~80 lines of duplicate loading code
        After: Each cmdlet uses 1-5 lines to call this function
        
        Eliminates approximately 800-1000 lines of code duplication across the cmdlets folder.
        
    .LINK
        https://github.com/Donovoi/PowerShell-Profile
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string[]]$RequiredCmdlets,
        
        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$MaxRetries = 20,
        
        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$RetryDelaySeconds = 5,
        
        [Parameter()]
        [ValidateScript({
                if ($_ -as [uri] -and ([uri]$_).IsAbsoluteUri -and ([uri]$_).Scheme -match '^https?$') {
                    $true
                }
                else {
                    throw "RepositoryUrl must be a valid HTTP/HTTPS URL. Provided: $_"
                }
            })]
        [string]$RepositoryUrl = 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions',
        
        [Parameter()]
        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 30,
        
        [Parameter()]
        [switch]$PreferLocal,
        
        [Parameter()]
        [switch]$Force,
        
        [Parameter()]
        [switch]$NoLocalFallback
    )
    
    begin {
        Write-Verbose -Message ('Initializing cmdlet dependencies: {0}' -f ($RequiredCmdlets -join ', '))
        
        # Set TLS 1.2 for secure connections (fixes SSL errors)
        if ($PSVersionTable.PSVersion.Major -le 5) {
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            }
            catch {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
        }
        
        # Use StringBuilder for efficient string concatenation
        $script:FileScriptBlockBuilder = [System.Text.StringBuilder]::new()
        
        # Helper function for retry logic
        function Invoke-WithRetry {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [scriptblock]$ScriptBlock,
                
                [Parameter(Mandatory)]
                [string]$Operation,
                
                [Parameter()]
                [int]$MaxAttempts,
                
                [Parameter()]
                [int]$DelaySeconds
            )
            
            # Use parent scope values if not provided
            if (-not $MaxAttempts) {
                $MaxAttempts = $MaxRetries
            }
            if (-not $DelaySeconds) {
                $DelaySeconds = $RetryDelaySeconds
            }
            
            $Attempt = 0
            $Success = $false
            $Result = $null
            
            while (-not $Success -and $Attempt -lt $MaxAttempts) {
                $Attempt++
                
                if ($Attempt -gt 1) {
                    Write-Verbose -Message ('{0} - Retry attempt {1}/{2}' -f $Operation, $Attempt, $MaxAttempts)
                    Start-Sleep -Seconds $DelaySeconds
                }
                
                try {
                    Write-Verbose -Message ('{0} - Attempt {1}' -f $Operation, $Attempt)
                    $Result = & $ScriptBlock
                    $Success = $true
                    Write-Verbose -Message ('{0} - Success' -f $Operation)
                }
                catch {
                    $ErrorMsg = if ($_.Exception.InnerException) {
                        '{0} (Inner: {1})' -f $_.Exception.Message, $_.Exception.InnerException.Message
                    }
                    else {
                        $_.Exception.Message
                    }
                    
                    Write-Warning -Message ('{0} - Attempt {1} failed: {2}' -f $Operation, $Attempt, $ErrorMsg)
                    
                    if ($Attempt -eq $MaxAttempts) {
                        $ErrorMessage = 'CRITICAL: {0} failed after {1} attempts. Last error: {2}' -f $Operation, $MaxAttempts, $ErrorMsg
                        Write-Error -Message $ErrorMessage -ErrorAction Continue
                        return $null
                    }
                }
            }
            
            return $Result
        }
        
        # Helper function for local cmdlet loading
        function Get-LocalCmdletPath {
            [CmdletBinding()]
            [OutputType([string])]
            param(
                [Parameter(Mandatory)]
                [string]$CmdletName
            )
            
            # Try to determine cmdlets folder from call stack
            $CallStack = Get-PSCallStack -ErrorAction SilentlyContinue | 
                Where-Object { $_.ScriptName } | 
                    Select-Object -First 1
            
            $CandidatePaths = @()
            
            if ($CallStack -and $CallStack.ScriptName) {
                $CallerDir = Split-Path -Path $CallStack.ScriptName -Parent
                
                # Check if we're in Cmdlets folder
                if ($CallerDir -match '[\\/]Cmdlets$') {
                    $CandidatePaths += $CallerDir
                }
                
                # Check parent/Cmdlets
                $ParentCmdlets = Join-Path -Path (Split-Path -Path $CallerDir -Parent) -ChildPath 'Cmdlets'
                if (Test-Path -Path $ParentCmdlets -PathType Container) {
                    $CandidatePaths += $ParentCmdlets
                }
                
                # Check caller/Cmdlets
                $CallerCmdlets = Join-Path -Path $CallerDir -ChildPath 'Cmdlets'
                if (Test-Path -Path $CallerCmdlets -PathType Container) {
                    $CandidatePaths += $CallerCmdlets
                }
            }
            
            # Add PSScriptRoot fallback
            if ($PSScriptRoot) {
                $CandidatePaths += $PSScriptRoot
            }
            
            # Check each candidate path
            foreach ($Path in $CandidatePaths) {
                $CmdletFile = Join-Path -Path $Path -ChildPath ('{0}.ps1' -f $CmdletName)
                if (Test-Path -Path $CmdletFile -PathType Leaf) {
                    return $CmdletFile
                }
            }
            
            return $null
        }
    }
    
    process {
        # Filter to only cmdlets that aren't already loaded (unless Force is specified)
        $MissingCmdlets = if ($Force) {
            $RequiredCmdlets
        }
        else {
            $RequiredCmdlets | Where-Object { 
                -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) 
            }
        }
        
        if (-not $MissingCmdlets) {
            Write-Verbose -Message 'All required cmdlets are already loaded'
            return
        }
        
        Write-Verbose -Message ('Missing cmdlets detected: {0}' -f ($MissingCmdlets -join ', '))
        
        # Try local loading first if PreferLocal is specified
        if ($PreferLocal -and -not $NoLocalFallback) {
            Write-Verbose -Message 'Attempting to load cmdlets from local Cmdlets folder'
            
            $LocallyLoaded = @()
            foreach ($CmdletName in $MissingCmdlets) {
                $LocalPath = Get-LocalCmdletPath -CmdletName $CmdletName
                
                if ($LocalPath) {
                    try {
                        if ($PSCmdlet.ShouldProcess($LocalPath, 'Dot-source cmdlet')) {
                            . $LocalPath
                            Write-Verbose -Message ('Successfully loaded {0} from local path: {1}' -f $CmdletName, $LocalPath)
                            $LocallyLoaded += $CmdletName
                        }
                    }
                    catch {
                        Write-Warning -Message ('Failed to load {0} from local path: {1}' -f $CmdletName, $_.Exception.Message)
                    }
                }
            }
            
            # Remove successfully loaded cmdlets from missing list
            $MissingCmdlets = $MissingCmdlets | Where-Object { $_ -notin $LocallyLoaded }
            
            if (-not $MissingCmdlets) {
                Write-Verbose -Message 'All cmdlets loaded from local sources'
                return
            }
        }
        
        # Step 1: Ensure Install-Cmdlet infrastructure is available
        if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
            Write-Verbose -Message 'Install-Cmdlet not found, downloading from repository'
            
            $InstallCmdletContent = Invoke-WithRetry -Operation 'Download Install-Cmdlet' -MaxAttempts $MaxRetries -DelaySeconds $RetryDelaySeconds -ScriptBlock {
                $Uri = '{0}/Install-Cmdlet.ps1' -f $RepositoryUrl.TrimEnd('/')
                
                $WebRequestParams = @{
                    Uri             = $Uri
                    ErrorAction     = 'Stop'
                    TimeoutSec      = $TimeoutSeconds
                    UseBasicParsing = $true
                }
                
                # Add progress bar suppression for performance
                $OldProgressPreference = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                try {
                    $Response = Invoke-RestMethod @WebRequestParams
                    return $Response
                }
                finally {
                    $ProgressPreference = $OldProgressPreference
                }
            }
            
            if (-not $InstallCmdletContent) {
                Write-Error -Message 'Failed to download Install-Cmdlet after all retry attempts. Cannot continue.' -ErrorAction Stop
            }
            
            # Create and import Install-Cmdlet module
            if ($PSCmdlet.ShouldProcess('InstallCmdlet', 'Create and import dynamic module')) {
                try {
                    if ([string]::IsNullOrWhiteSpace($InstallCmdletContent)) {
                        throw 'Install-Cmdlet content is empty or null'
                    }
                    $ModuleScript = '{0}{1}Export-ModuleMember -Function * -Alias *' -f $InstallCmdletContent, [Environment]::NewLine
                    $ScriptBlock = [scriptblock]::Create($ModuleScript)
                    $InstallCmdletModule = New-Module -Name 'InstallCmdlet' -ScriptBlock $ScriptBlock
                    $InstallCmdletModule | Import-Module -Force -ErrorAction Stop
                    Write-Verbose -Message 'Install-Cmdlet module created and imported'
                }
                catch {
                    Write-Error -Message ('Failed to create Install-Cmdlet module: {0}' -f $_.Exception.Message) -ErrorAction Stop
                }
            }
        }
        
        # Step 2: Download and import each missing cmdlet
        foreach ($CmdletName in $MissingCmdlets) {
            Write-Verbose -Message ('Processing cmdlet: {0}' -f $CmdletName)
            
            $ScriptBlockResult = Invoke-WithRetry -Operation ('Download cmdlet: {0}' -f $CmdletName) -MaxAttempts $MaxRetries -DelaySeconds $RetryDelaySeconds -ScriptBlock {
                $InstallParams = @{
                    RepositoryCmdlets = $CmdletName
                }
                
                if ($PreferLocal) {
                    $InstallParams['PreferLocal'] = $true
                }
                if ($Force) {
                    $InstallParams['Force'] = $true
                }
                
                return (Install-Cmdlet @InstallParams)
            }
            
            # Step 3: Import the cmdlet based on its return type
            if ($PSCmdlet.ShouldProcess($CmdletName, 'Import cmdlet')) {
                try {
                    switch ($ScriptBlockResult) {
                        { $_ -is [scriptblock] } {
                            # ScriptBlock return - create dynamic module
                            $ModuleName = 'Dynamic_{0}' -f $CmdletName
                            $DynamicModule = New-Module -Name $ModuleName -ScriptBlock $ScriptBlockResult
                            $DynamicModule | Import-Module -Force -ErrorAction Stop
                            Write-Verbose -Message ('Imported {0} as dynamic module: {1}' -f $CmdletName, $ModuleName)
                        }
                        
                        { $_ -is [System.Management.Automation.PSModuleInfo] } {
                            # Module already imported
                            Write-Verbose -Message ('Module for {0} was already imported: {1}' -f $CmdletName, $_.Name)
                        }
                        
                        { $_ -and (Test-Path -Path $_ -PathType Leaf -ErrorAction SilentlyContinue) } {
                            # File path return - accumulate content for batch import
                            $Content = Get-Content -Path $_ -Raw -ErrorAction Stop
                            if ($script:FileScriptBlockBuilder -and -not [string]::IsNullOrWhiteSpace($Content)) {
                                [void]$script:FileScriptBlockBuilder.AppendLine($Content)
                                Write-Verbose -Message ('Added {0} from file to import queue: {1}' -f $CmdletName, $_)
                            }
                            else {
                                Write-Warning -Message ('Could not append content for {0} - StringBuilder or content is null' -f $CmdletName)
                            }
                        }
                        
                        default {
                            $TypeName = if ($null -ne $_) {
                                $_.GetType().FullName 
                            }
                            else {
                                'null' 
                            }
                            Write-Warning -Message ('Unexpected return type from Install-Cmdlet for {0}. Type: {1}, Value: {2}' -f $CmdletName, $TypeName, $_)
                        }
                    }
                }
                catch {
                    Write-Error -Message ('Failed to import cmdlet {0}: {1}' -f $CmdletName, $_.Exception.Message)
                }
            }
        }
    }
    
    end {
        # Import any file-based cmdlets as a single module
        $FileScriptBlock = if ($script:FileScriptBlockBuilder) {
            $script:FileScriptBlockBuilder.ToString()
        }
        else {
            ''
        }
        
        if (-not [string]::IsNullOrWhiteSpace($FileScriptBlock)) {
            if ($PSCmdlet.ShouldProcess('cmdletCollection', 'Import file-based cmdlets module')) {
                Write-Verbose -Message 'Importing file-based cmdlets as cmdletCollection module'
                
                try {
                    $ModuleScript = '{0}{1}Export-ModuleMember -Function * -Alias *' -f $FileScriptBlock, [Environment]::NewLine
                    $FinalScriptBlock = [scriptblock]::Create($ModuleScript)
                    $CollectionModule = New-Module -Name 'cmdletCollection' -ScriptBlock $FinalScriptBlock
                    $CollectionModule | Import-Module -Force -ErrorAction Stop
                    Write-Verbose -Message 'Successfully imported cmdletCollection module'
                }
                catch {
                    Write-Error -Message ('Failed to import cmdletCollection module: {0}' -f $_.Exception.Message) -ErrorAction Stop
                }
            }
        }
        
        Write-Verbose -Message 'Cmdlet dependency initialization complete'
    }
}
