function Convert-MusicXmlToAudio {
    [CmdletBinding()]
    param(
        # Path to .mxl / .musicxml / .xml / .mscz / etc.
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)]
        [Alias('FullName')]
        [string]$Path,

        # Where to drop the rendered audio/MIDI
        [string]$OutDir = (Join-Path (Split-Path -Parent $Path) 'audio-out'),

        # One or more targets: wav, mp3, flac, ogg, mid, midi
        [ValidateSet('wav', 'mp3', 'flac', 'ogg', 'mid', 'midi')]
        [string[]]$Format = @('wav'),

        # Explicit path to MuseScore4/Studio/3 executable (if not on PATH)
        [string]$MuseScorePath,

        # MP3 bitrate (MuseScore supports -b/--bitrate)
        [ValidateRange(32, 320)]
        [int]$Bitrate = 192,

        # Overwrite existing outputs
        [switch]$Force,

        # Return objects (paths, exe, logs, codes)
        [switch]$PassThru
    )

    begin {
        # Auto-discover MuseScore if not provided
        if (-not $MuseScorePath) {
            $candidates = @(
                'C:\Program Files\MuseScore 4\bin\MuseScore4.exe',
                'C:\Program Files\MuseScore 4\MuseScoreStudio.exe',
                'C:\Program Files\MuseScore 4\MuseScore4.exe',
                'C:\Program Files\MuseScore 3\bin\MuseScore3.exe',
                'C:\Program Files\MuseScore 3\MuseScore3.exe',
                'C:\Program Files\MuseScore\MuseScore.exe',
                'C:\Program Files\MuseScore\bin\MuseScore.exe',
                'mscore.exe',   # on PATH (Linux/mac), still fine on Win if present
                'musescore'     # on PATH
            )
            $MuseScorePath = $candidates | Where-Object { $_ -and (Get-Command $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
        }
        if (-not $MuseScorePath) {
            throw "Could not find MuseScore. Set -MuseScorePath (e.g. 'C:\Program Files\MuseScore 4\bin\MuseScore4.exe')." 
        }
    }

    process {
        $inFile = (Resolve-Path $Path).Path
        if (-not (Test-Path $inFile)) {
            throw "Input file '$inFile' not found." 
        }

        if (-not (Test-Path $OutDir)) {
            New-Item -ItemType Directory -Path $OutDir | Out-Null 
        }

        $baseName = [IO.Path]::GetFileNameWithoutExtension($inFile)

        # Flatten formats in case someone passes "midi,mp3" as a single token
        $fmtList = @()
        foreach ($f in $Format) {
            $fmtList += ($f -split '\s*,\s*') 
        }
        $fmtList = $fmtList | Where-Object { $_ }

        $results = @()

        foreach ($fmt in $fmtList) {
            $ext = if ($fmt -ieq 'midi') {
                'mid' 
            }
            else {
                $fmt.ToLower() 
            }
            $outFile = Join-Path $OutDir "$baseName.$ext"
            $logFile = Join-Path $OutDir "$baseName.musescore-export.$ext.log"

            if ((Test-Path $outFile) -and -not $Force) {
                throw "Output exists: $outFile. Use -Force to overwrite."
            }

            # Build argument list. MuseScore infers type from the -o filename’s extension.
            $argList = @()
            if ($ext -eq 'mp3' -and $Bitrate) {
                $argList += @('-b', $Bitrate) 
            }   # MP3 bitrate
            $argList += @('-o', $outFile, $inFile)                                # converter mode
            # Docs: -o/--export-to selects format by extension; -b sets MP3 bitrate. 

            Write-Verbose ('[MuseScore] {0}' -f $MuseScorePath)
            Write-Verbose ('Args: {0}' -f ($argList -join ' '))

            # Run and tee output to per-format log
            $output = & $MuseScorePath @argList *>&1
            $exitCode = $LASTEXITCODE
            $output | Out-File -FilePath $logFile -Encoding UTF8

            if ($exitCode -ne 0) {
                throw "MuseScore export to .$ext failed with exit code $exitCode. See $logFile" 
            }
            if (-not (Test-Path $outFile) -or ((Get-Item $outFile).Length -eq 0)) {
                throw "MuseScore reported success but '$outFile' is missing/empty. See $logFile"
            }

            if ($PassThru) {
                $results += [PSCustomObject]@{
                    InputScore   = $inFile
                    OutputFile   = $outFile
                    Format       = $ext
                    Log          = $logFile
                    ExitCode     = $exitCode
                    MuseScoreExe = $MuseScorePath
                }
            }
            else {
                Write-Host ('Created: {0}' -f $outFile)
                Write-Host ('  Log  : {0}' -f $logFile)
            }
        }

        if ($PassThru) {
            return $results 
        }
    }
}
