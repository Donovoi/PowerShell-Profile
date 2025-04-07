# Helper function to save binary content in a PowerShell version-compatible way
function Save-BinaryContent {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [byte[]]$Content,
                
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
            
    begin {
        Write-Verbose "Preparing to save binary content to: $Path"
        $allContent = @()
    }
            
    process {
        # Accumulate content from pipeline
        $allContent += $Content
    }
            
    end {
        try {
            Write-Verbose "Saving binary content to: $Path"
                    
            # Use version-appropriate method to write binary content
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                # PowerShell 6+ uses -AsByteStream
                $allContent | Set-Content -Path $Path -AsByteStream -Force
            } 
            else {
                # PowerShell 5.1 and below uses -Encoding Byte
                $allContent | Set-Content -Path $Path -Encoding Byte -Force
            }
                    
            Write-Verbose 'Content saved successfully.'
            return $true
        }
        catch {
            Write-Error "Failed to save content: $_"
            throw $_
        }
    }
}