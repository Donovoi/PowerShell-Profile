
function Get-NetworkSpeedTest {
  [CmdletBinding()]
  param(
    [Parameter()]
    [switch]
    $SendEmail
  )
  #https://www.speedtest.net/apps/cli
  Clear-Host

  $DownloadURL = 'https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip'
  #location to save on the computer. Path must exist or it will error
  $DOwnloadPath = "$ENV:USERPROFILE\Documents\SpeedTest.Zip"
  $ExtractToPath = "$ENV:USERPROFILE\Documents\SpeedTest"
  $SpeedTestEXEPath = "$ENV:USERPROFILE\Documents\SpeedTest\speedtest.exe"
  #Log File Path
  $LogPath = "$ENV:USERPROFILE\Documents\SpeedTestLog.txt"

  #Start Logging to a Text File
  $ErrorActionPreference = 'SilentlyContinue'
  Stop-Transcript | Out-Null
  $ErrorActionPreference = 'Continue'
  Start-Transcript -Path $LogPath -Append:$false
  #check for and delete existing log files
  if (Test-Path $LogPath) {
    Remove-Item $LogPath -Force
  }

  function RunTest () {
    $test = & $SpeedTestEXEPath --accept-license
    $test
  }

  #check if file exists
  if (Test-Path $SpeedTestEXEPath -PathType leaf) {
    Write-Host 'SpeedTest EXE Exists, starting test' -ForegroundColor Green
    RunTest
  }
  else {
    Write-Host "SpeedTest EXE Doesn't Exist, starting file download"

    #downloads the file from the URL
    Invoke-WebRequest -Uri $DownloadURL -OutFile $DownloadPath

    #Unzip the file
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function Unzip {
      param([string]$zipfile,[string]$outpath)

      [System.IO.Compression.ZipFile]::ExtractToDirectory($zipfile,$outpath)
    }

    Unzip $DOwnloadPath $ExtractToPath
    RunTest
  }

  #Send Email if requested
  if ($SendEmail) {
    function sendMail ($subject,$message) {
      'Sending Email'

      #SMTP server name
      $smtpServer = 'smtp.office365.com'
      $EmailSender = 'noreply@yourdomain.com'
      $emailPassword = 'password123_or_monkey'
      $port = '587'
      $from = 'noreply@yourdomain.com'
      $to = 'you@yourdomain.com'

      #Creating a Mail object
      $msg = New-Object Net.Mail.MailMessage

      $emailCredential = New-Object System.Net.NetworkCredential ($EmailSender,$emailPassword)

      #Creating SMTP server object
      $smtp = New-Object Net.Mail.SmtpClient ($smtpServer)
      $smtp.Port = $port

      $smtp.EnableSSl = $true
      $smtp.Credentials = $emailCredential

      #Email structure
      $msg.From = $from
      $msg.To.Add($to)
      $msg.subject = $subject
      $msg.body = $message

      #Sending email
      $smtp.Send($msg)

      Write-Host 'Email Sent' -ForegroundColor Green

    }
    #get hostname
    $Hostname = hostname

    #read results out of log file into string
    $MailMessage = (Get-Content -Path $LogPath) -join "`n"

    #email results use log file string as body
    $MailSubject = $Hostname + ' SpeedTest Results'
    sendMail $MailSubject $MailMessage

  }

  #stop logging
  Stop-Transcript
  exit 0
}
# Get-NetworkSpeedTest

