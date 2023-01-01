function Get-SpeedyDownload {

    [CmdletBinding()]
    param (
        [Parameter()]
        [uri] $url = "https://drive.google.com/file/d/1_NZo5gVGq5k7vFzsA4APVnAi5LK33x7j/view?usp=share_link"      
    )
    
    # import the System.Net.Http assembly
    Add-Type -AssemblyName System.Net.Http

    # create a new HttpClient instance
    $client = New-Object System.Net.Http.HttpClient

    # set the number of connections to use
    $client.DefaultRequestHeaders.ConnectionClose = $false

    # set the download speed threshold (in bytes per second)
    $threshold = 1024 * 1024 # 1 MB/s

    # flag to indicate if another connection should be added
    $addConnection = $false

    # get the start time of the download
    $start = Get-Date

    # download the file
    $response = $client.GetAsync($url).Result
    $content = $response.Content

    # get the content length of the file
    $length = [int]$response.Content.Headers.ContentLength

    # create a buffer to hold the downloaded data
    $buffer = New-Object byte[] $length

    # download the file in chunks
    $offset = 0
    while ($offset -lt $length) {
        # calculate the number of bytes to download in this chunk
        $bytesToRead = $length - $offset
        if ($bytesToRead -gt $chunkSize) {
            $bytesToRead = $chunkSize    
        }

        # download a chunk of the file
        $bytesRead = $content.ReadAsByteArrayAsync().Result
        $offset += $bytesRead.Length
    
        # check the download speed
        $elapsed = [int](Get-Date).Subtract($start).TotalMilliseconds
        $speed = [int]($offset / $elapsed * 1000)
        if ($speed -lt $threshold) {
            $addConnection = $true
        }
    
        # copy the downloaded data to the buffer
        [Array]::Copy($bytesRead, 0, $buffer, $offset, $bytesRead.Count)
    
        # update the progress bar
        Write-Progress -Activity "Downloading" -Status "$($offset / 1MB) MB / $($length / 1MB) MB" -PercentComplete ($offset / $length * 100)
    }
    
    # add another connection if the speed was below the threshold
    if ($addConnection) {
        $client.DefaultRequestHeaders.ConnectionClose = $false
        $response = $client.GetAsync($url).Result
        $content = $response.Content
        $bytesRead = $content.ReadAsByteArrayAsync().Result
        $offset += $bytesRead.Length
    
        # copy the downloaded data to the buffer
       $arrayvar = [Array]::Copy($bytesRead, 0, $buffer, $offset, $bytesRead.Length)
    }
    
    # save the downloaded data to a file
    [System.IO.File]::WriteAllBytes("C:\temp\file.zip", $buffer)
}

Get-SpeedyDownload -Verbose