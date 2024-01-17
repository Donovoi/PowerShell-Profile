function Invoke-RemoveItem {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Path
    )

    begin {
        # Check if the file is removable and if not, try to make it removable
        $Path | ForEach-Object {
            if (-not (Test-IsRemovable -Path $_)) {
                Set-Removable -Path $_
            }
        }
    }

    process {
        # Attempt to remove the file
        $Path | ForEach-Object {
            if (Test-IsRemovable -Path $_) {
                Remove-Item $_ -ErrorAction Stop
            }
            else {
                Write-Error "Failed to remove the file: $_"
            }
        }
    }
}

function Test-IsRemovable {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        Remove-Item $Path -WhatIf -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Set-Removable {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($PSCmdlet.ShouldProcess($Path, 'Take ownership and grant full control')) {
        try {
            takeown /f $Path
            icacls $Path /grant "${env:USERNAME}`:(F)"
        }
        catch {
            Write-Error "Failed to make the file removable: $($_.Exception.Message)"
        }
    }
}