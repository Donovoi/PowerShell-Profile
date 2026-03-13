@{
  RootModule           = 'ImageForensics.psm1'
  ModuleVersion        = '0.6.0'
  GUID                 = 'b9a2e6a4-38b8-4c3a-9b3a-8b2a0f2b8c44'
  Author               = 'Your Team'
  CompanyName          = 'Yes'
  PowerShellVersion    = '5.1'
  CompatiblePSEditions = @('Desktop', 'Core')
  Description          = 'Image and video deepfake triage with entropy analysis, face-focused forensics, overlays, JSON features, and CSV summaries.'
  FunctionsToExport    = @('Invoke-DeepfakeScan')
  CmdletsToExport      = @()
  AliasesToExport      = @()
  PrivateData          = @{
    PSData = @{
      Tags         = @('forensics', 'deepfake', 'image', 'video', 'opencv', 'mediapipe', 'powershell')
      ProjectUri   = 'https://github.com/Donovoi/PowerShell-Profile'
      ReleaseNotes = 'v0.6.0: Hardened WhatIf behavior, added Python preflight and dependency repair, fixed detector/video metric reporting, aligned help/tests, and added README guidance.'
    }
  }
}
