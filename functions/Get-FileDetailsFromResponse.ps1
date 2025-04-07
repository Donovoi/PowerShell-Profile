function Get-FileDetailsFromResponse {
    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebResponseObject]$Response,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Initialize defaults
    $fileName = 'downloaded_file'
    $fileSize = 0

    # Try to get filename from Content-Disposition header
    if ($Response.Headers.ContainsKey('Content-Disposition')) {
        $contentDisposition = $Response.Headers['Content-Disposition']
        Write-Verbose "Content-Disposition: $contentDisposition"

        if ($contentDisposition -match 'filename="?([^"]+)"?') {
            $fileName = $matches[1].Trim()
            Write-Verbose "Extracted filename: $fileName"
        }
        elseif ($contentDisposition -match 'filename\*=UTF-8''([^'']+)') {
            $fileName = [System.Web.HttpUtility]::UrlDecode($matches[1])
            Write-Verbose "Extracted UTF-8 filename: $fileName"
        }
    }
    else {
        Write-Verbose 'No Content-Disposition header found, using default filename.'
    }

    # Try to get file size from Content-Length header
    try {
        if ($Response.Headers.ContainsKey('Content-Length')) {
            # Fix: Handle Content-Length as possible array
            $contentLength = $Response.Headers['Content-Length']

            if ($contentLength -is [array]) {
                Write-Verbose 'Content-Length is an array, using first value'
                $fileSize = [long]($contentLength[0])
            }
            else {
                $fileSize = [long]$contentLength
            }

            Write-Verbose "Content-Length: $fileSize bytes"
        }
        else {
            # If no Content-Length, measure the content
            $fileSize = $Response.Content.Length
            Write-Verbose "No Content-Length header, measured content size: $fileSize bytes"
        }
    }
    catch {
        Write-Warning "Could not determine file size: $_"
        # Default to measuring content if conversion fails
        try {
            $fileSize = $Response.Content.Length
            Write-Verbose "Using content length after header conversion failure: $fileSize bytes"
        }
        catch {
            Write-Warning "Could not measure content size: $_"
            $fileSize = 0
        }
    }

    return @{
        FileName = $fileName
        FileSize = $fileSize
        Force    = $Force
    }
}