ConvertFrom-StringData -StringData @'
UnsupportedOSBuild                        = 脚本支持Windows 11 22H2+。
UpdateWarning                             = 您的Windows 11构建: {0}.{1}。支持的构建: 22621.2283+。运行Windows Update并再次尝试。
UnsupportedLanguageMode                   = PowerShell会话在有限的语言模式下运行。
LoggedInUserNotAdmin                      = 登录的用户没有管理员的权利。
UnsupportedPowerShell                     = 你想通过PowerShell {0}.{1}运行脚本。在适当的PowerShell版本中运行该脚本。
UnsupportedHost                           = 该脚本不支持通过{0}运行。
Win10TweakerWarning                       = 可能你的操作系统是通过"Win 10 Tweaker"后门感染的。
TweakerWarning                            = Windows的稳定性可能已被{0}所破坏。预防性地，重新安装整个操作系统。
bin                                       = bin文件夹中没有文件。请重新下载该档案。
RebootPending                             = 计算机正在等待重新启动。
UnsupportedRelease                        = 找到新版本。
KeyboardArrows                            = 请使用键盘上的方向键{0}和{1}选择您的答案
CustomizationWarning                      = 在运行Sophia Script之前，您是否已自定义{0}预设文件中的每个函数？
WindowsComponentBroken                    = {0} 损坏或从操作系统中删除。
UpdateDefender                            = Microsoft Defender的定义已经过期。运行Windows Update并再次尝试。
ControlledFolderAccessDisabled            = "受控文件夹访问"已禁用。
ScheduledTasks                            = 计划任务
OneDriveUninstalling                      = 卸载OneDrive.....
OneDriveInstalling                        = OneDrive正在安装.....
OneDriveDownloading                       = 正在下载OneDrive.....
OneDriveWarning                           = 只有当预设被配置为删除OneDrive（或应用程序已经被删除）时，才会应用"{0}"功能，否则OneDrive中 "桌面 "和 "图片 "文件夹的备份功能就会中断。
WindowsFeaturesTitle                      = Windows功能
OptionalFeaturesTitle                     = 可选功能
EnableHardwareVT                          = UEFI中开启虚拟化。
UserShellFolderNotEmpty                   = 一些文件留在了"{0}"文件夹。请手动将它们移到一个新位置。
RetrievingDrivesList                      = 取得驱动器列表.....
DriveSelect                               = 选择将在其根目录中创建"{0}"文件夹的驱动器。
CurrentUserFolderLocation                 = 当前"{0}"文件夹的位置:"{1}"。
UserFolderRequest                         = 是否要更改"{0}"文件夹位置？
UserDefaultFolder                         = 您想将"{0}"文件夹的位置更改为默认值吗？
ReservedStorageIsInUse                    = 保留存储空间正在使用时不支持此操作\n请在电脑重启后重新运行"{0}"功能。
ShortcutPinning                           = "{0}"快捷方式将被固定到开始菜单.....
SSDRequired                               = 要在您的设备上使用Windows Subsystem for Android™，您的电脑需要安装固态驱动器（SSD）。
UninstallUWPForAll                        = 对于所有用户
UWPAppsTitle                              = UWP应用
HEVCDownloading                           = 下载"HEVC Video Extensions from Device Manufacturer".....
GraphicsPerformanceTitle                  = 是否将所选应用程序的图形性能设置设为"高性能"？
ActionCenter                              = 为了使用"{0}"功能，你必须启用行动中心。
WindowsScriptHost                         = 没有在该机执行 Windows 脚本宿主的权限。请与系统管理员联系。 为了使用"{0}"功能，你必须启用Windows脚本主机。
ScheduledTaskPresented                    = "{0}"函数已经被创建为"{1}"。
CleanupTaskNotificationTitle              = Windows清理
CleanupTaskNotificationEvent              = 运行任务以清理Windows未使用的文件和更新？
CleanupTaskDescription                    = 使用内置磁盘清理工具清理未使用的Windows文件和更新。
CleanupNotificationTaskDescription        = 关于清理Windows未使用的文件和更新的弹出通知提醒。
SoftwareDistributionTaskNotificationEvent = Windows更新缓存已成功删除。
TempTaskNotificationEvent                 = 临时文件文件夹已成功清理。
FolderTaskDescription                     = "{0}"文件夹清理。
EventViewerCustomViewName                 = 进程创建
EventViewerCustomViewDescription          = 进程创建和命令行审核事件。
RestartWarning                            = 确保重启电脑。
ErrorsLine                                = 行
ErrorsMessage                             = 错误/警告
DialogBoxOpening                          = 显示对话窗口.....
Disable                                   = 禁用
Enable                                    = 启用
AllFilesFilter                            = 所有文件
FolderSelect                              = 选择一个文件夹
FilesWontBeMoved                          = 文件将不会被移动。
Install                                   = 安装
NoData                                    = 无数据。
NoInternetConnection                      = 无网络连接。
RestartFunction                           = 请重新运行"{0}"函数。
NoResponse                                = 无法建立{0}。
Restore                                   = 恢复
Run                                       = 运行
Skipped                                   = 已跳过。
GPOUpdate                                 = GPO更新.....
TelegramGroupTitle                        = 加入我们的官方Telegram 群。
TelegramChannelTitle                      = 加入我们的官方Telegram 频道。
DiscordChannelTitle                       = 加入我们的官方Discord 频道。
Uninstall                                 = 卸载
'@

# SIG # Begin signature block
# MIIblwYJKoZIhvcNAQcCoIIbiDCCG4QCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUkw0C/l3imPTdvMWdrahax2+t
# vsSgghYPMIIDAjCCAeqgAwIBAgIQaCN8KfrjD6BOk5DiIPWouTANBgkqhkiG9w0B
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
# IwYJKoZIhvcNAQkEMRYEFOGDc7VtZlqYiNdlQn7bGkgTzsiCMA0GCSqGSIb3DQEB
# AQUABIIBAJXds/waScZCeM3krCwiSwdBbATEQGiYUb8355viQjkU0uvauw+f0D15
# uRJKUlxS0mo4exDBOssMLLvEOTePfWCHzMXd5c1tSkDCoG/KvqeYM8NxoSN4Y/in
# SRmOvdO9fmxk/i0M/eqMETKIJrxtFe/S4MTI71mudLgBgpDqKZ3/UPc5yw8bdokx
# 9FARD3AhwRvB2MLqsfJEYh6qefyE3RGRDEjd+TwbT+MxjgTEZyml6QNRV1M7jyln
# Rja2mg7+jqpOBx0vnbezcoAcfO19oNr2ZoLQmFJu2GJNbrJAJbyHk8p+CgNRDRc8
# MYVu+HCB0RptpK4EphZImxyyJd0D6JKhggMgMIIDHAYJKoZIhvcNAQkGMYIDDTCC
# AwkCAQEwdzBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4x
# OzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQgRzQgUlNBNDA5NiBTSEEyNTYgVGlt
# ZVN0YW1waW5nIENBAhAFRK/zlJ0IOaa/2z9f5WEWMA0GCWCGSAFlAwQCAQUAoGkw
# GAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjMwOTE3
# MTgwNTM0WjAvBgkqhkiG9w0BCQQxIgQgMrtk0yYhdi+4TdUXWLFuqaQDpiK+pH2r
# flkCyTR2S24wDQYJKoZIhvcNAQEBBQAEggIAW9N2sJhKoSnw5CBgkTlHLEHyiqPm
# 0wlBNQRg4MtG3JD+M3KKdU1AdPkIgGQfrLlQ1SAtzcptyETaLUQiDHdTKld0LLgT
# mWGGogKpZiEtBhA3LdyAFPd6oOI2RWVxnHl42R42dH3/Gx3xQky0Dofhjr3S/9Ra
# h/UW74Bf3z4rukQp7LoWtxvWBHAaL2lqWHhSykO9JnqZTCAMtNSs8cDkdw0aKW3j
# VMQ2+UwBpL9tUfUDwkOY0XIQjLtB3iuqNxIXf4lCyGpYyelPDZKGWNE87fulkMYP
# V6+krlM93r8VCMxRdKKPeIKd9h8A1YS1D8SH07brQz9YiY4KcEMgS2OXiXUrqQY+
# w0hdOQbRP+t0GF3BjAHkb2NTz6vtAmzpWlto2FocOYikaAENm8/eak9S4bWGEAuD
# dD7SJsRW2VpY+i9yFWFTV13FNTs54xH2gZxCyghJkBlQVN51azYxgONDoHjy1a5Y
# tSCRanmftMb18/EOU0n8SQR7PnmANl+s959scGTlvHoIsHpZ21/lyqFwdXAr/tWm
# ngP3c8bQ8shLxsAWse8HFTjSABDDa7kIf16iyQYllteVWvtx2FvimNlK74YjdoXg
# Xo1UazR74Odi8o99RM10kq7Gbk38Sp/eNxIYO0QY90T3qstFG2V0iGGvwr3Vd3r7
# kMcBhIMtJkoXN+M=
# SIG # End signature block
