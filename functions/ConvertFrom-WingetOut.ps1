function ConvertFrom-WingetOut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string[]]$InputObject,

        [Parameter(Position = 0, Mandatory = $true)]
        [string]$WCommand,

        [Parameter()]
        [switch]$DebugMode
    )

    begin {
        $startProcessing = $false
        $index = 0
        $fieldnames = @()
        $fieldoffsets = @()
        $offset = 0
        $re = ''
        $objcount = 0
        $progress_re = '(Ôûê|ÔûÆ|Γûê|ΓûÆ|[█▉▊▋▌▍▎▏▒])+\s+([\d\.]+\s+.B\s+/\s+[\d\.]+\s+.B|[\d\.]+%)'
    }

    process {
        foreach ($line in $InputObject) {
            # If the command is 'search' or 'search query', only start processing lines once the 'id' header is encountered
            Add-Type -TypeDefinition @'
using System;
using System.Text.RegularExpressions;

public class TextFilter
{
    public static string[] FilterNonAscii(string[] lines)
    {
        var regex = new Regex(@"^[\\u0000-\\u007F]*$");
        return Array.FindAll(lines, line => regex.IsMatch(line));
    }
}
'@ -Language CSharp

            # Assuming $lines is the array of lines you want to filter
            $asciiLine = [TextFilter]::FilterNonAscii($line)

            if (($WCommand -eq 'search' -or $WCommand -eq 'search query') -and ($line -match '^id') -and ($asciiLine)) {
                $startProcessing = $true
            }
            else {
                continue
            }
        }
        if ($startProcessing) {
            # Skip lines that start with '-' or '\'
            if ($asciiLine -match '^-|^-\\|^\s*-|^\s*-\\') {
                continue
            }
            if ($DebugMode) {
                Write-Debug("index=$index, fieldcount=$($fieldnames.Count), fieldnames=$($fieldnames -join ':'), re='$re'")
                Write-Debug("line='$($line -replace '[\x01-\x1F]', '.')'")
            }

            if ($line -notmatch '^\s+\x08' -and $line -notmatch $progress_re -and $line -notmatch '^\s*$') {
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
                elseif ($index -eq 1) {
                    if ($line -notmatch '^-+$') {
                        if ($line -match $progress_re -or $line0 -match $progress_re) {
                            $index = -1
                        }
                        else {
                            throw "Unexpected input:`n$line0`n$line"
                        }
                    }
                }
                else {
                    if ($line -match $re) {
                        $obj = New-Object -TypeName PSObject
                        for ($fieldindex = 0; $fieldindex -lt ($Matches.Count - 1); $fieldindex++) {
                            Add-Member -InputObject $obj -MemberType NoteProperty -Name $fieldnames[$fieldindex] -Value ($Matches[$fieldindex + 1] -replace '\s+$', '')
                        }
                        $obj
                        $objcount++
                    }
                    else {
                        throw "Cannot match input based on field names: '$line' 're='$re'"
                    }
                }

                $index++
            }
            else {
                if ($DebugMode) {
                    Write-Debug("Skipped '$($line -replace '[\x01-\x1F]', '.')'")
                }
            }
        }
    }

    end {
        if ($DebugMode) {
            Write-Debug("Output $objcount object(s)")
        }
    }
}