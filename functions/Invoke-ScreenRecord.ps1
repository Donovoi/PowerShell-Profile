



function Install-psScreenRecorder {
    param (
    )
    # Import the required cmdlets
    $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties')
    $neededcmdlets | ForEach-Object {
        if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose -Message "Importing cmdlet: $_"
            $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
            $Cmdletstoinvoke | Import-Module -Force
        }
    }
    Install-Dependencies -PSModule psScreenRecorder -LocalModulesDirectory "$PWD\Modules" -NoNugetPackage

}

function Start-StepsRecorder {
    # Define the default output path
    $defaultOutputPath = "$PWD" + '\StepsRecorder'

    # Ensure the directory exists
    if (-not (Test-Path -Path $defaultOutputPath)) {
        New-Item -ItemType Directory -Path $defaultOutputPath
    }

    # Set the default output path in the registry
    $psrRegistryKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Problem Steps Recorder'
    if (-not (Test-Path -Path $psrRegistryKey)) {
        New-Item -Path $psrRegistryKey -Force
    }

    Set-ItemProperty -Path $psrRegistryKey -Name 'OutputLocation' -Value $defaultOutputPath

    Write-Output "Default output path for Steps Recorder set to $defaultOutputPath."

    # Define the number of recent screen captures to store
    $numberOfCaptures = 50

    # Set the registry key path
    $psrRegistryKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Problem Steps Recorder'

    # Ensure the registry key exists
    if (-not (Test-Path -Path $psrRegistryKey)) {
        New-Item -Path $psrRegistryKey -Force
    }

    # Set the number of recent screen captures to store
    Set-ItemProperty -Path $psrRegistryKey -Name 'NumberOfRecentScreenCapturesToStore' -Value $numberOfCaptures

    Write-Output "Number of recent screen captures to store set to $numberOfCaptures."

    # Hide the PowerShell console window
    Add-Type -Name Win32ShowWindowAsync -Namespace Win32Functions -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
'@
    $hwnd = (Get-Process -Id $PID).MainWindowHandle
    [Win32Functions.Win32ShowWindowAsync]::ShowWindowAsync($hwnd, 0)

    # Start Steps Recorder
    Start-Process -FilePath 'C:\Windows\System32\psr.exe'

    # Wait for Steps Recorder to start
    Start-Sleep -Seconds 5

    # Simulate ALT + A to start recording
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait('%a')


}

function Stop-AndSave-StepsRecorder {
    param (
        [string]$SavePath
    )

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait('%o')
    Start-Sleep -Seconds 1
    [System.Windows.Forms.SendKeys]::SendWait('%f')
    Start-Sleep -Seconds 1
    [System.Windows.Forms.SendKeys]::SendWait('s')
    Start-Sleep -Seconds 1
    [System.Windows.Forms.SendKeys]::SendWait("$SavePath")
    Start-Sleep -Seconds 1
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Write-Output "Steps Recorder stopped and saved to $SavePath."
}

function Compress-Files {
    param (
        [string]$SourcePath1,
        [string]$SourcePath2,
        [string]$DestinationPath
    )

    try {
        Compress-Archive -Path $SourcePath1, $SourcePath2 -DestinationPath $DestinationPath -ErrorAction Stop
        Write-Output "Files compressed into $DestinationPath."
    }
    catch {
        throw "Failed to compress files: $_"
    }
}

function Invoke-RecordActions {
    param (
        [string]$OutFolder = 'C:\temp\ScreenRecord',
        [string]$VideoName = 'ScreenCapture.mp4',
        [string]$StepsFileName = 'StepsRecording.mht',
        [string]$ZipFileName = 'RecordingBundle.zip',
        [int]$Duration = 30,
        [switch]$LocalDependencies,
        [string]$LocalPath
    )

    # Ensure output directory exists
    if (-Not (Test-Path -Path $OutFolder)) {
        New-Item -Path $OutFolder -ItemType Directory -Force | Out-Null
    }

    $ffmpegPath = if ($LocalDependencies) {
        Join-Path -Path $LocalPath -ChildPath 'ffmpeg\bin\ffmpeg.exe' 
    }
    else {
        "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe" 
    }
    $videoPath = Join-Path -Path $OutFolder -ChildPath $VideoName
    $stepsPath = Join-Path -Path $OutFolder -ChildPath $StepsFileName
    $zipPath = Join-Path -Path $OutFolder -ChildPath $ZipFileName

    Get-FFmpeg -DestinationPath $ffmpegPath -LocalDependencies:$LocalDependencies -LocalPath $LocalPath
    Install-psScreenRecorder -LocalDependencies:$LocalDependencies -LocalPath $LocalPath

    try {
        Start-StepsRecorder

        Import-Module psScreenRecorder
        New-psScreenRecord -outFolder $OutFolder -videoName $VideoName -fps 30 -ffMPegPath $ffmpegPath

        Start-Sleep -Seconds $Duration

        Stop-AndSave-StepsRecorder -SavePath $stepsPath
        Stop-psScreenRecord

        Compress-Files -SourcePath1 $videoPath -SourcePath2 $stepsPath -DestinationPath $zipPath

        Write-Output "Recording and steps have been saved and bundled into: $zipPath"
    }
    catch {
        throw "An error occurred during the recording process: $_"
    }
}