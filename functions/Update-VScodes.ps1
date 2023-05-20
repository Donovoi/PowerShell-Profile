function Update-VScodes {
  [CmdletBinding()]
  param(
  )
  process {
      Write-Host -Object "Script is running as $($MyInvocation.MyCommand.Name)" -Verbose
      $Global:XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter

      $Urls = @(
          @{
              URL             = 'https://code.visualstudio.com/sha/download?build=insider&os=win32-x64-archive'
              OutFile         = "$ENV:USERPROFILE\downloads\insiders.zip"
              DestinationPath = "$XWAYSUSB\vscode-insider\"
          },
          @{
              URL             = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
              OutFile         = "$ENV:USERPROFILE\downloads\vscode.zip"
              DestinationPath = "$XWAYSUSB\vscode\"
          }
      )

      function Download-UrlToFile {
          [CmdletBinding()]
          param([string]$url, [string]$outputPath)
          $httpClient = New-Object System.Net.Http.HttpClient
          $response = $httpClient.GetAsync($url).Result
          $response.EnsureSuccessStatusCode()
          [System.IO.File]::WriteAllBytes($outputPath, $response.Content.ReadAsByteArrayAsync().Result)
      }

      $funcDef = ${function:Download-UrlToFile}.ToString()

      $Urls | ForEach-Object -Parallel {
          ${function:Download-UrlToFile} = $using:funcDef
          try {
              Download-UrlToFile -Url $_.URL -OutputPath $_.OutFile
              Write-Progress -Activity "Downloading and extracting" -Status $_.OutFile
              Expand-Archive $_.OutFile -DestinationPath $_.DestinationPath -Force -Verbose
          } catch {
              Write-Error -Message "Error occurred: $($_.Exception.Message)" -ErrorAction Continue
          }
      }
  }
}
