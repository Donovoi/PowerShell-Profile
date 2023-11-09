Function Start-BurpSuite {
    <#
    .SYNOPSIS
        Launches Burp Suite with specific memory allocation and project file settings.
    
    .DESCRIPTION
        This function calculates 80% of the available RAM to allocate to the JVM and launches Burp Suite with administrative privileges using a project file with a unique timestamp name.
    
    .PARAMETER BurpSuiteJarPath
        The file path to the Burp Suite JAR file.
    
    .EXAMPLE
        Start-BurpSuite -BurpSuiteJarPath "C:\path\to\burpsuite.jar"
    
    .INPUTS
        None
    
    .OUTPUTS
        None
    
    .NOTES
        Version:        1.0
        Author:         ChatGPT
        Creation Date:  2023-11-09
        Purpose/Change: Initial function development without Java version check.
    #>
    
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [string]$BurpSuiteJarPath
    )
    
    Process {
        try {
            # Calculate 80% of available RAM in KB
            $memInfo = Get-CimInstance -ClassName Win32_OperatingSystem
            $availableRAM = $memInfo.FreePhysicalMemory # FreePhysicalMemory is in KB
            $eightyPercentRAM = [Math]::Round($availableRAM * 0.8)
    
            # Generate a timestamp for the project file name
            $timestamp = Get-Date -Format "yyyy-MM-dd - HH-mm-ss"
            $projectFile = "$timestamp Project.burp"
            $projectFilePath = Join-Path -Path (Split-Path -Parent $BurpSuiteJarPath) -ChildPath $projectFile
    
            # Start Burp Suite with elevated privileges
            Start-Process "java" -ArgumentList "-Xmx${eightyPercentRAM}k -jar '$BurpSuiteJarPath' --project-file='$projectFilePath'" -Verb RunAs
            Write-Host "Burp Suite launched successfully with project file: $projectFilePath"
        }
        catch {
            Write-Error "Error launching Burp Suite: $_"
        }
    }
}
# Import-Module .\Microsoft.PowerShell_profile.ps1
# Start-BurpSuite -BurpSuiteJarPath "$xwaysusb\chocolatey apps\chocolatey\bin\burpsuite.jar"