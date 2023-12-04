
function Get-CommandlineOptions {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [string]$ExePath
    )


    # Download radare2 from github if it doesn't exist
    if (-not($r2Path = Join-Path -Path $PWD -ChildPath 'radare2-5.8.8-w64' -AdditionalChildPath 'bin', 'radare2.exe' -Resolve)) {
        . "$PSScriptRoot\Get-LatestGitHubRelease.ps1"
        Get-LatestGitHubRelease -OwnerRepository radareorg/radare2 -AssetName '*w64.zip' -DownloadPathDirectory $PWD -ExtractZip
        $r2Path = Join-Path -Path $PWD -ChildPath 'radare2-5.8.8-w64' -AdditionalChildPath 'bin', 'radare2.exe' -Resolve
    }

    # Run radare2 and output the options to a file
    $output = cmd.exe /c "$r2path -file $ExePath "


    $output | ConvertFrom-Json | Select-Object -ExpandProperty opcode | Where-Object { $_ -match '^cmp' } | ForEach-Object { $_.Split(',')[1].Trim() }

    $options | ForEach-Object {
        Write-Output $_
    }
}

