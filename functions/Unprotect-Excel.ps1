<#
.SYNOPSIS
    Removes protection from Excel sheets in a given Excel file.

.DESCRIPTION
    The Unprotect-Excel function takes an Excel file path as input and removes protection from all sheets within the Excel workbook.
    It creates a backup of the original file. If the file appears to be encrypted with Microsoft MAM, it provides an assessment of its content.

.PARAMETER ExcelFilePath
    The path to the Excel file that needs to be unprotected.

.EXAMPLE
    Unprotect-Excel -ExcelFilePath "C:\path\to\your\file.xlsx"
    This example removes protection from the Excel sheets in 'file.xlsx'.

.NOTES
    Requires PowerShell 5.0 or higher due to the usage of certain advanced features like classes and compression.
    Includes functions for checking MAM encryption and calculating file entropy.

#>


function Unprotect-Excel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
        [string]$Excel
    )

    try {
        if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
            $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
            $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
            New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            Get-Module -Name 'InstallCmdlet'
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
            $encryption = Test-MAMEncryption -FilePath $excelBackup
            if ($encryption) {
                Write-Logg -message "Here's some more info:" -level info
                $entropy = Get-Entropy -FilePath $FilePath
                Write-Logg -Message "Entropy: $($entropy.Entropy)" -Level info
                Write-Logg -Message "Assessment: $($entropy.Assessment)" -Level info
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