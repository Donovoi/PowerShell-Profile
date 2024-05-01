function Get-FidoDownload {
  [CmdletBinding()]
  <#
Win: Specify Windows version (e.g. "Windows 10"). Abbreviated version should work as well (e.g -Win 10) as long as it is unique enough. If this option isn't specified, the most recent version of Windows is automatically selected. You can obtain a list of supported versions by specifying -Win List.
Rel: Specify Windows release (e.g. "21H1"). If this option isn't specified, the most recent release for the chosen version of Windows is automatically selected. You can also use -Rel Latest to force the most recent to be used. You can obtain a list of supported versions by specifying -Rel List.
Ed: Specify Windows edition (e.g. "Pro/Home"). Abbreviated editions should work as well (e.g -Ed Pro) as long as it is unique enough. If this option isn't specified, the most recent version of Windows is automatically selected. You can obtain a list of supported versions by specifying -Ed List.
Lang: Specify Windows language (e.g. "Arabic"). Abbreviated or part of a language (e.g. -Lang Int for English International) should work as long as it's unique enough. If this option isn't specified, the script attempts to select the same language as the system locale. You can obtain a list of supported languages by specifying -Lang List.
Arch: Specify Windows architecture (e.g. "x64"). If this option isn't specified, the script attempts to use the same architecture as the one from the current system.
GetUrl: By default, the script attempts to automatically launch the download. But when using the -GetUrl switch, the script only displays the download URL, which can then be piped into another command or into a file.
#>
  <#
.SYNOPSIS
Downloads a Windows ISO using the Fido script.

.DESCRIPTION
The Get-FidoDownload function downloads a Windows ISO using the Fido script. It allows you to specify the Windows version, release, edition, architecture, and language. You can also choose to only get the download URL without starting the download.

.PARAMETER WindowsVersion
Specifies the Windows version to download. If not specified, the default is '11'.

.PARAMETER Rel
Specifies the Windows release to download. If not specified, the default is 'latest'.

.PARAMETER Ed
Specifies the Windows edition to download. If not specified, the default is 'Pro'.

.PARAMETER Arch
Specifies the Windows architecture to download. If not specified, the default is 'x64'.

.PARAMETER GetUrl
If this switch is present, the function only displays the download URL without starting the download.

.PARAMETER LOCALE
Specifies the locale to use. If not specified, the default is 'en-US'.

.PARAMETER Language
Specifies the language to use. If not specified, the default is 'English'.

.EXAMPLE
Get-FidoDownload -WindowsVersion '10' -Rel '20H2' -Ed 'Home' -Arch 'x86' -GetUrl

This command gets the download URL for the Home edition of the Windows 10 20H2 release for the x86 architecture.

.INPUTS
None. You cannot pipe objects to Get-FidoDownload.

.OUTPUTS
System.String. Get-FidoDownload returns the download URL as a string if the -GetUrl switch is present.
#>
  param(
    [string]$WindowsVersion = '11',
    [string]$Rel = 'latest',
    [string]$Ed = 'Pro',
    [string]$Arch = 'x64',
    [switch]$GetUrl,
    [string]$LOCALE = 'en-US',
    [string]$Language = 'English'
  )
  try {
    $FidoURL = 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1'
    $FidoResponse = Invoke-WebRequest -Uri $FidoURL -UseBasicParsing -Verbose
    # convert script content to ascii
    $FidoResponse.Content | Out-File -FilePath 'Fido.ps1' -Encoding utf8 -Force
    # Fix weird encoding issue
    Get-Content -Path 'Fido.ps1' -Raw | Out-File -FilePath 'Fidodecoded.ps1' -Encoding Ascii -Force
    # execute the script
    $file = 'Fidodecoded.ps1'
    $Arguments = @{
      Win      = $WindowsVersion
      Rel      = $Rel
      Ed       = $Ed
      Arch     = $Arch
      GetUrl   = $GetUrl.IsPresent
      Locale   = $LOCALE
      Language = $Language
    }
    # Convert the hashtable to a list of arguments
    $ArgumentList = $Arguments.GetEnumerator() | ForEach-Object { "-$($_.Key)", $_.Value }

    # Add the necessary arguments for powershell.exe
    $ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file) + $ArgumentList

    # Start the process and capture the output
    $ProcessStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessStartInfo.FileName = 'powershell.exe'
    $ProcessStartInfo.Arguments = $ArgumentList -join ' '
    $ProcessStartInfo.RedirectStandardOutput = $true
    $ProcessStartInfo.UseShellExecute = $false
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $ProcessStartInfo
    $Process.Start() | Out-Null
    $Process.WaitForExit()

    # Return the output of the process
    return $Process.StandardOutput.ReadToEnd()
  }
  catch {
    Write-Error "Failed to download or execute the Fido script: $($_.Exception.Message)"
  }
}