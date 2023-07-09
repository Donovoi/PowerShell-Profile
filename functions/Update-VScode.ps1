function Update-VSCode {
    [CmdletBinding()]
    param(
        [ValidateSet('stable', 'insider')]
        [string]$Version = 'both'
    )
    process {
        Write-Host "Script is running as $($MyInvocation.MyCommand.Name)" 

        $drive = Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'"
        if ($drive) {
            $global:XWAYSUSB = $drive.DriveLetter
        }
        else {
            Write-Error 'X-Ways USB drive not found.'
            return
        }

        $urls = @(
            @{
                Version         = 'stable'
                URL             = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
                OutFile         = "$ENV:USERPROFILE\downloads\vscode.zip"
                DestinationPath = "$XWAYSUSB\vscode\"
            },
            @{
                Version         = 'insider'
                URL             = 'https://code.visualstudio.com/sha/download?build=insider&os=win32-x64-archive'
                OutFile         = "$ENV:USERPROFILE\downloads\insiders.zip"
                DestinationPath = "$XWAYSUSB\vscode-insider\"
            }
        )

        if ($Version -eq 'both') {
            foreach ($url in $urls) {
                if (Test-Path $url.OutFile) {
                    Remove-Item -Path $url.OutFile -Force -Verbose -ErrorAction SilentlyContinue
                }
                Start-Process -FilePath 'aria2c' -ArgumentList @(
                    '--file-allocation=none',
                    '--check-certificate=false',
                    '--continue=false',
                    '--max-connection-per-server=16',
                    '--split=16',
                    '--min-split-size=1M',
                    '--max-tries=0',
                    '--allow-overwrite=true',
                    "--dir=$($url.OutFile | Split-Path -Parent)"
                    "--out=$($url.OutFile | Split-Path -Leaf)",
                    $url.URL
                ) -NoNewWindow -Wait

                Expand-Archive -Path $url.OutFile -DestinationPath $url.DestinationPath -Force 
            }
        }
        elseif ($urls.Version -contains $Version) {
            $url = $urls | Where-Object { $_.Version -eq $Version }
            if (Test-Path $url.OutFile) {
                Remove-Item -Path $url.OutFile -Force -Verbose -ErrorAction SilentlyContinue
            }
            Start-Process -FilePath 'aria2c' -ArgumentList @(
                '--file-allocation=none',
                '--check-certificate=false',
                '--continue=false',
                '--max-connection-per-server=16',
                '--split=16',
                '--min-split-size=1M',
                '--max-tries=0',
                '--allow-overwrite=true',
                "--dir=$($url.OutFile | Split-Path -Parent)"
                "--out=$($url.OutFile | Split-Path -Leaf)",
                $url.URL
            ) -NoNewWindow -Wait

            Expand-Archive -Path $url.OutFile -DestinationPath $url.DestinationPath -Force -Verbose
        }
        else {
            Write-Error "Invalid version specified. Please choose 'stable', 'insider', or 'both'."
            return
        }
    }
}