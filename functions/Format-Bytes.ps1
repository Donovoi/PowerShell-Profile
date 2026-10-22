<#
.SYNOPSIS
    Formats a byte value into a human-readable string.
.DESCRIPTION
    This function takes a byte value and formats it into a human-readable string with the appropriate
    unit (B, KB, MB, GB, TB, or PB).
.PARAMETER bytes
    The byte value to format.
.EXAMPLE
    PS C:\> Format-Bytes 1234567890
    1.15 GB
#>
Function Format-Bytes {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ $_ -ge 0 -and -not [double]::IsInfinity($_) -and -not [double]::IsNaN($_) })]
        [double]$bytes
    )
    switch ($bytes) {
        { $_ -ge 1PB } {
            '{0:0.00} PB' -f ($bytes / 1PB); break
        }
        { $_ -ge 1TB } {
            '{0:0.00} TB' -f ($bytes / 1TB); break
        }
        { $_ -ge 1GB } {
            '{0:0.00} GB' -f ($bytes / 1GB); break
        }
        { $_ -ge 1MB } {
            '{0:0.00} MB' -f ($bytes / 1MB); break
        }
        { $_ -ge 1KB } {
            '{0:0.00} KB' -f ($bytes / 1KB); break
        }
        Default {
            '{0:0.00} B' -f $bytes
        }
    }
}