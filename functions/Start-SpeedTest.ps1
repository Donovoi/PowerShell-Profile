function Start-SpeedTest {
    [CmdletBinding()]
    param (
        # The time interval in seconds between each internet speed check. Default is 10 seconds.
        [Parameter(Mandatory = $false)]
        [int]$TimeInterval = 300
    )

    begin {
        # Run in a new powershell window so that the script can be stopped with Ctrl+C
        # Once we have opened a new powershell window, we can exit the current one
        Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Start-SpeedTest -TimeInterval 300"'
        Write-Host 'this is a function to check your internet speed and alert you if it is less than 5 Mbit/s'
        Write-Host "the time interval between each check is $TimeInterval seconds"
        Write-Host 'press Ctrl+C to stop the script'
        Write-Host 'you will get a pop up alert if your internet speed is less than 5 Mbit/s'

        # Check if Rust and Cargo are installed
        if (-not(Get-Command cargo -ErrorAction SilentlyContinue)) {
            # Download and install Rust and Cargo
            Invoke-WebRequest -Uri 'https://sh.rustup.rs' -OutFile 'rustup-init.exe'
            Start-Process -FilePath 'rustup-init.exe' -ArgumentList '-y' -Wait
            Remove-Item 'rustup-init.exe'
            cargo install cargo-update
            cargo install speedtest-rs
            cargo install-update -a
        }

        # install and update speedtest
        cargo install speedtest-rs
        cargo install cargo-update
        cargo install-update -a
            
    }



    process {
        while ($true) {
            Write-Host 'Checking internet speed...'
            $speedtest = & speedtest-rs | Out-String
            $downloadSpeed = $speedtest -split "`n" | ForEach-Object { Select-String -InputObject $_ -Pattern "Download`: .*$" }
            $UploadSpeed = $speedtest -split "`n" | ForEach-Object { Select-String -InputObject $_ -Pattern "Upload`: .*$" }
            [float[]]$Speeds = @($downloadSpeed, $UploadSpeed).ForEach{ $_ -match '\d+\.\d+'; [float]$matches[0] }
            Write-Host "Download: $($Speeds[1]) Mbit/s"
            Write-Host "Upload: $($Speeds[3]) Mbit/s"
            if (([float]$Speeds[1] -lt 5) -or ([float]$Speeds[3] -lt 5)) {
                Add-Type -TypeDefinition @'
                using System;
                using System.Runtime.InteropServices;
                
                public static class ToastNotificationInterop
                {
                    [DllImport("user32.dll", CharSet = CharSet.Auto)]
                    public static extern int MessageBox(IntPtr hWnd, String text, String caption, int options);
                }
'@
                
                [ToastNotificationInterop]::MessageBox(0, 'Your download or upload speed is less than 5 Mbit/s', 'Internet Speed Alert', 0)
                # Log the number of times this has happened in a file on the desktop
                $logFile = "$env:USERPROFILE\Desktop\InternetSpeedAlert.txt"
                if (-not(Test-Path $logFile)) {
                    New-Item -Path $logFile -ItemType File
                }
                $log = Get-Content $logFile
                $log += (Get-Date).ToString()
                $log | Out-File $logFile
                # Count how many occurrences of this have happened and append to the log
                $count = $log | Measure-Object | Select-Object -ExpandProperty Count
                $log += "This has happened $count times"
                $log | Out-File $logFile


            }

            Start-Sleep -Seconds $TimeInterval
        }
    }
}
Start-SpeedTest -Verbose