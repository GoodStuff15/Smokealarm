# TestRunner.ps1
# Orchestrates test execution using ResolveEndpoints, EndpointPriority, AuthFlow, EndpointWarnings and TestFramework

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
    [string[]]$skipPaths      = @('auth'),
    [string[]]$methods        = @('get','post', 'put', 'delete'),
    [bool]$showDetailedErrors = $true,
    [bool]$saveReports = $true,
    [int]$maxReports = 10,
    [int]$maxAgeDays = 10,
    [string[]]$postOrder = @()

    )

    $global:capturedIds = @{}
    $script:creationOrder = [System.Collections.Generic.List[PSCustomObject]]::new()
    $script:getResponses = [System.Collections.Generic.Dictionary[string, object]]::new()
    $script:warnings = [System.Collections.Generic.List[PSCustomObject]]::new()


function Get-CapturedId {
    param ([string]$paramName, [string]$path)

    $keyword = $paramName -replace '[Ii]ds$', '' -replace '[Ii]d$', ''

if ([string]::IsNullOrWhiteSpace($keyword)) {
    $segments = $path.Trim('/') -split '/'
    
    $keyword = $null
    # Try segments in reverse order, skipping action words
    $candidates = $segments | Where-Object { 
        $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' -and 
        $_ -notmatch '^(create|add|update|delete|remove|get|list|by|change|set|activate|deactivate|snapshot|report|advance)$'
    } | Select-Object -Last 3

    foreach ($segment in ($candidates | Sort-Object { $candidates.IndexOf($_) } -Descending)) {
        $parts = @()
        # Split on dashes
        $parts += $segment -split '-'
        # Split camelCase — reverse order so last word before Id is tried first
        # e.g. competitionRoundStageId -> Stage, Round, competition (Stage wins)
        $camelParts = [regex]::Matches($segment, '[A-Z]?[a-z]+|[A-Z]+(?=[A-Z]|$)') | 
            ForEach-Object { $_.Value }
        # Remove trailing 'Id'/'Ids' part and reverse so most specific (last) comes first
        $camelParts = $camelParts | Where-Object { $_ -notmatch '^[Ii]ds?$' }
        [array]::Reverse($camelParts)
        $parts += $camelParts
        
        foreach ($part in $parts) {
            $part = $part -replace '[Ii]ds$', '' -replace '[Ii]d$', ''
            if ($part.Length -gt 2) {
                $exact = $global:capturedIds.Keys | Where-Object { $_ -eq $part.ToLower() } | Select-Object -First 1
                $partial = $global:capturedIds.Keys | Where-Object { $_ -like "*$part*" } | Select-Object -First 1
                if ($exact -or $partial) {
                    $keyword = $part.ToLower()
                    break
                }
            }
        }
        if ($keyword) { break }
    }

    # If still no match, just use the first meaningful segment as keyword
    if (-not $keyword) {
        $keyword = $candidates | Select-Object -First 1
        if ($keyword) { $keyword = $keyword.ToLower() }
    }
    
}

    if ($keyword) {

        $splitPath = $path.Trim('/') -split '/' | Where-Object { $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' -and $_ -notmatch 'create|add|update|delete|get|list|change|set|remove|activate|deactivate' }

        $match = $global:capturedIds.Keys | Where-Object { $_ -eq $keyword } | Select-Object -First 1

        #First try to resolve from path segments if exact keyword match not found
        if(-not $match) {
            $match = $splitPath | Where-Object { $global:capturedIds.Keys -like "*$_*" } | Select-Object -First 1
        }
        if (-not $match) {
            $match = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" } | Select-Object -First 1
        }

        if ($match) {
        return [string]$global:capturedIds[$match]
        }
    }

    Write-Host "  WARNING: No captured ID found for '$paramName' in '$path', using 1" -ForegroundColor DarkYellow
    return '1'
}

function Save-ResponseId {
    param (
        [string]$path, 
        [string]$body,
        [bool]$overwrite = $false,
        [string]$resourceHint = $null
    )

    if ([string]::IsNullOrWhiteSpace($body)) { return }

    try {
        $parsed = $body | ConvertFrom-Json

        $items  = @($parsed)
        foreach ($item in $items) {
            Get-IdsFromObject -obj $item -path $path -overwrite $overwrite -resourceHint $resourceHint
        }
    } catch {
        Write-Host "  WARNING: Could not parse response body for ID extraction" -ForegroundColor DarkYellow
    }
}

function Get-IdsFromObject {
    param (
        [object]$obj,
        [string]$path,
        [int]$depth = 0,
        [bool]$overwrite = $false,
        [string]$resourceHint = $null
    )

    if ($depth -gt 10 -or $null -eq $obj) { return }

    if ($obj -is [System.Object[]]) {
        foreach ($item in $obj) {
            Get-IdsFromObject -obj $item -path $path -depth ($depth + 1) -overwrite $overwrite
        }
        return
    }

    if ($obj.PSObject.Properties) {
        foreach ($prop in $obj.PSObject.Properties) {
            $name  = $prop.Name
            $value = $prop.Value

            if ($null -eq $value) { continue }

            if (($name -eq 'id' -or $name -eq 'Id' -or $name -match '[Ii]d$') -and 
                ($value -is [int] -or $value -is [long])) {

                # Skip plain 'id' fields in nested objects — they belong to a different resource
                if (($name -eq 'id' -or $name -eq 'Id') -and $depth -gt 0) { continue }

                $key = if (($name -eq 'id' -or $name -eq 'Id') -and $resourceHint) {
                    # Plain 'id' — use hint
                    $resourceHint.ToLower()
                } elseif ($name -eq 'id' -or $name -eq 'Id') {
                    # Plain 'id' — derive from path
                    $segments = $path.Trim('/') -split '/'
                    $segments | Where-Object { 
                        $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' -and $_ -notmatch 'create|add|update|delete|get|list'
                    } | Select-Object -Last 1 | ForEach-Object { $_.ToLower() }
                } else {
                    # Named property like 'participantId' — always derive from property name
                    ($name -replace '[Ii]ds$', '' -replace '[Ii]d$', '').ToLower()
                }

                if ($key -and $value) {
                    if ($overwrite -or -not $global:capturedIds.ContainsKey($key)) {
                        $global:capturedIds[$key] = $value
                    }
                }
            }

            if ($value -is [System.Management.Automation.PSCustomObject] -or 
                $value -is [System.Object[]]) {
                Get-IdsFromObject -obj $value -path $path -depth ($depth + 1) -overwrite $overwrite
            }
        }
    }
}

function Resolve-RequestBody {
    param (
        [object]$body,
        [string]$path = ""
    )

    if (-not $body) { return $body }

    # Handle raw array bodies
    if ($body -is [array] -or $body -is [System.Collections.Generic.List[object]]) {
        $firstItem = @($body)[0]

        if ($firstItem -is [System.Collections.Specialized.OrderedDictionary] -or 
            $firstItem -is [hashtable] -or
            $firstItem -is [System.Management.Automation.PSCustomObject]) {
            $resolved = @($body | ForEach-Object { Resolve-RequestBody -body $_ -path $path })
            return [object[]]@($resolved)
        }

        $segments = $path.Trim('/') -split '/'
        $meaningfulSegments = $segments | Where-Object {
            $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' -and
            $_ -notmatch '^(create|add|update|remove|delete|get|list|register|by)$'
        }

        $keyword = $null
        foreach ($segment in ($meaningfulSegments | Sort-Object { $meaningfulSegments.IndexOf($_) } -Descending)) {
            if ($segment -match '-') {
                $parts = $segment -split '-' | Where-Object {
                    $_ -notmatch '^(create|add|update|remove|delete|get|list|register|by)$' -and $_.Length -gt 2
                }
                if ($parts) {
                    $keyword = ($parts | Select-Object -Last 1) -replace 's$', ''
                    break
                }
            } else {
                $keyword = $segment -replace 's$', '' -replace '[Ii]ds$', '' -replace '[Ii]d$', ''
                break
            }
        }

        $keyword = $keyword.ToLower()
        $matching = $global:capturedIds.Keys | Where-Object { $_ -eq $keyword } | Select-Object -First 1
        if (-not $matching) {
            $matching = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" } | Select-Object -First 1
        }
        if ($matching) {
            return [object[]]@([int]$global:capturedIds[$matching])
        }
        return [object[]]@($body)
    }

    $baseBody = $null
    if ($path -and $script:getResponses) {
        $segments = $path.Trim('/') -split '/'
        $resource = $segments | Where-Object {
            $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' -and $_ -notmatch 'get|list|by'
        } | Select-Object -First 1

        if ($resource -and $script:getResponses.ContainsKey($resource.ToLower())) {
            $baseBody = $script:getResponses[$resource.ToLower()]
            Write-Host "  USING GET RESPONSE as base for PUT: $($resource.ToLower())" -ForegroundColor DarkCyan
        }
    }

    # Determine current resource from path for self-reference detection
    $currentResource = $path.Trim('/') -split '/' |
        Where-Object { $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' } |
        Select-Object -First 1

    $obj = [ordered]@{}

    $properties = if ($body -is [hashtable] -or $body -is [System.Collections.Specialized.OrderedDictionary]) {
        $body.Keys | ForEach-Object { [PSCustomObject]@{ Name = $_; Value = $body[$_] } }
    } else {
        $body.PSObject.Properties
    }

    foreach ($prop in $properties) {
        $key   = $prop.Name
        $value = $prop.Value

        if ($baseBody -and $baseBody.PSObject.Properties[$key]) {
            $getValue = $baseBody.PSObject.Properties[$key].Value
            if ($null -ne $getValue) {
                $obj[$key] = $getValue
                continue
            }
        }

        if ($null -eq $value) {
            $obj[$key] = $null
            continue
        }

        if ($value.GetType().Name -like 'List*' -or $value -is [array] -or
            $value -is [System.Collections.ArrayList]) {
            $keyword  = $key -replace '[Ii]ds$', '' -replace '[Ii]d$', ''
            $matching = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" }
            
            $arr = if ($matching) {
                [int[]]@($matching | ForEach-Object { [int]$global:capturedIds[$_] })
            } else {
                $firstVal = @($value)[0]
                if ($firstVal -is [int] -or $firstVal -is [long]) {
                    [int[]]@($value)
                } else {
                    [object[]]@($value)
                }
            }
            $obj[$key] = [object[]]@($arr)

        } elseif ($value -is [int] -or $value -is [long]) {
            $keyword      = $key -replace '[Ii]ds$', '' -replace '[Ii]d$', ''
            $shortKeyword = ([regex]::Match($key, '([A-Z][a-z]+)(?:[Ii]d)?$').Groups[1].Value).ToLower()

            # Detect self-referential fields
            $isSelfRef = $currentResource -and (
                $shortKeyword -eq $currentResource.ToLower().TrimEnd('s') -or
                $keyword -like "*$($currentResource.ToLower().TrimEnd('s'))*"
            )

            $match = $global:capturedIds.Keys | Where-Object { $_ -eq $shortKeyword } | Select-Object -First 1
            if ($match -and [int]$global:capturedIds[$match] -eq 0) { $match = $null }
            if (-not $match) {
                $match = $global:capturedIds.Keys | Where-Object { $_ -eq $keyword } | Select-Object -First 1
            }
            if (-not $match) {
                $match = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" } | Select-Object -First 1
            }

            $obj[$key] = if ($match) {
                [int]$global:capturedIds[$match]
            } elseif ($isSelfRef) {
                $null  # self-referential and nothing captured yet — send null
            } else {
                $value
            }
        } else {
            $obj[$key] = $value
        }
    }
    return $obj
}

function Get-ResponseDtoName {
    param ($endpoint)

    try {
        $responses = $endpoint.Responses

        $ok = $responses.PSObject.Properties['200'].Value

        if (-not $ok) { return $null }

        $content = $ok.content
        if (-not $content) { return $null }

        # Use PSObject.Properties to handle 'application/json' key with dot
        $jsonContent = $content.PSObject.Properties['application/json'].Value
        if (-not $jsonContent) { return $null }

        $schema = $jsonContent.schema
        if (-not $schema) { return $null }

        if ($schema.'$ref') {
            $test = extractDtoName -refString "#/components/schemas/CreateScheduleRequest"
            Write-Host "  Extracted DTO name from $($schema.'$ref'): $test" -ForegroundColor DarkCyan
            return extractDtoName -refString $schema.'$ref'
        }

        if ($schema.type -eq 'array' -and $schema.items.'$ref') {
            return extractDtoName -refString $schema.items.'$ref'
        }
    } catch {
    }

    return $null
}

. "$PSScriptRoot\EndpointPriority.ps1" 
. "$PSScriptRoot\ResolveEndpoints.ps1"
. "$PSScriptRoot\TestFramework.ps1" -baseUrl $baseUrl -accessToken $accessToken
. "$PSScriptRoot\AuthFlow.ps1"
. "$PSScriptRoot\EndpointWarnings.ps1"
. "$PSScriptRoot\New-RequestOverrides.ps1"
. "$PSScriptRoot\GenerateOverrides.ps1"

$script:requestOverrides = Get-RequestOverrides

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

$endpoints = Get-SortedEndpoints -endpoints $apiData.Endpoints -schemas $apiData.Schemas -postOrder $postOrder


    # ===
    # 2.5 Check for endpoint warnings
    # ===
    Test-EndpointWarnings -endpoints $endpoints


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

# Pass 1 — run everything except deletes
foreach ($endpoint in ($endpoints | Where-Object { $_.Method -ne 'delete' })) {

    $method       = $endpoint.Method
    $overrideKey  = "$($method.ToUpper()):$($endpoint.Path)"
$override     = $script:requestOverrides[$overrideKey]

if ($override) {
    # Use manual override
    $resolvedPath = $endpoint.Path
    
    # Apply path parameters
    if ($override.pathParameters) {
        foreach ($param in $override.pathParameters.PSObject.Properties) {
            $resolvedPath = $resolvedPath -replace "\{$($param.Name)\}", $param.Value
        }
    }
    
    # Apply query parameters
    if ($override.queryParameters) {
        $queryString = ($override.queryParameters.PSObject.Properties | ForEach-Object {
            "$($_.Name)=$($_.Value)"
        }) -join '&'
        $resolvedPath = "$resolvedPath?$queryString"
    }

    $resolvedBody = if ($override.body) {
        $override.body
    } else { $null }

    $isManualOverride = $true
} else {
    # Normal auto-resolution
    $resolvedPath = (Resolve-PathParameters -path $endpoint.Path) +
                    (Resolve-QueryParameters -parameters $endpoint.Parameters)
    $resolvedBody = if ($method -eq 'post' -or $method -eq 'put') {
        Resolve-RequestBody -body $endpoint.RequestBody -path $endpoint.Path
    } else { $null }

    $isManualOverride = $false
}

    Write-Host "  -> $($method.ToUpper()) $resolvedPath" -NoNewline

    $passed = switch ($method) {
        'post' { RunPostRequest -url $resolvedPath -body $resolvedBody }
        'get'  { RunGetRequest  -url $resolvedPath }
        'put'  { RunPutRequest  -url $resolvedPath -body $resolvedBody }
    }

    if ($passed) {
        Write-Host "  PASSED" -ForegroundColor Green
        if ($method -eq 'post') {
            $last = $script:resultArray | Select-Object -Last 1
            Save-ResponseId -path $endpoint.Path -body $last.Body -overwrite $true

            # Track creation order for reverse delete
            $null = $script:creationOrder.Add($endpoint)
        } elseif ($method -eq 'get') {
        $last        = $script:resultArray | Select-Object -Last 1
        $dtoName     = Get-ResponseDtoName -endpoint $endpoint

        $resourceHint = if ($dtoName) {
            ($dtoName -replace '^Get', '' -replace 'ResponseDto$','' -replace 'Response$', '' -replace 'Dto$', '' -replace 'Result$', '').ToLower()
        } else { $null }

        Save-ResponseId -path $endpoint.Path -body $last.Body -overwrite $false -resourceHint $resourceHint

        # Save GET response for PUT pre-population
        if ($last.Body -and $resourceHint) {
            try {
                $parsed = @($last.Body | ConvertFrom-Json)
                if ($parsed[0]) {
                    $script:getResponses[$resourceHint] = $parsed[0]
                    Write-Host "  SAVED GET: $resourceHint (from DTO: $dtoName)" -ForegroundColor DarkCyan
                }
            } catch {}
        }
    }
    
    } 
    else {
        Write-Host "  FAILED" -ForegroundColor Red
        if ($showDetailedErrors) {
            $last = $script:resultArray | Select-Object -Last 1
            Format-ErrorBody -body $last.Body -statusCode $last.StatusCode
        }
    }

}

# Pass 2 — run deletes in reverse creation order
$allDeletes = $endpoints | Where-Object { $_.Method -eq 'delete' }

# Sort deletes by matching them to creation order, reversed                                                                                                                                                                                                                                 
$orderedDeletes = [System.Collections.Generic.List[object]]::new()

# First add deletes that match a created resource, in reverse order
for ($i = $script:creationOrder.Count - 1; $i -ge 0; $i--) {
    $created = $script:creationOrder[$i]
    $postSegment = $created.Path.Trim('/') -split '/' | 
                            Where-Object { $_ -notmatch '^api$|^\{|\d+|create|add|update|delete' } | 
                            Select-Object -First 1

    $match = $allDeletes | Where-Object {
        $delSegment = $_.Path.Trim('/') -split '/' |                                                                                                                
                    Where-Object { $_ -notmatch '^api$|^\{|\d+|create|add|update|delete' } | 
                    Select-Object -First 1
        $delSegment -eq $postSegment
    } | Select-Object -First 1

    if ($match -and -not ($orderedDeletes | Where-Object { $_.Path -eq $match.Path })) {
        $null = $orderedDeletes.Add($match)
    }
}

# Then add any unmatched deletes at the end
foreach ($ep in $allDeletes) {
    if (-not ($orderedDeletes | Where-Object { $_.Path -eq $ep.Path })) {
        $null = $orderedDeletes.Add($ep)
    }
}

foreach ($endpoint in $orderedDeletes) {
    $resolvedPath = Resolve-PathParameters -path $endpoint.Path

    Write-Host "  -> DELETE $resolvedPath" -NoNewline

    $passed = RunDeleteRequest -url $resolvedPath

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

