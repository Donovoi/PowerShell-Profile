function Get-Fido {
  [CmdletBinding()]
  param()

  $scriptUrl = 'https://github.com/pbatard/Fido/releases/download/v1.50/Fido.ps1.lzma'

  try {
    # Use Invoke-WebRequest to download the script
    $scriptContent = Get-latestGithubRelease
    
    # Convert the script content to bytes using the UTF-8 encoding
    $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($scriptContent)
    
    # Use the default encoding on your machine
    $scriptBytesDefaultEncoding = [System.Text.Encoding]::Convert([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Default, $scriptBytes)
    
    # Unpack the LZMA file (assuming you have the SevenZipSharp library installed)
    Add-Type -Path 'C:\Path\To\SevenZipSharp.dll'
    $sevenZip = New-Object SevenZip.SevenZipExtractor('C:\Path\To\LzmaFile.lzma')
    $sevenZip.ExtractArchive('C:\Path\To\OutputDirectory')
    
    # Execute the script
    Invoke-Expression -Command ([System.Text.Encoding]::Default.GetString($scriptBytesDefaultEncoding))
  }
  catch {
    Write-Error "Failed to download or execute the Fido script: $($_.Exception.Message)"
  }
}
