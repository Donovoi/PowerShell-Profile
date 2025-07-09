function Start-ForensicSystemElevation {
    <#
    .SYNOPSIS
    Handles elevation to SYSTEM privileges for forensic collection.

    .DESCRIPTION
    Creates and executes a script under SYSTEM context for comprehensive forensic
    artifact collection with maximum privileges.

    .PARAMETER CollectionPath
    Path where artifacts will be collected.

    .EXAMPLE
    $result = Start-ForensicSystemElevation -CollectionPath "C:\Investigation"

    .OUTPUTS
    PSCustomObject with elevation results.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$CollectionPath
    )

    try {
        Write-Verbose "Preparing SYSTEM elevation for forensic collection..."

        # Build elevated script content
        $elevatedScript = Build-ElevatedForensicScript -CollectionPath $CollectionPath

        # Create temporary script file
        $tempScript = New-TemporaryFile | Rename-Item -NewName { $_.Name + '.ps1' } -PassThru
        $elevatedScript | Out-File -FilePath $tempScript.FullName -Encoding UTF8

        Write-Verbose "Created temporary script: $($tempScript.FullName)"

        # Determine PowerShell executable
        $powershellPath = if (Get-Command pwsh -ErrorAction SilentlyContinue) {
            'pwsh.exe'
        } else {
            'powershell.exe'
        }

        $systemArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$($tempScript.FullName)`""

        Write-Verbose "Executing SYSTEM elevation with: $powershellPath $systemArgs"

        # Execute under SYSTEM context
        Get-SYSTEM -Command $powershellPath -Arguments $systemArgs

        # Schedule cleanup
        Register-ForensicCleanup -TempScript $tempScript.FullName

        return [PSCustomObject]@{
            Success = $true
            CollectionPath = $CollectionPath
            Message = "SYSTEM elevation initiated successfully"
        }
    }
    catch {
        return [PSCustomObject]@{
            Success = $false
            CollectionPath = $null
            Message = "SYSTEM elevation failed: $($_.Exception.Message)"
        }
    }
}

function Build-ElevatedForensicScript {
    <#
    .SYNOPSIS
    Builds the PowerShell script to run under SYSTEM privileges.

    .DESCRIPTION
    Creates a self-contained script that includes all necessary functions
    and executes the forensic collection under SYSTEM context.

    .PARAMETER CollectionPath
    Path where artifacts will be collected.

    .OUTPUTS
    String containing the complete script content.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$CollectionPath
    )

    $scriptContent = @"
# Forensic Collection Script - SYSTEM Context
# Generated: $(Get-Date)
# Collection Path: $CollectionPath

# Error handling
`$ErrorActionPreference = 'Continue'
`$VerbosePreference = 'Continue'

# Initialize logging
`$logFile = Join-Path '$CollectionPath' 'system_collection.log'
Start-Transcript -Path `$logFile -Append

try {
    Write-Host "Starting forensic collection under SYSTEM privileges..."
    Write-Host "Collection Path: $CollectionPath"

    # Install dependencies
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        Write-Host "Installing powershell-yaml module..."
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser -ErrorAction Stop
        Import-Module powershell-yaml -Force
    }

    # Import forensic functions from the profile directory
    `$profileRoot = Split-Path '$PSScriptRoot' -Parent
    `$functionsDir = Join-Path `$profileRoot 'functions'

    # Import the new modular forensic functions
    `$forensicModules = @(
        'ForensicArtifacts\Get-ForensicArtifacts.ps1',
        'ForensicArtifacts\Initialize-ForensicEnvironment.ps1',
        'ForensicArtifacts\ConvertTo-ForensicArtifact.ps1',
        'ForensicArtifacts\Invoke-ForensicCollection.ps1',
        'ForensicArtifacts\Copy-ForensicArtifact.ps1',
        'ForensicArtifacts\Copy-FileSystemUtilities.ps1'
    )

    foreach (`$module in `$forensicModules) {
        `$modulePath = Join-Path `$functionsDir `$module
        if (Test-Path `$modulePath) {
            Write-Host "Importing: `$module"
            . `$modulePath
        } else {
            Write-Warning "Module not found: `$modulePath"
        }
    }

    # Import additional required functions
    `$additionalFunctions = @('Invoke-RawyCopy.ps1')
    foreach (`$func in `$additionalFunctions) {
        `$funcPath = Join-Path `$functionsDir `$func
        if (Test-Path `$funcPath) {
            Write-Host "Importing additional function: `$func"
            . `$funcPath
        }
    }

    # Execute forensic collection
    Write-Host "Executing forensic artifact collection..."
    `$results = Get-ForensicArtifacts -CollectArtifacts -CollectionPath '$CollectionPath' -Verbose

    Write-Host "Collection completed. Processed `$(`$results.Count) artifacts."

    # Create completion marker
    `$completionFile = Join-Path '$CollectionPath' 'SYSTEM_COLLECTION_COMPLETE.txt'
    "Forensic collection completed under SYSTEM privileges at `$(Get-Date)" | Out-File -FilePath `$completionFile

    Write-Host "Collection completed successfully!"
}
catch {
    Write-Error "Error during SYSTEM collection: `$(`$_.Exception.Message)"
    `$errorFile = Join-Path '$CollectionPath' 'SYSTEM_COLLECTION_ERROR.txt'
    `$_.Exception | Out-File -FilePath `$errorFile
}
finally {
    Stop-Transcript
}
"@

    return $scriptContent
}

function Register-ForensicCleanup {
    <#
    .SYNOPSIS
    Registers cleanup tasks for temporary forensic collection files.

    .DESCRIPTION
    Schedules cleanup of temporary scripts and files created during the
    forensic collection process.

    .PARAMETER TempScript
    Path to the temporary script file to clean up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TempScript
    )

    try {
        # Register a job to clean up the temporary script after a delay
        $cleanupScript = {
            param($ScriptPath)
            Start-Sleep -Seconds 60  # Wait for SYSTEM process to complete
            if (Test-Path $ScriptPath) {
                Remove-Item -Path $ScriptPath -Force -ErrorAction SilentlyContinue
                Write-Verbose "Cleaned up temporary script: $ScriptPath"
            }
        }

        Start-Job -ScriptBlock $cleanupScript -ArgumentList $TempScript -Name "ForensicCleanup_$(Get-Date -Format 'HHmmss')" | Out-Null
        Write-Verbose "Registered cleanup job for: $TempScript"
    }
    catch {
        Write-Warning "Failed to register cleanup: $($_.Exception.Message)"
    }
}

function Write-ForensicCollectionReport {
    <#
    .SYNOPSIS
    Generates a comprehensive report of forensic collection results.

    .DESCRIPTION
    Creates detailed reports and summaries of the forensic artifact collection
    process, including statistics and error information.

    .PARAMETER Results
    Array of collection results from forensic artifacts.

    .PARAMETER CollectionPath
    Path where the collection was performed.

    .EXAMPLE
    Write-ForensicCollectionReport -Results $results -CollectionPath "C:\Investigation"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$Results,

        [Parameter(Mandatory)]
        [string]$CollectionPath
    )

    try {
        Write-Progress -Activity 'Generating Collection Report' -PercentComplete 100 -Completed

        # Calculate statistics
        $totalArtifacts = $Results.Count
        $collectedArtifacts = @($Results | Where-Object { $_.CollectionResult.Success }).Count
        $failedArtifacts = $totalArtifacts - $collectedArtifacts
        $totalFiles = ($Results | Where-Object { $_.CollectionResult } | Measure-Object -Property { $_.CollectionResult.FilesCollected } -Sum).Sum

        # Get privilege information
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $privilegeLevel = if ($currentUser.IsSystem) {
            'SYSTEM'
        } elseif (([Security.Principal.WindowsPrincipal]$currentUser).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            'Administrator'
        } else {
            'Standard User'
        }

        # Generate summary report
        $reportContent = @"
Forensic Artifact Collection Report
===================================
Collection Time: $(Get-Date)
Collection Path: $CollectionPath
Privilege Level: $privilegeLevel
PowerShell Version: $($PSVersionTable.PSVersion)

Collection Summary:
------------------
Total Artifacts Processed: $totalArtifacts
Successfully Collected: $collectedArtifacts
Failed Collections: $failedArtifacts
Total Files Collected: $totalFiles
Success Rate: $([math]::Round(($collectedArtifacts / $totalArtifacts) * 100, 2))%

Successful Collections:
----------------------
$(($Results | Where-Object { $_.CollectionResult.Success } | ForEach-Object { "✓ $($_.Name) ($($_.CollectionResult.FilesCollected) files)" }) -join "`n")

Failed Collections:
------------------
$(($Results | Where-Object { -not $_.CollectionResult.Success } | ForEach-Object { "✗ $($_.Name)" }) -join "`n")

Collection Notes:
----------------
- Empty collections may indicate artifacts don't exist on this system
- Some artifacts may require elevated permissions to access
- Registry artifacts are exported as .reg files
- File system artifacts are copied preserving directory structure
- Running as $privilegeLevel provides access to system-level artifacts

Detailed Error Information:
--------------------------
$(($Results | Where-Object { $_.CollectionResult.Errors.Count -gt 0 } | ForEach-Object {
    "$($_.Name):"
    $_.CollectionResult.Errors | ForEach-Object { "  - $_" }
}) -join "`n")
"@

        # Write report files
        $reportFile = Join-Path $CollectionPath 'collection_report.txt'
        $reportContent | Out-File -FilePath $reportFile -Encoding UTF8

        # Create JSON report for programmatic analysis
        $jsonReport = [PSCustomObject]@{
            CollectionTime = Get-Date
            CollectionPath = $CollectionPath
            PrivilegeLevel = $privilegeLevel
            Statistics = [PSCustomObject]@{
                TotalArtifacts = $totalArtifacts
                SuccessfulCollections = $collectedArtifacts
                FailedCollections = $failedArtifacts
                TotalFiles = $totalFiles
                SuccessRate = [math]::Round(($collectedArtifacts / $totalArtifacts) * 100, 2)
            }
            Results = $Results
        }

        $jsonFile = Join-Path $CollectionPath 'collection_report.json'
        $jsonReport | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonFile -Encoding UTF8

        # Display summary
        Write-Information "`nForensic artifact collection completed!" -InformationAction Continue
        Write-Information "Collection Path: $CollectionPath" -InformationAction Continue
        Write-Information "Artifacts Processed: $totalArtifacts | Collected: $collectedArtifacts | Failed: $failedArtifacts" -InformationAction Continue
        Write-Information "Total Files Collected: $totalFiles" -InformationAction Continue
        Write-Information "Reports Generated: $reportFile, $jsonFile" -InformationAction Continue

        # Clean up empty directories
        Get-ChildItem -Path $CollectionPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $contents = Get-ChildItem -Path $_.FullName -Recurse -ErrorAction SilentlyContinue
            if (-not $contents) {
                Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Verbose "Removed empty collection directory: $($_.Name)"
            }
        }
    }
    catch {
        Write-Error "Failed to generate collection report: $($_.Exception.Message)"
    }
}
