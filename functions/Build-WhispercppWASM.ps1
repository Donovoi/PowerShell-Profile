function Build-WhispercppWASM {
    <#
.SYNOPSIS
Builds whisper.cpp for WebAssembly (WASM) to run in browsers and mobile devices.

.DESCRIPTION
Builds whisper.cpp using Emscripten to create a WASM binary that can run in web browsers,
enabling speech-to-text transcription on mobile devices without native apps.

Requirements:
- Emscripten SDK (automatically downloaded if not present)
- Python 3.x (for Emscripten)

.PARAMETER InstallDir
Base directory for whisper.cpp source. Default: $env:ProgramData\WhisperCPP

.PARAMETER OutputDir
Directory to output WASM files for web deployment. Default: <InstallDir>\wasm-build

.PARAMETER Model
Whisper model to bundle with WASM. Default: ggml-base.en.bin (smallest for web)

.PARAMETER SkipEmscriptenInstall
Skip Emscripten SDK installation check (use if already installed).

.EXAMPLE
Build-WhispercppWASM

.EXAMPLE
Build-WhispercppWASM -Model ggml-small.bin -OutputDir "C:\inetpub\wwwroot\whisper"

.NOTES
- WASM build is significantly slower than native but works on any device with a browser
- Recommended models for web: ggml-tiny.en.bin (75MB) or ggml-base.en.bin (142MB)
- Deploy OutputDir contents to any web server (nginx, IIS, Apache, or GitHub Pages)
- Requires HTTPS for microphone access in browsers
- Mobile browsers (iOS Safari, Chrome Android) fully supported
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$InstallDir = "$env:ProgramData\WhisperCPP",
        [string]$OutputDir,
        [ValidatePattern('^ggml-.*\.bin$')]
        [string]$Model = 'ggml-base.en.bin',
        [switch]$SkipEmscriptenInstall
    )

    begin {
        $ErrorActionPreference = 'Stop'
        
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
        $srcDir = Join-Path $InstallDir 'src'
        $repoDir = Join-Path $srcDir 'whisper.cpp'
        
        if (-not $OutputDir) {
            $OutputDir = Join-Path $InstallDir 'wasm-build'
        }
        
        # Check if whisper.cpp source exists
        if (-not (Test-Path $repoDir)) {
            throw "Whisper.cpp source not found at $repoDir. Run Invoke-Whispercpp first to clone the repository."
        }
        
        # Emscripten SDK setup
        $emsdk = Join-Path $InstallDir 'emsdk'
        if (-not $SkipEmscriptenInstall -and -not (Test-Path $emsdk)) {
            Write-Step 'Emscripten SDK not found. Installing...'
            if ($PSCmdlet.ShouldProcess($emsdk, 'Clone and install Emscripten SDK')) {
                Push-Location $InstallDir
                try {
                    Write-Step 'Cloning Emscripten SDK...'
                    git clone https://github.com/emscripten-core/emsdk.git $emsdk 2>&1 | Out-Null
                    
                    Push-Location $emsdk
                    try {
                        Write-Step 'Installing latest Emscripten (this may take 5-10 minutes)...'
                        .\emsdk.ps1 install latest 2>&1 | Out-Null
                        .\emsdk.ps1 activate latest 2>&1 | Out-Null
                    }
                    finally {
                        Pop-Location
                    }
                }
                finally {
                    Pop-Location
                }
            }
        }
        
        # Activate Emscripten environment
        if (Test-Path $emsdk) {
            Write-Step 'Activating Emscripten environment...'
            Push-Location $emsdk
            try {
                # Source the environment (PowerShell version)
                $emsdkEnv = Join-Path $emsdk 'emsdk_env.ps1'
                if (Test-Path $emsdkEnv) {
                    & $emsdkEnv
                }
                else {
                    Write-Warning 'emsdk_env.ps1 not found. Attempting manual activation...'
                    .\emsdk.ps1 activate latest
                }
            }
            finally {
                Pop-Location
            }
        }
        
        # Check for emcmake
        $emcmake = Get-Command emcmake -ErrorAction SilentlyContinue
        if (-not $emcmake) {
            throw 'emcmake not found in PATH. Emscripten may not be installed correctly. Try running: emsdk activate latest'
        }
        
        # Build WASM
        Write-Step 'Building whisper.cpp for WebAssembly...'
        if ($PSCmdlet.ShouldProcess($repoDir, 'Build WASM with Emscripten')) {
            Push-Location $repoDir
            try {
                $wasmBuildDir = Join-Path $repoDir 'build-wasm'
                
                # Configure with Emscripten
                Write-Step 'Configuring CMake for WASM...'
                emcmake cmake -B $wasmBuildDir `
                    -DWHISPER_WASM=ON `
                    -DWHISPER_SDL2=OFF `
                    -DGGML_CUDA=OFF
                
                if ($LASTEXITCODE -ne 0) {
                    throw "CMake configuration failed with exit code $LASTEXITCODE"
                }
                
                # Build
                Write-Step 'Compiling WASM (this may take several minutes)...'
                cmake --build $wasmBuildDir --config Release
                
                if ($LASTEXITCODE -ne 0) {
                    throw "Build failed with exit code $LASTEXITCODE"
                }
                
                # Copy WASM files to output directory
                Write-Step 'Copying WASM files to output directory...'
                Initialize-Directory $OutputDir
                
                $wasmFiles = Get-ChildItem $wasmBuildDir -Recurse -Include *.wasm, *.js, *.html
                foreach ($file in $wasmFiles) {
                    Copy-Item $file.FullName $OutputDir -Force
                    Write-Verbose "Copied: $($file.Name)"
                }
                
                # Copy model if specified
                $modelDir = Join-Path $InstallDir 'models'
                $modelPath = Join-Path $modelDir $Model
                if (Test-Path $modelPath) {
                    Write-Step "Copying model $Model to output..."
                    Copy-Item $modelPath $OutputDir -Force
                }
                else {
                    Write-Warning "Model $Model not found. You'll need to download it separately."
                    Write-Warning 'Run: Invoke-Whispercpp (without -Start) to download the model.'
                }
                
                Write-Step 'WASM build complete!'
                Write-Host ''
                Write-Host 'Deployment Instructions:' -ForegroundColor Green
                Write-Host "1. Deploy the contents of $OutputDir to your web server" -ForegroundColor Yellow
                Write-Host '2. Ensure HTTPS is enabled (required for microphone access)' -ForegroundColor Yellow
                Write-Host '3. Open the HTML file in a browser on any device' -ForegroundColor Yellow
                Write-Host ''
                Write-Host 'Files ready for deployment:' -ForegroundColor Green
                Get-ChildItem $OutputDir | ForEach-Object {
                    Write-Host "  - $($_.Name)" -ForegroundColor Cyan
                }
                Write-Host ''
                Write-Host 'Example deployment commands:' -ForegroundColor Green
                Write-Host '  # GitHub Pages: Copy to docs/ folder and commit' -ForegroundColor Gray
                Write-Host '  # Nginx: Copy to /var/www/html/whisper/' -ForegroundColor Gray
                Write-Host '  # IIS: Copy to C:\\inetpub\\wwwroot\\whisper\\' -ForegroundColor Gray
                Write-Host "  # Test locally: python -m http.server 8000 (in $OutputDir)" -ForegroundColor Gray
            }
            finally {
                Pop-Location
            }
        }
    }
}
