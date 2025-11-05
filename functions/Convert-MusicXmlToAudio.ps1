function Convert-MusicXmlToAudio {
    <#
.SYNOPSIS
Headless conversion of .mxl/.musicxml/.xml/.mscz to WAV/MP3/OGG/FLAC/MID using MuseScore.
Falls back to FluidSynth+FFmpeg only when MuseScore doesn’t emit audio.

.DESCRIPTION
- Primary path: one MuseScore “converter mode” run per requested format:
    MuseScore.exe -w -f -o <outfile> <infile>
  (‘-o’ switches to converter mode and avoids the GUI; format inferred by extension.)  [MS docs]
- Fallback path (only if a requested audio file is missing/empty):
    export MIDI via MuseScore → render WAV with FluidSynth (-F, -r) → encode MP3/OGG/FLAC via FFmpeg.

.PARAMETER Path
Input score (.mxl, .musicxml, .xml, .mscz, .mscx, .mid).

.PARAMETER OutDir
Destination directory (created if missing).

.PARAMETER Format
One or more of: wav, mp3, flac, ogg, mid, midi.

.PARAMETER MuseScorePath
Optional explicit path to MuseScore4/MuseScore Studio/MuseScore3 executable.

.PARAMETER SoundProfile
MuseScore sound profile override (MuseScore Basic | Muse Sounds).

.PARAMETER SoundFont
Optional .sf2/.sf3 for FluidSynth fallback.

.PARAMETER FluidSynthPath
Optional path to fluidsynth.exe (fallback only).

.PARAMETER FFmpegPath
Optional path to ffmpeg.exe (fallback only).

.PARAMETER SampleRate
Sample rate for FluidSynth/FFmpeg fallback (default 44100).

.PARAMETER BitrateKbps
MP3 bitrate for FFmpeg fallback (default 256).

.PARAMETER Force
Overwrite outputs if present.

.PARAMETER PassThru
Return an object describing the run.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [string]$OutDir = $(Join-Path (Split-Path -Parent $Path) 'audio-out'),

        [ValidateSet('wav', 'mp3', 'flac', 'ogg', 'mid', 'midi')]
        [string[]]$Format = @('wav'),

        [string]$MuseScorePath,

        [ValidateSet('MuseScore Basic', 'Muse Sounds')]
        [string]$SoundProfile,

        [string]$SoundFont,
        [string]$FluidSynthPath,
        [string]$FFmpegPath,

        [int]$SampleRate = 44100,
        [int]$BitrateKbps = 256,

        [switch]$Force,
        [switch]$PassThru
    )

    begin {
        function Resolve-Exe([string[]]$Candidates) {
            foreach ($c in $Candidates) {
                if (-not $c) {
                    continue 
                }
                try {
                    $cmd = Get-Command $c -ErrorAction Stop
                    if ($cmd -and (Test-Path $cmd.Source)) {
                        return $cmd.Source 
                    }
                }
                catch { 
                }
                if (Test-Path $c) {
                    return (Resolve-Path $c).Path 
                }
            }
            return $null
        }
        function New-Dir($p) {
            if (-not (Test-Path $p)) {
                New-Item -ItemType Directory -Force -Path $p | Out-Null 
            } 
        }

        function Invoke-Process($exe, [string[]]$arguments, $stdoutPath, $stderrPath, $envExtra = @{}) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            foreach ($a in $arguments) {
                [void]$psi.ArgumentList.Add($a) 
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            foreach ($k in $envExtra.Keys) {
                $psi.Environment[$k] = $envExtra[$k] 
            }
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.WaitForExit()
            $out = $p.StandardOutput.ReadToEnd()
            $err = $p.StandardError.ReadToEnd()
            if ($stdoutPath) {
                Set-Content -Path $stdoutPath -Value $out -Encoding UTF8 
            }
            if ($stderrPath) {
                Set-Content -Path $stderrPath -Value $err -Encoding UTF8 
            }
            return $p.ExitCode
        }

        function Expand-MxlToMusicXml {
            param([string]$MxlPath, [string]$WorkDir)
            New-Dir $WorkDir
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($MxlPath, $WorkDir, $true)
            $container = Join-Path $WorkDir 'META-INF\container.xml'
            if (Test-Path $container) {
                [xml]$cx = Get-Content -LiteralPath $container
                $root = $cx.container.rootfiles.rootfile.'full-path'
                if ($root) {
                    $rootPath = Join-Path $WorkDir $root
                    if (Test-Path $rootPath) {
                        return (Resolve-Path $rootPath).Path 
                    }
                }
            }
            $cand = Get-ChildItem -LiteralPath $WorkDir -Recurse -Include *.musicxml, *.xml -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($cand) {
                return (Resolve-Path $cand.FullName).Path 
            }
            throw 'Could not locate MusicXML inside MXL.'
        }

        if (-not $MuseScorePath) {
            $MuseScorePath = Resolve-Exe @(
                'C:\Program Files\MuseScore Studio 4\bin\MuseScoreStudio.exe',
                'C:\Program Files\MuseScore 4\bin\MuseScore4.exe',
                'C:\Program Files\MuseScore 3\bin\MuseScore3.exe',
                'MuseScoreStudio.exe', 'MuseScore4.exe', 'MuseScore3.exe', 'mscore.exe'
            )
        }
        if (-not $MuseScorePath) {
            throw 'MuseScore executable not found. Install MuseScore Studio 4 / 3 or pass -MuseScorePath.' 
        }

        # Optional fallbacks
        if (-not $FluidSynthPath) {
            $FluidSynthPath = Resolve-Exe @('C:\Program Files\FluidSynth\bin\fluidsynth.exe', 'C:\Program Files (x86)\FluidSynth\bin\fluidsynth.exe', 'fluidsynth.exe')
        }
        if (-not $FFmpegPath) {
            $FFmpegPath = Resolve-Exe @('C:\Program Files\FFmpeg\bin\ffmpeg.exe', 'C:\Program Files (x86)\FFmpeg\bin\ffmpeg.exe', 'ffmpeg.exe')
        }
    }

    process {
        if (-not (Test-Path $Path)) {
            throw "Input not found: $Path" 
        }
        New-Dir $OutDir

        $inAbs = (Resolve-Path $Path).Path
        $baseName = [IO.Path]::GetFileNameWithoutExtension($inAbs)
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $work = Join-Path $OutDir ('.musescore-run-{0}-{1}' -f $baseName, $stamp)
        New-Dir $work

        # Normalize format list
        $fmt = @()
        foreach ($f in $Format) {
            if (-not $f) {
                continue 
            }
            $x = $f.ToLowerInvariant()
            if ($x -eq 'midi') {
                $x = 'mid' 
            }
            if ($fmt -notcontains $x) {
                $fmt += $x 
            }
        }

        # If .mxl, unpack to .musicxml
        $ext = [IO.Path]::GetExtension($inAbs).ToLowerInvariant()
        $jobInput = if ($ext -eq '.mxl') {
            Expand-MxlToMusicXml -MxlPath $inAbs -WorkDir (Join-Path $work 'unzipped')
        }
        else {
            $inAbs 
        }

        # Build target list
        $targets = @{}
        foreach ($e in $fmt) {
            $outFile = Join-Path $OutDir ('{0}.{1}' -f $baseName, $e)
            if ((Test-Path $outFile) -and -not $Force) {
                throw "Output exists: $outFile (use -Force)." 
            }
            if ($Force -and (Test-Path $outFile)) {
                Remove-Item -LiteralPath $outFile -Force 
            }
            $targets[$e] = $outFile
        }

        # --- Primary path: sequential -o exports (converter mode, no GUI) ---
        $present = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        foreach ($kv in $targets.GetEnumerator()) {
            $extOut = $kv.Key
            $out = $kv.Value

            $arguments = @('-w', '-f') + @('-o', $out)
            if ($SoundProfile) {
                $arguments += @('--sound-profile', $SoundProfile) 
            }
            $arguments += @($jobInput)

            $so = Join-Path $work "ms-$extOut.stdout.log"
            $se = Join-Path $work "ms-$extOut.stderr.log"

            # Skip JACK init to keep things quiet in headless runs (env per docs)
            $envExtra = @{ 'SKIP_LIBJACK' = '1' }

            Write-Verbose ("[MuseScore] {0}`nArgs: {1}" -f $MuseScorePath, ($arguments -join ' '))
            $code = Invoke-Process -exe $MuseScorePath -args $arguments -stdoutPath $so -stderrPath $se -envExtra $envExtra

            if ($code -eq 0 -and (Test-Path $out) -and ((Get-Item $out).Length -gt 0)) {
                $null = $present.Add($extOut)
            }
        }

        # Check which audio formats are still missing
        $needSynthFallback = $false
        foreach ($k in @('wav', 'mp3', 'flac', 'ogg')) {
            if ($targets.ContainsKey($k) -and -not $present.Contains($k)) {
                $needSynthFallback = $true 
            }
        }

        # --- Fallback: export MIDI with MuseScore, then FluidSynth -> WAV, FFmpeg encoders ---
        $didFallback = $false
        if ($needSynthFallback) {
            $midOut = if ($targets.ContainsKey('mid')) {
                $targets['mid'] 
            }
            else {
                Join-Path $OutDir ('{0}.mid' -f $baseName) 
            }
            if (-not (Test-Path $midOut) -or ((Get-Item $midOut).Length -eq 0)) {
                $argumentsMid = @('-w', '-f', '-o', $midOut, $jobInput)
                $codeMid = Invoke-Process -exe $MuseScorePath -args $argumentsMid -stdoutPath (Join-Path $work 'ms-mid.stdout.log') -stderrPath (Join-Path $work 'ms-mid.stderr.log') -envExtra @{ 'SKIP_LIBJACK' = '1' }
                if ($codeMid -ne 0 -or -not (Test-Path $midOut)) {
                    throw "MuseScore MIDI export failed (exit $codeMid). See $work" 
                }
            }

            if (-not $FluidSynthPath) {
                throw 'Audio export failed and FluidSynth is not available. Install fluidsynth or pass -FluidSynthPath.' 
            }
            # Find a reasonable SoundFont if not provided
            if (-not $SoundFont) {
                $sfHit = @(
                    "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf3",
                    "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf2",
                    "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf3",
                    "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf2",
                    'C:\Program Files\MuseScore 3\sound\*.sf3',
                    'C:\Program Files\MuseScore 4\resources\soundfonts\*.sf3'
                ) | ForEach-Object { Get-ChildItem -Path $_ -File -ErrorAction SilentlyContinue | Select-Object -First 1 } | Select-Object -First 1
                if ($sfHit) {
                    $SoundFont = $sfHit.FullName 
                }
            }
            if (-not $SoundFont -or -not (Test-Path $SoundFont)) {
                throw 'Audio export failed and no SoundFont (.sf2/.sf3) found for FluidSynth.' 
            }

            $wavOut = if ($targets.ContainsKey('wav')) {
                $targets['wav'] 
            }
            else {
                Join-Path $OutDir ('{0}.wav' -f $baseName) 
            }
            if ($Force -and (Test-Path $wavOut)) {
                Remove-Item -LiteralPath $wavOut -Force 
            }

            # FluidSynth fast file render: -ni (no interactive), -F <wav>, -r <rate>, <sf2/sf3> <mid>
            $fsArgs = @('-ni', '-F', $wavOut, '-r', $SampleRate.ToString(), $SoundFont, $midOut)
            $fsCode = Invoke-Process -exe $FluidSynthPath -args $fsArgs -stdoutPath (Join-Path $work 'fluidsynth.stdout.log') -stderrPath (Join-Path $work 'fluidsynth.stderr.log')
            if ($fsCode -ne 0 -or -not (Test-Path $wavOut)) {
                throw "FluidSynth rendering failed (exit $fsCode). See $work" 
            }
            $null = $present.Add('wav')

            if ($targets.ContainsKey('mp3')) {
                if (-not $FFmpegPath) {
                    throw 'Need FFmpeg to encode mp3; install ffmpeg or pass -FFmpegPath.' 
                }
                $mp3 = $targets['mp3']; if ($Force -and (Test-Path $mp3)) {
                    Remove-Item -LiteralPath $mp3 -Force 
                }
                $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-b:a', ('{0}k' -f $BitrateKbps), $mp3)
                $ffCode = Invoke-Process -exe $FFmpegPath -args $ffArgs -stdoutPath (Join-Path $work 'ffmpeg.mp3.stdout.log') -stderrPath (Join-Path $work 'ffmpeg.mp3.stderr.log')
                if ($ffCode -ne 0 -or -not (Test-Path $mp3)) {
                    throw "FFmpeg mp3 encode failed (exit $ffCode). See $work" 
                }
                $null = $present.Add('mp3')
            }
            if ($targets.ContainsKey('ogg')) {
                if (-not $FFmpegPath) {
                    throw 'Need FFmpeg to encode ogg; install ffmpeg or pass -FFmpegPath.' 
                }
                $ogg = $targets['ogg']; if ($Force -and (Test-Path $ogg)) {
                    Remove-Item -LiteralPath $ogg -Force 
                }
                $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-c:a', 'libvorbis', '-qscale:a', '5', $ogg)
                $ffCode = Invoke-Process -exe $FFmpegPath -args $ffArgs -stdoutPath (Join-Path $work 'ffmpeg.ogg.stdout.log') -stderrPath (Join-Path $work 'ffmpeg.ogg.stderr.log')
                if ($ffCode -ne 0 -or -not (Test-Path $ogg)) {
                    throw "FFmpeg ogg encode failed (exit $ffCode). See $work" 
                }
                $null = $present.Add('ogg')
            }
            if ($targets.ContainsKey('flac')) {
                if (-not $FFmpegPath) {
                    throw 'Need FFmpeg to encode flac; install ffmpeg or pass -FFmpegPath.' 
                }
                $flac = $targets['flac']; if ($Force -and (Test-Path $flac)) {
                    Remove-Item -LiteralPath $flac -Force 
                }
                $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-c:a', 'flac', $flac)
                $ffCode = Invoke-Process -exe $FFmpegPath -args $ffArgs -stdoutPath (Join-Path $work 'ffmpeg.flac.stdout.log') -stderrPath (Join-Path $work 'ffmpeg.flac.stderr.log')
                if ($ffCode -ne 0 -or -not (Test-Path $flac)) {
                    throw "FFmpeg flac encode failed (exit $ffCode). See $work" 
                }
                $null = $present.Add('flac')
            }
            $didFallback = $true
        }

        # Final verification
        $missing = @()
        foreach ($k in $targets.Keys) {
            $p = $targets[$k]
            if (-not (Test-Path $p) -or ((Get-Item $p).Length -eq 0)) {
                $missing += $p 
            }
        }
        if ($missing.Count -gt 0) {
            throw "Completed with errors: missing/empty outputs:`n - " + ($missing -join "`n - ") + "`nSee logs in $work"
        }

        if ($PassThru) {
            [PSCustomObject]@{
                InputScore   = $jobInput
                MuseScoreExe = $MuseScorePath
                Outputs      = $targets.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Value }
                UsedFallback = $didFallback
                WorkDir      = $work
                SampleRate   = $SampleRate
                BitrateKbps  = $BitrateKbps
            }
        }
        else {
            Write-Host ('Input: {0}' -f $jobInput)
            Write-Host ('MuseScore: {0}' -f $MuseScorePath)
            if ($didFallback) {
                Write-Host 'Fallback used: FluidSynth + FFmpeg' 
            }
            Write-Host 'Outputs:'
            $targets.GetEnumerator() | Sort-Object Key | ForEach-Object { Write-Host (' - {0}' -f $_.Value) }
            Write-Host ('Logs/work: {0}' -f $work)
        }
    }
}
