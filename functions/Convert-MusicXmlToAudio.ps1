function Convert-MusicXmlToAudio {
    [CmdletBinding()]
    param(
        # Path to .mxl / .musicxml / .xml / .mscz / etc.
        [Parameter(Mandatory=$true,
                   ValueFromPipeline=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=0)]
        [Alias('FullName')]
        [string]$Path,

        # Where to drop the rendered audio/MIDI
        [Parameter()]
        [string]$OutDir = (Join-Path (Split-Path -Parent $Path) 'audio-out'),

        # What to make: wav, mp3, flac, ogg, mid, midi
        [Parameter()]
        [ValidateSet('wav','mp3','flac','ogg','mid','midi')]
        [string]$Format = 'wav',

        # Explicit path to MuseScore4.exe / MuseScore3.exe / mscore.exe
        [Parameter()]
        [string]$MuseScorePath,

        # Overwrite existing output?
        [switch]$Force,

        # Return info object at the end
        [switch]$PassThru
    )

    begin {
        # Try to auto-discover MuseScore if not provided.
        if (-not $MuseScorePath) {
            $candidates = @(
                "C:\Program Files\MuseScore 4\bin\MuseScore4.exe",
                "C:\Program Files\MuseScore 4\MuseScore4.exe",
                "C:\Program Files\MuseScore 4\MuseScoreStudio.exe",
                "C:\Program Files\MuseScore 3\bin\MuseScore3.exe",
                "C:\Program Files\MuseScore 3\MuseScore3.exe",
                "C:\Program Files\MuseScore\MuseScore.exe",
                "C:\Program Files\MuseScore\bin\MuseScore.exe",
                "mscore.exe"  # if it's already on PATH
            )
            $MuseScorePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        }

        if (-not $MuseScorePath -or -not (Test-Path $MuseScorePath)) {
            throw "Could not find MuseScore. Set -MuseScorePath 'C:\Program Files\MuseScore 4\bin\MuseScore4.exe'."
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

        # Normalize extension: treat "midi" as "mid"
        $targetExt = if ($Format -ieq 'midi') { 'mid' } else { $Format.ToLower() }
        $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($inFile)
        $outFile   = Join-Path $OutDir "$baseName.$targetExt"
        $logFile   = Join-Path $OutDir "$baseName.musescore-export.log"

        if ((Test-Path $outFile) -and -not $Force) {
            throw "Output '$outFile' already exists. Use -Force to overwrite."
        }

        # Build MuseScore args.
        # MuseScore CLI supports "-o / --export-to <outfile>" and will infer format from extension.
        # Then we pass the input file.
        $argList = @('-o', $outFile, $inFile)

        Write-Verbose ("[MuseScore] {0}`nArgs: {1}" -f $MuseScorePath, ($argList -join ' '))

        # Launch MuseScore in "converter mode" (no GUI) and capture stdout/stderr.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $MuseScorePath
        foreach ($a in $argList) { [void]$psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()

        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $logContent = "STDOUT:`r`n$stdout`r`n`r`nSTDERR:`r`n$stderr"
        Set-Content -Path $logFile -Value $logContent

        $exitCode = $proc.ExitCode
        if ($exitCode -ne 0) {
            throw "MuseScore export failed with exit code $exitCode. See $logFile"
        }

        if (-not (Test-Path $outFile) -or ((Get-Item $outFile).Length -eq 0)) {
            throw "MuseScore reported success but '$outFile' is missing or empty. Check $logFile"
        }

        if ($PassThru) {
            [PSCustomObject]@{
                InputScore   = $inFile
                OutputFile   = $outFile
                Format       = $targetExt
                Log          = $logFile
                ExitCode     = $exitCode
                MuseScoreExe = $MuseScorePath
            }
        }
    }
}
