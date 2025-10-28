function Convert-MidiToWav {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$MidiPath,

        # Path to a General MIDI-ish SoundFont (.sf2 or .sf3),
        # e.g. "C:\SoundFonts\GeneralUserGS.sf2"
        [Parameter(Mandatory = $true)]
        [string]$SoundFontPath,

        [Parameter()]
        [string]$OutDir = (Join-Path (Split-Path -Parent $MidiPath) 'audio-rendered'),

        [Parameter()]
        [int]$SampleRate = 44100,

        # fluidsynth.exe location (assume it's on PATH by default)
        [Parameter()]
        [string]$FluidsynthPath = 'fluidsynth.exe',

        [switch]$Force,
        [switch]$PassThru
    )

    $midiAbs = (Resolve-Path $MidiPath).Path
    if (-not (Test-Path $midiAbs)) {
        throw "MIDI '$midiAbs' not found." 
    }

    $sfAbs = (Resolve-Path $SoundFontPath).Path
    if (-not (Test-Path $sfAbs)) {
        throw "SoundFont '$sfAbs' not found." 
    }

    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir | Out-Null
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($midiAbs)
    $outFile = Join-Path $OutDir "$baseName.wav"
    $logFile = Join-Path $OutDir "$baseName.fluidsynth.log"

    if ((Test-Path $outFile) -and -not $Force) {
        throw "Output '$outFile' already exists. Use -Force to overwrite."
    }

    # fluidsynth offline render pattern (fast render):
    # fluidsynth -ni -F <out.wav> -T wav -r <rate> <soundfont.sf2> <song.mid>
    $fsArgs = @(
        '-ni',                       # no shell, no MIDI input
        '-F', $outFile,              # render to file
        '-T', 'wav',                 # file type = WAV
        '-r', $SampleRate,           # sample rate
        $sfAbs,                      # SoundFont
        $midiAbs                     # MIDI file
    )

    Write-Verbose ("[FluidSynth] {0}`nArgs: {1}" -f $FluidsynthPath, ($fsArgs -join ' '))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FluidsynthPath
    foreach ($a in $fsArgs) {
        [void]$psi.ArgumentList.Add($a) 
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $logContent = "STDOUT:`r`n$stdout`r`n`r`nSTDERR:`r`n$stderr"
    Set-Content -Path $logFile -Value $logContent

    $exitCode = $proc.ExitCode
    if ($exitCode -ne 0) {
        throw "fluidsynth failed with exit code $exitCode. See $logFile"
    }

    if (-not (Test-Path $outFile) -or ((Get-Item $outFile).Length -eq 0)) {
        throw "fluidsynth reported success but '$outFile' is missing or empty. See $logFile"
    }

    if ($PassThru) {
        [PSCustomObject]@{
            Midi       = $midiAbs
            SoundFont  = $sfAbs
            OutputFile = $outFile
            SampleRate = $SampleRate
            Log        = $logFile
            ExitCode   = $exitCode
            FluidSynth = $FluidsynthPath
        }
    }
}
