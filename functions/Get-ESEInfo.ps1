#This script assumes you have installed ESENT.Interop from Nuget (https://www.nuget.org/packages/ESENT.Interop/)
#Please install via the 'Install-Package ESENT.Interop -Version 1.9.4' command in PowerShell before using this script

[Reflection.Assembly]::LoadFrom("ESENT.dll")

$contactsDatabase = "Contacts.edb"

function Get-ContactsFromEDB {
    param (
        [string] $DataPath
    )
    $instance = New-Object -TypeName ESENT.Interop.Instance -ArgumentList "Contacts"
    try {
        $instance.Init()
        $instance.AttachDatabase($DataPath)
        $session = $instance.BeginSession(ESENT.Interop.OpenSessionGrbit.ReadOnly)
        $database = $session.OpenDatabase("Contacts.edb")
        
        $cursor = $session.OpenTable("Contacts")

        # Define columns to retrieve
        $columns = @("ContactID", "FullName", "EmailAddress", "PhoneNumber", "PostalAddress")

        $contacts = @()
        
        if ($cursor.TryMoveFirst()) {
            do {
                $contact = New-Object PSObject
                foreach ($column in $columns) {
                    $getter = [ESENT.Interop.Columnar]$cursor
                    Add-Member -InputObject $contact -MemberType NoteProperty -Name $column -Value ($getter[$column].ToString())
                }
                
                $contacts += $contact
            } while ($cursor.TryMoveNext())
        }

        return $contacts
    }
    finally {
        if ($null -ne $cursor) { $cursor.Close() }
        if ($null -ne $database) { $session.CloseDatabase($database) }
        if ($null -ne $session) { $session.End() }
        if ($null -ne $instance) { $instance.Term() }
    }
$contacts = Get-ContactsFromEDB -DataPath $contactsDatabase
$contacts
}