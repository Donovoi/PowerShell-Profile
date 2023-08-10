function Get-Fido {
  [CmdletBinding()]
  param()

  try {
    # Use Invoke-WebRequest to download the script
    $ZippedScriptContent = Get-latestGithubRelease -OwnerRepository pbatard/Fido -AssetName 'Fido.ps1.lzma' -ExtractZip -UseAria2
    
    #  Extract the zip using .net static method
    if (-not(Get-Command 'Expand-7Zip' -ErrorAction SilentlyContinue)) {
      Install-ExternalDependencies
    }
    $scriptContent = Expand-7Zip -InputObject $ZippedScriptContent -OutputPath $env:TEMP -PassThru | Select-Object -ExpandProperty 'FullName'

    # Convert the script content to bytes using the UTF-8 encoding
    $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($scriptContent)
    
    # Use the default encoding on your machine
    $scriptBytesDefaultEncoding = [System.Text.Encoding]::Convert([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Default, $scriptBytes)    
    # Execute the script
    $FidoPath = [System.Text.Encoding]::Default.GetString($scriptBytesDefaultEncoding) | Out-File -Encoding ascii -FilePath $env:TEMP\Fido.ps1 -Force
    . $FidoPath
  }
  catch {
    Write-Error "Failed to download or execute the Fido script: $($_.Exception.Message)"
  }
}
