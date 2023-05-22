function Update-VScodes {
    [CmdletBinding()]
    param(
    )
    process {
        Write-Host -Object "Script is running as $($MyInvocation.MyCommand.Name)" 
        $Global:XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter

        $Urls = @(
            @{
                URL             = 'https://code.visualstudio.com/sha/download?build=insider&os=win32-x64-archive'
                OutFile         = "$ENV:USERPROFILE\downloads\insiders.zip"
                DestinationPath = "$XWAYSUSB\vscode-insider\"
            },
            @{
                URL             = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive'
                OutFile         = "$ENV:USERPROFILE\downloads\vscode.zip"
                DestinationPath = "$XWAYSUSB\vscode\"
            }
        )

        $Urls | ForEach-Object -Process {
            try {
                Invoke-WebRequest -Uri $_.URL -OutFile $_.OutFile
                Write-Progress -Activity "Downloading and extracting" -Status $_.OutFile
                Expand-Archive $_.OutFile -DestinationPath $_.DestinationPath -Force 
            }
            catch {
                Write-Error -Message "Error occurred: $($_.Exception.Message)" -ErrorAction Continue
            }
        }
    }
}