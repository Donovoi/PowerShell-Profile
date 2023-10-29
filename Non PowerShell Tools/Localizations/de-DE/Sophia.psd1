ConvertFrom-StringData -StringData @'
UnsupportedOSBuild                        = Das Skript unterstützt Windows 11 22H2+.
UpdateWarning                             = Ihr Windows 11-Build: {0}.{1}. Unterstützter Builds: 22621.2283+. Führen Sie Windows Update aus und versuchen Sie es erneut.
UnsupportedLanguageMode                   = Die PowerShell-Sitzung wird in einem eingeschränkten Sprachmodus ausgeführt.
LoggedInUserNotAdmin                      = Der angemeldete Benutzer hat keine Administratorrechte.
UnsupportedPowerShell                     = Sie versuchen ein Skript über PowerShell {0}.{1} auszuführen. Das Skript in der entsprechenden PowerShell-Version ausführen.
UnsupportedHost                           = Das Skript unterstützt nicht die Ausführung über {0}.
Win10TweakerWarning                       = Wahrscheinlich wurde Ihr Betriebssystem über die Win 10 Tweaker-Hintertür infiziert.
TweakerWarning                            = Die Stabilität des Windows-Betriebssystems kann durch die Verwendung des {0} beeinträchtigt worden sein. Installieren Sie Windows vorsichtshalber neu.
bin                                       = Im Ordner "bin" befinden sich keine Dateien. Bitte das Archiv erneut herunterladen.
RebootPending                             = Der PC wartet darauf, neu gestartet zu werden.
UnsupportedRelease                        = Neue Version gefunden.
KeyboardArrows                            = Bitte verwenden Sie die Pfeiltasten {0} und {1} auf Ihrer Tastatur, um Ihre Antwort auszuwählen
CustomizationWarning                      = Haben Sie alle Funktionen in der voreingestellten Datei {0} angepasst, bevor Sie Sophia Script ausführen?
WindowsComponentBroken                    = {0} defekt oder aus dem Betriebssystem entfernt.
UpdateDefender                            = Die Microsoft Defender-Definitionen sind veraltet. Führen Sie Windows Update aus und versuchen Sie es erneut.
ControlledFolderAccessDisabled            = Kontrollierter Ordnerzugriff deaktiviert.
ScheduledTasks                            = Geplante Aufgaben
OneDriveUninstalling                      = OneDrive deinstallieren...
OneDriveInstalling                        = OneDrive installieren...
OneDriveDownloading                       = OneDrive herunterladen...
OneDriveWarning                           = Die "{0}"-Funktion wird nur angewendet, wenn die Voreinstellung so konfiguriert ist, dass OneDrive entfernt wird (oder die App bereits entfernt wurde), andernfalls wird die Backup-Funktionalität für die Ordner "Desktop" und "Bilder" in OneDrive unterbrochen.
WindowsFeaturesTitle                      = Windows-Features
OptionalFeaturesTitle                     = Optionale Features
EnableHardwareVT                          = Virtualisierung in UEFI aktivieren.
UserShellFolderNotEmpty                   = Im Ordner "{0}" befinden sich noch Dateien \nVerschieben Sie sie manuell an einen neuen Ort.
RetrievingDrivesList                      = Laufwerksliste abrufen...
DriveSelect                               = Wählen Sie das Laufwerk aus, in dessen Stammverzeichnis der Ordner "{0}" erstellt werden soll.
CurrentUserFolderLocation                 = Der aktuelle Speicherort des Ordners "{0}" lautet: "{1}".
UserFolderRequest                         = Möchten Sie den Speicherort des Ordners "{0}" ändern?
UserDefaultFolder                         = Möchten Sie den Speicherort des Ordners "{0}" auf den Standardwert ändern?
ReservedStorageIsInUse                    = Dieser Vorgang wird nicht unterstützt, wenn reservierter Speicher verwendet wird\nBitte führen Sie die Funktion "{0}" nach dem PC-Neustart erneut aus.
ShortcutPinning                           = Die Verknüpfung "{0}" wird an Start angeheftet...
SSDRequired                               = Um Windows Subsystem für Android™ auf Ihrem Gerät zu verwenden, muss auf Ihrem PC ein Solid State Drive (SSD) installiert sein.
UninstallUWPForAll                        = Für alle Benutzer
UWPAppsTitle                              = UWP-Apps
HEVCDownloading                           = HEVC-Videoerweiterungen vom Gerätehersteller herunterladen...
GraphicsPerformanceTitle                  = Möchten Sie die Einstellung der Grafikleistung einer App Ihrer Wahl auf "Hohe Leistung" einstellen?
ActionCenter                              = Um die Funktion "{0}" nutzen zu können, müssen Sie das Action Center aktivieren.
WindowsScriptHost                         = Der Zugriff auf Windows Script Host wurde für diesem Computer deaktiviert. Um die Funktion "{0}" nutzen zu können, müssen Sie den Windows Script Host aktivieren.
ScheduledTaskPresented                    = Die Funktion "{0}" wurde bereits als "{1}" angelegt.
CleanupTaskNotificationTitle              = Windows aufräumen
CleanupTaskNotificationEvent              = Aufgabe zum Bereinigen nicht verwendeter Windows-Dateien und -Updates ausführen?
CleanupTaskDescription                    = Bereinigung von nicht verwendeten Windows-Dateien und Updates mit der integrierten Festplattenbereinigung.
CleanupNotificationTaskDescription        = Popup-Benachrichtigung zur Erinnerung an die Bereinigung von nicht verwendeten Windows-Dateien und Updates.
SoftwareDistributionTaskNotificationEvent = Der Windows Update-Cache wurde erfolgreich gelöscht.
TempTaskNotificationEvent                 = Der Ordner mit den temporären Dateien wurde erfolgreich bereinigt.
FolderTaskDescription                     = Ordner "{0}" bereinigen.
EventViewerCustomViewName                 = Prozesserstellung
EventViewerCustomViewDescription          = Prozesserstellungen und Befehlszeilen-Auditing-Ereignisse.
RestartWarning                            = Sicherstellen, dass Sie Ihren PC neu starten.
ErrorsLine                                = Zeile
ErrorsMessage                             = Fehler/Warnungen
DialogBoxOpening                          = Anzeigen des Dialogfensters...
Disable                                   = Deaktivieren
Enable                                    = Aktivieren
AllFilesFilter                            = Alle Dateien
FolderSelect                              = Einen Ordner auswählen
FilesWontBeMoved                          = Dateien werden nicht verschoben.
Install                                   = Installieren
NoData                                    = Nichts anzuzeigen.
NoInternetConnection                      = Keine Internetverbindung.
RestartFunction                           = Bitte die Funktion "{0}" neustarten.
NoResponse                                = Eine Verbindung mit {0} konnte nicht hergestellt werden.
Restore                                   = Wiederherstellen
Run                                       = Starten
Skipped                                   = Übersprungen.
GPOUpdate                                 = GPO-Aktualisierung...
TelegramGroupTitle                        = Treten Sie unserer offiziellen Telegram-Gruppe bei.
TelegramChannelTitle                      = Treten Sie unserem offiziellen Telegram-Kanal bei.
DiscordChannelTitle                       = Treten Sie unserem offiziellen Discord-Kanal bei.
Uninstall                                 = Deinstallieren
'@

# SIG # Begin signature block
# MIIblwYJKoZIhvcNAQcCoIIbiDCCG4QCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUN5+8NYpJwbEQCJxmZC1rFHNe
# 92WgghYPMIIDAjCCAeqgAwIBAgIQaCN8KfrjD6BOk5DiIPWouTANBgkqhkiG9w0B
# AQsFADAZMRcwFQYDVQQDDA5Tb3BoaWEgUHJvamVjdDAeFw0yMzA5MTcxNzU1Mjha
# Fw0yNTA5MTcxODA0NTdaMBkxFzAVBgNVBAMMDlNvcGhpYSBQcm9qZWN0MIIBIjAN
# BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyX2JF3ExXjGKMrUp79D6hyQXY+zu
# MQU6qtebkcjxlnOjlQf7PJdXi7PwxxuuCJWiDGTuGB+hUTXPE6DJWzJNWEfXI3aH
# c32Ps7RCPg8Aviy7zdLx+zHGJ328fXXvRMyCSmAqA05cxuRYMmiak7yQ1egVtH+a
# iQj2P4WeuX8QntM3k1v0YGIdUWCW4lPMw3seWXCS0cf+R8Je6l8H+dgrzIkQdJSb
# vfF9n356lfRx8fk/eG21Zm3yINQTz1uC6sHu+Zp1azQu97IPvEbEilXwiVV9w00k
# 3jRej4TFpNYinxnf/MVqe0qgU7eV95OAYpi8a9gn/bqj99uS+W0LR+yrYQIDAQAB
# o0YwRDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwHQYDVR0O
# BBYEFFTlv/SckttupzhAMIJfxGGz0oVmMA0GCSqGSIb3DQEBCwUAA4IBAQAPuSjM
# EmxBPRqAtZZKBlvpqZ+43+phpn/MXwLjRpdSJg7L9K/vPUuh+N2oPjX4VoRKT3kj
# zL4/kfGX7cS8H1o4GyljrxKcrrbPFRgsZ5tjqqBBEqAh5cGnkJhALy8Tftx2a6Jd
# Yd2ZxwoaFZiRPNZiAQoyIFbUnf607mNxKYQKMyE1rbDF0UIBCt1ZKSSHMW+K7/uu
# TRaaJYzy1fBPkrDMO8jUDcFq5cFGiQH3G+fao2uKUp99oWTGxWi2U+n41rGIRo5i
# kK2LoxucRaIdxMRoh3+Qw/dN2CxEckkboAdfuByigeyhq3kcoiB00WrR3uMzeKTS
# /oPtgG2zf3WMkUttMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkq
# hkiG9w0BAQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5j
# MRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBB
# c3N1cmVkIElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5
# WjBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQL
# ExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJv
# b3QgRzQwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1K
# PDAiMGkz7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2r
# snnyyhHS5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C
# 8weE5nQ7bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBf
# sXpm7nfISKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGY
# QJB5w3jHtrHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8
# rhsDdV14Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaY
# dj1ZXUJ2h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+
# wJS00mFt6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw
# ++hkpjPRiQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+N
# P8m800ERElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7F
# wI+isX4KJpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUw
# AwEB/zAdBgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAU
# Reuir/SSy4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEB
# BG0wazAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsG
# AQUFBzAChjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1
# cmVkSURSb290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRp
# Z2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAow
# CDAGBgRVHSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/
# Vwe9mqyhhyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLe
# JLxSA8hO0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE
# 1Od/6Fmo8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9Hda
# XFSMb++hUD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbO
# byMt9H5xaiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIG
# rjCCBJagAwIBAgIQBzY3tyRUfNhHrP0oZipeWzANBgkqhkiG9w0BAQsFADBiMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQw
# HhcNMjIwMzIzMDAwMDAwWhcNMzcwMzIyMjM1OTU5WjBjMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0
# ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMIICIjANBgkqhkiG
# 9w0BAQEFAAOCAg8AMIICCgKCAgEAxoY1BkmzwT1ySVFVxyUDxPKRN6mXUaHW0oPR
# nkyibaCwzIP5WvYRoUQVQl+kiPNo+n3znIkLf50fng8zH1ATCyZzlm34V6gCff1D
# tITaEfFzsbPuK4CEiiIY3+vaPcQXf6sZKz5C3GeO6lE98NZW1OcoLevTsbV15x8G
# ZY2UKdPZ7Gnf2ZCHRgB720RBidx8ald68Dd5n12sy+iEZLRS8nZH92GDGd1ftFQL
# IWhuNyG7QKxfst5Kfc71ORJn7w6lY2zkpsUdzTYNXNXmG6jBZHRAp8ByxbpOH7G1
# WE15/tePc5OsLDnipUjW8LAxE6lXKZYnLvWHpo9OdhVVJnCYJn+gGkcgQ+NDY4B7
# dW4nJZCYOjgRs/b2nuY7W+yB3iIU2YIqx5K/oN7jPqJz+ucfWmyU8lKVEStYdEAo
# q3NDzt9KoRxrOMUp88qqlnNCaJ+2RrOdOqPVA+C/8KI8ykLcGEh/FDTP0kyr75s9
# /g64ZCr6dSgkQe1CvwWcZklSUPRR8zZJTYsg0ixXNXkrqPNFYLwjjVj33GHek/45
# wPmyMKVM1+mYSlg+0wOI/rOP015LdhJRk8mMDDtbiiKowSYI+RQQEgN9XyO7ZONj
# 4KbhPvbCdLI/Hgl27KtdRnXiYKNYCQEoAA6EVO7O6V3IXjASvUaetdN2udIOa5kM
# 0jO0zbECAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYE
# FLoW2W1NhS9zKXaaL3WMaiCPnshvMB8GA1UdIwQYMBaAFOzX44LScV1kTN8uZz/n
# upiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAKBggrBgEFBQcDCDB3Bggr
# BgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNv
# bTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lD
# ZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDovL2Ny
# bDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcmwwIAYDVR0g
# BBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQB9
# WY7Ak7ZvmKlEIgF+ZtbYIULhsBguEE0TzzBTzr8Y+8dQXeJLKftwig2qKWn8acHP
# HQfpPmDI2AvlXFvXbYf6hCAlNDFnzbYSlm/EUExiHQwIgqgWvalWzxVzjQEiJc6V
# aT9Hd/tydBTX/6tPiix6q4XNQ1/tYLaqT5Fmniye4Iqs5f2MvGQmh2ySvZ180HAK
# fO+ovHVPulr3qRCyXen/KFSJ8NWKcXZl2szwcqMj+sAngkSumScbqyQeJsG33irr
# 9p6xeZmBo1aGqwpFyd/EjaDnmPv7pp1yr8THwcFqcdnGE4AJxLafzYeHJLtPo0m5
# d2aR8XKc6UsCUqc3fpNTrDsdCEkPlM05et3/JWOZJyw9P2un8WbDQc1PtkCbISFA
# 0LcTJM3cHXg65J6t5TRxktcma+Q4c6umAU+9Pzt4rUyt+8SVe+0KXzM5h0F4ejjp
# nOHdI/0dKNPH+ejxmF/7K9h+8kaddSweJywm228Vex4Ziza4k9Tm8heZWcpw8De/
# mADfIBZPJ/tgZxahZrrdVcA6KYawmKAr7ZVBtzrVFZgxtGIJDwq9gdkT/r+k0fNX
# 2bwE+oLeMt8EifAAzV3C+dAjfwAL5HYCJtnwZXZCpimHCUcr5n8apIUP/JiW9lVU
# Kx+A+sDyDivl1vupL0QVSucTDh3bNzgaoSv27dZ8/DCCBsIwggSqoAMCAQICEAVE
# r/OUnQg5pr/bP1/lYRYwDQYJKoZIhvcNAQELBQAwYzELMAkGA1UEBhMCVVMxFzAV
# BgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVk
# IEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFtcGluZyBDQTAeFw0yMzA3MTQwMDAw
# MDBaFw0zNDEwMTMyMzU5NTlaMEgxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjEgMB4GA1UEAxMXRGlnaUNlcnQgVGltZXN0YW1wIDIwMjMwggIi
# MA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCjU0WHHYOOW6w+VLMj4M+f1+XS
# 512hDgncL0ijl3o7Kpxn3GIVWMGpkxGnzaqyat0QKYoeYmNp01icNXG/OpfrlFCP
# HCDqx5o7L5Zm42nnaf5bw9YrIBzBl5S0pVCB8s/LB6YwaMqDQtr8fwkklKSCGtpq
# utg7yl3eGRiF+0XqDWFsnf5xXsQGmjzwxS55DxtmUuPI1j5f2kPThPXQx/ZILV5F
# dZZ1/t0QoRuDwbjmUpW1R9d4KTlr4HhZl+NEK0rVlc7vCBfqgmRN/yPjyobutKQh
# ZHDr1eWg2mOzLukF7qr2JPUdvJscsrdf3/Dudn0xmWVHVZ1KJC+sK5e+n+T9e3M+
# Mu5SNPvUu+vUoCw0m+PebmQZBzcBkQ8ctVHNqkxmg4hoYru8QRt4GW3k2Q/gWEH7
# 2LEs4VGvtK0VBhTqYggT02kefGRNnQ/fztFejKqrUBXJs8q818Q7aESjpTtC/XN9
# 7t0K/3k0EH6mXApYTAA+hWl1x4Nk1nXNjxJ2VqUk+tfEayG66B80mC866msBsPf7
# Kobse1I4qZgJoXGybHGvPrhvltXhEBP+YUcKjP7wtsfVx95sJPC/QoLKoHE9nJKT
# BLRpcCcNT7e1NtHJXwikcKPsCvERLmTgyyIryvEoEyFJUX4GZtM7vvrrkTjYUQfK
# lLfiUKHzOtOKg8tAewIDAQABo4IBizCCAYcwDgYDVR0PAQH/BAQDAgeAMAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwIAYDVR0gBBkwFzAIBgZn
# gQwBBAIwCwYJYIZIAYb9bAcBMB8GA1UdIwQYMBaAFLoW2W1NhS9zKXaaL3WMaiCP
# nshvMB0GA1UdDgQWBBSltu8T5+/N0GSh1VapZTGj3tXjSTBaBgNVHR8EUzBRME+g
# TaBLhklodHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRS
# U0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3JsMIGQBggrBgEFBQcBAQSBgzCB
# gDAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMFgGCCsGAQUF
# BzAChkxodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVk
# RzRSU0E0MDk2U0hBMjU2VGltZVN0YW1waW5nQ0EuY3J0MA0GCSqGSIb3DQEBCwUA
# A4ICAQCBGtbeoKm1mBe8cI1PijxonNgl/8ss5M3qXSKS7IwiAqm4z4Co2efjxe0m
# gopxLxjdTrbebNfhYJwr7e09SI64a7p8Xb3CYTdoSXej65CqEtcnhfOOHpLawkA4
# n13IoC4leCWdKgV6hCmYtld5j9smViuw86e9NwzYmHZPVrlSwradOKmB521BXIxp
# 0bkrxMZ7z5z6eOKTGnaiaXXTUOREEr4gDZ6pRND45Ul3CFohxbTPmJUaVLq5vMFp
# GbrPFvKDNzRusEEm3d5al08zjdSNd311RaGlWCZqA0Xe2VC1UIyvVr1MxeFGxSjT
# redDAHDezJieGYkD6tSRN+9NUvPJYCHEVkft2hFLjDLDiOZY4rbbPvlfsELWj+MX
# kdGqwFXjhr+sJyxB0JozSqg21Llyln6XeThIX8rC3D0y33XWNmdaifj2p8flTzU8
# AL2+nCpseQHc2kTmOt44OwdeOVj0fHMxVaCAEcsUDH6uvP6k63llqmjWIso765qC
# NVcoFstp8jKastLYOrixRoZruhf9xHdsFWyuq69zOuhJRrfVf8y2OMDY7Bz1tqG4
# QyzfTkx9HmhwwHcK1ALgXGC7KP845VJa1qwXIiNO9OzTF/tQa/8Hdx9xl0RBybhG
# 02wyfFgvZ0dl5Rtztpn5aywGRu9BHvDwX+Db2a2QgESvgBBBijGCBPIwggTuAgEB
# MC0wGTEXMBUGA1UEAwwOU29waGlhIFByb2plY3QCEGgjfCn64w+gTpOQ4iD1qLkw
# CQYFKw4DAhoFAKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcN
# AQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUw
# IwYJKoZIhvcNAQkEMRYEFLYKHfaYBaaodhE/bTpcZ46Wq1QfMA0GCSqGSIb3DQEB
# AQUABIIBACvlaeg6AcVpUH3O7UDN9cb4kLWc4/FDSVvdap8Sge2McLtj+pEF+o76
# PHImnlEo798OzVJ59FTWGNc78+qUO1YJ4WmJ5UAvv5yDsboziHRImxMNO6xXY/LN
# txsz4zGsVUZAxkFALmUKRi83hjwqB53Lb+YT/lNgMS7vVP/31g2kC+I8W6gPj1uC
# /f0GJNPJwgQ0P0NcPIDzEqpGpX/zaqjjetbXjH/Mcr8M2vYJPxSA1/3ZTpDrRY31
# 6S5URIMzDu4UnHvyQ9QXJUU5BgjlZD9Y7SYCtzTKcL+S8fWoYsmKnnqpjKgFuXh1
# oU6uQopf2PUkv6ZVzi944unOjfNAIh+hggMgMIIDHAYJKoZIhvcNAQkGMYIDDTCC
# AwkCAQEwdzBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4x
# OzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGlt
# ZVN0YW1waW5nIENBAhAFRK/zlJ0IOaa/2z9f5WEWMA0GCWCGSAFlAwQCAQUAoGkw
# GAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjMwOTE3
# MTgwNTMzWjAvBgkqhkiG9w0BCQQxIgQgmDhT9UymEnHuuT09Xo/yLXXkqL9JaHwW
# 9r41GOYqHRQwDQYJKoZIhvcNAQEBBQAEggIAPajeduNbevStznqN7oee/Y7Ov7eQ
# GW+qYJ+3ACPNHf9PKPMcmnWo4HElq60PuDDipHu+r+5s0TlPguFTciiqKDHfD+uZ
# Pf6XOe8FENC7+D7FLd7urBB9oobwT4eGGksZSHYhEGexfNhpyF/a23umo8rQZcBm
# mwoG3BJq5y2PewvL8c+sB0iRrDchfv+uFrQj/uJfCKUdL6gAkbTvNfn5CJ55Mz//
# 6ocMjF9ZxTBEoQ3p50dojAFt7754LdoJa9Ecy/GQcdVc0+7MkFYVnVwDdsGBXhQP
# RGInUO3QdPJR1QyMJYRWExeF+f36bI/Vi1CmEQLVf4olJiAYfkKPXUHuyZgLSCnL
# 7gKdwBBcsN4QjOYnTvhrfRXMJ0613QKk+UkP3bUaCqGCS4aYKW+5wWEF7RGlOET2
# DgFjcUKRh9cy8ATWRDdZ6Bsi6nP5XdDc8T5NK3dk7GQgeP5YtP5W/lQ2mgfp/s2G
# C1CuYcUYgsRuQZ1I8Y71aN6+i5G6u6DrtTxysf5kPj0hbiFwRjkfLDbGrDsR8Xoa
# zxupzTSJsa556syrmHhb3ZznbblOKHw8j/BPZUAv7StAoIqiSx545Ld1muNJVhFV
# P/2ILUnFwTMdROv2WIyTAXdIflPHrzLESbIzJ6NQ7oUvci757+S2c89TN/OeNCjS
# F43UtiT/nB7ZS/A=
# SIG # End signature block
