# Helper function to parse Google Drive confirmation page
function Get-FormDataFromGDriveConfirmation {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Contents
    )

    Write-Verbose 'Parsing Google Drive confirmation page...'
    # Import needed cmdlets if not already available
    $neededcmdlets = @(
        'Install-Dependencies'                  # Installs required dependencies
        'Get-FinalOutputPath'                   # Determines final output path for downloaded files
        'Add-NuGetDependencies'                 # Adds NuGet package dependencies
        'Invoke-AriaDownload'                   # Alternative download method for large files
        'Get-FileDetailsFromResponse'           # Extracts file details from web response
        'Save-BinaryContent'                    # Saves binary content to disk
        'Add-FileToAppDomain'
        'Write-Logg'
    )
    foreach ($cmd in $neededcmdlets) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose "Importing cmdlet: $cmd"
            $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $cmd
            $Cmdletstoinvoke | Import-Module -Force
        }
    }

    Install-Dependencies -NugetPackage @{'HtmlAgilityPack' = '1.12.0' } -AddCustomAssemblies @('System.Web')

    # Create and load the HTML document
    $doc = New-Object HtmlAgilityPack.HtmlDocument
    $doc.LoadHtml($Contents)

    # Look for a form with id 'download-form'
    $form = $doc.DocumentNode.SelectSingleNode("//*[@id='download-form']")
    if ($form) {
        Write-Verbose 'Found download form in the page.'
        $formAction = $form.GetAttributeValue('action', '')

        # Fix: Check if the action is already a complete URL
        if (-not ($formAction -match '^https?://')) {
            $formAction = 'https://docs.google.com' + $formAction
        }

        # Extract all form fields
        $formData = @{}
        $inputNodes = $form.SelectNodes('.//input')
        if ($inputNodes) {
            foreach ($inputField in $inputNodes) {
                $name = $inputField.GetAttributeValue('name', '')
                if ($name) {
                    $value = $inputField.GetAttributeValue('value', '')
                    $formData[$name] = $value
                    Write-Verbose "Form field: $name = $value"
                }
            }
        }

        return @{
            FormAction = $formAction
            FormData   = $formData
        }
    }

    # If no form found, check for direct download link
    $aNode = $doc.DocumentNode.SelectSingleNode("//a[contains(@href, '/uc?export=download')]")
    if ($aNode) {
        Write-Verbose 'Found direct download link.'
        $href = $aNode.GetAttributeValue('href', '')
        $url = 'https://docs.google.com' + $href
        $url = $url -replace '&amp;', '&'
        return @{
            DirectUrl = $url
        }
    }

    # Check for a JSON-like "downloadUrl" key in the raw content
    if ($Contents -match '"downloadUrl":"([^"]+)"') {
        Write-Verbose 'Found downloadUrl in JSON content.'
        $url = $matches[1]
        $url = $url -replace '\\u003d', '=' -replace '\\u0026', '&'
        return @{
            DirectUrl = $url
        }
    }

    # Look for an error message in a <p> with class "uc-error-subcaption"
    $errorNode = $doc.DocumentNode.SelectSingleNode("//p[contains(@class, 'uc-error-subcaption')]")
    if ($errorNode) {
        $errorMessage = $errorNode.InnerText.Trim()
        throw "FileURLRetrievalError: $errorMessage"
    }

    throw "Cannot retrieve the download information. You may need to change the permission to 'Anyone with the link', or have had many accesses. Check FAQ at https://github.com/wkentaro/gdown?tab=readme-ov-file#faq."
}