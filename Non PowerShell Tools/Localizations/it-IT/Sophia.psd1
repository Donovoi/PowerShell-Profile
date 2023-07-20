ConvertFrom-StringData -StringData @'
UnsupportedOSBuild                        = Lo script supporta Windows 11 22H2+.
UpdateWarning                             = La tua build di Windows 11 {0}.{1} non è supportata. Build supportate: 22621.1992+. Eseguire Windows Update e riprovare.
UnsupportedLanguageMode                   = La sessione PowerShell è in esecuzione in modalità lingua limitata.
LoggedInUserNotAdmin                      = L'utente in suo non ha i diritti di amministratore.
UnsupportedPowerShell                     = Stai cercando di eseguire lo script tramite PowerShell {0}.{1}. Esegui lo script nella versione di PowerShell appropriata.
UnsupportedHost                           = Lo script non supporta l'esecuzione tramite {0}.
Win10TweakerWarning                       = Probabilmente il tuo sistema operativo è stato infettato tramite una backdoor in Win 10 Tweaker.
TweakerWarning                            = La stabilità del sistema operativo Windows potrebbe essere stata compromessa dall'utilizzo dello {0}. Per sicurezza, reinstallare Windows.
bin                                       = Non ci sono file nella cartella bin. Per favore, scarica di nuovo l'archivio.
RebootPending                             = Il PC è in attesa di essere riavviato.
UnsupportedRelease                        = Nuova versione trovata.
KeyboardArrows                            = Per selezionare la risposta, utilizzare i tasti freccia "{0}" e "{1}" della tastiera
CustomizationWarning                      = Sono state personalizzate tutte le funzioni nel file di configurazione {0} prima di eseguire Sophia Script?
WindowsComponentBroken                    = {0} rimosso dal sistema.
UpdateDefender                            = Le definizioni di Microsoft Defender non sono aggiornate. Eseguire Windows Update e riprovare.
ControlledFolderAccessDisabled            = l'accesso alle cartelle controllata disattivata.
ScheduledTasks                            = Attività pianificate
OneDriveUninstalling                      = Disinstallazione di OneDrive...
OneDriveInstalling                        = Installazione di OneDrive...
OneDriveDownloading                       = Download di OneDrive...
OneDriveWarning                           = La funzione "{0}" sarà applicata solo se il preset è configurato per rimuovere OneDrive (o se l'app è già stata rimossa), altrimenti la funzionalità di backup per le cartelle "Desktop" e "Pictures" in OneDrive si interromperà.
WindowsFeaturesTitle                      = Funzionalità di Windows
OptionalFeaturesTitle                     = Caratteristiche opzionali
EnableHardwareVT                          = Abilita virtualizzazione in UEFI.
UserShellFolderNotEmpty                   = Alcuni file rimasti nella cartella "{0}". Spostali manualmente in una nuova posizione.
RetrievingDrivesList                      = Recupero lista unità...
DriveSelect                               = Selezionare l'unità all'interno della radice del quale verrà creato la cartella "{0}" .
CurrentUserFolderLocation                 = La posizione attuale della cartella "{0}": "{1}".
UserFolderRequest                         = Volete cambiare la posizione della cartella "{0}"?
UserDefaultFolder                         = Volete cambiare la posizione della cartella "{0}" al valore di default?
ReservedStorageIsInUse                    = Questa operazione non è supportata quando spazio riservato è in uso Si prega di eseguire nuovamente la funzione "{0}" dopo il riavvio del PC.
ShortcutPinning                           = Il collegamento "{0}" è stato bloccato...
SSDRequired                               = Per utilizzare Windows Subsystem for Android™ sul proprio dispositivo, è necessario che sul PC sia installata un'unità a stato solido (SSD).
UninstallUWPForAll                        = Per tutti gli utenti
UWPAppsTitle                              = UWP Apps
HEVCDownloading                           = Download del codec video HEVC Video estenxion dal produttore...
GraphicsPerformanceTitle                  = Volete impostare l'impostazione delle prestazioni grafiche di un app di vostra scelta a "Prestazioni elevate"?
ActionCenter                              = Per utilizzare la funzione "{0}" è necessario attivare il Centro operativo.
WindowsScriptHost                         = Accesso a Windows Script Host disabilitato sul computer in uso. Per utilizzare la funzione "{0}" è necessario abilitare Windows Script Host.
ScheduledTaskPresented                    = La funzione "{0}" è già stata creata come "{1}".
CleanupTaskNotificationTitle              = Pulizia di Windows
CleanupTaskNotificationEvent              = Eseguire l'operazione di pulizia dei file inutilizzati e aggiornamenti di Windows?
CleanupTaskDescription                    = Pulizia di Windows e dei file inutilizzati degli aggiornamenti utilizzando l'app built-in ""pulizia disco".
CleanupNotificationTaskDescription        = Pop-up promemoria di pulizia dei file inutilizzati e degli aggiornamenti di Windows.
SoftwareDistributionTaskNotificationEvent = La cache degli aggiornamenti di Windows cancellata con successo.
TempTaskNotificationEvent                 = I file cartella Temp puliti con successo.
FolderTaskDescription                     = Pulizia della cartella "{0}".
EventViewerCustomViewName                 = Creazione del processo
EventViewerCustomViewDescription          = Creazione del processi e degli eventi di controllo della riga di comando.
RestartWarning                            = Assicurarsi di riavviare il PC.
ErrorsLine                                = Linea
ErrorsMessage                             = Errori/avvisi
DialogBoxOpening                          = Visualizzazione della finestra di dialogo...
Disable                                   = Disattivare
AllFilesFilter                            = Tutti i file
FolderSelect                              = Selezionare una cartella
FilesWontBeMoved                          = I file non verranno trasferiti.
Install                                   = Installare
NoData                                    = Niente da esposizione.
NoInternetConnection                      = Nessuna connessione Internet.
RestartFunction                           = Si prega di riavviare la funzione "{0}".
NoResponse                                = Non è stato possibile stabilire una connessione con {0}.
Restore                                   = Ristabilire
Run                                       = Eseguire
Skipped                                   = Saltato.
GPOUpdate                                 = Aggiornamento GPO...
TelegramGroupTitle                        = Unisciti al nostro gruppo ufficiale Telegram.
TelegramChannelTitle                      = Unisciti al nostro canale ufficiale di Telegram.
DiscordChannelTitle                       = Unisciti al nostro canale ufficiale di Discord.
Uninstall                                 = Disinstallare
'@

# SIG # Begin signature block
# MIIblQYJKoZIhvcNAQcCoIIbhjCCG4ICAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUF2bfRqCPgwgLBogVhbwlbRnz
# IsigghYNMIIDAjCCAeqgAwIBAgIQaksVnyyz84NPdVUTWD8u7zANBgkqhkiG9w0B
# AQsFADAZMRcwFQYDVQQDDA5Tb3BoaWEgUHJvamVjdDAeFw0yMzA3MTYxNzEwMjJa
# Fw0yNTA3MTYxNzE5NTBaMBkxFzAVBgNVBAMMDlNvcGhpYSBQcm9qZWN0MIIBIjAN
# BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApicz5jh8o7haSVVBc1LCYPa09UJh
# v9J52gmBcJHyq+sFrgyZvzY5IlLbAfk/VnlyADVKKbr6qc6dhT0BCjTraLAPxLEZ
# dG3GQU9ROwyKom6qdS933uWdQP/GA6miccGxLIVia6eYfLi7WYmFI3NLtXQTs9EO
# EXQTNDuFCl3KN0/CQUiRe1Ye5/tpzFdSq33tcFVuJ/+AkTV3dJTOjafwv3Zejv8e
# isuGAtjaJSti4kGCry8iQLQVfbIUk+gX+39djvug/aZ1LwrMisn6oSO8f8aJoOhg
# PsaQUsPu2j8griGCtC7Wa+sWlBkK5rpeZme6E019qP1dQCIC9Bb2aU+3jQIDAQAB
# o0YwRDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMwHQYDVR0O
# BBYEFBDjDCjlL9oTkLaBglE0uU6zFaLiMA0GCSqGSIb3DQEBCwUAA4IBAQB2RyYn
# B5dCJUJC8WtfweY5eBb4K8IEf23N8dfktjsARnZ6zmG+3ggkABsHWVS392HGMLdW
# r8a2iiqkwZy1TsZl6Y+WfWbaGPnPpBVuVtxe7dC9bsm+5EQObDvFj2msFmgHyDKn
# mSAiu8Qp0SpXFoR6Q3Qkkehhcsp8M4ijQRTpl92fu6EQuJ+1B+2QJRd/DV9Jz+JY
# lkgJ+01R7oBH3HHzfg33DaLLlnOmEpte8SFOYQR3/lv2uOnHrq0KFUQZCk4RJBie
# gcDQdEy5mwQlBzTrF55iu6MU7HV8SS2ehUFcVDVq5B54Z7LzFIo8a7DlBXLr8yhQ
# 3OaYIlpoe8rzQ6IQMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkq
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
# Kx+A+sDyDivl1vupL0QVSucTDh3bNzgaoSv27dZ8/DCCBsAwggSooAMCAQICEAxN
# aXJLlPo8Kko9KQeAPVowDQYJKoZIhvcNAQELBQAwYzELMAkGA1UEBhMCVVMxFzAV
# BgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVk
# IEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVTdGFtcGluZyBDQTAeFw0yMjA5MjEwMDAw
# MDBaFw0zMzExMjEyMzU5NTlaMEYxCzAJBgNVBAYTAlVTMREwDwYDVQQKEwhEaWdp
# Q2VydDEkMCIGA1UEAxMbRGlnaUNlcnQgVGltZXN0YW1wIDIwMjIgLSAyMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAz+ylJjrGqfJru43BDZrboegUhXQz
# Gias0BxVHh42bbySVQxh9J0Jdz0Vlggva2Sk/QaDFteRkjgcMQKW+3KxlzpVrzPs
# YYrppijbkGNcvYlT4DotjIdCriak5Lt4eLl6FuFWxsC6ZFO7KhbnUEi7iGkMiMbx
# vuAvfTuxylONQIMe58tySSgeTIAehVbnhe3yYbyqOgd99qtu5Wbd4lz1L+2N1E2V
# hGjjgMtqedHSEJFGKes+JvK0jM1MuWbIu6pQOA3ljJRdGVq/9XtAbm8WqJqclUeG
# hXk+DF5mjBoKJL6cqtKctvdPbnjEKD+jHA9QBje6CNk1prUe2nhYHTno+EyREJZ+
# TeHdwq2lfvgtGx/sK0YYoxn2Off1wU9xLokDEaJLu5i/+k/kezbvBkTkVf826uV8
# MefzwlLE5hZ7Wn6lJXPbwGqZIS1j5Vn1TS+QHye30qsU5Thmh1EIa/tTQznQZPpW
# z+D0CuYUbWR4u5j9lMNzIfMvwi4g14Gs0/EH1OG92V1LbjGUKYvmQaRllMBY5eUu
# KZCmt2Fk+tkgbBhRYLqmgQ8JJVPxvzvpqwcOagc5YhnJ1oV/E9mNec9ixezhe7nM
# ZxMHmsF47caIyLBuMnnHC1mDjcbu9Sx8e47LZInxscS451NeX1XSfRkpWQNO+l3q
# RXMchH7XzuLUOncCAwEAAaOCAYswggGHMA4GA1UdDwEB/wQEAwIHgDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMCAGA1UdIAQZMBcwCAYGZ4EM
# AQQCMAsGCWCGSAGG/WwHATAfBgNVHSMEGDAWgBS6FtltTYUvcyl2mi91jGogj57I
# bzAdBgNVHQ4EFgQUYore0GH8jzEU7ZcLzT0qlBTfUpwwWgYDVR0fBFMwUTBPoE2g
# S4ZJaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0UlNB
# NDA5NlNIQTI1NlRpbWVTdGFtcGluZ0NBLmNybDCBkAYIKwYBBQUHAQEEgYMwgYAw
# JAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBYBggrBgEFBQcw
# AoZMaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0
# UlNBNDA5NlNIQTI1NlRpbWVTdGFtcGluZ0NBLmNydDANBgkqhkiG9w0BAQsFAAOC
# AgEAVaoqGvNG83hXNzD8deNP1oUj8fz5lTmbJeb3coqYw3fUZPwV+zbCSVEseIhj
# VQlGOQD8adTKmyn7oz/AyQCbEx2wmIncePLNfIXNU52vYuJhZqMUKkWHSphCK1D8
# G7WeCDAJ+uQt1wmJefkJ5ojOfRu4aqKbwVNgCeijuJ3XrR8cuOyYQfD2DoD75P/f
# nRCn6wC6X0qPGjpStOq/CUkVNTZZmg9U0rIbf35eCa12VIp0bcrSBWcrduv/mLIm
# lTgZiEQU5QpZomvnIj5EIdI/HMCb7XxIstiSDJFPPGaUr10CU+ue4p7k0x+GAWSc
# AMLpWnR1DT3heYi/HAGXyRkjgNc2Wl+WFrFjDMZGQDvOXTXUWT5Dmhiuw8nLw/ub
# E19qtcfg8wXDWd8nYiveQclTuf80EGf2JjKYe/5cQpSBlIKdrAqLxksVStOYkEVg
# M4DgI974A6T2RUflzrgDQkfoQTZxd639ouiXdE4u2h4djFrIHprVwvDGIqhPm73Y
# HJpRxC+a9l+nJ5e6li6FV8Bg53hWf2rvwpWaSxECyIKcyRoFfLpxtU56mWz06J7U
# WpjIn7+NuxhcQ/XQKujiYu54BNu90ftbCqhwfvCXhHjjCANdRyxjqCU4lwHSPzra
# 5eX25pvcfizM/xdMTQCi2NYBDriL7ubgclWJLCcZYfZ3AYwxggTyMIIE7gIBATAt
# MBkxFzAVBgNVBAMMDlNvcGhpYSBQcm9qZWN0AhBqSxWfLLPzg091VRNYPy7vMAkG
# BSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMG
# CSqGSIb3DQEJBDEWBBSLKa0wdqrQ4/X2x6jNNkfec3xBVTANBgkqhkiG9w0BAQEF
# AASCAQBBscWPUn7B7Jbl4TD3H5T6UDe7IyubxsrJU/w+Y3GoYQahj+p2nbTeDKrX
# tgTOaVtscnjhDsVkNiRKSsdZUHwXKJt0V21msSD6yCGuXgjV0x4HG4PiN85LHApo
# 4mxVOkitjVXUzhBKXwZY24E9NFE21iiOQby+PDP/g6ETmhyD0uM3o8NRsQm4a7w9
# 7NzCf5URNfSLKU+xwvcmku19lCCNyjtx+Tp4o06qtwNS1jqopwfRyK5Fajp6Mbz7
# FYFL6QOeWDKFzbutPKMPgIq0jlM1Xw+h8LbjIwefXUdd/8t2nOLevapfJXOi7aOt
# xvit8u0bOZQpBEvWEPSuB/Be9cQ/oYIDIDCCAxwGCSqGSIb3DQEJBjGCAw0wggMJ
# AgEBMHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTsw
# OQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVT
# dGFtcGluZyBDQQIQDE1pckuU+jwqSj0pB4A9WjANBglghkgBZQMEAgEFAKBpMBgG
# CSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTIzMDcxNjE3
# MjAzMlowLwYJKoZIhvcNAQkEMSIEIMuE2z+GxDAKsF+vk7l2Gu36pDWkMNEhirg4
# 8Itwd4GRMA0GCSqGSIb3DQEBAQUABIICAFmAL7dmFQm5w0/3TXuaeiypEEsz7DDQ
# nrVUzvibVp2Lb9gXHaiq04c8qdeIJBzii6RID5q4sTKhaoxlBwrqnh4bOBiAQKpl
# TC5N5hambJXxX2+DvKO0HmNBy8l4XRV5cVjnarbbxaSfnamtTlbQR3jZmElSv8F+
# wmnY2BhrwNKO/GP5eeATGTGz5sEtI5mZLb0k6036mxBzaJKFXIW3j23ru4Vh+y1z
# Yp1IZobNwttoRjL1ypI9FXFJM6dElNbZTlmi/RDLPoOcjEEhZsoFW7EFfyX/XwUP
# zsXXAIoOd0r/8ip1cOtEZ0onbvjfixOQulLlhpBTQML/+RPuGJ0q9fnkK13EboQc
# F+2LXIxrZPBK5rJwXpGebfIVvYO9wjMZ5JmZ/oeWm2r6IywXpVQ+aZYBmupKakOB
# PvsbplCojsZ1mJu8INBJpKfG/Na3VKyFCVnSe6EWPcB6NPpouH+q/Q331eYg1stS
# K50lSTQfIFqSlyebTY/0ILFupYb9/XRb/WhFTxWN21mX21hki8l1rmLsTw2uZUSy
# CNR685dW1mtrtjLgoe8WquN8iw5VFNxpnmwgpw/BuN5/XsGAJk06/MzeiVGqLZ7A
# oEPI8qpBB22v4XJTGbn0GVumqE6mKcpu412EVsLcyjJVVfHl3f8l7J5yMiDkyUbo
# 5Z04dTTnqzvC
# SIG # End signature block
