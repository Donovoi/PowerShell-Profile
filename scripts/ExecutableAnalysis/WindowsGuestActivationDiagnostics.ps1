# Trusted function-only asset for the owned guest management administrator.
# Loading this file performs no event queries. The helper never enables logs.
#requires -Version 5.1
function Get-AnalysisWindowsActivationDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{2,255}$')][string]$PackageFullName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{2,49}_[a-z0-9]{13}$')][string]$PackageFamilyName,
        [Parameter(Mandatory)][datetime]$StartedUtc
    )

    $collectedUtc=[datetime]::UtcNow
    $windowStart=$StartedUtc.ToUniversalTime()
    if($windowStart -gt $collectedUtc -or ($collectedUtc-$windowStart).TotalMinutes -gt 30){
        throw 'Activation diagnostics require a past start time no more than 30 minutes ago.'
    }
    $fullIdentity=[regex]::Match($PackageFullName,'\A(?<name>[A-Za-z0-9][A-Za-z0-9.-]{2,49})_\d+\.\d+\.\d+\.\d+_[A-Za-z0-9]+_[A-Za-z0-9.]*_(?<publisher>[a-z0-9]{13})\z')
    if(-not $fullIdentity.Success -or $PackageFamilyName -cne ($fullIdentity.Groups['name'].Value+'_'+$fullIdentity.Groups['publisher'].Value)){
        throw 'The supplied full package identity and family do not agree.'
    }
    $channels=@(
        'Microsoft-Windows-AppModel-Runtime/Admin',
        'Microsoft-Windows-TWinUI/Operational',
        'Microsoft-Windows-AppXDeploymentServer/Operational',
        'Microsoft-Windows-Store/Operational',
        'Application',
        'System'
    )
    $matchOptions=[Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
    $fullPattern=[regex]::new('(?<![A-Za-z0-9._-])'+[regex]::Escape($PackageFullName)+'(?![A-Za-z0-9._-])',$matchOptions)
    $familyPattern=[regex]::new('(?<![A-Za-z0-9._-])'+[regex]::Escape($PackageFamilyName)+'(?![A-Za-z0-9._-])',$matchOptions)

    function ConvertTo-ActivationBoundedText {
        param([AllowNull()][object]$Value,[int]$Limit)
        $text=[string]$Value
        [pscustomobject]@{Text=$text.Substring(0,[Math]::Min($Limit,$text.Length));Truncated=$text.Length -gt $Limit}
    }
    function ConvertTo-ActivationReadError {
        param([Management.Automation.ErrorRecord]$Record)
        $cause=$Record.Exception.GetBaseException()
        $message=ConvertTo-ActivationBoundedText -Value $cause.Message -Limit 2048
        # Never serialize ErrorRecord, InvocationInfo, SourceLine or exception Data.
        [pscustomobject]@{Message=$message.Text;MessageTruncated=$message.Truncated;ExceptionType=$cause.GetType().FullName;HResult=$cause.HResult}
    }

    $channelResults=[Collections.Generic.List[object]]::new()
    $partial=$false
    foreach($channel in $channels){
        $channelRecord=[ordered]@{LogName=$channel;Availability='Available';Enabled=$null;EnabledStatus='Unknown';ReadStatus='NotAttempted';EventCount=0;EventLimitReached=$false;IdentityMatchCount=0;TimeWindowContextCount=0;Events=@();Error=$null}
        try{
            $metadata=@(Get-WinEvent -ListLog $channel -ErrorAction Stop|Select-Object -First 2)
            if($metadata.Count -ne 1){throw 'Event channel metadata was missing or ambiguous.'}
            if($metadata[0].IsEnabled -is [bool]){
                $channelRecord.Enabled=$metadata[0].IsEnabled
                $channelRecord.EnabledStatus=if($metadata[0].IsEnabled){'Enabled'}else{'Disabled'}
            }
        }catch{
            $channelRecord.Availability='Unavailable';$channelRecord.Error=ConvertTo-ActivationReadError -Record $_
            $partial=$true;$channelResults.Add([pscustomobject]$channelRecord);continue
        }
        if($channelRecord.Enabled -is [bool] -and -not $channelRecord.Enabled){$channelResults.Add([pscustomobject]$channelRecord);continue}
        try{
            # Get-WinEvent reparses hashtable dates as local clock values in both
            # Windows PowerShell 5.1 and PowerShell 7. Supply local-kind values;
            # UTC-kind values silently shift the intended event window.
            $events=@(Get-WinEvent -FilterHashtable @{LogName=$channel;StartTime=$windowStart.ToLocalTime();EndTime=$collectedUtc.ToLocalTime()} -MaxEvents 32 -ErrorAction Stop|Select-Object -First 32)
            $channelRecord.ReadStatus=if($events.Count){'Completed'}else{'NoEvents'}
            $channelRecord.EventLimitReached=$events.Count -eq 32
        }catch{
            if($_.FullyQualifiedErrorId -match '^NoMatchingEventsFound(?:,|$)'){$channelRecord.ReadStatus='NoEvents'}
            else{$channelRecord.ReadStatus='Failed';$channelRecord.Error=ConvertTo-ActivationReadError -Record $_;$partial=$true}
            $channelResults.Add([pscustomobject]$channelRecord);continue
        }
        $rows=[Collections.Generic.List[object]]::new()
        foreach($eventItem in $events){
            $eventRecord=[ordered]@{Id=$null;RecordId=$null;ProviderName='';TimeCreatedUtc=$null;ActivityId=$null;Level='';Message='';MessageTruncated=$false;Xml='';XmlTruncated=$false;Attribution='TimeWindowContext';IdentityMatches=@();Error=$null}
            try{
                $eventRecord.Id=[int]$eventItem.Id;$eventRecord.RecordId=[long]$eventItem.RecordId
                $eventRecord.ProviderName=(ConvertTo-ActivationBoundedText -Value $eventItem.ProviderName -Limit 256).Text
                $eventRecord.Level=(ConvertTo-ActivationBoundedText -Value $eventItem.LevelDisplayName -Limit 128).Text
                if($eventItem.TimeCreated -is [datetime]){$eventRecord.TimeCreatedUtc=$eventItem.TimeCreated.ToUniversalTime().ToString('o')}
                if($eventItem.ActivityId -is [guid]){$eventRecord.ActivityId=$eventItem.ActivityId.ToString()}
                $message=ConvertTo-ActivationBoundedText -Value $eventItem.Message -Limit 4096
                $eventRecord.Message=$message.Text;$eventRecord.MessageTruncated=$message.Truncated
                $xml=ConvertTo-ActivationBoundedText -Value $eventItem.ToXml() -Limit 8192
                $eventRecord.Xml=$xml.Text;$eventRecord.XmlTruncated=$xml.Truncated
            }catch{$eventRecord.Error=ConvertTo-ActivationReadError -Record $_;$partial=$true}
            # Match only retained text so each classification has visible evidence.
            $matchText=$eventRecord.Message+"`n"+$eventRecord.Xml
            if($fullPattern.IsMatch($matchText)){$eventRecord.IdentityMatches+='PackageFullName'}
            if($familyPattern.IsMatch($matchText)){$eventRecord.IdentityMatches+='PackageFamilyName'}
            if($eventRecord.IdentityMatches.Count){$eventRecord.Attribution='PackageIdentityMatched';$channelRecord.IdentityMatchCount++}
            else{$channelRecord.TimeWindowContextCount++}
            $rows.Add([pscustomobject]$eventRecord)
        }
        $channelRecord.Events=$rows.ToArray();$channelRecord.EventCount=$rows.Count
        $channelResults.Add([pscustomobject]$channelRecord)
    }
    [pscustomobject]@{
        Schema='PowerShellProfile.WindowsActivationDiagnostics.v1'
        Status=if($partial){'Partial'}else{'Completed'}
        PackageFullName=$PackageFullName;PackageFamilyName=$PackageFamilyName
        StartedUtc=$windowStart.ToString('o');CollectedUtc=$collectedUtc.ToString('o')
        QueryDateTimeKind='Local';QueryTimeZone=[TimeZoneInfo]::Local.Id
        Limits=[pscustomobject]@{MaximumWindowMinutes=30;EventsPerChannel=32;MessageCharacters=4096;XmlCharacters=8192;ErrorCharacters=2048}
        Scope='Read-only events in the requested time window. PackageIdentityMatched records contain an exact package identity in retained text; TimeWindowContext records are not attributed to this package.'
        Channels=$channelResults.ToArray()
    }
}
