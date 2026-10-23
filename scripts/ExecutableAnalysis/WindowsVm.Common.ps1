function Invoke-AnalysisWindowsVBox {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ArgumentList,[ValidateRange(1,7200)][int]$TimeoutSeconds=60,[ValidateRange(1024,67108864)][int]$MaxOutputCharacters=1048576)
    $command=Join-Path $env:ProgramFiles 'Oracle/VirtualBox/VBoxManage.exe'
    if(-not(Test-Path -LiteralPath $command -PathType Leaf)){throw 'Oracle VirtualBox is required.'}
    $info=[Diagnostics.ProcessStartInfo]::new($command)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in $ArgumentList){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    try {
        if(-not $process.Start()){throw 'VirtualBox did not start.'}
        $started=$true
        $buffers=@([char[]]::new(8192),[char[]]::new(8192));$readers=@($process.StandardOutput,$process.StandardError)
        $texts=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new());$ended=@($false,$false)
        $pending=@($readers[0].ReadAsync($buffers[0],0,8192),$readers[1].ReadAsync($buffers[1],0,8192))
        $timer=[Diagnostics.Stopwatch]::StartNew();$characters=0
        while(-not($ended[0] -and $ended[1] -and $process.HasExited)){
            if($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds){throw 'VirtualBox command timed out.'}
            foreach($index in 0..1){
                if($ended[$index] -or -not $pending[$index].IsCompleted){continue}
                $count=$pending[$index].GetAwaiter().GetResult()
                if($count -eq 0){$ended[$index]=$true;continue}
                $characters+=$count
                if($characters -gt $MaxOutputCharacters){throw 'VirtualBox output exceeded its bounded capture limit.'}
                $null=$texts[$index].Append($buffers[$index],0,$count)
                $pending[$index]=$readers[$index].ReadAsync($buffers[$index],0,8192)
            }
            Start-Sleep -Milliseconds 10
        }
        $text=$texts[0].ToString();$errorText=$texts[1].ToString()
        if($process.ExitCode -ne 0){throw "VirtualBox failed ($($process.ExitCode)): $($errorText.Trim())"}
        $text.Replace("`r`n","`n")
    } finally {if($started -and -not $process.HasExited){$process.Kill($true);$null=$process.WaitForExit(5000)};$process.Dispose()}
}

function ConvertFrom-AnalysisWindowsVmInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $settings=@{}
    foreach($line in ($Text -split '\r?\n')) {
        if($line -match '^([^=]+)="(.*)"$'){$settings[$Matches[1].Trim('"')]=$Matches[2]}
        elseif($line -match '^([^=]+)=([0-9]+)$'){$settings[$Matches[1].Trim('"')]=$Matches[2]}
    }
    $settings
}

function Enter-AnalysisWindowsVmLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StoragePath)
    $path=Join-Path $StoragePath 'runtime.lock'
    if(Test-Path -LiteralPath $path){
        if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The Windows VM lock must be a regular file.'}
    }
    try{[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch{throw 'This Windows analysis VM is busy or its exclusive lock is unavailable. No VM state was changed.'}
}

function Assert-AnalysisWindowsVmIsolation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings,[Parameter(Mandatory)]$Manifest)
    if($Manifest.Schema -ne 'PowerShellProfile.AnalysisWindowsVm.v1' -or $Manifest.GuestOS -ne 'Windows 11 x64'){throw 'The manifest does not identify an owned Windows analysis VM.'}
    if($Settings.UUID -ne $Manifest.VirtualMachineId -or $Settings.name -ne $Manifest.VirtualMachineName){throw 'VM name or UUID differs from its ownership manifest.'}
    foreach($index in 1..8){if($Settings["nic$index"] -ne 'none'){throw "Isolation failed: NIC $index is enabled or unknown."}}
    foreach($key in @('usb','ehci','xhci','vrde','audio_in','audio_out','nested-hw-virt','teleporterenabled')){if($Settings[$key] -ne 'off'){throw "Isolation failed: $key is enabled or unknown."}}
    foreach($key in @('clipboard','draganddrop')){if($Settings[$key] -ne 'disabled'){throw "Isolation failed: $key is enabled or unknown."}}
    if($Settings.clipboard_file_transfers -ne 'off'){throw 'Isolation failed: clipboard file transfers are enabled or unknown.'}
    foreach($index in 1..4){if($Settings["uart$index"] -ne 'off'){throw "Isolation failed: UART $index is enabled or unknown."}}
    if(@($Settings.Keys|Where-Object {$_ -like 'SharedFolder*'}).Count){throw 'Isolation failed: a shared folder exists.'}
    $owned=[IO.Path]::GetFullPath($Manifest.StoragePath).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    foreach($key in @($Settings.Keys|Where-Object {$_ -match '^.+-\d+-\d+$' -and $_ -notmatch '-(ImageUUID|hot-pluggable|nonrotational|discard|tempeject|IsEjected)-'})) {
        $medium=$Settings[$key].Replace('\\','\')
        if($medium -in 'none','emptydrive'){continue}
        if(-not[IO.Path]::GetFullPath($medium).StartsWith($owned,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($medium) -ne '.vdi'){throw 'Isolation failed: a disk or removable medium is not an owned VDI.'}
    }
}

function Protect-AnalysisWindowsPrivatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)
    $acl=Get-Acl -LiteralPath $LiteralPath
    $item=Get-Item -LiteralPath $LiteralPath
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Private VM storage cannot be a reparse point.'}
    $acl.SetAccessRuleProtection($true,$false)
    foreach($rule in @($acl.Access)){$null=$acl.RemoveAccessRuleSpecific($rule)}
    foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule=if($item.PSIsContainer){[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')}else{[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow')}
        $acl.AddAccessRule($rule)
    }
    if($item.PSIsContainer){[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($LiteralPath),$acl)}
    else{[IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($LiteralPath),$acl)}
}

function ConvertTo-AnalysisWindowsSecureString {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword','',Justification='Accepts only a transient cryptographically generated bootstrap value required by VirtualBox unattended provisioning; never logs it or passes it as a process argument.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GeneratedPassword)
    $secure=[Security.SecureString]::new()
    foreach($character in $GeneratedPassword.ToCharArray()){$secure.AppendChar($character)}
    $secure.MakeReadOnly()
    $secure
}

function Test-AnalysisWindowsPe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)
    $stream=[IO.File]::OpenRead($LiteralPath)
    try {
        $header=[byte[]]::new(64)
        if($stream.Read($header,0,64) -ne 64 -or $header[0] -ne 0x4d -or $header[1] -ne 0x5a){return $false}
        $offset=[BitConverter]::ToUInt32($header,60)
        if($offset -gt $stream.Length-24){return $false}
        $stream.Position=$offset
        $pe=[byte[]]::new(24)
        if($stream.Read($pe,0,24) -ne 24 -or [BitConverter]::ToUInt32($pe,0) -ne 0x4550){return $false}
        $machine=[BitConverter]::ToUInt16($pe,4)
        $flags=[BitConverter]::ToUInt16($pe,22)
        # DLLs and nonexecutable COFF objects need an explicit harness, not direct launch.
        return $machine -in 0x14c,0x8664 -and ($flags -band 2) -ne 0 -and ($flags -band 0x2000) -eq 0
    } finally {$stream.Dispose()}
}
