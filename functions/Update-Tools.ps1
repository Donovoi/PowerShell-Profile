function Update-Tools {
  [CmdletBinding()]
  param(
    [switch]$SingleWindow,
    [ValidateSet('Tabs', 'Panes')]
    [string]$WindowLayout = 'Panes'
  )

  # -------------------------------
  # Script-scoped config for MenuItem
  # -------------------------------
  $script:UpdateTools_SingleWindow = [bool]$SingleWindow
  $script:UpdateTools_WindowLayout = $WindowLayout

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
    # HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions\<GUID>\
    try {
      $inst = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions' -ErrorAction Stop |
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

    $argString = ($sequence -join ' ')
    try {
      Start-Process -FilePath $wt.Source -ArgumentList $argString -Verb RunAs -ErrorAction Stop | Out-Null
    }
    catch {
      # Fallback: open in an existing window (use -w 0)
      $fallback = $argString -replace '^-w\s+-1', '-w 0'
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
  try {
    Resolve-Path $XWAYSUSB -ErrorAction SilentlyContinue | Out-Null
    $ENV:ChocolateyInstall = Join-Path -Path $XWAYSUSB -ChildPath '*\chocolatey apps\chocolatey\bin' -Resolve
  }
  catch {
    Write-Verbose 'Failed to resolve Chocolatey installation path.'
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
      <add key="chocolatey" value="https://community.chocolatey.org/api/v2/"/>
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

    MenuItem([string]$Name, [scriptblock]$Action) {
      $this.Name = $Name
      $this.Action = $Action
    }

    [void]Invoke() {
      if ($this.Name -eq 'Exit') {
        try {
          & $this.Action
        }
        catch {
          Write-Error "Error during exit action: $($_.Exception.Message)"
          [Environment]::Exit(1)
        }
        return
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
      Write-Verbose "Preparing to launch $($commandParts.Count) command(s) in $modeMsg."

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
              $args = @('-w', '-1', 'new-tab', '--', $encodedCmd)
              Start-Process -FilePath $wt.Source -ArgumentList $args -Verb RunAs -ErrorAction Stop | Out-Null
            }
            catch {
              # Fallback: target the active window
              $args = @('-w', '0', 'new-tab', '--', $encodedCmd)
              Start-Process -FilePath $wt.Source -ArgumentList $args -Verb RunAs -ErrorAction Stop | Out-Null
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
  $menuItem14 = [MenuItem]::new('Exit', { [Terminal.Gui.Application]::RequestStop(); [Terminal.Gui.Application]::Shutdown(); [Environment]::Exit(0) })

  Show-TUIMenu -MenuItems @(
    $menuItem0, $menuItem1, $menuItem2, $menuItem3, $menuItem4,
    $menuItem5, $menuItem6, $menuItem7, $menuItem8, $menuItem9,
    $menuItem10, $menuItem11, $menuItem12, $menuItem13, $menuItem14
  ) -ErrorAction SilentlyContinue
}
