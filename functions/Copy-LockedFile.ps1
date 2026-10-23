function Copy-LockedFile {
    <#
    .SYNOPSIS
    Copies a locked file only through a tool that provides verified acquisition evidence.
    .DESCRIPTION
    Invoke-RawCopy implements the required adapter contract: Success, Length and SHA256
    must describe the newly staged output. Arbitrary executable exit codes or an
    old destination file are not accepted as proof. Legacy external adapters are
    refused until their output/provenance can be validated.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceFile,[Parameter(Mandatory)][string]$DestinationFile,[pscustomobject[]]$ForensicTools=@(),[switch]$PassThru)
    $record=[pscustomobject]@{Success=$false;Source=$SourceFile;Destination=$DestinationFile;Length=0L;SHA256=$null;Verified=$false;Method='Unavailable';Error='No verified locked-file adapter was supplied.'}
    $tool=$ForensicTools|Where-Object Name -EQ 'Invoke-RawCopy'|Select-Object -First 1
    $temporary=$null
    if($tool){
        try {
            $destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationFile)
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $temporary=$destination+'.'+[guid]::NewGuid().ToString('N')+'.partial'
            $command=if($tool.Path){$tool.Path}else{'Invoke-RawCopy'}
            $acquisition=& $command -Path $SourceFile -Destination $temporary -Confirm:$false -ErrorAction Stop
            if(@($acquisition).Count -ne 1 -or -not $acquisition.Success -or $acquisition.SHA256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Acquisition did not return verified provenance.'}
            $file=Get-Item -LiteralPath $temporary -ErrorAction Stop
            if($file.Length -ne $acquisition.Length -or (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $acquisition.SHA256){throw 'Acquisition output differs from its provenance.'}
            [IO.File]::Move($temporary,$destination,$true)
            $record.Success=$true;$record.Verified=$true;$record.Length=$file.Length;$record.SHA256=$acquisition.SHA256;$record.Method=$acquisition.Method;$record.Error=$null
        }
        catch {$record.Error=$_.Exception.Message}
        finally {if($temporary -and [IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    }
    if($PassThru){$record}else{[bool]$record.Success}
}
