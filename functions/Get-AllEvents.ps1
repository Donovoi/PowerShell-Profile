function Get-AllEvents {
  param (
    [CmdletBinding()]
    [Parameter(
      ValueFromPipeline = $True,
      ValueFromPipelineByPropertyName = $True,
      HelpMessage = 'Enter one or more hosts'
    )]
    [Alias('ComputerName', 'MachineName', 'Server', 'Host')]
    [switch]$ExportToCsv,
    [string]$ExportToCSVPath = '.'
  )

  if (!(Test-IsAdministrator)) {
    Write-Warning "This session is running under non-admin privileges.`nPlease restart with admin privileges (run as Administrator) in order to read all logs on the system."
    return
  }

  $culture = [System.Globalization.CultureInfo]::InvariantCulture
  $Computer = $env:COMPUTERNAME

  function Get-Events {
    param(
      [Parameter(Mandatory = $true, HelpMessage = 'Please enter the full start date and time')]
      [Alias('BeginDate', 'BeginTime', 'StartDate')]
      [datetime]$StartTime,
      [Parameter(Mandatory = $true, HelpMessage = 'Please enter the full end date and time')]
      [Alias('EndDate')]
      [datetime]$EndTime
    )

    try {
      $EventLogs = Get-WinEvent -ListLog * -ErrorVariable err -ea 0
      $err | ForEach-Object -Process {
        $warnmessage = $_.exception.message -replace '.*about the ', ''
        Write-Warning $warnmessage
      }

      $Events = foreach ($log in $EventLogs) {
        $Percentage = [Array]::IndexOf($EventLogs, $log) / $EventLogs.Count

        Write-Progress -Activity "Retrieving events from Logs ($($EventLogs.IndexOf($log) + 1) of $($EventLogs.Count))" -PercentComplete ($Percentage * 100) -CurrentOperation $log.LogName -Status 'Processing ...'

        Get-WinEvent -FilterHashtable @{
          logname   = $log.LogName
          StartTime = $StartTime
          EndTime   = $EndTime
        } -ea 0
      }

      if ($Events.Count -gt 0) {
        $EventsSorted = $Events |
          Sort-Object -Property TimeCreated |
            Select-Object -Property TimeCreated, Id, LogName, LevelDisplayName, Message

        Write-Progress -Activity 'Almost there' -PercentComplete 100 -CurrentOperation 'Generating gridview output data ...' -Completed -Status 'Done'

        if ($ExportToCsv) {
          if (!(Test-Path $ExportToCSVPath)) {
            Write-Error "$ExportToCSVPath doesn't exist, re-run script ..."
            return
          }
          
          $date = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
          $filename = "Events_$date`_$Computer.csv" -replace ':', '_'
          $filename = $filename -replace '/', '-'
          $EventsSorted | Export-Csv (Join-Path $ExportToCSVPath $filename) -NoTypeInformation
        }
        else {
          try {
            $EventsSorted | Out-GridView -Title 'Events Found'
          }
          catch {
            Write-Warning "Error using the Out-GridView cmdlet, use the '$EventsSorted' variable to see all found events sorted on date and time. Or use the -ExportToCSV parameter with this script's function to export the results to CSV."
            Write-Warning $_.Exception.Message
          }
        }
      }
      else {
        Write-Warning "No events found between $StartTime and $EndTime"
      }
    }
    catch {
      Write-Warning "An error occurred while retrieving events:`n$($_.Exception.Message)"
    }
  }

  function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
      Get-Events -StartTime $startDateTime -EndTime $endDateTime
      $window.Cursor = [System.Windows.Input.Cursors]::Arrow
    })

  $window.ShowDialog()

  Write-Log -Message 'TIP: Use the $EventsSorted variable to interact with the results yourself.'
}