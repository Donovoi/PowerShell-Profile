<#
.SYNOPSIS
    Short description
.DESCRIPTION
    Long description
.EXAMPLE
    Example of how to use this cmdlet
.EXAMPLE
    Another example of how to use this cmdlet
#>
function ConvertFrom-WingetStdout {
    [Alias("cfwo")]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [string[]]$InputObject,
        [string] $DebugCmd = 'upgrade'
    )
    # this is one of Stéphane BARIZIEN's public domain scripts
    # the most recent version can be found at:
    # https://gist.github.com/sba923/7924b726fd44af91d18453ee595e6548

    #requires -version 7

    # This crude script converts the output of the winget.exe executable into an array of PowerShell objects
    # usage: winget <args> | ConvertFrom-WingetStdout.ps1
    #
    # examples of application:
    #
    # 1. Upgrade everything except some apps (e.g. managed by your employer's IT, 
    #    or you know winget doesn't handle them properly yet)
    #
    #    winget upgrade | ConvertFrom-WingetStdout.ps1 | ? { $_.Id -notin ('VideoLAN.VLC', 'Microsoft.Office', 'Kitware.CMake') } | % { winget upgrade --id $_.Id }
    #
    #
    # If this code doesn't work, I dunno who wrote it.
    #
    # Stéphane BARIZIEN <github.nospam4sba@xoxy.net>
    #


    # winget now outputs UTF-8 e.g. for '…' in the 'Available' column, we need to account for this
    [Console]::InputEncoding = [Console]::OutputEncoding = $InputEncoding = $OutputEncoding = [System.Text.Utf8Encoding]::new()
    # get rid of PSSA warning
    $null = $InputEncoding

    $index = 0
    $fieldnames = @()
    $fieldoffsets = @()
    $offset = 0
    $re = ""
    $objcount = 0

    # regex for matching progress information such as
    # ██████████████████▒▒▒▒▒▒▒▒▒▒▒▒  2.00 MB / 3.20 MB
    # ████████████████████████████▒▒  3.00 MB / 3.20 MB
    # ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  0%
    # ΓûêΓûêΓûêΓûêΓûêΓûêΓûêΓûêΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆΓûÆ  1024 KB / 3.49 MB
    # add U+2589..U+258F to account for https://github.com/microsoft/winget-cli/pull/2046
    # 
    # first part of $progress_re within first () is 
    # U+00d4 U+00fb U+00ea U+007c 
    # U+00d4 U+00fb U+00c6 U+007c 
    # U+0393 U+00fb U+00ea U+007c 
    # U+0393 U+00fb U+00c6 U+007c 
    # U+005b U+2588 U+2589 U+258a U+258b U+258c U+258d U+258e U+258f U+2592 U+005d
    $progress_re = '(Ôûê|ÔûÆ|Γûê|ΓûÆ|[█▉▊▋▌▍▎▏▒])+\s+([\d\.]+\s+.B\s+/\s+[\d\.]+\s+.B|[\d\.]+%)'

    # logfile for debugging
    $logfile = Join-Path -Path $env:TEMP -ChildPath ($MyInvocation.MyCommand.Name -replace '\.ps1', '.log')

    # for debugging within VScode
    if ($Host.Name -eq 'Visual Studio Code Host') {
        Write-Debug ("Debugging with output from 'winget {0}'" -f $DebugCmd)
        $data = & winget $DebugCmd
    }
    else {
        $data = $input
    }

    function DumpString([string] $string) {
        $result = "hex: "
        for ($index = 0; $index -lt $string.Length; $index++) {
            $result += ("{0:x2} " -f [int]$string[$index])
        }
        return ($result -replace '\s+$', '')
    }

    foreach ($line in $data) {
        Write-Debug("index={0}, fieldcount={1}, fieldnames={3}, re='{2}'" -f `
                $index, `
                $fieldnames.Count, `
                $re, `
            ($fieldnames -join ':') `
        )
        Write-Debug ("line='{0}'" -f ($line -replace '[\x01-\x1F]', '.'))
        # skip lines before the column headers
        if ($line -notmatch '^\s+\x08' -and $line -notmatch $progress_re -and $line -notmatch '^\s*$') {
            # build regex from line with field names
            if ($index -eq 0) {
                $line0 = $line
                while ($line -ne '') {
                    if ($line -match '^(\S+)(\s+)(.*)') {
                        $fieldnames += $Matches[1]
                        $fieldoffsets += $offset
                        $offset += $Matches[1].Length + $Matches[2].Length
                        $line = $Matches[3]
                    }
                    else {
                        $fieldnames += $line
                        $fieldoffsets += $offset
                        $line = ''
                    }
                }

                $re = '^'
                for ($fieldindex = 0; $fieldindex -lt ($fieldnames.Count - 1); $fieldindex++) {
                    $re += ('(.{{{0},{0}}})' -f ($fieldoffsets[$fieldindex + 1] - $fieldoffsets[$fieldindex]))
                }
                $re += '(.*)'
            }
            # skip separator line
            elseif ($index -eq 1) {
                if ($line -notmatch '^-+$') {
                    if ($line -match $progress_re -or $line0 -match $progress_re) { # progress info, skip and reset index
                        $msg = ("Skipping:`n{0}`n{1}" -f $line0, $line)
                        $msg | Out-File -Encoding utf8BOM -Append -LiteralPath $logfile
                        $index = -1
                    }
                    else {
                        $msg = ("Unexpected input:`n{0}`n{1}" -f $line0, $line)
                        Write-Host -ForegroundColor Red $msg
                        $msg | Out-File -Encoding utf8BOM -Append -LiteralPath $logfile
                        Exit(1)
                    }
                }
            }
            else {
                # if line matches regex, turn into object and output said object to pipeline
                if ($line -match $re) {
                    $obj = New-Object -TypeName PSObject
                    for ($fieldindex = 0; $fieldindex -lt ($Matches.Count - 1); $fieldindex++) {
                        Add-Member -InputObject $obj -MemberType NoteProperty -Name $fieldnames[$fieldindex] -Value ($Matches[$fieldindex + 1] -replace '\s+$', '')
                    }
                    $obj
                    $objcount++
                }
                else {
                    Write-Debug ("Cannot match input based on field names: '{0}' 're='{1}')" -f $line, $re)
                }
            }

            $index++
        }
        else {
            # skip
            Write-Debug ("Skipped '{0}' ({1})" -f ($line -replace '[\x01-\x1F]', '.'), (DumpString -string $line))
        }
    }

    Write-Debug("Output {0} object(s)" -f $objcount)
}