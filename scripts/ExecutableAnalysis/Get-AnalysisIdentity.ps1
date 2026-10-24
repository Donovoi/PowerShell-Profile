function Get-AnalysisIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath, [int]$ScanBytes = 16777216)
    $file = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
    $stream = [IO.File]::Open($file.FullName, 'Open', 'Read', 'Read')
    try {
        $bytes = [byte[]]::new([int][Math]::Min($file.Length,$ScanBytes))
        $count = 0
        while ($count -lt $bytes.Length) {
            $read = $stream.Read($bytes,$count,$bytes.Length-$count)
            if (-not $read) { break }; $count += $read
        }
    } finally { $stream.Dispose() }
    $format = 'Unknown'; $architecture = 'Unknown'; $managed = $false; $header = [ordered]@{}
    $magic = if($bytes.Length){[Convert]::ToHexString($bytes[0..([Math]::Min(7,$bytes.Length-1))])}else{''}
    if ($count -ge 64 -and $bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a) {
        $pe = [BitConverter]::ToInt32($bytes,60)
        if ($pe -ge 64 -and $pe -le $count-24 -and [BitConverter]::ToUInt32($bytes,$pe) -eq 0x4550) {
            $format = 'PE'; $machine = [BitConverter]::ToUInt16($bytes,$pe+4)
            $header.Subsystem=$null; $header.IsEfi=$false
            $architecture = switch ($machine) { 0x8664 {'x86_64'} 0x14c {'x86'} 0xaa64 {'arm64'} default {'Unknown'} }
            $optionalSize = [BitConverter]::ToUInt16($bytes,$pe+20)
            $optional = $pe+24
            if ($optionalSize -ge 2 -and $optional+$optionalSize -le $count) {
                $kind = [BitConverter]::ToUInt16($bytes,$optional)
                if($kind -in 0x10b,0x20b -and $optionalSize -ge 70){
                    $header.Subsystem=[BitConverter]::ToUInt16($bytes,$optional+68)
                    $header.IsEfi=$header.Subsystem -in 10,11,12,13
                }
                $directories = if ($kind -eq 0x20b) {112} elseif ($kind -eq 0x10b) {96} else {0}
                if ($directories -and $optionalSize -ge $directories+120) {
                    $directoryCount = [BitConverter]::ToUInt32($bytes,$optional+$directories-4)
                    $managed = $directoryCount -gt 14 -and [BitConverter]::ToUInt32($bytes,$optional+$directories+112) -ne 0
                }
            }
            $header.Sections = [BitConverter]::ToUInt16($bytes,$pe+6)
            $header.ManagedHeaderPresent = $managed
            $characteristics=[BitConverter]::ToUInt16($bytes,$pe+22)
            $header.IsDll=($characteristics -band 0x2000) -ne 0
            $header.ExecutableImage=($characteristics -band 2) -ne 0
        } else { $format = 'DOS-MZ' }
    } elseif ($count -ge 20 -and $magic.StartsWith('7F454C46')) {
        $format = 'ELF'
        $machine = if ($bytes[5] -eq 2) { $bytes[18]*256+$bytes[19] } else { $bytes[18]+$bytes[19]*256 }
        $architecture = switch ($machine) { 62 {'x86_64'} 3 {'x86'} 40 {'arm'} 183 {'arm64'} 243 {'riscv'} default {'Unknown'} }
        $header.Class = $bytes[4]; $header.Endianness = $bytes[5]
        $header.Type=if($bytes[5] -eq 2){$bytes[16]*256+$bytes[17]}else{$bytes[16]+$bytes[17]*256}
    } elseif ($magic -match '^(CEFAEDFE|CFFAEDFE|FEEDFACE|FEEDFACF|CAFEBABE|BEBAFECA|CAFEBABF|BFBAFECA)') {
        $format = if ($magic.StartsWith('CAFEBABE') -and $count -ge 8 -and ($bytes[6]*256+$bytes[7]) -ge 45 -and ($bytes[6]*256+$bytes[7]) -le 100) { 'JavaClass' } else { 'MachO' }
    } elseif ($magic.StartsWith('0061736D')) { $format = 'WASM' }
    elseif ($magic -match '^504B(0304|0506|0708)') { $format = 'ZIP' }
    elseif ($magic.StartsWith('6465780A')) { $format = 'DEX' }
    elseif ($file.Extension -in '.js','.mjs','.cjs','.asar') { $format = 'JavaScriptCandidate' }
    $frequencies = [long[]]::new(256)
    foreach ($b in $bytes) { $frequencies[$b]++ }
    $entropy = 0.0
    foreach ($frequency in $frequencies) { if ($frequency) { $p=$frequency/[double]$count; $entropy -= $p*[Math]::Log($p,2) } }
    [pscustomobject]@{ Format=$format; Architecture=$architecture; Managed=$managed; Header=$header; Magic=$magic; Length=$file.Length; SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash; ScannedBytes=$count; ScanComplete=($count -eq $file.Length); Entropy=[Math]::Round($entropy,4) }
}

function Export-AnalysisString {
    [CmdletBinding()]
    param([string]$LiteralPath,[string]$OutputDirectory,[int]$ScanBytes=16777216,[int]$MaxStrings=20000)
    $stream=[IO.File]::OpenRead($LiteralPath)
    try {
        $bytes=[byte[]]::new([int][Math]::Min($stream.Length,$ScanBytes)); $read=0
        while($read -lt $bytes.Length) { $n=$stream.Read($bytes,$read,$bytes.Length-$read); if(-not $n){break};$read+=$n }
    } finally { $stream.Dispose() }
    $text=[Text.Encoding]::Latin1.GetString($bytes)
    $records=[Collections.Generic.List[object]]::new()
    $decode=[Collections.Generic.List[object]]::new()
    $truncatedStrings=0
    $pattern='[\x20-\x7e]{5,}|(?:[\x20-\x7e]\x00){5,}'
    $stringMatches=[regex]::Matches($text,$pattern,[Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromSeconds(15))
    foreach($match in $stringMatches) {
        if($records.Count -ge $MaxStrings){break}
        $value=$match.Value.Replace([string][char]0,'')
        $originalLength=$value.Length
        if($value.Length -gt 8192){$value=$value.Substring(0,8192);$truncatedStrings++}
        $records.Add([pscustomobject]@{Offset=$match.Index;Encoding=if($match.Value.Contains([char]0)){'UTF-16LE'}else{'ASCII'};OriginalCharacters=$originalLength;TextTruncated=($originalLength -gt $value.Length);Text=$value})
        if($decode.Count -lt 1000 -and $value -cmatch '^[A-Za-z0-9+/]{16,}={0,2}$' -and $value.Length%4 -eq 0) {
            try {
                $decoded=[Convert]::FromBase64String($value)
                $utf8=[Text.UTF8Encoding]::new($false,$true).GetString($decoded)
                if($utf8 -match '^[\x09\x0a\x0d\x20-\x7e]+$'){
                    $decode.Add([pscustomobject]@{Offset=$match.Index;Transform='Base64';Text=$utf8;Confidence='Candidate; valid encoding does not establish intent'})
                }
            } catch [FormatException] { Write-Verbose 'Rejected an invalid Base64 candidate.' } catch [Text.DecoderFallbackException] { Write-Verbose 'Decoded bytes are not valid UTF-8 text.' }
        }
    }
    ConvertTo-Json -InputObject $records.ToArray() -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'strings.json') -Encoding utf8
    ConvertTo-Json -InputObject $decode.ToArray() -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'decoded-candidates.json') -Encoding utf8
    [pscustomobject]@{Count=$records.Count;DecodedCandidates=$decode.Count;ScannedBytes=$bytes.Length;TotalMatches=$stringMatches.Count;TruncatedStrings=$truncatedStrings;Truncated=($truncatedStrings -gt 0 -or $stringMatches.Count -gt $MaxStrings -or $bytes.Length -lt (Get-Item -LiteralPath $LiteralPath).Length)}
}
