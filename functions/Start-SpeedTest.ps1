function Start-SpeedTest {
    [CmdletBinding()]
    param (
        # The time interval in seconds between each internet speed check. Default is 60 seconds.
        [Parameter(Mandatory = $false)]
        [int]$TimeInterval = 60,

        # Enable colorful display of letters
        [switch]$ColorMeSilly
    )

    begin {
        # Define the wrapper function for Write-Host
        function Write-HostColorful {
            param (
                [Parameter(Mandatory = $true)]
                [string]$Message,
                [ConsoleColor]$ForegroundColor = 'White',
                [ConsoleColor]$BackgroundColor = 'Black'
            )

            if ($ColorMeSilly) {
                Write-Host -NoNewline -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor $Message
            }
            else {
                Write-Host $Message
            }
        }

        # Run in a new PowerShell window so that the script can be stopped with Ctrl+C
        # Once we have opened a new PowerShell window, we can exit the current one
        Write-HostColorful -Message 'This is a function to check your internet speed and alert you if it is less than 5 Mbit/s' -ForegroundColor 'Green'
        Write-HostColorful -Message "The time interval between each check is $TimeInterval seconds" -ForegroundColor 'Yellow'
        Write-HostColorful -Message 'Press Ctrl+C to stop the script' -ForegroundColor 'Yellow'
        Write-HostColorful -Message 'You will get a pop-up alert if your internet speed is less than 5 Mbit/s' -ForegroundColor 'Yellow'

        # Check if Rust and Cargo are installed
        if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
            # Download and install Rust and Cargo
            Write-HostColorful -Message 'Checking for Rust and Cargo...' -ForegroundColor 'Cyan'
            Invoke-WebRequest -Uri 'https://sh.rustup.rs' -OutFile 'rustup-init.exe'
            Start-Process -FilePath 'rustup-init.exe' -ArgumentList '-y' -Wait
            Remove-Item 'rustup-init.exe'
            cargo install cargo-update | Out-Null
            cargo install speedtest-rs | Out-Null
            cargo install-update -a | Out-Null
        }

        # Install and update speedtest
        Write-HostColorful -Message 'Checking for updates to speedtest...' -ForegroundColor 'Cyan'
        cargo install speedtest-rs | Out-Null
        cargo install cargo-update | Out-Null
        cargo install-update -a | Out-Null
    }

    process {
        while ($true) {
            Write-HostColorful -Message 'Checking internet speed...' -ForegroundColor 'White'

            
            $speedtest = & speedtest-rs | Out-String
            [regex]$pattern = '(Download|Upload): (\d\d\.\d\d) (\w.+\/s)'
            [float]$downloadSpeed = $pattern.Matches($speedtest) | ForEach-Object { $_.Groups[2].Value } | Select-Object -First 1
            [float]$uploadSpeed = $pattern.Matches($speedtest) | ForEach-Object { $_.Groups[2].Value } | Select-Object -Last 1
            $DLspeedType = $pattern.Matches($speedtest) | ForEach-Object { $_.Groups[3].Value } | Select-Object -Index 0
            $UPspeedType = $pattern.Matches($speedtest) | ForEach-Object { $_.Groups[3].Value } | Select-Object -Index 1

            # Set the background color
            $bgColor = 'White'

            # Convert the download and upload speeds to strings
            $downloadString = "$downloadSpeed $DLspeedType"
            $uploadString = "$uploadSpeed $UPspeedType"

            # Get the length of the download and upload strings
            $downloadLength = $downloadString.Length
            $uploadLength = $uploadString.Length

            if ($ColorMeSilly) {
                # Generate unique color codes for each letter
                $downloadColors = 0..($downloadLength - 1) | ForEach-Object { ($bgColor, 'Black', 'Red', 'Green', 'Blue', 'Yellow')[($_ % 6) + 1] }
                $uploadColors = 0..($uploadLength - 1) | ForEach-Object { ($bgColor, 'Black', 'Red', 'Green', 'Blue', 'Yellow')[($_ % 6) + 1] }

                # Print the download string with colored letters
                $downloadString.ToCharArray() | ForEach-Object {
                    $color = $downloadColors | Get-Random
                    if (($null -eq $color) -or ($color -eq $bgColor)) {
                        $color = 'White'  # Use 'White' as a default color if $color is null or the same as the background color
                    }
                    Write-Host -NoNewline -ForegroundColor $color -BackgroundColor $bgColor $PSItem
                }
                Write-Host ''  # Newline
            }
            
            # Print the upload string with colored letters
            $uploadString.ToCharArray() | ForEach-Object {
                $color = $uploadColors[$PSItem.Index]
                if ($null -eq $color -or $color -eq $bgColor) {
                    $color = 'White'  # Use 'White' as a default color if $color is null or the same as the background color
                }
                Write-Host -NoNewline -ForegroundColor $color -BackgroundColor $bgColor $PSItem
            }
            Write-Host ''  # Newline

            # If the download or upload speed is less than 5 Mbit/s, alert the user
            if ([float]$downloadSpeed -lt 5 -or [float]$uploadSpeed -lt 5) {
                Write-Host 'Your download or upload speed is less than 5 Mbit/s' -ForegroundColor 'Red'
                Add-Type -TypeDefinition @'
                using System;
                using System.Runtime.InteropServices;

                public static class ToastNotificationInterop
                {
                    [DllImport("user32.dll", CharSet = CharSet.Auto)]
                    public static extern int MessageBox(IntPtr hWnd, string text, string caption, int options);
                }
'@

                [ToastNotificationInterop]::MessageBox(0, 'Your download or upload speed is less than 5 Mbit/s', 'Internet Speed Alert', 0)
            }

            # Count down the time until the next check
            $progress = $TimeInterval
            do {
                $status = "Next check in $progress seconds"
                Write-Progress -Activity 'Internet Speed Check' -Status $status -SecondsRemaining $progress
                Start-Sleep -Seconds 1
                $progress--
            } while ($progress -gt 0)

            # Clear the progress bar
            Write-Progress -Activity 'Internet Speed Check' -Completed
        }
    }
}
