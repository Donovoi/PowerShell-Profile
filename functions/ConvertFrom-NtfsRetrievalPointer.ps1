function ConvertFrom-NtfsRetrievalPointer {
    <#
    .SYNOPSIS
    Decodes a validated Windows RETRIEVAL_POINTERS_BUFFER into signed extents.
    .DESCRIPTION
    ExtentCount is at byte 0; aligned StartingVcn is at byte 8; extents start at 16.
    Lcn=-1 denotes an unallocated/compressed region, not an out-of-range recovery.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][byte[]]$Buffer,[ValidateRange(0,[long]::MaxValue)][long]$ExpectedStartingVcn=0)
    if($Buffer.Length -lt 16){throw 'Truncated retrieval-pointer header.'}
    $count=[BitConverter]::ToUInt32($Buffer,0)
    if($count -gt [Math]::Floor(($Buffer.Length-16)/16)){throw 'Truncated retrieval-pointer extent array.'}
    $start=[BitConverter]::ToInt64($Buffer,8)
    if($start -ne $ExpectedStartingVcn){throw 'Unexpected retrieval-pointer starting VCN.'}
    for($index=0;$index -lt $count;$index++){
        $offset=16+16*$index
        $next=[BitConverter]::ToInt64($Buffer,$offset)
        $lcn=[BitConverter]::ToInt64($Buffer,$offset+8)
        if($next -le $start -or $lcn -lt -1){throw 'Invalid or non-progressing NTFS extent.'}
        [pscustomobject]@{StartingVcn=$start;NextVcn=$next;Lcn=$lcn;ClusterCount=($next-$start)}
        $start=$next
    }
}
