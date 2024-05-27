


# Import the required cmdlets
$neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', , 'Get-LatestGitHubRelease', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties')
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
#hashtable listing the nuget packages to install and their version
$NugetPackages = @{
  'Terminal.Gui' = '1.16.0'
  'NStack.Core'  = '1.1.1'
}

Install-Dependencies -NugetPackage $NugetPackages

# Initialize Terminal.Gui
$module = (Get-Module Microsoft.PowerShell.ConsoleGuiTools -List).ModuleBase
Add-Type -Path (Join-Path $module 'Terminal.Gui.dll') -ErrorAction SilentlyContinue
[Terminal.Gui.Application]::Init()

Write-Logg -Message 'Starting the Update-USBTools function' -Level INFO

# Function to show detailed job information
function Show-JobDetails {
  param($JobId)
  $job = Get-Job -Id $JobId
  $detailsWindow = [Terminal.Gui.Window]::new("Job Details for Job ID: $JobId")
  $detailsTextView = [Terminal.Gui.TextView]::new()
  $detailsTextView.Text = ($job | Format-List * | Out-String)
  $detailsTextView.Width = [Terminal.Gui.Dim]::Fill()
  $detailsTextView.Height = [Terminal.Gui.Dim]::Fill()
  $detailsWindow.Add($detailsTextView)
  [Terminal.Gui.Application]::Run($detailsWindow)
}


# Create the main window
$window = [Terminal.Gui.Window]::new('Job Status')
$window.Width = [Terminal.Gui.Dim]::Fill()
$window.Height = [Terminal.Gui.Dim]::Fill()

# Create the job list view
$jobListView = [Terminal.Gui.ListView]::new()
$jobListView.Width = [Terminal.Gui.Dim]::Fill()
$jobListView.Height = [Terminal.Gui.Dim]::Fill()

# Function to update the GUI with job status
function Update-Gui {
  $jobList = Get-Job | ForEach-Object {
    [PSCustomObject]@{
      Id     = $_.Id
      Name   = $_.Name
      Status = $_.State
    }
  }
  $jobListView.SetSource($jobList)
}

# Handle click events to show job details
$jobListView.OnSelectedChanged({
  Show-JobDetails -JobId $jobListView.SelectedItem.Id
})

# Add columns to the list view
$jobListView.AddColumn('Id', 'Id', 5)
$jobListView.AddColumn('Name', 'Name', 30)
$jobListView.AddColumn('Status', 'Status', 10)



# Add the list view to the window
$window.Add($jobListView)
[Terminal.Gui.Application]::Top.Add($window)

# Function to write job progress
function Write-JobProgress {
  param($Job)
  if ($null -ne $Job.ChildJobs[0].Progress) {
    $jobProgressHistory = $Job.ChildJobs[0].Progress
    $latestProgress = $jobProgressHistory[-1]
        
    if ($latestProgress) {
      $latestPercentComplete = $latestProgress.PercentComplete
      $latestActivity = $latestProgress.Activity
      $latestStatus = $latestProgress.StatusDescription
            
      if ($latestActivity -and $latestStatus -and $null -ne $latestPercentComplete) {
        Write-Progress -Id $Job.Id -Activity $latestActivity -Status $latestStatus -PercentComplete $latestPercentComplete
      }
    }
  }
}

# ScriptBlock with function name logging and progress reporting
$startJobParams = @{
  ScriptBlock  = {
    param($command, $functionName)
    Write-Host "Executing function: $functionName"
    Invoke-Expression $command

    # Simulate progress for demonstration purposes
    for ($i = 0; $i -le 100; $i += 10) {
      Write-Progress -Activity $functionName -Status "$i% complete" -PercentComplete $i
      Start-Sleep -Seconds 1
    }
  }
  ArgumentList = $null
}

# List of commands and their function names
$commands = @(
  @{Command = 'chocolatey upgrade all --ignore-dependencies'; FunctionName = 'UpgradeChocolatey' },
  @{Command = 'Update-VcRedist'; FunctionName = 'UpdateVcRedist' },
  @{Command = 'winget install JanDeDobbeleer.OhMyPosh -s winget --force --accept-source-agreements --accept-package-agreements'; FunctionName = 'InstallOhMyPosh' },
  @{Command = 'Update-VisualStudio'; FunctionName = 'UpdateVisualStudio' },
  @{Command = 'Update-VSCode'; FunctionName = 'UpdateVSCode' },
  @{Command = 'Get-KapeAndTools'; FunctionName = 'GetKapeAndTools' },
  @{Command = 'Get-GitPull'; FunctionName = 'GetGitPull' },
  @{Command = 'Update-PowerShell'; FunctionName = 'UpdatePowerShell' },
  @{Command = 'Get-LatestSIV'; FunctionName = 'GetLatestSIV' },
  @{Command = 'winget source reset --disable-interactivity --force'; FunctionName = 'ResetWingetSource' },
  @{Command = 'winget source update --disable-interactivity'; FunctionName = 'UpdateWingetSource' },
  @{Command = 'winget upgrade --all --include-unknown --wait -h --force --accept-source-agreements --accept-package-agreements'; FunctionName = 'UpgradeWinget' },
  @{Command = 'DISM /Online /Cleanup-Image /RestoreHealth; sfc /scannow'; FunctionName = 'SystemImageCleanup' },
  @{Command = 'Update-DotNetSDK'; FunctionName = 'UpdateDotNetSDK' }
)

# Array to hold job information
$jobs = @()

# Loop through each command and start a new job
foreach ($command in $commands) {
  $startJobParams.ArgumentList = @($command.Command, $command.FunctionName)
  $job = Start-Job @startJobParams
  $jobs += $job
  Write-Host "Started job for command: $($command.FunctionName) with JobId: $($job.Id)"
}

# Monitor and display job progress in GUI
do {
  foreach ($job in $jobs) {
    Write-JobProgress -Job $job
  }
  Update-Gui
  Start-Sleep -Seconds 5
  $jobs = Get-Job | Where-Object { $_.State -eq 'Running' }
} while ($jobs.Count -gt 0)

# Final update to the GUI to show all jobs have completed
Update-Gui

# Run the TUI application
[Terminal.Gui.Application]::Run()
