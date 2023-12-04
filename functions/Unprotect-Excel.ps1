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

function Unprotect-ExcelSheet {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
        [string]$Excel
    )

    try {
        if (-not (Get-Command -Name 'Write-Logg' -ErrorAction SilentlyContinue)) {
            function Write-Logg {
                $uri = 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Write-Logg.ps1'
                # Save the module in a script-level variable, and pipe it to Import-Module
                # so that it can be removed before the script exits.
                $script:dynMod = New-Module ([scriptblock]::Create(
                  ((Invoke-RestMethod $uri)) + "`nExport-ModuleMember -Function * -Alias *")
                ) | Import-Module -PassThru
                # If this stub function shadows the newly defined function in the dynamic
                # module, remove it first, so that re-invocation by name use the new function.
                # Note: This happens if this stub function is run in a child scope, such as
                #       in a (non-dot-sourced) script rather than in the global scope.
                #       If run in the global scope, curiously, the stub function seemingly
                #       disappears from view right away - not even Get-Command -All shows it later.
                $myName = $MyInvocation.MyCommand.Name
                if ((Get-Command -Type Function $myName).ModuleName -ne $dynMod.Name) {
                    Remove-Item -LiteralPath "function:$myName"
                }
                # Now invoke the newly defined function of the same name, passing the arguments
                # through.
                & $myName @args
            }
        }
        # Define paths for temporary and backup files
        $excelFilePath = Split-Path -Path $Excel
        $excelName = Split-Path -Path $Excel -Leaf
        $excelTempDir = Join-Path -Path $excelFilePath -ChildPath "${excelName}_temp"
        $excelFileSaved = Join-Path -Path $excelFilePath -ChildPath "${excelName}_unprotected.xlsx"
        $excelBackup = Join-Path -Path $excelFilePath -ChildPath "${excelName}_backup.xlsx"

        # Create a backup of the original Excel file
        Copy-Item -Path $Excel -Destination $excelBackup -Force

        # Remove existing temporary and saved files if they exist
        Remove-Item -Path $excelTempDir, $excelFileSaved -Force -Recurse -ErrorAction SilentlyContinue

        # Add necessary assembly for compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        # Extract the Excel file (which is a ZIP archive)
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Excel, $excelTempDir)

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
        [System.IO.Compression.ZipFile]::CreateFromDirectory($excelTempDir, $excelFileSaved)

        # Output success message
        Write-Logg -Message 'Success: Excel sheet protection removed.' -Level info
    }
    catch {
        # Output failure message and rethrow the exception
        Write-Logg -Message 'Failed: An error occurred.' -Level error
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



