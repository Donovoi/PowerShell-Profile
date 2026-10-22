# PSReflect compatibility import surface.
# Author: Matthew Graeber (@mattifestation). License: BSD 3-Clause.
# Canonical implementations and original attribution are in the files below.
foreach ($commandFile in 'New-InMemoryModule','func','Add-Win32Type','psenum','field','struct') {
    . (Join-Path $PSScriptRoot ($commandFile + '.ps1'))
}
