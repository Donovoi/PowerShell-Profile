<#
.SYNOPSIS
Performs a sector-level copy of an NTFS file by reading its disk extents
directly and writing them to a destination file.

.DESCRIPTION
Invoke-RawCopy is intended for low-level forensics, backup, or migration
scenarios where a byte-for-byte clone of a file is required.  
It uses NtObjectManager to enumerate NTFS retrieval pointers, can create a
VSS snapshot to avoid “file in use” issues, and supports sparse regions so
holes are preserved without allocating unnecessary disk space.

The cmdlet:
• Validates parameters and loads NtObjectManager on demand.  
• Optionally creates a VSS snapshot of the source volume (default).  
• Reads each logical cluster (LCN) run with un-buffered IO respecting physical
  sector size.  
• Writes to the destination file, optionally overwriting an existing file.  
• Displays real-time progress, ETA, and enforces a user-selectable buffer size.  

.PARAMETER Path
Absolute path to the source file.  
Must exist and reference a regular file.

.PARAMETER Destination
Absolute path (including filename) for the output file.  
If the file exists, specify ‑Overwrite to replace it.

.PARAMETER Overwrite
Switch. Allow overwriting an existing destination file.

.PARAMETER DisableVss
Switch. Skip creation of a Volume Shadow Copy snapshot and access the source
file directly. Use when VSS is unavailable or not required.

.PARAMETER BufferSizeKB
Size of the in-memory transfer buffer in kilobytes (default 64 KB, range
4-40960). Must be a multiple of the underlying physical sector size.

.EXAMPLE
Invoke-RawCopy -Path 'C:\Images\disk.img' -Destination 'D:\Backups\disk.img'

Creates a VSS snapshot of C:\, then copies disk.img sector-by-sector to the
backup location.

.EXAMPLE
Invoke-RawCopy -Path 'C:\db\database.mdf' -Destination '\\Server\Share\database.mdf' `
               -BufferSizeKB 256 -Overwrite -DisableVss

Copies the database file using a 256 KB buffer, overwriting any existing file
at the destination and bypassing VSS.

.INPUTS
None. Parameters are provided by value.

.OUTPUTS
None. Produces a file at the destination path and progress output.

.NOTES
Author : Unknown (profile function)  
Requires: NtObjectManager 2.0.1 or later, Windows Vista+ with PowerShell 5.1+.  
The cmdlet must run with sufficient privileges to create VSS snapshots and
perform raw disk reads.

.LINK
Get-Help
#>
function Invoke-RawCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Mandatory, Position = 1)]
        [string]$Destination,

        [switch]$Overwrite,
        [switch]$DisableVss,
        [ValidateRange(4, 40960)][int]$BufferSizeKB = 64
    )

    # ────────── prerequisites ──────────
    if (-not (Get-Module -ListAvailable -Name NtObjectManager)) {
        Install-Module NtObjectManager -RequiredVersion 2.0.1 -Scope CurrentUser -Force
    }
    Import-Module NtObjectManager -ErrorAction Stop
    Set-StrictMode -Version Latest

    # ────────── helpers ──────────
    function New-VssSnapshot($VolumeRoot) {
        $cl = [wmiclass]'Win32_ShadowCopy'
        $r = $cl.Create($VolumeRoot, 'ClientAccessible')
        if ($r.ReturnValue) {
            throw "VSS create failed: $($r.ReturnValue)" 
        }
        Get-CimInstance Win32_ShadowCopy -Filter "ID='$($r.ShadowID)'"
    }
    function Remove-VssSnapshot($Shadow) {
        if ($Shadow) {
            $Shadow | Remove-CimInstance 
        }
    }
    function Get-NtfsExtents([NtCoreLib.NtFile]$File) {
        $ctl = Get-NtIoControlCode 0x90073   # FSCTL_GET_RETRIEVAL_POINTERS
        $bufSz = 64KB
        $STATUS_BUFFER_OVERFLOW = 0x80000005
        $STATUS_END_OF_FILE = 0xC0000011
        $ext = @(); [UInt64]$vcn = 0; $more = $false
        do {
            $in = [BitConverter]::GetBytes($vcn)
            $status = 0; $out = $null
            try {
                $out = Send-NtFileControl -File $File -ControlCode $ctl -Input $in -OutputLength $bufSz
            }
            catch [NtApiDotNet.NtException] {
                $status = $_.Exception.Status
                if ($status -eq $STATUS_BUFFER_OVERFLOW) {
                    $out = $_.Exception.OutputBuffer
                }
                elseif ($status -eq $STATUS_END_OF_FILE) {
                    break
                }
                else {
                    throw 
                }
            }
            if (-not $out) {
                break 
            }
            $pin = [Runtime.InteropServices.GCHandle]::Alloc($out, 'Pinned')
            try {
                $count = [BitConverter]::ToUInt32($out, 0)
                if (-not $count) {
                    break 
                }
                $start = [BitConverter]::ToUInt64($out, 4)
                $ofs = 12
                for ($i = 0; $i -lt $count; $i++) {
                    $next = [BitConverter]::ToUInt64($out, $ofs)
                    $lcn = [BitConverter]::ToUInt64($out, $ofs + 8)
                    $len = $next - ($i ? $ext[-1].NextVcn : $start)
                    $ext += [pscustomobject]@{ NextVcn = $next; Lcn = $lcn; ClusterCount = $len }
                    $ofs += 16
                }
                $vcn = $ext[-1].NextVcn
            }
            finally {
                if ($pin.IsAllocated) {
                    $pin.Free() 
                } 
            }
        } while ($status -eq $STATUS_BUFFER_OVERFLOW)
        return $ext
    }

    # ────────── main ──────────
    if ((Test-Path $Destination) -and (-not $Overwrite)) {
        throw 'Destination exists - use -Overwrite.'
    }

    $volRoot = ([IO.Path]::GetPathRoot((Resolve-Path $Path))).TrimEnd('\') + '\'
    $drive = $volRoot[0]
    $clusterSize = (Get-Volume -DriveLetter $drive).AllocationUnitSize
    $logicalSizeBytes = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive`:'").Size

    # physical sector size
    $sectorSize = 4096
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive`:'" |
            Get-CimAssociatedInstance -ResultClassName Win32_DiskPartition |
                Get-CimAssociatedInstance -ResultClassName Win32_DiskDrive | Select-Object -First 1
        if ($disk -and $disk.BytesPerSector) {
            $sectorSize = [int]$disk.BytesPerSector 
        }
        else {
            # Fallback to using Get-PhysicalDisk if available (Windows 8+)
            try {
                $physicalDisk = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $disk.Index } | Select-Object -First 1
                if ($physicalDisk -and $physicalDisk.PhysicalSectorSize) {
                    $sectorSize = [int]$physicalDisk.PhysicalSectorSize
                }
                elseif ($physicalDisk -and $physicalDisk.LogicalSectorSize) {
                    $sectorSize = [int]$physicalDisk.LogicalSectorSize
                }
            }
            catch {
                Write-Verbose 'Get-PhysicalDisk not available, using default sector size'
            }
        }
    }
    catch {
        Write-Warning "Failed to determine physical sector size for $volRoot. Using default $sectorSize bytes." 
        Write-Warning "$_.Exception.Message"
    }

    # snapshot
    $shadow = $null; $srcPath = $Path; $volDevice = "\\.\$drive`:"
    if (-not $DisableVss) {
        Write-Verbose "Creating VSS snapshot of $volRoot"
        $shadow = New-VssSnapshot $volRoot
        $volDevice = $shadow.DeviceObject.TrimEnd('\\')
        $srcPath = $Path -replace '^[A-Za-z]:', $volDevice
    }

    # handles
    $srcFile = Get-NtFile -Win32Path $srcPath -Access ReadData -ShareMode All
    $extents = Get-NtfsExtents $srcFile
    $total = ($extents | Measure-Object ClusterCount -Sum).Sum * $clusterSize

    $bufSize = $BufferSizeKB * 1KB
    if ($bufSize % $sectorSize) {
        throw "BufferSizeKB must be a multiple of $sectorSize bytes." 
    }

    $buffer = [byte[]]::new($bufSize)
    $volNt = Get-NtFile -Win32Path $volDevice -Access ReadData -ShareMode All -Options 'NoIntermediateBuffering,SequentialOnly'
    $vol = [System.IO.FileStream]::new($volNt.Handle, [System.IO.FileAccess]::Read)
    $dest = [IO.File]::Open($Destination, 'Create', 'ReadWrite', 'None')

    try {
        [UInt64]$copied = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        
        # Get the actual file size to avoid setting length too large
        $actualFileSize = (Get-Item $Path).Length
        
        foreach ($e in $extents) {
            # skip sparse run or nonsense extents beyond disk size
            $extentBytes = [UInt64]$e.ClusterCount * [UInt64]$clusterSize
            if ($e.Lcn -eq [UInt64]::MaxValue -or (($e.Lcn * [UInt64]$clusterSize) + $extentBytes -gt [UInt64]$logicalSizeBytes)) {
                # For sparse runs, seek forward but don't exceed actual file size
                $newPosition = [Math]::Min([Int64]($dest.Position + $extentBytes), [Int64]$actualFileSize)
                $dest.Seek($newPosition, 'Begin') | Out-Null
                $copied += $extentBytes
                continue
            }

            $offset = [UInt64]$e.Lcn * [UInt64]$clusterSize
            $vol.Seek([Int64]$offset, 'Begin') | Out-Null
            [UInt64]$remaining = $extentBytes
            while ($remaining -gt 0) {
                $chunk = [UInt64][Math]::Min($bufSize, ($remaining / $sectorSize) * $sectorSize)
                if ($chunk -eq 0) {
                    $chunk = $sectorSize 
                }
                $r = $vol.Read($buffer, 0, [int]$chunk)
                if ($r -eq 0) {
                    throw "Unexpected EOF at LCN $($e.Lcn)" 
                }
                $dest.Write($buffer, 0, $r)
                $copied += $r; $remaining -= [UInt64]$r
                $pct = [Math]::Round(($copied / $total) * 100, 2)
                $eta = if ($copied) {
                    ($total - $copied) / ($copied / $sw.Elapsed.TotalSeconds) 
                }
                else {
                    0 
                }
                Write-Progress -Activity 'RawCopy' -Status "$pct %" -PercentComplete $pct -SecondsRemaining $eta
            }
        }
        
        # Set the final file length to match the original file
        $dest.SetLength([Int64]$actualFileSize)
        Write-Progress -Activity 'RawCopy' -Completed -Status 'Copy complete' -PercentComplete 100
        Write-Output 'Copy complete'
        Write-Output "Destination File is: $Destination"
    }
    finally {
        $dest.Dispose(); $vol.Dispose(); $srcFile.Dispose(); if ($shadow) {
            Remove-VssSnapshot $shadow 
        }
    }
}
