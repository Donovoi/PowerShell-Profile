<#
.SYNOPSIS
    Retrieves all events from specified computers within a given time range.

.DESCRIPTION
    This function fetches event logs from specified computers. It allows exporting these logs to CSV and viewing in Timeline Explorer.

.PARAMETER ExportToCsv
    Indicates whether to export the events to a CSV file.

.PARAMETER ExportToCSVPath
    Specifies the path to export the CSV file.

.PARAMETER TimelineExplorerPath
    Specifies the path of Timeline Explorer.

.PARAMETER ViewInTimelineExplorer
    Indicates whether to view the exported events in Timeline Explorer.

.EXAMPLE
    Get-AllEvents -ExportToCsv -ExportToCSVPath "C:\ExportPath"

    Retrieves events from Server1 and exports them to a CSV file at C:\ExportPath.
#>
function Get-AllEvents {
  [CmdletBinding()]
  param (

    [Parameter()]
    [switch]$ExportToCsv,

    [Parameter()]
    [string]$ExportCSVToFolder = '.',

    [Parameter()]
    [string]$TimelineExplorerPath = "$ENV:TEMP\TimelineExplorer\TimelineExplorer.exe",

    [Parameter()]
    [switch]$ViewInTimelineExplorer,

    [Parameter()]
    [string[]]$CollectEVTXFromDirectory = ''
  )

  begin {
    # Import the required cmdlets
    $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties', 'Test-IsAdministrator')
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
    function Test-AdminPrivilege {
      # Ensure the script is run with administrative privileges
      if (-not (Test-IsAdministrator)) {
        Write-Warning 'This script requires administrative privileges. Please restart with admin rights.'
        exit
      }
    }

    function Initialize-EventLogGui {
      Convert-XAMLtoWindow -NamedElements 'Retrieve', 'Begin', 'DateBegin', 'DateEnd', 'Time1', 'Time2', 'Begin1', 'End'
    }

    function Get-SelectedDateTimeFromGui {
      [CmdletBinding()]
      [OutputType([System.Collections.Hashtable])]
      param (
        [object]$Window
      )

      # Helper function to combine date and time
      function Join-DateAndTime {
        [CmdletBinding()]
        param (
          [DateTime]$date,
          [string]$timeString
        )
        try {
          $time = [TimeSpan]::Parse($timeString)
          $combinedDateTime = $date.Date + $time
          return $combinedDateTime
        }
        catch {
          Write-Logg -Message "Invalid time format: $timeString"
          return $null
        }
      }

      # Extract selected dates from the GUI
      $startDate = $Window.DateBegin.SelectedDate
      $endDate = $Window.DateEnd.SelectedDate

      # Extract times from the TextBoxes
      $startTimeString = $Window.Time1.Text
      $endTimeString = $Window.Time2.Text

      # Combine dates and times
      $startDateTime = Join-DateAndTime -date $startDate -timeString $startTimeString
      $endDateTime = Join-DateAndTime -date $endDate -timeString $endTimeString

      return @{Start = $startDateTime; End = $endDateTime }
    }


    function Close-EventLogGui {
      [CmdletBinding()]
      param (
        [object]$Window
      )
      # Close the GUI and release resources
      $Window.Close()
      [System.GC]::Collect()
      [System.GC]::WaitForPendingFinalizers()
    }

    function Convert-XAMLtoWindow {
      [CmdletBinding()]
      param (
        [string[]]$NamedElements
      )

      $xaml = @'
      <Window
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Topmost="false" SizeToContent="Height" Title="Retrieve Events from all Event Logs" Width="525" Height="450">
        <Grid Margin="0,0,9,4">
          <Grid.Background>
            <LinearGradientBrush EndPoint="0.5,1" StartPoint="0.5,0">
                <GradientStop Color="#d3d3d3" Offset="0.007"/>
                <GradientStop Color="#d3d3d3" Offset="1"/>
            </LinearGradientBrush>
          </Grid.Background>
          <Grid.ColumnDefinitions>
              <ColumnDefinition/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
              <RowDefinition Height="20*"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="20*"/>
          </Grid.RowDefinitions>
          <Button x:Name="Retrieve" Width="80" Height="25" Margin="0,50,216,30" VerticalAlignment="Bottom" HorizontalAlignment="Right" Content="Retrieve" Grid.Row="2"/>
          <TextBlock x:Name="Begin" HorizontalAlignment="Left" Margin="36,51,0,0" TextWrapping="Wrap" VerticalAlignment="Top" FontSize="14.667" FontWeight="Bold"/>
          <DatePicker x:Name="DateBegin" HorizontalAlignment="Left" Margin="36,71,0,0" VerticalAlignment="Top"/>
          <DatePicker x:Name="DateEnd" HorizontalAlignment="Left" Margin="297,71,0,0" VerticalAlignment="Top"/>
          <TextBox x:Name="Time1" HorizontalAlignment="Left" Height="23" Margin="138,71,0,0" TextWrapping="Wrap" VerticalAlignment="Top" Width="58" RenderTransformOrigin="1.296,-0.605"/>
          <TextBox x:Name="Time2" HorizontalAlignment="Left" Height="23" Margin="399,71,0,0" TextWrapping="Wrap" VerticalAlignment="Top" Width="58" RenderTransformOrigin="0.457,-3.533"/>
          <TextBlock x:Name="Begin1" HorizontalAlignment="Left" Margin="107,29,0,0" TextWrapping="Wrap" Text="Begin" VerticalAlignment="Top" FontSize="14.667"/>
          <TextBlock x:Name="End" HorizontalAlignment="Left" Margin="361,29,0,0" TextWrapping="Wrap" Text="End" VerticalAlignment="Top" FontSize="14.667"/>
        </Grid>
      </Window>
'@
      Add-Type -AssemblyName PresentationFramework

      $reader = [System.XML.XMLReader]::Create([System.IO.StringReader]$XAML)
      $result = [System.Windows.Markup.XamlReader]::Load($reader)
      foreach ($Name in $NamedElements) {
        $result | Add-Member -MemberType NoteProperty -Name $Name -Value $result.FindName($Name) -Force
      }

      # Initialize date-time pickers to current date and time
      $currentDateTime = Get-Date
      $result.Time1.Text = $currentDateTime.AddHours(-1).ToString('HH:mm:ss')
      $result.Time2.Text = $currentDateTime.ToString('HH:mm:ss')

      # Set DateBegin to 1 hour ago and DateEnd to current time
      $result.DateBegin.SelectedDate = $currentDateTime.AddHours(-1)
      $result.DateEnd.SelectedDate = $currentDateTime

      # add a onclick handler for the retrieve button
      $result.Retrieve.Add_Click({
          $selectedDates = Get-SelectedDateTimeFromGui -Window $result
          $startDateTime = $selectedDates.Start
          $endDateTime = $selectedDates.End

          $events = Get-Events -startDateTime $startDateTime -endDateTime $endDateTime -CollectEVTXFromDirectory $CollectEVTXFromDirectory
          Out-EventsFormatted -Events $events -ExportToCsv:$ExportToCsv -ExportCSVToFolder:$ExportCSVToFolder -ViewInTimelineExplorer:$ViewInTimelineExplorer -TimelineExplorerPath:$TimelineExplorerPath

          $result.Close()
        })

      $result.ShowDialog() | Out-Null
    }

    function Get-Events {
      [CmdletBinding()]
      param(
        [Parameter()]
        [datetime]$startDateTime,

        [Parameter()]
        [datetime]$endDateTime,

        [Parameter()]
        [string[]]$CollectEVTXFromDirectory = ''
      )

      try {
        if ([string]::IsNullOrEmpty($CollectEVTXFromDirectory)) {

          try {
            $EventLogs = Get-WinEvent -ListLog * -ErrorVariable err -ErrorAction Stop
            $err | ForEach-Object -Process {
              $warnmessage = $_.Exception.Message -replace '.*about the ', ''
              Write-Warning $warnmessage
            }
            # Get all event logs
            $Events = $EventLogs | ForEach-Object -Parallel {
              try {
                Get-WinEvent -FilterHashtable @{
                  LogName   = "$($_.LogName)"
                  StartTime = $using:startDateTime
                  EndTime   = $using:endDateTime
                } -MaxEvents $([System.Int64]::MaxValue) -Force -ErrorAction stop
              }
              catch {
                # Output the log name along with the error message
                $errorMessage = "Error querying log $($_): $($_.Exception.Message)"
                Write-Logg -Message $errorMessage -Level Error
                throw
              }
            } -ThrottleLimit 100
          }
          catch {
            Write-Logg -Message "An error occurred: $($_.Exception.Message)" -Level Error
            throw
          }
        }
        else {
          # Use the ParallelFileSearcher class to search for EVTX files in parallel
          Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Threading.Tasks;

public class UniqueParallelFileSearcher
{
    // Delegate with an additional severity parameter and async Task return type
    public static Func<string, string, Task> LogMessage;

    public static async Task<ConcurrentQueue<string>> SearchFilesAsync(string rootDirectory, string searchPattern)
    {
        var fileQueue = new ConcurrentQueue<string>();
        var directoriesToProcess = new ConcurrentQueue<string>();

        // Add the root directory to the queue to be processed
        directoriesToProcess.Enqueue(rootDirectory);
        if (LogMessage != null) await LogMessage("Info", $"[Info] Starting search in root directory: {rootDirectory}");

        // Step 1: Custom directory enumeration using a queue
        while (directoriesToProcess.TryDequeue(out string currentDirectory))
        {
            try
            {
                if (LogMessage != null) await LogMessage("Info", $"[Info] Enumerating directories under: {currentDirectory}");

                // Enumerate and add subdirectories to the queue
                foreach (var subDirectory in Directory.GetDirectories(currentDirectory))
                {
                    if (LogMessage != null) await LogMessage("Info", $"[Info] Discovered Directory: {subDirectory}");
                    directoriesToProcess.Enqueue(subDirectory);
                }

                // Step 2: Collect files in the current directory
                foreach (var file in Directory.EnumerateFiles(currentDirectory, searchPattern, SearchOption.TopDirectoryOnly))
                {
                    if (LogMessage != null) await LogMessage("Info", $"[Info] Found File: {file}");
                    fileQueue.Enqueue(file);
                }
            }
            catch (UnauthorizedAccessException)
            {
                if (LogMessage != null) await LogMessage("Warning", $"[Access Denied] Directory: {currentDirectory}");
            }
            catch (Exception ex)
            {
                if (LogMessage != null) await LogMessage("Error", $"[Error] Failed to process directory {currentDirectory}: {ex.Message}");
            }
        }

        if (LogMessage != null) await LogMessage("Info", $"[Info] Total files found: {fileQueue.Count}");
        return fileQueue;
    }
}
'@ -Language CSharp

          # Define an async logging function
          $loggingActionAsync = [Func[string, string, [System.Threading.Tasks.Task]]] {
            param($level, $msg)
            # Start a Task to asynchronously log the message using a lambda
            [System.Threading.Tasks.Task]::Run([Func[System.Threading.Tasks.Task]] {
                switch ($level) {
                  'Info' {
                    Write-Logg -Message $msg -Level Info
                  }
                  'Warning' {
                    Write-Logg -Message $msg -Level Warning
                  }
                  'Error' {
                    Write-Logg -Message $msg -Level Error
                  }
                  default {
                    Write-Logg -Message $msg -Level Info
                  }
                }
                return [System.Threading.Tasks.Task]::CompletedTask
              })
          }

          # Set the LogMessage delegate in the C# class to use the async logging action
          [UniqueParallelFileSearcher]::LogMessage = $loggingActionAsync

          # Run the search asynchronously
          $filesTask = [UniqueParallelFileSearcher]::SearchFilesAsync($CollectEVTXFromDirectory, '*.evt*')

          # Await the task to complete
          $files = $filesTask.GetAwaiter().GetResult()

          # Output the result
          Write-Output "Total files found: $($files.Count)"

          # Count the number of files found
          $filecount = $files.Count

          # Let the user know the next command will take a while
          Write-Logg -Message "Getting all Events from $filecount files, this may take a few minutes..." -Level Info

          # Convert $files into an array
          $fileArray = @($files.ToArray())

          # Pass to Get-WinEvent
          $Events = Get-WinEvent -Path $fileArray -ErrorAction Stop

        }

        if ($Events.Count -gt 0) {
          $EventsSorted = $Events |
            Where-Object { $_.TimeCreated -ge $startDateTime -and $_.TimeCreated -le $endDateTime } |
              Sort-Object -Property TimeCreated |
                Select-Object -Property TimeCreated, Id, LogName, LevelDisplayName, Message
        }
        else {
          Write-Logg -Message "No events found between $startDateTime and $endDateTime"
        }
      }
      catch {
        Write-Logg -Message "An error occurred while retrieving events:`n$($_.Exception.Message)"
      }
      return $EventsSorted
    }

    function Export-EventsToCsv {
      [CmdletBinding()]
      param (
        [Parameter()]
        [object[]]$Events = $EventsSorted,

        [Parameter()]
        [string]$ExportFolder

      )

      $date = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
      $filename = "Events_${date}_${ENV:COMPUTERNAME}.csv" -replace ':', '_' -replace '/', '-'

      if (($ExportFolder -match '\.') -or ($ExportFolder -eq $PWD)) {
        # Expand the path if it is a relative path
        $ExportFolder = Resolve-Path -Path $ExportFolder
      }
      $fullPath = Join-Path $ExportFolder $filename
      $Events | Export-Csv $fullPath -NoTypeInformation
      Write-Logg -Message "Events exported to $fullPath" -Level Info
      if (-not(Resolve-Path $fullPath)) {
        write-logg -message 'Export failed. Please check the log for details.' -level error
        throw
      }

      return $fullPath
    }

    function Open-WithTimelineExplorer {
      [CmdletBinding()]
      param (
        [string]$CsvFilePath,
        [string]$TimelineExplorerPath = "$ENV:TEMP\TimelineExplorer\TimelineExplorer.exe"
      )

      if ((Test-Path $TimelineExplorerPath) -and (Test-Path $CsvFilePath)) {
        Start-Process -FilePath $TimelineExplorerPath -ArgumentList $(Resolve-Path $CsvFilePath).Path
        # end script
        return
      }
      elseif (-not (Test-Path $TimelineExplorerPath)) {
        Write-Logg -Message "Timeline Explorer not found at $TimelineExplorerPath" -Level Warning
        Write-Logg -Message 'Downloading now from https://ericzimmerman.github.io/#!index.md' -Level Info
        $downloadUrl = 'https://download.ericzimmermanstools.com/net6/TimelineExplorer.zip'
        $downloadPath = "$env:TEMP"
        Get-FileDownload -Url $downloadUrl -DestinationDirectory $downloadPath -UseAria2 -NoRPCMode
        $downloadzip = "$env:TEMP\TimelineExplorer.zip"
        Write-Logg -Message "Extracting $downloadfile to $env:TEMP" -Level Info
        $extracteddownloadfolder = Expand-Archive -Path $downloadzip -DestinationPath $env:TEMP -Force
        Write-Logg -Message "Extracted $downloadzip to $extracteddownloadfolder" -Level Info
        Write-Logg -Message 'Copying TimelineExplorer.exe to $env:TEMP' -Level Info
        Copy-Item -Path "$env:TEMP\timelineexplorer\TimelineExplorer.exe" -Destination $env:TEMP -Force
        $TimelineExplorerPath = "$env:TEMP\TimelineExplorer.exe"
      }
      # If the csv file doesn't exist, export the events to CSV
      if (-not (Test-Path $CsvFilePath)) {
        Write-Logg -Message 'Windows Event Log CSV not found at creating one now..' -Level Warning
        $exportedCSV = Export-EventsToCsv -Events $EventsSorted -ExportFolder $ExportCSVToFolder
        $fullcsvpath = $(Resolve-Path -Path $exportedCSV).Path
      }

      Write-Logg -Message "Opening $fullcsvpath in Timeline Explorer" -Level Info
      Start-Process -FilePath $TimelineExplorerPath -ArgumentList $fullcsvpath -Wait
    }

    function Out-EventsFormatted {
      [CmdletBinding()]
      param (
        [Parameter(Mandatory = $true)]
        [object[]]$Events,

        [switch]$ExportToCsv,

        [string]$ExportCSVToFolder,

        [switch]$ViewInTimelineExplorer,

        [string]$TimelineExplorerPath
      )

      # Process events based on parameters
      if ($ExportToCsv) {
        $csvPath = Export-EventsToCsv -Events $Events -ExportFolder $ExportCSVToFolder
      }

      if ($ViewInTimelineExplorer) {
        $csvPath = $csvPath ? $csvPath : $(Export-EventsToCsv -Events $Events -ExportFolder $ExportCSVToFolder)
        Open-WithTimelineExplorer -CsvFilePath $csvPath -TimelineExplorerPath $TimelineExplorerPath
      }
      elseif (-not $ExportToCsv) {
        $Events | Out-ConsoleGridView -Title 'Events Found'
      }
    }
    Test-AdminPrivilege
  }

  process {
    Initialize-EventLogGui
  }
}
# Get-AllEvents -ExportToCsv -ExportCSVToFolder "$ENV:USERPROFILE" -ViewInTimelineExplorer -CollectEVTXFromDirectory 'C:\' -Verbose -ErrorAction Break