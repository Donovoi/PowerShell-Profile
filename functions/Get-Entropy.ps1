<#
.SYNOPSIS
Calculates the entropy of a file and provides an assessment based on the entropy value.

.DESCRIPTION
The Get-Entropy function reads all bytes from a specified file, calculates the Shannon entropy, and assesses the nature of the file's content based on the entropy level. It returns a hashtable containing the entropy value and a string assessment.

.PARAMETER FilePath
The path to the file for which entropy is to be calculated. This parameter is mandatory.

.EXAMPLE
$entropyInfo = Get-Entropy -FilePath "C:\path\to\your\file.txt"
This example calculates the entropy for 'file.txt' and stores the resulting entropy value and assessment in the $entropyInfo variable.

.OUTPUTS
Hashtable
A hashtable with two keys: 'Entropy', which holds the calculated entropy value as a double, and 'Assessment', which contains a string describing the entropy level.

.NOTES
Entropy is a measure of randomness or disorder within a set of data. Low entropy indicates predictable data patterns, while high entropy suggests randomness, such as encrypted or compressed data.

.LINK
https://en.wikipedia.org/wiki/Entropy_(information_theory)

#>
function Get-Entropy {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    try {
        # Read all bytes from the file
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)

        # Get the frequency of each byte
        $frequencyTable = @{}
        foreach ($byte in $bytes) {
            if (!$frequencyTable.ContainsKey($byte)) {
                $frequencyTable[$byte] = 0
            }
            $frequencyTable[$byte]++
        }

        # Calculate the entropy
        $entropy = 0.0
        $totalBytes = $bytes.Length
        foreach ($byte in $frequencyTable.Keys) {
            $probability = $frequencyTable[$byte] / $totalBytes
            $entropy -= $probability * [Math]::Log($probability, 2)
        }

        # Assess the entropy value
        $assessment = ''
        if ($entropy -lt 3) {
            $assessment = 'Low entropy. Likely plain text or structured data.'
        }
        elseif ($entropy -ge 3 -and $entropy -lt 5) {
            $assessment = 'Moderate entropy. Could be natural language or mixed content.'
        }
        elseif ($entropy -ge 5) {
            $assessment = 'High entropy. Likely encrypted or compressed data.'
        }

        # Return the entropy value and assessment
        return @{
            Entropy    = $entropy
            Assessment = $assessment
        }
    }
    catch {
        throw $_.Exception.Message
    }
}
