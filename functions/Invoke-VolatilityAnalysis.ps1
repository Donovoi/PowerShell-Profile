# pip install capstone

function Invoke-VolatilityAnalysis {
    <#
    .SYNOPSIS
    Runs Volatility 3 plugins against a memory image file and outputs results to text files.

    .DESCRIPTION
    This advanced function automates the process of running multiple Volatility 3 plugins against 
    a memory image file. It automatically discovers available plugins, runs each one, and saves 
    the output to separate text files.

    The function provides progress reporting, error handling, and verbose logging to help troubleshoot 
    any issues that might occur during analysis.

    .PARAMETER MemoryImagePath
    The full path to the memory image file to analyze. This parameter is mandatory.

    .PARAMETER VolatilityPath
    The path to the Volatility executable. Defaults to 'vol.exe' which assumes it's in your PATH.

    .PARAMETER OutputDirectory
    The directory where plugin output files will be saved. Defaults to a 'volatility3' folder on your Desktop.

    .PARAMETER SpecificPlugins
    Optional array of specific plugin names to run. If not specified, all Windows plugins will be discovered and run.

    .PARAMETER ExcludePlugins
    Optional array of plugin names to exclude from running.

    .PARAMETER IncludeLsaDump
    Switch to specifically include the windows.lsadump.Lsadump plugin, which is often useful for credential extraction.

    .PARAMETER Force
    Switch to force overwrite of existing output files without prompting.

    .EXAMPLE
    Invoke-VolatilityAnalysis -MemoryImagePath "C:\Evidence\memory.raw"

    Runs all discovered Volatility 3 plugins against the memory.raw file and saves output to the default directory.

    .EXAMPLE
    Invoke-VolatilityAnalysis -MemoryImagePath "C:\Evidence\memory.raw" -OutputDirectory "C:\Cases\Case123\MemoryAnalysis" -IncludeLsaDump -Verbose

    Runs all plugins plus the LSA dump plugin, with detailed verbose output, and saves results to a case-specific directory.

    .EXAMPLE
    Invoke-VolatilityAnalysis -MemoryImagePath "C:\Evidence\memory.raw" -SpecificPlugins @("windows.pslist.PsList", "windows.netscan.NetScan")

    Runs only the specified plugins against the memory image.

    .NOTES
    Author: PowerShell Expert
    Version: 1.0
    Requires: Volatility 3 framework installed
    Dependencies: Capstone Python library (pip install capstone)

    .LINK
    https://github.com/volatilityfoundation/volatility3
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'AllPlugins')]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateScript({
                if (-not (Test-Path -Path $_ -PathType Leaf)) {
                    throw "Memory image file does not exist at path: $_"
                }
                return $true
            })]
        [Alias('Path', 'MemImage')]
        [string]$MemoryImagePath,

        [Parameter(Mandatory = $false)]
        [ValidateScript({
                if ($_ -eq 'vol.exe' -and -not (Get-Command $_ -ErrorAction SilentlyContinue)) {
                    throw 'Volatility executable not found in PATH. Please provide the full path or ensure vol.exe is in your PATH.'
                }
                elseif ($_ -ne 'vol.exe' -and -not (Test-Path -Path $_ -PathType Leaf)) {
                    throw "Volatility executable does not exist at path: $_"
                }
                return $true
            })]
        [string]$VolatilityPath = 'vol.exe',

        [Parameter(Mandatory = $false)]
        [ValidateScript({
                if (-not (Test-Path -Path $_ -PathType Container) -and -not (New-Item -Path $_ -ItemType Directory -Force -ErrorAction SilentlyContinue)) {
                    throw "Cannot create output directory at path: $_"
                }
                return $true
            })]
        [string]$OutputDirectory = "$ENV:USERPROFILE\Desktop\volatility3",

        [Parameter(Mandatory = $false, ParameterSetName = 'SpecificPlugins')]
        [string[]]$SpecificPlugins,

        [Parameter(Mandatory = $false, ParameterSetName = 'AllPlugins')]
        [string[]]$ExcludePlugins,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeLsaDump,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    begin {
        # Initialize
        Write-Verbose "Initializing Volatility analysis with memory image: $MemoryImagePath"

        # Ensure the output directory exists
        if (-not (Test-Path -Path $OutputDirectory)) {
            try {
                $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop
                Write-Verbose "Created output directory: $OutputDirectory"
            }
            catch {
                throw "Failed to create output directory '$OutputDirectory': $_"
            }
        }
        
        # Check if Volatility is accessible
        try {
            $volatilityVersion = & $VolatilityPath --version 2>&1
            Write-Verbose "Using Volatility: $volatilityVersion"
        }
        catch {
            throw "Error running Volatility. Please ensure it's installed correctly: $_"
        }

        # Get available plugins - only if we're not using SpecificPlugins
        $pluginList = @()
        
        if ($PSCmdlet.ParameterSetName -eq 'AllPlugins') {
            Write-Verbose 'Getting available Volatility plugins...'
            try {
                $helpText = & $VolatilityPath -h 2>&1 | Out-String
                
                # Extract Windows plugin names using regex
                $regex = [regex]::new('windows\.[A-Za-z0-9_]+\.[A-Za-z0-9_]+')
                $pluginList = $regex.Matches($helpText) | ForEach-Object { $_.Value } | Sort-Object -Unique
                
                # Remove excluded plugins if specified
                if ($ExcludePlugins) {
                    $pluginList = $pluginList | Where-Object { $ExcludePlugins -notcontains $_ }
                    Write-Verbose "Excluded plugins: $($ExcludePlugins -join ', ')"
                }
                
                Write-Verbose "Found $($pluginList.Count) plugins to run"
            }
            catch {
                throw "Failed to retrieve Volatility plugin list: $_"
            }
        }
        else {
            $pluginList = $SpecificPlugins
            Write-Verbose "Using specific plugins: $($SpecificPlugins -join ', ')"
        }

        # Add LSA dump plugin if requested and not already included
        $lsaDumpPlugin = 'windows.lsadump.Lsadump'
        if ($IncludeLsaDump -and $pluginList -notcontains $lsaDumpPlugin) {
            $pluginList += $lsaDumpPlugin
            Write-Verbose 'Added LSA Dump plugin to the list'
        }
        
        # Validate memory image using info plugin before proceeding
        Write-Verbose 'Validating memory image...'
        try {
            $infoOutput = & $VolatilityPath -f $MemoryImagePath windows.info.Info 2>&1
            
            if ($infoOutput -match 'ERROR' -or $infoOutput -match 'No valid') {
                Write-Warning "Memory image validation warning: $($infoOutput -join "`n")"
            }
            else {
                Write-Verbose 'Memory image validated successfully'
                # Extract and log OS information
                $osInfo = $infoOutput | Where-Object { $_ -match 'Kernel Base|NT Build|Major/Minor' }
                foreach ($line in $osInfo) {
                    Write-Verbose "Memory image info: $line"
                }
            }
        }
        catch {
            Write-Warning "Memory image validation error: $_"
        }
    }

    process {
        # Process the plugins
        $results = @()
        $totalPlugins = $pluginList.Count
        $currentPlugin = 0
        
        foreach ($plugin in $pluginList) {
            $currentPlugin++
            $percentComplete = [math]::Round(($currentPlugin / $totalPlugins) * 100)
            
            # Create safe filename
            $safePluginName = $plugin -replace '[^\w\.]', '_'
            $outputFile = Join-Path -Path $OutputDirectory -ChildPath "$safePluginName.txt"
            
            # Check if output exists and handle Force parameter
            if (Test-Path -Path $outputFile) {
                if (-not $Force) {
                    if (-not $PSCmdlet.ShouldProcess($outputFile, 'Overwrite existing plugin output file')) {
                        Write-Verbose "Skipping $plugin - output file exists and -Force not specified"
                        continue
                    }
                }
                Write-Verbose "Output file for $plugin exists and will be overwritten"
            }
            
            Write-Progress -Activity 'Running Volatility Plugins' -Status "Running plugin $currentPlugin of $totalPlugins`: $plugin" -PercentComplete $percentComplete
            Write-Verbose "Running plugin: $plugin"
            
            try {
                # Run the plugin and capture output
                & $VolatilityPath -f $MemoryImagePath $plugin > $outputFile 2>&1
                
                # Check if the output file has content
                $fileSize = (Get-Item -Path $outputFile).Length
                if ($fileSize -gt 0) {
                    Write-Verbose "Successfully saved output of $plugin to $outputFile ($fileSize bytes)"
                    $results += [PSCustomObject]@{
                        Plugin     = $plugin
                        OutputFile = $outputFile
                        Success    = $true
                        FileSize   = $fileSize
                    }
                } 
                else {
                    Write-Warning "Plugin $plugin produced no output"
                    $results += [PSCustomObject]@{
                        Plugin     = $plugin
                        OutputFile = $outputFile
                        Success    = $false
                        FileSize   = 0
                        Error      = 'No output produced'
                    }
                }
            }
            catch {
                Write-Warning "Error running plugin $plugin : $_"
                $results += [PSCustomObject]@{
                    Plugin     = $plugin
                    OutputFile = $null
                    Success    = $false
                    Error      = $_.ToString()
                }
            }
        }
        
        Write-Progress -Activity 'Running Volatility Plugins' -Completed
        
        # Return results
        return $results
    }

    end {
        # Summarize results
        $successCount = ($results | Where-Object { $_.Success }).Count
        $failCount = ($results | Where-Object { -not $_.Success }).Count
        
        Write-Verbose "Volatility analysis complete: $successCount plugins completed successfully, $failCount plugins failed"
        Write-Verbose "Results saved to: $OutputDirectory"
    }
}