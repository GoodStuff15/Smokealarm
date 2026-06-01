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
        [object]$body,
        [int[]]$expectedStatusCodes = @(200, 201)  # <-- POST defaults to both
    )

    $fullUrl = "$script:baseUrl/$($url.TrimStart('/'))"
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $errorBody    = $null
    $json = ConvertTo-JsonPreserveArrays $body

    try {
        $response = Invoke-WebRequest -Uri $fullUrl -Method Post `
                        -Body $json `
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
        [object]$body,
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

function Write-HtmlReport {
    param (
        [string]$outputFolder = ".\reports\",
        [int]$maxReports = 0, #0 = unlimited
        [int]$maxAgeDays = 0 #0 = unlimited
    )

    if(-not (Test-Path $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder | Out-Null
    }

    $getDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $outputPath = Join-Path -Path $outputFolder -ChildPath "SmokeAlarm_Report_$getDate.html"
    $results = $script:resultArray
    $summary = Get-TestSummary

    $passColor = "#4caf50"
    $failColor = "#f44336"

    $rows = $results | ForEach-Object {
        $statusColor = if ($_.Passed) { $passColor } else { $failColor }
        $passText    = if ($_.Passed) { "PASSED" } else { "FAILED" }
        $body        = if (-not $_.Passed -and $_.Body) {
            $escaped = [System.Web.HttpUtility]::HtmlEncode($_.Body)
            "<pre class='error-body'>$escaped</pre>"
        } else { "" }

        @"
        <tr>
            <td><span class="method method-$($_.Method.ToLower())">$($_.Method.ToUpper())</span></td>
            <td class="path">$($_.Url)</td>
            <td style="color:$statusColor;font-weight:bold">$passText</td>
            <td>$($_.StatusCode)</td>
            <td>$($_.DurationMs) ms</td>
        </tr>
        $(if ($body) { "<tr><td colspan='5'>$body</td></tr>" })
"@
    }

    $passPercent = if ($summary.Total -gt 0) { 
    [math]::Round(($summary.Passed / $summary.Total) * 100) 
    } else { 0 }

    $styleContent = ""
    $cssPath = Join-Path -Path $PSScriptRoot -ChildPath "reportStyle.css"
    if (Test-Path $cssPath) {
        $styleContent = Get-Content -Raw -Path $cssPath
    } else {
        Write-Host "Warning: reportStyle.css not found, report will be unstyled" -ForegroundColor Yellow
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>SmokeAlarm Report</title>
    <style>
    $styleContent
    </style>
</head>
<body>
    <h1>SmokeAlarm</h1>
    <div class="subtitle">API Smoke Test Report</div>

    <div class="summary">
        <div class="card">
            <div class="card-label">Total</div>
            <div class="card-value">$($summary.Total)</div>
        </div>
        <div class="card">
            <div class="card-label">Passed</div>
            <div class="card-value" style="color:$passColor">$($summary.Passed)</div>
        </div>
        <div class="card">
            <div class="card-label">Failed</div>
            <div class="card-value" style="color:$failColor">$($summary.Failed)</div>
        </div>
        <div class="card">
            <div class="card-label">Total Time</div>
            <div class="card-value">$([math]::Round($summary.TotalMs)) ms</div>
        </div>
        <div class="card">
            <div class="card-label">Avg Time</div>
            <div class="card-value">$([math]::Round($summary.AverageMs)) ms</div>
        </div>
    </div>

    <div class="progress-bar"><div class="progress-bar-fill" style="width:$passPercent%"></div></div>


    <table>
        <thead>
            <tr>
                <th>Method</th>
                <th>Path</th>
                <th>Result</th>
                <th>Status</th>
                <th>Duration</th>
            </tr>
        </thead>
        <tbody>
            $($rows -join "`n")
        </tbody>
    </table>

    <div class="timestamp">Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</body>
</html>
"@

    $html | Out-File -FilePath $outputPath -Encoding utf8
    Write-Host "Report saved to $outputPath" -ForegroundColor Cyan

    Limit-Reports -outputFolder $outputFolder -maxReports $maxReports -maxAgeDays $maxAgeDays

}


# Helper functions
function ConvertTo-JsonPreserveArrays {
    param([object]$obj)
    
    $cleaned = [ordered]@{}
    foreach ($key in $obj.Keys) {
        $val = $obj[$key]

        if ($val -is [array] -or $val -is [System.Collections.Generic.List[object]]) {
            # Wrap in @() to force array even for single element
            $cleaned[$key] = @($val)
        } else {
            $cleaned[$key] = $val
        }
    }
    return $cleaned | ConvertTo-Json -Depth 10
}

function Limit-Reports {
    param (
        [string]$outputFolder,
        [int]$maxReports,
        [int]$maxAgeDays
    )

    $reports = Get-ChildItem -Path $outputFolder -Filter "SmokeAlarm_Report_*.html" |
            Sort-Object LastWriteTime -Descending

    # Delete by age
    if ($maxAgeDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$maxAgeDays)
        $reports | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
            Remove-Item $_.FullName -Force
        }
        $reports = Get-ChildItem -Path $outputFolder -Filter "SmokeAlarm_Report_*.html" |
                Sort-Object LastWriteTime -Descending
    }

    # Delete by count
    if ($maxReports -gt 0 -and $reports.Count -gt $maxReports) {
        $reports | Select-Object -Skip $maxReports | ForEach-Object {
            Remove-Item $_.FullName -Force
        }
    }
}