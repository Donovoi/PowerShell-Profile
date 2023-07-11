
<#
.EXAMPLE
Get-GPTResponse -prompt 'Translate the following English text to French: "{your text here}"'
#>
function Get-GPTResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$prompt
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $apiKey = 'your-openai-api-key'
    $headers = @{
        'Authorization' = "Bearer $apiKey"
        'Content-Type'  = 'application/json'
    }
    $body = @{
        'prompt'     = $prompt
        'max_tokens' = 60
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri 'https://api.openai.com/v1/engines/davinci-codex/completions' -Method Post -Headers $headers -Body $body

    $output = $response.choices[0].text.Trim()

    $outputBox = New-Object System.Windows.Forms.TextBox
    $outputBox.Multiline = $true
    $outputBox.ScrollBars = 'Vertical'
    $outputBox.Width = 500
    $outputBox.Height = 300
    $outputBox.Text = $output

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'OpenAI Response'
    $form.Controls.Add($outputBox)

    $form.ShowDialog()
}






function Show-GPTForm {
    [CmdletBinding()]
    param ()
    
    Add-Type -AssemblyName PresentationFramework
    
    $window = New-Object -TypeName System.Windows.Window -Property @{
        Title                 = 'OpenAI GPT-3 Query'
        SizeToContent         = 'WidthAndHeight'
        WindowStartupLocation = 'CenterScreen'
        ResizeMode            = 'CanMinimize'
    }
    
    $grid = New-Object -TypeName System.Windows.Controls.Grid
    $window.Content = $grid
    
    $row = 0
    
    $fields = @(
        [PSCustomObject]@{
            Label = 'Problem Description:'
            Name  = 'ProblemDescription'
        },
        [PSCustomObject]@{
            Label = 'Code:'
            Name  = 'Code'
        },
        [PSCustomObject]@{
            Label = 'Expected Behavior:'
            Name  = 'ExpectedBehavior'
        },
        [PSCustomObject]@{
            Label = 'Actual Behavior:'
            Name  = 'ActualBehavior'
        },
        [PSCustomObject]@{
            Label = "What I've Tried So Far:"
            Name  = 'TriedSoFar'
        },
        [PSCustomObject]@{
            Label = 'My Question:'
            Name  = 'Question'
        }
    )
    
    foreach ($field in $fields) {
        $label = New-Object -TypeName System.Windows.Controls.Label -Property @{
            Content = $field.Label
            Margin  = New-Object -TypeName System.Windows.Thickness -ArgumentList 5
        }
        
        $textBox = New-Object -TypeName System.Windows.Controls.TextBox -Property @{
            Name                        = $field.Name
            AcceptsReturn               = $true
            TextWrapping                = 'Wrap'
            VerticalScrollBarVisibility = 'Auto'
            Margin                      = New-Object -TypeName System.Windows.Thickness -ArgumentList 5
        }
        
        $grid.RowDefinitions.Add((New-Object -TypeName System.Windows.Controls.RowDefinition))
        $grid.Children.Add($label)
        $label.SetValue([System.Windows.Controls.Grid]::RowProperty, $row)
        $grid.Children.Add($textBox)
        $textBox.SetValue([System.Windows.Controls.Grid]::RowProperty, $row)
        
        $row++
    }
    
    $okButton = New-Object -TypeName System.Windows.Controls.Button -Property @{
        Content = 'Done'
        Margin  = New-Object -TypeName System.Windows.Thickness -ArgumentList 5
    }
    
    $cancelButton = New-Object -TypeName System.Windows.Controls.Button -Property @{
        Content = 'Cancel'
        Margin  = New-Object -TypeName System.Windows.Thickness -ArgumentList 5
    }
    
    $buttonsPanel = New-Object -TypeName System.Windows.Controls.StackPanel -Property @{
        Orientation = [System.Windows.Controls.Orientation]::Horizontal
        HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        Margin = New-Object -TypeName System.Windows.Thickness -ArgumentList 5
    }
    
    $buttonsPanel.Children.Add($okButton)
    $buttonsPanel.Children.Add($cancelButton)
    
    
    $grid.RowDefinitions.Add((New-Object -TypeName System.Windows.Controls.RowDefinition))
    $grid.Children.Add($buttonsPanel)
    $buttonsPanel.SetValue([System.Windows.Controls.Grid]::RowProperty, $row)
    
    $okButton.Add_Click({
            $window.DialogResult = $true
            $window.Close()
        })
    
    $cancelButton.Add_Click({
            $window.DialogResult = $false
            $window.Close()
        })
    
    $window.ShowDialog() | Out-Null
    
    if ($window.DialogResult -eq $true) {
        $fields | ForEach-Object {
            $textBox = $grid.FindName($_.Name)
            $_.Value = $textBox.Text.Trim()
        }
        
        foreach ($field in $fields) {
            "Label: {0}`nValue: {1}`n" -f $field.Label, $field.Value
        }
    }
    
    return $fields
}