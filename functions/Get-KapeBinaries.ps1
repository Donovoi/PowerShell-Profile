<#
.SYNOPSIS
Automates the downloading of binaries used by KAPE module files.

.DESCRIPTION
The `Get-KapeBinaries` function automates the process of downloading binaries used by KAPE module files. It provides options to specify the destination directory for the downloaded binaries, the path to the KAPE Modules directory, and various switches to control the behavior of the script.

.PARAMETER Dest
Specifies the destination directory where the binaries will be downloaded. The default value is "$ENV:USERPROFILE\kapeDownloadedBinaries".

.PARAMETER ModulePath
Specifies the path to the KAPE Modules directory. The default value is "$XWAYSUSB\Triage\Kape\Modules".

.PARAMETER CreateBinaryList
An optional switch that, when used, scans the mkape files and dumps the binary URLs found to the console.

.PARAMETER DownloadBinaries
An optional switch that, when used, enables the downloading of binaries after the list is created.

.PARAMETER UseBinaryList
An optional switch that, when used, enables the use of a text file to specify which binaries to download.

.PARAMETER BinaryListPath
Specifies the path of the text file containing the binary URLs. This parameter is required if the UseBinaryList switch is used.

.EXAMPLE
Get-KapeBinaries -Dest "C:\Downloads" -ModulePath "C:\Kape\Modules" -CreateBinaryList

This example downloads the binaries used by KAPE module files to the "C:\Downloads" directory, using the KAPE Modules directory located at "C:\Kape\Modules". It also scans the mkape files and dumps the binary URLs found to the console.

.EXAMPLE
Get-KapeBinaries -Dest "C:\Downloads" -ModulePath "C:\Kape\Modules" -UseBinaryList -BinaryListPath "C:\BinaryList.txt"

This example downloads the binaries specified in the "C:\BinaryList.txt" file to the "C:\Downloads" directory, using the KAPE Modules directory located at "C:\Kape\Modules".

.NOTES
This script requires the Write-Logg and Get-FileDownload functions to be available.

.LINK
Write-Logg: https://example.com/Write-Logg
Get-FileDownload: https://example.com/Get-FileDownload
#>


function Get-KapeBinaries {
  [CmdletBinding()]
  param
  (
    [Parameter()]
    [string]$Dest = "$ENV:USERPROFILE\kapeDownloadedBinaries", # Where to download binaries

    [Parameter()]
    [string]$ModulePath = '', # Path to Kape Modules directory

    [Parameter()]
    [switch]$CreateBinaryList, #Optional switch which scans mkape file and dumps binary urls found to console

    [Parameter()]
    [switch]$DownloadBinaries, # Optional switch to enable downloading of binaries after list is created

    [Parameter()]
    [switch]$UseBinaryList, # Optional switch to enable use of txt file to specify which binaries to download
    [string]$BinaryListPath # Path of txt file containing Binary URLs
  )

  # Import the required cmdlets
  $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties')
  $neededcmdlets | ForEach-Object {
    if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
      if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
        $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
        $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
        New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
      }
      Write-Verbose -Message "Importing cmdlet: $_"
      $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
      $Cmdletstoinvoke | Import-Module -Force
    }
  }

  $XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
  if ([string]::IsNullOrWhiteSpace($ModulePath)) {
    $ModulePath = $(Resolve-Path -Path "$XWAYSUSB\Triage\Kape\Modules").Path
  }
  Write-Logg -Message "This script will automate the downloading of binaries used by KAPE module files to $Dest"

  $newInstall = $false

  if (-not (Test-Path -Path $Dest)) {
    Write-Logg -Message "$Dest does not exist. Creating..." -level Warning
    New-Item -ItemType directory -Path $Dest -Force -ErrorAction SilentlyContinue
    $newInstall = $true
  }


  $WebKeyCollection = @()

  $localDetailsFile = Join-Path $Dest -ChildPath '!!!RemoteFileDetails.csv'

  if (Test-Path -Path $localDetailsFile) {
    Write-Logg -Message "Loading local details from '$Dest'..."
    $LocalKeyCollection = Import-Csv -Path $localDetailsFile
  }

  $toDownload = @()

  # Check if $UseBinaryList switch was used and import binary URLs
  if ($UseBinaryList) {
    try {
      $BinaryContent = Get-Content $BinaryListPath -ErrorAction Stop
    }
    catch {
      Write-Logg -Message "Unable to import list of Binary URLs. Verify file exists in $BinaryListPath or that you have access to this file"
    }

    
    $regex = [regex]'(?i)\b(http.)://[-A-Z0-9+&@#/%?=~_|$!:,.;]*[A-Z0-9+&@#/%=~_|$].(zip|txt|ps1|exe)'
    $matchdetails = $regex.Match($BinaryContent)
  }

  #If $CreateBinaryList switch is used dump list of Binary URLs to console
  elseif ($CreateBinaryList) {
    Write-Logg -Message 'Dumping list of Binary URLs to console'
    try {
      $mkapeFiles = Get-ChildItem -Recurse -Force -Path $modulePath\*.mkape -ErrorAction Stop
      $mkapeContent = $mkapeFiles | Get-Content
    }
    catch {
      Write-Logg -Message 'Unable to import list of Binary URLs. Verify path to modules folder is correct or that you have access to this directory'
    }

    # $UniqueURLs = @{}
    
    $mkapeContent.ForEach{
      $regex = [regex]'(?i)\b(http.):\/\/[-A-Z0-9+&@#\/%?=~_|$!:,.;]*[A-Z0-9+&@#\/%=~_|$]\.(zip|txt|ps1|exe)'
      if ($regex.IsMatch($_)) {
        $matchdetails = $regex.Match($_)
        $UniqueURLs += [System.Collections.Generic.HashSet[string]]::new([string[]]($_), [System.StringComparer]::Ordinal)
      }
    }
    $FinalUrls = $UniqueURLs | Sort-Object -Unique
    # $hashString | Out-File -FilePath $FinalFilePath -Encoding Ascii -Force


    Write-Output $FinalUrls

    if ($DownloadBinaries) {
      $FinalUrls.foreach{
        $DownloadedBinaries = $(Join-Path -Path $Dest -ChildPath "$($_.split('/')[-1])")
        if (Test-Path -Path $DownloadedBinaries) {
          Remove-Item -Path $DownloadedBinaries -Force -ErrorAction SilentlyContinue
        }
        Get-FileDownload -Url "$_" -DestinationDirectory $(Split-Path $DownloadedBinaries -Parent) -UseAria2
      }

    }

  }
  # If $UseBinaryList switch wasn't used, scan mkape files for binary URLs and download
  else {
    
    try {
      $matchdetails = [System.Collections.Generic.List[string]]::new()
      $kapefiles = Get-ChildItem -Recurse -Force -Path "$modulePath" -Include '*.mkape'
    
      $kapefiles | ForEach-Object {
        $mkapeContent = Get-Content -Path $_ -ReadCount 0
        $regex = [regex]'(?i)\b(http.)://[-A-Z0-9+&@#/%?=~_|$!:,.;]*[A-Z0-9+&@#/%=~_|$].(zip|txt|ps1|exe)'
        $matchdetails += $regex.Match($mkapeContent).Value
      }
    }
    catch {
      Write-Logg -Message 'Unable to import list of Binary URLs. Verify path to modules folder is correct or that you have access to this directory'
    }
  }

  Write-Logg -Message 'Getting available programs...'
  # clean up matchdetails by removing duplicates and removing any empty entries
  $matchdetails = $matchdetails | Where-Object { $_ -ne '' } | Sort-Object -Unique
  if ($matchdetails.Length -gt 0) {
    
    $matchdetails | ForEach-Object {
      $headers = Invoke-WebRequest -Uri $_ -UseBasicParsing -Method Head -ErrorAction SilentlyContinue -SkipHttpErrorCheck

      # Checking to verify data was returned before updating $headers variable
      if ($null -ne $headers) {
        $headers = $headers.headers
      }
      else {
        $headers = @{}
        $headers. 'x-bz-content-sha1' = 'n/a'
        $headers. 'Content-Length' = 'n/a'
        $headers. 'x-bz-file-name' = $_ | Split-Path -Leaf
      }

      # Eric's tools have the hash available in the header so we can check these to see if we have the current version already
      if ($_ -like '*EricZimmermanTools*') {
        $getUrl = $_
        $sha = $headers['x-bz-content-sha1']
        $name = $headers['x-bz-file-name']
        $size = $headers['Content-Length']

        $details = @{
          Name = $name
          SHA1 = $sha
          URL  = $getUrl
          Size = $size
        }
      }
      # Downloading
      else {
        $getUrl = $_
        $sha = 'N/A'
        $name = $_ | Split-Path -Leaf
        $size = $headers['Content-Length']


        $details = @{
          Name = $name
          SHA1 = $sha
          URL  = $getUrl
          Size = $size
        }
      }
      # create a new object with the details, add to the existing one if it already exists
      if ($null -ne $webKeyCollection) {
        $webKeyCollection += New-Object PSObject -Property $details
      }
      else {
        $webKeyCollection = @()
        $webKeyCollection += New-Object PSObject -Property $details
      }

      foreach ($webKey in $webKeyCollection) {
        if ($newInstall) {
          $toDownload += $webKey
          continue
        }

        $localFile = $LocalKeyCollection | Where-Object { $_.Name -eq $webKey.Name }

        if ($null -eq $localFile -or $localFile.SHA1 -ne $webKey.SHA1 -or $localFile.SHA1 -eq 'N/A') {
          #Needs to be downloaded since file doesn't exist, SHA is different, or SHA is not in header to compare
          $toDownload += $webKey
        }
      }

      if ($toDownload.Count -eq 0) {
        Write-Logg -Message 'All files current. Exiting.'
        return
      }
    }


    #if (-not (test-path ".\7z\7za.exe"))
    #{
    #    Write-Logg -Message ".\7z\7za.exe needed! Exiting"
    #    return
    #}
    #set-alias sz ".\7z\7za.exe"

    $downloadedOK = @()

    foreach ($td in $toDownload) {
      try {
        $dUrl = $td.URL
        $size = $td.Size
        $name = $td.Name
        Write-Logg -Message "Downloading $name (Size: $size)"
        $destFile = Join-Path -Path $dest -ChildPath $td.Name

        try {
          Invoke-WebRequest -Uri $dUrl -OutFile $destFile -ErrorAction Stop -UseBasicParsing
        }
        catch {
          $ErrorMessage = $_.Exception.Message
          Write-Logg -Message "Error downloading $name : ($ErrorMessage). Verify Binary URL is correct and try again"
          continue
        }

        $downloadedOK += $td

        if ($name.endswith('zip')) {
          # Test for Archiving cmdlets and if installed, use instead of 7zip
          if (!(Get-Command Expand-Archive -ErrorAction SilentlyContinue)) {

            # Archiving cmdlets not found, use 7zip
            try {
              sz x $destFile -o"$Dest" -y > $null
            }
            catch {
              $ErrorMessage = $_.Exception.Message
              Write-Logg -Message "Error extracting ZIP $name - ($ErrorMessage)."
            }
          }
          # Archiving cmdlets found so 7zip will not be used
          else {
            $global:progressPreference = 'silentlyContinue'
            try {
              Expand-Archive -Path $destFile -DestinationPath $Dest -Force -ErrorAction Stop
            }
            catch {
              Write-Logg -Message "Unable to extract file:$destFile. Verify file is not in use and that you have access to $Dest."
            }
          }
        }
      }
      catch {
        $ErrorMessage = $_.Exception.Message
        Write-Logg -Message "Error downloading $name : ($ErrorMessage). Verify Binary URL is correct and try again"
      }
      finally {
      
        if ($null -ne $name) {
          if ($name.endswith('zip')) {
            try {
              Remove-Item -Path $destFile -ErrorAction SilentlyContinue
            }
            catch {
              Write-Logg -Message "Unable to remove item: $destFile"
            }
          }
        }

      }
    }

    #Downloaded ok contains new stuff, but we need to account for existing stuff too
    foreach ($webItems in $webKeyCollection) {
      #Check what we have locally to see if it also contains what is in the web collection
      $localFile = $LocalKeyCollection | Where-Object { $_.SHA1 -eq $webItems.SHA1 }

      #if its not null, we have a local file match against what is on the website, so its ok

      if ($null -ne $localFile) {
        #consider it downloaded since SHAs match
        $downloadedOK += $webItems
      }
    }

    # Doing some cleanup to remove files not needed by KAPE and reorganize directory names and structure in line with modules

    # EvtxECmd Directory rename

    # Check to make sure \EvtxExplorer is in $dest before doing anything
    if (Test-Path "$Dest\EvtxExplorer") {
      # Rename EvtxExplorer directory to EvtxECmd to match path in EvtxECmd.mkape
      try {
        Rename-Item -Path "$Dest\EvtxExplorer" -NewName "$Dest\EvtxECmd" -Force -ErrorAction Stop
      }
      catch {
        Write-Logg -Message "Unable to rename $Dest\EvtxExplorer to $Dest\EvtxECmd. Directory may need to be manually renamed for EvtxECmd.mkape to function properly"
      }
    }

    # Registry Explorer Cleanup and Reorg

    # Check to make sure \RegistryExplorer is in $dest before doing anything
    if (Test-Path "$Dest\RegistryExplorer") {
      $reCmdDir = "$dest\ReCmd"
      if (!(Test-Path -Path $ReCmdDir)) {
        try {
          New-Item -ItemType directory -Path $ReCmdDir -ErrorAction Stop > $null
        }
        catch {
          Write-Logg -Message "Unable to create directory path: $RECmdDir. You may need to manually create \Kape\Modules\Bin\ReCmd"
        }
      }

      $reCmdChanges = @("$Dest\RegistryExplorer\ReCmd.exe", "$Dest\RegistryExplorer\BatchExamples\*.reb", "$Dest\RegistryExplorer\Plugins")

      foreach ($change in $reCmdChanges) {
        try {
          Move-Item -Path $change -Destination $ReCmdDir -Force -ErrorAction Stop
        }
        catch {
          Write-Logg -Message "Unable to move $change to $RECmdDir. You may need to manually move this for RECmd.mkape to function properly"
        }
      }

      # Delete RegistryExplorer Directory
      try {
        Remove-Item -Path "$Dest\RegistryExplorer" -Recurse -Force -ErrorAction Stop
      }
      catch {
        Write-Logg -Message "Unable to delete $Dest\RegistryExplorer"
      }
    }

    # Additonal cleanup of tools that must reside directly in \Kape\Modules\Bin
    $toolPath = @("$Dest\ShellBagsExplorer\SBECmd.exe", "$Dest\win64\densityscout.exe", "$Dest\sqlite-tools-win32-x86-3270200\*.exe")
    foreach ($tool in $toolPath) {

      # Check to make sure each $tool is in $dest before doing anything
      if (Test-Path $tool) {
        try {
          Move-Item -Path $tool -Destination $Dest -Force -ErrorAction Stop
        }
        catch {
          Write-Logg -Message "Unable to move $tool to $Dest. You may need to manually move this for the module to function properly"
        }

        # Delete Tool Directory
        try {
          $toolDir = $tool | Split-Path -Parent
          Remove-Item -Path $toolDir -Recurse -Force -ErrorAction Stop
        }
        catch {
          Write-Logg -Message "Unable to delete $toolDir"
        }
      }
    }

    Write-Logg -Message "Saving downloaded version information to $localDetailsFile"
    $downloadedOK | Export-Csv -Path $localDetailsFile
  }
}