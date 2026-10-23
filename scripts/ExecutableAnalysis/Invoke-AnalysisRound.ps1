function Resolve-AnalysisCodex {
    [CmdletBinding()]
    param([string]$LogDirectory)
    $candidates=[Collections.Generic.List[string]]::new()
    $diagnostics=[Collections.Generic.List[object]]::new()
    $appRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenAI/Codex/bin'
    if(Test-Path -LiteralPath $appRoot) {
        foreach($directory in Get-ChildItem -LiteralPath $appRoot -Directory|Sort-Object LastWriteTimeUtc -Descending) {
            $file=Join-Path $directory.FullName 'codex.exe'
            if((Test-Path -LiteralPath $file) -and (Test-Path -LiteralPath (Join-Path $directory.FullName 'codex-code-mode-host.exe'))){$candidates.Add($file)}
        }
    }
    foreach($command in Get-Command codex -CommandType Application -All -ErrorAction Ignore) {
        if([IO.Path]::GetExtension($command.Source) -in '.cmd','.bat','.ps1') {
            # ArgumentList cannot preserve shell metacharacters through a batch shim.
            # Official npm launcher layout: codex-cli/bin/codex.js, findCodexExecutable.
            # https://github.com/openai/codex/blob/main/codex-cli/bin/codex.js
            $diagnostics.Add([pscustomobject]@{Candidate=$command.Source;Status='Skipped';Reason='Shell launcher refused; looking for the npm package native executable.'})
            $npmModules=Join-Path (Split-Path $command.Source -Parent) 'node_modules'
            $packageRoot=Join-Path $npmModules '@openai/codex'
            try {
                $metadata=Get-Content -LiteralPath (Join-Path $packageRoot 'package.json') -Raw -ErrorAction Stop|ConvertFrom-Json
                if($metadata.name -ne '@openai/codex'){continue}
                $platforms=if([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64'){@('arm64','x64')}else{@('x64')}
                foreach($platform in $platforms) {
                    $triple=if($platform -eq 'arm64'){'aarch64-pc-windows-msvc'}else{'x86_64-pc-windows-msvc'}
                    foreach($moduleRoot in @((Join-Path $packageRoot 'node_modules'),$npmModules)) {
                        $platformRoot=Join-Path $moduleRoot "@openai/codex-win32-$platform"
                        $platformMetadata=Join-Path $platformRoot 'package.json'
                        if((Test-Path -LiteralPath $platformMetadata -PathType Leaf) -and
                            (Get-Content -LiteralPath $platformMetadata -Raw|ConvertFrom-Json).name -eq "@openai/codex-win32-$platform") {
                            $candidates.Add((Join-Path $platformRoot "vendor/$triple/bin/codex.exe"))
                        }
                    }
                    $candidates.Add((Join-Path $packageRoot "vendor/$triple/bin/codex.exe"))
                }
            } catch {$diagnostics.Add([pscustomobject]@{Candidate=$command.Source;Status='Unavailable';Reason=$_.Exception.Message})}
        } else {$candidates.Add($command.Source)}
    }
    $diagnosticPath=Join-Path $LogDirectory 'codex-resolver.json'
    $index=0
    try {
        foreach($candidate in $candidates|Select-Object -Unique) {
            $index++
            try {
                if(-not(Test-Path -LiteralPath $candidate -PathType Leaf)) {
                    $diagnostics.Add([pscustomobject]@{Candidate=$candidate;Status='Unavailable';Reason='Native executable is missing.'})
                    continue
                }
                $result=Invoke-AnalysisTool $candidate @('--version') -LogPath (Join-Path $LogDirectory "codex-version-$index") -WorkingDirectory $LogDirectory -TimeoutSeconds 15
                $versionText=[IO.File]::ReadAllText($result.StandardOutputPath).Trim()
                $compatible=$result.Status -eq 'Completed' -and $versionText -match 'codex-cli (\d+\.\d+\.\d+)' -and [version]$Matches[1] -ge [version]'0.163.0'
                $diagnostics.Add([pscustomobject]@{Candidate=$candidate;Status=if($compatible){'Compatible'}else{'Incompatible'};Version=$versionText;Process=$result})
                if($compatible){return [pscustomobject]@{Source=$candidate;Version=$versionText;DiagnosticsPath=$diagnosticPath}}
            } catch {$diagnostics.Add([pscustomobject]@{Candidate=$candidate;Status='Failed';Reason=$_.Exception.Message})}
        }
    } finally {
        $stream=[IO.File]::Open($diagnosticPath,'CreateNew','Write','Read')
        try{$bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $diagnostics.ToArray() -Depth 6));$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    }
    Write-Verbose 'Codex CLI 0.163.0 or newer is required. Update the CLI or desktop app, then sign in.'
    return $null
}

function Select-AnalysisEvidenceFile {
    [CmdletBinding()]
    [OutputType([IO.FileInfo])]
    param([Parameter(Mandatory)][string]$RunDirectory)
    # Reserve identity, runtime observations and invocation provenance before code.
    # A large function export must not crowd actual guest behavior out of the review.
    $roots=@('basic','runtime','logs','code','rea','application')|ForEach-Object{Join-Path $RunDirectory $_}|Where-Object{Test-Path -LiteralPath $_ -PathType Container}
    Get-ChildItem -LiteralPath $roots -Recurse -File | Where-Object {
        $_.Extension -in '.c','.cs','.js','.mjs','.cjs','.jsx','.ts','.tsx','.wat','.java','.json','.log','.txt','.stdout','.stderr','.trace' -and
        $_.Name -notmatch 'tools-list|catalog' -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        ($_.DirectoryName -ne (Join-Path $RunDirectory 'logs') -or $_.Name -like '*.command.json')
    } | Sort-Object @{Expression={
        $relative=[IO.Path]::GetRelativePath($RunDirectory,$_.FullName)
        if($relative -match '^basic[\\/]'){0}
        elseif($relative -match '^runtime[\\/]'){1}
        elseif($_.Name -in 'rea-result.json','ghidra-result.json','manifest.json' -or $_.Name -like '*.command.json'){2}
        elseif($relative -match '^(?:rea|application[\\/]rea-\d+)[\\/]rea-extracted[\\/]package\.json$'){3}
        elseif($_.Name -match '-(binary_overview|list_strings|inspect_artifact|analyze_javascript_application)\.json$'){4}
        elseif($_.Name -match '^(main|preload)([.-].*)?\.[cm]?js$' -and $relative -notmatch '[\\/]node_modules[\\/]'){5}
        elseif($_.Name -eq 'package.json'){6}
        elseif($_.Extension -in '.c','.cs','.js','.mjs','.cjs','.jsx','.ts','.tsx','.wat','.java'){7}
        else{8}
    }},FullName | Select-Object -First 40
}

function Invoke-AnalysisRound {
    [CmdletBinding()]
    param([string]$Name,[string]$Prompt,[string]$OutputDirectory,[string]$CodexPath,[int]$TimeoutSeconds=600,[switch]$Research)
    $output=Join-Path $OutputDirectory ($Name+'.md')
    $promptPath=Join-Path $OutputDirectory ($Name+'.prompt.txt')
    [IO.File]::WriteAllText($promptPath,$Prompt)
    # Give the model evidence as data through stdin. It has no shell, MCP, application,
    # browser-control, patching or subagent tools with which to execute target content.
    $arguments=@('exec','--ignore-user-config','--ephemeral','--skip-git-repo-check','--sandbox','read-only','--color','never','--json','-C',$OutputDirectory,'-o',$output,
        '-c','approval_policy="never"','-c','project_doc_max_bytes=0','-c','project_root_markers=[]','-c','mcp_servers={}',
        '-c',('web_search="'+$(if($Research){'live'}else{'disabled'})+'"'))
    foreach($feature in @('shell_tool','unified_exec','apps','plugins','hooks','multi_agent','memories','browser_use','browser_use_external','computer_use','apply_patch_freeform','in_app_browser')) {$arguments+=@('--disable',$feature)}
    $arguments+='-'
    $result=Invoke-AnalysisTool $CodexPath $arguments -LogPath (Join-Path $OutputDirectory $Name) -WorkingDirectory $OutputDirectory -TimeoutSeconds $TimeoutSeconds -InputText $Prompt
    $valid=$result.Status -eq 'Completed' -and (Test-Path -LiteralPath $output) -and (Get-Item -LiteralPath $output).Length -gt 20
    $eventErrors=[Collections.Generic.List[string]]::new()
    $webSearches=0
    if(Test-Path -LiteralPath $result.StandardOutputPath) {
        foreach($line in [IO.File]::ReadLines($result.StandardOutputPath)) {
            try{$cliEvent=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
            if($cliEvent.type -in 'error','turn.failed' -or $cliEvent.item.type -eq 'error'){$eventErrors.Add($line.Substring(0,[Math]::Min(1000,$line.Length)))}
            if($cliEvent.type -eq 'item.completed' -and $cliEvent.item.type -eq 'web_search' -and $cliEvent.item.results){$webSearches++}
        }
    }
    if($Research -and -not $webSearches){$eventErrors.Add('No completed web search with returned results was recorded; current-documentation research is unverified.')}
    [pscustomobject]@{Name=$Name;Status=if(-not $valid){'Failed'}elseif($eventErrors.Count){'Partial'}else{'Completed'};Result=$result;OutputPath=if($valid){$output}else{$null};PromptPath=$promptPath;WebSearches=$webSearches;ToolErrors=$eventErrors.ToArray()}
}
