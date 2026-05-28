# TestRunner.ps1
# Orchestrates test execution using ResolveEndpoints and TestFramework

param(
    [string]$openApiSpecPath = "$PSScriptRoot\swagger.json",
    [string]$baseUrl         = "https://localhost:7194",
    [string]$accessToken     = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwidW5pcXVlX25hbWUiOiJhZG1pbiIsImp0aSI6ImVkNmUyOGY3LWViNTItNDdmMS05M2ZjLTdiMWRjMTExMWMwZiIsImh0dHA6Ly9zY2hlbWFzLm1pY3Jvc29mdC5jb20vd3MvMjAwOC8wNi9pZGVudGl0eS9jbGFpbXMvcm9sZSI6IkFkbWluIiwiZXhwIjoxNzc5OTY2Nzc0LCJpc3MiOiJHQ29tcGV0aXRpb25zQVBJIiwiYXVkIjoiR0NvbXBVc2VycyJ9.gAjPDpOlkwdmQjrlCMCWc75BnXd7ukLueSB_Gn6WBek",

    # Pipeline options
    [bool]$failOnTestFailures = $true,
    [string[]]$skipPaths      = @(),
    [string[]]$methods        = @('get','post'),
    [bool]$showDetailedErrors = $true

    )

. "$PSScriptRoot\ResolveEndpoints.ps1"
. "$PSScriptRoot\TestFramework.ps1" -baseUrl $baseUrl -accessToken $accessToken

# =====================
# 1. Load endpoints
# =====================
$endpoints = Get-ApiEndpoints -openApiSpecPath $openApiSpecPath

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
$methodGroups = $endpoints | Group-Object -Property Method

foreach ($group in $methodGroups) {
    Write-Host "`nRunning $($group.Name.ToUpper()) tests..." -ForegroundColor Cyan

    foreach ($endpoint in $group.Group) {
        Write-Host "  -> $($group.Name.ToUpper()) $($endpoint.Path)" -NoNewline

        $passed = switch ($group.Name) {
            'post'   { RunPostRequest   -url $endpoint.Path -body $endpoint.RequestBody }
            'get'    { RunGetRequest    -url $endpoint.Path }
            'put'    { RunPutRequest    -url $endpoint.Path -body $endpoint.RequestBody }
            'delete' { RunDeleteRequest -url $endpoint.Path }
        }

        if ($passed) {
            Write-Host "  PASSED" -ForegroundColor Green
        } else {
            Write-Host "  FAILED" -ForegroundColor Red

            if ($showDetailedErrors) {
                $last = $script:resultArray | Select-Object -Last 1
                Format-ErrorBody -body $last.Body -statusCode $last.StatusCode
            }
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