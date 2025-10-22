@{
  RootModule           = 'EntropyForensics.psm1'
  ModuleVersion        = '0.5.1'
  GUID                 = 'b9a2e6a4-38b8-4c3a-9b3a-8b2a0f2b8c44'
  Author               = 'Your Team'
  CompanyName          = 'Yes'
  PowerShellVersion    = '5.1'
  CompatiblePSEditions = @('Desktop', 'Core')
  Description          = 'Entropy-based deepfake triage with pixel/byte entropy, MediaPipe/Haar face ROI, JPEG DCT/Benford, overlays, and CSV logging.'
  FunctionsToExport    = @('Invoke-EntropyDeepfakeScan')
  CmdletsToExport      = @()
  AliasesToExport      = @()
  PrivateData          = @{
    PSData = @{
      Tags         = @('forensics', 'deepfake', 'entropy', 'mediapipe', 'opencv', 'scikit-image')
      ProjectUri   = 'https://example.local/tools/entropyforensics'
      ReleaseNotes = 'v0.5.1: Replace bash-like heredocs with PowerShell-safe python -c; rename $home/$args locals; ensure method returns; minor polish.'
    }
  }
}
