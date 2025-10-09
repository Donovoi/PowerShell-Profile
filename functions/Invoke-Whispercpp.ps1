function Invoke-Whispercpp {
    <#
.SYNOPSIS
Ensures whisper.cpp + model are present on Windows and starts live microphone -> English translation.

.DESCRIPTION
Idempotently:
  1) Ensures prerequisites (git, cmake, MSVC Build Tools) — installs via winget if missing.
  2) Clones or updates ggml-org/whisper.cpp.
  3) Builds Release binaries (MSVC) and stages whisper-stream.exe.
  4) Ensures a multilingual model (default: ggml-small.bin) is downloaded.
  5) Starts whisper-stream with -l auto -tr (auto-detect language, translate to English).

.PARAMETER InstallDir
Base directory for install + models. Default: $env:ProgramData\WhisperCPP

.PARAMETER Model
Multilingual Whisper model file name to fetch if missing (e.g., ggml-small.bin, ggml-medium.bin, ggml-large-v3.bin).
Default: ggml-small.bin  (do NOT use *.en for translation)

.PARAMETER RepoUrl
Upstream repository. Default: https://github.com/ggml-org/whisper.cpp.git

.PARAMETER Update
Force a git pull + rebuild even if binaries already exist.

.PARAMETER Start
After ensuring install, launch whisper-stream and attach to console.

.PARAMETER Threads
Number of compute threads to pass to whisper-stream (-t). Default: [Environment]::ProcessorCount

.PARAMETER CaptureIndex
Input device index to capture from (whisper-stream --capture N). Omit to use default device.

.PARAMETER WhatIf
Preview steps without changing system (standard PowerShell what-if).

.NOTES
- Requires an interactive shell with permission to run winget (for auto-install), or you already have git/cmake/MSVC.
- Uses Hugging Face “ggerganov/whisper.cpp” model hosting for model binaries.

.EXAMPLE
Invoke-Whispercpp -Start

.EXAMPLE
Invoke-Whispercpp -Model ggml-medium.bin -Start -Threads 8

.EXAMPLE
Invoke-Whispercpp -Update -Start -CaptureIndex 1
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$InstallDir = "$env:ProgramData\WhisperCPP",
        [ValidatePattern('^ggml-.*\.bin$')]
        [string]$Model = 'ggml-large-v3.bin',
        [string]$RepoUrl = 'https://github.com/ggml-org/whisper.cpp.git',
        [switch]$Update,
        [switch]$Start,
        [int]$Threads = [Environment]::ProcessorCount,
        [int]$CaptureIndex
    )

    begin {
        $ErrorActionPreference = 'Stop'
        $PSStyle.OutputRendering = 'Ansi'
        function Write-Step($msg) {
            Write-Host "[*] $msg" -ForegroundColor Cyan 
        }
        function Initialize-Directory([string]$p) {
            if (-not(Test-Path $p)) {
                New-Item -ItemType Directory -Path $p | Out-Null 
            } 
        }
        function Test-Cmd($name) {
            try {
                $null = Get-Command $name -ErrorAction Stop; $true 
            }
            catch {
                $false 
            } 
        }
        function Use-WingetInstall($id) {
            if (-not (Test-Cmd winget)) {
                return $false 
            }
            Write-Step "Installing $id via winget (may prompt for elevation/agreements)…"
            winget install --id $id --silent --accept-package-agreements --accept-source-agreements | Out-Null
            return $true
        }
    }

    process {
        # Directories
        $srcDir = Join-Path $InstallDir 'src'
        $repoDir = Join-Path $srcDir 'whisper.cpp'
        $buildDir = Join-Path $repoDir 'build'
        $binDir = Join-Path $buildDir 'bin\Release'
        $stageDir = Join-Path $InstallDir 'bin'
        $modelDir = Join-Path $InstallDir 'models'
        $modelPath = Join-Path $modelDir $Model

        if ($PSCmdlet.ShouldProcess($InstallDir, 'Prepare install layout')) {
            Initialize-Directory $InstallDir; Initialize-Directory $srcDir; Initialize-Directory $stageDir; Initialize-Directory $modelDir
        }

        # 1) Prereqs: git, cmake, MSVC Build Tools
        if (-not (Test-Cmd git)) {
            if (-not (Use-WingetInstall 'Git.Git')) {
                throw 'git not found. Install Git and re-run.' 
            }
        }
        if (-not (Test-Cmd cmake)) {
            if (-not (Use-WingetInstall 'Kitware.CMake')) {
                throw 'cmake not found. Install CMake and re-run.' 
            }
        }
        # VS Build Tools — we rely on CMake to locate MSVC; install if nothing found
        $haveMSVC = Test-Path 'HKLM:\SOFTWARE\Microsoft\VisualStudio\SxS\VS7' -or (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\SxS\VS7')
        if (-not $haveMSVC) {
            # Desktop C++ workload; on many machines this needs elevation / user acceptance
            Use-WingetInstall 'Microsoft.VisualStudio.2022.BuildTools' | Out-Null
        }

        # 2) Clone / update
        if (Test-Path $repoDir) {
            Push-Location $repoDir
            try {
                if ($Update -and $PSCmdlet.ShouldProcess($repoDir, 'git pull')) {
                    git fetch --all | Out-Null; git reset --hard origin/master | Out-Null
                }
            }
            finally {
                Pop-Location 
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($srcDir, 'git clone whisper.cpp')) {
                git clone $RepoUrl $repoDir | Out-Null
            }
        }

        # 3) Build (skip if whisper-stream.exe staged and not forcing update)
        $streamExe = Join-Path $stageDir 'whisper-stream.exe'
        $needBuild = $Update -or -not (Test-Path $streamExe)

        if ($needBuild) {
            if ($PSCmdlet.ShouldProcess($repoDir, 'Configure & build whisper-stream (Release)')) {
                Push-Location $repoDir
                try {
                    # Configure
                    cmake -B $buildDir | Out-Null
                    # Build Release
                    cmake --build $buildDir --config Release -j | Out-Null
                    # Stage binary
                    $built = Join-Path $binDir 'whisper-stream.exe'
                    if (-not (Test-Path $built)) {
                        throw "Build finished but $built not found. Open the repo in Visual Studio and build 'whisper-stream' target manually."
                    }
                    Copy-Item $built $streamExe -Force
                }
                finally {
                    Pop-Location 
                }
            }
        }

        # 4) Model (multilingual only; DO NOT use *.en for translation)
        if (-not (Test-Path $modelPath)) {
            if ($PSCmdlet.ShouldProcess($modelPath, "Download model $Model")) {
                $hfBase = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main'
                $uri = "$hfBase/$Model"
                Write-Step "Fetching model: $uri"
                Invoke-WebRequest -Uri $uri -OutFile $modelPath
            }
        }

        # 5) Start whisper-stream with translation
        if ($Start) {
            $arguments = @('-m', $modelPath, '-t', $Threads, '-l', 'auto', '-tr')
            if ($PSBoundParameters.ContainsKey('CaptureIndex')) {
                $arguments += @('--capture', $CaptureIndex)
            }

            Write-Step "Starting whisper-stream: `"$streamExe`" $($arguments -join ' ')"
            # Attach directly so user can Ctrl+C to exit
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $streamExe
            $psi.Arguments = ($arguments -join ' ')
            $psi.WorkingDirectory = $stageDir
            $psi.RedirectStandardOutput = $false
            $psi.RedirectStandardError = $false
            $psi.UseShellExecute = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.WaitForExit() | Out-Null
            return
        }

        Write-Step 'Ready. Run again with -Start to begin live mic → English.'
    }
}
