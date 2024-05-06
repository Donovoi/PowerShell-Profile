function Invoke-DockerSnapshot {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$ContainerName,

        [Parameter(Mandatory=$true)]
        [string]$VolumeName,

        [Parameter(Mandatory=$true)]
        [string]$BackupDirectory,

        [Parameter(Mandatory=$false)]
        [int]$SnapshotIntervalMinutes = 10
    )

    while ($true) {
        # Generate timestamped identifiers
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $imageName = "$ContainerName-snapshot_$timestamp"
        $backupPath = Join-Path -Path $BackupDirectory -ChildPath "$VolumeName-$timestamp.tar"

        try {
            # Commit the container to an image
            docker commit $ContainerName $imageName
            Write-Host "Container $ContainerName committed as image $imageName"

            # Backup the volume
            docker run --rm --volume $VolumeName:/volume --volume $BackupDirectory:/backup ubuntu tar cvf /backup/$backupPath /volume
            Write-Host "Volume $VolumeName backed up to $backupPath"

            # Cleanup previous backups and images if the current backup is successful
            Get-ChildItem -Path $BackupDirectory -Filter "$VolumeName-*.tar" |
                Sort-Object -Property Name |
                Select-Object -SkipLast 1 |
                Remove-Item -Force

            # Optionally, remove old images based on naming convention or other criteria
            # This part is left as an exercise or can be customized based on specific needs

        } catch {
            Write-Host "An error occurred: $_"
        }

        Start-Sleep -Seconds ($SnapshotIntervalMinutes * 60)
    }
}
#Invoke-DockerSnapshot -ContainerName "myContainer" -VolumeName "myVolume" -BackupDirectory "C:\DockerBackups"
