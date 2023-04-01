
function Get-AllEvents {
  param(
    [CmdletBinding()]
    [Parameter(ValueFromPipeline = $True,ValueFromPipelineByPropertyName = $True,HelpMessage = 'Enter the one or more hosts')]
    [Alias('ComputerName','MachineName','Server','Host')]
    [switch]$ExportToCsv,
    [string]$ExportToCSVPath = '.'
  )
  #requires -version 2
  if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    Write-Warning -Message "This session is running under non-admin priviliges.`nPlease restart with Admin priviliges (runas Administrator) in order to read all logs on the system." -Debug
  } # end if admin check

  $culture = [System.Globalization.CultureInfo]::InvariantCulture
  $Computer = $env:COMPUTERNAME

  function Convert-XAMLtoWindow {
    param
    (
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
    $result = [System.Windows.Markup.XAMLReader]::Load($reader)
    foreach ($Name in $NamedElements) {
      $result | Add-Member -MemberType NoteProperty -Name $Name -Value $result.FindName($Name) -Force
    }

    if ($PassThru) {
      $result
    }
    else {
      $result.ShowDialog()
    }
  }

  function Get-Events {
    param(
      [Parameter(Mandatory = $true,HelpMessage = 'Please enter the full start date and time')]
      [Alias('BeginDate','BeginTime','StartDate')]
      [ValidateScript({
          (Get-Date $_)
        })]
      [datetime]$StartTime,
      [Parameter(Mandatory = $true,HelpMessage = 'Please enter the full end date and time')]
      [Alias('EndDate')]
      [ValidateScript({
          (Get-Date $_)
        })]
      [datetime]$EndTime
    )

    $EventLogs = Get-WinEvent -ListLog * -ErrorVariable err -ea 0
    $err | ForEach-Object -Process {
      $warnmessage = $_.exception.message -replace '.*about the ',''
      Write-Warning -Message $warnmessage
    }

    $Count = $EventLogs.Count

    $Events = $EventLogs |

    ForEach-Object -Process {
      $LogName = $_.logname
      $Index = [array]::IndexOf($EventLogs,$_)
      $Percentage = $Index / $Count
      $Message = "Retrieving events from Logs ($Index of $Count)"

      Write-Progress -Activity $Message -PercentComplete ($Percentage * 100) -CurrentOperation $LogName -Status 'Processing ...'

      Get-WinEvent -FilterHashtable @{
        logname = $LogName
        StartTime = $StartTime
        EndTime = $EndTime
      } -ea 0
    }

    if ($Events) {

      $Global:EventsSorted = $Events |
      Sort-Object -Property timecreated |
      Select-Object -Property timecreated,id,logname,leveldisplayname,message

      Write-Progress -Activity 'Almost there' -PercentComplete 100 -CurrentOperation 'Generating gridview output data ...' -Completed -Status 'Done'

      if ($ExportToCsv) {

        $exists = Test-Path $ExportToCSVPath

        if (!$exists) {
          Write-Error "$ExportToCSVPath doesn't exist, re-run script ..."
        }
        else {
          $date = Get-Date
          $filename = "Events_$date`_$Computer.csv" -replace ':','_'
          $filename = $filename -replace '/','-'
          $EventsSorted | Export-Csv ($ExportToCSVPath + '\' + $Filename) -NoTypeInformation -Verbose
        }
      }
      else {

        try {
          $EventsSorted |
          Out-GridView -Title 'Events Found'
        }
        catch {
          Write-Warning 'Error using the ''Out-GridView'' cmdlet, use the ''$EventsSorted'' variable to see all found events sorted on date and time. Or use the -ExportToCSV parameter with this script to Export the results to CSV'
          write-ouput ''
          Write-Warning $_.exception.message
          break
        }
      } # end if exporttocsv 


    }
    else {
      Write-Warning -Message "`n`n`nNo events found between $StartTime and $EndTime"
    }
  } # end function

  if ($PSVersionTable.psversion.major -lt 3) {
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')

    $objForm = New-Object -TypeName System.Windows.Forms.Form
    $objForm.Text = 'Retrieve All Events'
    $objForm.Size = New-Object -TypeName System.Drawing.Size -ArgumentList (525,300)
    $objForm.StartPosition = 'CenterScreen'

    $objForm.KeyPreview = $true
    $objForm.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
          $x = $objTextBox.Text
          $objForm.Close()
        }
      })
    $objForm.Add_KeyDown({
        if ($_.KeyCode -eq 'Escape') {
          $objForm.Close()
        }
      })

    $RetrieveButton = New-Object -TypeName System.Windows.Forms.Button
    $RetrieveButton.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (200,216)
    $RetrieveButton.Size = New-Object -TypeName System.Drawing.Size -ArgumentList (80,25)
    $RetrieveButton.Text = 'Retrieve'
    $RetrieveButton.Add_Click({
        $timevalue1 = $objTextBox3 -split ' '
        $datevalue1 = $objLabel -split ' '
        $global:date1 = $datevalue1[2] + ' ' + $timevalue1[3]

        $timevalue2 = $objTextBox4 -split ' '
        $datevalue2 = $objLabel2 -split ' '
        $global:date2 = $datevalue2[2] + ' ' + $timevalue2[3]

        $StartTime = Get-Date $date1
        $EndTime = Get-Date $date2

        Get-Events -StartTime $StartTime -EndTime $EndTime
      })

    $objForm.Controls.Add($RetrieveButton)

    $CurrentDate = Get-Date

    $Time2 = $CurrentDate
    $Time1 = ($CurrentDate).addhours(-1)

    $objLabel = New-Object -TypeName System.Windows.Forms.DateTimePicker
    $objLabel.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (12,80)
    $objForm.Controls.Add($objLabel)

    $objLabel2 = New-Object -TypeName System.Windows.Forms.DateTimePicker
    $objLabel2.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (250,80)
    $objForm.Controls.Add($objLabel2)

    $objTextBox1 = New-Object -TypeName System.Windows.Forms.label
    $objTextBox1.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (100,40)
    $objTextBox1.Text = 'Start'
    $objForm.Controls.Add($objTextBox1)

    $objTextBox2 = New-Object -TypeName System.Windows.Forms.label
    $objTextBox2.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (350,40)
    $objTextBox2.Text = 'End'
    $objForm.Controls.Add($objTextBox2)

    $objTextBox3 = New-Object -TypeName System.Windows.Forms.DateTimePicker
    $objTextBox3.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (12,100)
    $objTextBox3.Size = New-Object -TypeName System.Drawing.Size -ArgumentList (90,20)
    $objTextBox3.Format = 'Time'
    $objTextBox3.ShowUpDown = $true
    $objTextBox3.Text = $Time1
    $objForm.Controls.Add($objTextBox3)

    $objTextBox4 = New-Object -TypeName System.Windows.Forms.DateTimePicker
    $objTextBox4.Location = New-Object -TypeName System.Drawing.Size -ArgumentList (250,100)
    $objTextBox4.Size = New-Object -TypeName System.Drawing.Size -ArgumentList (90,20)
    $objTextBox4.Format = 'Time'
    $objTextBox4.ShowUpDown = $true
    $objTextBox4.Text = $Time2
    $objForm.Controls.Add($objTextBox4)

    $objForm.Topmost = $true

    $objForm.Add_Shown({
        $objForm.Activate()
      })
    [void]$objForm.ShowDialog()
  }
  else {
    $XAML = @'
<Window 
  xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
  xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
  Topmost="True" SizeToContent="Height"
  Title="Retrieve Events from all Event Logs"  Width="525" Height="450">
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
        <Button x:Name="Retrieve" Width="80" Height="25" 
			Margin="0,50,216,30" VerticalAlignment="Bottom" 
			HorizontalAlignment="Right" Content="Retrieve" Grid.Row="2"/>
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

    $window = Convert-XAMLtoWindow -XAML $XAML -NamedElements 'Retrieve','Begin','DateBegin','DateEnd','Time1','Time2','Begin1','End' -Passthru


    # $window.Retrieve.Add_MouseEnter(
    #   {
    #     $window.Cursor = [System.Windows.Input.Cursors]::Hand
    #   }
    # )

    # $window.Retrieve.Add_MouseLeave(
    #   {
    #     $window.Cursor = [System.Windows.Input.Cursors]::Arrow
    #   }
    # )

    $window.Retrieve.Add_Click(
      {
        $global:time1 = $window.Time1.Text
        $global:time2 = $window.Time2.Text
        $global:date1 = $window.Time1.Text
        $global:date2 = $window.Time2.Text
        $window.Cursor = [System.Windows.Input.Cursors]::AppStarting
        Get-Events -StartTime $date1 -EndTime $date2
        $window.Cursor = [System.Windows.Input.Cursors]::Arrow
        [System.Object]$sender = $args[0]
        [System.Windows.RoutedEventArgs]$e = $args[1]
      }
    )


    $CurrentDate = Get-Date
    $window.DateBegin.add_Loaded(
      {
        $window.DateBegin.SelectedDate = $CurrentDate
        $window.DateEnd.SelectedDate = $CurrentDate
        $window.Time2.Text = $CurrentDate.ToString('HH:mm:ss')
        $window.Time1.Text = ($CurrentDate).addhours(-1).ToString('HH:mm:ss')
        [System.Object]$sender = $args[0]
        [System.Windows.RoutedEventArgs]$e = $args[1]
      }
    )

    $window.ShowDialog()
  } # end if PowerShell version check

  Write-Host 'TIP: Use the $EventsSorted variable to interact with the results yourself.'
}

