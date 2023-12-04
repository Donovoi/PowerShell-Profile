function Get-MFT {

  <#
    .SYNOPSIS

    Extracts master file table from volume.

    Version: 0.1
    Author : Jesse Davis (@secabstraction)
    License: BSD 3-Clause

    Version: 0.1
    Author : Matt Pichelmayer
    License: BSD 3-Clause

    .DESCRIPTION
    This module reads the Master File Table from a remote host and streams it to a local path on the workstation the script is ran from.
    .PARAMETER ComputerName
    Specify host to retrieve the Master File Table from.
    .PARAMETER Volume
    Specify a volume to retrieve its master file table.
    .PARAMETER FirewallRuleName
    Speficy the name of the FirewallRuleName to use when opening a firewall port.
    .PARAMETER LPort
    Specify a local port to listen on to receive the MFT file transfer.
    .EXAMPLE
    The following example extracts the master file table from a remote workstation, connects back to this script's workstation and streams the file on port 7777. If an LPort
    is not secified, port 2998 is used by default.
    PS C:\> Get-RemoteMFT -ComputerName <computer_name> -OutputFilePath "C:\mft.bin" -FirewallRuleName "MFT File Transfer" -Port 7777
    .NOTES
    This script is a slightly modified version + wrapper for Jesse Davis's Export-MFT (https://gist.github.com/secabstraction/4044f4aadd3ef21f0ca9).  It will parse the MFT and
    send it over the network to prevent any writes to disk.
    The MFT location isn't always fixed on the volume. You should get the starting MFT offset from the boot sector (sector 0 of the volume, you can find the structure online).
    The first file in the MFT is the "$MFT" file which is the file record for the entire MFT itself. You can parse the attributes of this file like any other file and get it's
    data run list. When you know the size of each fragment in clusters, parse the last cluster for each 1024 byte record of the last fragment (although I believe a fragmented
    MFT is rare). The last record in the MFT is the last record in that particular cluster marked "FILE0", if you encounter a null magic number that would be 1024 bytes too far.
    Or you can just get the file size from it's attributes and calculate the offset to the end of the MFT based on how many fragments it has. Then subtract 1024 from the offset
    and you should be looking at the last file.

    .INPUTS
    .OUTPUTS
    .LINK
    Export-MFT: https://gist.github.com/secabstraction/4044f4aadd3ef21f0ca9
    Get-RemoteMFT: https://github.com/picheljitsu/Powershell/blob/master/Forensics/Get-RemoteMFT.ps1
    #>

  [CmdletBinding()]
  param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [String[]]$ComputerName,
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [char]$Volume = 0,
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [int]$LPort = 2998,
    [Parameter()]
    [string]$OutputFilePath = "$($pwd.Path)\$($Computername)_MFT.bin",
    [Parameter()]
    [string]$FirewallRuleName = "MFT XFER $lport",
    [Parameter()]
    [switch]$Localonly = $false

  )

  #Enable verbosity by default
  $VerbosePreference = 'Continue'

  # if localonly is specified, then we don't need to do any network stuff and can just run the script locally
  if ($LocalOnly) {

    Write-Verbose "[*] Running locally..."
    $ComputerName = $env:COMPUTERNAME
    $OutputFilePath = Join-Path (Split-Path $OutputFilePath | Resolve-Path) (Split-Path $OutputFilePath -Leaf) -ErrorAction Stop
    $OutputFileStream = New-Object IO.FileStream $OutputFilePath, 'Append', 'Write', 'Read'


    if ($Volume -ne 0) {

      $Win32_Volume = Get-CimInstance -Namespace "root\cimv2" -ClassName "Win32_Volume" -Filter "DriveLetter = '$($Volume):'"

      if ($Win32_Volume.FileSystem -ne "NTFS") {

        Write-Error "$Volume is not an NTFS filesystem."
        break
      }
    }

    else {

      $Win32_Volume = Get-CimInstance -Class Win32_Volume -Filter "DriveLetter LIKE $($env:SystemDrive)"

      if ($Win32_Volume.FileSystem -ne "NTFS") {

        Write-Error "$env:SystemDrive is not an NTFS filesystem."
        break
      }
    }

    #region WinAPI
    $GENERIC_READWRITE = 0x80000000
    $FILE_SHARE_READWRITE = 0x02 -bor 0x01
    $OPEN_EXISTING = 0x03

    $DynAssembly = New-Object System.Reflection.AssemblyName ('MFT')
    $AssemblyBuilder = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($DynAssembly, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $ModuleBuilder = $AssemblyBuilder.DefineDynamicModule('InMemory')

    $TypeBuilder = $ModuleBuilder.DefineType('kernel32', 'Public, Class')
    $DllImportConstructor = [Runtime.InteropServices.DllImportAttribute].GetConstructor(@([string]))
    $SetLastError = [Runtime.InteropServices.DllImportAttribute].GetField('SetLastError')
    $SetLastErrorCustomAttribute = New-Object Reflection.Emit.CustomAttributeBuilder ($DllImportConstructor,
      @('kernel32.dll'),
      [Reflection.FieldInfo[]]@($SetLastError),
      @($True))

    #CreateFile
    $PInvokeMethodBuilder = $TypeBuilder.DefinePInvokeMethod('CreateFile', 'kernel32.dll',
      ([Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::Static),
      [Reflection.CallingConventions]::Standard,
      [IntPtr],
      [Type[]]@([string], [int32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr]),
      [Runtime.InteropServices.CallingConvention]::Winapi,
      [Runtime.InteropServices.CharSet]::Ansi)

    $PInvokeMethodBuilder.SetCustomAttribute($SetLastErrorCustomAttribute)

    #CloseHandle
    $PInvokeMethodBuilder = $TypeBuilder.DefinePInvokeMethod('CloseHandle', 'kernel32.dll',
      ([Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::Static),
      [Reflection.CallingConventions]::Standard,
      [bool],
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
    $FileStream = New-Object IO.FileStream ($VolumeHandle, [IO.FileAccess]::Read)

    # Read VBR from volume
    $VolumeBootRecord = New-Object Byte[] (512)
    if ($FileStream.Read($VolumeBootRecord, 0, $VolumeBootRecord.Length) -ne 512) {
      Write-Error "Error reading volume boot record."
    }

    # Parse MFT offset from VBR and set stream to its location
    $MftOffset = [Bitconverter]::ToInt32($VolumeBootRecord[0x30..0x37], 0) * 0x1000
    $FileStream.Position = $MftOffset

    # Read MFT's file record header
    $MftFileRecordHeader = New-Object byte[] (48)
    if ($FileStream.Read($MftFileRecordHeader, 0, $MftFileRecordHeader.Length) -ne $MftFileRecordHeader.Length) {
      Write-Error "Error reading MFT file record header."
    }

    # Parse values from MFT's file record header
    $OffsetToAttributes = [Bitconverter]::ToInt16($MftFileRecordHeader[0x14..0x15], 0)
    $AttributesRealSize = [Bitconverter]::ToInt32($MftFileRecordHeader[0x18..0x21], 0)

    # Read MFT's full file record
    $MftFileRecord = New-Object byte[] ($AttributesRealSize)
    $FileStream.Position = $MftOffset
    if ($FileStream.Read($MftFileRecord, 0, $MftFileRecord.Length) -ne $AttributesRealSize) {
      Write-Error "Error reading MFT file record."
    }

    # Parse MFT's attributes from file record
    $Attributes = New-Object byte[] ($AttributesRealSize - $OffsetToAttributes)
    [array]::Copy($MftFileRecord, $OffsetToAttributes, $Attributes, 0, $Attributes.Length)

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
    $MftData = New-Object byte[] (0x1000)
    [array]$SendBuffer = @()

    do {
      $StartBytes = [int]($DataRunStrings[$DataRunStringsOffset][0]).ToString()
      $LengthBytes = [int]($DataRunStrings[$DataRunStringsOffset][1]).ToString()
      $DataRunStart = "0x"
      $DataRunLength = "0x"

      for ($i = $StartBytes; $i -gt 0; $i --) {
        $DataRunStart += $DataRunStrings[($DataRunStringsOffset + $LengthBytes + $i)]
      }

      for ($i = $LengthBytes; $i -gt 0; $i --) {
        $DataRunLength += $DataRunStrings[($DataRunStringsOffset + $StartBytes + $i)]
      }

      $FileStreamOffset += ([int]$DataRunStart * 0x1000)
      $FileStream.Position = $FileStreamOffset

      for ($i = 1; $i -lt [int]$DataRunLength + 1; $i++) {

        $readlen = $FileStream.Read($MftData, 0, $MftData.Length)
        [array]$SendBuffer += $MftData[0..($readlen - 1)]


        if ($readlen -ne $MftData.Length) {

          Write-Warning "Possible error reading MFT data on $env:COMPUTERNAME."

        }

        #Logic to only write to stream only if buffer is full (16384)
        #or not divisble by 4096, meaning it's the last write
        switch ($Sendbuffer.Length) {

          16384 {
            $SendBuffer = $null
          }

          { ![math]::Equals(($_ % 4092), 0) } {
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

    #On success return the MFT's size
    $MftSize



  }

  #Scriptblock to start a tcp server that will be forked into a seperate

  $OutputFilePath = Join-Path (Split-Path $OutputFilePath | Resolve-Path) (Split-Path $OutputFilePath -Leaf) -ErrorAction Stop
  $remote_pssession = New-PSSession -ComputerName $computername -SessionOption (New-PSSessionOption -NoMachineProfile) -ErrorAction Stop

  #Powershell Runspace
  $ListenerBlock = {

    param($Lport, $OutputFilePath)

    #Start TCP SERVER
    $Tcplistener = New-Object System.Net.Sockets.TcpListener $lport

    $Tcplistener.Start()
    $TcpClient = $Tcplistener.AcceptTcpClient()

    $remotesvr = $TcpClient.Client.RemoteEndPoint.Address.IPAddressToString
    $TcpNetworkstream = $TCPClient.GetStream()
    $Receivebuffer = New-Object Byte[] $TcpClient.ReceiveBufferSize
    $OutputFileStream = New-Object IO.FileStream $OutputFilePath, 'Append', 'Write', 'Read'

    try {

      while ($TcpClient.Connected) {

        $Read = $TcpNetworkstream.Read($Receivebuffer, 0, $Receivebuffer.Length)

        if ($Read -eq 0) {
          break
        }
        else {

          [array]$Bytesreceived += $Receivebuffer[0..($Read - 1)]
          [array]::Clear($Receivebuffer, 0, $Read)
          $OutputFileStream.Write($Bytesreceived, 0, $Bytesreceived.Length)
          $TcpNetworkstream.Flush()
          $Bytesreceived = $null

        }

      }

    }

    catch {
      exit (1)
    }

    $OutputFileStream.Close()
    $Tcplistener.Stop()

  } #End Listener Block

  Write-Verbose "[*] Initializing Listener Runspace..."
  $InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  $runspacepool = [runspacefactory]::CreateRunspacePool($InitialSessionState)

  Write-Verbose "[*] Opening Runspace..."
  Start-Sleep 1
  $runspacepool.Open()
  $runspace = [powershell]::Create()
  $runspace.runspacePool = $runspacepool

  Write-Verbose "[+] Runspace Open"
  Start-Sleep 1
  $ParamList = @{ "Lport" = $Lport
    "OutputFilePath"      = $OutputFilePath
  }

  Write-Verbose "[*] Forking Listener to Runspace..."
  [void]$runspace.AddScript($ListenerBlock).AddParameters($ParamList)

  Write-Verbose "[*] Starting Listener..."

  Start-Sleep 1
  $runspace.begininvoke() | Out-Null

  if (-not ($runspace.HadErrors)) {

    if ($(netstat -ant | findstr $Lport)) {
      Write-Verbose "[+] Successfully forked TCP listener on port $Lport to background"
    }

  }

  else {
    Write-Verbose "[-] Couldn't start Listener. Exiting."
  }

  #Scriptblock to dump MFT on Remote host
  $ScriptBlock = {

    param($calling_host, $Volume, $Lport)

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

    $DynAssembly = New-Object System.Reflection.AssemblyName ('MFT')
    $AssemblyBuilder = [AppDomain]::CurrentDomain.DefineDynamicAssembly($DynAssembly, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $ModuleBuilder = $AssemblyBuilder.DefineDynamicModule('InMemory', $false)

    $TypeBuilder = $ModuleBuilder.DefineType('kernel32', 'Public, Class')
    $DllImportConstructor = [Runtime.InteropServices.DllImportAttribute].GetConstructor(@([string]))
    $SetLastError = [Runtime.InteropServices.DllImportAttribute].GetField('SetLastError')
    $SetLastErrorCustomAttribute = New-Object Reflection.Emit.CustomAttributeBuilder ($DllImportConstructor,
      @('kernel32.dll'),
      [Reflection.FieldInfo[]]@($SetLastError),
      @($True))

    #CreateFile
    $PInvokeMethodBuilder = $TypeBuilder.DefinePInvokeMethod('CreateFile', 'kernel32.dll',
      ([Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::Static),
      [Reflection.CallingConventions]::Standard,
      [IntPtr],
      [Type[]]@([string], [int32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr]),
      [Runtime.InteropServices.CallingConvention]::Winapi,
      [Runtime.InteropServices.CharSet]::Ansi)

    $PInvokeMethodBuilder.SetCustomAttribute($SetLastErrorCustomAttribute)

    #CloseHandle
    $PInvokeMethodBuilder = $TypeBuilder.DefinePInvokeMethod('CloseHandle', 'kernel32.dll',
      ([Reflection.MethodAttributes]::Public -bor [Reflection.MethodAttributes]::Static),
      [Reflection.CallingConventions]::Standard,
      [bool],
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
    $FileStream = New-Object IO.FileStream ($VolumeHandle, [IO.FileAccess]::Read)

    # Read VBR from volume
    $VolumeBootRecord = New-Object Byte[] (512)
    if ($FileStream.Read($VolumeBootRecord, 0, $VolumeBootRecord.Length) -ne 512) {
      Write-Error "Error reading volume boot record."
    }

    # Parse MFT offset from VBR and set stream to its location
    $MftOffset = [Bitconverter]::ToInt32($VolumeBootRecord[0x30..0x37], 0) * 0x1000
    $FileStream.Position = $MftOffset

    # Read MFT's file record header
    $MftFileRecordHeader = New-Object byte[] (48)
    if ($FileStream.Read($MftFileRecordHeader, 0, $MftFileRecordHeader.Length) -ne $MftFileRecordHeader.Length) {
      Write-Error "Error reading MFT file record header."
    }

    # Parse values from MFT's file record header
    $OffsetToAttributes = [Bitconverter]::ToInt16($MftFileRecordHeader[0x14..0x15], 0)
    $AttributesRealSize = [Bitconverter]::ToInt32($MftFileRecordHeader[0x18..0x21], 0)

    # Read MFT's full file record
    $MftFileRecord = New-Object byte[] ($AttributesRealSize)
    $FileStream.Position = $MftOffset
    if ($FileStream.Read($MftFileRecord, 0, $MftFileRecord.Length) -ne $AttributesRealSize) {
      Write-Error "Error reading MFT file record."
    }

    # Parse MFT's attributes from file record
    $Attributes = New-Object byte[] ($AttributesRealSize - $OffsetToAttributes)
    [array]::Copy($MftFileRecord, $OffsetToAttributes, $Attributes, 0, $Attributes.Length)

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
    $MftData = New-Object byte[] (0x1000)
    [array]$SendBuffer = @()

    # Connect Back to calling host to send MFT
    $Tcpclient = New-Object System.Net.Sockets.TcpClient
    $Tcpclient.sendbuffersize = 16384
    $serverip = (([System.Net.Dns]::GetHostAddresses($calling_host))[0]).IPAddressToString

    try {
      $Tcpclient.Connect($serverip, $lport)
      $TcpNetworkStream = $Tcpclient.GetStream()

      do {
        $StartBytes = [int]($DataRunStrings[$DataRunStringsOffset][0]).ToString()
        $LengthBytes = [int]($DataRunStrings[$DataRunStringsOffset][1]).ToString()
        $DataRunStart = "0x"
        $DataRunLength = "0x"

        for ($i = $StartBytes; $i -gt 0; $i --) {
          $DataRunStart += $DataRunStrings[($DataRunStringsOffset + $LengthBytes + $i)]
        }

        for ($i = $LengthBytes; $i -gt 0; $i --) {
          $DataRunLength += $DataRunStrings[($DataRunStringsOffset + $i)]
        }

        $FileStreamOffset += ([int]$DataRunStart * 0x1000)
        $FileStream.Position = $FileStreamOffset

        for ($i = 1; $i -lt [int]$DataRunLength + 1; $i++) {

          $readlen = $FileStream.Read($MftData, 0, $MftData.Length)
          [array]$SendBuffer += $MftData[0..($readlen - 1)]


          if ($readlen -ne $MftData.Length) {

            Write-Warning "Possible error reading MFT data on $env:COMPUTERNAME."

          }

          #Logic to only write to stream only if buffer is full (16384)
          #or not divisble by 4096, meaning it's the last write
          switch ($Sendbuffer.Length) {

            16384 {
              $TcpNetworkstream.Write($Sendbuffer, 0, $Sendbuffer.Length)
              $TcpNetworkstream.Flush()
              $SendBuffer = $null
            }

            { ![math]::Equals(($_ % 4092), 0) } {

              $TcpNetworkstream.Write($Sendbuffer, 0, $Sendbuffer.Length)
              $TcpNetworkstream.Flush()
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

      #Shutdown the connection
      $TcpNetworkstream.Dispose()
      $Tcpclient.Close()

      #On success return the MFT's size
      $MftSize

    }

    catch {
      0
    }

  }

  $calling_host = $env:COMPUTERNAME
  netsh advfirewall firewall delete rule name=$FirewallRuleName | Out-Null
  netsh advfirewall firewall add rule name=$FirewallRuleName dir=in action=allow protocol=TCP localport=$lport | Out-Null

  Write-Verbose "[+] Added Firewall rule `"$FirewallRuleName`" for port $LPort"
  $scriptTime = [Diagnostics.Stopwatch]::StartNew()

  Write-Verbose "[+] Execution Start time: $(Get-Date -Format t)"
  Write-Verbose "[*] Writing to $OutputFilePath"
  $ReturnedObjects = Invoke-Command -Session $remote_pssession -ScriptBlock $ScriptBlock -ArgumentList @($calling_host, $Volume, $LPort)
  if ($ReturnedObjects -eq 0) {
    Write-Verbose "[-] Failed to transfer MFT."
  }
  else {
    Write-Verbose "[+] Successfully copied MFT with a size of $($ReturnedObjects / 1024 / 1024) MB"
  }

  Write-Verbose "[*] Removing Runspace..."
  $runspace.Stop()
  $runspacepool.Close()
  $runspacepool.Dispose()
  [GC]::Collect()
  $ScriptTime.Stop()

  Write-Verbose "[+] Runspace removed."
  netsh advfirewall firewall delete rule name=$FirewallRuleName | Out-Null
  Write-Verbose "[+] Firewall rule removed"
  Write-Verbose "[+] Done, execution time: $($ScriptTime.Elapsed)"

}

