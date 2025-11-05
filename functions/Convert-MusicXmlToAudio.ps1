function Convert-MusicXmlToAudio {
    <#
.SYNOPSIS
Headless conversion of .mxl/.musicxml/.xml/.mscz to WAV/MP3/OGG/FLAC/MID via MuseScore 4/Studio/3.
Falls back to FluidSynth+FFmpeg only if MuseScore doesn’t produce audio.

.NOTES
- Converter mode is enabled by -o and “avoids the graphical user interface.”  (MuseScore 4 handbook)
- Some MS3-era switches are gone in MS4; don’t pass -w.                                   (MuseScore 4 handbook)
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [string]$OutDir = $(Join-Path (Split-Path -Parent $Path) 'audio-out'),

        [ValidateSet('wav', 'mp3', 'flac', 'ogg', 'mid', 'midi')]
        [string[]]$Format = @('wav'),

        [string]$MuseScorePath,          # Optional: MuseScoreStudio.exe / MuseScore4.exe / MuseScore3.exe
        [ValidateSet('MuseScore Basic', 'Muse Sounds')]
        [string]$SoundProfile,           # Optional for mp3 export quality profile

        [string]$SoundFont,              # Optional fallback: .sf2/.sf3 for FluidSynth
        [string]$FluidSynthPath,         # Optional fallback: fluidsynth.exe
        [string]$FFmpegPath,             # Optional fallback: ffmpeg.exe

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
                    $cmd = Get-Command $c -ErrorAction Stop; if ($cmd -and (Test-Path $cmd.Source)) {
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

        function Invoke-Process([string]$Exe, [string[]]$CliArgs, [string]$StdoutPath, [string]$StderrPath, [hashtable]$EnvExtra = @{}) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $Exe
            foreach ($a in $CliArgs) {
                [void]$psi.ArgumentList.Add($a) 
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            foreach ($k in $EnvExtra.Keys) {
                $psi.Environment[$k] = $EnvExtra[$k] 
            }
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.WaitForExit()
            $out = $p.StandardOutput.ReadToEnd()
            $err = $p.StandardError.ReadToEnd()
            if ($StdoutPath) {
                Set-Content -Path $StdoutPath -Value $out -Encoding UTF8 
            }
            if ($StderrPath) {
                Set-Content -Path $StderrPath -Value $err -Encoding UTF8 
            }
            return $p.ExitCode
        }

        function Expand-Mxl([string]$MxlPath, [string]$WorkDir) {
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
            $cand = Get-ChildItem -LiteralPath $WorkDir -Recurse -Include *.musicxml, *.xml -File -ErrorAction SilentlyContinue | Select-Object -First 1
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
            throw 'MuseScore executable not found. Install MuseScore Studio 4/3 or pass -MuseScorePath.' 
        }

        if (-not $FluidSynthPath) {
            $FluidSynthPath = Resolve-Exe @('C:\Program Files\FluidSynth\bin\fluidsynth.exe', 'C:\Program Files (x86)\FluidSynth\bin\fluidsynth.exe', 'fluidsynth.exe') 
        }
        if (-not $FFmpegPath) {
            $FFmpegPath = Resolve-Exe @('C:\Program Files\FFmpeg\bin\ffmpeg.exe', 'C:\Program Files (x86)\FFmpeg\bin\ffmpeg.exe', 'ffmpeg.exe') 
        }

        # Nuke stray Qt env that can cause “no Qt platform plugin” popups; -o should already avoid GUI.
        foreach ($k in 'QT_QPA_PLATFORM', 'QT_PLUGIN_PATH') {
            if (Test-Path Env:$k) {
                Remove-Item Env:$k -ErrorAction SilentlyContinue 
            } 
        }
    }

    process {
        if (-not (Test-Path $Path)) {
            throw "Input not found: $Path" 
        }
        New-Dir $OutDir

        $inAbs = (Resolve-Path $Path).Path
        $baseName = [IO.Path]::GetFileNameWithoutExtension($inAbs)
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $work = Join-Path $OutDir (".musescore-run-$baseName-$stamp"); New-Dir $work

        # normalize formats
        $want = @()
        foreach ($f in $Format) {
            if (-not $f) {
                continue 
            }
            $x = $f.ToLowerInvariant(); if ($x -eq 'midi') {
                $x = 'mid' 
            }
            if ($want -notcontains $x) {
                $want += $x 
            }
        }

        # if .mxl, expand to .musicxml
        $jobInput = if ([IO.Path]::GetExtension($inAbs).ToLowerInvariant() -eq '.mxl') {
            Expand-Mxl $inAbs (Join-Path $work 'unzipped')
        }
        else {
            $inAbs 
        }

        # target paths
        $targets = @{}
        foreach ($ext in $want) {
            $out = Join-Path $OutDir ("$baseName.$ext")
            if (Test-Path $out -and -not $Force) {
                throw "Output exists: $out (use -Force)." 
            }
            if ($Force -and (Test-Path $out)) {
                Remove-Item -LiteralPath $out -Force 
            }
            $targets[$ext] = $out
        }

        # prefer one JSON job (-j) when multiple outputs; fall back to sequential -o if needed
        $present = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        $stdout = Join-Path $work 'musescore.stdout.log'
        $stderr = Join-Path $work 'musescore.stderr.log'

        if ($targets.Count -gt 1) {
            # job: { in: "<file>", out: ["a.ext","b.ext",...] }
            $job = @(@{ in = $jobInput; out = @($targets.Values) })
            $jobPath = Join-Path $work 'job.json'
            ($job | ConvertTo-Json -Compress) | Set-Content -LiteralPath $jobPath -Encoding UTF8

            $cli = @('-j', $jobPath, '-f')  # -f = ignore mismatch warnings in converter mode
            if ($SoundProfile) {
                $cli += @('--sound-profile', $SoundProfile) 
            }  # (doc allows with -j or -o .mp3)

            Write-Verbose ("[MuseScore] {0}`nArgs: {1}" -f $MuseScorePath, ($cli -join ' '))
            $code = Invoke-Process -Exe $MuseScorePath -CliArgs $cli -StdoutPath $stdout -StderrPath $stderr -EnvExtra @{ 'SKIP_LIBJACK' = '1' }

            foreach ($kv in $targets.GetEnumerator()) {
                if (Test-Path $kv.Value -and ((Get-Item $kv.Value).Length -gt 0)) {
                    $null = $present.Add($kv.Key) 
                }
            }
        }

        if ($present.Count -lt $targets.Count) {
            # sequential -o exports (always converter mode; no GUI)
            foreach ($kv in $targets.GetEnumerator()) {
                if ($present.Contains($kv.Key)) {
                    continue 
                }
                $so = Join-Path $work "ms-$($kv.Key).stdout.log"
                $se = Join-Path $work "ms-$($kv.Key).stderr.log"
                $cliSeq = @('-f', '-o', $kv.Value)
                if ($SoundProfile -and $kv.Key -eq 'mp3') {
                    $cliSeq += @('--sound-profile', $SoundProfile) 
                }
                $cliSeq += @($jobInput)

                Write-Verbose ("[MuseScore] {0}`nArgs: {1}" -f $MuseScorePath, ($cliSeq -join ' '))
                $codeSeq = Invoke-Process -Exe $MuseScorePath -CliArgs $cliSeq -StdoutPath $so -StderrPath $se -EnvExtra @{ 'SKIP_LIBJACK' = '1' }

                if (Test-Path $kv.Value -and ((Get-Item $kv.Value).Length -gt 0)) {
                    $null = $present.Add($kv.Key) 
                }
            }
        }

        # Need fallback?
        $needSynth = $false
        foreach ($k in @('wav', 'mp3', 'flac', 'ogg')) {
            if ($targets.ContainsKey($k) -and -not $present.Contains($k)) {
                $needSynth = $true; break 
            }
        }

        $didFallback = $false
        if ($needSynth) {
            # Ensure we have a MIDI
            $midOut = if ($targets.ContainsKey('mid')) {
                $targets['mid'] 
            }
            else {
                Join-Path $OutDir "$baseName.mid" 
            }
            if (-not (Test-Path $midOut) -or ((Get-Item $midOut).Length -eq 0)) {
                $midSO = Join-Path $work 'ms-mid.stdout.log'
                $midSE = Join-Path $work 'ms-mid.stderr.log'
                $cliMid = @('-f', '-o', $midOut, $jobInput)
                $midCode = Invoke-Process -Exe $MuseScorePath -CliArgs $cliMid -StdoutPath $midSO -StderrPath $midSE -EnvExtra @{ 'SKIP_LIBJACK' = '1' }
                if ($midCode -ne 0 -or -not (Test-Path $midOut)) {
                    throw "MuseScore export failed for 'mid' (no output). Last stderr lines:`n$(Get-Content $midSE -Tail 20 -ErrorAction SilentlyContinue -Raw)"
                }
            }

            if (-not $FluidSynthPath) {
                throw 'Audio export failed and FluidSynth is not available. Install fluidsynth or pass -FluidSynthPath.' 
            }

            if (-not $SoundFont) {
                $sfHit = @(
                    "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf3",
                    "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf2",
                    "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf3",
                    "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf2",
                    'C:\Program Files\MuseScore 4\resources\soundfonts\*.sf3',
                    'C:\Program Files\MuseScore 3\sound\*.sf3'
                ) | ForEach-Object { Get-ChildItem -Path $_ -File -ErrorAction SilentlyContinue | Select-Object -First 1 } | Select-Object -First 1
                if ($sfHit) {
                    $SoundFont = $sfHit.FullName 
                }
            }
            if (-not $SoundFont -or -not (Test-Path $SoundFont)) {
                throw 'Audio export failed and no SoundFont (.sf2/.sf3) was found for FluidSynth.' 
            }

            # render WAV
            $wavOut = if ($targets.ContainsKey('wav')) {
                $targets['wav'] 
            }
            else {
                Join-Path $OutDir "$baseName.wav" 
            }
            if ($Force -and (Test-Path $wavOut)) {
                Remove-Item -LiteralPath $wavOut -Force 
            }

            $fsSO = Join-Path $work 'fluidsynth.stdout.log'
            $fsSE = Join-Path $work 'fluidsynth.stderr.log'
            $fsArgs = @('-ni', '-F', $wavOut, '-r', $SampleRate.ToString(), $SoundFont, $midOut)
            $fsCode = Invoke-Process -Exe $FluidSynthPath -CliArgs $fsArgs -StdoutPath $fsSO -StderrPath $fsSE
            if ($fsCode -ne 0 -or -not (Test-Path $wavOut)) {
                throw "FluidSynth rendering failed (exit $fsCode). See $work" 
            }

            $null = $present.Add('wav')

            # encode requested compressed formats
            if ($targets.ContainsKey('mp3')) {
                if (-not $FFmpegPath) {
                    throw 'Need FFmpeg to encode mp3; install ffmpeg or pass -FFmpegPath.' 
                }
                $mp3 = $targets['mp3']; if ($Force -and (Test-Path $mp3)) {
                    Remove-Item -LiteralPath $mp3 -Force 
                }
                $ffSO = Join-Path $work 'ffmpeg.mp3.stdout.log'; $ffSE = Join-Path $work 'ffmpeg.mp3.stderr.log'
                $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-b:a', ('{0}k' -f $BitrateKbps), $mp3)
                $ffCode = Invoke-Process -Exe $FFmpegPath -CliArgs $ffArgs -StdoutPath $ffSO -StderrPath $ffSE
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
                $ffSO = Join-Path $work 'ffmpeg.ogg.stdout.log'; $ffSE = Join-Path $work 'ffmpeg.ogg.stderr.log'
                $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-c:a', 'libvorbis', '-qscale:a', '5', $ogg)
                $ffCode = Invoke-Process -Exe $FFmpegPath -CliArgs $ffArgs -StdoutPath $ffSO -StderrPath $ffSE
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
                $ffSO = Join-Path $work 'ffmpeg.flac.stdout.log'; $ffSE = Join-Path $work 'ffmpeg.flac.stderr.log'
                $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-c:a', 'flac', $flac)
                $ffCode = Invoke-Process -Exe $FFmpegPath -CliArgs $ffArgs -StdoutPath $ffSO -StderrPath $ffSE
                if ($ffCode -ne 0 -or -not (Test-Path $flac)) {
                    throw "FFmpeg flac encode failed (exit $ffCode). See $work" 
                }
                $null = $present.Add('flac')
            }
            $didFallback = $true
        }

        # final verification
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
            Write-Host 'Outputs:'; $targets.GetEnumerator() | Sort-Object Key | ForEach-Object { Write-Host (' - {0}' -f $_.Value) }
            Write-Host ('Logs/work: {0}' -f $work)
        }
    }
}
