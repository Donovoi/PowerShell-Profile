function Get-TopModulesByDownloadCount {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ModuleName
    )

    # Use Find-Module to search for the module
    $modules = Find-Module -Name $ModuleName

    # Create an empty array to hold the module info
    $moduleInfo = @()

    foreach ($module in $modules) {
        # Construct the URL for the module's page on the PowerShell Gallery
        $url = "https://www.powershellgallery.com/packages/$($module.Name)"

        try {
            # Download the HTML of the page
            $html = Invoke-WebRequest -Uri $url

            # Parse the download count from the HTML using regex
            $downloadCountPattern = '<li class="package-details-info-main">\s*(\d+[\d,]*)\s*<br>\s*<text class="text-sideColumn">\s*Downloads\s*</text>\s*</li>'
            $downloadCount = ""

            # Check if the HTML content matches the pattern
            if ($html -contains $downloadCountPattern) {
                $downloadCount = $Matches[0] -replace ',', ''
            }

            # Add the module info to the array
            $moduleInfo += New-Object PSObject -Property @{
                Name = $module.Name
                DownloadCount = [int]$downloadCount
            }
        }
        catch {
            Write-Warning "An error occurred while processing module '$($module.Name)': $_"
        }
    }

    # Sort the modules by download count in descending order and select the top 10
    $topModules = $moduleInfo | Sort-Object -Property DownloadCount -Descending | Select-Object -First 10

    # Return the top modules
    return $topModules
}