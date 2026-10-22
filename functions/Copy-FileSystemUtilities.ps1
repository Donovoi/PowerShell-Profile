# Compatibility import surface. Canonical definitions live in command-named files.
foreach ($commandFile in @(
    'Copy-FileSystemArtifact','Copy-RecursivePattern','Copy-WildcardPattern',
    'Copy-DirectPath','Copy-StandardFile','Copy-LockedFile','Copy-DirectoryRecursive'
)) {
    . (Join-Path $PSScriptRoot ($commandFile + '.ps1'))
}
