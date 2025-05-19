
<#
.SYNOPSIS
    A function to download and install FFmpeg.
.DESCRIPTION
    This function downloads and installs FFmpeg from the specified URL. It can also download FFmpeg locally and extract it.
.NOTES
    File Name      : Get-FFmpeg.ps1
    Author         : Donovoi
    Prerequisite   : PowerShell V5.1
.EXAMPLE
    Get-FFmpeg -Url 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-full.7z' -DestinationPath 'C:\ffmpeg\bin\ffmpeg.exe'
    This example downloads FFmpeg from the specified URL and installs it to the specified destination path.
#>


function Get-FFmpeg {
    [CmdletBinding()]
    param (
        [string]$Url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-full.7z',
        [string]$DestinationPath,
        [switch]$LocalDependencies,
        [string]$LocalPath = $PWD
    )
    # Import the required cmdlets
    $neededcmdlets = @('Install-Dependencies', 'Write-Logg')
    $neededcmdlets | ForEach-Object {
        if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose -Message "Importing cmdlet: $_"
            $Cmdletstoinvoke = Install-Cmdlet -RepositoryCmdlets $_
            $Cmdletstoinvoke | Import-Module -Force
        }
    }
    if ($LocalDependencies) {
        $DestinationPath = Join-Path -Path $LocalPath -ChildPath 'ffmpeg\bin\ffmpeg.exe'
        if (-Not (Test-Path -Path $DestinationPath)) {
            Write-Output 'FFmpeg not found locally. Downloading...'
            $zipPath = Join-Path -Path $LocalPath -ChildPath 'ffmpeg.7z'
            try {
                Invoke-WebRequest -Uri $Url -OutFile $zipPath -ErrorAction Stop
                #  to unzip we will use the libarchive library
                Install-dependencies -NugetPackage @{LibArchive = '0.1.5' }
                Remove-Item -Path $zipPath -ErrorAction Stop
                Write-Output 'FFmpeg downloaded and installed locally.'
            }
            catch {
                throw "Failed to download or extract FFmpeg: $_"
            }
        }
        else {
            Write-Output 'FFmpeg is already installed locally.'
        }
    }
    else {
        if (-Not (Test-Path -Path $DestinationPath)) {
            Write-Output 'FFmpeg not found. Downloading...'
            $zipPath = "$env:TEMP\ffmpeg.zip"
            try {
                Invoke-WebRequest -Uri $Url -OutFile $zipPath -ErrorAction Stop
                Expand-Archive -Path $zipPath -DestinationPath (Split-Path -Parent $DestinationPath) -ErrorAction Stop
                Remove-Item -Path $zipPath -ErrorAction Stop
                Write-Output 'FFmpeg downloaded and installed.'
            }
            catch {
                throw "Failed to download or extract FFmpeg: $_"
            }
        }
        else {
            Write-Output 'FFmpeg is already installed.'
        }
    }
}