function Get-AllEvents {
  [CmdletBinding()]
  param (
    [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = 'Enter one or more hosts')]
    [Alias('ComputerName', 'MachineName', 'Server', 'Host')]
    [switch]$ExportToCsv,

    [Parameter(HelpMessage = 'Specify the path to export CSV file')]
    [string]$ExportToCSVPath = '.',

    [Parameter(HelpMessage = 'Specify the path of Timeline Explorer')]
    [string]$TimelineExplorerPath = "$ENV:TEMP\TimelineExplorer.exe",

    [Parameter(HelpMessage = 'View in Timeline Explorer')]
    [switch]$ViewInTimelineExplorer
  )
  # # get all files in the current directory except this file and import it as a script
  # $ActualScriptName = Get-PSCallStack | Select-Object -First 1 -ExpandProperty ScriptName
  # $ScriptParentPath = Split-Path -Path $(Resolve-Path -Path $($ActualScriptName.foreach{ $_ }) ) -Parent
  # $scriptstonotimport = @("$($($ActualScriptName.foreach{$_}).split('\')[-1])", 'Get-KapeAndTools.ps1', '*RustandFriends*', '*zimmerman*', '*memorycapture*' )
  # Get-ChildItem -Path $ScriptParentPath -Exclude $scriptstonotimport | ForEach-Object {
  #   . $_.FullName
  # }

  # Check if Test-IsAdministrator function exists before calling it
  if (Get-Command Test-IsAdministrator -ErrorAction SilentlyContinue) {
    if (!(Test-IsAdministrator)) {
      Write-Warning "This session is running under non-admin privileges.`nPlease restart with admin privileges (run as Administrator) in order to read all logs on the system."
      return
    }
  }

  # Check if Install-ExternalDependencies function exists before calling it
  if (Get-Command Install-ExternalDependencies -ErrorAction SilentlyContinue) {
    Install-ExternalDependencies -PSModule 'pansies' -NoNugetPackages
  }

  $culture = [System.Globalization.CultureInfo]::InvariantCulture
  $Computer = $env:COMPUTERNAME

  function Get-Events {
    [CmdletBinding()]
    param(
      [datetime]$startDateTime,
      [datetime]$endDateTime,
      [string]$ComputerName = $Computer,
      [switch]$ExportToCsv,
      [string]$ExportToCSVPath,
      [string]$TimelineExplorerPath,
      [switch]$ViewInTimelineExplorer
    )

    try {
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
            Write-Verbose $errorMessage
          }
        } -ThrottleLimit 100
      }
      catch {
        Write-Warning "An error occurred: $($_.Exception.Message)"
      }
    

      if ($Events.Count -gt 0) {
        $EventsSorted = $Events | Sort-Object -Property TimeCreated | Select-Object -Property TimeCreated, Id, LogName, LevelDisplayName, Message

        if ($ExportToCsv) {
          $csvpath = Export-EventsToCsv -Events $EventsSorted -ExportFolder $ExportToCSVPath -ComputerName $Computer
          if ($ViewInTimelineExplorer) {
            Open-WithTimelineExplorer -CsvFilePath $csvpath -TimelineExplorerPath $TimelineExplorerPath
            exit
          }
        }
        elseif ($ViewInTimelineExplorer) {
          $csvpath = Export-EventsToCsv -Events $EventsSorted -ExportFolder $ExportToCSVPath -ComputerName $Computer
          Open-WithTimelineExplorer -CsvFilePath $csvpath -TimelineExplorerPath $TimelineExplorerPath
          exit
        }
        else {
          $EventsSorted | Out-GridView -Title 'Events Found'
        }
      }
      else {
        Write-Warning "No events found between $startDateTime and $endDateTime"
      }
    }
    catch {
      Write-Warning "An error occurred while retrieving events:`n$($_.Exception.Message)"
    }
  }

  function Export-EventsToCsv {
    [CmdletBinding()]
    [CmdletBinding()]
    param (
      [object[]]$Events = $EventsSorted,
      [string]$ExportFolder = $PWD.Path,
      [string]$ComputerName = $Computer
    )

    $date = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $filename = "Events_${date}_${ComputerName}.csv" -replace ':', '_' -replace '/', '-'
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
      [string]$CsvFilePath = $fullPath,
      [string]$TimelineExplorerPath = "$ENV:TEMP\TimelineExplorer.exe"
    )

    if ((Test-Path $TimelineExplorerPath) -and (Test-Path $CsvFilePath)) {
      Start-Process -FilePath $TimelineExplorerPath -ArgumentList $CsvFilePath
    }
    elseif (-not (Test-Path $TimelineExplorerPath)) {
      Write-Logg -Message "Timeline Explorer not found at $TimelineExplorerPath" -Level Warning
      Write-Logg -Message 'Downloading now from https://ericzimmerman.github.io/#!index.md' -Level Info
      $downloadUrl = 'https://f001.backblazeb2.com/file/EricZimmermanTools/net6/TimelineExplorer.zip'
      $downloadPath = "$env:TEMP"
      $downloadfile = Get-DownloadFile -Url $downloadUrl -OutFileDirectory $downloadPath -UseAria2
      Write-Logg -Message "Extracting $downloadfile to $env:TEMP" -Level Info
      Expand-Archive -Path $downloadfile -DestinationPath $env:TEMP -Force
      Copy-Item -Path "$env:TEMP\timelineexplorer\TimelineExplorer.exe" -Destination $env:TEMP -Force
      $TimelineExplorerPath = "$env:TEMP\TimelineExplorer.exe"
    }
    # If the csv file doesn't exist, export the events to CSV
    if (-not (Test-Path $CsvFilePath)) {
      Write-Logg -Message 'Windows Event Log CSV not found at creating one now..' -Level Warning
      $exportedCSV = Export-EventsToCsv -Events $EventsSorted -ExportFolder $ExportToCSVPath -ComputerName $Computer
      $fullcsvpath = $(Resolve-Path -Path $exportedCSV).Path
    }

    Write-Logg -Message "Opening $fullcsvpath in Timeline Explorer" -Level Info
    Start-Process -FilePath $TimelineExplorerPath -ArgumentList $CsvFilePath
  }


  $CurrentDate = Get-Date
  $startDateTime = $CurrentDate.AddHours(-1)
  $endDateTime = $CurrentDate

  $xaml = @'
<Window
  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Topmost="True" SizeToContent="Height" Title="Retrieve Events from all Event Logs" Width="525" Height="450">
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

  function Convert-XAMLtoWindow {
    param (
      [Parameter(Mandatory = $true)]
      [string]
      $XAML,

      [string[]]
      $NamedElements,

      [switch]
      $PassThru
    )

    Add-Type -AssemblyName PresentationFramework

    $reader = [System.XML.XMLReader]::Create([System.IO.StringReader]$XAML)
    $result = [System.Windows.Markup.XamlReader]::Load($reader)
    foreach ($Name in $NamedElements) {
      $result | Add-Member -MemberType NoteProperty -Name $Name -Value $result.FindName($Name) -Force
    }

    if ($PassThru) {
      $result
    }
    else {
      $result.ShowDialog() | Out-Null
    }
  }

  $window = Convert-XAMLtoWindow -XAML $xaml -NamedElements 'Retrieve', 'Begin', 'DateBegin', 'DateEnd', 'Time1', 'Time2', 'Begin1', 'End' -PassThru

  $window.DateBegin.SelectedDate = $startDateTime
  $window.DateEnd.SelectedDate = $endDateTime
  $window.Time1.Text = $startDateTime.ToString('HH:mm:ss', $culture)
  $window.Time2.Text = $endDateTime.ToString('HH:mm:ss', $culture)

  $window.Retrieve.Add_Click({
      $startDateTime = Get-Date -Year $window.DateBegin.SelectedDate.Year -Month $window.DateBegin.SelectedDate.Month -Day $window.DateBegin.SelectedDate.Day -Hour $window.Time1.Text.Split(':')[0] -Minute $window.Time1.Text.Split(':')[1] -Second $window.Time1.Text.Split(':')[2]
      $endDateTime = Get-Date -Year $window.DateEnd.SelectedDate.Year -Month $window.DateEnd.SelectedDate.Month -Day $window.DateEnd.SelectedDate.Day -Hour $window.Time2.Text.Split(':')[0] -Minute $window.Time2.Text.Split(':')[1] -Second $window.Time2.Text.Split(':')[2]
      $window.Cursor = [System.Windows.Input.Cursors]::AppStarting
      # Call Get-Events function
      Get-Events -startDateTime $startDateTime -endDateTime $endDateTime -ComputerName $ComputerName -ExportToCsv:$ExportToCsv -ExportToCSVPath $ExportToCSVPath -TimelineExplorerPath $TimelineExplorerPath -ViewInTimelineExplorer:$ViewInTimelineExplorer
      $window.Cursor = [System.Windows.Input.Cursors]::Arrow
    })

  $window.ShowDialog()

  # If ExportToCsv switch is set, call Export-EventsToCsv function
  if ($ExportToCsv) {
    $CsvFilePath = Export-EventsToCsv -Events $EventsSorted -ExportFolder $ExportToCSVPath -ComputerName $ComputerName
  }
  # If ViewInTimelineExplorer switch is set, call Open-WithTimelineExplorer function
  if ($ViewInTimelineExplorer) {
    Open-WithTimelineExplorer -TimelineExplorerPath $TimelineExplorerPath
  }

  # close any dialog boxes and clear memory, the window does not close with $window.Close() so we need to force
  $window.Dispatcher.Invoke([action] { $window.Close() })
  $window.Dispatcher.InvokeShutdown()
  $window = $null
  [GC]::Collect()
  exit
}

# Get-AllEvents -ExportToCsv -ViewInTimelineExplorer -Verbose -ErrorAction Break