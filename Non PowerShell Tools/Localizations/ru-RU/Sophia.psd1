ConvertFrom-StringData -StringData @'
UnsupportedOSBuild                        = Скрипт поддерживает Windows 11 22H2+.
UpdateWarning                             = Ваш билд Windows 11: {0}.{1}. Поддерживаемые сборки: 22621.1992+. Запустите обновление Windows и попробуйте заново.
UnsupportedLanguageMode                   = Сессия PowerShell работает в ограниченном режиме.
LoggedInUserNotAdmin                      = Текущий вошедший пользователь не обладает правами администратора.
UnsupportedPowerShell                     = Вы пытаетесь запустить скрипт в PowerShell {0}.{1}. Запустите скрипт в соответствующей версии PowerShell.
UnsupportedHost                           = Скрипт не поддерживает работу через {0}.
Win10TweakerWarning                       = Ваша ОС, возможно, через бэкдор в Win 10 Tweaker была заражена трояном.
TweakerWarning                            = Стабильность Windows могла быть нарушена использованием {0}. На всякий случай переустановите Windows.
bin                                       = В папке bin отсутствуют файлы. Пожалуйста, перекачайте архив.
RebootPending                             = Компьютер ожидает перезагрузки.
UnsupportedRelease                        = Обнаружена новая версия.
KeyboardArrows                            = Для выбора используйте на клавиатуре стрелки {0} и {1}
CustomizationWarning                      = Вы настроили все функции в пресет-файле {0} перед запуском Sophia Script?
WindowsComponentBroken                    = {0} сломан или удален из ОС.
UpdateDefender                            = Определения Microsoft Defender устарели. Запустите обновление Windows.
ControlledFolderAccessDisabled            = Контролируемый доступ к папкам выключен.
ScheduledTasks                            = Запланированные задания
OneDriveUninstalling                      = Удаление OneDrive...
OneDriveInstalling                        = OneDrive устанавливается...
OneDriveDownloading                       = Скачивается OneDrive...
OneDriveWarning                           = Функция "{0}" будет применена только в случае, если в пресете настроено удаление OneDrive (или приложение уже удалено), иначе ломается функционал резервного копирования для папок "Рабочий стол" и "Изображения" в OneDrive.
WindowsFeaturesTitle                      = Компоненты Windows
OptionalFeaturesTitle                     = Дополнительные компоненты
EnableHardwareVT                          = Включите виртуализацию в UEFI.
UserShellFolderNotEmpty                   = В папке "{0}" остались файлы. Переместите их вручную в новое расположение.
RetrievingDrivesList                      = Получение списка дисков...
DriveSelect                               = Выберите диск, в корне которого будет создана папка "{0}".
CurrentUserFolderLocation                 = Текущее расположение папки "{0}": "{1}".
UserFolderRequest                         = Хотите изменить расположение папки "{0}"?
UserDefaultFolder                         = Хотите изменить расположение папки "{0}" на значение по умолчанию?
ReservedStorageIsInUse                    = Операция не поддерживается, пока используется зарезервированное хранилище\nПожалуйста, повторно запустите функцию "{0}" после перезагрузки.
ShortcutPinning                           = Ярлык "{0}" закрепляется на начальном экране...
SSDRequired                               = Чтобы использовать подсистему Windows для Android™ на вашем ПК должен быть установлен твердотельный накопитель (SSD).
UninstallUWPForAll                        = Для всех пользователей
UWPAppsTitle                              = UWP-приложения
HEVCDownloading                           = Скачивается расширение "Расширения для видео HEVC от производителя устройства"...
GraphicsPerformanceTitle                  = Установить для любого приложения по вашему выбору настройки производительности графики на "Высокая производительность"?
ActionCenter                              = Чтобы использовать функцию "{0}" вам необходимо включить центр уведомлений.
WindowsScriptHost                         = На данном компьютере отключен доступ к серверу сценариев Windows. Чтобы использовать функцию "{0}", вам необходимо включить сервер сценариев Windows.
ScheduledTaskPresented                    = Функция "{0}" уже была создана от имени "{1}".
CleanupTaskNotificationTitle              = Очистка Windows
CleanupTaskNotificationEvent              = Запустить задание по очистке неиспользуемых файлов и обновлений Windows?
CleanupTaskDescription                    = Очистка неиспользуемых файлов и обновлений Windows, используя встроенную программу Очистка диска.
CleanupNotificationTaskDescription        = Всплывающее уведомление с напоминанием об очистке неиспользуемых файлов и обновлений Windows.
SoftwareDistributionTaskNotificationEvent = Кэш обновлений Windows успешно удален.
TempTaskNotificationEvent                 = Папка временных файлов успешно очищена.
FolderTaskDescription                     = Очистка папки {0}.
EventViewerCustomViewName                 = Создание процесса
EventViewerCustomViewDescription          = События создания нового процесса и аудит командной строки.
RestartWarning                            = Обязательно перезагрузите ваш ПК.
ErrorsLine                                = Строка
ErrorsMessage                             = Ошибки/предупреждения
DialogBoxOpening                          = Диалоговое окно открывается...
Disable                                   = Отключить
AllFilesFilter                            = Все файлы
FolderSelect                              = Выберите папку
FilesWontBeMoved                          = Файлы не будут перенесены.
Install                                   = Установить
NoData                                    = Отсутствуют данные.
NoInternetConnection                      = Отсутствует интернет-соединение.
RestartFunction                           = Пожалуйста, повторно запустите функцию "{0}".
NoResponse                                = Невозможно установить соединение с {0}.
Restore                                   = Восстановить
Run                                       = Запустить
Skipped                                   = Пропущено.
GPOUpdate                                 = Обновление GPO...
TelegramGroupTitle                        = Присоединяйтесь к нашей официальной группе в Telegram.
TelegramChannelTitle                      = Присоединяйтесь к нашему официальному каналу в Telegram.
DiscordChannelTitle                       = Присоединяйтесь к нашему официальному каналу в Discord.
Uninstall                                 = Удалить
'@

# SIG # Begin signature block
# MIIblQYJKoZIhvcNAQcCoIIbhjCCG4ICAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU5hh9RLZV/RI/5AWYWvVkyAmr
# QB6gghYNMIIDAjCCAeqgAwIBAgIQaksVnyyz84NPdVUTWD8u7zANBgkqhkiG9w0B
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
# CSqGSIb3DQEJBDEWBBS+VFdOpuQ1PYshNoIeDWFeMPKItjANBgkqhkiG9w0BAQEF
# AASCAQBa6UDH77NStS++yZ9birpugaOE++4z17OH6mUGf3XP1XlsXUKl9RXWHcsL
# 6ZXdqKZ47Z2pQ8kbWL+WSXuklJ9/SVwXJ0uXNfXhTobuW1KtE2rQZfUyhpJoihBK
# z3TANGnMWhQbNlwOPMagcxsyGg+afJBVrE/pf2SmoBhL3CjpePUokF8yTZfyJZ5u
# LO/qCr9yKKlwbjxmdwiO77qYa1pPkihoXtMIO4Fz7ftJboJtdKdXU8H58dDv1qLP
# OPe7O4mzzdHXrP7ZJQNwM8sAcoe2T3D3tdc4R4HrX6sjnkuV+cVYK5DGdMT3oQ5r
# yeWaRdfYjM+/sGYR1gu63sje2oV6oYIDIDCCAxwGCSqGSIb3DQEJBjGCAw0wggMJ
# AgEBMHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTsw
# OQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYgU0hBMjU2IFRpbWVT
# dGFtcGluZyBDQQIQDE1pckuU+jwqSj0pB4A9WjANBglghkgBZQMEAgEFAKBpMBgG
# CSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTIzMDcxNjE3
# MjAzMlowLwYJKoZIhvcNAQkEMSIEIKWrQGTumdhaz5BQEaq12YZv+sbCj26+AkvR
# 5sXCHFwEMA0GCSqGSIb3DQEBAQUABIICADQ/JzAXTJEy71QS4Rz8GFW0Uk+85Mf/
# 3s+C1y7uOZGQKm8muvochaNt7DJtKbRpihlP+3vnr1qA1QpvRgi6CA2xkH0tguJt
# ezrjPzpvpwYF5E0Hz6xiLXyu4tyXxYlp1H59/3H+jwGee/+K7GhgV7LRVk3p3cXl
# eekoaK1nJ6MhzrepkRrupfRNm3u5pL3solEPiXU8JnP/nN4gNhrbeCA33Wh9afVp
# qdvYPFtVbcgvkUtzZ9vFs/V8fuFAYQFx4uuP8zwP9gQerECDH97I88AyTV9pSjLj
# ki7rb6M8LtmPP9dVAAemRMll1NJS2AjqLWre8fw2elJrp4kNl3tcZGGMBh9snXuI
# GmOC3/HiULyWMAjVciwW/OanMYonsJc7lZGajT3B/IK2gx7j5K3J8Yx0y+5azyu3
# OjQe/27rrQi/l4jAsXgXujwOKZe23vDxtjB271rgJl9/xwbVSRoRS5fjy4sAfAv3
# FJWEInKRaTuo43z9IFEYp6psmRi4gMsL2em6BB49Yj4mun4QMs50k2iyvwIjZ792
# 0Guvm3NO2UvGK7j6E+sIdP1pi9MqQqu02O1E+IYW2473vqnB1tsPJ4w9iv+GPbh5
# fmJ47dxunLnF6WeioqQE/9CwjDPL9NCURvDeNwXca63ez6v6pxaZiBG5uRItrHGu
# kcrOrJWK6eDL
# SIG # End signature block
