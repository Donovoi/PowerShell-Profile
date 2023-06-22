function Invoke-GPT4 {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [Parameter(Mandatory=$false)]
        [string]$ApiKey
    )

    # If an API key was provided, encrypt it and save it to a file
    if ($ApiKey) {
        $encryptedApiKey = ConvertTo-SecureString -String $ApiKey -AsPlainText -Force | ConvertFrom-SecureString
        Set-Content -Path "$env:USERPROFILE\OpenAIKey.txt" -Value $encryptedApiKey
    }

    # Read the encrypted API key from the file and decrypt it
    $encryptedApiKey = Get-Content -Path "$env:USERPROFILE\OpenAIKey.txt"
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString -String $encryptedApiKey)))

    # Define the headers
    $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type"  = "application/json"
    }

    # The maximum chunk size for the OpenAI API is 2048 tokens
    $chunkSize = 2048

    # Chunk the message into smaller parts
    $messageChunks = $Message -split "(.{$chunkSize})" | Where-Object { $_ }

    # Send each chunk to the API
    $responses = foreach ($chunk in $messageChunks) {
        $body = @{
            "prompt" = $chunk
            "max_tokens" = 60
        } | ConvertTo-Json

        # Define the OpenAI API endpoint with the model
        $uri = "https://api.openai.com/v1/engines/davinci-codex/completions"

        # Send the request and receive the response
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body -Headers $headers

        # Return the response text
        $response.choices[0].text
    }

    # Chunk the responses into smaller parts
    $responseChunks = $responses -join "" -split "(.{$chunkSize})" | Where-Object { $_ }

    # Colorize and return the response chunks
    foreach ($chunk in $responseChunks) {
        # Create a prompt to ask the model to analyze the sentiment of the chunk
        $sentimentPrompt = "The following text: `"$chunk`" has a sentiment that is: (positive, negative, neutral)"

        $sentimentBody = @{
            "prompt" = $sentimentPrompt
            "max_tokens" = 1
        } | ConvertTo-Json

        # Send the sentiment request and receive the response
        $sentimentResponse = Invoke-RestMethod -Uri $uri -Method Post -Body $sentimentBody -Headers $headers

        # Get the sentiment from the response
        $sentiment = $sentimentResponse.choices[0].text.Trim()

        switch ($sentiment) {
            "positive" { Write-Host $chunk -ForegroundColor Green }
            "negative" { Write-Host $chunk -ForegroundColor Red }
            "neutral"  { Write-Host $chunk -ForegroundColor White }
        }
    }
}
