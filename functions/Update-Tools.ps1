function Update-Tools {
  [CmdletBinding()]
  param (
    [switch]$SingleWindow,
    [ValidateSet('Tabs', 'Panes')]
    [string]$WindowLayout = 'Panes'
  )
  # Expose configuration to the MenuItem class via script scope
  $script:UpdateTools_SingleWindow = [bool]$SingleWindow
  $script:UpdateTools_WindowLayout = $WindowLayout

  # Helper: Launch a single Windows Terminal window and orchestrate tabs/panes
  $script:UpdateTools_StartWTSequence = {
    param(
      [string[]]$Commands
    )
    if (-not $Commands -or $Commands.Count -eq 0) {
      return 
    }

    $wt = Get-Command -Name 'wt.exe' -ErrorAction SilentlyContinue
    if (-not $wt) {
      throw 'Windows Terminal (wt.exe) was not found.' 
    }

    # Resolve shell path
    $shellCmd = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $shellCmd) {
      $shellCmd = Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue 
    }
    if (-not $shellCmd) {
      throw 'Neither pwsh.exe nor powershell.exe could be located on PATH.' 
    }
    $shellPath = $shellCmd.Source

    # Build command lines for each part using -EncodedCommand
    $encodedCmds = foreach ($c in $Commands) {
      $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($c))
      "`"$shellPath`" -NoExit -EncodedCommand $enc"
    }

    # Compose wt sequence
    $sequence = @()
    # First command opens a new window
    $sequence += 'new-window'
    $sequence += '--'
    $sequence += $encodedCmds[0]

    if ($encodedCmds.Count -gt 1) {
      for ($i = 1; $i -lt $encodedCmds.Count; $i++) {
        if ($script:UpdateTools_WindowLayout -eq 'Tabs') {
          $sequence += '; new-tab -- '
          $sequence += $encodedCmds[$i]
        }
        else {
          # Panes
          # Alternate split direction for readability
          $dirFlag = if ($i % 2 -eq 0) {
            '-H' 
          }
          else {
            '-V' 
          }
          $sequence += "; split-pane $dirFlag -- "
          $sequence += $encodedCmds[$i]
        }
      }
    }

    # Join into a single argument string for wt.exe
    $argString = ($sequence -join ' ')

    try {
      Start-Process -FilePath $wt.Source -ArgumentList $argString -Verb RunAs -ErrorAction Stop | Out-Null
    }
    catch {
      # Fallback: replace new-window with new-tab (opens in existing window)
      $fallback = $argString -replace '^(\s*)new-window', '$1new-tab'
      Start-Process -FilePath $wt.Source -ArgumentList $fallback -Verb RunAs -ErrorAction Stop | Out-Null
    }
  }


  $neededcmdlets = @(
    'Write-Logg',
    'Get-Properties',
    'Show-TUIMenu',
    'Update-DotNetSDK',
    'Update-VisualStudio',
    'Get-KapeAndTools',
    'Get-GitPull',
    'Update-PowerShell',
    'Update-VScode',
    'Update-VcRedist'
  )
  $neededcmdlets | ForEach-Object {
    if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
      if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
        # Ensure TLS 1.2 support for GitHub requests (especially on Windows PowerShell 5.1)
        try {
          if (-not ([Net.ServicePointManager]::SecurityProtocol.HasFlag([Net.SecurityProtocolType]::Tls12))) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
          }
        }
        catch {
          Write-Verbose 'Unable to adjust SecurityProtocol for TLS 1.2. Proceeding anyway.'
        }

        try {
          $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1' -TimeoutSec 30 -ErrorAction Stop
          if (-not $method) {
            throw 'Empty response for Install-Cmdlet.ps1' 
          }
          $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
          New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module -ErrorAction Stop
        }
        catch {
          Write-Warning "Failed to retrieve/import Install-Cmdlet.ps1: $($_.Exception.Message)"
          return
        }
      }
      Write-Verbose -Message "Importing cmdlet: $_"
      try {
        $Cmdletstoinvoke = Install-Cmdlet -RepositoryCmdlets $_
        if ($Cmdletstoinvoke) {
          $Cmdletstoinvoke | Import-Module -Force
        }
        else {
          Write-Verbose "Install-Cmdlet returned no modules for '$_'"
        }
      }
      catch {
        Write-Warning "Failed to install/import cmdlet '$_': $($_.Exception.Message)"
      }
    }
  }

  #  define the menuitem class
  <#
.SYNOPSIS
    Represents a menu item with a display name and an associated action.

.DESCRIPTION
    The MenuItem class is used to create menu items for the terminal GUI. Each menu item has a name that is displayed in the GUI and an action that is a script block, which gets executed when the menu item is selected.

.PARAMETER Name
    The display name of the menu item.

.PARAMETER Action
    The script block that contains the action to be executed when this menu item is selected.

.EXAMPLE
    $menuItem = [MenuItem]::new('Option 1', { Write-Host 'You selected option 1' })

    This creates a new menu item with the display name 'Option 1' and an action that writes a message to the host when invoked.

.NOTES
    This class is intended to be used with the Show-TUIMenu function which handles the GUI representation and interaction.
#>

  try {
    Resolve-Path $XWAYSUSB -ErrorAction SilentlyContinue
    $ENV:ChocolateyInstall = Join-Path -Path $XWAYSUSB -ChildPath '*\chocolatey apps\chocolatey\bin' -Resolve
  }
  catch {
    Write-Verbose 'Failed to resolve Chocolatey installation path.'
  }

  # create a nuget.config file in the user profile directory if it doesn't exist
  $nugetConfigPath = Join-Path -Path $env:USERPROFILE -ChildPath '.nuget\NuGet\NuGet.Config'

  $nugetConfigContent = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
   <packageSources>
      <clear/>
      <add key="chocolatey" value="https://community.chocolatey.org/api/v2/"/>
   </packageSources>
</configuration>
'@
  # create the folder if it doesn't exist
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
      Write-Verbose "NuGet.Config at '$nugetConfigPath' already up-to-date. Skipping write."
    }
  }
  catch {
    Write-Warning "Failed to write NuGet.Config at '$nugetConfigPath': $($_.Exception.Message)"
  }


  class MenuItem {
    [string]$Name
    [scriptblock]$Action

    MenuItem([string]$Name, [scriptblock]$Action) {
      $this.Name = $Name
      $this.Action = $Action
    }

    [void]Invoke() {
      if ($this.Name -eq 'Exit') {
        # Execute the exit action directly in the current context
        # This should correctly stop the Terminal.Gui application
        try {
          & $this.Action
        }
        catch {
          # Log error if stopping fails, though Exit(0) should terminate anyway
          Write-Error "Error during exit action: $($_.Exception.Message)"
          # Force exit if necessary
          [System.Environment]::Exit(1)
        }
      }
      else {
        # Logic for other actions: either orchestrate a single WT window with tabs/panes, or spawn separate windows
        $actionString = $this.Action.ToString().Trim()
        # Remove surrounding braces if present
        if ($actionString.StartsWith('{') -and $actionString.EndsWith('}')) {
          $actionString = $actionString.Substring(1, $actionString.Length - 2).Trim()
        }

        # Split the action string into individual command parts
        # Filter out any empty parts that might result from multiple semicolons or trailing ones
        $commandParts = $actionString -split "[`r`n;]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ }

        if ($commandParts.Count -gt 0) {
          $modeMsg = if ($script:UpdateTools_SingleWindow) {
            "single WT window ($script:UpdateTools_WindowLayout)" 
          }
          else {
            'separate WT windows' 
          }
          Write-Verbose "Preparing to launch $($commandParts.Count) command(s) concurrently in $modeMsg."
        }
        else {
          Write-Verbose "No command parts to execute for action: $($this.Name)"
          return
        }

        # If SingleWindow mode is requested and wt.exe is available, build a single orchestrated spawn
        if ($script:UpdateTools_SingleWindow) {
          try {
            & $script:UpdateTools_StartWTSequence -Commands $commandParts
          }
          catch {
            Write-Warning "Failed to orchestrate single-window WT launch. Falling back to separate windows. Error: $($_.Exception.Message)"
            # fall through to separate-window behavior
          }
          if ($?) {
            return 
          }
        }

        foreach ($commandPartItem in $commandParts) {
          try {
            Write-Verbose "Launching Windows Terminal for action part: $commandPartItem"

            # Use -EncodedCommand to avoid quoting issues
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandPartItem))

            $wt = Get-Command -Name 'wt.exe' -ErrorAction SilentlyContinue
            if ($wt) {
              # Resolve full path to pwsh.exe; fallback to Windows PowerShell if needed
              $shellCmd = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
              if (-not $shellCmd) {
                $shellCmd = Get-Command -Name 'powershell.exe' -ErrorAction SilentlyContinue 
              }
              if (-not $shellCmd) {
                throw 'Neither pwsh.exe nor powershell.exe could be located on PATH.' 
              }

              $shellPath = $shellCmd.Source
              # Everything after '--' is treated as the commandline for the shell
              $cmdLine = "`"$shellPath`" -NoExit -EncodedCommand $encoded"

              try {
                # Prefer a brand new terminal window
                $wtArgs = @('new-window', '--', $cmdLine)
                Start-Process -FilePath $wt.Source -ArgumentList $wtArgs -Verb RunAs -ErrorAction Stop | Out-Null
              }
              catch {
                # Fallback to a new tab if 'new-window' fails for any reason
                $wtArgs = @('new-tab', '--', $cmdLine)
                Start-Process -FilePath $wt.Source -ArgumentList $wtArgs -Verb RunAs -ErrorAction Stop | Out-Null
              }
            }
            else {
              # Fallback: launch elevated pwsh directly if Windows Terminal isn't available
              Start-Process -FilePath 'pwsh.exe' -ArgumentList @('-NoExit', '-EncodedCommand', $encoded) -Verb RunAs -ErrorAction Stop | Out-Null
            }
          }
          catch {
            Write-Warning "Failed to launch terminal for action part '$commandPartItem'. Error: $($_.Exception.Message)"
          }
        }
        # After this loop, all processes are started in separate terminal windows and run concurrently.
      }
    }
  }
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
  $menuItem14 = [MenuItem]::new('Exit', { [Terminal.Gui.Application]::RequestStop(); [Terminal.Gui.Application]::Shutdown(); [System.Environment]::Exit(0) })
  Show-TUIMenu -MenuItems @(
    $menuItem0,
    $menuItem1,
    $menuItem2,
    $menuItem3,
    $menuItem4,
    $menuItem5,
    $menuItem6,
    $menuItem7,
    $menuItem8,
    $menuItem9,
    $menuItem10,
    $menuItem11,
    $menuItem12,
    $menuItem13,
    $menuItem14
  ) -ErrorAction SilentlyContinue
}