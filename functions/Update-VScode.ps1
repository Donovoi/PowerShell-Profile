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

        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $session.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36'

        $headers = @{
            'authority'                 = 'az764295.vo.msecnd.net'
            'method'                    = 'GET'
            'scheme'                    = 'https'
            'accept'                    = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7'
            'accept-encoding'           = 'gzip, deflate, br'
            'accept-language'           = 'en-AU,en-GB;q=0.9,en-US;q=0.8,en;q=0.7,zh-CN;q=0.6,zh;q=0.5'
            'cache-control'             = 'no-cache'
            'dnt'                       = '1'
            'pragma'                    = 'no-cache'
            'referer'                   = 'https://code.visualstudio.com/'
            'sec-ch-ua'                 = "`"Not.A/Brand`";v=`"8`", `"Chromium`";v=`"114`", `"Google Chrome`";v=`"114`""
            'sec-ch-ua-mobile'          = '?0'
            'sec-ch-ua-platform'        = "`"Windows`""
            'sec-fetch-dest'            = 'document'
            'sec-fetch-mode'            = 'navigate'
            'sec-fetch-site'            = 'cross-site'
            'upgrade-insecure-requests' = '1'
        }

        if ($Version -eq 'both') {
            foreach ($url in $urls) {
                Invoke-WebRequest -Uri $url.URL -WebSession $session -Headers $headers -OutFile $url.OutFile
                Expand-Archive -Path $url.OutFile -DestinationPath $url.DestinationPath -Force 
            }
        }
        elseif ($urls.Version -contains $Version) {
            $url = $urls | Where-Object { $_.Version -eq $Version }
            Invoke-WebRequest -Uri $url.URL -WebSession $session -Headers $headers -OutFile $url.OutFile
            Expand-Archive -Path $url.OutFile -DestinationPath $url.DestinationPath -Force -Verbose
        }
        else {
            Write-Error "Invalid version specified. Please choose 'stable', 'insider', or 'both'."
            return
        }
    }
}
