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



function Get-Everything {
  [CmdletBinding()]
  param(
    # Everything executable path
    [Parameter(Mandatory = $false)]
    [string]
    $EverythingPortable,
    [Parameter(Mandatory = $false)]
    [string]
    $EverythingDirectory = $PWD,
    [Parameter(Mandatory = $false)]
    [string]
    $SearchTerm = '*',
    [Parameter(Mandatory = $false)]
    [string[]]
    $Volume = (Get-Volume).DriveLetter,
    [Parameter(Mandatory = $false)]
    [switch]
    $EverythingHome
  )

  begin {
    if ($EverythingHome) {
      & $EverythingEXE '-home'
    }
    # we need to check if the Everything executable is present
    if (-not (Test-Path $EverythingEXE -ErrorAction SilentlyContinue)) {
      Write-Logg -Message 'Everything executable not found' -Level Info
      Write-Logg -Message 'Downloading Everything' -Level Info



      # Download Everything
      $everythingclizip = Get-FileDownload -URL 'https://www.voidtools.com/ES-1.1.0.26.zip' -OutFileDirectory $EverythingDirectory -UseAria2
      $everythingPortablezip = Get-FileDownload -Url 'https://www.voidtools.com/Everything-1.5.0.1361a.x64.zip' -OutFileDirectory $EverythingDirectory -UseAria2
      $Zipstoexpand = @($everythingclizip, $everythingPortablezip)
      $Zipstoexpand.ForEach{ Expand-Archive -Path $_ -DestinationPath $EverythingDirectory -Force }
      $EverythingCLI = Get-ChildItem -Path $EverythingDirectory -Filter 'es.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
      $EverythingPortable = Get-ChildItem -Path $EverythingDirectory -Filter 'Everything*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
      try {


        # We will now start everything portable with the right arguments/needs to be as forensically sound as possible:
        # Get a list of all volumes
        $AllVolumesExceptScriptVolume = $Volume.Where{ $_ -ne $PWD.Drive.Name }
        # create a string for the command line arguments
        $createUSNJounal = @{}
        $maxusnjournalsizebytes = 1GB
        $AllVolumesExceptScriptVolume.ForEach{ $createUSNJounal.Add('-create-usn-journal', $_, $maxusnjournalsizebytes ) }

        # create the command line arguments for everything portable
        $EverythingPortableOptions = @(
          '-no-app-data',
          '-choose-volumes',
          '-enable-run-as-admin',
          '-disable-update-notification',
          '-install-service',
          '-install-service-pipe-name "EverythingDF"',
          '-start-service',
          '-no-case',
          '-no-diacritics',
          "-filename `"$SearchTerm`"",
          '-regex',
          '-no-ignore-punctuation',
          '-no-ignore-white-space',
          '-save-db',
          '-admin',
          '-config',
          '-index-as-admin',
          '-instance EverythingDF',
          '-no-auto-include',
          '-safemode',
          '-startup',
          '-svc'
        )
        $EverythingPortableOptions += $createUSNJounal.Keys | ForEach-Object { "$_ $($createUSNJounal[$_])" }
        # start everything portable
        & $EverythingPortable $EverythingPortableOptions
        # start everything cli
        & $EverythingCLI '-s', $SearchTerm

      }
      catch {
        <#Do this if a terminating exception happens#>
      }
      finally {
        # Uninstall Client Service
        & $EverythingPortable '-stop-service'
        & $EverythingPortable '-uninstall-service'
      }
    }
  }
  process {


  }

  end {

  }
}

# # get all files in the current directory except this file and import it as a script
# $ActualScriptName = Get-PSCallStack | Select-Object -First 1 -ExpandProperty ScriptName
# $ScriptParentPath = Split-Path -Path $(Resolve-Path -Path $($ActualScriptName.foreach{ $_ }) ) -Parent
# $scriptstonotimport = @("$($($ActualScriptName.foreach{$_}).split('\')[-1])", 'Get-KapeAndTools.ps1', '*RustandFriends*', '*zimmerman*', '*memorycapture*' )
# Get-ChildItem -Path $ScriptParentPath -Exclude $scriptstonotimport | ForEach-Object {
#   . $_.FullName
# }

# Get-Everything