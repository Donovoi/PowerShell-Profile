# Helper function to parse Google Drive confirmation page
function Get-FormDataFromGDriveConfirmation {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Contents
    )

    Write-Verbose 'Parsing Google Drive confirmation page...'

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