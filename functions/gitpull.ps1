Function Git-Pull {
    [cmdletbinding()]
    Param(

    )
    $ErrorActionPreference = 'Continue'
    $global:OriginalCommand = $MyInvocation.MyCommand
    # Import-Module $PSScriptRoot\Start-AsAdmin.ps1 -Force
    Start-AsAdmin -WindowsPowerShell -Verbose
    # Find all git repositories in any directory on this drive, then perform git pull on each one.
    $DriveLetter = Get-PSDrive | Where-Object { $_.Description -eq 'X-Ways Portable' } | Select-Object -Property root
    [System.IO.Directory]::EnumerateDirectories($DriveLetter.root, '.git', 'AllDirectories') | ForEach-Object -Verbose -Process { 
        $ErrorActionPreference = 'SilentlyContinue'
        $pathparent = $_ -split '.git'
        Write-Output "Pulling from $pathparent"
        Set-Location -Path $($pathparent)[0]
        # verbose git fetch
        git fetch --all --verbose
        $NAMEOFHEAD = $(git symbolic-ref refs/remotes/origin/HEAD) 
        git reset --hard origin/$($NAMEOFHEAD.split('/')[-1]) 
        Write-Output "Git pull complete for $($pathparent)[0]"
        [GC]::Collect()
        #git pull --verbose; 
        #git config --global --add safe.directory $(Resolve-Path .)
        #git config --global --add safe.directory '*'
        #gh repo sync --force
    } 
}