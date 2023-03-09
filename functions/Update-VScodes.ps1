function Update-VScodes {
	[CmdletBinding()]
	param (
		
	)	
	process {
		Invoke-WebRequest 'https://code.visualstudio.com/sha/download?build=insider&os=win32-x64-archive' -OutFile "$ENV:USERPROFILE\downloads\insiders.zip" -Verbose
		Expand-Archive "$ENV:USERPROFILE\Downloads\insiders.zip" -DestinationPath $XWAYSUSB + "\vscode-insider\" -Force -Verbose
		Invoke-WebRequest 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-archive' -OutFile "$ENV:USERPROFILE\downloads\vscode.zip" -Verbose
		Expand-Archive "$ENV:USERPROFILE\Downloads\vscode.zip" -DestinationPath $XWAYSUSB + "\vscode\" -Force -Verbose
	}
}
   