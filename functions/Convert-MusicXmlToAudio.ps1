function Convert-MusicXmlToAudio {
    <#
.SYNOPSIS
Convert .mxl/.musicxml/.xml/.mscz to audio/MIDI via MuseScore CLI, with robust fallbacks.

.DESCRIPTION
- Primary path: MuseScore “converter mode” using a single JSON job (-j) to export multiple formats in one run.
- Fallback path: if audio export files are missing/empty, export MIDI, then render with FluidSynth to WAV,
  then encode with FFmpeg to mp3/ogg/flac as requested.

.PARAMETER Path
Input score (.mxl, .musicxml, .xml, .mscz, .mscx, .mid).

.PARAMETER OutDir
Destination directory. Created if missing.

.PARAMETER Format
One or more of: wav, mp3, flac, ogg, mid, midi. (Comma/space separated is fine.)

.PARAMETER MuseScorePath
Optional explicit path to MuseScore executable (MuseScore4/MuseScoreStudio, MuseScore3).

.PARAMETER SoundFont
Optional explicit .sf2/.sf3 for FluidSynth fallback.

.PARAMETER FluidSynthPath
Optional explicit path to fluidsynth.exe.

.PARAMETER FFmpegPath
Optional explicit path to ffmpeg.exe.

.PARAMETER SampleRate
Audio sample rate for FluidSynth/FFmpeg fallbacks (default 44100).

.PARAMETER BitrateKbps
MP3 bitrate for FFmpeg fallback (default 256).

.PARAMETER SoundProfile
Optional MuseScore sound profile for audio export: 'MuseScore Basic' or 'Muse Sounds'.

.PARAMETER Force
Overwrite outputs if present.

.PARAMETER PassThru
Return an object describing what was created (instead of just printing).
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [string]$Path,

        [Parameter()]
        [string]$OutDir = $(Join-Path (Split-Path -Parent $Path) 'audio-out'),

        [Parameter()]
        [ValidateSet('wav', 'mp3', 'flac', 'ogg', 'mid', 'midi')]
        [string[]]$Format = @('wav'),

        [Parameter()]
        [string]$MuseScorePath,

        [Parameter()]
        [string]$SoundFont,

        [Parameter()]
        [string]$FluidSynthPath,

        [Parameter()]
        [string]$FFmpegPath,

        [Parameter()]
        [int]$SampleRate = 44100,

        [Parameter()]
        [int]$BitrateKbps = 256,

        [Parameter()]
        [ValidateSet('MuseScore Basic', 'Muse Sounds')]
        [string]$SoundProfile,

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

        if (-not $MuseScorePath) {
            $MuseScorePath = Resolve-Exe @(
                'C:\Program Files\MuseScore 4\bin\MuseScore4.exe',
                'C:\Program Files\MuseScore 4\MuseScore4.exe',
                'C:\Program Files\MuseScore Studio 4\MuseScoreStudio.exe',
                'C:\Program Files\MuseScore Studio 4\bin\MuseScoreStudio.exe',
                'C:\Program Files\MuseScore 3\bin\MuseScore3.exe',
                'C:\Program Files\MuseScore 3\MuseScore3.exe',
                'MuseScore4.exe', 'MuseScoreStudio.exe', 'MuseScore3.exe', 'mscore.exe'
            )
        }
        if (-not $MuseScorePath) {
            throw 'MuseScore executable not found. Install MuseScore Studio 4 or MuseScore 3, or pass -MuseScorePath.'
        }

        if (-not $FluidSynthPath) {
            $FluidSynthPath = Resolve-Exe @(
                'C:\Program Files\FluidSynth\bin\fluidsynth.exe',
                'C:\Program Files (x86)\FluidSynth\bin\fluidsynth.exe',
                'fluidsynth.exe'
            )
        }

        if (-not $FFmpegPath) {
            $FFmpegPath = Resolve-Exe @(
                'C:\Program Files\FFmpeg\bin\ffmpeg.exe',
                'C:\Program Files (x86)\FFmpeg\bin\ffmpeg.exe',
                'ffmpeg.exe'
            )
        }

        function Ensure-Dir($p) {
            if (-not (Test-Path $p)) {
                New-Item -ItemType Directory -Path $p -Force | Out-Null 
            }
        }

        function Unzip-MxlToMusicXml {
            param([string]$MxlPath, [string]$WorkDir)

            Ensure-Dir $WorkDir
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
            # Fallback: first *.musicxml then *.xml
            $cand = Get-ChildItem -LiteralPath $WorkDir -Recurse -Include *.musicxml -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $cand) {
                $cand = Get-ChildItem -LiteralPath $WorkDir -Recurse -Include *.xml -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }
            if ($cand) {
                return (Resolve-Path $cand.FullName).Path 
            }
            throw 'Could not locate MusicXML inside MXL (no META-INF/container.xml match nor *.musicxml/*.xml found).'
        }

        function Find-SoundFont {
            param([string]$Hint)
            if ($Hint -and (Test-Path $Hint)) {
                return (Resolve-Path $Hint).Path 
            }
            $cands = @(
                "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf3",
                "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf2",
                "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf3",
                "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf2",
                'C:\Program Files\MuseScore 3\sound\MuseScore_General.sf3',
                'C:\Program Files\MuseScore 3\sound\*.sf3',
                'C:\Program Files\MuseScore 4\resources\soundfonts\*.sf3',
                'C:\Program Files\MuseScore 4\soundfonts\*.sf3'
            )
            foreach ($p in $cands) {
                $hit = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hit) {
                    return (Resolve-Path $hit.FullName).Path 
                }
            }
            return $null
        }

        function Run-Process($exe, [string[]]$args, $stdoutPath, $stderrPath) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exe
            foreach ($a in $args) {
                [void]$psi.ArgumentList.Add($a) 
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
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
    }

    process {
        if (-not (Test-Path $Path)) {
            throw "Input not found: $Path" 
        }
        Ensure-Dir $OutDir

        $inAbs = (Resolve-Path $Path).Path
        $baseName = [IO.Path]::GetFileNameWithoutExtension($inAbs)
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $work = Join-Path $OutDir ('.musescore-run-{0}-{1}' -f $baseName, $stamp)
        Ensure-Dir $work

        # Normalize formats: treat 'midi' as 'mid', de-dup, order stable
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

        # If input is .mxl, unzip to .musicxml first
        $ext = [IO.Path]::GetExtension($inAbs).ToLowerInvariant()
        $jobInput = if ($ext -eq '.mxl') {
            try {
                Unzip-MxlToMusicXml -MxlPath $inAbs -WorkDir $work
            }
            catch {
                throw "Failed to unpack .mxl: $($_.Exception.Message)"
            }
        }
        else {
            $inAbs
        }

        # Build output paths (one per requested format)
        $targets = @{}
        foreach ($e in $fmt) {
            $outFile = Join-Path $OutDir ('{0}.{1}' -f $baseName, $e)
            if ((Test-Path $outFile) -and -not $Force) {
                throw "Output exists: $outFile (use -Force to overwrite)."
            }
            if ($Force -and (Test-Path $outFile)) {
                Remove-Item -LiteralPath $outFile -Force 
            }
            $targets[$e] = $outFile
        }

        # === Primary attempt: one MuseScore run with a JSON job (-j) ===
        $job = @(@{ in = $jobInput; out = @($targets.Values) })
        $jobPath = Join-Path $work 'job.json'
        $null = ($job | ConvertTo-Json -Compress) | Set-Content -LiteralPath $jobPath -Encoding UTF8

        $msStdout = Join-Path $work 'musescore.stdout.log'
        $msStderr = Join-Path $work 'musescore.stderr.log'

        $args = @('-j', $jobPath)
        if ($SoundProfile) {
            $args += @('--sound-profile', $SoundProfile) 
        } # e.g., 'MuseScore Basic' or 'Muse Sounds'
        # Avoid GUI; converter mode is implied by -j. Add -f to ignore mismatch warnings.
        $args += '-f'

        Write-Verbose ("[MuseScore] {0}`nArgs: {1}" -f $MuseScorePath, ($args -join ' '))

        $code = Run-Process -exe $MuseScorePath -args $args -stdoutPath $msStdout -stderrPath $msStderr

        # Verify produced files
        $present = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($kv in $targets.GetEnumerator()) {
            $p = $kv.Value
            if ((Test-Path $p) -and ((Get-Item $p).Length -gt 0)) {
                $null = $present.Add($kv.Key) 
            }
        }

        $needFallback = $false
        foreach ($k in $targets.Keys) {
            if ($k -in @('wav', 'mp3', 'flac', 'ogg')) {
                if (-not $present.Contains($k)) {
                    $needFallback = $true; break 
                }
            }
        }

        # === Fallback path if audio missing: export MIDI, then FluidSynth + FFmpeg ===
        $didSynthFallback = $false
        $midOut = $targets.ContainsKey('mid') ? $targets['mid'] : (Join-Path $OutDir ('{0}.mid' -f $baseName))

        if ($needFallback) {
            # Ensure MIDI exists
            if (-not (Test-Path $midOut) -or ((Get-Item $midOut).Length -eq 0)) {
                $argsMid = @('-o', $midOut, $jobInput)
                Write-Verbose ('[MuseScore] Export MIDI: {0} {1}' -f $MuseScorePath, ($argsMid -join ' '))
                $codeMid = Run-Process -exe $MuseScorePath -args $argsMid -stdoutPath (Join-Path $work 'musescore.mid.stdout.log') -stderrPath (Join-Path $work 'musescore.mid.stderr.log')
                if ($codeMid -ne 0 -or -not (Test-Path $midOut)) {
                    throw "MuseScore fallback MIDI export failed (exit $codeMid). See $work"
                }
            }

            # Need a soundfont and fluidsynth
            if (-not $FluidSynthPath) {
                throw 'Audio export failed and FluidSynth not found. Install fluidsynth or pass -FluidSynthPath.'
            }
            $sf = Find-SoundFont -Hint $SoundFont
            if (-not $sf) {
                throw 'Audio export failed and a SoundFont (.sf2/.sf3) was not found. Install one under Documents\MuseScore4\SoundFonts or pass -SoundFont.'
            }

            # Render WAV via FluidSynth fast file renderer
            $wavOut = $targets.ContainsKey('wav') ? $targets['wav'] : (Join-Path $OutDir ('{0}.wav' -f $baseName))
            if ((Test-Path $wavOut) -and -not $Force) {
                throw "Output exists: $wavOut (use -Force)."
            }
            if ($Force -and (Test-Path $wavOut)) {
                Remove-Item -LiteralPath $wavOut -Force 
            }

            # Prefer file renderer flags; many builds support: -ni (no MIDI input), -F <wav>, -r <rate> <sf> <mid>
            $fsStdout = Join-Path $work 'fluidsynth.stdout.log'
            $fsStderr = Join-Path $work 'fluidsynth.stderr.log'
            $fsArgs = @('-ni', '-F', $wavOut, '-r', $SampleRate.ToString(), $sf, $midOut)
            Write-Verbose ('[FluidSynth] {0} {1}' -f $FluidSynthPath, ($fsArgs -join ' '))
            $fsCode = Run-Process -exe $FluidSynthPath -args $fsArgs -stdoutPath $fsStdout -stderrPath $fsStderr
            if ($fsCode -ne 0 -or -not (Test-Path $wavOut)) {
                throw "FluidSynth rendering failed (exit $fsCode). See $work"
            }

            # Encode other requested formats from WAV with FFmpeg
            foreach ($k in $targets.Keys) {
                if ($k -eq 'mp3') {
                    if (-not $FFmpegPath) {
                        throw 'Need FFmpeg to encode mp3; install ffmpeg or pass -FFmpegPath.' 
                    }
                    $mp3 = $targets['mp3']
                    if ($Force -and (Test-Path $mp3)) {
                        Remove-Item -LiteralPath $mp3 -Force 
                    }
                    $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-b:a', ('{0}k' -f $BitrateKbps), $mp3)
                    $ffCode = Run-Process -exe $FFmpegPath -args $ffArgs -stdoutPath (Join-Path $work 'ffmpeg.mp3.stdout.log') -stderrPath (Join-Path $work 'ffmpeg.mp3.stderr.log')
                    if ($ffCode -ne 0 -or -not (Test-Path $mp3)) {
                        throw "FFmpeg mp3 encode failed (exit $ffCode). See $work" 
                    }
                    $present.Add('mp3') | Out-Null
                }
                elseif ($k -eq 'ogg') {
                    if (-not $FFmpegPath) {
                        throw 'Need FFmpeg to encode ogg; install ffmpeg or pass -FFmpegPath.' 
                    }
                    $ogg = $targets['ogg']
                    if ($Force -and (Test-Path $ogg)) {
                        Remove-Item -LiteralPath $ogg -Force 
                    }
                    $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-c:a', 'libvorbis', '-qscale:a', '5', $ogg)
                    $ffCode = Run-Process -exe $FFmpegPath -args $ffArgs -stdoutPath (Join-Path $work 'ffmpeg.ogg.stdout.log') -stderrPath (Join-Path $work 'ffmpeg.ogg.stderr.log')
                    if ($ffCode -ne 0 -or -not (Test-Path $ogg)) {
                        throw "FFmpeg ogg encode failed (exit $ffCode). See $work" 
                    }
                    $present.Add('ogg') | Out-Null
                }
                elseif ($k -eq 'flac') {
                    if (-not $FFmpegPath) {
                        throw 'Need FFmpeg to encode flac; install ffmpeg or pass -FFmpegPath.' 
                    }
                    $flac = $targets['flac']
                    if ($Force -and (Test-Path $flac)) {
                        Remove-Item -LiteralPath $flac -Force 
                    }
                    $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-c:a', 'flac', $flac)
                    $ffCode = Run-Process -exe $FFmpegPath -args $ffArgs -stdoutPath (Join-Path $work 'ffmpeg.flac.stdout.log') -stderrPath (Join-Path $work 'ffmpeg.flac.stderr.log')
                    if ($ffCode -ne 0 -or -not (Test-Path $flac)) {
                        throw "FFmpeg flac encode failed (exit $ffCode). See $work" 
                    }
                    $present.Add('flac') | Out-Null
                }
            }

            # If WAV requested but came from fallback, mark present
            if ($targets.ContainsKey('wav')) {
                $present.Add('wav') | Out-Null 
            }
            $didSynthFallback = $true
        }

        # Final verification for all requested formats
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
                InputScore    = $jobInput
                MuseScoreExe  = $MuseScorePath
                Outputs       = $targets.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Value }
                UsedFallback  = $didSynthFallback
                WorkDir       = $work
                SampleRate    = $SampleRate
                BitrateKbps   = $BitrateKbps
                SoundFontUsed = if ($didSynthFallback) {
                    (Find-SoundFont -Hint $SoundFont) 
                }
                else {
                    $null 
                }
            }
        }
        else {
            Write-Host ('Input:  {0}' -f $jobInput)
            Write-Host ('MuseScore: {0}' -f $MuseScorePath)
            if ($didSynthFallback) {
                Write-Host 'Fallback: FluidSynth + FFmpeg were used.'
            }
            Write-Host 'Outputs:'
            $targets.GetEnumerator() | Sort-Object Key | ForEach-Object { Write-Host (' - {0}' -f $_.Value) }
            Write-Host ('Logs/work: {0}' -f $work)
        }
    }
}
