<#
.SYNOPSIS
    This is a PowerShell Cmdlet that uses voidtools' Everything to get a list of all files in a folder and its subfolders.
.DESCRIPTION
    Either given a directory, or given a query using Everything syntax, this function will return a list of all files in a folder and its subfolders.
.NOTES
    Information or caveats about the function e.g. 'This function is not supported in Linux'
.LINK
    Specify a URI to a help page, this will show when Get-Help -Online is used.
.EXAMPLE
    Test-MyTestFunction
    Explanation of the function or its result. You can include multiple examples with additional .EXAMPLE lines
#>



# function Get-Everything {
#   [CmdletBinding()]
#   param(
#     # Everything executable path
#     [Parameter(Mandatory = $false)]
#     [string]
#     $EverythingPortable,
#     [Parameter(Mandatory = $false)]
#     [string]
#     $EverythingDirectory = $PWD,
#     [Parameter(Mandatory = $false)]
#     [string]
#     $SearchTerm = '*',
#     [Parameter(Mandatory = $false)]
#     [string[]]
#     $Volume = (Get-Volume).DriveLetter,
#     [Parameter(Mandatory = $false)]
#     [switch]
#     $EverythingHome
#   )

#   begin {
#     if ($EverythingHome) {
#       & $EverythingEXE '-home'
#     }
#     # we need to check if the Everything executable is present
#     if (-not (Test-Path $EverythingEXE -ErrorAction SilentlyContinue)) {
#       Write-Logg -Message 'Everything executable not found' -Level Info
#       Write-Logg -Message 'Downloading Everything' -Level Info



#       # Download Everything
#       $everythingclizip = Get-FileDownload -URL 'https://www.voidtools.com/ES-1.1.0.26.zip' -OutFileDirectory $EverythingDirectory -UseAria2
#       $everythingPortablezip = Get-FileDownload -Url 'https://www.voidtools.com/Everything-1.5.0.1361a.x64.zip' -OutFileDirectory $EverythingDirectory -UseAria2
#       $Zipstoexpand = @($everythingclizip, $everythingPortablezip)
#       $Zipstoexpand.ForEach{ Expand-Archive -Path $_ -DestinationPath $EverythingDirectory -Force }
#       $EverythingCLI = Get-ChildItem -Path $EverythingDirectory -Filter 'es.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
#       $EverythingPortable = Get-ChildItem -Path $EverythingDirectory -Filter 'Everything*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
#       try {


#         # We will now start everything portable with the right arguments/needs to be as forensically sound as possible:
#         # Get a list of all volumes
#         $AllVolumesExceptScriptVolume = $Volume.Where{ $_ -ne $PWD.Drive.Name }
#         # create a string for the command line arguments
#         $createUSNJounal = @{}
#         $maxusnjournalsizebytes = 1GB
#         $AllVolumesExceptScriptVolume.ForEach{ $createUSNJounal.Add('-create-usn-journal', $_, $maxusnjournalsizebytes ) }

#         # create the command line arguments for everything portable
#         $EverythingPortableOptions = @(
#           '-no-app-data',
#           '-choose-volumes',
#           '-enable-run-as-admin',
#           '-disable-update-notification',
#           '-install-service',
#           '-install-service-pipe-name "EverythingDF"',
#           '-start-service',
#           '-no-case',
#           '-no-diacritics',
#           "-filename `"$SearchTerm`"",
#           '-regex',
#           '-no-ignore-punctuation',
#           '-no-ignore-white-space',
#           '-save-db',
#           '-admin',
#           '-config',
#           '-index-as-admin',
#           '-instance EverythingDF',
#           '-no-auto-include',
#           '-safemode',
#           '-startup',
#           '-svc'
#         )
#         $EverythingPortableOptions += $createUSNJounal.Keys | ForEach-Object { "$_ $($createUSNJounal[$_])" }
#         # start everything portable
#         & $EverythingPortable $EverythingPortableOptions
#         # start everything cli
#         & $EverythingCLI '-s', $SearchTerm

#       }
#       catch {
#         <#Do this if a terminating exception happens#>
#       }
#       finally {
#         # Uninstall Client Service
#         & $EverythingPortable '-stop-service'
#         & $EverythingPortable '-uninstall-service'
#       }
#     }
#   }
#   process {


#   }

#   end {

#   }
# }

# # get all files in the current directory except this file and import it as a script
# $ActualScriptName = Get-PSCallStack | Select-Object -First 1 -ExpandProperty ScriptName
# $ScriptParentPath = Split-Path -Path $(Resolve-Path -Path $($ActualScriptName.foreach{ $_ }) ) -Parent
# $scriptstonotimport = @("$($($ActualScriptName.foreach{$_}).split('\')[-1])", 'Get-KapeAndTools.ps1', '*RustandFriends*', '*zimmerman*', '*memorycapture*' )
# Get-ChildItem -Path $ScriptParentPath -Exclude $scriptstonotimport | ForEach-Object {
#   . $_.FullName
# }

# Get-Everything
function Invoke-ForensicTriaging {
  [CmdletBinding()]
  param (
    [string]$LocalDirectory,
    [string]$SearchPattern
  )

  # Function to download the latest version of Everything CLI
  function Download-LatestEverything {
    $downloadPageUrl = 'https://www.voidtools.com/downloads/'
    $content = Invoke-WebRequest -Uri $downloadPageUrl
    $downloadLink = $content.Links | Where-Object { $_.href -like '*Everything-*-x64.zip' } | Select-Object -First 1 -ExpandProperty href
    $latestVersionUrl = 'https://www.voidtools.com' + $downloadLink
    $localFilePath = Join-Path $LocalDirectory (Split-Path -Path $downloadLink -Leaf)

    if (-not (Test-Path $localFilePath)) {
      Write-Host 'Downloading latest Everything CLI...'
      Invoke-WebRequest -Uri $latestVersionUrl -OutFile $localFilePath
    }

    return $localFilePath
  }

  # Function to extract Everything CLI
  function Extract-Everything {
    param (
      [string]$FilePath
    )

    $extractPath = [System.IO.Path]::GetDirectoryName($FilePath)
    Write-Host 'Extracting Everything CLI...'
    Expand-Archive -Path $FilePath -DestinationPath $extractPath -Force
    return (Get-ChildItem -Path $extractPath -Filter 'Everything.exe').FullName
  }

  # Function to remove Everything service if exists
  function Remove-EverythingService {
    if (Get-Service -Name 'Everything' -ErrorAction SilentlyContinue) {
      Stop-Service -Name 'Everything' -Force
      Remove-Service -Name 'Everything'
    }
  }

  # Function to close Everything instances
  function Close-EverythingInstances {
    Get-Process -Name 'Everything' | Stop-Process -Force
  }

  # Main Process
  try {
    if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      throw 'Administrative privileges required.'
    }

    Remove-EverythingService
    Close-EverythingInstances

    $zipFilePath = Download-LatestEverything
    $everythingExePath = Extract-Everything -FilePath $zipFilePath

    Start-Process -FilePath $everythingExePath -ArgumentList '-instance forensic -startup'
    Start-Sleep -Seconds 5

    $searchResults = & $everythingExePath -search $SearchPattern

    Write-Host 'Search Results:'
    $searchResults
  }
  catch {
    Write-Error "An error occurred: $_"
  }
  finally {
    Close-EverythingInstances
    Remove-Item -Path $zipFilePath -Force
    Remove-Item -Path ([System.IO.Path]::GetDirectoryName($zipFilePath)) -Recurse -Force
    Remove-EverythingService
  }
}

# Example Usage
# Invoke-ForensicTriaging -LocalDirectory "C:\Forensics" -SearchPattern "*.txt"
