function Start-BitsTransferAndShowProgress {
    param(
        [PSCustomObject]$url
    )
    try {
        Restart-Service -Name BITS -Force
        Get-BitsTransfer | Remove-BitsTransfer 

        $job = Start-BitsTransfer -Source $url.URL -Destination $url.OutFile -Asynchronous

        Set-BitsTransfer -BitsJob $job -Priority High

        $previousTransferred = 0
        $previousTime = Get-Date

        while (($job.JobState -eq 'Transferring') -or ($job.JobState -eq 'Connecting')) {
            $percentageCompleted = [math]::Round((($job.BytesTransferred / $job.BytesTotal) * 100), 2)
            $currentTime = Get-Date
            $timeTaken = ($currentTime - $previousTime).TotalSeconds
            $currentSpeed = [math]::Round(($job.BytesTransferred - $previousTransferred) / $timeTaken, 2)
            $previousTransferred = $job.BytesTransferred
            $previousTime = $currentTime
            $currentSpeedStr = Format-Bytes -Bytes $currentSpeed
            $totalDownloadedStr = Format-Bytes -Bytes $job.BytesTransferred
            Write-Progress -Activity 'Downloading file' -Status "$percentageCompleted% Completed" -PercentComplete $percentageCompleted -Id 1
            Write-Progress -Activity ' ' -Status "Speed: $currentSpeedStr/second, TotalDownloaded: $totalDownloadedStr" -Id 2

            Start-Sleep -Seconds 1
        }    

        if ($job.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $job
            Clear-Host
        }
        Write-Host "Downloaded $($url.OutFile)"

    }
    catch {
        Write-Error -Message "Error occurred: $($_.Exception.Message)" -ErrorAction Continue
    }
}

function Update-VSCode {
    [CmdletBinding()]
    param(
        [ValidateSet('stable', 'insider')]
        [string]$Version = 'both'
    )
    process {
        Write-Host "Script is running as $($MyInvocation.MyCommand.Name)" 

        $drive = Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'"
        if ($drive) {
            $global:XWAYSUSB = $drive.DriveLetter
        }
        else {
            Write-Error 'X-Ways USB drive not found.'
            return
        }

        $urls = @(
            @{
                Version         = 'stable'
                URL             = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
                OutFile         = "$ENV:USERPROFILE\downloads\vscode.zip"
                DestinationPath = "$XWAYSUSB\vscode\"
            },
            @{
                Version         = 'insider'
                URL             = 'https://code.visualstudio.com/sha/download?build=insider&os=win32-x64-archive'
                OutFile         = "$ENV:USERPROFILE\downloads\insiders.zip"
                DestinationPath = "$XWAYSUSB\vscode-insider\"
            }
        )

        if ($Version -eq 'both') {
            foreach ($url in $urls) {
                Start-BitsTransferAndShowProgress -url $url
            }
        }
        elseif ($urls.Version -contains $Version) {
            $url = $urls | Where-Object { $_.Version -eq $Version }
            Start-BitsTransferAndShowProgress -url $url
        }
        else {
            Write-Error "Invalid version specified. Please choose 'stable', 'insider', or 'both'."
            return
        }
        Write-Progress -Activity 'Extracting' -Status $url.OutFile
        Expand-Archive -Path $url.OutFile -DestinationPath $url.DestinationPath -Force 
        
    }
}

Function Format-Bytes {
    param([double]$bytes)
    switch ($bytes) {
        { $_ -gt 1PB } {
            '{0:0.00} PB' -f ($bytes / 1PB); break 
        }
        { $_ -gt 1TB } {
            '{0:0.00} TB' -f ($bytes / 1TB); break 
        }
        { $_ -gt 1GB } {
            '{0:0.00} GB' -f ($bytes / 1GB); break 
        }
        { $_ -gt 1MB } {
            '{0:0.00} MB' -f ($bytes / 1MB); break 
        }
        { $_ -gt 1KB } {
            '{0:0.00} KB' -f ($bytes / 1KB); break 
        }
        Default {
            '{0:0.00} B' -f $bytes 
        }
    }
}