<#
.SYNOPSIS
    Interactive menu for updating various development tools and system components.

.DESCRIPTION
    Provides a Terminal UI menu to selectively update tools like Chocolatey packages, 
    Winget applications, Visual Studio, VS Code, PowerShell, and run system maintenance 
    tasks. Can launch operations in separate Windows Terminal windows or organize them 
    in a single window using tabs or panes.

    This cmdlet requires administrative privileges for some operations like DISM, SFC, 
    and certain package managers.

.PARAMETER SingleWindow
    Launch all selected operations in a single Windows Terminal window using the 
    specified layout (tabs or panes) instead of separate windows.

.PARAMETER WindowLayout
    Specifies the layout when using SingleWindow. Valid values are 'Tabs' or 'Panes'.
    Default is 'Panes'. Only used when SingleWindow is specified.

.PARAMETER Force
    Suppresses confirmation prompts where possible and forces operations to proceed.

.PARAMETER WhatIf
    Shows what would be done without actually performing the operations.

.EXAMPLE
    Update-Tools
    
    Launch the interactive menu with default settings (separate windows).

.EXAMPLE
    Update-Tools -SingleWindow -WindowLayout Tabs
    
    Launch with all operations organized in tabs within a single Windows Terminal window.

.EXAMPLE
    Update-Tools -Force
    
    Launch the menu and suppress confirmation prompts where possible.

.NOTES
    Author: Donovoi
    Requires: Windows Terminal (optional but recommended), PowerShell 5.1+
    Some operations require administrative privileges and will prompt for elevation.

.LINK
    https://github.com/Donovoi/PowerShell-Profile
#>
function Update-Tools {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [switch]$SingleWindow,
    
    [ValidateSet('Tabs', 'Panes')]
    [string]$WindowLayout = 'Panes',
    
    [switch]$Force,
    
    [string[]]$IncludeTools,
    
    [string[]]$ExcludeTools
  )

  # -------------------------------
  # Constants and Configuration
  # -------------------------------
  $script:GITHUB_BASE_URL = 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/'
  $script:CHOCOLATEY_COMMUNITY_URL = 'https://community.chocolatey.org/api/v2/'
  $script:INSTALL_CMDLET_URL = "$script:GITHUB_BASE_URL/Install-Cmdlet.ps1"
  $script:WEB_REQUEST_TIMEOUT = 30
  $script:REGISTRY_PATH_PWSH = 'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions'
  
  # -------------------------------
  # Script-scoped config for MenuItem
  # -------------------------------
  $script:UpdateTools_SingleWindow = [bool]$SingleWindow
  $script:UpdateTools_WindowLayout = $WindowLayout
  $script:UpdateTools_Force = [bool]$Force

  # Validate global variables if they exist
  if (Get-Variable -Name 'XWAYSUSB' -Scope Global -ErrorAction SilentlyContinue) {
    if (-not (Test-Path -Path $Global:XWAYSUSB -ErrorAction SilentlyContinue)) {
      Write-Warning "Global variable XWAYSUSB points to non-existent path: $Global:XWAYSUSB"
    }
  }

  # -------------------------------
  # Helpers
  # -------------------------------

  function Get-PwshPath {
    # Prefer whatever pwsh.exe is on PATH
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) {
      return $cmd.Source 
    }

    # PowerShell 7+ writes discovery keys under InstalledVersions (MSI/MSIX)
    try {
      $inst = Get-ChildItem $script:REGISTRY_PATH_PWSH -ErrorAction Stop |
        Get-ItemProperty -ErrorAction Stop |
          ForEach-Object {
            if ($_.InstallLocation) {
              $path = Join-Path $_.InstallLocation 'pwsh.exe'
              if (Test-Path $path) {
                $path 
              }
            }
          } |
            Select-Object -First 1
      if ($inst) {
        return $inst 
      }
    }
    catch {
      Write-Verbose "Failed to query PowerShell registry path: $($_.Exception.Message)"
    }

    # Last resort: Windows PowerShell 5.1
    return (Get-Command powershell.exe -ErrorAction Stop).Source
  }

  function New-EncodedShellCommand {
    param(
      [Parameter(Mandatory)] [string] $Command
    )
    $shellPath = Get-PwshPath
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    return "`"$shellPath`" -NoExit -EncodedCommand $enc"
  }

  # One WT window, orchestrating tabs or panes
  $script:UpdateTools_StartWTSequence = {
    param([string[]]$Commands)

    if (-not $Commands -or -not $Commands.Count) {
      return 
    }

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if (-not $wt) {
      throw 'Windows Terminal (wt.exe) was not found.' 
    }

    # Build per-command encoded shell lines
    $encodedCmds = foreach ($c in $Commands) {
      New-EncodedShellCommand -Command $c 
    }

    # Build a documented, robust sequence:
    #   -w -1         => open a brand-new window
    #   new-tab       => first tab
    #   split-pane    => additional panes (or new-tab for Tabs layout)
    $sequence = @()
    $sequence += '-w -1 new-tab --'
    $sequence += $encodedCmds[0]

    for ($i = 1; $i -lt $encodedCmds.Count; $i++) {
      if ($script:UpdateTools_WindowLayout -eq 'Tabs') {
        $sequence += '; new-tab --'
        $sequence += $encodedCmds[$i]
      }
      else {
        $dirFlag = if ($i % 2 -eq 0) {
          '-H' 
        }
        else {
          '-V' 
        }
        $sequence += "; split-pane $dirFlag --"
        $sequence += $encodedCmds[$i]
      }
    }

    $argumentstring = ($sequence -join ' ')
    try {
      Start-Process -FilePath $wt.Source -ArgumentList $argumentstring -Verb RunAs -ErrorAction Stop | Out-Null
    }
    catch {
      # Fallback: open in an existing window (use -w 0)
      $fallback = $argumentstring -replace '^-w\s+-1', '-w 0'
      Start-Process -FilePath $wt.Source -ArgumentList $fallback -Verb RunAs -ErrorAction Stop | Out-Null
    }
  }

  # -------------------------------
  # Ensure dependency cmdlets exist
  # -------------------------------
  $neededcmdlets = @(
    'Write-Logg',
    'Get-Properties',
    'Show-TUIMenu',
    'Update-DotNetSDK',
    'Update-VisualStudio',
    'Get-KapeAndTools',
    'Get-GitPull',
    'Update-PowerShell',
    'Update-VSCode',     # fixed casing to match later usage
    'Update-VcRedist'
  )

  foreach ($name in $neededcmdlets) {
    if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
      if (-not (Get-Command -Name Install-Cmdlet -ErrorAction SilentlyContinue)) {
        # Ensure TLS 1.2 when pulling raw from GitHub on WinPS5.1
        try {
          if (-not ([Net.ServicePointManager]::SecurityProtocol.HasFlag([Net.SecurityProtocolType]::Tls12))) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Write-Information 'Enabled TLS 1.2 for secure web requests.' -InformationAction Continue
          }
        }
        catch {
          Write-Warning "Unable to adjust SecurityProtocol for TLS 1.2: $($_.Exception.Message). Proceeding anyway."
        }

        try {
          Write-Information 'Downloading Install-Cmdlet from repository...' -InformationAction Continue
          $method = Invoke-RestMethod -Uri $script:INSTALL_CMDLET_URL -TimeoutSec $script:WEB_REQUEST_TIMEOUT -ErrorAction Stop
          if (-not $method) {
            throw 'Empty response for Install-Cmdlet.ps1' 
          }
          $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
          New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module -ErrorAction Stop
          Write-Information 'Successfully imported Install-Cmdlet module.' -InformationAction Continue
        }
        catch {
          Write-Warning "Failed to retrieve/import Install-Cmdlet.ps1: $($_.Exception.Message)"
          return
        }
      }

      try {
        $mods = Install-Cmdlet -RepositoryCmdlets $name
        if ($mods) {
          $mods | Import-Module -Force 
        }
        else {
          Write-Verbose "Install-Cmdlet returned no modules for '$name'" 
        }
      }
      catch {
        Write-Warning "Failed to install/import cmdlet '$name': $($_.Exception.Message)"
      }
    }
  }

  # -------------------------------
  # Try to set ChocolateyInstall if you use portable media ($XWAYSUSB)
  # -------------------------------
  if (Get-Variable -Name 'XWAYSUSB' -Scope Global -ErrorAction SilentlyContinue) {
    try {
      if (Test-Path -Path $Global:XWAYSUSB -ErrorAction SilentlyContinue) {
        $chocoPath = Join-Path -Path $Global:XWAYSUSB -ChildPath '*\chocolatey apps\chocolatey\bin' -Resolve -ErrorAction SilentlyContinue
        if ($chocoPath) {
          $ENV:ChocolateyInstall = $chocoPath
          Write-Information "Set ChocolateyInstall to: $chocoPath" -InformationAction Continue
        }
      }
    }
    catch {
      Write-Verbose "Failed to resolve Chocolatey installation path: $($_.Exception.Message)"
    }
  }

  # -------------------------------
  # Create a minimal NuGet.Config for choco if missing/different
  # -------------------------------
  $nugetConfigPath = Join-Path -Path $env:USERPROFILE -ChildPath '.nuget\NuGet\NuGet.Config'
  $nugetConfigContent = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
   <packageSources>
      <clear/>
      <add key="chocolatey" value="$script:CHOCOLATEY_COMMUNITY_URL"/>
   </packageSources>
</configuration>
'@
  $nugetConfigDir = Split-Path -Path $nugetConfigPath -Parent
  if (-not (Test-Path -Path $nugetConfigDir)) {
    New-Item -Path $nugetConfigDir -ItemType Directory -Force | Out-Null
  }
  try {
    $writeConfig = $true
    if (Test-Path -LiteralPath $nugetConfigPath) {
      $existingConfig = Get-Content -LiteralPath $nugetConfigPath -Raw -ErrorAction SilentlyContinue
      if ($existingConfig -eq $nugetConfigContent) {
        $writeConfig = $false 
      }
    }
    if ($writeConfig) {
      $nugetConfigContent | Out-File -FilePath $nugetConfigPath -Force -Encoding UTF8
      Write-Verbose "NuGet.Config written to '$nugetConfigPath'"
    }
    else {
      Write-Verbose "NuGet.Config already up-to-date at '$nugetConfigPath'."
    }
  }
  catch {
    Write-Warning "Failed to write NuGet.Config at '$nugetConfigPath': $($_.Exception.Message)"
  }

  # -------------------------------
  # MenuItem class
  # -------------------------------
  class MenuItem {
    [string]$Name
    [scriptblock]$Action
    [bool]$IsExitItem
    [bool]$RequiresAdmin

    MenuItem([string]$Name, [scriptblock]$Action) {
      if ([string]::IsNullOrWhiteSpace($Name)) {
        throw [ArgumentException]::new('MenuItem name cannot be null or empty')
      }
      if ($null -eq $Action) {
        throw [ArgumentNullException]::new('MenuItem action cannot be null')
      }
      
      $this.Name = $Name
      $this.Action = $Action
      $this.IsExitItem = ($Name -eq 'Exit')
      
      # Determine if this action requires admin privileges
      $actionString = $Action.ToString()
      $this.RequiresAdmin = ($actionString -match 'DISM|sfc|choco|winget|Update-.*|Invoke-Tron')
    }

    [void]Invoke() {
      if ($this.IsExitItem) {
        try {
          & $this.Action
        }
        catch {
          Write-Error "Error during exit action: $($_.Exception.Message)"
          return
        }
        return
      }

      # Check if we need admin privileges
      if ($this.RequiresAdmin) {
        $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
          Write-Warning "Action '$($this.Name)' requires administrative privileges. Some operations may fail."
        }
      }

      # Flatten the scriptblock to plain commands, splitting on ; and newlines
      $actionString = $this.Action.ToString().Trim()
      if ($actionString.StartsWith('{') -and $actionString.EndsWith('}')) {
        $actionString = $actionString.Substring(1, $actionString.Length - 2).Trim()
      }

      $commandParts = $actionString -split "[`r`n;]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ }

      if ($commandParts.Count -eq 0) {
        Write-Verbose "No command parts to execute for action: $($this.Name)"
        return
      }

      $modeMsg = if ($script:UpdateTools_SingleWindow) {
        "single WT window ($script:UpdateTools_WindowLayout)"
      }
      else {
        'separate WT windows'
      }
      Write-Information "Preparing to launch $($commandParts.Count) command(s) in $modeMsg." -InformationAction Continue

      # Try the single-window orchestrated flow first (if requested)
      if ($script:UpdateTools_SingleWindow) {
        try {
          & $script:UpdateTools_StartWTSequence -Commands $commandParts
          if ($?) {
            return 
          }
        }
        catch {
          Write-Warning "Single-window WT launch failed, falling back to separate windows. Error: $($_.Exception.Message)"
        }
      }

      # Separate windows / tabs fallback: launch each command individually
      foreach ($command in $commandParts) {
        try {
          $encodedCmd = New-EncodedShellCommand -Command $command
          $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
          if ($wt) {
            # Open a brand-new window for each command
            try {
              $arguments = @('-w', '-1', 'new-tab', '--', $encodedCmd)
              Start-Process -FilePath $wt.Source -ArgumentList $arguments -Verb RunAs -ErrorAction Stop | Out-Null
            }
            catch {
              # Fallback: target the active window
              $arguments = @('-w', '0', 'new-tab', '--', $encodedCmd)
              Start-Process -FilePath $wt.Source -ArgumentList $arguments -Verb RunAs -ErrorAction Stop | Out-Null
            }
          }
          else {
            # Final fallback: launch shell directly (no WT)
            $shellPath = Get-PwshPath
            Start-Process -FilePath $shellPath -ArgumentList @('-NoExit', '-EncodedCommand', ($encodedCmd -replace '.*EncodedCommand\s+', '')) -Verb RunAs -ErrorAction Stop | Out-Null
          }
        }
        catch {
          Write-Warning "Failed to launch terminal for action part '$command'. Error: $($_.Exception.Message)"
        }
      }
    }
  }

  # -------------------------------
  # Menu definitions
  # -------------------------------
  if ($PSCmdlet.ShouldProcess('System Tools', 'Display Update Tools Menu')) {
    Write-Information 'Initializing Update Tools menu...' -InformationAction Continue
    
    $menuItem0 = [MenuItem]::new('All', {
        choco upgrade all --ignore-dependencies -y
        winget install JanDeDobbeleer.OhMyPosh -s winget --force --accept-source-agreements --accept-package-agreements
        Update-VisualStudio
        Update-VSCode
        Get-KapeAndTools
        Get-GitPull
        Update-PowerShell
        winget source reset --disable-interactivity --force
        winget source update --disable-interactivity
        winget upgrade --all --force --accept-source-agreements --accept-package-agreements
        DISM /Online /Cleanup-Image /RestoreHealth
        sfc /scannow
        Update-DotNetSDK
        Update-VcRedist
        Invoke-Tron -Elevate -Wait
      })
    $menuItem1 = [MenuItem]::new('UpgradeChocolateyAndTools', { choco upgrade all --ignore-dependencies })
    $menuItem2 = [MenuItem]::new('InstallOhMyPosh', { winget install JanDeDobbeleer.OhMyPosh -s winget --force --accept-source-agreements --accept-package-agreements })
    $menuItem3 = [MenuItem]::new('UpdateVisualStudio', { Update-VisualStudio })
    $menuItem4 = [MenuItem]::new('UpdateVSCode', { Update-VSCode })
    $menuItem5 = [MenuItem]::new('GetKapeAndTools', { Get-KapeAndTools })
    $menuItem6 = [MenuItem]::new('GetGitPull', { Get-GitPull })
    $menuItem7 = [MenuItem]::new('UpdatePowerShell', { Update-PowerShell })
    $menuItem8 = [MenuItem]::new('ResetWingetSource', { winget source reset --disable-interactivity --force })
    $menuItem9 = [MenuItem]::new('UpdateWingetSource', { winget source update --disable-interactivity })
    $menuItem10 = [MenuItem]::new('UpgradeWingetAndTools', { winget upgrade --all --accept-source-agreements --accept-package-agreements })
    $menuItem11 = [MenuItem]::new('SystemImageCleanup', { DISM /Online /Cleanup-Image /RestoreHealth; sfc /scannow })
    $menuItem12 = [MenuItem]::new('UpdateDotNetSDK', { Update-DotNetSDK })
    $menuItem13 = [MenuItem]::new('UpdateVcRedist', { Update-VcRedist })
    $menuItem14 = [MenuItem]::new('Invoke Tron', { Invoke-Tron -Elevate -Wait })
    $menuItem15 = [MenuItem]::new('Exit', { return })

    # Filter menu items based on IncludeTools/ExcludeTools if specified
    $allMenuItems = @(
      $menuItem0, $menuItem1, $menuItem2, $menuItem3, $menuItem4,
      $menuItem5, $menuItem6, $menuItem7, $menuItem8, $menuItem9,
      $menuItem10, $menuItem11, $menuItem12, $menuItem13, $menuItem14, $menuItem15
    )
    
    $filteredMenuItems = $allMenuItems
    if ($IncludeTools -and $IncludeTools.Count -gt 0) {
      $filteredMenuItems = $allMenuItems | Where-Object { $_.Name -in $IncludeTools -or $_.Name -eq 'Exit' }
    }
    if ($ExcludeTools -and $ExcludeTools.Count -gt 0) {
      $filteredMenuItems = $filteredMenuItems | Where-Object { $_.Name -notin $ExcludeTools }
    }
    
    try {
      Show-TUIMenu -MenuItems $filteredMenuItems -ErrorAction SilentlyContinue
    }
    catch {
      Write-Error "Failed to display menu: $($_.Exception.Message)"
    }
  }
  else {
    Write-Information 'WhatIf: Would display Update Tools menu with 16 items' -InformationAction Continue
  }
}
