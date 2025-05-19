<#
.SYNOPSIS
Uses Voidtools' Everything to retrieve a list of all files in a specified directory and its subdirectories.

.DESCRIPTION
The Invoke-EverythingSearch cmdlet searches for files within a specified directory and its subdirectories using Voidtools' Everything. You can provide a directory path or use Everything's query syntax to perform the search. The cmdlet handles automatic downloading of required executables if not available.

.PARAMETER EverythingPortableExe
Specifies the path to the Everything executable. Defaults to "$EverythingDirectory\Everything64.exe" if not specified.

.PARAMETER EverythingDirectory
Specifies the directory where the Everything executable is located. Defaults to the system's temporary directory if not specified.

.PARAMETER EverythingCLI
Specifies the path to the Everything command-line interface executable. Defaults to "$EverythingDirectory\es.exe" if not specified.

.PARAMETER SearchInDirectory
Specifies the directory to search in. If not specified, the search is performed in all indexed locations by Everything.

.PARAMETER EverythingCLIDownloadURL
Specifies the URL to download the Everything CLI. Defaults to 'https://www.voidtools.com/ES-1.1.0.27.x64.zip'.

.PARAMETER EverythingPortableDownloadURL
Specifies the URL to download the Everything Portable executable. Defaults to 'https://www.voidtools.com/Everything-1.5.0.1383a.x64.zip'.

.PARAMETER SearchTerm
Specifies the search term to use. Defaults to '*' to match all files.

.NOTES
This cmdlet is not supported on Linux systems. Requires Windows OS.

.LINK
For more information, visit: https://www.voidtools.com/support/everything/

.EXAMPLE
Invoke-EverythingSearch -EverythingPortableExe "C:\Path\To\Everything.exe" -SearchTerm "*.txt"
Retrieves a list of all .txt files in all indexed locations using the specified Everything executable.

.EXAMPLE
Invoke-EverythingSearch -SearchInDirectory "C:\Users\Example"
Uses the default Everything executable path to retrieve a list of all files in the specified directory (C:\Users\Example) and its subdirectories.
#>


function Invoke-EverythingSearch {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]
    $EverythingDirectory = $(Join-Path -Path $ENV:Temp -ChildPath 'Everything'),

    [Parameter(Mandatory = $false)]
    [string]
    $EverythingCLI = "$EverythingDirectory\es.exe",

    [Parameter(Mandatory = $false)]
    [string]
    $EverythingPortableExe = "$EverythingDirectory\Everything64.exe",

    [Parameter(Mandatory = $false)]
    [string]
    $SearchInDirectory = '',

    [Parameter(Mandatory = $false)]
    [string]
    $SearchTerm = '*',

    [Parameter(Mandatory = $false)]
    [string]
    $EverythingCLIDownloadURL = 'https://www.voidtools.com/ES-1.1.0.27.x64.zip',

    [Parameter(Mandatory = $false)]
    [string]
    $EverythingPortableDownloadURL = 'https://www.voidtools.com/Everything-1.5.0.1390a.x64.zip'
  )

  # Import the required cmdlets
  $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Show-TUIConfirmationDialog')
  $missingCmdlets = $neededcmdlets | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }

  if ($missingCmdlets) {
    if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
      $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
      $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
      New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
    }
    Write-Verbose -Message "Importing missing cmdlets: $missingCmdlets"
    $Cmdletstoinvoke = Install-Cmdlet -RepositoryCmdlets $missingCmdlets
    $Cmdletstoinvoke | Import-Module -Force
  }

  # First we need to terminate any existing everything processes
  if (Get-Process -Name 'Everything*' -ErrorAction SilentlyContinue) {
    Stop-Process -Name 'Everything*' -Force
  }

  # Make sure everythingdirectory exists
  if (-not (Test-Path -Path $EverythingDirectory)) {
    New-Item -Path $EverythingDirectory -ItemType Directory -Force
  }

  # Download Everything if not found
  $EverythingCLIResolved = $(Resolve-Path -Path $EverythingCLI -ErrorAction SilentlyContinue).Path
  if (-not($EverythingCLIResolved) ) {
    Write-Logg -Message 'Everything CLI not found' -Level INFO
    Write-Logg -Message 'Downloading Everything CLI' -Level INFO
    $everythingclizip = Get-FileDownload -URL $EverythingCLIDownloadURL -DestinationDirectory $EverythingDirectory -UseAria2 -noRPCMode | Select-Object -Last 1
    Expand-Archive -Path $everythingclizip -DestinationPath $EverythingDirectory -Force
    $EverythingCLI = Get-ChildItem -Path $EverythingDirectory -Filter 'es.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  }


  $EverythingPortableExeResolved = $(Resolve-Path -Path $EverythingPortableExe -ErrorAction SilentlyContinue).Path
  if (-not ($EverythingPortableExeResolved)) {
    Write-Logg -Message 'Everything executable not found' -Level INFO
    Write-Logg -Message 'Downloading Everything Portable' -Level INFO
    $everythingPortablezip = Get-FileDownload -Url $EverythingPortableDownloadURL -DestinationDirectory $EverythingDirectory -UseAria2 -noRPCMode | Select-Object -Last 1
    Expand-Archive -Path $everythingPortablezip -DestinationPath $EverythingDirectory -Force
    $EverythingPortableExe = Get-ChildItem -Path $EverythingDirectory -Filter 'Everything*.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    $EverythingPortableExeResolved = $(Resolve-Path -Path $EverythingPortableExe -ErrorAction SilentlyContinue).Path
  }
  try {
    #region Everything Portable Options


    # We will now start everything portable with the right arguments
    # $EverythingPortableOptions = @{
    #   #'-filename *.evt' = '# <filename> Search for a file or folder by filename.'
    #   ## Installation Options
    #   #'-app-data'                                                              = '# Store settings and data in %APPDATA%\Everything or in the same location as the executable.'
    #   #'-noapp-data' = '# Store settings and data in the same location as the executable.'
    #   #'-choose-language'                                                       = '# Show the language selection page.'
    #   #'-choose-volumes'                  = '# Do not automatically index volumes, removes all NTFS volumes from the index.'
    #   #'-service-port <port>'                                                   = '# Specify the port of the Everything service.'
    #   #'-service-pipe-name <name>'                                              = '# Specify the pipe name of the Everything service.'
    #   #'-enable-run-as-admin'              = '# Enable run as administrator. Requires administrative privileges.'
    #   #'-disable-run-as-admin'                                                  = '# Disable run as administrator. Requires administrative privileges.'
    #   #'-enable-update-notification'                                            = '# Enable update notification on startup.'
    #   #'-disable-update-notification'                                           = '# Disable update notification on startup.'
    #   #'-install <location>'                                                    = '# Copy Everything.exe and uninstall.exe to the new location. Creates uninstall entry in Programs and Features. Requires administrative privileges.'
    #   #'-install-client-service'      = "# Install the 'Everything' client as a service. Requires administrative privileges."
    #   #'-uninstall-client-service'                                              = "# Uninstall the 'Everything' client service. Requires administrative privileges."
    #   #'-install-config <filename>'                                             = '# Install the specified configuration file.'
    #   #'-install-desktop-shortcut'                                              = '# Create a desktop shortcut for the current user. Requires administrative privileges.'
    #   #'-uninstall-desktop-shortcut'                                            = '# Delete the desktop shortcut for the current user. Requires administrative privileges.'
    #   #'-install-all-users-desktop-shortcut'                                    = '# Create a desktop shortcut for all users. Requires administrative privileges.'
    #   #'-uninstall-all-users-desktop-shortcut'                                  = '# Delete the desktop shortcut for all users. Requires administrative privileges.'
    #   #'-install-efu-association'                                               = '# Create the EFU file association with Everything. Requires administrative privileges.'
    #   #'-uninstall-efu-association'                                             = '# Remove the EFU file association with Everything. Requires administrative privileges.'
    #   #'-install-folder-context-menu'                                           = '# Install folder context menus. Requires administrative privileges.'
    #   #'-uninstall-folder-context-menu'                                         = '# Uninstall folder context menus. Requires administrative privileges.'
    #   #'-install-options <command line options>'                                = '# Command line options to pass to the newly installed Everything.exe. Requires administrative privileges.'
    #   #'-install-quick-launch-shortcut'                                         = '# Create the Search Everything quick launch shortcut.'
    #   #'-uninstall-quick-launch-shortcut'                                       = '# Delete the Search Everything quick launch shortcut.'
    #   #'-install-run-on-system-startup'                                         = '# Add Everything to system startup. Requires administrative privileges.'
    #   #'-uninstall-run-on-system-startup'                                       = '# Remove Everything from system startup. Requires administrative privileges.'
    #   #'-install-service' = "# Install the 'Everything' service. Service starts automatically. Requires administrative privileges."
    #   #'-uninstall-service'                                                     = "# Uninstall the 'Everything' service. Requires administrative privileges."
    #   #'-install-service-port <port>'                                           = '# Install the Everything service on the specified port. Requires administrative privileges.'
    #   #'-install-service-pipe-name <name>'                                      = '# Install the Everything service with the specified pipe name. Requires administrative privileges.'
    #   #'-install-start-menu-shortcuts'                                          = '# Create the Everything shortcuts in the Start menu for the current user. Requires administrative privileges.'
    #   #'-uninstall-start-menu-shortcuts'                                        = '# Delete the Everything shortcuts in the Start menu for the current user. Requires administrative privileges.'
    #   #'-install-all-users-start-menu-shortcuts'                                = '# Create the Everything shortcuts in the Start menu for all users. Requires administrative privileges.'
    #   #'-uninstall-all-users-start-menu-shortcuts'                              = '# Delete the Everything shortcuts in the Start menu for all users. Requires administrative privileges.'
    #   #'-install-url-protocol'                                                  = '# Install the URL Protocol for Everything. Requires administrative privileges.'
    #   #'-uninstall-url-protocol'                                                = '# Uninstall the URL Protocol for Everything. Requires administrative privileges.'
    #   #'-language <langID>'                                                     = '# Set the language to the specified language ID. Example: 1033 = English (US).'
    #   #'-uninstall [path]'                                                      = '# Uninstall Everything from the specified path. Requires administrative privileges.'
    #   #'-uninstall-user'                                                        = '# Uninstall Everything user files.'
    #   #'-create-usn-journal \\.\C 1073741824' = '# <volume> <max-size-bytes> <allocation-delta-bytes> Create a USN Journal on the specified volume. Requires administrative privileges. '
    #   #'-delete-usn-journal <volume>'                                           = '# Delete the USN Journal on the specified volume. Requires administrative privileges.'
    #   #'-install-language <langID>'                                             = '# Set the installation language to the specified language ID. Requires administrative privileges.'
    #   #'-save-install-options <user-install-option-flags>'                      = '# Save user install options to the registry. Example: 1 = Update notifications, 2 = Install Quick Launch shortcut.'

    #   ## File Lists
    #   #'[file-list-filename]'                                                   = '# Open the specified file list.'
    #   #'-create-file-list <filename> <path>'                                    = '# Create a file list of a specified path.'
    #   #'-create-file-list-exclude-files <filters>'                              = '# Set filters to exclude files while creating a file list.'
    #   #'-create-file-list-exclude-folders <filters>'                            = '# Set filters to exclude folders while creating a file list.'
    #   #'-create-file-list-include-only-files <filters>'                         = '# Set filters to include only specific files while creating a file list.'
    #   #'-edit <filename>'                                                       = '# Open a file list with the file list editor.'
    #   #'-f <filename>'                                                          = '# Open a file list (short version).'
    #   #'-filelist <filename>'                                                   = '# Open a file list.'

    #   ## ETP Options
    #   #'-admin-server-share-links'                                              = '# Set link type for ETP connections.'
    #   #'-server-share-links'                                                    = '# Set server link type for ETP connections.'
    #   #'-ftp-links'                                                             = '# Set FTP links for ETP connections.'
    #   #'-drive-links'                                                           = '# Set drive links for ETP connections.'
    #   #'-connect <[username[:password]@]host[:port]>'                           = '# Connect to an ETP server.'

    #   ## Searching Options
    #   #'-bookmark <name>'                                                       = '# Open a bookmark.'
    #   #'-case'                                                                  = '# Enable case matching in searches.'
    #   #'-nocase'                                                                = '# Disable case matching in searches.'
    #   #'-diacritics'                                                            = '# Enable diacritics matching in searches.'
    #   #'-nodiacritics'                                                          = '# Disable diacritics matching in searches.'
    #   #'-filename *.evt*'                  = '# <filename> Search for a file or folder by filename.'
    #   #'-filter <name>'                                                         = '# Select a search filter.'
    #   #'-l'                                                                     = '# Load the local database.'
    #   #'-local'                                                                 = '# Load the local database (alternative command).'
    #   #'-matchpath'                                                             = '# Enable full path matching in searches.'
    #   #'-nomatchpath'                                                           = '# Disable full path matching in searches.'
    #   #'-p <path>'                                                              = '# Search for a specific path.'
    #   #'-path <path>'                                                           = '# Search for a path (alternative command).'
    #   #'-parent <path>'                                                         = '# Search for files and folders in a specified path without searching subfolders.'
    #   #'-parentpath <path>'                                                     = '# Search for the parent of a specified path.'
    #   #'-regex'                                                                 = '# Enable Regex in searches.'
    #   #'-noregex'                                                               = '# Disable Regex in searches.'
    #   #'-s C:\ "*.evt*"' = '#<text> Set the search text.'
    #   #'-search <text>'                                                         = '# Set the search text (alternative command).'
    #   #'-url <[es:]search>'                                                     = '# Set the search from an ES: URL.'
    #   #'-wholeword'                                                             = '# Enable match whole word in searches.'
    #   #'-nowholeword'                                                           = '# Disable match whole word in searches.'
    #   #'-ww'                                                                    = '# Enable match whole word (short version).'
    #   #'-noww'                                                                  = '# Disable match whole word (short version).'
    #   #'-home'                                                                  = '# Open the home search page.'
    #   #'-name-part <filename>'                                                  = '# Search for the name part of a filename.'
    #   #'-search-file-list <filename>'                                           = '# Search a specified text file for a list of file names.'

    #   ## Results Options
    #   #'-sort <name>'                                                           = "# Set the sorting criteria for results. Example: -sort size, -sort 'Date Modified'."
    #   #'-sort-ascending'                                                        = '# Sort results in ascending order.'
    #   #'-sort-descending'                                                       = '# Sort results in descending order.'
    #   #'-details'                     = '# View results in the detail view.'
    #   #'-thumbnail-size <size>'                                                 = '# Specify the size of thumbnails in pixels.'
    #   #'-thumbnails'                                                            = '# Show results in thumbnail view.'
    #   #'-focus-bottom-result'                                                   = '# Focus on the bottom result.'
    #   #'-focus-last-run-result'                                                 = '# Focus on the last run result.'
    #   #'-focus-most-run-result'                                                 = '# Focus on the most run result.'
    #   #'-focus-results'                                                         = '# Focus the result list.'
    #   #'-focus-top-result'                                                      = '# Focus the top result.'
    #   #'-select <filename>'                                                     = '# Focus and select a specified result.'

    #   ## General Options
    #   #'-?'                                                                     = '# Show help.'
    #   #'-h'                                                                     = '# Show help (alternative command).'
    #   #'-help'                                                                  = '# Show help (alternative command).'
    #   #'-admin'      = '# Run Everything as an administrator.'
    #   #'-client-svc'                                                            = '# Everything client service entry point.'
    #   #'-config <filename>'                                                     = '# Specify the ini file to use for configuration.'
    #   #'-console'                     = '# Show the debugging console.'
    #   #'-debug'                       = '# Show the debugging console.'
    #   #'-debug-log'                   = '# Enable debug mode and log debugging information to disk.'
    #   #'-exit'                                                                  = '# Exit an existing Everything instance.'
    #   #'-quit'                                                                  = '# Exit an existing Everything instance (alternative command).'
    #   #'-instance everythingportable' = '#  <name> The name of the Everything instance to run.'
    #   #'-is-run-as'                                                             = "# Specify that Everything was executed with 'runas' and should not attempt to runas again."
    #   #'-start-client-service'        = '# Start the Everything client service.'
    #   #'-stop-client-service'                                                   = '# Stop the Everything client service.'
    #   #'-start-service'               = '# Start the Everything service.'
    #   #'-stop-service'                                                          = '# Stop the Everything service.'
    #   #'-startup'                                                               = '# Run Everything in the background.'
    #   #'-svc'                                                                   = '# Service entry point. Optionally combine with -svc-port.'
    #   #'-svc-port <port>'                                                       = '# Run the Everything service on the specified port.'
    #   #'-svc-pipe-name <name>'                                                  = '# Host the pipe server with the specified name.'
    #   #'-svc-security-descriptor <sd>'                                          = '# Host the Everything Service pipe server with the specified security descriptor. Requires Everything 1.4.1.994 or later.'
    #   #'-verbose'                     = '# Display all debug messages.'
    #   #'-noverbose'                                                             = '# Display basic debug messages.'
    #   #'-first-instance'                                                        = '# Only run Everything if this is the first instance.'
    #   #'-no-first-instance'                                                     = '# Only run Everything if Everything is already running.'

    #   ## Database Options
    #   #'-db <filename>'                                                         = '# The filename of the database to load or save.'
    #   #'-load-delay <milliseconds>'                                             = '# Delay in milliseconds before loading the database.'
    #   #'-nodb'                                                                  = '# Do not save to or load from the Everything database file.'
    #   #'-read-only'                                                             = '# Do not update the database.'
    #   #'-reindex'                                                               = '# Force a database rebuild.'
    #   #'-update'                                                                = '# Save the database to disk.'
    #   #'-rescan-all'                                                            = '# Rescan all folder indexes.'
    #   #'-monitor-pause'                                                         = '# Pause NTFS, ReFS, and folder index monitors.'
    #   #'-monitor-resume'                                                        = '# Resume NTFS, ReFS, and folder index monitors.'

    #   ## Window Options
    #   #'-fullscreen'                                                            = '# Show the search window in fullscreen.'
    #   #'-nofullscreen'                                                          = '# Show the search window in a regular window.'
    #   #'-maximized'                                                             = '# Maximize the search window.'
    #   #'-nomaximized'                                                           = '# Restore the search window from maximized.'
    #   #'-minimized'                                                             = '# Minimize the search window.'
    #   #'-nominimized'                                                           = '# Restore the search window from minimized.'
    #   #'-newwindow'                                                             = '# Create a new search window.'
    #   #'-nonewwindow'                                                           = '# Show an existing window instead of creating a new one.'
    #   #'-ontop'                                                                 = '# Enable always on top for the search window.'
    #   #'-noontop'                                                               = '# Disable always on top for the search window.'
    #   #'-close'                                                                 = '# Close the current search window.'
    #   #'-toggle-window'                                                         = '# Show or hide the current search window.'

    #   ## Multi File Renaming
    #   #'-copyto [filename1] [filename2] [filename3] [...]'                      = '# Show the multi file renamer for a copy to operation.'
    #   #'-moveto [filename1] [filename2] [filename3] [...]'                      = '# Show the multi file renamer for a move to operation.'
    #   #'-rename [filename1] [filename2] [filename3] [...]'                      = '# Show the multi file renamer for a rename operation.'
    # }
    #endregion

    #region EverthingCLI Options
    $ESOptions = @{

      # # General Command Line Options
      # '-r <search>'                                                   = '# Search using regular expressions. Escape spaces with double quotes.'
      # '-regex <search>'                                               = '# Search using regular expressions. Escape spaces with double quotes.'
      # '-i'                                                            = '# Match case in search.'
      # '-case'                                                         = '# Match case in search (alternative command).'
      # '-w'                                                            = '# Match whole words in search.'
      # '-ww'                                                           = '# Match whole words in search (alternative command).'
      # '-whole-word'                                                   = '# Match whole words in search (alternative command).'
      # '-whole-words'                                                  = '# Match whole words in search (alternative command).'
      # '-p'                                                            = '# Match full path and file name.'
      # '-match-path'                                                   = '# Match full path and file name (alternative command).'
      # '-h'                                                            = '# Display help information.'
      # '-help'                                                         = '# Display help information (alternative command).'
      # '-o <offset>'                                                   = '# Show results starting from the zero-based offset.'
      # '-offset <offset>'                                              = '# Show results starting from the zero-based offset (alternative command).'
      # '-n <num>'                                                      = '# Limit the number of results shown to <num>.'
      # '-max-results <num>'                                            = '# Limit the number of results shown to <num> (alternative command).'
      # '-s'                                                            = '# Sort results by full path.'

      # # Everything 1.4 Command Line Options
      # '-a'                                                            = '# Match diacritical marks.'
      # '-diacritics'                                                   = '# Match diacritical marks (alternative command).'
      # '-name'                                                         = '# Show the name column in the results.'
      # '-path-column'                                                  = '# Show the path column in the results.'
      # '-full-path-and-name'                                           = '# Show the full path and name column in the results.'
      # '-filename-column'                                              = '# Show the filename column in the results.'
      # '-extension'                                                    = '# Show the extension column in the results.'
      # '-ext'                                                          = '# Show the extension column in the results (alternative command).'
      # '-size'                                                         = '# Show the size column in the results.'
      # '-date-created'                                                 = '# Show the date created column in the results.'
      # '-dc'                                                           = '# Show the date created column in the results (alternative command).'
      # '-date-modified'                                                = '# Show the date modified column in the results.'
      # '-dm'                                                           = '# Show the date modified column in the results (alternative command).'
      # '-date-accessed'                                                = '# Show the date accessed column in the results.'
      # '-da'                                                           = '# Show the date accessed column in the results (alternative command).'
      # '-attributes'                                                   = '# Show the attributes column in the results.'
      # '-attribs'                                                      = '# Show the attributes column in the results (alternative command).'
      # '-attrib'                                                       = '# Show the attributes column in the results (alternative command).'
      # '-file-list-file-name'                                          = '# Show the file list file name column in the results.'
      # '-run-count'                                                    = '# Show the run count column in the results.'
      # '-date-run'                                                     = '# Show the date run column in the results.'
      # '-date-recently-changed'                                        = '# Show the date recently changed column in the results.'
      # '-rc'                                                           = '# Show the date recently changed column in the results (alternative command).'

      # # Sorting Options
      # '-sort <column>'                                                = '# Sort results by the specified column. Example: -sort size.'
      # '-sort-ascending'                                               = '# Sort results in ascending order.'
      # '-sort-descending'                                              = '# Sort results in descending order.'
      # '-sort name-ascending'                                          = '# Sort by name in ascending order.'
      # '-sort name-descending'                                         = '# Sort by name in descending order.'
      # '-sort path-ascending'                                          = '# Sort by path in ascending order.'
      # '-sort path-descending'                                         = '# Sort by path in descending order.'
      # '-sort size-ascending'                                          = '# Sort by size in ascending order.'
      # '-sort size-descending'                                         = '# Sort by size in descending order.'
      # '-sort extension-ascending'                                     = '# Sort by extension in ascending order.'
      # '-sort extension-descending'                                    = '# Sort by extension in descending order.'
      # '-sort date-created-ascending'                                  = '# Sort by date created in ascending order.'
      # '-sort date-created-descending'                                 = '# Sort by date created in descending order.'
      # '-sort date-modified-ascending'                                 = '# Sort by date modified in ascending order.'
      # '-sort date-modified-descending'                                = '# Sort by date modified in descending order.'
      # '-sort date-accessed-ascending'                                 = '# Sort by date accessed in ascending order.'
      # '-sort date-accessed-descending'                                = '# Sort by date accessed in descending order.'

      # # Export Options
      # '-csv'                                                          = '# Change display format to CSV.'
      # '-efu'                                                          = '# Change display format to EFU.'
      # '-txt'                                                          = '# Change display format to TXT.'
      # '-m3u'                                                          = '# Change display format to M3U.'
      # '-m3u8'                                                         = '# Change display format to M3U8.'
      # '-export-csv <out.csv>'                                         = '# Export results to a CSV file.'
      # '-export-efu <out.efu>'                                         = '# Export results to an EFU file.'
      # '-export-txt <out.txt>'                                         = '# Export results to a TXT file.'
      # '-export-m3u <out.m3u>'                                         = '# Export results to an M3U file.'
      # '-export-m3u8 <out.m3u8>'                                       = '# Export results to an M3U8 file.'
      # '-no-header'                                                    = "# Don't write the CSV header in the export file."
      # '-utf8-bom'                                                     = '# Write the UTF-8 byte order mark at the start of the export file.'

      # # Highlighting Options
      # '-highlight'                                                    = '# Highlight results.'
      # '-highlight-color <color>'                                      = '# Set the highlight color. Example: 0x0a for light green on black.'

      # # Other Options
      #'-instance everythingportable' = '# Connect to a unique Everything instance name.'
      # '-pause'                                                        = '# Pause after each page of output.'
      # '-more'                                                         = '# Pause after each page of output (alternative command).'
      # '-hide-empty-search-results'                                    = "# Don't show any results when the search is empty."
      # '-empty-search-help'                                            = '# Show help when no search is specified.'
      # '-timeout <milliseconds>'                                       = '# Set the timeout in milliseconds for the Everything database to load before sending a query.'
      # '-save-settings'                                                = '# Save current settings to the es.ini file.'
      # '-clear-settings'                                               = '# Clear current settings from the es.ini file.'
      # '-version'                                                      = '# Display the ES version and exit.'
      # '-Invoke-EverythingSearch-version'                                       = '# Display the Everything version and exit.'
      # '-save-db'                                                      = '# Save the Everything database to disk.'
      # '-reindex'                                                      = '# Force Everything to reindex.'
      # '-no-result-error'                                              = '# Set the error level if no results are found.'

      # # Examples
      # 'es.exe *.mp3 -export-efu mp3.efu'                              = '# Export all mp3 files to an EFU file named mp3.efu.'
      # 'es.exe -sort size -n 10'                                       = '# Show the top 10 largest files.'
      # 'es.exe -sort dm -n 10'                                         = '# Show the last 10 modified files.'
      # 'es.exe foo bar -highlight'                                     = '# Highlight the search terms foo and bar.'
      # 'es.exe -size -dm -sizecolor 0x0d -dmcolor 0x0b -save-settings' = '# Show size and date modified columns, set colors, and save settings.'
    }
    #endregion

    # Start Everything Portable but throw if it does not start after 5 seconds
    try {
      # Before starting we need to ensure alpha_instance is 0 in the Everything-1.5a.ini file to allow ipc
      # Get the first Everything-*.ini file, excluding backups
      $everythingini = $(Get-ChildItem -Path $EverythingDirectory -Filter '*.ini' -ErrorAction SilentlyContinue).FullName | Where-Object { $_ -notlike 'backup' } | Select-Object -First 1
      if ([string]::IsNullOrEmpty($everythingini)) {
        Write-Logg -Message 'Everything ini file not found' -Level Warning
        Write-Logg -Message "Creating Everything ini file in $EverythingDirectory" -Level Warning
        $null = Start-Process -FilePath $EverythingPortableExeResolved -ArgumentList '-quit', ' -noapp-data' -Wait
      }

      # check if the ini file has been created
      $everythingini2nd = $(Get-ChildItem -Path $EverythingDirectory -Filter '*.ini' -ErrorAction SilentlyContinue).FullName | Where-Object { $_ -notlike 'backup' } | Select-Object -First 1
      if ([string]::IsNullOrEmpty($everythingini2nd)) {
        Write-Logg -Message 'Everything ini file not found' -Level ERROR
        throw 'Everything ini file not found'
      }

      # Stop everything process if it is running, make sure we only stop the ones with running from $EverythingDirectory
      $ProcessToKill = Get-Process -Name 'Everything*' -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "$EverythingDirectory*" }
      if ($ProcessToKill) {
        Write-Logg -Message "Stopping Everything processes: $($ProcessToKill.Name -join ', ')" -Level Warning
        Stop-Process -Name $ProcessToKill -Force -ErrorAction SilentlyContinue
      }
      # Check if the file is locked by any process
      $everythinginilock = $false
      try {
        # Attempt to open the file to detect if it's locked
        $fileStream = [System.IO.File]::Open($everythingini2nd, 'Open', 'ReadWrite', [System.IO.FileShare]::None)
        $fileStream.Close()
      }
      catch {
        # If an exception is thrown, assume the file is locked
        $everythinginilock = $true
      }

      # If the file is locked, display error
      if ($everythinginilock) {
        Write-Logg -Message 'Everything ini file is locked' -Level ERROR
        Write-Logg -Message 'Please close the file and try again' -Level ERROR
        throw 'Everything ini file is locked'
      }

      # Proceed with modifying the ini file
      $everythinginicontent = Get-Content -Path $everythingini2nd
      $everythinginicontentfixed = $everythinginicontent -replace 'alpha_instance=1', 'alpha_instance=0'
      $everythinginicontentfixed | Set-Content -Path $everythingini2nd -Force

      Write-Logg -Message "Successfully modified the ini file at $everythingini2nd" -Level INFO

      # Start Everything Portable
      $everythingprocess = Start-Process -FilePath $EverythingPortableExeResolved -WindowStyle Minimized -ErrorAction Stop -PassThru
      # Sleep for 5 seconds to allow Everything to start
      Start-Sleep -Seconds 5
      $count = 0
      while (-not (Get-Process -Id $everythingprocess.Id -ErrorAction SilentlyContinue | Where-Object { $_.HasExited -eq $false })) {
        Start-Sleep -Seconds 1
        $count++
        if ($count -eq 4) {
          throw 'Everything did not start'
        }
      }
    }
    catch {
      Write-Logg -Message "Everything did not start. Executable is found at $EverythingExeResolved" -Level ERROR
      Write-Logg -Message $_.Exception.Message -Level ERROR
      $Confirmation = Write-Logg -Message 'Would you like to check for and kill any existing Everything processes?' -Level INFO -TUIPopUpMessage
      if ($Confirmation -eq 'Yes') {
        $ProcessesToKill = Get-Process | Where-Object { $_ -like '*everything64*' }
        if ($ProcessesToKill) {
          Write-Logg -Message "Stopping Everything processes: $($ProcessesToKill -join ', ')" -Level INFO
          Stop-Process -Name $ProcessesToKill -Force -ErrorAction SilentlyContinue
        }
      }
      else {
        Write-Logg -Message 'Exiting script' -Level INFO
        throw
      }
    }

    # Start the cli this way so we can capture the output in memory
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $EverythingCLI
    $processInfo.Arguments = "$($SearchInDirectory + ' ' + $SearchTerm + ' ' + $ESOptions.Keys -join ' ')"
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    # Create and start the process
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null

    # Capture the output and error asynchronously
    $stdOutput = $process.StandardOutput.ReadToEnd()
    $stdError = $process.StandardError.ReadToEnd()

    # Wait for the process to exit
    $process.WaitForExit()

    # Check if any errors were found in the stderr output
    if ($stdError -match 'Error:') {
      Write-Logg -Message "Error detected: $stdError" -Level ERROR
    }

    # Split the output into a hash table to make sure there are no empty lines or duplicates
    $stdOutputHashtable = @{}  # Initialize an empty hash table
    if ($stdOutput) {
      # Split the output into lines, remove empty lines, and trim each line
      $allines = $stdOutput -split [System.Environment]::NewLine | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim() }

      # Add each line to the hash table with a default key (numerical index)
      $index = 0
      foreach ($line in $allines) {
        $stdOutputHashtable[$index] = $line
        $index++
      }
    }

    # Optionally handle errors
    if ($stdError) {
      Write-Logg -Message "CLI Error Output: $stdError" -Level ERROR
    }
    return $stdOutputHashtable.Values ? $stdOutputHashtable.Values : $stdError
  }
  catch {
    Write-Logg -Message $_.Exception.Message -Level ERROR
  }
  finally {
    # Make sure the process we started is now closed
    if ($everythingprocess) {
      Stop-Process -Id $everythingprocess.Id -Force -ErrorAction SilentlyContinue
    }
  }
}