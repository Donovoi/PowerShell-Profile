function Get-RemoteMFT {

    <#

        .SYNOPSIS

        Extracts Master File Table from volume from a remote host without writing to the 
        remote host's disk. 
        
        .DESCRIPTION

        This module reads the Master File Table from a remote host and streams it to a local 
        path on the workstation the script is ran from.

        .PARAMETER ComputerName 

        Specify host to retrieve the Master File Table from.

        .PARAMETER Volume 

        Specify a volume to retrieve its master file table.

        .PARAMETER FirewallRuleName

        Speficy the name of the FirewallRuleName to use when opening a firewall port.

        .PARAMETER LPort

        Specify a local port to listen on to receive the MFT file transfer.

        .EXAMPLE

        The following example extracts the master file table from a remote workstation, 
        connects back to this script's workstation and streams the file on port 7777. If an 
        LPort is not secified, port 2998 is used by default.

        PS C:\> Get-RemoteMFT -ComputerName <computer_name> -OutputFilePath "C:\mft.bin" -FirewallRuleName "MFT File Transfer" -Port 7777

        .NOTES

        This script is a heavily modified version + wrapper for Jesse Davis's Export-MFT 
        (https://gist.github.com/secabstraction/4044f4aadd3ef21f0ca9).  It will parse the MFT 
        and send it over the network to prevent any writes to disk. The MFT location isn't 
        always fixed on the volume. You should get the starting MFT offset from the boot 
        sector (sector 0 of the volume, you can find the structure online). The first file 
        in the MFT is the "$MFT" file which is the file record for the entire MFT itself. 
        You can parse the attributes of this file like any other file and get it's data run
        list. When you know the size of each fragment in clusters, parse the last cluster 
        for each 1024 byte record of the last fragment (although I believe a fragmented MFT
        is rare). The last record in the MFT is the last record in that particular cluster 
        marked "FILE0", if you encounter a null magic number that would be 1024 bytes too far.
        Or you can just get the file size from it's attributes and calculate the offset to 
        the end of the MFT based on how many fragments it has. Then subtract 1024 from the 
        offset and you should be looking at the last file.
              
        Author : Matt Pichelmayer
        License: BSD 3-Clause
        
        MFT Parsing:
        Source: https://gist.github.com/secabstraction/4044f4aadd3ef21f0ca9
        Author : Jesse Davis (@secabstraction)
        License: BSD 3-Clause

        .LINK

        https://github.com/picheljitsu/Powershell/edit/master/Forensics/Get-RemoteMFT.ps1
        
    #>

    [CmdLetBinding()]
    Param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [String[]]$ComputerName,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [Char]$Volume = 0,           
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [Int]$LPort = 2998, 
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [Int]$Timeout = 30,                
        [Parameter()]
        [string]$OutputFilePath = "$($pwd.Path)\$($Computername)_MFT.bin",
        [Parameter()]
        [String]$FirewallRuleName = "MFT XFER"
    )

    #Enable verbosity by default
    $VerbosePreference = 'Continue'

    $OrginalFileName = (Split-Path $OutputFilePath -Leaf)
    $OutputFilePath = Join-Path (Split-Path $OutputFilePath | Resolve-Path ) (Split-Path $OutputFilePath -Leaf) -ErrorAction Stop
    
    if ($(Test-Path $OutputFilePath)) {
        $date = $(Get-Date -f { yyyy-MMMM-dd-hhmmss })
        $OutputFilePath = $OutputFilePath.Replace(".bin", "$date.bin") 
        Write-Verbose "[+] File $OrginalFileName exists. MFT will be written to  $(Split-Path $OutputFilePath -Leaf)" 

    }

    #Scriptblock to start a tcp server that will be forked into a seperate
    $ListenerBlock = {
 
        param($Lport, $OutputFilePath, $ListenerStatus)
     
        #Used to encode the MFT size message received from client
        $Encoder = [System.Text.Encoding]

        #Start TCP SERVER
        $Tcplistener = New-Object System.Net.Sockets.TcpListener $Lport
        $ListenerStatus.State = "Started"

        $Tcplistener.Start()
        $TcpClient = $Tcplistener.AcceptTcpClient()
        $ListenerStatus.State = "Connect"        

        $ListenerStatus.RemoteHost = $TcpClient.Client.RemoteEndPoint.Address.IPAddressToString
        $TcpNetworkstream = $TCPClient.GetStream()
        $MFTSizeMsg = New-Object Byte[] 0x20
        $Receivebuffer = New-Object Byte[] $TcpClient.ReceiveBufferSize
        
        if ($TcpClient.Connected) { 

            #Let the main powershell session know we're waiting on the MFT size message
            $ListenerStatus.State = "Wait"   
 
            #Waiting for the MFT size message
            do {
                $GetMFTSize = $TcpNetworkstream.Read($MFTSizeMsg, 0, $MFTSizeMsg.Length)

            }until($GetMFTSize -ne '' -OR $ListenerStatus.disconnect -eq $true )

            #Give the MFT size to the main session
            $DecodeMSG = $Encoder::ASCII.GetString($MFTSizeMsg)
            $ListenerStatus.MFTSize = $DecodeMSG

            #Let the main powershell session know the message was received
            $ListenerStatus.MessageReceived = $true
          
            #Flushout the Network stream in preparation for receipt of MFT data
            $TcpNetworkstream.flush()  

            #Let the main powershell session know we're ready to start receiving the MFT
            $ListenerStatus.State = "Receive"  

            #Open the destination file where bytes received over the network will be written
            $OutputFileStream = New-Object IO.FileStream $OutputFilePath , 'Append', 'Write', 'Read'       

            #Loop until all bytes are received
            do {
                $Read = $TcpNetworkstream.Read($Receivebuffer, 0, $Receivebuffer.Length)
        
                if ($Read -eq 0) {
                    break 
                } 
                else {     
        
                    [Array]$Bytesreceived += $Receivebuffer[0..($Read - 1)]
                    [Array]::Clear($Receivebuffer, 0, $Read)
                    $OutputFileStream.Write($Bytesreceived, 0, $Bytesreceived.Length) 
                    $TcpNetworkstream.Flush()  
                    $ListenerStatus.BytesReceived += $Bytesreceived.Length
                    $Bytesreceived = $null                    
        
                }

            }until($ListenerStatus.BytesReceived -eq $MFTSizeMsg -or (!$TcpClient.Connected))

            Start-Sleep 1
            $OutputFileStream.Close()            
            $TcpNetworkstream.Dispose()
            $ListenerStatus.State = "Done"   
            $Tcplistener.Stop()

        }

        else {
            $ListenerStatus.State = "Failed" 
        }    
                      
        $ListenerStatus.disconnect = $true

    } #End Listener Block
       
    ################# Scriptblock to dump MFT on Remote host #################

    $MFTScriptBlock = {  

        Param($Listener, $Volume, $Lport)

        if ($Volume -ne 0) { 

            $Win32_Volume = Get-WmiObject -Class Win32_Volume -Filter "DriveLetter LIKE '$($Volume):'"

            if ($Win32_Volume.FileSystem -ne "NTFS") { 

                Write-Error "$Volume is not an NTFS filesystem."
                break
            }
        }

        else {

            $Win32_Volume = Get-WmiObject -Class Win32_Volume -Filter "DriveLetter LIKE '$($env:SystemDrive)'"

            if ($Win32_Volume.FileSystem -ne "NTFS") { 

                Write-Error "$env:SystemDrive is not an NTFS filesystem."
                break
            }
        }
    
        #region WinAPI
        $GENERIC_READWRITE = 0x80000000
        $FILE_SHARE_READWRITE = 0x02 -bor 0x01
        $OPEN_EXISTING = 0x03
    
        $DynAssembly = New-Object System.Reflection.AssemblyName('MFT')
        $AssemblyBuilder = [AppDomain]::CurrentDomain.DefineDynamicAssembly($DynAssembly, [Reflection.Emit.AssemblyBuilderAccess]::Run)
        $ModuleBuilder = $AssemblyBuilder.DefineDynamicModule('InMemory', $false)
    
        $TypeBuilder = $ModuleBuilder.DefineType('kernel32', 'Public, Class')
        $DllImportConstructor = [Runtime.InteropServices.DllImportAttribute].GetConstructor(@([String]))
        $SetLastError = [Runtime.InteropServices.DllImportAttribute].GetField('SetLastError')
        $SetLastErrorCustomAttribute = New-Object Reflection.Emit.CustomAttributeBuilder($DllImportConstructor,
            @('kernel32.dll'),
            [Reflection.FieldInfo[]]@($SetLastError),
            @($True))
    
        #CreateFile
        $PInvokeMethodBuilder = $TypeBuilder.DefinePInvokeMethod('CreateFile', 'kernel32.dll',
            ([Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::Static),
            [Reflection.CallingConventions]::Standard,
            [IntPtr],
            [Type[]]@([String], [Int32], [UInt32], [IntPtr], [UInt32], [UInt32], [IntPtr]),
            [Runtime.InteropServices.CallingConvention]::Winapi,
            [Runtime.InteropServices.CharSet]::Ansi)

        $PInvokeMethodBuilder.SetCustomAttribute($SetLastErrorCustomAttribute)
    
        #CloseHandle
        $PInvokeMethodBuilder = $TypeBuilder.DefinePInvokeMethod('CloseHandle', 'kernel32.dll',
            ([Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::Static),
            [Reflection.CallingConventions]::Standard,
            [Bool],
            [Type[]]@([IntPtr]),
            [Runtime.InteropServices.CallingConvention]::Winapi,
            [Runtime.InteropServices.CharSet]::Auto)

        $PInvokeMethodBuilder.SetCustomAttribute($SetLastErrorCustomAttribute)
    
        $Kernel32 = $TypeBuilder.CreateType()
    
        #endregion WinAPI
    
        #Get handle to volume
        if ($Volume -ne 0) {
         
            $VolumeHandle = $Kernel32::CreateFile(('\\.\' + $Volume + ':'), $GENERIC_READWRITE, $FILE_SHARE_READWRITE, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero) 

        }

        else { 
            $VolumeHandle = $Kernel32::CreateFile(('\\.\' + $env:SystemDrive), $GENERIC_READWRITE, $FILE_SHARE_READWRITE, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero) 
            $Volume = ($env:SystemDrive).TrimEnd(':')
        }
        
        if ($VolumeHandle -eq -1) { 
            Write-Error "Unable to obtain read handle for volume."
            break 
        }         
        
        # Create a FileStream to read from the volume handle
        $FileStream = New-Object IO.FileStream($VolumeHandle, [IO.FileAccess]::Read)                   
    
        # Read VBR from volume
        $VolumeBootRecord = New-Object Byte[](512)                                                     
        if ($FileStream.Read($VolumeBootRecord, 0, $VolumeBootRecord.Length) -ne 512) {
            Write-Error "Error reading volume boot record." 
        }
    
        # Parse MFT offset from VBR and set stream to its location
        $MftOffset = [Bitconverter]::ToInt32($VolumeBootRecord[0x30..0x37], 0) * 0x1000
        $FileStream.Position = $MftOffset
    
        # Read MFT's file record header
        $MftFileRecordHeader = New-Object byte[](48)
        if ($FileStream.Read($MftFileRecordHeader, 0, $MftFileRecordHeader.Length) -ne $MftFileRecordHeader.Length) {
            Write-Error "Error reading MFT file record header." 
        }
    
        # Parse values from MFT's file record header
        $OffsetToAttributes = [Bitconverter]::ToInt16($MftFileRecordHeader[0x14..0x15], 0)
        $AttributesRealSize = [Bitconverter]::ToInt32($MftFileRecordHeader[0x18..0x21], 0)
    
        # Read MFT's full file record
        $MftFileRecord = New-Object byte[]($AttributesRealSize)
        $FileStream.Position = $MftOffset
        if ($FileStream.Read($MftFileRecord, 0, $MftFileRecord.Length) -ne $AttributesRealSize) {
            Write-Error "Error reading MFT file record." 
        }
        
        # Parse MFT's attributes from file record
        $Attributes = New-Object byte[]($AttributesRealSize - $OffsetToAttributes)
        [Array]::Copy($MftFileRecord, $OffsetToAttributes, $Attributes, 0, $Attributes.Length)
        
        # Find Data attribute
        $CurrentOffset = 0

        do {

            $AttributeType = [Bitconverter]::ToInt32($Attributes[$CurrentOffset..$($CurrentOffset + 3)], 0)
            $AttributeSize = [Bitconverter]::ToInt32($Attributes[$($CurrentOffset + 4)..$($CurrentOffset + 7)], 0)
            $CurrentOffset += $AttributeSize

        } until ($AttributeType -eq 128)
        
        # Parse data attribute from all attributes
        $DataAttribute = $Attributes[$($CurrentOffset - $AttributeSize)..$($CurrentOffset - 1)]
    
        # Parse MFT size from data attribute
        
        $MftSize = [Bitconverter]::ToUInt64($DataAttribute[0x30..0x37], 0)

        # Parse data runs from data attribute
        $OffsetToDataRuns = [Bitconverter]::ToInt16($DataAttribute[0x20..0x21], 0)        
        $DataRuns = $DataAttribute[$OffsetToDataRuns..$($DataAttribute.Length - 1)]
        
        # Convert data run info to string[] for calculations
        $DataRunStrings = ([Bitconverter]::ToString($DataRuns)).Split('-')
        
        # Setup to read MFT
        $FileStreamOffset = 0
        $DataRunStringsOffset = 0        
        $TotalBytesWritten = 0
        $MftData = New-Object byte[](0x1000)
        [array]$SendBuffer = @()

        # Connect Back to calling host to send MFT
        $Tcpclient = New-Object System.Net.Sockets.TcpClient
        $Tcpclient.sendbuffersize = 16384
        $Listenerip = (([System.Net.Dns]::GetHostAddresses($Listener))[0]).IPAddressToString

        try {
            $Tcpclient.Connect($Listenerip, $lport)
            $TcpNetworkStream = $Tcpclient.GetStream()

            $MftMsg = ($MftSize.ToString()).PadRight(20, " ")

            #Send the MFT size first
            $Encoder = [System.Text.ASCIIEncoding]
            $EncodedMSG = $Encoder::ASCII.GetBytes($MftMsg)

            $TcpNetworkStream.write($EncodedMSG, 0 , $MftMsg.length)
            $TcpNetworkStream.Flush()
 
            #Get-RemoteMFT -ComputerName L6011577
            Start-Sleep 1

            do {
                $StartBytes = [int]($DataRunStrings[$DataRunStringsOffset][0]).ToString()
                $LengthBytes = [int]($DataRunStrings[$DataRunStringsOffset][1]).ToString()
                $DataRunStart = "0x"
                $DataRunLength = "0x"
             
                for ($i = $StartBytes; $i -gt 0; $i--) {
                    $DataRunStart += $DataRunStrings[($DataRunStringsOffset + $LengthBytes + $i)] 
                }            
             
                for ($i = $LengthBytes; $i -gt 0; $i--) {
                    $DataRunLength += $DataRunStrings[($DataRunStringsOffset + $i)] 
                }
             
                $FileStreamOffset += ([int]$DataRunStart * 0x1000)
                $FileStream.Position = $FileStreamOffset   
                  
                for ($i = 1; $i -lt [int]$DataRunLength + 1; $i++) {
             
                    $readlen = $FileStream.Read($MftData, 0, $MftData.Length)
                    [array]$SendBuffer += $MftData[0..($readlen - 1)]
             
             
                    if ( $readlen -ne $MftData.Length) { 
             
                        Write-Warning "Possible error reading MFT data on $env:COMPUTERNAME." 
             
                    }
             
                    #Logic to only write to stream only if buffer is full (16384) 
                    #or not divisble by 4096, meaning it's the last write
                    switch ($Sendbuffer.length) {
             
                        16384 {
                            $TcpNetworkstream.write($Sendbuffer, 0, $Sendbuffer.Length)
                            $TcpNetworkstream.flush()
                            $SendBuffer = $null 
                        }
             
                        { ![math]::Equals(($_ % 4092), 0) } { 
             
                            $TcpNetworkstream.write($Sendbuffer, 0, $Sendbuffer.Length)
                            $TcpNetworkstream.flush()
                            $SendBuffer = $null 
                        }
             
                        default {
                            continue 
                        }
             
                    }
             
                    $TotalBytesWritten += $MftData.Length  
             
                }
             
                $DataRunStringsOffset += $StartBytes + $LengthBytes + 1
             
            } until ($TotalBytesWritten -eq $MftSize)

            ###Shutdown the connection
            $TcpNetworkstream.Dispose()
            $Tcpclient.Close()

            wait 3

            #On success return the MFT's size
            $MftSize

        }

        catch {
            0 
        }
        
    }

    ################# Set Firewall Rule #################

    #Set up a local firewall rule for the listening port so the MFT can be sent inbound
    netsh advfirewall firewall delete rule name=$FirewallRuleName | Out-Null
    netsh advfirewall firewall add rule name=$FirewallRuleName dir=in action=allow protocol=TCP localport=$lport | Out-Null

    Write-Verbose "[+] Added Firewall rule `"$FirewallRuleName`" for port $LPort" 

    ################# Runspace Setup #################
    
    $Listener = $env:COMPUTERNAME
    
    #Synchronized Hashtables to grab the status of the file transfer between the main Powershell 
    #session and the runspaces
    $ListenerStatus = [hashtable]::Synchronized(@{ "State" = "Stopped"
            "RemoteHost"                                   = ''
            "MessageReceived"                              = $false
            "MFTSize"                                      = 0
            "Disconnect"                                   = $false
            "BytesReceived"                                = 0 
            "Client"                                       = '' 
        })

    $ClientStatus = [hashtable]::Synchronized(@{ "Failed" = $false 
            "MFTSize"                                     = 0 
            "State"                                       = "Unavailable" 
        }) 
    
    Write-Verbose "[*] Initializing Client and Server Runspaces..."

    #Create the runspace environments for listener and client
    $Listenerrunspace = [RunspaceFactory]::CreateRunspace()
    $Clientrunspace = [RunspaceFactory]::CreateRunspace()
    $ListenerRunspace.Open()
    $ClientRunspace.Open()

    #Push the sync'd hashtables into the Client/Server runspaces
    $ClientRunspace.SessionStateProxy.SetVariable('ClientStatus', $ClientStatus)
    $ListenerRunspace.SessionStateProxy.SetVariable('ListenerStatus', $ListenerStatus)    

    #Create the Runspaces
    $PowershellListener = [PowerShell]::Create()
    $PowershellClient = [PowerShell]::Create()

    #Set the environment on each to the objects created
    $PowershellClient.runspace = $Clientrunspace
    $PowershellListener.runspace = $Listenerrunspace

    Write-Verbose "[+] Runspaces Open"
    Start-Sleep 1

    #Build parameters and commands to push into each runspace
    $ListenerParamList = @{ "Lport" = $Lport
        "OutputFilePath"            = $OutputFilePath
        "ListenerStatus"            = $ListenerStatus 
    }

    $MFTArgument = [scriptblock]::Create($MFTScriptBlock)
    $MFTParamList = @{ "ComputerName" = $ComputerName
        "Listener"                    = $Listener
        "Volume"                      = $Volume
        "LPort"                       = $Lport 
        "MFTScriptBlock"              = $MFTArgument 
    }
    
    $GetMFTScript = { param($ComputerName, $Listener, $Volume, $Lport, $MFTScriptBlock)
        $remote_pssession = New-PSSession -ComputerName $ComputerName -SessionOption (New-PSSessionOption -NoMachineProfile) -ErrorAction Stop
        Start-Sleep .5

        #Check to see if the session succeeded.  The New-PSSession object's availability property indicates the session succeeded
        #If it didn't succeed, the issue could be that 1) authentication failed to the remote workstation or 2) there are too many
        #remote sessions running
        $ClientStatus.State = $remote_pssession.Availability 

        #Start the MFT parsing and sending
        try {
            $ClientStatus.MFTsize = Invoke-Command -Session $remote_pssession `
                -ScriptBlock $MFTScriptBlock `
                -ArgumentList @($Listener, $Volume, $LPort) 
        }

        catch {
            $ClientStatus.Failed = $true
            $ClientStatus.MFTsize = 0 
        } 

        Remove-PSSession $remote_pssession }
    
    Write-Verbose "[*] Sending Processes to Runspaces..."

    [void]$PowershellListener.AddScript($ListenerBlock).AddParameters($ListenerParamList)
    [void]$PowershellClient.AddScript($GetMFTScript).AddParameters($MFTParamList)
  
    ################# Listener Start Section #################
    
    #These are used to control verbose messages while looping
    $Started = $false
    $Waiting = $false
    $Receive = $false
    $Connect = $false

    $timeoutCounter = 0

    #Switch for overall script execution. No failures are terminal since runspace disposal will
    #need to occur regardless.
    $Failed = $false
    $Completed = $false

    Write-Verbose "[*] Starting Listener Runspace..."

    #Invoke the Listener runspace and start the TCP Server
    try {
        $PowershellListener.begininvoke() | Out-Null 
    }

    catch {
        $Failed = $true 
    }

    Start-Sleep 1

    #Start the Listener in it's runspace and wait for it to return a status
    do {
        $msg = ''
        switch ($ListenerStatus.State) {

            "Stopped" {
                $timeoutCounter += 1
                Start-Sleep 1
                break 
            }

            "Started" {
                if (!$started) {
                    $msg = "[+] Started Listener on port $Lport" 
                }   
                #Makes sure the message is only sent to the console once
                $Started = $true
                break 
            } 

            "Failed" {
                $msg = "[-] Failed to start server."
                $failed = $true
                break 
            } 
        }
        
        #Write the status to the console
        if ($timeoutCounter -eq $Timeout) { 
    
            $msg = "[-] Timeout reached. Failed to start the Listener." 
            $Failed = $true 
            
        }
    

    }until($Started -or $Failed)

    Write-Verbose $msg

    #Start the client runspace and attempt to set up the remote PS Session
    Write-Verbose "[*] Starting Client Runspace..."

    try {
        $PowershellClient.BeginInvoke() | Out-Null 
    }

    catch {
        $Failed = $True
        $Msg = "[-] Failed to start the client. Exiting." 
    }

    #Wait on the Client Runspace to establish a Remote PSSession with the target
    do { 
        Start-Sleep 1
        
        if ($ClientStatus.State -eq "Available") {
            break 
        }
 
        $timeoutCounter += 1
 
        if ($timeoutCounter -ge $Timeout) { 
            
            $Failed = $True 
            Write-Verbose "[-] Failed to create session on remote client."
            
        }
            

    }while (!$Failed)
       
    #Read the listener's status while it waits for a connection and receives data
    do {

        $msg = ''
        switch ($ListenerStatus.State) {
            
            "Connect" {
                if (-not $Connect) {
                    $msg = "[+] Received connection from  $($ListenerStatus.RemoteHost)." 
                }
                $Connect = $true
                $timeoutCounter += 1
                break 
            }

            "Wait" {
                if (-not $waiting) {
                    $msg = "[*] Getting MFT size." 
                }   
                $Waiting = $true
                $timeoutCounter += 1
                break 
            }

            "Receive" {
                $scriptTime = [Diagnostics.Stopwatch]::StartNew()
                $msg = "[+] Execution Start time: $(Get-Date -Format t)"
                $Receive = $true
                break 
            } 
        }
        
        Start-Sleep 1

        if ($timeoutCounter -eq $Timeout) {
            $Failed = $true
            $Msg = "[-] Timeout reached. Failed to start the Client."  
        }
        if ($msg) {
            Write-Verbose $msg
        }

        if ($Receive) {
            break 
        }

    }while (!$Failed)

    if ($Receive) { 

        $MFTByteSize = [int]$ListenerStatus.MFTsize    
        $msg = "[*] Receiving MFT size of $MFTByteSize ($($MFTByteSize / 1024 / 1024) MBs). Writing to $OutputFilePath" 
        
    }

    elseif ($ClientStatus.Failed) { 

        $failed = $true            
        $msg = "[-] Client runspace failed to initiate MFT collection" 
                    
    }

    Write-Verbose $msg

    ################# Receive until MFT size is received or timeout is reached #################

    if ($Receive -and !$Failed) { 

        Write-Progress -Verbose -Activity "Collecting MFT" -Status "Transfering..." -PercentComplete 0
        $bytePercentage = .1
        do {
                             
            #Calculate the current percentage of bytes received
            $percentage = $MFTByteSize * $bytePercentage

            switch ($ListenerStatus.BytesReceived) {
                
                #We reached a 10% checkpoint, increment to the next 10%
                { $_ -ge $percentage } {
                    Write-Progress -Verbose -Activity "Collecting MFT" `
                        -Status "Transfering.." `
                        -PercentComplete ($bytePercentage * 100 )

                                        
                    $bytePercentage += .1
                    $LastCount = $ListenerStatus.BytesReceived
                    break 
                }
                #If the current byte count equals the last byte count, the connection may be stalled
                { $_ -eq $LastCount } {
                    $TimeoutCounter += 1 
                } 
            }

            Start-Sleep 1

            if ($TimeoutCounter -eq $Timeout) {
                $Failed = $True 
            }

        }until(($ListenerStatus.BytesReceived -eq $MFTByteSize) -OR ($failed))
            
        if ($ListenerStatus.BytesReceived -eq $MFTByteSize) { 
            
            $ScriptTime.Stop()        
            $msg = "[+] Done, execution time: $($ScriptTime.Elapsed)" 
            
        }

        elseif ($timeout -eq $ServerTimeout) {
            $msg = "[-] Server reached the timeout limit. Exiting." 
        }

        else {
            $msg = "[-] Unknown error. " 
        }

        Write-Verbose $msg

        #Send signal to listener to close the port before disposing of the runspaces
        $ListenerStatus.disconnect = $true

    }

    ################# Stop Runspaces #################           

    Write-Verbose "[*] Ending..."
    netsh advfirewall firewall delete rule name=$FirewallRuleName | Out-Null
    Write-Verbose "[+] Firewall rule removed"      
    Write-Verbose "[*] Removing Runspaces..."

    Start-Sleep 1
    #Closeout listener
    $Listenerrunspace.Close()
    $Listenerrunspace.Dispose()
    $PowershellListener.Stop()
    $PowershellListener.Dispose()
    Write-Verbose "[+] Stopped Listener Runspace"
  
    #Closeout client
    $PowershellClient.Stop()
    $PowershellClient.Dispose()
    $Clientrunspace.Close()
    $Clientrunspace.Dispose()
    Write-Verbose "[+] Stopped Client Runspace"
    [GC]::Collect()

    $md5hash = (Get-FileHash -Algorithm MD5 $OutputFilePath).hash
    Write-Verbose "[+] MD5 hash: $md5hash"

}
    
