<#
.SYNOPSIS
    Downloads a file using BITS (Background Intelligent Transfer Service) and shows the download progress.

.DESCRIPTION
    This function downloads a file from a specified URL using BITS (Background Intelligent Transfer Service)
    and shows the download progress in the console. The progress is displayed as a percentage of the total download completed,
    the current download speed, and the total amount downloaded.

.PARAMETER URL
    The URL of the file to download.

.PARAMETER OutFile
    The path and filename to save the downloaded file.

.EXAMPLE
    Start-BitsTransferAndShowProgress -URL "https://example.com/file.zip" -OutFile "C:\Downloads\file.zip"
    Downloads the file from the specified URL and saves it to the specified path while showing the download progress.
#>
function Start-BitsTransferAndShowProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$URL,
        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )
    try {
        Restart-Service -Name BITS -Force
        Get-BitsTransfer | Remove-BitsTransfer 

        $job = Start-BitsTransfer -Source $URL -Destination $OutFile -Asynchronous

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
        Write-Logg -Message "Downloaded $OutFile"

    }
    catch {
        Write-Error -Message "Error occurred: $($_.Exception.Message)" -ErrorAction Continue
    }
}