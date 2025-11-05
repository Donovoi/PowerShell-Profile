function Convert-MusicXmlToAudio {
    <#
.SYNOPSIS
Headless conversion of .mxl/.musicxml/.xml/.mscz to WAV/MP3/OGG/FLAC/MID via MuseScore.
Falls back to FluidSynth+FFmpeg only if MuseScore emits no audio.

.NOTES
MuseScore converter mode: -o / --export-to <outfile> infers format by extension; -f ignores mismatch warnings.
Valid output extensions include wav, mp3, ogg, flac, mid/midi, pdf, png, svg, xml/mxl, etc.
Sound profile can be overridden with --sound-profile "MuseScore Basic" | "Muse Sounds".
(See MuseScore Studio Handbook “Command line usage”.)
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [string]$OutDir = (Join-Path (Split-Path -Parent $Path) 'audio-out'),

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
            if (-not (Test-Path -LiteralPath $p)) {
                New-Item -ItemType Directory -Force -Path $p | Out-Null
            }
        }

        function Invoke-Process {
            param(
                [Parameter(Mandatory)] [string]$Exe,
                [Parameter(Mandatory)] [string[]]$ArgumentList,
                [string]$StdoutPath,
                [string]$StderrPath,
                [hashtable]$EnvExtra
            )
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $Exe
            foreach ($a in $ArgumentList) {
                [void]$psi.ArgumentList.Add($a) 
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            if ($EnvExtra) {
                foreach ($k in $EnvExtra.Keys) {
                    $psi.Environment[$k] = [string]$EnvExtra[$k]
                }
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

        function Expand-MxlToMusicXml {
            param([string]$MxlPath, [string]$WorkDir)
            New-Dir $WorkDir
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($MxlPath, $WorkDir, $true)

            $container = Join-Path $WorkDir 'META-INF\container.xml'
            if (Test-Path -LiteralPath $container) {
                [xml]$cx = Get-Content -LiteralPath $container
                $root = $cx.container.rootfiles.rootfile.'full-path'
                if ($root) {
                    $rootPath = Join-Path $WorkDir $root
                    if (Test-Path -LiteralPath $rootPath) {
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
    }

    process {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "Input not found: $Path"
        }
        New-Dir $OutDir

        $inAbs = (Resolve-Path $Path).Path
        $baseName = [IO.Path]::GetFileNameWithoutExtension($inAbs)
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $work = Join-Path $OutDir ('.musescore-run-{0}-{1}' -f $baseName, $stamp)
        New-Dir $work

        # normalize requested formats (dedupe, accept 'midi')
        $req = @()
        foreach ($f in $Format) {
            if (-not $f) {
                continue 
            }
            $x = $f.ToLowerInvariant()
            if ($x -eq 'midi') {
                $x = 'mid' 
            }
            if ($req -notcontains $x) {
                $req += $x 
            }
        }

        # unpack .mxl if needed
        $ext = [IO.Path]::GetExtension($inAbs).ToLowerInvariant()
        $scoreForMs = if ($ext -eq '.mxl') {
            Expand-MxlToMusicXml -MxlPath $inAbs -WorkDir (Join-Path $work 'unzipped')
        }
        else {
            $inAbs 
        }

        # target files
        $targets = @{}
        foreach ($e in $req) {
            $out = Join-Path $OutDir ('{0}.{1}' -f $baseName, $e)
            if ((Test-Path -LiteralPath $out) -and (-not $Force)) {
                throw "Output exists: $out (use -Force)."
            }
            if ($Force -and (Test-Path -LiteralPath $out)) {
                Remove-Item -LiteralPath $out -Force 
            }
            $targets[$e] = $out
        }

        # Environment for stable headless run (avoid Qt plugin surprises; skip JACK)
        $qtEnv = @{
            'QT_QPA_PLATFORM'             = 'windows'  # select Windows platform plugin
            'QT_PLUGIN_PATH'              = ''         # ignore any stray global Qt plugin path
            'QT_QPA_PLATFORMTHEME'        = ''         # avoid mismatched theme plugins
            'QT_QPA_PLATFORM_PLUGIN_PATH' = ''         # avoid wrong plugin dirs
            'SKIP_LIBJACK'                = '1'        # per handbook ENV section
        }

        # Try MuseScore once per requested format (converter mode)
        $produced = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $targets.Keys) {
            $out = $targets[$k]
            $msArgs = @('-f')  # ignore mismatch warnings in converter mode
            if ($k -eq 'mp3') {
                # set bitrate if exporting mp3
                $msArgs += @('-b', $BitrateKbps.ToString())
            }
            if ($SoundProfile) {
                # handbook: use with -o .mp3 or -j
                $msArgs += @('--sound-profile', $SoundProfile)
            }
            $msArgs += @('-o', $out, $scoreForMs)

            Write-Verbose ("[MuseScore] {0}`nArgs: {1}" -f $MuseScorePath, ($msArgs -join ' '))
            $code = Invoke-Process -Exe $MuseScorePath -ArgumentList $msArgs `
                -StdoutPath (Join-Path $work "ms-$k.stdout.log") `
                -StderrPath (Join-Path $work "ms-$k.stderr.log") `
                -EnvExtra $qtEnv

            if (($code -eq 0) -and (Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out).Length -gt 0)) {
                [void]$produced.Add($k)
            }
        }

        # If any requested audio types missing, fallback: MID -> FluidSynth -> FFmpeg
        $needAudioFallback = $false
        foreach ($a in @('wav', 'mp3', 'flac', 'ogg')) {
            if ($targets.ContainsKey($a) -and (-not $produced.Contains($a))) {
                $needAudioFallback = $true 
            }
        }

        $didFallback = $false
        if ($needAudioFallback) {
            # Ensure we have a MIDI
            $midOut = if ($targets.ContainsKey('mid')) {
                $targets['mid'] 
            }
            else {
                Join-Path $OutDir "$baseName.mid" 
            }
            if ((-not (Test-Path -LiteralPath $midOut)) -or ((Get-Item -LiteralPath $midOut).Length -eq 0)) {
                $midArgs = @('-f', '-o', $midOut, $scoreForMs)
                Write-Verbose ('[MuseScore] export MIDI: {0}' -f ($midArgs -join ' '))
                $mcode = Invoke-Process -Exe $MuseScorePath -ArgumentList $midArgs `
                    -StdoutPath (Join-Path $work 'ms-mid.stdout.log') `
                    -StderrPath (Join-Path $work 'ms-mid.stderr.log') `
                    -EnvExtra $qtEnv
                if (($mcode -ne 0) -or (-not (Test-Path -LiteralPath $midOut))) {
                    throw "MuseScore MIDI export failed (exit $mcode). See $work"
                }
            }

            if (-not $FluidSynthPath) {
                throw 'Audio export failed and FluidSynth is not available. Install fluidsynth or pass -FluidSynthPath.'
            }

            # pick a SoundFont if not provided
            if (-not $SoundFont) {
                $sf = @(
                    "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf3",
                    "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf2",
                    "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf3",
                    "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf2",
                    'C:\Program Files\MuseScore 4\resources\soundfonts\*.sf3',
                    'C:\Program Files\MuseScore 3\sound\*.sf3'
                ) | ForEach-Object { Get-ChildItem -Path $_ -File -ErrorAction SilentlyContinue | Select-Object -First 1 } | Select-Object -First 1
                if ($sf) {
                    $SoundFont = $sf.FullName 
                }
            }
            if (-not $SoundFont -or -not (Test-Path -LiteralPath $SoundFont)) {
                throw 'Audio export failed and no SoundFont (.sf2/.sf3) found for FluidSynth.'
            }

            $wavOut = if ($targets.ContainsKey('wav')) {
                $targets['wav'] 
            }
            else {
                Join-Path $OutDir "$baseName.wav" 
            }
            if ($Force -and (Test-Path -LiteralPath $wavOut)) {
                Remove-Item -LiteralPath $wavOut -Force 
            }

            $fsArgs = @('-ni', '-F', $wavOut, '-r', $SampleRate.ToString(), $SoundFont, $midOut)
            $fsCode = Invoke-Process -Exe $FluidSynthPath -ArgumentList $fsArgs `
                -StdoutPath (Join-Path $work 'fluidsynth.stdout.log') `
                -StderrPath (Join-Path $work 'fluidsynth.stderr.log')
            if (($fsCode -ne 0) -or (-not (Test-Path -LiteralPath $wavOut))) {
                throw "FluidSynth rendering failed (exit $fsCode). See $work"
            }
            [void]$produced.Add('wav')

            if ($targets.ContainsKey('mp3')) {
                if (-not $FFmpegPath) {
                    throw 'Need FFmpeg for mp3; pass -FFmpegPath or install ffmpeg.' 
                }
                $mp3 = $targets['mp3']; if ($Force -and (Test-Path -LiteralPath $mp3)) {
                    Remove-Item -LiteralPath $mp3 -Force 
                }
                $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-b:a', ("$BitrateKbps`k"), $mp3)
                $ffCode = Invoke-Process -Exe $FFmpegPath -ArgumentList $ffArgs `
                    -StdoutPath (Join-Path $work 'ffmpeg.mp3.stdout.log') `
                    -StderrPath (Join-Path $work 'ffmpeg.mp3.stderr.log')
                if (($ffCode -ne 0) -or (-not (Test-Path -LiteralPath $mp3))) {
                    throw "FFmpeg mp3 encode failed (exit $ffCode). See $work" 
                }
                [void]$produced.Add('mp3')
            }
            if ($targets.ContainsKey('ogg')) {
                if (-not $FFmpegPath) {
                    throw 'Need FFmpeg for ogg; pass -FFmpegPath or install ffmpeg.' 
                }
                $ogg = $targets['ogg']; if ($Force -and (Test-Path -LiteralPath $ogg)) {
                    Remove-Item -LiteralPath $ogg -Force 
                }
                $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-c:a', 'libvorbis', '-qscale:a', '5', $ogg)
                $ffCode = Invoke-Process -Exe $FFmpegPath -ArgumentList $ffArgs `
                    -StdoutPath (Join-Path $work 'ffmpeg.ogg.stdout.log') `
                    -StderrPath (Join-Path $work 'ffmpeg.ogg.stderr.log')
                if (($ffCode -ne 0) -or (-not (Test-Path -LiteralPath $ogg))) {
                    throw "FFmpeg ogg encode failed (exit $ffCode). See $work" 
                }
                [void]$produced.Add('ogg')
            }
            if ($targets.ContainsKey('flac')) {
                if (-not $FFmpegPath) {
                    throw 'Need FFmpeg for flac; pass -FFmpegPath or install ffmpeg.' 
                }
                $flac = $targets['flac']; if ($Force -and (Test-Path -LiteralPath $flac)) {
                    Remove-Item -LiteralPath $flac -Force 
                }
                $ffArgs = @('-y', '-loglevel', 'error', '-i', $wavOut, '-c:a', 'flac', $flac)
                $ffCode = Invoke-Process -Exe $FFmpegPath -ArgumentList $ffArgs `
                    -StdoutPath (Join-Path $work 'ffmpeg.flac.stdout.log') `
                    -StderrPath (Join-Path $work 'ffmpeg.flac.stderr.log')
                if (($ffCode -ne 0) -or (-not (Test-Path -LiteralPath $flac))) {
                    throw "FFmpeg flac encode failed (exit $ffCode). See $work" 
                }
                [void]$produced.Add('flac')
            }
            $didFallback = $true
        }

        # verify everything requested exists
        $missing = @()
        foreach ($k in $targets.Keys) {
            $p = $targets[$k]
            if ((-not (Test-Path -LiteralPath $p)) -or ((Get-Item -LiteralPath $p).Length -eq 0)) {
                $missing += $p 
            }
        }
        if ($missing.Count -gt 0) {
            throw "Completed with errors: missing/empty outputs:`n - " + ($missing -join "`n - ") + "`nSee logs in $work"
        }

        $outs = $targets.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Value }
        if ($PassThru) {
            [PSCustomObject]@{
                InputScore   = $scoreForMs
                MuseScoreExe = $MuseScorePath
                Outputs      = $outs
                UsedFallback = $didFallback
                WorkDir      = $work
                SampleRate   = $SampleRate
                BitrateKbps  = $BitrateKbps
            }
        }
        else {
            Write-Host ('Input:     {0}' -f $scoreForMs)
            Write-Host ('MuseScore: {0}' -f $MuseScorePath)
            if ($didFallback) {
                Write-Host 'Fallback:  FluidSynth + FFmpeg used.' 
            }
            Write-Host 'Outputs:'; $outs | ForEach-Object { Write-Host (' - {0}' -f $_) }
            Write-Host ('Logs/work: {0}' -f $work)
        }
    }
}