function Start-SpeedTest {    
    [CmdletBinding()]
    param (
        [Parameter()]
        [timespan]
        $TimeInterval = [TimeSpan]::FromSeconds(60),
        [Parameter()]
        [switch] 
        $ColorMeSilly,
        [Parameter()]
        [switch]
        $NoRust
        
    )

    # install pswritecolor module
    if (-not (Get-Module -Name PSWriteColor -ListAvailable)) {
        Install-Module -Name PSWriteColor -Scope CurrentUser -Force
    }
    Import-Module PSWriteColor -Force -InformationAction SilentlyContinue -ProgressAction SilentlyContinue

    # Check if Rust and Cargo are installed
    if (-not(Get-Command cargo -ErrorAction SilentlyContinue)) {
        # Download and install Rust and Cargo
        Invoke-WebRequest -Uri 'https://sh.rustup.rs' -OutFile 'rustup-init.exe'
        Start-Process -FilePath 'rustup-init.exe' -ArgumentList '-y' -Wait
        Remove-Item 'rustup-init.exe'
    }
    
    # Check if speedtest-rs is installed
    $installedVersion = cargo install --list | Select-String 'speedtest-rs v' | ForEach-Object { $_.ToString().Split(' ')[1].TrimEnd(':') }
    if ($null -eq $installedVersion) {
        # Install speedtest-rs 
        cargo install cargo-update
        cargo install speedtest-rs
        cargo install-update -a
    }

    while ($true) {
        # Run the speed test
        $speedtest = speedtest-rs

        # Extract the download and upload speeds from the speedtest output
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
            $downloadColors = 0..($downloadLength - 1) | ForEach-Object { Get-Random -Minimum 0 -Maximum 16 }
            $uploadColors = 0..($uploadLength - 1) | ForEach-Object { Get-Random -Minimum 0 -Maximum 16 }

            # Print the download string with colored letters
            $downloadString.ToCharArray() | ForEach-Object {
                $color = $downloadColors
                $randomcolor = Get-Random $downloadColors
                if ($color -eq $bgColor) {
                    $color = 'White'  # Use 'White' as a default color if $color is the same as the background color
                }
                $coloredChar = Write-Color -ForegroundColor $randomcolor -BackGroundColor $bgColor -NoNewLine
                Write-Output $coloredChar
            }
            Write-Output ''  # Newline
        }

        # Print the upload string with colored letters
        $uploadString.ToCharArray() | ForEach-Object {
            $color = $uploadColors
            if ($color -eq $bgColor) {
                $color = 'White'  # Use 'White' as a default color if $color is the same as the background color
            }
            $coloredChar = $_ | Write-Color -ForegroundColor $color -BackGroundColor $bgColor -NoNewLine
            Write-Output $coloredChar
        }
        Write-Output ''  # Newline

        # If the download or upload speed is less than 5 Mbit/s, alert the user
        if ([float]$downloadSpeed -lt 5 -or [float]$uploadSpeed -lt 5) {
            Write-Output 'Speed Alert' | Write-Color -ForegroundColor 'Red'
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

# Start-SpeedTest -ColorMeSilly -Verbose