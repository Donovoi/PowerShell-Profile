<#
.SYNOPSIS
    Force-installs this PowerShell profile from a Git repository.

.DESCRIPTION
    Clones the profile repository into a temporary staging folder, validates the staged
    profile, force-stops other PowerShell sessions, force-deletes the existing profile
    directory, and copies the new profile into place.

    The command returns a structured object with the installation result and a reload
    instruction. It does not use Write-Host and it does not prompt for confirmation.
#>
function Install-Profile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [uri]$ProfileUrl = 'https://github.com/Donovoi/PowerShell-Profile.git',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ProfilePath = (Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)) -ChildPath 'PowerShell')
    )

    function Assert-CommandAvailable {
        param([string]$Name, [string]$InstallMessage)

        if (Get-Command -Name $Name -ErrorAction SilentlyContinue) { return }

        if ($Name -eq 'git' -and (Get-Command -Name winget -ErrorAction SilentlyContinue)) {
            Write-Information -MessageData 'Git was not found. Installing Git with winget.'
            winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements
            $env:Path += ';C:\Program Files\Git\cmd;C:\Program Files\Git\bin'
            if (Get-Command -Name git -ErrorAction SilentlyContinue) { return }
        }

        throw $InstallMessage
    }

    function Assert-StagedProfileValid {
        param([string]$Path)

        $profileFile = Join-Path -Path $Path -ChildPath 'Microsoft.PowerShell_profile.ps1'
        $functionsPath = Join-Path -Path $Path -ChildPath 'functions'

        if (-not (Test-Path -LiteralPath $profileFile -PathType Leaf)) {
            throw "The staged repository does not contain Microsoft.PowerShell_profile.ps1 at '$profileFile'."
        }

        if (-not (Test-Path -LiteralPath $functionsPath -PathType Container)) {
            throw "The staged repository does not contain a functions directory at '$functionsPath'."
        }
    }

    function Assert-SafeProfilePath {
        param([string]$Path)

        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $rootPath = [IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
        $homePath = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)).TrimEnd('\')
        $documentsPath = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)).TrimEnd('\')

        if ($fullPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete root path '$fullPath'."
        }

        if ($fullPath.Equals($homePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete user profile root '$fullPath'."
        }

        if (-not $fullPath.StartsWith($documentsPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to delete profile path outside Documents: '$fullPath'."
        }
    }

    function Stop-OtherPowerShellSessions {
        param([int]$CurrentProcessId)

        $stoppedCount = 0
        $processes = Get-Process -Name pwsh, powershell -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $CurrentProcessId }

        foreach ($process in $processes) {
            try {
                Stop-Process -Id $process.Id -Force -Confirm:$false -ErrorAction Stop
                $stoppedCount++
            }
            catch {
                Write-Warning "Failed to stop PowerShell process $($process.Id): $($_.Exception.Message)"
            }
        }

        return $stoppedCount
    }

    function Grant-CurrentUserFullControl {
        param([string]$Path)

        if (-not (Test-Path -LiteralPath $Path)) { return }

        $takeownArgs = @('/f', $Path)
        $icaclsArgs = @($Path, '/grant', "${env:USERNAME}:(F)")

        if (Test-Path -LiteralPath $Path -PathType Container) {
            $takeownArgs += @('/r', '/d', 'Y')
            $icaclsArgs += @('/t', '/c')
        }

        & takeown.exe @takeownArgs 2>&1 | ForEach-Object { Write-Verbose -Message $_ }
        & icacls.exe @icaclsArgs 2>&1 | ForEach-Object { Write-Verbose -Message $_ }
    }

    function Remove-ProfileDirectoryForce {
        param([string]$Path)

        if (-not (Test-Path -LiteralPath $Path)) { return $false }

        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                Remove-Item -LiteralPath $Path -Recurse -Force -Confirm:$false -ErrorAction Stop
                return $true
            }
            catch {
                if ($attempt -eq 1) {
                    Grant-CurrentUserFullControl -Path $Path
                    Start-Sleep -Milliseconds 300
                    continue
                }

                throw "Failed to force-delete existing profile directory '$Path': $($_.Exception.Message)"
            }
        }
    }

    function Copy-DirectoryContents {
        param([string]$SourcePath, [string]$DestinationPath, [string[]]$ExcludeName = @())

        New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null

        $copiedCount = 0
        $items = Get-ChildItem -LiteralPath $SourcePath -Force -ErrorAction Stop |
            Where-Object { $_.Name -notin $ExcludeName }

        foreach ($item in $items) {
            Copy-Item -LiteralPath $item.FullName -Destination $DestinationPath -Recurse -Force -Confirm:$false -ErrorAction Stop
            $copiedCount++
        }

        return $copiedCount
    }

    $repositoryUrl = $ProfileUrl.AbsoluteUri
    $resolvedProfilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath)
    $stagePath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('PowerShell-Profile-{0}' -f ([guid]::NewGuid()))

    try {
        Assert-SafeProfilePath -Path $resolvedProfilePath
        Assert-CommandAvailable -Name 'git' -InstallMessage 'Git is required to install this profile. Install Git, then run Install-Profile again.'

        git clone --recursive $repositoryUrl $stagePath
        if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE." }

        Assert-StagedProfileValid -Path $stagePath

        $stoppedProcessCount = Stop-OtherPowerShellSessions -CurrentProcessId $PID
        $deletedExistingProfile = Remove-ProfileDirectoryForce -Path $resolvedProfilePath
        $copiedItemCount = Copy-DirectoryContents -SourcePath $stagePath -DestinationPath $resolvedProfilePath -ExcludeName @('.git')

        Write-Information -MessageData 'PowerShell profile installed. Reload the console to load the new profile.'

        [pscustomobject]@{
            ProfilePath            = $resolvedProfilePath
            Repository             = $repositoryUrl
            Installed              = $true
            ExistingProfileDeleted = $deletedExistingProfile
            StoppedPowerShellCount = $stoppedProcessCount
            CopiedItemCount        = $copiedItemCount
            RestartRequired        = $true
            NextStep               = 'Reload the console to load the new profile.'
            CurrentSessionCommand  = '. $PROFILE'
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagePath) {
            Remove-Item -LiteralPath $stagePath -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}