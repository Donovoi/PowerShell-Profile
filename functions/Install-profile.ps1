function Install-Profile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $profileURL = 'https://github.com/Donovoi/PowerShell-Profile.git'
    )

    $myDocuments = [System.Environment]::GetFolderPath('MyDocuments')
    $powerShell7ProfilePath = Join-Path -Path $myDocuments -ChildPath 'PowerShell'

    function Install-PowerShell7 {
        if (-not (Get-Command -Name pwsh -ErrorAction SilentlyContinue)) {
            if (Get-Command -Name winget -ErrorAction SilentlyContinue) {
                Write-Host 'PowerShell 7 is not installed. Installing now...' -ForegroundColor Yellow
                winget install --id=Microsoft.PowerShell
                Write-Host 'PowerShell 7 installed successfully!' -ForegroundColor Green
            }
            else {
                Write-Host 'winget is not available. Please install winget first.' -ForegroundColor Red
                exit
            }
        }
    }

    function New-ProfileFolder {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )
        if (Test-Path -Path $path) {
            Invoke-RemoveItem -Path $path
        }
        New-Item -Path $path -ItemType Directory -Force
        Write-Host "Profile folder created successfully at $path" -ForegroundColor Green
    }

    function Import-Functions {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )
        $functionPath = Join-Path -Path $path -ChildPath 'functions'
        if (Test-Path -Path $functionPath) {
            $FunctionsFolder = Get-ChildItem -Path (Join-Path -Path $functionPath -ChildPath '*.ps*') -Recurse
            $FunctionsFolder.ForEach{
                try {
                    . $_.FullName
                }
                catch {
                    Write-Host "Error importing function from $($_.FullName): $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }

    function Install-Git {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            if (Get-Command -Name winget -ErrorAction SilentlyContinue) {
                winget install --id=Git.Git
            }
            else {
                Write-Host 'winget is not available. Please install winget first.' -ForegroundColor Red
                exit
            }
        }
    }

    function Clone-Repo {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )
        if (Test-Path -Path $path) {
            Set-Location -Path $path
            $repoPath = Join-Path -Path $path -ChildPath 'powershellprofile'
            if (Test-Path -Path $repoPath) {
                Remove-Item -Path $repoPath -Recurse -Force
            }
            try {
                git clone --recursive $profileURL $repoPath
                Copy-Item -Path "$repoPath\*" -Destination $path -Force -Recurse
            }
            catch {
                Write-Host "Error cloning repository: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    function Invoke-RemoveItem {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string[]]$Path
        )
    
        begin {
            # Check if the file is removable and if not, try to make it removable
            $Path | ForEach-Object {
                if (-not (Test-IsRemovable -Path $_)) {
                    Set-Removable -Path $_
                }
            }
        }
    
        process {
            # Attempt to remove the file
            $Path | ForEach-Object {
                if (Test-IsRemovable -Path $_) {
                    Remove-Item $_ -ErrorAction Stop
                }
                else {
                    Write-Error "Failed to remove the file: $_"
                }
            }
        }
    }
    
    function Test-IsRemovable {
        [CmdletBinding()]
        [OutputType([bool])]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )
    
        try {
            Remove-Item $Path -WhatIf -ErrorAction Stop
            return $true
        }
        catch {
            return $false
        }
    }
    
    function Set-Removable {
        [CmdletBinding(SupportsShouldProcess)]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )
    
        if ($PSCmdlet.ShouldProcess($Path, 'Take ownership and grant full control')) {
            try {
                takeown /f $Path
                icacls $Path /grant "${env:USERNAME}`:(F)"
            }
            catch {
                Write-Error "Failed to make the file removable: $($_.Exception.Message)"
            }
        }
    }

    Install-PowerShell7

    New-ProfileFolder -Path $powerShell7ProfilePath
    Import-Functions -Path $powerShell7ProfilePath

    Install-Git

    $folderarray = $powerShell7ProfilePath
    $folderarray | ForEach-Object -Process {
        Clone-Repo -Path $_
        Import-Functions -Path $_
    }
}

# Install-Profile
