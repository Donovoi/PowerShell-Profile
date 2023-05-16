function Get-LatestAria2c {
    $aria2LatestReleaseApi = "https://api.github.com/repos/aria2/aria2/releases/latest"
    $response = Invoke-RestMethod -Uri $aria2LatestReleaseApi
    
    $zipUrl = $response.assets | Where-Object { $_.name -like "aria2-*-win-64bit-build1.zip" } | Select-Object -ExpandProperty browser_download_url
    
    if (-not (Test-Path -Path "TemporaryAria2c")) {
        New-Item -ItemType Directory -Path "TemporaryAria2c" | Out-Null
    }
    $zipOutput = "TemporaryAria2c\aria2c.zip"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipOutput
    
    Expand-Archive -Path $zipOutput -DestinationPath "TemporaryAria2c"
    $GLOBAL:aria2cExePath = (Get-ChildItem -Path "TemporaryAria2c" -Recurse -Filter "aria2c.exe" | Select-Object -First 1).FullName
    
    return $aria2cExePath
}

function Invoke-Aria2Download {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Url,
        
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [int]$Connections = 20
    )


    if (-not (Test-Path $aria2cExePath)) {
        $aria2cExePath = Get-LatestAria2c
    }

    $downloadParentDir = (Resolve-Path -Path (Split-Path -Path $OutputPath)).Path
    $downloadFileName = (Split-Path -Path $OutputPath -Leaf)

    $aria2cArgs = @("--log-level=notice", "--split=$Connections", "--dir=""$downloadParentDir""", "--out=""$downloadFileName""", $Url)

    try {
        $process = Start-Process -FilePath $aria2cExePath -ArgumentList $aria2cArgs -NoNewWindow -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            throw "Aria2c exited with a non-zero code. Download may be incomplete or failed."
        }
    } catch {
        throw "Failed while downloading with Aria2c. Error: $_"
    }
}