function Invoke-Whispercpp {
    <#
.SYNOPSIS
Builds whisper.cpp from source with SDL3 and CUDA support on Windows.

.DESCRIPTION
Idempotently:
  1) Ensures prerequisites (git, cmake, MSVC Build Tools 2022, vcpkg).
  2) Installs SDL2 via vcpkg.
  3) Clones whisper.cpp.
  4) Builds with CUDA support if NVIDIA GPU detected.
  5) Starts whisper-stream with -l auto -tr (auto-detect language, translate to English).

.PARAMETER InstallDir
Base directory for install + models. Default: $env:ProgramData\WhisperCPP

.PARAMETER Model
Multilingual Whisper model file name (e.g., ggml-small.bin, ggml-medium.bin, ggml-large-v3.bin).
Default: ggml-small.bin

.PARAMETER RepoUrl
Upstream repository. Default: https://github.com/ggml-org/whisper.cpp.git

.PARAMETER Update
Force git pull + rebuild.

.PARAMETER Start
After ensuring install, launch whisper-stream and attach to console.

.PARAMETER Threads
Number of compute threads to pass to whisper-stream (-t). Default: [Environment]::ProcessorCount

.PARAMETER CaptureIndex
Audio input device index. Omit for default device.

.PARAMETER WhatIf
Preview steps without changing system (standard PowerShell what-if).

.NOTES
- Builds from source with SDL2 for audio capture.
- Automatically enables CUDA if NVIDIA GPU + CUDA Toolkit detected.
- Requires VS Build Tools 2022 or newer.

.EXAMPLE
Invoke-Whispercpp -Start

.EXAMPLE
Invoke-Whispercpp -Model ggml-large-v3.bin -Start -Threads 8

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
                $null = Get-Command $name -ErrorAction Stop
                $true 
            }
            catch {
                $false 
            } 
        }
        
        function Use-WingetInstall($id) {
            if (-not (Test-Cmd winget)) {
                return $false 
            }
            Write-Step "Installing $id via winget..."
            winget install --id $id --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
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
        $streamExe = Join-Path $stageDir 'whisper-stream.exe'

        if ($PSCmdlet.ShouldProcess($InstallDir, 'Prepare install layout')) {
            Initialize-Directory $InstallDir
            Initialize-Directory $srcDir
            Initialize-Directory $stageDir
            Initialize-Directory $modelDir
        }

        # 1) Prerequisites
        if (-not (Test-Cmd git)) {
            if (-not (Use-WingetInstall 'Git.Git')) {
                throw 'git not found. Install Git and re-run.' 
            }
            $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
        }
        
        if (-not (Test-Cmd cmake)) {
            if (-not (Use-WingetInstall 'Kitware.CMake')) {
                throw 'cmake not found. Install CMake and re-run.' 
            }
            $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
            
            if (-not (Test-Cmd cmake)) {
                throw 'cmake was installed but not found in PATH. Please restart your terminal.'
            }
        }

        # Check for VS 2022 Build Tools (required for SDL3 C++20 and CUDA support)
        $vs2022InstallPath = $null
        try {
            $vs2022Key = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\VisualStudio\SxS\VS7' -Name '17.0' -ErrorAction SilentlyContinue
            if ($vs2022Key) {
                $vs2022InstallPath = $vs2022Key.'17.0'
            }
        }
        catch {
            # Key doesn't exist
        }
        
        if (-not $vs2022InstallPath -or -not (Test-Path $vs2022InstallPath)) {
            Write-Step 'VS Build Tools 2022 not found. Installing...'
            Write-Warning 'This may take 10-15 minutes and requires ~5GB disk space.'
            Write-Warning 'The installer may open a GUI - please follow prompts if needed.'
            if ($PSCmdlet.ShouldProcess('VS Build Tools 2022', 'Install via winget')) {
                # Try winget installation
                $result = Use-WingetInstall 'Microsoft.VisualStudio.2022.BuildTools'
                
                if ($result) {
                    Write-Step 'Waiting for VS 2022 installation to complete...'
                    # Wait and re-check multiple times
                    for ($i = 1; $i -le 12; $i++) {
                        Start-Sleep -Seconds 10
                        
                        # Check both x64 and x86 registry paths
                        $registryPaths = @(
                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\SxS\VS7',
                            'HKLM:\SOFTWARE\Microsoft\VisualStudio\SxS\VS7'
                        )
                        
                        $found = $false
                        foreach ($regPath in $registryPaths) {
                            if (Test-Path $regPath) {
                                $vs2022Key = Get-ItemProperty -Path $regPath -Name '17.0' -ErrorAction SilentlyContinue
                                if ($vs2022Key -and $vs2022Key.'17.0') {
                                    $vs2022InstallPath = $vs2022Key.'17.0'
                                    if (Test-Path $vs2022InstallPath) {
                                        Write-Step 'VS 2022 installation detected!'
                                        $found = $true
                                        break
                                    }
                                }
                            }
                        }
                        
                        if ($found) {
                            break 
                        }
                        Write-Host '.' -NoNewline
                    }
                    Write-Host ''
                }
            }
        }
        
        # Determine which Visual Studio version to use
        # Try vswhere.exe first (most reliable method)
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        $vs2019InstallPath = $null
        $vs2017InstallPath = $null
        
        if ((Test-Path $vswhere) -and -not $vs2022InstallPath) {
            Write-Step 'Using vswhere.exe to detect Visual Studio installations...'
            
            # Look for latest VS with C++ tools
            $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
            if ($vsPath -and (Test-Path $vsPath)) {
                $vsVersionOutput = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationVersion 2>$null
                if ($vsVersionOutput -match '^(\d+)\.') {
                    $vsMajor = $matches[1]
                    if ($vsMajor -eq '17') {
                        Write-Step "vswhere detected VS 2022: $vsPath"
                        $vs2022InstallPath = $vsPath
                    }
                    elseif ($vsMajor -eq '16') {
                        Write-Step "vswhere detected VS 2019: $vsPath"
                        $vs2019InstallPath = $vsPath
                    }
                    elseif ($vsMajor -eq '15') {
                        Write-Step "vswhere detected VS 2017: $vsPath"
                        $vs2017InstallPath = $vsPath
                    }
                }
            }
        }
        
        $vsGenerator = $null
        $vsVersion = $null
        
        if ($vs2022InstallPath -and (Test-Path $vs2022InstallPath)) {
            Write-Step "VS 2022 Build Tools found: $vs2022InstallPath"
            $vsGenerator = 'Visual Studio 17 2022'
            $vsVersion = '2022'
            
            # Set environment variable to force CMake to use VS 2022
            $env:VS170COMNTOOLS = Join-Path $vs2022InstallPath 'Common7\Tools\'
            
            # Add VS 2022 to PATH to ensure it's found first
            $vs2022BinPath = Join-Path $vs2022InstallPath 'MSBuild\Current\Bin'
            if (Test-Path $vs2022BinPath) {
                $env:Path = "$vs2022BinPath;$env:Path"
            }
        }
        elseif ($vs2019InstallPath -and (Test-Path $vs2019InstallPath)) {
            Write-Step "VS 2019 Build Tools found: $vs2019InstallPath"
            $vsGenerator = 'Visual Studio 16 2019'
            $vsVersion = '2019'
        }
        elseif ($vs2017InstallPath -and (Test-Path $vs2017InstallPath)) {
            Write-Step "VS 2017 Build Tools found: $vs2017InstallPath"
            $vsGenerator = 'Visual Studio 15 2017'
            $vsVersion = '2017'
            Write-Warning 'VS 2017 detected - CUDA will be disabled (requires VS 2019+).'
            Write-Warning 'VS 2017 may also have issues with SDL3 C++20 features.'
            Write-Warning 'For best results, install VS 2022: winget install Microsoft.VisualStudio.2022.BuildTools'
        }
        else {
            # Final fallback: check registry if vswhere didn't find anything
            Write-Warning 'No Visual Studio found via vswhere. Checking registry...'
            
            $registryPaths = @(
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\SxS\VS7',
                'HKLM:\SOFTWARE\Microsoft\VisualStudio\SxS\VS7'
            )
            
            $vsFound = $false
            foreach ($regPath in $registryPaths) {
                if (-not $vsFound -and (Test-Path $regPath)) {
                    # Check VS 2019
                    try {
                        $vs2019Key = Get-ItemProperty -Path $regPath -Name '16.0' -ErrorAction SilentlyContinue
                        if ($vs2019Key -and $vs2019Key.'16.0' -and (Test-Path $vs2019Key.'16.0')) {
                            Write-Step "Registry: VS 2019 found at $($vs2019Key.'16.0')"
                            $vsGenerator = 'Visual Studio 16 2019'
                            $vsVersion = '2019'
                            $vsFound = $true
                            continue
                        }
                    }
                    catch {
                    }
                    
                    # Check VS 2017
                    try {
                        $vs2017Key = Get-ItemProperty -Path $regPath -Name '15.0' -ErrorAction SilentlyContinue
                        if ($vs2017Key -and $vs2017Key.'15.0' -and (Test-Path $vs2017Key.'15.0')) {
                            Write-Step "Registry: VS 2017 found at $($vs2017Key.'15.0')"
                            $vsGenerator = 'Visual Studio 15 2017'
                            $vsVersion = '2017'
                            $vsFound = $true
                            Write-Warning 'VS 2017 detected - CUDA will be disabled (requires VS 2019+).'
                            Write-Warning 'Consider installing VS 2022: winget install Microsoft.VisualStudio.2022.BuildTools'
                            continue
                        }
                    }
                    catch {
                    }
                }
            }
            
            if (-not $vsFound) {
                throw 'No Visual Studio installation found. Please install VS Build Tools 2022: winget install Microsoft.VisualStudio.2022.BuildTools'
            }
        }

        # vcpkg for SDL3
        $vcpkgDir = Join-Path $InstallDir 'vcpkg'
        $vcpkgExe = Join-Path $vcpkgDir 'vcpkg.exe'
        
        if (-not (Test-Path $vcpkgExe)) {
            Write-Step 'Installing vcpkg...'
            if ($PSCmdlet.ShouldProcess($vcpkgDir, 'Clone and bootstrap vcpkg')) {
                git clone https://github.com/microsoft/vcpkg.git $vcpkgDir 2>&1 | Out-Null
                Push-Location $vcpkgDir
                try {
                    .\bootstrap-vcpkg.bat -disableMetrics 2>&1 | Out-Null
                }
                finally {
                    Pop-Location
                }
            }
        }

        # Install SDL2
        Write-Step 'Installing SDL2 via vcpkg (x64-windows)...'
        if ($PSCmdlet.ShouldProcess('SDL2', 'Install via vcpkg')) {
            & $vcpkgExe install sdl2:x64-windows 2>&1 | Out-Null
            & $vcpkgExe integrate install 2>&1 | Out-Null
        }

        # Detect CUDA (but disable for VS 2017 or if VS doesn't have CUDA integration)
        $cudaEnabled = $false
        if ($vsVersion -eq '2017') {
            Write-Verbose 'CUDA detection skipped - VS 2017 does not support CUDA 13.0+'
        }
        else {
            try {
                $gpuInfo = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -like '*NVIDIA*' }
                
                if ($gpuInfo) {
                    Write-Step "NVIDIA GPU detected: $($gpuInfo.Name)"
                    
                    $cudaPath = $env:CUDA_PATH
                    if (-not $cudaPath) {
                        $cudaPath = Get-ChildItem 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA' -Directory -ErrorAction SilentlyContinue | 
                            Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
                    }
                    
                    if ($cudaPath -and (Test-Path $cudaPath)) {
                        # Check for nvcc compiler (full CUDA SDK)
                        $nvccPath = Join-Path $cudaPath 'bin\nvcc.exe'
                        if (Test-Path $nvccPath) {
                            # Check if VS has CUDA integration (Build Customizations)
                            $cudaPropsPath = $null
                            if ($vs2022InstallPath) {
                                $cudaPropsPath = Join-Path $vs2022InstallPath 'MSBuild\Microsoft\VC\*\BuildCustomizations\CUDA*.props'
                            }
                            elseif ($vs2019InstallPath) {
                                $cudaPropsPath = Join-Path $vs2019InstallPath 'MSBuild\Microsoft\VC\*\BuildCustomizations\CUDA*.props'
                            }
                            
                            $hasCudaIntegration = $false
                            if ($cudaPropsPath) {
                                $hasCudaIntegration = (Get-ChildItem $cudaPropsPath -ErrorAction SilentlyContinue).Count -gt 0
                            }
                            
                            if ($hasCudaIntegration) {
                                $cudaEnabled = $true
                                $env:CUDA_PATH = $cudaPath
                                Write-Step "CUDA Toolkit with nvcc compiler found: $cudaPath"
                            }
                            else {
                                Write-Warning "CUDA Toolkit found but Visual Studio $vsVersion lacks CUDA integration."
                                Write-Warning 'To enable CUDA support, install CUDA Build Customizations:'
                                Write-Warning '  1. Run CUDA installer again'
                                Write-Warning '  2. Choose "Custom" installation'
                                Write-Warning '  3. Select "Visual Studio Integration"'
                                Write-Warning 'Or install via: winget install Nvidia.CUDA --version 13.0'
                                Write-Warning 'Building without CUDA acceleration (CPU-only).'
                            }
                        }
                        else {
                            Write-Warning 'CUDA Toolkit found but nvcc compiler missing. Full CUDA SDK required for compilation.'
                            Write-Warning 'Download from: https://developer.nvidia.com/cuda-downloads'
                            Write-Warning 'Building without CUDA acceleration.'
                        }
                    }
                    else {
                        Write-Warning 'NVIDIA GPU found but CUDA Toolkit missing. Download from: https://developer.nvidia.com/cuda-downloads'
                        Write-Warning 'Building without CUDA acceleration.'
                    }
                }
            }
            catch {
                Write-Verbose 'Could not detect GPU information'
            }
        }

        # 2) Clone/update whisper.cpp
        if (Test-Path $repoDir) {
            if ($Update -and $PSCmdlet.ShouldProcess($repoDir, 'git pull')) {
                Push-Location $repoDir
                try {
                    git fetch --all 2>&1 | Out-Null
                    git reset --hard origin/master 2>&1 | Out-Null
                }
                finally {
                    Pop-Location 
                }
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($srcDir, 'git clone whisper.cpp')) {
                Write-Step 'Cloning whisper.cpp...'
                git clone $RepoUrl $repoDir 2>&1 | Out-Null
            }
        }

        # 3) whisper.cpp is ready to build with SDL2 (no patches needed)
        Write-Step 'Repository ready for SDL2 build...'        # Patch wchess CMakeLists.txt to guard all set_target_properties calls
        $wchessCMakePath = Join-Path $repoDir 'examples\wchess\CMakeLists.txt'
        if (Test-Path $wchessCMakePath) {
            $wchessContent = Get-Content $wchessCMakePath -Raw
            $nl = [Environment]::NewLine
            # Wrap each set_target_properties in a check for target existence
            # Replace set_target_properties(wchess-core ...) 
            $wchessContent = $wchessContent -replace '(set_target_properties\(wchess-core\s+[^)]+\))', "if(TARGET wchess-core)$nl    `$1$nl endif()"
            # Replace set_target_properties(wchess.wasm ...)
            $wchessContent = $wchessContent -replace '(set_target_properties\(wchess\.wasm\s+[^)]+\))', "if(TARGET wchess.wasm)$nl    `$1$nl endif()"
            # Replace set_target_properties(wchess ...) - must be last to not match wchess-core or wchess.wasm
            $wchessContent = $wchessContent -replace '(?<!-)(?<!\.)(set_target_properties\(wchess\s+[^)]+\))', "if(TARGET wchess)$nl    `$1$nl endif()"
            Set-Content -Path $wchessCMakePath -Value $wchessContent -NoNewline
        }

        # Patch whisper.cpp for M_PI
        $whisperCppPath = Join-Path $repoDir 'src\whisper.cpp'
        if (Test-Path $whisperCppPath) {
            $whisperContent = Get-Content $whisperCppPath -Raw
            if ($whisperContent -notmatch '#define _USE_MATH_DEFINES') {
                $whisperContent = "#define _USE_MATH_DEFINES`n" + $whisperContent
            }
            Set-Content -Path $whisperCppPath -Value $whisperContent -NoNewline
        }

        # 4) Build
        $needBuild = $Update -or -not (Test-Path $streamExe)
        
        if ($needBuild) {
            if ($PSCmdlet.ShouldProcess($repoDir, 'Build whisper-stream with SDL3')) {
                Push-Location $repoDir
                try {
                    # Clean build
                    if (Test-Path $buildDir) {
                        Remove-Item $buildDir -Recurse -Force
                    }
                    
                    Write-Step "Configuring CMake with SDL2 (using $vsVersion)..."
                    $cmakeArgs = @(
                        '-B', $buildDir,
                        '-G', $vsGenerator,
                        '-A', 'x64',
                        '-DWHISPER_SDL2=ON',
                        '-DWHISPER_WCHESS=OFF',
                        "-DCMAKE_TOOLCHAIN_FILE=$vcpkgDir\scripts\buildsystems\vcpkg.cmake",
                        '-DVCPKG_TARGET_TRIPLET=x64-windows'
                    )
                    
                    if ($cudaEnabled) {
                        $cmakeArgs += '-DGGML_CUDA=ON'
                        Write-Step 'CUDA enabled for GPU acceleration'
                    }
                    else {
                        $cmakeArgs += '-DGGML_CUDA=OFF'
                    }
                    
                    & cmake @cmakeArgs
                    
                    if ($LASTEXITCODE -ne 0) {
                        throw "CMake configuration failed with exit code $LASTEXITCODE"
                    }
                    
                    Write-Step 'Building whisper-stream (Release)...'
                    cmake --build $buildDir --config Release --target whisper-stream -j
                    
                    if ($LASTEXITCODE -ne 0) {
                        throw "Build failed with exit code $LASTEXITCODE"
                    }
                    
                    # Find built executable
                    $possiblePaths = @(
                        (Join-Path $binDir 'whisper-stream.exe'),
                        (Join-Path $buildDir 'bin\Release\whisper-stream.exe'),
                        (Join-Path $buildDir 'examples\stream\Release\whisper-stream.exe')
                    )
                    
                    $built = $possiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
                    
                    if (-not $built) {
                        $built = Get-ChildItem -Path $buildDir -Recurse -Filter 'whisper-stream.exe' -ErrorAction SilentlyContinue | 
                            Where-Object { $_.FullName -notlike '*\CMakeFiles\*' } |
                                Select-Object -First 1 -ExpandProperty FullName
                    }
                    
                    if (-not $built) {
                        throw 'whisper-stream.exe not found after build. Check build output for errors.'
                    }
                    
                    Write-Step "Built executable: $built"
                    Copy-Item $built $streamExe -Force
                    
                    # Copy required DLLs
                    $dllPaths = @(
                        (Join-Path $buildDir 'bin\Release\*.dll'),
                        (Join-Path $vcpkgDir 'installed\x64-windows\bin\SDL3.dll')
                    )
                    
                    foreach ($dllPattern in $dllPaths) {
                        Get-ChildItem $dllPattern -ErrorAction SilentlyContinue | ForEach-Object {
                            Copy-Item $_.FullName $stageDir -Force
                        }
                    }
                }
                finally {
                    Pop-Location 
                }
            }
        }

        # 5) Download model
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

        # 6) Start
        if ($Start) {
            $arguments = @('-m', $modelPath, '-t', $Threads, '-l', 'auto', '-tr')
            if ($PSBoundParameters.ContainsKey('CaptureIndex')) {
                $arguments += @('--capture', $CaptureIndex)
            }

            Write-Step "Starting whisper-stream (SDL3): `"$streamExe`""
            Write-Step "Arguments: $($arguments -join ' ')"
            Write-Step 'Speak into your microphone. Press Ctrl+C to stop.'
            
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

        Write-Step 'Ready! SDL2 audio capture configured. Run with -Start to begin live mic → English translation.'
    }
}
