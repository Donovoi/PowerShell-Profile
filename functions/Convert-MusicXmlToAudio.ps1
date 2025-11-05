function Convert-MusicXmlToAudio {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)]
        [Alias('FullName')]
        [string]$Path,

        [string]$OutDir = (Join-Path (Split-Path -Parent $Path) 'audio-out'),

        [ValidateSet('wav', 'mp3', 'flac', 'ogg', 'mid', 'midi')]
        [string[]]$Format = @('wav'),

        # If not set, auto-discover MS4 first, then MS3
        [string]$MuseScorePath,

        # MP3 bitrate (applies when mp3 requested)
        [ValidateRange(32, 320)]
        [int]$Bitrate = 192,

        [switch]$Force,
        [switch]$PassThru
    )

    begin {
        function _Find-MuseScore {
            param([string]$Hint)
            if ($Hint -and (Get-Command $Hint -ErrorAction SilentlyContinue)) {
                return $Hint 
            }
            $candidates = @(
                # MS4 / Studio
                'C:\Program Files\MuseScore 4\MuseScore4.exe',
                'C:\Program Files\MuseScore 4\bin\MuseScore4.exe',
                'C:\Program Files\MuseScore 4\MuseScoreStudio.exe',
                # MS3
                'C:\Program Files\MuseScore 3\MuseScore3.exe',
                'C:\Program Files (x86)\MuseScore 3\bin\MuseScore3.exe',
                # PATH fallbacks
                'musescore', 'mscore', 'musescore4', 'mscore4portable', 'MuseScore4.exe', 'MuseScore3.exe'
            )
            foreach ($c in $candidates) {
                if (Get-Command $c -ErrorAction SilentlyContinue) {
                    return (Get-Command $c).Source 
                } 
            }
            return $null
        }

        function _Ensure-OutDir([string]$p) {
            if (-not (Test-Path $p)) {
                New-Item -ItemType Directory -Force -Path $p | Out-Null 
            }
        }

        function _Unzip-Mxl-ToMusicXml {
            param([string]$mxlPath, [string]$tmpDir)
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($mxlPath)
            try {
                $entry = $zip.Entries | Where-Object { $_.FullName -match '\.musicxml$' -or $_.FullName -match '\.xml$' } | Select-Object -First 1
                if (-not $entry) {
                    return $null 
                }
                $out = Join-Path $tmpDir ([IO.Path]::GetFileNameWithoutExtension($mxlPath) + '.musicxml')
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $out, $true)
                return $out
            }
            finally {
                $zip.Dispose() 
            }
        }

        function _Run-Job {
            param(
                [string]$Exe, [string]$JobJson, [string]$LogFile, [int]$MP3kbps
            )
            $args = @()
            if ($MP3kbps) {
                $args += @('-b', $MP3kbps) 
            }  # MS manual: -b sets mp3 bitrate
            $args += @('-j', $JobJson)
            $output = & $Exe @args *>&1
            $exit = $LASTEXITCODE
            $output | Out-File -FilePath $LogFile -Encoding UTF8
            return $exit
        }
    }

    process {
        $in = (Resolve-Path $Path).Path
        if (-not (Test-Path $in)) {
            throw "Input not found: $in" 
        }
        _Ensure-OutDir $OutDir

        # Normalize format set
        $fmt = @()
        foreach ($f in $Format) {
            $fmt += ($f -split '\s*,\s*') 
        }
        $fmt = $fmt | ForEach-Object { if ($_ -ieq 'midi') {
                'mid' 
            }
            else {
                $_.ToLower() 
            } } | Select-Object -Unique

        $baseName = [IO.Path]::GetFileNameWithoutExtension($in)
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $runDir = Join-Path $OutDir (".musescore-run-$($baseName)-$stamp")
        _Ensure-OutDir $runDir

        # Decide which executable(s) to try
        $pref = _Find-MuseScore -Hint $MuseScorePath
        $fallback = $null
        if (-not $pref) {
            throw 'MuseScore not found. Install MuseScore 4 or 3, or pass -MuseScorePath.' 
        }
        # If preferred is MS4, also look for MS3 as fallback
        if ($pref -match 'MuseScore4' -or $pref -match 'MuseScoreStudio') {
            $fb = _Find-MuseScore -Hint 'MuseScore3.exe'
            if ($fb) {
                $fallback = $fb 
            }
        }

        # Build outputs
        $outs = @()
        foreach ($ext in $fmt) {
            $of = Join-Path $OutDir "$baseName.$ext"
            if ((Test-Path $of) -and -not $Force) {
                throw "Output exists: $of (use -Force to overwrite)"
            }
            $outs += $of
        }

        # Build a JSON job (MS handbook: -j expects a JSON array with {in,out} and out can be an array) 
        # This lets us generate multiple formats in one pass.
        $job = @(@{ in = $in; out = $outs })
        $jobPath = Join-Path $runDir 'job.json'
        $job | ConvertTo-Json -Depth 5 | Set-Content -Path $jobPath -Encoding UTF8

        # Try 1: run with preferred MuseScore
        $log1 = Join-Path $runDir 'musescore-run.pref.log'
        $exit1 = _Run-Job -Exe $pref -JobJson $jobPath -LogFile $log1 -MP3kbps ($(if ($fmt -contains 'mp3') {
                    $Bitrate 
                }
                else {
                    0 
                }))
        # Validate outputs
        $ok = $true
        foreach ($of in $outs) {
            if (-not (Test-Path $of) -or ((Get-Item $of).Length -eq 0)) {
                $ok = $false 
            } 
        }

        # If failed and input is .mxl, try unzipping to .musicxml and re-run
        if (-not $ok -and $in -match '\.mxl$') {
            $xmlIn = _Unzip-Mxl-ToMusicXml -mxlPath $in -tmpDir $runDir
            if ($xmlIn) {
                $job = @(@{ in = $xmlIn; out = $outs })
                $job | ConvertTo-Json -Depth 5 | Set-Content -Path $jobPath -Encoding UTF8
                $log2 = Join-Path $runDir 'musescore-run.pref.unzipped.log'
                $exit1 = _Run-Job -Exe $pref -JobJson $jobPath -LogFile $log2 -MP3kbps ($(if ($fmt -contains 'mp3') {
                            $Bitrate 
                        }
                        else {
                            0 
                        }))
                $ok = $true
                foreach ($of in $outs) {
                    if (-not (Test-Path $of) -or ((Get-Item $of).Length -eq 0)) {
                        $ok = $false 
                    } 
                }
            }
        }

        # If still failed and we have MS3, try fallback
        if (-not $ok -and $fallback) {
            $log3 = Join-Path $runDir 'musescore-run.fb-ms3.log'
            $exit2 = _Run-Job -Exe $fallback -JobJson $jobPath -LogFile $log3 -MP3kbps ($(if ($fmt -contains 'mp3') {
                        $Bitrate 
                    }
                    else {
                        0 
                    }))
            $ok = $true
            foreach ($of in $outs) {
                if (-not (Test-Path $of) -or ((Get-Item $of).Length -eq 0)) {
                    $ok = $false 
                } 
            }
        }

        if (-not $ok) {
            $tail = @()
            foreach ($lf in @($log1, $log2, $log3) | Where-Object { $_ }) {
                if (Test-Path $lf) {
                    $tail += "`n===== $([IO.Path]::GetFileName($lf)) ====="
                    $tail += (Get-Content $lf -Tail 60)
                }
            }
            $tailTxt = ($tail -join "`n")
            $hint = 'MuseScore CLI converts with -o/-j and infers type by extension; MS4 docs warn not all options work, and job JSON supports multi-output. See handbook.' 
            throw "MuseScore returned success but outputs were missing/empty.`n$hint`nLogs:$tailTxt"
        }

        if ($PassThru) {
            return ($outs | Get-Item | Sort-Object LastWriteTime -Descending | Select-Object FullName, Length, LastWriteTime)
        }
        else {
            foreach ($f in $outs) {
                Write-Host "Created: $f" 
            }
            Write-Host "Logs: $runDir"
        }
    }
}
