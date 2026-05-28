# TestRunner.ps1
# Orchestrates test execution using ResolveEndpoints and TestFramework

param(
    [string]$openApiSpecPath = "$PSScriptRoot\swagger.json",
    [string]$baseUrl         = "https://localhost:7194",
    [string]$accessToken     = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwidW5pcXVlX25hbWUiOiJhZG1pbiIsImp0aSI6IjU0NTFiZGJkLWNlMTctNGQyOS1iN2EyLWU4ZTdmYzNkMzgzOCIsImh0dHA6Ly9zY2hlbWFzLm1pY3Jvc29mdC5jb20vd3MvMjAwOC8wNi9pZGVudGl0eS9jbGFpbXMvcm9sZSI6IkFkbWluIiwiZXhwIjoxNzgwMDAxNzYwLCJpc3MiOiJHQ29tcGV0aXRpb25zQVBJIiwiYXVkIjoiR0NvbXBVc2VycyJ9.mOjaNCGw4hdmCQfllGifT5PHkVm4QqLziWdll9lK_Qo",

    # Pipeline options
    [bool]$failOnTestFailures = $true,
    [string[]]$skipPaths      = @(),
    [string[]]$methods        = @('get','post', 'put', 'delete'),
    [bool]$showDetailedErrors = $true

    )

    $global:capturedIds = @{}

function Get-CapturedId {
    param ([string]$paramName, [string]$path)

    # Strip the param name down to the resource keyword (e.g. "userId" -> "user") for better matching with captured IDs
    $keyword = $paramName -replace 'id$', '' -replace 'Id$', ''

    # Look for a captured ID whose key contains the keyword
    $match = $global:capturedIds.Keys | 
                Where-Object { $_ -like "*$keyword*" } | 
                Select-Object -First 1
    if ($match) {
        return [string]$global:capturedIds[$match]
    }

    return '1'
}

function Save-ResponseId {
    param ([string]$path, [string]$body)

    if ([string]::IsNullOrWhiteSpace($body)) { return }

    try {
        $parsed = $body | ConvertFrom-Json

        # Find first property ending in Id/id at top level
        $idProp = $parsed.PSObject.Properties | 
                    Where-Object { $_.Name -match '[Ii]d$' } | 
                    Select-Object -First 1

        if (-not $idProp) { return }

        $id  = $idProp.Value
        $key = ($idProp.Name -replace '[Ii]d$', '').ToLower()

        if ($id -and $key) {
            $global:capturedIds[$key] = $id
            Write-Host "    Captured: $key = $id" -ForegroundColor DarkCyan
        }
    } catch { }
}

function Resolve-RequestBody {
    param ([hashtable]$body)

    if (-not $body) { return $body }

    $resolved = @{}
    foreach ($key in $body.Keys) {
        $value = $body[$key]

        if ($value -is [array]) {
            # Try to find a captured ID for this array property
            # e.g. playerIds -> player
            $keyword = $key -replace '[Ii]ds$', '' -replace '[Ii]d$', ''
            $match   = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" } | Select-Object -First 1

            $resolved[$key] = if ($match) {
                @([int]$global:capturedIds[$match])  # array with one captured ID
            } else {
                @(1)  # fallback
            }
        } elseif ($value -is [int] -or $value -is [long]) {
            # Try to find a captured ID for integer properties
            $keyword = $key -replace '[Ii]d$', ''
            $match   = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" } | Select-Object -First 1

            $resolved[$key] = if ($match) {
                [int]$global:capturedIds[$match]
            } else {
                $value
            }
        } else {
            $resolved[$key] = $value
        }
    }

    return $resolved
}

. "$PSScriptRoot\ResolveEndpoints.ps1"
. "$PSScriptRoot\TestFramework.ps1" -baseUrl $baseUrl -accessToken $accessToken
. "$PSScriptRoot\EndpointPriority.ps1" 

# =====================
# 1. Load endpoints
# =====================
$endpoints = Get-ApiEndpoints -openApiSpecPath $openApiSpecPath | Sort-Object {
    Get-EndpointPriority -path $_.Path -method $_.Method
}

$endpoints = $endpoints | Where-Object {
    $path   = $_.Path
    $method = $_.Method

    # Filter by method
    if ($method -notin $methods) { return $false }

    # Skip paths containing any of the skip strings
    foreach ($skip in $skipPaths) {
        if ($skip -and $path -like "*$skip*") { return $false }
    }

    return $true
}

# =====================
# 2. Run tests
# =====================

foreach ($endpoint in $endpoints) {
    $method       = $endpoint.Method
    $resolvedPath = (Resolve-PathParameters -path $endpoint.Path) + 
                (Resolve-QueryParameters -parameters $endpoint.Parameters)


    Write-Host "  -> $($method.ToUpper()) $resolvedPath" -NoNewline

    $passed = switch ($method) {
        'post'   { RunPostRequest   -url $resolvedPath -body (Resolve-RequestBody -body $endpoint.RequestBody) }
        'get'    { RunGetRequest    -url $resolvedPath }
        'put'    { RunPutRequest    -url $resolvedPath -body (Resolve-RequestBody -body $endpoint.RequestBody) }
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
# 3. Print summary
# =====================
Write-Host ""
Write-TestSummary

# =====================
# 4. Fail if any test failed (for CI pipelines)
# =====================

$summary = Get-TestSummary
if ($failOnTestFailures -and $summary.Failed -gt 0) {
    # Azure DevOps
    Write-Host "##vso[task.logissue type=error]$($summary.Failed) test(s) failed"
    # GitHub Actions
    Write-Host "::error::$($summary.Failed) test(s) failed"
    exit 1
}


# Helper functions
