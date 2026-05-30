

# If credentials provided, authenticate first and get token

function Get-AuthToken {
    param(
        [string]$baseUrl,
        [string]$username,      # from pipeline secret
        [string]$password      # from pipeline secret
    )

    if ($username -and $password) {
        Write-Host "Authenticating..." -ForegroundColor Cyan
        $authBody = @{
            username = $username
            password = $password
        }
        $authResponse = Invoke-WebRequest -Uri "$baseUrl/api/Auth/login" `
                            -Method Post `
                            -Body ($authBody | ConvertTo-Json) `
                            -ContentType "application/json" `
                            -SkipHttpErrorCheck

        if ($authResponse.StatusCode -ne 200) {
            Write-Host "Authentication failed — aborting" -ForegroundColor Red
            exit 1
        }

        $accessToken = ($authResponse.Content | ConvertFrom-Json).token
        Write-Host "Authentication successful" -ForegroundColor Green
    }

return $accessToken
}