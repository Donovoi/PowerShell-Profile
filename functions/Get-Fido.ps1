function Get-Fido {
  [CmdletBinding()]
  param()

  try {

    # Use Invoke-WebRequest to download the script
    $ZippedScriptPath = Get-latestGithubRelease -OwnerRepository pbatard/Fido -AssetName 'Fido.ps1.lzma' -UseAria2

    #  Extract the zip using .net static method
    if (-not(Get-Command 'Expand-7Zip' -ErrorAction SilentlyContinue)) {
    Install-ExternalDependencies -PSModule 7zip4powershell
    }
    $ScriptPath = Expand-7Zip -ArchiveFileName $ZippedScriptPath -TargetPath $env:TEMP

    # Convert the script content to bytes using the UTF-8 encoding
    $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($ScriptPath.FullName)

    # Use the default encoding on your machine
    $scriptBytesDefaultEncoding = [System.Text.Encoding]::Convert([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Default, $scriptBytes)
    # Execute the script
    $FidoPath = [System.Text.Encoding]::Default.GetString($scriptBytesDefaultEncoding) | Out-File -Encoding ascii -FilePath $env:TEMP\Fido.ps1 -Force
    Get-Item $FidoPath | Invoke-Expression
  }
  catch {
    Write-Error "Failed to download or execute the Fido script: $($_.Exception.Message)"
  }
}