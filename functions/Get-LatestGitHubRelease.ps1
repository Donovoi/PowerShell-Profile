<#
.SYNOPSIS
   This is a magic tool that finds the newest treasure (release) from a GitHub castle (repository) and can even bring it to your computer!

.DESCRIPTION
   Imagine you are a treasure hunter, and you are looking for the newest treasure in a GitHub castle. 
   This magic tool helps you find the latest treasure and even brings it to your computer if you want. 
   It's like having a magic map and a teleportation spell all in one!

.PARAMETER OwnerRepository
   This is the name of the castle where the treasure is hidden. It looks something like 'king/castle'.

.PARAMETER AssetName
   This is the name of the treasure you are looking for. If you don't tell the tool, it will just pick the first treasure it finds.

.PARAMETER DownloadPathDirectory
   This is where you want to keep the treasure once you find it. If you don't choose a place, the tool will just put it where you are standing right now.

.PARAMETER ExtractZip
   This is a magic word that tells the tool to open the treasure chest (zip file) automatically if it finds one.

.PARAMETER UseAria2
   This is another magic word that tells the tool to use a special spell (Aria2) to bring the treasure to you.

.PARAMETER PreRelease
   This magic word tells the tool to also look for treasures that are not officially released yet.

.PARAMETER VersionOnly
   If you say this magic word, the tool will only tell you the name of the newest treasure, but won't bring it to you.

.PARAMETER TokenName
   This is a secret password that helps the tool talk to the GitHub castle's guards. Keep it safe!

.EXAMPLE
   Get-LatestGitHubRelease -OwnerRepository 'king/castle' -TokenName 'your_secret_password_here'

.NOTES
   Remember, the GitHub castle has guards that only allow a certain number of treasure hunts in a short time. So use your magic tool wisely!
#>
function Get-LatestGitHubRelease {
    [CmdletBinding(DefaultParameterSetName = 'Download')]
    [OutputType([string])]
    param(
        # This is where you tell the tool the name of the castle (repository) where the treasure is hidden.
        [Parameter(Mandatory = $true)]
        [string]
        $OwnerRepository,

        # Here, you can tell the tool the name of the treasure (asset) you are looking for.
        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [string]
        $AssetName,

        # This is where you tell the tool where to put the treasure once it finds it.
        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [string]
        $DownloadPathDirectory = $PWD,

        # Say this magic word if you want the tool to open the treasure chest (zip file) automatically.
        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [switch]
        $ExtractZip,

        # Say this magic word if you want the tool to use a special spell (Aria2) to bring the treasure to you.
        [Parameter(Mandatory = $false, ParameterSetName = 'Download')]
        [switch]
        $UseAria2,

        # This magic word tells the tool to also look for treasures that are not officially released yet.
        [Parameter(Mandatory = $false)]
        [switch]
        $PreRelease,

        # If you say this magic word, the tool will only tell you the name of the newest treasure, but won't bring it to you.
        [Parameter(Mandatory = $false, ParameterSetName = 'VersionOnly')]
        [switch]
        $VersionOnly,

        # This is where you tell the tool your secret password to talk to the GitHub castle's guards.
        [Parameter(Mandatory = $false)]
        [string]
        $TokenName = 'GitHubToken'
    )
    
    # Here, the tool checks if it already knows the secret password to the GitHub castle.
    $currentConfig = Get-SecretStoreConfiguration

    if ($currentConfig.Authentication -ne 'None') {
        try {
            # The tool asks you for the password to the secret store where the GitHub castle's password is kept.
            Write-Host "You will now be asked to enter the password for the current store: " -ForegroundColor Yellow
            Unlock-SecretStore -Password $(Read-Host -Prompt "Enter the password for the secret store" -AsSecureString)
        }
        catch {
            # If the tool can't unlock the secret store, it changes the settings so it doesn't need a password next time.
            Set-SecretStoreConfiguration -Scope CurrentUser -Authentication None -Interaction None -Confirm:$false
        }
    }
    else {
        # If there is no secret store yet, the tool creates one and asks you for a new password to keep the GitHub castle's password safe.
        try {
            Write-Host "Initializing the secret store..." -ForegroundColor Yellow
            Write-Host "You will now be asked to enter a password for the secret store: " -ForegroundColor Yellow
            Set-SecretStoreConfiguration -Scope CurrentUser -Authentication None -Interaction None -Confirm:$false
        }
        catch {
            # If something goes wrong while creating the secret store, the tool tells you what happened.
            Write-Host "An error occurred while initializing the secret store: $_" -ForegroundColor Red
            throw
        }
    }

    # Here, the tool checks if it already knows the GitHub castle's password.
    $Token = Get-Secret -Name $TokenName -ErrorAction SilentlyContinue -AsPlainText

    # If the tool doesn't know the GitHub castle's password yet, it asks you to tell it.
    if ($null -eq $Token) {
        $TokenValue = Read-Host -Prompt "Enter the GitHub token" -AsSecureString
        Set-StoredSecret -Secret $TokenValue -SecretName $TokenName
        $Token = $TokenValue
    }

    # Here, the tool prepares to talk to the GitHub castle's guards.
    $headers = @{
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($null -ne $Token) {
        $headers['Authorization'] = "Bearer $Token"
    }

    # Here, the tool starts looking for the treasure in the GitHub castle.
    $apiurl = "https://api.github.com/repos/$OwnerRepository/releases"
    if ($PreRelease) {
        $releases = Invoke-RestMethod -Uri $apiurl -Headers $headers
        $Release = $releases | Sort-Object -Property created_at | Select-Object -Last 1
    }
    else {
        $Release = Invoke-RestMethod $($apiurl + '/latest') -Headers $headers
    }

    # If the tool can't find the newest treasure, it tries another way to find it.
    if ($Release.Message -like '*Not Found*') {
        Write-Log -Message "Looks like the repo doesn't have a latest tag, let's try another way" -Level Warning
        $ManualRelease = Invoke-RestMethod -Uri $apiurl -Headers $headers | Sort-Object -Property created_at | Select-Object -Last 1
        $manualDownloadurl = $ManualRelease.assets.Browser_Download_url | Select-Object -First 1
    }

    # If you said the 'VersionOnly' magic word, the tool stops here and tells you the name of the newest treasure.
    if ($PSBoundParameters.ContainsKey('VersionOnly')) {
        $Version = $Release.name.Split(' ')[0]
        return $Version
    }
    else {
        # If you didn't say the 'VersionOnly' magic word, the tool finds the exact treasure you are looking for.
        $asset = $Release.assets | Where-Object { $_ -like "*$AssetName*" } | Select-Object -First 1
    }

    # Here, the tool prepares to bring the treasure to you.
    if (-not (Test-Path $DownloadPathDirectory)) {
        New-Item -Path $DownloadPathDirectory -ItemType Directory -Force
    }

    # Here, the tool brings the treasure to you using the method you chose (with or without Aria2).
    if ($asset.Browser_Download_url) {
        if ($UseAria2) {
            $downloadedFile = Get-DownloadFile -URL $asset.Browser_Download_url -OutFile (Join-Path -Path $DownloadPathDirectory -ChildPath $asset.Name) -UseAria2
        }
        else {
            $downloadedFile = (Join-Path -Path $DownloadPathDirectory -ChildPath $asset.Name)
            Invoke-WebRequest $asset.Browser_Download_url -OutFile $downloadedFile
        }
    }
    else {
        if ($UseAria2) {
            $downloadedFile = Get-DownloadFile -URL $manualDownloadurl -OutFile (Join-Path -Path $DownloadPathDirectory -ChildPath $($manualDownloadurl -split '\/')[-1]) -UseAria2
        }
        else {
            $downloadedFile = (Join-Path -Path $DownloadPathDirectory -ChildPath $($manualDownloadurl -split '\/')[-1])
            Invoke-WebRequest $manualDownloadurl -OutFile $downloadedFile
        }
    }

    # If you said the 'ExtractZip' magic word, the tool opens the treasure chest (zip file) for you.
    if ($ExtractZip) {
        if ($downloadedFile -notlike '*.zip') {
            Write-Log -Message 'The downloaded file is not a zip file, skipping extraction' -Level Warning
            return $downloadedFile
        }
        Expand-Archive -Path $downloadedFile -DestinationPath $DownloadPathDirectory -Force
        $ExtractedFiles = Join-Path -Path $DownloadPathDirectory -ChildPath ($asset.Name -replace '.zip', '')
        Write-Log -Message "Extracted $downloadedFile to $ExtractedFiles"
        return $ExtractedFiles
    }
    else {
        # If you didn't say the 'ExtractZip' magic word, the tool just brings the treasure to you without opening it.
        Write-Log -Message "Downloaded $downloadedFile to $DownloadPathDirectory"
    }
    return $downloadedFile
}