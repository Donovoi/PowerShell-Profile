function Assert-AnalysisFirmwareRegularPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $cursor=[IO.Path]::GetFullPath($Path)
    $paths=[Collections.Generic.Stack[string]]::new()
    while($cursor){$paths.Push($cursor);$parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent}
    while($paths.Count){
        $candidate=$paths.Pop()
        if(Test-Path -LiteralPath $candidate){
            if((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse-point cache or tool path refused: $candidate"}
        }
    }
}

function Get-AnalysisFirmwarePackageSpec {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    @(
        [pscustomobject]@{Name='BIOSUtilities';File='BIOSUtilities-f799425.zip';Root='biosutilities';StripRoot='BIOSUtilities-f799425af93264b62a2f3c3cc5bbabf8a2226114';Version='f799425af93264b62a2f3c3cc5bbabf8a2226114';Uri='https://codeload.github.com/platomav/BIOSUtilities/zip/f799425af93264b62a2f3c3cc5bbabf8a2226114';SHA256='491AA8B91830D0EAC7A8AAB8DC6149CF7C10B2017C9EFF6C44269AFD68092DC1'}
        [pscustomobject]@{Name='UEFIExtract';File='UEFIExtract_NE_A75_win64.zip';Root='uefi';StripRoot='';Version='A75';Uri='https://github.com/LongSoft/UEFITool/releases/download/A75/UEFIExtract_NE_A75_win64.zip';SHA256='20FF18208913D32C99E3B002717ABEDDAA3B6509AC62E6699E462B0F533BE646'}
        [pscustomobject]@{Name='IFRExtractor';File='ifrextractor_1.6.1_windows.zip';Root='ifr';StripRoot='';Version='1.6.1';Uri='https://github.com/LongSoft/IFRExtractor-RS/releases/download/v1.6.1/ifrextractor_1.6.1_windows.zip';SHA256='3A0D93ECD3A4CB092D210C499D125FFD782982311F5F8DC40A8B180B58C4FFE7'}
        [pscustomobject]@{Name='DissectUtil';File='dissect_util-3.20-py3-none-any.whl';Root='python-dependencies';StripRoot='';Version='3.20';Uri='https://files.pythonhosted.org/packages/7d/e3/e085af89d225b5893f75fcc4d74d9ddbe07a2a93714e2fb2e3a8756d4e72/dissect_util-3.20-py3-none-any.whl';SHA256='EE43E092953802F9C8E6367822C50046794B90159C56128AFFB0ADBE798D4397'}
        [pscustomobject]@{Name='Pefile';File='pefile-2023.2.7-py3-none-any.whl';Root='python-dependencies';StripRoot='';Version='2023.2.7';Uri='https://files.pythonhosted.org/packages/55/26/d0ad8b448476d0a1e8d3ea5622dc77b916db84c6aa3cb1e1c0965af948fc/pefile-2023.2.7-py3-none-any.whl';SHA256='DA185CD2AF68C08A6CD4481F7325ED600A88F6A813BAD9DEA07AB3EF73D8D8D6'}
    )
}

function Get-AnalysisFirmwareArchivePlan {
    <# Internal bounded ZIP inspection; does not extract or execute entries. #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$ArchivePath,[Parameter(Mandatory)][string]$Root,[string]$StripRoot)
    if($Root -notmatch '^[A-Za-z0-9-]+$'){throw 'Unsafe archive destination root.'}
    Assert-AnalysisFirmwareRegularPath $ArchivePath
    if((Get-Item -LiteralPath $ArchivePath).Length -gt 64MB){throw 'Firmware dependency archive exceeds 64 MiB.'}
    $zip=[IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $total=0L
    try{
        if($zip.Entries.Count -gt 10000){throw 'Firmware dependency archive exceeds 10,000 entries.'}
        foreach($entry in $zip.Entries){
            $name=$entry.FullName.Replace('\','/')
            $isDirectory=$name.EndsWith('/')
            $parts=$name.TrimEnd('/').Split('/')
            if([IO.Path]::IsPathRooted($name) -or $name.StartsWith('/') -or $name.Contains(':') -or $name.Contains([char]0)){throw "Unsafe archive path: $name"}
            foreach($part in $parts){
                if(-not $part -or $part -in '.','..' -or $part -match '[\x00-\x1F<>"|?*]' -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw "Unsafe archive path: $name"}
            }
            $mode=($entry.ExternalAttributes -shr 16) -band 0xF000
            if($mode -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400)){throw "Archive link/reparse entry refused: $name"}
            if($StripRoot){
                if($parts[0] -cne $StripRoot){throw "Unexpected archive root: $name"}
                $name=($parts|Select-Object -Skip 1) -join '/'
            }else{$name=$name.TrimEnd('/')}
            if($isDirectory -or -not $name){continue}
            $relative=$Root+'/'+$name
            if(-not $seen.Add($relative)){throw "Duplicate archive path: $relative"}
            if($entry.Length -gt 64MB -or $entry.Length -lt 0){throw 'Firmware archive entry exceeds its 64 MiB bound.'}
            $total+=$entry.Length
            if($total -gt 256MB){throw 'Firmware dependency archive exceeds 256 MiB expanded.'}
            $inputStream=$entry.Open()
            $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            try{
                $buffer=[byte[]]::new(65536);$readTotal=0L
                while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){
                    $readTotal+=$read
                    if($readTotal -gt $entry.Length){throw 'Archive entry expanded beyond its declared length.'}
                    $hash.AppendData($buffer,0,$read)
                }
                if($readTotal -ne $entry.Length){throw 'Archive entry is truncated.'}
                $digest=[Convert]::ToHexString($hash.GetHashAndReset())
            }finally{$hash.Dispose();$inputStream.Dispose()}
            [pscustomobject]@{ArchivePath=$ArchivePath;EntryName=$entry.FullName;RelativePath=$relative;Length=$entry.Length;SHA256=$digest}
        }
    }finally{$zip.Dispose()}
}

function Save-AnalysisFirmwareDownload {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Internal pinned download called only after the parent analysis ShouldProcess decision.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][uri]$Uri,[Parameter(Mandatory)][string]$Destination)
    if($Uri.Scheme -ne 'https'){throw 'Firmware dependencies require HTTPS.'}
    Assert-AnalysisFirmwareRegularPath $Destination
    $handler=[Net.Http.HttpClientHandler]::new();$handler.MaxAutomaticRedirections=5
    $client=[Net.Http.HttpClient]::new($handler)
    $cancellation=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(180))
    $response=$null;$inputStream=$null;$output=$null
    try{
        $response=$client.GetAsync($Uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancellation.Token).GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        if($response.Content.Headers.ContentLength -gt 64MB){throw 'Firmware download exceeds 64 MiB.'}
        $inputStream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output=[IO.File]::Open($Destination,'CreateNew','Write','None')
        $buffer=[byte[]]::new(65536);$total=0L
        while(($count=$inputStream.ReadAsync($buffer,0,$buffer.Length,$cancellation.Token).GetAwaiter().GetResult()) -gt 0){
            $total+=$count
            if($total -gt 64MB){throw 'Firmware download exceeds 64 MiB; partial download preserved.'}
            $output.Write($buffer,0,$count)
        }
    }finally{if($output){$output.Dispose()};if($inputStream){$inputStream.Dispose()};if($response){$response.Dispose()};$cancellation.Dispose();$client.Dispose()}
}

function Resolve-AnalysisFirmwareTool {
    <#
    .SYNOPSIS
    Resolves pinned firmware parsers into a private, verified cache.
    .DESCRIPTION
    Called after the analysis command's ShouldProcess decision. Never installs
    Python, runs a target, invokes pip or changes PATH/user configuration. Uses
    an existing native Python 3.10+ and pinned source/native/wheel archives.
    NoInstall permits reuse only. Corrupt and incomplete caches are preserved.
    Workers must use Python -B -I -S and explicitly insert PythonDependencies
    and BIOSUtilities into sys.path; bytecode additions invalidate the cache.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$LogDirectory,[switch]$NoInstall,[string]$CacheRoot)
    $ErrorActionPreference='Stop'
    $tools=[ordered]@{Python=$null;BIOSUtilities=$null;UEFIExtract=$null;IFRExtractor=$null;PythonDependencies=$null;Versions=[ordered]@{};Limitations=[Collections.Generic.List[string]]::new();Status='Unavailable';CacheRoot=$null;ManifestPath=$null;Limits=[pscustomobject]@{DownloadBytes=64MB;ArchiveExpandedBytes=256MB;ArchiveEntries=10000;VersionTimeoutSeconds=20;LockWaitSeconds=0}}
    if(-not $IsWindows){$tools.Limitations.Add('The pinned native firmware tools require Windows.');$tools.Limitations=$tools.Limitations.ToArray();return [pscustomobject]$tools}
    $log=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogDirectory)
    Assert-AnalysisFirmwareRegularPath $log
    if(-not (Test-Path -LiteralPath $log -PathType Container)){throw 'Firmware tool LogDirectory must already exist.'}
    if(-not $CacheRoot){$CacheRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PowerShellProfile/AnalysisTools/firmware-v1'}
    $cache=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CacheRoot)
    $tools.CacheRoot=$cache
    $probeIndex=0
    foreach($command in @(Get-Command python.exe,python3.exe -CommandType Application -All -ErrorAction SilentlyContinue|Select-Object -First 8)){
        $python=$command.Source
        if([IO.Path]::GetExtension($python) -ine '.exe' -or $python -match '(?i)[\\/]WindowsApps[\\/]'){continue}
        try{
            Assert-AnalysisFirmwareRegularPath $python
            $check=[IO.File]::OpenRead($python)
            try{if($check.ReadByte() -ne 77 -or $check.ReadByte() -ne 90){continue}}finally{$check.Dispose()}
            $probeIndex++
            $probe=Invoke-AnalysisTool -FilePath $python -ArgumentList @('-B','-I','-S','-c','import sys;print("%d.%d.%d" % sys.version_info[:3])') -LogPath (Join-Path $log ('firmware-python-'+$probeIndex+'-'+[guid]::NewGuid().ToString('N'))) -WorkingDirectory $log -TimeoutSeconds 20 -MaxLogBytes 1MB
            $version=[IO.File]::ReadAllText($probe.StandardOutputPath).Trim()
            if($probe.Status -eq 'Completed' -and $version -match '^3\.(\d+)\.\d+$' -and [int]$Matches[1] -ge 10){
                $tools.Python=$python;$tools.Versions.Python=$version;$tools.Versions.PythonSHA256=(Get-FileHash -LiteralPath $python -Algorithm SHA256).Hash;break
            }
        }catch{$tools.Limitations.Add('Python candidate rejected: '+$_.Exception.Message)}
    }
    if(-not $tools.Python){$tools.Limitations.Add('Native Python 3.10+ is unavailable. Python was not installed; Windows Store aliases and shell shims were not executed.')}
    $lock=$null
    try{
        Assert-AnalysisFirmwareRegularPath $cache
        if(-not (Test-Path -LiteralPath $cache)){
            if($NoInstall){throw 'Pinned firmware tools are not cached and NoInstall prevents downloading or extracting them.'}
            $null=[IO.Directory]::CreateDirectory($cache)
        }
        $lockPath=Join-Path $cache 'cache.lock'
        Assert-AnalysisFirmwareRegularPath $lockPath
        try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch{throw 'Firmware cache lock is unavailable; another resolver may be using this cache. Retry after it finishes.'}
        $manifestPath=Join-Path $cache 'manifest.json'
        $pendingPath=Join-Path $cache 'installation.pending.json'
        $payload=Join-Path $cache 'payload'
        $archives=Join-Path $cache 'archives'
        foreach($path in @($manifestPath,$pendingPath,$payload,$archives)){Assert-AnalysisFirmwareRegularPath $path}
        $ready=Test-Path -LiteralPath $manifestPath -PathType Leaf
        if(-not $ready -and ((Test-Path -LiteralPath $pendingPath) -or (Test-Path -LiteralPath $payload))){throw 'Incomplete firmware cache preserved. Inspect its pending record/payload and choose a new CacheRoot or repair it explicitly.'}
        if(-not $ready -and $NoInstall){throw 'Firmware cache has no ready manifest; NoInstall prevents installation.'}
        $specs=@(Get-AnalysisFirmwarePackageSpec)
        if(-not $ready){
            $pending=[IO.File]::Open($pendingPath,'CreateNew','Write','None')
            try{$bytes=[Text.Encoding]::UTF8.GetBytes(([pscustomobject]@{StartedUtc=[DateTime]::UtcNow.ToString('o');Packages=$specs}|ConvertTo-Json -Depth 4));$pending.Write($bytes,0,$bytes.Length)}finally{$pending.Dispose()}
            $null=[IO.Directory]::CreateDirectory($archives)
        }
        $plan=[Collections.Generic.List[object]]::new()
        $allPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($spec in $specs){
            $archive=Join-Path $archives $spec.File
            Assert-AnalysisFirmwareRegularPath $archive
            if(-not (Test-Path -LiteralPath $archive -PathType Leaf)){
                if($ready -or $NoInstall){throw "Missing pinned archive $($spec.File); cache preserved for inspection."}
                $download=$archive+'.download-'+[guid]::NewGuid().ToString('N')
                Save-AnalysisFirmwareDownload -Uri $spec.Uri -Destination $download
                if((Get-Item -LiteralPath $download).Length -gt 64MB -or (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $spec.SHA256){throw "Downloaded firmware dependency checksum/size mismatch; preserved at $download"}
                [IO.File]::Move($download,$archive)
            }
            if((Get-Item -LiteralPath $archive).Length -gt 64MB -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $spec.SHA256){throw "Pinned archive checksum/size mismatch: $archive. Cache preserved; choose a new CacheRoot or repair it explicitly."}
            foreach($entry in @(Get-AnalysisFirmwareArchivePlan -ArchivePath $archive -Root $spec.Root -StripRoot $spec.StripRoot)){
                if(-not $allPaths.Add($entry.RelativePath)){throw "Overlapping dependency archive paths: $($entry.RelativePath)"}
                $plan.Add($entry)
            }
            $tools.Versions[$spec.Name]=$spec.Version
        }
        if(-not $ready){
            $null=[IO.Directory]::CreateDirectory($payload)
            foreach($spec in $specs){
                $archive=Join-Path $archives $spec.File
                $zip=[IO.Compression.ZipFile]::OpenRead($archive)
                try{
                    foreach($entry in @($plan|Where-Object ArchivePath -EQ $archive)){
                        $destination=[IO.Path]::GetFullPath((Join-Path $payload $entry.RelativePath))
                        if(-not $destination.StartsWith($payload.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Archive destination escapes the payload directory.'}
                        Assert-AnalysisFirmwareRegularPath $destination
                        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                        $source=$zip.GetEntry($entry.EntryName).Open();$output=$null
                        try{$output=[IO.File]::Open($destination,'CreateNew','Write','None');$source.CopyTo($output)}finally{if($output){$output.Dispose()};$source.Dispose()}
                    }
                }finally{$zip.Dispose()}
            }
        }
        # Recreate expected hashes from pinned archive bytes on every reuse;
        # editing both a payload file and its manifest cannot bless the change.
        $actual=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $directories=[Collections.Generic.Stack[string]]::new();$directories.Push($payload)
        while($directories.Count){
            $directory=$directories.Pop();Assert-AnalysisFirmwareRegularPath $directory
            foreach($item in @(Get-ChildItem -LiteralPath $directory -Force)){
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse-point payload refused: $($item.FullName)"}
                if($item.PSIsContainer){$directories.Push($item.FullName);continue}
                $relative=[IO.Path]::GetRelativePath($payload,$item.FullName).Replace('\','/')
                if(-not $allPaths.Contains($relative)){throw "Unexpected payload file: $relative. Cache preserved."}
                $null=$actual.Add($relative)
            }
        }
        if($actual.Count -ne $plan.Count){throw 'Firmware payload file inventory is incomplete. Cache preserved.'}
        foreach($entry in $plan){
            $file=Join-Path $payload $entry.RelativePath
            if((Get-Item -LiteralPath $file).Length -ne $entry.Length -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.SHA256){throw "Firmware payload hash mismatch: $($entry.RelativePath). Cache preserved."}
        }
        $layout=@{
            BIOSUtilities=Join-Path $payload 'biosutilities'
            UEFIExtract=Join-Path $payload 'uefi/UEFIExtract.exe'
            IFRExtractor=Join-Path $payload 'ifr/ifrextractor.exe'
            PythonDependencies=Join-Path $payload 'python-dependencies'
        }
        foreach($required in @((Join-Path $layout.BIOSUtilities 'biosutilities/dell_pfs_extract.py'),$layout.UEFIExtract,$layout.IFRExtractor,(Join-Path $layout.PythonDependencies 'pefile.py'),(Join-Path $layout.PythonDependencies 'dissect/util/__init__.py'))){if(-not (Test-Path -LiteralPath $required -PathType Leaf)){throw "Pinned archive layout lacks required file: $required"}}
        $files=@($plan|Select-Object RelativePath,Length,SHA256|Sort-Object RelativePath)
        if($ready){
            if((Get-Item -LiteralPath $manifestPath).Length -gt 4MB){throw 'Firmware manifest exceeds its size limit.'}
            $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
            if($manifest.SchemaVersion -ne 1 -or $manifest.Status -ne 'Ready' -or @($manifest.Files).Count -ne $files.Count){throw 'Firmware manifest is invalid; cache preserved.'}
            if(($manifest.Files|ConvertTo-Json -Depth 4 -Compress) -cne ($files|ConvertTo-Json -Depth 4 -Compress)){throw 'Firmware manifest differs from pinned archive content; cache preserved.'}
            if(($manifest.Packages|ConvertTo-Json -Depth 4 -Compress) -cne ($specs|ConvertTo-Json -Depth 4 -Compress)){throw 'Firmware manifest package pins differ; cache preserved.'}
        }else{
            $manifest=[pscustomobject][ordered]@{SchemaVersion=1;Status='Ready';CreatedUtc=[DateTime]::UtcNow.ToString('o');Packages=$specs;Files=$files}
            $temp=$manifestPath+'.new-'+[guid]::NewGuid().ToString('N')
            $output=[IO.File]::Open($temp,'CreateNew','Write','None')
            try{$bytes=[Text.Encoding]::UTF8.GetBytes(($manifest|ConvertTo-Json -Depth 6));$output.Write($bytes,0,$bytes.Length)}finally{$output.Dispose()}
            [IO.File]::Move($temp,$manifestPath)
        }
        foreach($name in $layout.Keys){$tools[$name]=$layout[$name]}
        $tools.ManifestPath=$manifestPath
        if($tools.Python){$tools.Status='Completed'}
    }catch{
        $tools.BIOSUtilities=$null;$tools.UEFIExtract=$null;$tools.IFRExtractor=$null;$tools.PythonDependencies=$null
        $tools.Limitations.Add('Firmware tool resolution failed: '+$_.Exception.Message)
    }finally{if($lock){$lock.Dispose()}}
    if($tools.Status -ne 'Completed'){foreach($name in @('Python','BIOSUtilities','UEFIExtract','IFRExtractor','PythonDependencies')){$tools[$name]=$null}}
    $tools.Limitations=$tools.Limitations.ToArray()
    [pscustomobject]$tools
}
