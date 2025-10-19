# Function to download the latest Zimmerman Tools and put them in path with chocolatey bins.
# Also updates kape & bins
function Get-KapeAndTools {
  [CmdletBinding()]
  param(

  )
  # --- dynamically import helper cmdlets ----------------------------
  # Set TLS 1.2 for secure connections
  if ($PSVersionTable.PSVersion.Major -le 5) {
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    }
    catch {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
  }
  
  # Load shared dependency loader if not already available
  if (-not (Get-Command -Name 'Initialize-CmdletDependencies' -ErrorAction SilentlyContinue)) {
    $initScript = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
    if (Test-Path $initScript) {
      . $initScript
    }
    else {
      Write-Warning "Initialize-CmdletDependencies.ps1 not found in $PSScriptRoot"
      Write-Warning 'Falling back to direct download'
      try {
        $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -TimeoutSec 30 -UseBasicParsing
        $scriptBlock = [scriptblock]::Create($method)
        . $scriptBlock
      }
      catch {
        Write-Error "Failed to load Initialize-CmdletDependencies: $($_.Exception.Message)"
        throw
      }
    }
  }
  
  # Load all required cmdlets
  $neededCmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-LatestGitHubRelease')
  try {
    Initialize-CmdletDependencies -RequiredCmdlets $neededCmdlets -PreferLocal -ErrorAction Stop
  }
  catch {
    Write-Warning "Failed to load some dependencies: $($_.Exception.Message)"
    Write-Warning 'Attempting to continue with available cmdlets...'
  }
  
  if (Get-Command -Name 'Write-Logg' -ErrorAction SilentlyContinue) {
    Write-Logg -Message "Script is running as $($MyInvocation.MyCommand.Name)" -level info
  }
  else {
    Write-Verbose "Script is running as $($MyInvocation.MyCommand.Name)"
  }
  # Get X-Ways USB drive
  try {
    $XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'" -ErrorAction Stop).DriveLetter
    if (-not $XWAYSUSB) {
      throw 'X-Ways USB drive not found'
    }
  }
  catch {
    Write-Error "Failed to find X-Ways USB drive: $($_.Exception.Message)"
    return
  }
  
  $ENV:ChocolateyInstall = Join-Path -Path $XWAYSUSB -ChildPath 'chocolatey apps\chocolatey\bin'

  # Resolve Triage folder path
  $XWAYSUSBtriagefolder = ''
  $triagePath = Join-Path -Path $XWAYSUSB -ChildPath 'Triage'
  
  if (Test-Path -Path $triagePath) {
    $XWAYSUSBtriagefolder = $triagePath
  }
  else {
    # Try wildcard pattern
    $wildcard = Join-Path -Path $XWAYSUSB -ChildPath '*\Triage'
    $resolved = Get-Item -Path $wildcard -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($resolved) {
      $XWAYSUSBtriagefolder = $resolved.FullName
    }
    else {
      Write-Warning "Triage folder not found at $triagePath or $wildcard"
      Write-Warning "Creating Triage folder at $triagePath"
      New-Item -Path $triagePath -ItemType Directory -Force | Out-Null
      $XWAYSUSBtriagefolder = $triagePath
    }
  }


  # Clean up old Zimmerman tools
  $zimmermanPath = Join-Path -Path $XWAYSUSBtriagefolder -ChildPath 'KAPE\Modules\bin\ZimmermanTools'
  if (Test-Path -Path $zimmermanPath) {
    try {
      Remove-Item -Path $zimmermanPath -Recurse -Force -ErrorAction Stop
      Write-Verbose "Removed old ZimmermanTools from $zimmermanPath"
    }
    catch {
      Write-Warning "Failed to remove ${zimmermanPath}: $($_.Exception.Message)"
    }
  }
  
  $getZimmermanScript = Join-Path -Path $XWAYSUSBtriagefolder -ChildPath 'KAPE\Modules\bin\Get-ZimmermanTools.ps1'
  if (Test-Path -Path $getZimmermanScript) {
    try {
      Remove-Item -Path $getZimmermanScript -Force -ErrorAction Stop
      Write-Verbose 'Removed old Get-ZimmermanTools.ps1'
    }
    catch {
      Write-Warning "Failed to remove ${getZimmermanScript}: $($_.Exception.Message)"
    }
  }

  # Resolve KAPE installation location
  $kapeinstalllocation = Join-Path -Path $XWAYSUSBtriagefolder -ChildPath 'KAPE'
  
  if (-not (Test-Path -Path $kapeinstalllocation)) {
    Write-Warning "KAPE folder not found at $kapeinstalllocation"
    Write-Warning 'Creating KAPE folder'
    try {
      New-Item -Path $kapeinstalllocation -ItemType Directory -Force | Out-Null
    }
    catch {
      Write-Error "Failed to create KAPE folder: $($_.Exception.Message)"
      return
    }
  }
  
  try {
    Push-Location -Path $kapeinstalllocation -ErrorAction Stop
  }
  catch {
    Write-Error "Failed to navigate to ${kapeinstalllocation}: $($_.Exception.Message)"
    return
  }
  # Get latest version of KAPE-ANCILLARYUpdater.ps1
  if (-not (Get-Command -Name 'Get-LatestGitHubRelease' -ErrorAction SilentlyContinue)) {
    Write-Error 'Get-LatestGitHubRelease cmdlet not available. Cannot download KAPE updater.'
    Pop-Location
    return
  }
  
  $kapePath = Join-Path -Path $XWAYSUSBtriagefolder -ChildPath 'kape'
  if (-not (Test-Path -Path $kapePath)) {
    New-Item -Path $kapePath -ItemType Directory -Force | Out-Null
  }
  
  try {
    $params = @{
      OwnerRepository       = 'AndrewRathbun/KAPE-EZToolsAncillaryUpdater'
      AssetName             = 'KAPE-EZToolsAncillaryUpdater.ps1'
      DownloadPathDirectory = $kapePath
      UseAria2              = $true
      NoRPCMode             = $true
    }

    $KapeAncillaryUpdater = Get-LatestGitHubRelease @params
    
    if ($KapeAncillaryUpdater -and (Test-Path -Path $KapeAncillaryUpdater)) {
      Write-Verbose "Running KAPE updater: $KapeAncillaryUpdater"
      Start-Process -FilePath 'pwsh.exe' -ArgumentList '-NoProfile', '-NoExit', '-File', $KapeAncillaryUpdater, '-silent' -Wait -ErrorAction Stop
    }
    else {
      Write-Warning 'KAPE updater download failed or file not found'
    }
  }
  catch {
    Write-Error "Failed to download or run KAPE updater: $($_.Exception.Message)"
  }

  # Copy KAPE folder to ventoy USB
  try {
    $fastusb = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'ventoy'" -ErrorAction Stop).DriveLetter
    
    if ($fastusb) {
      $triageDestination = Join-Path -Path $fastusb -ChildPath 'triage'
      if (-not (Test-Path -Path $triageDestination)) {
        New-Item -Path $triageDestination -ItemType Directory -Force | Out-Null
      }
      
      $kapeSource = Join-Path -Path $XWAYSUSBtriagefolder -ChildPath 'kape'
      if (Test-Path -Path $kapeSource) {
        $params = @{
          Path        = $kapeSource
          Destination = $triageDestination
          Recurse     = $true
          Force       = $true
          ErrorAction = 'Stop'
        }
        
        Copy-Item @params
        
        $message = "Successfully copied KAPE folder to $triageDestination\kape"
        if (Get-Command -Name 'Write-Logg' -ErrorAction SilentlyContinue) {
          Write-Logg -Message $message -level info
        }
        else {
          Write-Host $message -ForegroundColor Green
        }
      }
      else {
        Write-Warning "KAPE source folder not found at $kapeSource"
      }
    }
    else {
      Write-Warning 'Ventoy USB drive not found. Skipping copy operation.'
    }
  }
  catch {
    Write-Warning "Failed to copy KAPE folder to ventoy USB: $($_.Exception.Message)"
  }
  finally {
    Pop-Location
  }
}