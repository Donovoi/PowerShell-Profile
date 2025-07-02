<#
  Invoke-RawCopy.ps1 - NtObjectManager-only, VSS-aware raw copier
  Tested NTFS on Win 10/11, NtObjectManager 1.1.32 → 2.0.1
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
    # —————————————————  prerequisites  —————————————————
    #  install module NtObjectManager if not available
    if (-not (Get-Module -ListAvailable -Name NtObjectManager)) {
        $moduleName = 'NtObjectManager'
        $moduleVersion = '2.0.1'
        Write-Verbose "Installing module $moduleName version $moduleVersion"
        Install-Module -Name $moduleName -RequiredVersion $moduleVersion -Scope CurrentUser -Force
    }
    #  import module
    Import-Module NtObjectManager -Force -ErrorAction Stop

    Set-StrictMode -Version Latest

    # ————— helpers —————
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

        # Build input buffer: STARTING_VCN_INPUT_BUFFER{ULONGLONG StartingVcn=0}
        $in = New-Object byte[] 8        # all zeros → VCN 0
        # build the control-code object once
        $CtlGetRetrieval = Get-NtIoControlCode 0x90073     # FSCTL_GET_RETRIEVAL_POINTERS
        $out = Send-NtFileControl -File $File -ControlCode $CtlGetRetrieval -Input $in -OutputLength 65536

        # Pin & parse RETRIEVAL_POINTERS_BUFFER
        $pin = [Runtime.InteropServices.GCHandle]::Alloc($out, 'Pinned')
        try {
            $base = $pin.AddrOfPinnedObject()
            $count = [BitConverter]::ToUInt32($out, 0)            # ExtentCount
            $firstV = [BitConverter]::ToUInt64($out, 4)            # StartingVCN
            $ofs = 12                                         # first EXTENT
            $ext = @()
            for ($i = 0; $i -lt $count; $i++) {
                $next = [BitConverter]::ToUInt64($out, $ofs)
                $lcn = [BitConverter]::ToUInt64($out, $ofs + 8)
                $len = $next - ($i ? $ext[$i - 1].NextVcn : $firstV)
                $ext += [pscustomobject]@{NextVcn = $next; Lcn = $lcn; ClusterCount = $len }
                $ofs += 16
            }
            $ext
        }
        finally {
            if ($pin.IsAllocated) {
                $pin.Free() 
            } 
        }
    }

    # ————— main —————
    if ((Test-Path $Destination) -and (-not $Overwrite)) {
        throw 'Destination exists - use -Overwrite.'
    }

    $volRoot = ([IO.Path]::GetPathRoot((Resolve-Path $Path))).TrimEnd('\') + '\'
    $clusterSize = (Get-Volume -DriveLetter $volRoot[0]).AllocationUnitSize  # bytes/cluster

    # snapshot (optional)
    $shadow = $null
    $srcPath = $Path
    $volDevice = "\\.\$($volRoot[0]):"
    if (-not $DisableVss) {
        Write-Verbose "Creating VSS snapshot of $volRoot"
        $shadow = New-VssSnapshot $volRoot
        $volDevice = $shadow.DeviceObject.TrimEnd('\')
        $srcPath = $Path -replace '^[A-Za-z]:', $volDevice
    }

    # open handles
    $srcFile = Get-NtFile -Win32Path $srcPath -Access ReadData -ShareMode All
    $extents = Get-NtfsExtents $srcFile
    $total = ($extents | Measure-Object ClusterCount -Sum).Sum * $clusterSize

    $bufSize = $BufferSizeKB * 1KB
    if ($bufSize % 4096) {
        throw 'BufferSizeKB must be 4-KB aligned.' 
    }
    $buffer = New-Object byte[] $bufSize
    $volNt = Get-NtFile -Win32Path $volDevice `
        -Access ReadData `
        -ShareMode All `
        -Options 'NoIntermediateBuffering,SequentialOnly'

    # create a synchronous FileStream over that handle
    $vol = [System.IO.FileStream]::new( $volNt.Handle, [System.IO.FileAccess]::Read)                       # synchronous; use $true for async                 
    $dest = [IO.File]::Open($Destination, 'Create', 'Write', 'None')

    # copy loop with progress
    try {
        $copied = 0L; $sw = [Diagnostics.Stopwatch]::StartNew()
        foreach ($e in $extents) {
            [System.Int128]$offset = $($e.Lcn * $clusterSize)
            [System.Int128]$remaining = $($e.ClusterCount * $clusterSize)
            $vol.Seek($offset, 'Begin') > $null
            while ($remaining) {
                $n = [Math]::Min([long]$bufSize, [long]$remaining)
                $r = $vol.Read($buffer, 0, $n)
                if ($r -eq 0) {
                    throw 'Disk read failed.' 
                }
                $dest.Write($buffer, 0, $r)
                $copied += $r
                $remaining -= $r
                # progress
                $pct = [Math]::Round(($copied / $total) * 100, 2)
                $eta = if ($copied) {
                    ($total - $copied) / ($copied / $sw.Elapsed.TotalSeconds) 
                }
                else {
                    0
                }
                Write-Progress -Activity 'RawCopy' -Status "$pct %" `
                    -PercentComplete $pct -SecondsRemaining $eta
            }
        }
        Write-Progress -Activity 'RawCopy' -Completed
    }
    finally {
        $dest.Dispose(); $vol.Dispose(); $srcFile.Dispose()
        if ($shadow) {
            Remove-VssSnapshot $shadow 
        }
    }
}