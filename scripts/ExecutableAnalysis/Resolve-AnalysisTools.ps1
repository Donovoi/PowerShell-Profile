function Resolve-AnalysisTool {
    [CmdletBinding()]
    param([string]$LogDirectory,[string]$ReaScriptPath,[switch]$NoInstall,[switch]$Managed,[switch]$Native,[switch]$Wasm,[switch]$Java)
    $tools = [ordered]@{ Node=$null; ReaScript=$null; Ghidra=$null; ILSpy=$null; WabtBin=$null; JadxDirectory=$null; JadxMcpJar=$null; Java=$null; Versions=[ordered]@{}; Limitations=[Collections.Generic.List[string]]::new() }
    function Save-VerifiedAnalysisDownload {
        param([string]$Uri,[string]$Destination,[string]$SHA256)
        if(-not(Test-Path -LiteralPath $Destination)) { Invoke-WebRequest -Uri $Uri -OutFile $Destination -TimeoutSec 600 -ErrorAction Stop }
        if((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $SHA256){throw 'Downloaded analysis dependency checksum mismatch.'}
    }
    $node = Get-Command node -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    $cacheRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PowerShellProfile/AnalysisTools'
    if (-not $node) { $tools.Limitations.Add('Node.js is unavailable. REA requires Node 22.19+, 24.11+ or 26+; independent decompilers are still attempted.') }
    else {
    $tools.Node=$node.Source
    $versionRun=Invoke-AnalysisTool $tools.Node @('--version') -LogPath (Join-Path $LogDirectory 'node-version') -WorkingDirectory $LogDirectory -TimeoutSeconds 20
    $tools.Versions.Node=[IO.File]::ReadAllText($versionRun.StandardOutputPath).Trim()
    if ($ReaScriptPath) {
        $tools.ReaScript=(Resolve-Path -LiteralPath $ReaScriptPath -ErrorAction Stop).ProviderPath
    } else {
        $candidates=[Collections.Generic.List[string]]::new()
        $candidates.Add((Join-Path $cacheRoot 'rea-6.7.0/node_modules/rea-agents/scripts/rea.mjs'))
        $npmCache=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'npm-cache/_npx'
        if(Test-Path -LiteralPath $npmCache) {
            foreach($directory in Get-ChildItem -LiteralPath $npmCache -Directory) { $candidates.Add((Join-Path $directory.FullName 'node_modules/rea-agents/scripts/rea.mjs')) }
        }
        foreach($candidate in $candidates) {
            if(Test-Path -LiteralPath $candidate -PathType Leaf) {
                $package=Join-Path (Split-Path (Split-Path $candidate -Parent) -Parent) 'package.json'
                if((Get-Content -LiteralPath $package -Raw|ConvertFrom-Json).version -eq '6.7.0') { $tools.ReaScript=$candidate;break }
            }
        }
        if(-not $tools.ReaScript -and -not $NoInstall) {
            $npm=Join-Path (Split-Path $tools.Node -Parent) 'node_modules/npm/bin/npm-cli.js'
            if(Test-Path -LiteralPath $npm) {
                $prefix=Join-Path $cacheRoot 'rea-6.7.0'
                $result=Invoke-AnalysisTool $tools.Node @($npm,'install','--prefix',$prefix,'--ignore-scripts','--no-audit','--no-fund','--no-package-lock','rea-agents@6.7.0') -LogPath (Join-Path $LogDirectory 'install-rea') -WorkingDirectory $LogDirectory -TimeoutSeconds 600
                $candidate=Join-Path $prefix 'node_modules/rea-agents/scripts/rea.mjs'
                if($result.Status -eq 'Completed' -and (Test-Path -LiteralPath $candidate)) { $tools.ReaScript=$candidate }
            }
        }
    }
    if($tools.ReaScript) {
        $package=Join-Path (Split-Path (Split-Path $tools.ReaScript -Parent) -Parent) 'package.json'
        $tools.Versions.REA=(Get-Content -LiteralPath $package -Raw|ConvertFrom-Json).version
        if($tools.Versions.REA -ne '6.7.0'){throw 'The validated bridge requires rea-agents 6.7.0.'}
    } else { $tools.Limitations.Add('REA is unavailable; retained basic identity and strings are not deep decompilation.') }
    }
    if($Native) {
        $candidates=[Collections.Generic.List[string]]::new()
        if($env:GHIDRA_INSTALL_DIR){$candidates.Add($env:GHIDRA_INSTALL_DIR)}
        foreach($parent in @((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs/Ghidra'),$cacheRoot)) {
            if(Test-Path -LiteralPath $parent){foreach($dir in Get-ChildItem -LiteralPath $parent -Directory -Filter 'ghidra_12.1*'){ $candidates.Add($dir.FullName) }}
        }
        foreach($candidate in $candidates) {
            $properties=Join-Path $candidate 'Ghidra/application.properties'
            if((Test-Path -LiteralPath $properties) -and (Get-Content -LiteralPath $properties | Select-String '^application.version=12\.1(?:\.|$)')) { $tools.Ghidra=$candidate;break }
        }
        if(-not $tools.Ghidra -and -not $NoInstall) {
            $null=[IO.Directory]::CreateDirectory($cacheRoot)
            $archive=Join-Path $cacheRoot ('ghidra-'+[guid]::NewGuid().ToString('N')+'.zip')
            try {
                Invoke-WebRequest -Uri 'https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip' -OutFile $archive -TimeoutSec 600 -ErrorAction Stop
                if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne 'DDAC49F903DA9D5BAC833E5CC79395098B9C33CFD3279BE5F31BD00387D2D4DB'){throw 'Ghidra archive checksum mismatch.'}
                $destination=Join-Path $cacheRoot 'ghidra_12.1.4_PUBLIC'
                if(Test-Path -LiteralPath $destination){throw 'Existing Ghidra destination requires manual verification.'}
                Expand-Archive -LiteralPath $archive -DestinationPath $cacheRoot -ErrorAction Stop
                if(-not(Test-Path -LiteralPath (Join-Path $destination 'support/analyzeHeadless.bat'))){throw 'Downloaded Ghidra has no Windows headless launcher.'}
                $tools.Ghidra=$destination
            } catch { $tools.Limitations.Add("Ghidra installation failed: $($_.Exception.Message)") }
        }
        if($tools.Ghidra){$tools.Versions.Ghidra=(Get-Content -LiteralPath (Join-Path $tools.Ghidra 'Ghidra/application.properties')|Select-String '^application.version=').Line.Split('=')[1]}
        else{$tools.Limitations.Add('No compatible Ghidra 12.1.x installation; native pseudocode remains unavailable.')}
    }
    if($Managed) {
        $ilspy=Get-Command ilspycmd -CommandType Application -ErrorAction Ignore|Select-Object -First 1
        $tools.ILSpy=if($ilspy){$ilspy.Source}else{$null}
        $privateTool=Join-Path $cacheRoot 'ilspy-11.1.0.9782/ilspycmd.exe'
        if(-not $tools.ILSpy -and (Test-Path -LiteralPath $privateTool)){$tools.ILSpy=$privateTool}
        $dotnet=Get-Command dotnet -CommandType Application -ErrorAction Ignore|Select-Object -First 1
        if(-not $tools.ILSpy -and $dotnet -and -not $NoInstall) {
            $result=Invoke-AnalysisTool $dotnet.Source @('tool','install','ilspycmd','--version','11.1.0.9782','--tool-path',(Split-Path $privateTool -Parent)) -LogPath (Join-Path $LogDirectory 'install-ilspy') -WorkingDirectory $LogDirectory -TimeoutSeconds 600
            if($result.Status -eq 'Completed' -and (Test-Path -LiteralPath $privateTool)){$tools.ILSpy=$privateTool}
        }
        if(-not $tools.ILSpy){$tools.Limitations.Add('ILSpy is unavailable; managed metadata alone does not recover a C# project.')}
        else{
            $version=Invoke-AnalysisTool $tools.ILSpy @('--version') -LogPath (Join-Path $LogDirectory 'ilspy-version') -WorkingDirectory $LogDirectory -TimeoutSeconds 30
            $tools.Versions.ILSpy=[IO.File]::ReadAllText($version.StandardOutputPath).Trim()
        }
    }
    if($Wasm) {
        $wabtRoot=Join-Path $cacheRoot 'wabt-1.0.42'
        $candidate=if($env:REA_WABT_BIN_DIRECTORY){$env:REA_WABT_BIN_DIRECTORY}else{Join-Path $wabtRoot 'bin'}
        if(-not(Test-Path -LiteralPath (Join-Path $candidate 'wasm2wat.exe')) -and -not $NoInstall) {
            try{
                $null=[IO.Directory]::CreateDirectory($cacheRoot)
                $archive=Join-Path $cacheRoot 'wabt-1.0.42-windows-x64.tar.gz'
                Save-VerifiedAnalysisDownload 'https://github.com/WebAssembly/wabt/releases/download/1.0.42/wabt-1.0.42-windows-x64.tar.gz' $archive '62F1EB2B51AA57CF0F0B8BA333BF2C72A049930AA9C5DE01DCAD271C4FE48C88'
                if(Test-Path -LiteralPath $wabtRoot){throw 'An incomplete WABT destination already exists; inspect it before reinstalling.'}
                $tar=Get-Command tar -CommandType Application -ErrorAction Stop|Select-Object -First 1
                $result=Invoke-AnalysisTool $tar.Source @('-xf',$archive,'-C',$cacheRoot) -LogPath (Join-Path $LogDirectory 'install-wabt') -WorkingDirectory $LogDirectory -TimeoutSeconds 120
                if($result.Status -ne 'Completed'){throw 'WABT archive extraction failed.'}
                $candidate=Join-Path $wabtRoot 'bin'
            }catch{$tools.Limitations.Add("WABT installation failed: $($_.Exception.Message)")}
        }
        if(Test-Path -LiteralPath (Join-Path $candidate 'wasm2wat.exe')){$tools.WabtBin=$candidate}
        else{$tools.Limitations.Add('WABT is unavailable; validated WASM/WAT recovery cannot run.')}
    }
    if($Java) {
        $javaCommand=Get-Command java -CommandType Application -ErrorAction Ignore|Select-Object -First 1
        if($javaCommand){$tools.Java=$javaCommand.Source}
        $jadxRoot=Join-Path $cacheRoot 'jadx-1.5.6'
        $jar=Join-Path $cacheRoot 'jadx-headless-mcp-0.7.1-all.jar'
        if($tools.Java -and -not $NoInstall) {
            try{
                $null=[IO.Directory]::CreateDirectory($cacheRoot)
                if(-not(Test-Path -LiteralPath (Join-Path $jadxRoot 'lib'))) {
                    $archive=Join-Path $cacheRoot 'jadx-1.5.6.zip'
                    Save-VerifiedAnalysisDownload 'https://github.com/skylot/jadx/releases/download/v1.5.6/jadx-1.5.6.zip' $archive '545EA2BE9C242511BC145755CF4BDA2485ADE42966E096F8B4D3DA2A230E8974'
                    if(Test-Path -LiteralPath $jadxRoot){throw 'An incomplete JADX destination already exists; inspect it before reinstalling.'}
                    Expand-Archive -LiteralPath $archive -DestinationPath $jadxRoot -ErrorAction Stop
                }
                Save-VerifiedAnalysisDownload 'https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.7.1/jadx-headless-mcp-0.7.1-all.jar' $jar '6E5EACF500B64292BFB73C49797C1958F6EE44646E43E868039AE7FEB573FF75'
            }catch{$tools.Limitations.Add("JADX installation failed: $($_.Exception.Message)")}
        }
        if(Test-Path -LiteralPath (Join-Path $jadxRoot 'lib')){$tools.JadxDirectory=$jadxRoot;$tools.Versions.JADX='1.5.6'}
        if($env:REA_JADX_MCP_JAR -and (Test-Path -LiteralPath $env:REA_JADX_MCP_JAR)){$tools.JadxMcpJar=$env:REA_JADX_MCP_JAR}
        elseif(Test-Path -LiteralPath $jar){$tools.JadxMcpJar=$jar}
        if(-not $tools.Java -or -not $tools.JadxDirectory){$tools.Limitations.Add('Java/JADX is unavailable; Java/Android source recovery is incomplete.')}
    }
    [pscustomobject]$tools
}
