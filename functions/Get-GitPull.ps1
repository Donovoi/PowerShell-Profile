function Get-GitPull {
    <#
    .SYNOPSIS
    Previews and checkpoints Git pull/reset-and-sync operations.
    .DESCRIPTION
    With an upstream remote: stash tracked/untracked changes, reset HEAD, clean -fd,
    checkout the upstream default branch, merge -X theirs, and push to origin.
    Recovery refs retain HEAD, the target branch and stash. Ignored files remain.
    Push requires fast-forward ancestry plus an explicit remote lease.
    Without upstream: update the configured tracking branch with --ff-only.
    Preview and WhatIf never fetch, stash, reset, clean, merge or push.
    Repositories with submodules, active operations or lock files are refused.
    .EXAMPLE
    Get-GitPull -Path C:\Projects -Preview | Format-List
    .EXAMPLE
    Get-GitPull -Path C:\Projects -NoPush
    #>
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    [OutputType([pscustomobject])]
    param([Parameter(Position=0)][string]$Path=$PWD,[switch]$Preview,[switch]$NoPush,[ValidateRange(1,86400)][int]$TimeoutSeconds=300)
    $ErrorActionPreference='Stop'
    $gitTimeout=$TimeoutSeconds
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1')
    }
    Initialize-CmdletDependencies -RequiredCmdlets @('Invoke-Process') -PreferLocal -ErrorAction Stop
    $git=(Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $root=(Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
    if (-not [IO.Directory]::Exists($root)) { throw 'Path must be a repository or repository parent directory.' }
    function Invoke-SyncGit([string]$Repository,[string[]]$Arguments,[switch]$AllowFailure) {
        # Mutation calls are gated by the outer ShouldProcess; preview needs read-only Git commands.
        $result=Invoke-Process -FilePath $git -ArgumentList (@('-C',$Repository)+$Arguments) -PassThru -IgnoreExitCode -TimeoutSeconds $gitTimeout -WhatIf:$false -Confirm:$false
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) { throw "Git $($Arguments[0]) failed with exit code $($result.ExitCode) in '$Repository'. No later sync step was run." }
        if ($AllowFailure) { return $result }
        $result.StandardOutput.TrimEnd()
    }
    function Get-RemoteOid([string]$Repository,[string]$Remote,[string]$Branch) {
        $line=Invoke-SyncGit $Repository @('ls-remote','--refs',$Remote,"refs/heads/$Branch")
        if (-not $line) { return '' }
        if ($line -notmatch '^([a-f0-9]{40,64})\s+refs/heads/') { throw 'Unexpected remote branch response.' }
        $Matches[1]
    }
    function Get-DisplayRemote([string]$Value) {
        if ($Value -match '^[a-z]+://') {
            $uri=[uri]$Value
            return $uri.GetLeftPart([UriPartial]::Authority).Replace($uri.UserInfo+'@','')+$uri.AbsolutePath
        }
        $Value
    }
    function Assert-RepositoryIdle([string]$Repository) {
        $gitDirectory=Invoke-SyncGit $Repository @('rev-parse','--absolute-git-dir')
        foreach ($marker in 'index.lock','HEAD.lock','MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','rebase-merge','rebase-apply','BISECT_LOG') {
            if (Test-Path -LiteralPath (Join-Path $gitDirectory $marker)) { throw "Active operation or lock: $Repository ($marker)" }
        }
        if ((Invoke-SyncGit $Repository @('ls-files','--stage')) -match '(?m)^160000 ') { throw "Submodules require separate handling: $Repository" }
        if ((Invoke-SyncGit $Repository @('ls-files','-v')) -cmatch '(?m)^[a-zS] ') { throw "Assume-unchanged or skip-worktree entries require manual handling: $Repository" }
    }
    $queue=[Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($root)
    $repositories=[Collections.Generic.List[string]]::new()
    while ($queue.Count) {
        $directory=$queue.Dequeue()
        if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if (Test-Path -LiteralPath (Join-Path $directory '.git')) { $repositories.Add($directory); continue }
        foreach ($child in Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction Stop) {
            if ($child.Name -ne '.git' -and -not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $queue.Enqueue($child.FullName) }
        }
    }
    if (-not $repositories.Count) { throw 'No repositories found beneath Path.' }
    foreach ($repository in ($repositories|Sort-Object)) {
        Assert-RepositoryIdle $repository
        $branchResult=Invoke-SyncGit $repository @('symbolic-ref','--quiet','--short','HEAD') -AllowFailure
        if ($branchResult.ExitCode) { throw "Detached HEAD is not eligible for sync: $repository" }
        $currentBranch=$branchResult.StandardOutput.Trim()
        $beforeHead=Invoke-SyncGit $repository @('rev-parse','HEAD')
        $resetSync='upstream' -in ((Invoke-SyncGit $repository @('remote')) -split '\r?\n')
        if ($resetSync) {
            $remoteHead=Invoke-SyncGit $repository @('ls-remote','--symref','upstream','HEAD')
            if ($remoteHead -notmatch '(?m)^ref: refs/heads/([^\s]+)\s+HEAD') { throw 'Cannot resolve upstream default branch.' }
            $targetBranch=$Matches[1]; $remote='upstream'
        } else {
            $remote=Invoke-SyncGit $repository @('config',"branch.$currentBranch.remote")
            $mergeRef=Invoke-SyncGit $repository @('config',"branch.$currentBranch.merge")
            if ($remote -eq '.' -or $mergeRef -notlike 'refs/heads/*') { throw 'A remote tracking branch is required.' }
            $targetBranch=$mergeRef.Substring('refs/heads/'.Length)
        }
        $upstreamOid=Get-RemoteOid $repository $remote $targetBranch
        if (-not $upstreamOid) { throw 'Remote target branch does not exist.' }
        $fetchUrl=Invoke-SyncGit $repository @('remote','get-url',$remote)
        $pushUrl=''; $originOid=''
        if ($resetSync -and -not $NoPush) {
            $pushUrls=(Invoke-SyncGit $repository @('remote','get-url','--push','--all','origin')) -split '\r?\n'
            $originFetchUrl=Invoke-SyncGit $repository @('remote','get-url','origin')
            if ($pushUrls.Count -ne 1 -or $pushUrls[0] -ne $originFetchUrl) { throw 'Sync requires one origin URL shared by fetch and push; review split URLs manually.' }
            $pushUrl=$pushUrls[0]; $originOid=Get-RemoteOid $repository origin $targetBranch
        }
        $statusBefore=Invoke-SyncGit $repository @('status','--porcelain=v1','--untracked-files=all')
        $cleanPreview=if($resetSync){Invoke-SyncGit $repository @('clean','-nd')}else{''}
        $plan=[pscustomobject]@{
            Repository=$repository; Mode=$(if($resetSync){'ResetAndSync'}else{'FastForward'})
            CurrentBranch=$currentBranch; TargetBranch=$targetBranch; BeforeHead=$beforeHead
            Upstream=(Get-DisplayRemote $fetchUrl); UpstreamCommit=$upstreamOid
            PushTo=$(if($pushUrl){Get-DisplayRemote $pushUrl}else{''}); OriginCommit=$originOid
            LocalChanges=$statusBefore; CleanPreview=$cleanPreview; IgnoredFilesPreserved=$true
            Actions=$(if($resetSync){'Checkpoint; stash; reset HEAD; clean -fd; checkout default; merge -X theirs; guarded push'}else{'Fetch; merge --ff-only'})
            RecoveryRef=$null; Result='Preview'
        }
        if ($Preview) { $plan; continue }
        $action=if($resetSync){"Checkpoint, reset/clean, merge $remote/$targetBranch; push=$(-not $NoPush) to '$($plan.PushTo)'"}else{"Fast-forward from $remote/$targetBranch"}
        if (-not $PSCmdlet.ShouldProcess("$repository [$currentBranch -> $targetBranch; upstream $upstreamOid]",$action)) { $plan; continue }
        Assert-RepositoryIdle $repository
        if ((Invoke-SyncGit $repository @('rev-parse','HEAD')) -ne $beforeHead -or
            (Invoke-SyncGit $repository @('status','--porcelain=v1','--untracked-files=all')) -ne $statusBefore) { throw 'Repository changed after preview; run again.' }
        $null=Invoke-SyncGit $repository @('fetch','--no-tags',$remote,"+refs/heads/${targetBranch}:refs/remotes/$remote/$targetBranch")
        if ((Invoke-SyncGit $repository @('rev-parse',"refs/remotes/$remote/$targetBranch")) -ne $upstreamOid) { throw 'Upstream advanced after preview; run again before resetting.' }
        if ($originOid) {
            $null=Invoke-SyncGit $repository @('fetch','--no-tags','origin',"+refs/heads/${targetBranch}:refs/remotes/origin/$targetBranch")
            if ((Invoke-SyncGit $repository @('rev-parse',"refs/remotes/origin/$targetBranch")) -ne $originOid) { throw 'Origin advanced after preview; run again.' }
        }
        $recovery='refs/profile-sync/'+[guid]::NewGuid().ToString('N')
        $plan.RecoveryRef=$recovery
        $null=Invoke-SyncGit $repository @('update-ref',"$recovery/head",$beforeHead)
        try {
            if ($resetSync) {
                $targetResult=Invoke-SyncGit $repository @('rev-parse','--verify',"refs/heads/$targetBranch") -AllowFailure
                if ($targetResult.ExitCode -eq 0) { $null=Invoke-SyncGit $repository @('update-ref',"$recovery/target",$targetResult.StandardOutput.Trim()) }
                if ($statusBefore) {
                    $null=Invoke-SyncGit $repository @('stash','push','--include-untracked','--message',"Profile sync $recovery")
                    $stash=Invoke-SyncGit $repository @('rev-parse','refs/stash')
                    $null=Invoke-SyncGit $repository @('update-ref',"$recovery/worktree",$stash)
                    if (Invoke-SyncGit $repository @('status','--porcelain=v1','--untracked-files=all')) { throw 'Checkpoint left changes behind; reset was not attempted.' }
                }
                $null=Invoke-SyncGit $repository @('reset','--hard','HEAD')
                $null=Invoke-SyncGit $repository @('clean','-fd')
                if ($targetResult.ExitCode -eq 0) { $null=Invoke-SyncGit $repository @('checkout','--no-overwrite-ignore',$targetBranch) }
                else { $null=Invoke-SyncGit $repository @('checkout','--no-overwrite-ignore','-b',$targetBranch,"refs/remotes/upstream/$targetBranch") }
                $null=Invoke-SyncGit $repository @('merge','--no-overwrite-ignore','--no-edit','-X','theirs',$upstreamOid)
                if (-not $NoPush) {
                    if ((Get-RemoteOid $repository origin $targetBranch) -ne $originOid) { throw 'Origin changed; push was not attempted.' }
                    if ($originOid) {
                        $ancestry=Invoke-SyncGit $repository @('merge-base','--is-ancestor',$originOid,'HEAD') -AllowFailure
                        if ($ancestry.ExitCode -ne 0) { throw 'Push would rewrite origin history; reconcile manually.' }
                    }
                    $null=Invoke-SyncGit $repository @('push',"--force-with-lease=refs/heads/${targetBranch}:$originOid",'origin',"HEAD:refs/heads/$targetBranch")
                }
            } else { $null=Invoke-SyncGit $repository @('merge','--no-overwrite-ignore','--ff-only',$upstreamOid) }
            $plan.Result='Complete'; $plan
        }
        catch { throw "Sync stopped for '$repository'. Recovery refs: $recovery/head, optional /target and /worktree. $($_.Exception.Message)" }
    }
}
