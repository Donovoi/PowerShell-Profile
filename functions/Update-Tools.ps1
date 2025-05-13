function Update-Tools {
  [CmdletBinding()]
  param (

  )

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
        $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
        $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
        New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
      }
      Write-Verbose -Message "Importing cmdlet: $_"
      $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
      $Cmdletstoinvoke | Import-Module -Force
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
  $nugetConfigContent | Out-File -FilePath $nugetConfigPath -Force -Encoding UTF8


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
        # Logic for other actions: split and run in new elevated processes concurrently using jobs
        $actionString = $this.Action.ToString().Trim()
        # Remove surrounding braces if present
        if ($actionString.StartsWith('{') -and $actionString.EndsWith('}')) {
          $actionString = $actionString.Substring(1, $actionString.Length - 2).Trim()
        }

        # Split the action string into individual command parts
        # Filter out any empty parts that might result from multiple semicolons or trailing ones
        $commandParts = $actionString -split "[`r`n;]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ }

        if ($commandParts.Count -gt 0) {
          Write-Verbose "Preparing to launch $($commandParts.Count) command(s) concurrently via background jobs."
        }
        else {
          Write-Verbose "No command parts to execute for action: $($this.Name)"
          return
        }

        foreach ($commandPartItem in $commandParts) {
          # Renamed loop variable to avoid conflict
          try {
            Write-Verbose "Starting job for action part: $commandPartItem"
            # Each command part is launched in a separate background job.
            # The job's scriptblock will execute Start-Process.
            Start-Job -ScriptBlock {
              # This scriptblock runs in a background PowerShell process/runspace.
              param($CmdToExecuteInternal)

              try {
                # Start the actual command in a new, elevated PowerShell window.
                # -NoExit keeps the window open after the command finishes.
                # -Verb RunAs requests elevation.
                Start-Process -FilePath 'pwsh.exe' -ArgumentList "-NoExit -Command `"$CmdToExecuteInternal`"" -Verb RunAs -ErrorAction Stop
                # Verbose/Warning from here goes to job's stream, not console directly.
              }
              catch {
                # Catch errors from Start-Process (e.g., user cancels UAC).
                # This error will be in the job's error stream.
                $jobErrorMessage = "Job failed to start elevated process for '$CmdToExecuteInternal'. Error: $($_.Exception.Message)"
                Write-Error $jobErrorMessage # Puts error into the job's error stream
              }
            } -ArgumentList $commandPartItem # Pass the command part to the job's scriptblock
          }
          catch {
            # Catch errors from Start-Job itself (e.g., job system issues).
            Write-Warning "Failed to start job for action part '$commandPartItem'. Error: $($_.Exception.Message)"
          }
        }
        # After this loop, all jobs are started and running in the background.
        # The Invoke method returns, and the main script continues.
        # These are fire-and-forget jobs from the perspective of this Invoke method.
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