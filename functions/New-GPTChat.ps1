<#
.SYNOPSIS
This advanced function interacts with the OpenAI GPT-3.5-turbo API.

.DESCRIPTION
The function sends a conversation and available functions to GPT, checks if GPT wanted to call a function,
calls the function, and sends the info on the function call and function response to GPT.

.EXAMPLE
New-GPTChat -ApiKey "your-api-key"
#>
function New-GPTChat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiKey
    )

    # Validate the API key
    if (-not $ApiKey) {
        throw 'API key not provided or invalid.'
    }

    # Define the headers
    $headers = @{
        'Authorization' = "Bearer $ApiKey"
        'Content-Type'  = 'application/json'
    }

    try {
        # Define the initial message and function
        $messages = @(@{ 'role' = 'user'; 'content' = "What's the weather like in Boston?" })

        # Send the initial request
        $response = Invoke-RestMethod -Uri 'https://api.openai.com/v1/chat/completions' -Method Post -Body (@{
                'model'         = 'gpt-3.5-turbo-0613'
                'messages'      = $messages
                'function_call' = 'auto'
            } | ConvertTo-Json) -Headers $headers

        # Check if GPT wanted to call a function
        if ($response.choices[0].message.function_call) {
            # Call the function
            $functionName = $response.choices[0].message.function_call.name
            $functionArgs = $response.choices[0].message.function_call.arguments | ConvertFrom-Json

            # In this example, we only have one function, but you can have multiple
            $availableFunctions = @{
                'get_current_weather' = Get-CurrentWeather -Location $functionArgs.location -Unit $functionArgs.unit
            }

            $functionResponse = $availableFunctions[$functionName]

            # Send the info on the function call and function response to GPT
            $messages += $response.choices[0].message
            $messages += @{ 'role' = 'function'; 'name' = $functionName; 'content' = $functionResponse }

            # Get a new response from GPT where it can see the function response
            $secondResponse = Invoke-RestMethod -Uri 'https://api.openai.com/v1/chat/completions' -Method Post -Body (@{
                    'model'    = 'gpt-3.5-turbo-0613'
                    'messages' = $messages
                } | ConvertTo-Json) -Headers $headers

            return $secondResponse
        }
        else {
            return $response
        }
    }
    catch {
        Write-Error $_.Exception.Message
    }
}

function Get-CurrentWeather {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Location,

        [Parameter(Mandatory = $true)]
        [string]$Temperature,

        [Parameter(Mandatory = $false)]
        [ValidateSet('celsius', 'fahrenheit')]
        [string]$Unit = 'celsius',

        [Parameter(Mandatory = $false)]
        [string[]]$Forecast = @('sunny', 'windy')
    )

    # Here you would call the actual weather API to get the current weather for the specified location
    # For now, let's just return a dummy response
    return @{
        'location'    = $Location
        'temperature' = $Temperature
        'unit'        = $Unit
        'forecast'    = $Forecast
    } | ConvertTo-Json
}
