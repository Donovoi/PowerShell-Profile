function Invoke-Whispercpp {
    <#
.SYNOPSIS
Ensures whisper.cpp prebuilt binaries + model are present on Windows and starts live microphone -> English translation.

.DESCRIPTION
Idempotently:
  1) Downloads latest prebuilt whisper.cpp Windows binaries from GitHub releases.
  2) Ensures a multilingual model (default: ggml-small.bin) is downloaded.
  3) Starts whisper-stream with -l auto -tr (auto-detect language, translate to English).

.PARAMETER InstallDir
Base directory for install + models. Default: $env:ProgramData\WhisperCPP

.PARAMETER Model
Multilingual Whisper model file name to fetch if missing (e.g., ggml-small.bin, ggml-medium.bin, ggml-large-v3.bin).
Default: ggml-small.bin  (do NOT use *.en for translation)

.PARAMETER Update
Force re-download of binaries even if they already exist.

.PARAMETER Start
After ensuring install, launch whisper-stream and attach to console.

.PARAMETER Threads
Number of compute threads to pass to whisper-stream (-t). Default: [Environment]::ProcessorCount

.PARAMETER CaptureIndex
Input device index to capture from (whisper-stream --capture N). Omit to use default device.

.PARAMETER UseBLAS
Use BLAS-accelerated binaries (slightly faster on CPU). Default: $false

.PARAMETER WhatIf
Preview steps without changing system (standard PowerShell what-if).

.NOTES
- Uses official prebuilt Windows binaries from whisper.cpp GitHub releases.
- Uses Hugging Face "ggerganov/whisper.cpp" model hosting for model binaries.
- Includes SDL2 for audio capture built-in.

.EXAMPLE
Invoke-Whispercpp -Start

.EXAMPLE
Invoke-Whispercpp -Model ggml-medium.bin -Start -Threads 8

.EXAMPLE
Invoke-Whispercpp -Update -Start -CaptureIndex 1 -UseBLAS
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$InstallDir = "$env:ProgramData\WhisperCPP",
        [ValidatePattern('^ggml-.*\.bin$')]
        [string]$Model = 'ggml-small.bin',
        [switch]$Update,
        [switch]$Start,
        [int]$Threads = [Environment]::ProcessorCount,
        [int]$CaptureIndex,
        [switch]$UseBLAS
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
    }

    process {
        # Directories
        $binDir = Join-Path $InstallDir 'bin'
        $modelDir = Join-Path $InstallDir 'models'
        $modelPath = Join-Path $modelDir $Model
        $streamExe = Join-Path $binDir 'whisper-stream.exe'

        if ($PSCmdlet.ShouldProcess($InstallDir, 'Prepare install layout')) {
            Initialize-Directory $InstallDir; Initialize-Directory $binDir; Initialize-Directory $modelDir
        }

        # 1) Download prebuilt Windows binaries if needed
        $needDownload = $Update -or -not (Test-Path $streamExe)
        
        if ($needDownload) {
            Write-Step 'Fetching latest whisper.cpp release info...'
            $releasesUri = 'https://api.github.com/repos/ggerganov/whisper.cpp/releases/latest'
            $release = Invoke-RestMethod -Uri $releasesUri
            
            $assetName = if ($UseBLAS) {
                'whisper-blas-bin-Win32.zip' 
            }
            else {
                'whisper-bin-Win32.zip' 
            }
            $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
            
            if (-not $asset) {
                throw "Could not find Windows binary asset '$assetName' in latest release"
            }
            
            Write-Step "Downloading whisper.cpp $($release.tag_name) Windows binaries ($assetName)..."
            $zipPath = Join-Path $env:TEMP $assetName
            
            if ($PSCmdlet.ShouldProcess($asset.browser_download_url, 'Download Windows binaries')) {
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
                
                Write-Step 'Extracting binaries...'
                Expand-Archive -Path $zipPath -DestinationPath $binDir -Force
                Remove-Item $zipPath -Force
                
                # Move files if they're in a subdirectory
                $extractedFiles = Get-ChildItem -Path $binDir -Recurse -Filter '*.exe'
                foreach ($file in $extractedFiles) {
                    if ($file.Directory.FullName -ne $binDir) {
                        Move-Item -Path $file.FullName -Destination $binDir -Force
                    }
                }
                
                # Move DLLs too
                $extractedDlls = Get-ChildItem -Path $binDir -Recurse -Filter '*.dll'
                foreach ($dll in $extractedDlls) {
                    if ($dll.Directory.FullName -ne $binDir) {
                        Move-Item -Path $dll.FullName -Destination $binDir -Force
                    }
                }
                
                # Clean up empty subdirectories
                Get-ChildItem -Path $binDir -Directory | ForEach-Object {
                    if (-not (Get-ChildItem -Path $_.FullName -Recurse -File)) {
                        Remove-Item -Path $_.FullName -Recurse -Force
                    }
                }
                
                if (-not (Test-Path $streamExe)) {
                    throw "whisper-stream.exe not found after extraction. Check $binDir for available binaries."
                }
                
                Write-Step "Binaries installed to: $binDir"
            }
        }

        # 2) Model (multilingual only; DO NOT use *.en for translation)
        if (-not (Test-Path $modelPath)) {
            if ($PSCmdlet.ShouldProcess($modelPath, "Download model $Model")) {
                $hfBase = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main'
                $uri = "$hfBase/$Model"
                Write-Step "Fetching model: $uri"
                Write-Step 'This may take a while (models are 75MB-3GB)...'
                Invoke-WebRequest -Uri $uri -OutFile $modelPath
                Write-Step "Model downloaded: $modelPath"
            }
        }

        # 3) Start whisper-stream with translation
        if ($Start) {
            $arguments = @('-m', $modelPath, '-t', $Threads, '-l', 'auto', '-tr')
            if ($PSBoundParameters.ContainsKey('CaptureIndex')) {
                $arguments += @('--capture', $CaptureIndex)
            }

            Write-Step "Starting whisper-stream: `"$streamExe`" $($arguments -join ' ')"
            Write-Step 'Speak into your microphone. Press Ctrl+C to stop.'
            
            # Attach directly so user can Ctrl+C to exit
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $streamExe
            $psi.Arguments = ($arguments -join ' ')
            $psi.WorkingDirectory = $binDir
            $psi.RedirectStandardOutput = $false
            $psi.RedirectStandardError = $false
            $psi.UseShellExecute = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.WaitForExit() | Out-Null
            return
        }

        Write-Step 'Ready. Run again with -Start to begin live mic → English.'
        Write-Step "Available executables in ${binDir}:"
        Get-ChildItem -Path $binDir -Filter '*.exe' | Select-Object Name | Format-Table -AutoSize
    }
}
