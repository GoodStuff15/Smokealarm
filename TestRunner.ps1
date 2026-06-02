# TestRunner.ps1
# Orchestrates test execution using ResolveEndpoints, EndpointPriority, AuthFlow and TestFramework

param(
    # Configuration parameters
    [string]$openApiSpecPath = "$PSScriptRoot\swagger.json",
    [string]$baseUrl         = "https://localhost:7194",
    [string]$accessToken     = "your_token_here",  # optional hardcoded token for testing
    [string]$username        = $null,  # from pipeline secret
    [string]$password        = $null,  # from pipeline secret

    # Customization options
    [string]$reportLocation = ".\reports\",  # optional path to save HTML report (e.g. ".\reports\")
    [bool]$failOnTestFailures = $true,
    [string[]]$skipPaths      = @('team-participants'),
    [string[]]$methods        = @('get','post', 'put', 'delete'),
    [bool]$showDetailedErrors = $true,
    [bool]$saveReports = $true,
    [int]$maxReports = 10,
    [int]$maxAgeDays = 10

    )

    $global:capturedIds = @{}

function Get-CapturedId {
    param ([string]$paramName, [string]$path)

    $keyword = $paramName -replace '[Ii]ds$', '' -replace '[Ii]d$', ''

    # If keyword is empty (param is just "id"), derive resource from path
    if ([string]::IsNullOrWhiteSpace($keyword)) {
        $segments = $path.Trim('/') -split '/'
        
        # Try each segment, including hyphenated ones, for a captured ID match
        $keyword = $null
        foreach ($segment in ($segments | Where-Object { $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' -and $_ -notmatch 'create|add|update|delete|get|list|change|set|remove|activate|deactivate'} | Select-Object -Last 3)) {
            # Split hyphenated segments and check each part
            $parts = $segment -split '-'
            foreach ($part in $parts) {
                $part = $part -replace '[Ii]ds$', '' -replace '[Ii]d$', ''
                if ($part.Length -gt 2 -and $global:capturedIds.Keys -like "*$part*") {
                    $keyword = $part
                    break
                }
            }
            if ($keyword) { break }
        }
    }

    if ($keyword) {
        $match = $global:capturedIds.Keys | Where-Object { $_ -eq $keyword } | Select-Object -First 1
        if (-not $match) {
            $match = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" } | Select-Object -First 1
        }
                if ($match) {
            return [string]$global:capturedIds[$match]
        }
    }

    Write-Host "  WARNING: No captured ID found for '$paramName' in '$path', using 2" -ForegroundColor DarkYellow
    return '2'
}

function Save-ResponseId {
    param ([string]$path, [string]$body)

    if ([string]::IsNullOrWhiteSpace($body)) { return }

    try {
        $parsed = $body | ConvertFrom-Json

        $idProp = $parsed.PSObject.Properties | Where-Object { $_.Name -eq 'id' -or $_.Name -eq 'Id' } | 
                    Select-Object -First 1

        if (-not $idProp) {
            $idProp = $parsed.PSObject.Properties | 
                        Where-Object { $_.Name -match '[Ii]d$' } | 
                        Select-Object -First 1
        }

        if (-not $idProp) { 
            return 
        }

        $id  = $idProp.Value
        $key = if ($idProp.Name -eq 'id' -or $idProp.Name -eq 'Id') {
            $segments = $path.Trim('/') -split '/'
            $derived = $segments | Where-Object { $_ -notmatch 'api|create|add|update|delete' } | 
                Select-Object -First 1
            $derived.ToLower()
        } else {
            ($idProp.Name -replace '[Ii]d$', '').ToLower()
        }

        if ($id -and $key) {
            $global:capturedIds[$key] = $id
        }
    } catch {

    }
}

function Resolve-RequestBody {
    param ([object]$body)
    
    if (-not $body) { return $body }

    $obj = [ordered]@{}  # <-- hashtable instead of PSCustomObject

    $properties = if ($body -is [hashtable] -or $body -is [System.Collections.Specialized.OrderedDictionary]) {
        $body.Keys | ForEach-Object { [PSCustomObject]@{ Name = $_; Value = $body[$_] } }
    } else {
        $body.PSObject.Properties
    }

    foreach ($prop in $properties) {
        $key   = $prop.Name
        $value = $prop.Value

        if ($null -eq $value) {
            $obj[$key] = $null
            continue
        }

        if ($value.GetType().Name -like 'List*' -or $value -is [array] -or
            $value -is [System.Collections.ArrayList]) {

            $keyword = $key -replace '[Ii]ds$', '' -replace '[Ii]d$', ''
            $matching  = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" }
            $arr = if ($matching) {
                [int[]]@($matching | ForEach-Object { [int]$global:capturedIds[$_] })
            } else {
                [int[]]@($value)
            }
            $obj[$key] = [object[]]@($arr)  # force object array, not int array

        } elseif ($value -is [int] -or $value -is [long]) {
            $keyword = $key -replace '[Ii]ds$', '' -replace '[Ii]d$', ''
            $match    = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" } | Select-Object -First 1
            $obj[$key] = if ($match) { [int]$global:capturedIds[$match] } else { $value }

        } else {
            $obj[$key] = $value
        }
    }

    return $obj
}

. "$PSScriptRoot\ResolveEndpoints.ps1"
. "$PSScriptRoot\TestFramework.ps1" -baseUrl $baseUrl -accessToken $accessToken
. "$PSScriptRoot\EndpointPriority.ps1" 
. "$PSScriptRoot\AuthFlow.ps1"

# ======================
# 1. Authenticate and get token if credentials provided
#=======================
if ($username -and $password) {
    $accessToken = Get-AuthToken -baseUrl $baseUrl -username $username -password $password
}
# =====================
# 2. Load endpoints
# =====================
$apiData  = Get-ApiEndpoints -openApiSpecPath $openApiSpecPath

$endpoints = Get-SortedEndpoints -endpoints $apiData.Endpoints -schemas $apiData.Schemas

$endpoints = $endpoints | Where-Object {
    $path   = $_.Path
    $method = $_.Method

    if ($method -notin $methods) { return $false }

    foreach ($skip in $skipPaths) {
        if ($skip -and $path -like "*$skip*") { return $false }
    }

    return $true
}

# =====================
# 3. Run tests
# =====================

foreach ($endpoint in $endpoints) {


    $method       = $endpoint.Method
    $resolvedPath = (Resolve-PathParameters -path $endpoint.Path) + 
                (Resolve-QueryParameters -parameters $endpoint.Parameters)
    $resolvedBody = if ($method -eq 'post' -or $method -eq 'put') {
        Resolve-RequestBody -body $endpoint.RequestBody
    } else {
        $null
    }

    Write-Host "  -> $($method.ToUpper()) $resolvedPath" -NoNewline

    $passed = switch ($method) {
        'post'   { RunPostRequest   -url $resolvedPath -body $resolvedBody }
        'get'    { RunGetRequest    -url $resolvedPath }
        'put'    { RunPutRequest    -url $resolvedPath -body $resolvedBody }
        'delete' { RunDeleteRequest -url $resolvedPath }
    }

    if ($passed) {
        
        Write-Host "  PASSED" -ForegroundColor Green
        if ($method -eq 'post') {   # <-- was $group.Name
            $last = $script:resultArray | Select-Object -Last 1

            Save-ResponseId -path $endpoint.Path -body $last.Body
        }
    } else {
        Write-Host "  FAILED" -ForegroundColor Red
        if ($showDetailedErrors) {
            $last = $script:resultArray | Select-Object -Last 1
            Format-ErrorBody -body $last.Body -statusCode $last.StatusCode
        }
    }
}



# =====================
# 4. Print summary
# =====================
Write-Host ""
Write-TestSummary

if ($reportLocation) {
    Write-HtmlReport -outputFolder $reportLocation -maxReports $maxReports -maxAgeDays $maxAgeDays
}

# =====================
# 5. Fail if any test failed (for CI pipelines)
# =====================

$summary = Get-TestSummary
if ($failOnTestFailures -and $summary.Failed -gt 0) {
    # Azure DevOps
    Write-Host "##vso[task.logissue type=error]$($summary.Failed) test(s) failed"
    # GitHub Actions
    Write-Host "::error::$($summary.Failed) test(s) failed"
    exit 1
}

