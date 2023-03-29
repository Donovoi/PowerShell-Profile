function Set-PowerCFG {
  [CmdletBinding()]
  param(

  )
  Write-Verbose 'PowerSettings that will help you!'
  powercfg -change -monitor-timeout-ac 0
  powercfg -change -monitor-timeout-dc 0
  powercfg /hibernate off
  powercfg -change standby-timeout-ac 0
  powercfg -change standby-timeout-dc 0
  powercfg -change disk-timeout-ac 0
  powercfg -change disk-timeout-dc 0
  powercfg -change hibernate-timeout-ac 0
  powercfg -change hibernate-timeout-dc 0
}
