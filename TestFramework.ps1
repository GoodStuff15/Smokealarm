# This is the framework for running the tests. 
# It handles all the api calls and the test execution.

param(
    [string]$baseUrl = "http://localhost:8080",
    [string]$accessToken = "your_token_here"
)

$script:baseUrl     = $baseUrl
$script:accessToken = $accessToken
$script:resultArray = [System.Collections.Generic.List[PSObject]]::new()

function Get-AuthHeaders {
    return @{ "Authorization" = "Bearer $script:accessToken" }
}

function Add-Result {
    param($url, $method, $response, $errorBody = $null, $durationMs, [int[]]$expectedStatusCodes)

    $code   = if ($response) { $response.StatusCode } else { $null }
    $passed = ($code -in $expectedStatusCodes)

        # For successful responses, Content is already a string
    # For failed responses, use the pre-read errorBody
    $body = if ($errorBody) { $errorBody } else { $response.Content }

    $script:resultArray.Add([PSCustomObject]@{
        Url        = $url
        Method     = $method
        StatusCode = $code
        Expected   = $expectedStatusCodes -join ' or '
        Passed     = $passed
        DurationMs = $durationMs
        Body       = $body
        Response   = $response
    })

    return $passed
}

function RunPostRequest {
    param (
        [string]$url,
        [hashtable]$body,
        [int[]]$expectedStatusCodes = @(200, 201)  # <-- POST defaults to both
    )

    $fullUrl = "$script:baseUrl/$($url.TrimStart('/'))"
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $errorBody    = $null

    try {
        $response = Invoke-WebRequest -Uri $fullUrl -Method Post `
                        -Body ($body | ConvertTo-Json -Depth 10) `
                        -ContentType "application/json" `
                        -Headers (Get-AuthHeaders) `
                        -SkipHttpErrorCheck  # <-- stay in try on 4xx/5xx

        $errorBody = if ($response.Content -is [byte[]]) {
                            [System.Text.Encoding]::UTF8.GetString($response.Content)
                        } else {
                            $response.Content
                        }
    } catch {
        $errorBody = $_.Exception.Message
    } finally {
        $sw.Stop()
    }

    return Add-Result -url $fullUrl -method "POST" -response $response -errorBody $errorBody -durationMs $sw.ElapsedMilliseconds -expectedStatusCodes $expectedStatusCodes
}

function RunGetRequest {
    param (
        [string]$url,
        [int[]]$expectedStatusCodes = @(200)
    )

    $fullUrl = "$script:baseUrl/$($url.TrimStart('/'))"
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $errorBody = $null

    try {
        $response = Invoke-WebRequest -Uri $fullUrl -Method Get `
                        -Headers (Get-AuthHeaders) `
                        -ErrorAction Stop
                        -SkipHttpErrorCheck 

        $errorBody = if ($response.Content -is [byte[]]) {
                            [System.Text.Encoding]::UTF8.GetString($response.Content)
                        } else {
                            $response.Content
                        }
    } catch {
       
        $errorBody = $_.Exception.Message
    } finally {
        $sw.Stop()
    }

    return Add-Result -url $fullUrl -method "GET" -response $response -errorBody $errorBody -durationMs $sw.ElapsedMilliseconds -expectedStatusCodes $expectedStatusCodes
}

function RunPutRequest {
    param (
        [string]$url,
        [hashtable]$body,
        [int[]]$expectedStatusCodes = @(200, 201)  
    )

    $fullUrl = "$script:baseUrl/$($url.TrimStart('/'))"
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $errorBody    = $null

    try {
        $response = Invoke-WebRequest -Uri $fullUrl -Method Put `
                        -Body ($body | ConvertTo-Json -Depth 10) `
                        -ContentType "application/json" `
                        -Headers (Get-AuthHeaders) `
                        -ErrorAction Stop
                        -SkipHttpErrorCheck 
        $errorBody = if ($response.Content -is [byte[]]) {
                            [System.Text.Encoding]::UTF8.GetString($response.Content)
                        } else {
                            $response.Content
                        }
    } catch {
        
        $errorBody = $_.Exception.Message
    } finally {
        $sw.Stop()
    }

    return Add-Result -url $fullUrl -method "PUT" -response $response -errorBody $errorBody -durationMs $sw.ElapsedMilliseconds -expectedStatusCodes $expectedStatusCodes
}

function RunDeleteRequest {
    param (
        [string]$url,
        [int[]]$expectedStatusCodes = @(200, 204)
    )

    $fullUrl = "$script:baseUrl/$($url.TrimStart('/'))"
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $errorBody    = $null

    try {
        $response = Invoke-WebRequest -Uri $fullUrl -Method Delete `
                        -Headers (Get-AuthHeaders) `
                        -ErrorAction Stop
                        -SkipHttpErrorCheck 
        $errorBody = if ($response.Content -is [byte[]]) {
                            [System.Text.Encoding]::UTF8.GetString($response.Content)
                        } else {
                            $response.Content
                        }
    } catch {
       
        $errorBody = $_.Exception.Message
    } finally {
        $sw.Stop()
    }

    return Add-Result -url $fullUrl -method "DELETE" -response $response -errorBody $errorBody -durationMs $sw.ElapsedMilliseconds -expectedStatusCodes $expectedStatusCodes
}

function Get-TestSummary {
    param([int]$Last = 0)

    $results = if ($Last -gt 0) {
        $script:resultArray | Select-Object -Last $Last
    } else {
        $script:resultArray
    }

    return [PSCustomObject]@{
        Total     = $results.Count
        Passed    = ($results | Where-Object {  $_.Passed }).Count
        Failed    = ($results | Where-Object { -not $_.Passed }).Count
        TotalMs   = ($results | Measure-Object -Property DurationMs -Sum).Sum
        AverageMs = ($results | Measure-Object -Property DurationMs -Average).Average
        StatusCode = ($results | Select-Object -Last 1).StatusCode
        Response   = ($results | Select-Object -Last 1).Response
    }
}

function Write-TestSummary {
    $s = Get-TestSummary
    Write-Host "================================"
    Write-Host "  Total  : $($s.Total)"
    Write-Host "  Passed : $($s.Passed)" -ForegroundColor Green
    Write-Host "  Failed : $($s.Failed)" -ForegroundColor Red
    Write-Host "  Total  : $([math]::Round($s.TotalMs)) ms"
    Write-Host "  Avg    : $([math]::Round($s.AverageMs)) ms"
    Write-Host "================================"
}

function Format-ErrorBody {
    param (
        [string]$body,
        [int]$statusCode
    )

    # Known bodyless status codes
    $statusMessages = @{
        401 = "Unauthorized — token missing, expired, or invalid"
        403 = "Forbidden — valid token but insufficient permissions"
        404 = "Not Found — endpoint or resource does not exist"
        405 = "Method Not Allowed"
        429 = "Too Many Requests — rate limit hit"
        500 = "Internal Server Error"
        503 = "Service Unavailable"
    }

    Write-Host "    Status  : $statusCode" -ForegroundColor Yellow

    if ([string]::IsNullOrWhiteSpace($body)) {
        $hint = $statusMessages[$statusCode]
        if ($hint) {
            Write-Host "    Reason  : $hint" -ForegroundColor Yellow
        } else {
            Write-Host "    Body    : (empty)" -ForegroundColor Yellow
        }
        return
    }

    try {
        $parsed = $body | ConvertFrom-Json

        if ($parsed.title)  { Write-Host "    Title   : $($parsed.title)"  -ForegroundColor Yellow }

        if ($parsed.errors) {
            Write-Host "    Errors  :" -ForegroundColor Yellow
            $i = 1
            foreach ($parsedError in $parsed.errors.PSObject.Properties) {
                $details = $parsedError.Value -join ', '
                Write-Host "      $i. $($parsedError.Name): $details" -ForegroundColor Red
                $i++
            }
        } elseif ($parsed.message) {
            Write-Host "    Message : $($parsed.message)" -ForegroundColor Red
        } else {
            Write-Host "    Body    : $body" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    Body    : $body" -ForegroundColor Yellow
    }
}