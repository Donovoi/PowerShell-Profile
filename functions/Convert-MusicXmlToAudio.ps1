function Convert-MusicXmlToAudio {
    <#
.SYNOPSIS
Headless conversion of .mxl/.musicxml/.xml/.mscz to WAV/MP3/OGG/FLAC/MID via MuseScore CLI.
Recovers from MU4 “silent export” by retrying with MuseScore 3; then FluidSynth/FFmpeg as last resort.

#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')][string]$Path,

        [string]$OutDir = $(Join-Path (Split-Path -Parent $Path) 'audio-out'),

        [ValidateSet('wav', 'mp3', 'flac', 'ogg', 'mid', 'midi')]
        [string[]]$Format = @('wav'),

        [string]$MuseScorePath,  # explicit MS exe (MS4/Studio/3)
        [ValidateSet('MuseScore Basic', 'Muse Sounds')][string]$SoundProfile,

        # Fallback toolchain (only if audio missing from MS export)
        [string]$SoundFont, [string]$FluidSynthPath, [string]$FFmpegPath,

        [int]$SampleRate = 44100, [int]$BitrateKbps = 256,
        [switch]$Force, [switch]$PassThru
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

        function Invoke-Process($exe, [string[]]$arguments, $stdoutPath, $stderrPath, $envExtra = @{}) {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $exe
            foreach ($a in $arguments) {
                [void]$psi.ArgumentList.Add($a) 
            }
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            foreach ($k in $envExtra.Keys) {
                $psi.Environment[$k] = $envExtra[$k] 
            }
            $p = [System.Diagnostics.Process]::Start($psi); $p.WaitForExit()
            $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
            if ($stdoutPath) {
                Set-Content -Encoding UTF8 -LiteralPath $stdoutPath -Value $out 
            }
            if ($stderrPath) {
                Set-Content -Encoding UTF8 -LiteralPath $stderrPath -Value $err 
            }
            return @{ Code = $p.ExitCode; StdOut = $out; StdErr = $err }
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
            throw 'Could not locate MusicXML in MXL.'
        }

        function Find-SoundFont([string]$Hint) {
            if ($Hint -and (Test-Path $Hint)) {
                return (Resolve-Path $Hint).Path 
            }
            $cands = @(
                "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf3",
                "$env:USERPROFILE\Documents\MuseScore4\SoundFonts\*.sf2",
                "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf3",
                "$env:USERPROFILE\Documents\MuseScore3\Soundfonts\*.sf2",
                'C:\Program Files\MuseScore 4\resources\soundfonts\*.sf3',
                'C:\Program Files\MuseScore 3\sound\*.sf3'
            )
            foreach ($p in $cands) {
                $hit = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue | Select-Object -First 1; if ($hit) {
                    return (Resolve-Path $hit.FullName).Path 
                } 
            }
            return $null
        }

        # Prefer MS4/Studio; keep MS3 as fallback because MS4 CLI can silently fail.
        $MS4 = if ($MuseScorePath) {
            $MuseScorePath 
        }
        else {
            Resolve-Exe @(
                'C:\Program Files\MuseScore Studio 4\bin\MuseScoreStudio.exe',
                'C:\Program Files\MuseScore 4\bin\MuseScore4.exe',
                'MuseScoreStudio.exe', 'MuseScore4.exe'
            )
        }
        $MS3 = Resolve-Exe @('C:\Program Files\MuseScore 3\bin\MuseScore3.exe', 'MuseScore3.exe', 'mscore.exe')

        if (-not $MS4 -and -not $MS3) {
            throw 'MuseScore not found. Install MuseScore Studio 4 or MuseScore 3, or pass -MuseScorePath.' 
        }

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

        # Normalize requested formats
        $fmt = @()
        foreach ($f in $Format) {
            if (-not $f) {
                continue 
            }
            $x = $f.ToLowerInvariant(); if ($x -eq 'midi') {
                $x = 'mid' 
            }
            if ($fmt -notcontains $x) {
                $fmt += $x 
            }
        }

        # Normalize input
        $ext = [IO.Path]::GetExtension($inAbs).ToLowerInvariant()
        $jobInput = if ($ext -eq '.mxl') {
            Expand-Mxl $inAbs (Join-Path $work 'unzipped') 
        }
        else {
            $inAbs 
        }
        if ([IO.Path]::GetExtension($jobInput).ToLowerInvariant() -eq '.xml') {
            $xmlCopy = Join-Path $work ($baseName + '.musicxml')
            Copy-Item -LiteralPath $jobInput -Destination $xmlCopy -Force
            $jobInput = $xmlCopy
        }

        # Targets
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

        $present = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        # Helper: try one exporter (exe) for one format
        function Invoke-MuseScoreExport([string]$Exe, [string]$inFile, [string]$fmtKey, [string]$outFile) {
            $argList = @('-w', '-f', '-o', $outFile, $inFile)  # -o = converter mode; -w = no webview; -f = ignore warnings
            if ($SoundProfile) {
                $argList += @('--sound-profile', $SoundProfile) 
            }
            $so = Join-Path $work "ms-$fmtKey.stdout.$([IO.Path]::GetFileNameWithoutExtension($Exe)).log"
            $se = Join-Path $work "ms-$fmtKey.stderr.$([IO.Path]::GetFileNameWithoutExtension($Exe)).log"
            $envExtra = @{ 'SKIP_LIBJACK' = '1'; 'QT_QPA_PLATFORM' = 'offscreen' }
            Write-Verbose ("[MuseScore] {0}`nArgs: {1}" -f $Exe, ($argList -join ' '))
            $res = Invoke-Process -exe $Exe -arguments $argList -stdoutPath $so -stderrPath $se -envExtra $envExtra
            return $res
        }

        foreach ($kv in $targets.GetEnumerator()) {
            $k = $kv.Key; $out = $kv.Value

            # Try MS4 first (if available), else MS3
            $attempts = @(); if ($MS4) {
                $attempts += @{ Name = 'MS4'; Exe = $MS4 } 
            } ; if ($MS3) {
                $attempts += @{ Name = 'MS3'; Exe = $MS3 } 
            }

            $ok = $false; $last = $null
            foreach ($a in $attempts) {
                $last = Invoke-MuseScoreExport -Exe $a.Exe -inFile $jobInput -fmtKey $k -outFile $out
                if ((Test-Path $out) -and ((Get-Item $out).Length -gt 0)) {
                    $ok = $true; break 
                }
                # If MS4 produced nothing, automatically try MS3 next
            }

            if ($ok) {
                $null = $present.Add($k); continue 
            }

            # If audio failed, attempt FluidSynth fallback from a MIDI export
            if ($k -in @('wav', 'mp3', 'flac', 'ogg')) {
                $midPath = Join-Path $OutDir ('{0}.mid' -f $baseName)
                if ($Force -and (Test-Path $midPath)) {
                    Remove-Item -LiteralPath $midPath -Force 
                }

                $midiOk = $false
                foreach ($a in $attempts) {
                    $midArgs = @('-w', '-f', '-o', $midPath, $jobInput)
                    $r = Invoke-Process -exe $a.Exe -arguments $midArgs -stdoutPath (Join-Path $work 'ms-mid.stdout.log') -stderrPath (Join-Path $work 'ms-mid.stderr.log') -envExtra @{ 'SKIP_LIBJACK' = '1'; 'QT_QPA_PLATFORM' = 'offscreen' }
                    if ((Test-Path $midPath) -and ((Get-Item $midPath).Length -gt 0)) {
                        $midiOk = $true; break 
                    }
                }
                if (-not $midiOk) {
                    throw "MuseScore export failed for '$k' and couldn't produce a MIDI for fallback. See logs in $work" 
                }

                if (-not $FluidSynthPath) {
                    throw 'Audio export failed and FluidSynth is missing. Install fluidsynth or pass -FluidSynthPath.' 
                }
                $sf = Find-SoundFont -Hint $SoundFont
                if (-not $sf) {
                    throw 'Audio export failed and no SoundFont (.sf2/.sf3) found. Place one in Documents\MuseScore4\SoundFonts or pass -SoundFont.' 
                }

                $wavPath = if ($k -eq 'wav') {
                    $out 
                }
                else {
                    Join-Path $OutDir ('{0}.wav' -f $baseName) 
                }
                if ($Force -and (Test-Path $wavPath)) {
                    Remove-Item -LiteralPath $wavPath -Force 
                }

                $fsArgs = @('-ni', '-F', $wavPath, '-r', $SampleRate.ToString(), $sf, $midPath)
                $fs = Invoke-Process -exe $FluidSynthPath -arguments $fsArgs -stdoutPath (Join-Path $work 'fluidsynth.stdout.log') -stderrPath (Join-Path $work 'fluidsynth.stderr.log')
                if ($fs.Code -ne 0 -or -not (Test-Path $wavPath)) {
                    throw "FluidSynth rendering failed (exit $($fs.Code)). See logs in $work" 
                }

                if ($k -eq 'wav') {
                    $null = $present.Add('wav'); continue 
                }

                if (-not $FFmpegPath) {
                    throw "Need FFmpeg for '$k' encoding. Install ffmpeg or pass -FFmpegPath." 
                }
                switch ($k) {
                    'mp3' {
                        $encArgs = @('-y', '-loglevel', 'error', '-i', $wavPath, '-b:a', ("$BitrateKbps" + 'k'), $out) 
                    }
                    'ogg' {
                        $encArgs = @('-y', '-loglevel', 'error', '-i', $wavPath, '-c:a', 'libvorbis', '-qscale:a', '5', $out) 
                    }
                    'flac' {
                        $encArgs = @('-y', '-loglevel', 'error', '-i', $wavPath, '-c:a', 'flac', $out) 
                    }
                }
                $ff = Invoke-Process -exe $FFmpegPath -arguments $encArgs -stdoutPath (Join-Path $work "ffmpeg.$k.stdout.log") -stderrPath (Join-Path $work "ffmpeg.$k.stderr.log")
                if ($ff.Code -ne 0 -or -not (Test-Path $out)) {
                    throw "FFmpeg $k encode failed (exit $($ff.Code)). See logs in $work" 
                }
                $null = $present.Add($k)
            }
            else {
                # Non-audio format failed (e.g., mid) – surface last stderr lines
                $tail = ($last.StdErr -split "`r?`n") | Select-Object -Last 12 -ErrorAction SilentlyContinue
                $tail = ($tail -join [Environment]::NewLine)
                throw "MuseScore export failed for '$k' (no output). Last stderr lines:`n$tail`nSee logs in $work"
            }
        }

        # Verify all targets exist
        $missing = @()
        foreach ($k in $targets.Keys) {
            $p = $targets[$k]; if (-not (Test-Path $p) -or ((Get-Item $p).Length -eq 0)) {
                $missing += $p 
            } 
        }
        if ($missing.Count -gt 0) {
            throw "Completed with errors: missing/empty outputs:`n - " + ($missing -join "`n - ") + "`nSee logs in $work" 
        }

        if ($PassThru) {
            [PSCustomObject]@{
                InputScore   = $jobInput
                MuseScore4   = $MS4
                MuseScore3   = $MS3
                Outputs      = ($targets.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Value })
                UsedFallback = $false
                WorkDir      = $work
                SampleRate   = $SampleRate
                BitrateKbps  = $BitrateKbps
            }
        }
        else {
            Write-Host ('Input: {0}' -f $jobInput)
            if ($MS4) {
                Write-Host ('MuseScore4: {0}' -f $MS4) 
            }
            if ($MS3) {
                Write-Host ('MuseScore3: {0}' -f $MS3) 
            }
            Write-Host 'Outputs:'; $targets.GetEnumerator() | Sort-Object Key | ForEach-Object { Write-Host (' - {0}' -f $_.Value) }
            Write-Host ('Logs/work: {0}' -f $work)
        }
    }
}
