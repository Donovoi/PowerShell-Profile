<#
.SYNOPSIS
    Download the extra resources needed for xways forensics at the moment this is just Excire and Conditional Coloring
.DESCRIPTION
    Long description
.EXAMPLE
    Get-XwaysResources -DestinationFolder "C:\Xways" -Credentials $(Get-Credential)
#>
function Get-XwaysResources {
    [CmdletBinding()]
    [OutputType([type])]
    param(
        [Parameter()]
        [string]
        $DestinationFolder = "$XWAYSUSB\xwfportable",
        [Parameter(Mandatory = $true)]
        [securestring]
        $Credentials = $(Get-Credential)
    )
    
    #   First Resource to grab is Excire
    $UsernamePlainText = $Credentials.GetNetworkCredential().UserName
    $PasswordPlainText = $Credentials.GetNetworkCredential().Password

    $AuthenticationPair = "$($UsernamePlainText)`:$($PasswordPlainText)"
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($authenticationPair)
    $Base64AuthString = [System.Convert]::ToBase64String($bytes)



    # headers for xways website - can possibly remove some of these
    $method = [Microsoft.PowerShell.Commands.WebRequestMethod]::"GET"
    $URI = [System.Uri]::new("https://x-ways.net:443/res/Excire.zip")
    $maximumRedirection = [System.Int32] 0
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Host", "x-ways.net")
    $headers.Add("Authorization", "Basic $Base64AuthString")
    $headers.Add("Sec-Ch-Ua", "`"Chromium`";v=`"111`", `"Not_A Brand`";v=`"99`"")
    $headers.Add("Sec-Ch-Ua-Mobile", "?0")
    $headers.Add("Sec-Ch-Ua-Platform", "`"Windows`"")
    $headers.Add("Upgrade-Insecure-Requests", "1")
    $userAgent = [System.String]::new("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.5414.120 Safari/537.36")
    $headers.Add("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9")
    $headers.Add("Sec-Fetch-Site", "same-origin")
    $headers.Add("Sec-Fetch-Mode", "navigate")
    $headers.Add("Sec-Fetch-User", "?1")
    $headers.Add("Sec-Fetch-Dest", "document")
    $headers.Add("Referer", "https://x-ways.net/res/")
    $headers.Add("Accept-Encoding", "gzip, deflate")
    $headers.Add("Accept-Language", "en-US,en;q=0.9")
    $response = (Invoke-WebRequest -Method $method -Uri $URI -MaximumRedirection $maximumRedirection -Headers $headers -UserAgent $userAgent -OutFile "Excire.zip")
    $response

    # Extract zip to destination folder in the Excire folder
    Out-Host "Extracting Excire.zip to $DestinationFolder\Excire"
    Expand-Archive -Path "Excire.zip" -DestinationPath "$DestinationFolder\Excire" -Force

    # headers for xways website - can possibly remove some of these
    $method = [Microsoft.PowerShell.Commands.WebRequestMethod]::"GET"
    $URI = [System.Uri]::new("https://x-ways.net/res/conditional%20coloring/Conditional%20Coloring.cfg")
    $maximumRedirection = [System.Int32] 0
    $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
    $headers.Add("Host", "x-ways.net")
    $headers.Add("Authorization", "Basic $Base64AuthString")
    $headers.Add("Sec-Ch-Ua", "`"Chromium`";v=`"109`", `"Not_A Brand`";v=`"99`"")
    $headers.Add("Sec-Ch-Ua-Mobile", "?0")
    $headers.Add("Sec-Ch-Ua-Platform", "`"Windows`"")
    $headers.Add("Upgrade-Insecure-Requests", "1")
    $userAgent = [System.String]::new("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.5414.120 Safari/537.36")
    $headers.Add("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9")
    $headers.Add("Sec-Fetch-Site", "same-origin")
    $headers.Add("Sec-Fetch-Mode", "navigate")
    $headers.Add("Sec-Fetch-User", "?1")
    $headers.Add("Sec-Fetch-Dest", "document")
    $headers.Add("Referer", "https://x-ways.net/res/")
    $headers.Add("Accept-Encoding", "gzip, deflate")
    $headers.Add("Accept-Language", "en-US,en;q=0.9")
    $response = (Invoke-WebRequest -Method $method -Uri $URI -MaximumRedirection $maximumRedirection -Headers $headers -UserAgent $userAgent -OutFile "Conditional Coloring.cfg")
    $response


    # Copy Conditional Coloring.cfg to destination folder
    Out-Host "Copying Conditional Coloring.cfg to $DestinationFolder"
    Copy-Item -Path ".\Conditional Coloring.cfg" -Destination $DestinationFolder -Force


}