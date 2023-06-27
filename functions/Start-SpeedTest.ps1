function Start-SpeedTest {
    [CmdletBinding()]
    param (
        # The time interval in seconds between each internet speed check. Default is 10 seconds.
        [Parameter(Mandatory = $false)]
        [int]$TimeInterval = 10
    )

    begin {
        # Check if Rust and Cargo are installed
        if (!(Get-Command rustc -ErrorAction SilentlyContinue) -or !(Get-Command cargo -ErrorAction SilentlyContinue)) {
            # Download and install Rust and Cargo
            Invoke-WebRequest -Uri 'https://sh.rustup.rs' -OutFile 'rustup-init.exe'
            Start-Process -FilePath 'rustup-init.exe' -ArgumentList '-y' -Wait
            Remove-Item 'rustup-init.exe'
        }

        # Check if speedtest-rs is installed
        $installedVersion = cargo install --list | Select-String 'speedtest-rs v' | ForEach-Object { $_.ToString().Split(' ')[1].TrimEnd(':') }
        if ($null -eq $installedVersion) {
            # Install speedtest-rs
            cargo install speedtest-rs
        }
        else {
            # TODO: Compare $installedVersion with the latest version and update if necessary
        }
    }

    process {
        while ($true) {
            $speedtest = & speedtest-rs | Out-String
            $downloadSpeed = ($speedtest -split "`n")[1] -replace 'Download: ', '' -replace ' Mbps', ''

            if ([float]$downloadSpeed -lt 5) {
                $app = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]::CreateToastNotifier('PowerShell')
                $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
                $xml = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]::GetTemplateContent($template)
                $textNodes = $xml.GetElementsByTagName('text')
                $textNodes[0].AppendChild($xml.CreateTextNode('Internet Speed Alert'))
                $textNodes[1].AppendChild($xml.CreateTextNode('Your download speed is less than 5 Mbit/s'))
                $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
                $app.Show($toast)
            }

            Start-Sleep -Seconds $TimeInterval
        }
    }
}