<#
.SYNOPSIS
    Removes protection from Excel sheets in a given Excel file.

.DESCRIPTION
    The Unprotect-ExcelSheet function takes an Excel file path as input and removes protection from all sheets within the Excel workbook.
    It creates a backup of the original file and saves the unprotected version as a new file.

.PARAMETER Excel
    The path to the Excel file that needs to be unprotected.

.EXAMPLE
    Unprotect-ExcelSheet -Excel "C:\path\to\your\file.xlsx"
    This example removes protection from the Excel sheets in 'file.xlsx'.

.NOTES
    Requires PowerShell 5.0 or higher due to the usage of certain advanced features like classes and compression.

.LINK
    [Insert relevant link or documentation]

#>

function Unprotect-Excel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
        [string]$Excel
    )

    try {
        if (-not (Get-Command -Name 'Write-Logg' -ErrorAction SilentlyContinue)) {
            function Write-Logg {
                # Define a unique name for the dynamic module
                $dynModName = 'DynamicLoggingModule'

                # Check if the module is already loaded
                if (-not (Get-Module -Name $dynModName -ErrorAction SilentlyContinue)) {
                    # URL of the PowerShell script to import
                    $uri = 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Write-Logg.ps1'

                    # Create a new PowerShell module from the content obtained from the URI
                    # 'Invoke-RestMethod' is used to download the script content
                    # The script content is encapsulated in a script block, and a new module is created from it
                    # 'Export-ModuleMember' exports all functions and aliases from the module
                    $script:dynMod = New-Module -Name $dynModName ([scriptblock]::Create(
                        ((Invoke-RestMethod $uri)) + "`nExport-ModuleMember -Function * -Alias *"
                        )) | Import-Module -PassThru
                }
                else {
                    # Get the already loaded module
                    $script:dynMod = Get-Module -Name $dynModName
                }

                # Check if this function ('Write-Logg') is shadowing the function from the imported module
                # If it is, remove this function so that the newly imported function can be used
                $myName = $MyInvocation.MyCommand.Name
                if ((Get-Command -Type Function $myName).ModuleName -ne $dynMod.Name) {
                    Remove-Item -LiteralPath "function:$myName"
                }

                # Invoke the newly defined or already existing function with the same name ('Write-Logg')
                # Pass all arguments received by this stub function to the imported function
                & $myName @args

            }
        }
        # Define paths for temporary and backup files
        $excelFilePath = Split-Path -Path $Excel
        $excelName = Split-Path -Path $Excel -Leaf
        $excelTempDir = Join-Path -Path $excelFilePath -ChildPath "${excelName}_temp"
        $excelFileSaved = Join-Path -Path $excelFilePath -ChildPath "${excelName}_unprotected.xlsx"
        $excelBackup = Join-Path -Path $excelFilePath -ChildPath "${excelName}_backup.xlsx.zip"

        # Create a backup of the original Excel file
        Copy-Item -Path $Excel -Destination $excelBackup -Force

        # Remove existing temporary and saved files if they exist
        Remove-Item -Path $excelTempDir, $excelFileSaved -Force -Recurse -ErrorAction SilentlyContinue


        try {
            Expand-Archive -Path $excelBackup -DestinationPath $excelTempDir -Force
        }
        catch {
            # Show the magic bytes using the Write-Logg function
            Write-Logg -Message 'Error extracting file:' -Level Error
            Write-Logg -Message $_.Exception.Message -Level Error

            # Calculate encrypion and entropy and let the user know
            $encryption = Test-MAMEncryption -FilePath $excelBackup -TestEntropy
            if ($encryption) {
                write-logg -message $encryption[1] -level error
            }
            throw $_
        }


        # Process each sheet in the workbook
        $sheets = Get-ChildItem -Path "$excelTempDir\xl\worksheets" -Filter *.xml
        foreach ($sheet in $sheets) {
            $doc = ([xml](Get-Content -Path $sheet.FullName -Force))

            # Dynamically extract the namespace URI from the XML document
            $nsUri = $doc.DocumentElement.NamespaceURI

            # Create a hashtable for the namespace using the extracted URI
            $ns = @{ x = $nsUri }

            # Remove sheet protection nodes using the namespace
            $nodesToRemove = Select-Xml -Xml $doc -XPath '//x:sheetProtection' -Namespace $ns | Select-Object -ExpandProperty Node
            foreach ($node in $nodesToRemove) {
                $node.ParentNode.RemoveChild($node)
            }

            # Save the modified XML back to the file
            $doc.Save($sheet.FullName)
        }

        # Re-create the Excel file from the modified XML files
        Compress-Archive -Path "$excelTempDir\*" -DestinationPath $excelFileSaved -Force

        # Output success message
        Write-Logg -Message 'Success: Excel sheet protection removed.' -Level info
    }
    catch {
        # Log and rethrow any other errors
        Write-Logg -Message "Failed: $_.Exception.Message" -Level error
        throw $_.Exception.Message
    }
    finally {
        # Ensure cleanup of the temporary directory in case of failure
        if (Test-Path -Path $excelTempDir) {
            Remove-Item -Path $excelTempDir -Force -Recurse
        }
        # Before exiting, remove (unload) the dynamic module.
        $dynMod | Remove-Module
    }
}

function Test-MAMEncryption {
    [CmdletBinding()]
    [OutputType([bool, string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        # header from microsoft intune encryption mobile application management (MAM) for microsoft 365 apps for enterprise
        [Parameter(Mandatory = $false)]
        [string]$signaturePattern = 'MSMAMARPCRYPT',
        [Parameter(Mandatory = $false)]
        [switch]$TestEntropy

    )

    try {
        # Read the first 10 lines of the file
        $lines = Get-Content -Path $FilePath -TotalCount 10

        # Check if any of the lines match the signature pattern
        $isEncrypted = $lines -match $signaturePattern

        if ($isEncrypted) {
            Write-Logg -Message 'It appears file is encrypted by MDM.' -Level Error

            # show entropy
            if ($TestEntropy) {
                Write-Logg -message "Here's some more info:" -level info
                $entropy = Get-EntropyAndAssessment -FilePath $FilePath
                Write-Logg -Message "Entropy: $($entropy.Entropy)" -Level info
                Write-Logg -Message "Assessment: $($entropy.Assessment)" -Level info
            }
            return $true
        }
        else {
            Write-Logg -message 'The file is not encrypted by MDM.' -level error
            return $false
        }
    }
    catch {
        throw $_.Exception.Message
    }
}

function Get-EntropyAndAssessment {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    try {
        # Read all bytes from the file
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)

        # Get the frequency of each byte
        $frequencyTable = @{}
        foreach ($byte in $bytes) {
            if (!$frequencyTable.ContainsKey($byte)) {
                $frequencyTable[$byte] = 0
            }
            $frequencyTable[$byte]++
        }

        # Calculate the entropy
        $entropy = 0.0
        $totalBytes = $bytes.Length
        foreach ($byte in $frequencyTable.Keys) {
            $probability = $frequencyTable[$byte] / $totalBytes
            $entropy -= $probability * [Math]::Log($probability, 2)
        }

        # Assess the entropy value
        $assessment = ''
        if ($entropy -lt 3) {
            $assessment = 'Low entropy. Likely plain text or structured data.'
        }
        elseif ($entropy -ge 3 -and $entropy -lt 5) {
            $assessment = 'Moderate entropy. Could be natural language or mixed content.'
        }
        elseif ($entropy -ge 5) {
            $assessment = 'High entropy. Likely encrypted or compressed data.'
        }

        # Return the entropy value and assessment
        return @{
            Entropy    = $entropy
            Assessment = $assessment
        }
    }
    catch {
        throw $_.Exception.Message
    }
}


