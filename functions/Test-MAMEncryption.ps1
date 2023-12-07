<#
.SYNOPSIS
    Tests if a file is encrypted by Microsoft Intune Mobile Application Management (MAM).

.DESCRIPTION
    The Test-MAMEncryption function checks the specified file to determine if it has been encrypted using Microsoft Intune MAM encryption for Microsoft 365 apps for enterprise. It reads the first 10 lines of the file and searches for a signature pattern that indicates MAM encryption.

.PARAMETER FilePath
    The path to the file that needs to be checked for MAM encryption. This parameter is mandatory.

.PARAMETER signaturePattern
    An optional signature pattern string used to detect MAM encryption in the file's header. If not provided, the default value 'MSMAMARPCRYPT' is used.

.EXAMPLE
    Test-MAMEncryption -FilePath "C:\example\document.docx"

    Checks if the document at the specified path is encrypted by MAM.

.EXAMPLE
    Test-MAMEncryption -FilePath "C:\example\spreadsheet.xlsx" -signaturePattern "CUSTOMPATTERN"

    Checks if the spreadsheet at the specified path is encrypted by MAM using a custom signature pattern.

.OUTPUTS
    System.Boolean
    Returns $true if the file is encrypted by MAM, otherwise returns $false.

.NOTES
    Make sure that the function Write-Logg is defined in your script or module, as this function relies on it to log messages.

.LINK
    https://docs.microsoft.com/en-us/mem/intune/developer/app-sdk

#>
function Test-MAMEncryption {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        # Header from Microsoft Intune Encryption Mobile Application Management (MAM) for Microsoft 365 apps for enterprise
        [Parameter(Mandatory = $false)]
        [string]$signaturePattern = 'MSMAMARPCRYPT'
    )

    try {
        # Read the first 10 lines of the file
        $lines = Get-Content -Path $FilePath -TotalCount 10

        # Check if any of the lines match the signature pattern
        $isEncrypted = $lines -match $signaturePattern

        if ($isEncrypted) {
            Write-Logg -Message 'It appears the file is encrypted by MAM.' -Level Error
            return $true
        }
        else {
            Write-Logg -message 'The file is not encrypted by MAM.' -level error
            return $false
        }
    }
    catch {
        throw $_.Exception.Message
    }
}
