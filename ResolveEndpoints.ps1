    . "$PSScriptRoot\EndpointWarnings.ps1"

    function Get-RequestOverrides {
    param ([string]$overridesPath = ".\requestOverrides.json")

    if (-not $overridesPath -or -not (Test-Path $overridesPath)) { return @{} }

    $overrides = Get-Content -Raw -Path $overridesPath | ConvertFrom-Json
    $map       = @{}

    foreach ($override in $overrides) {
        if ($override.enabled -ne $true) { continue }
        $key        = "$($override.method.ToUpper()):$($override.path)"
        $map[$key]  = $override
    }

    Write-Host "Loaded $($map.Count) active request override(s)" -ForegroundColor Cyan
    return $map
}

function Get-ApiEndpoints {
    param(
        [string]$openApiSpecPath = "swagger.json"
    )


    $openApiSpec = Get-Content -Raw -Path $openApiSpecPath | ConvertFrom-Json
    $schemas = $openApiSpec.components.schemas

    $pathArray = @($openApiSpec.paths.PSObject.Properties | ForEach-Object {
        $path = $_.Name
        $_.Value.PSObject.Properties | ForEach-Object {
            [PSCustomObject]@{
                Path   = $path
                Method = $_.Name
                Detail = $_.Value
            }
        }
    })

    $requestArray = [System.Collections.Generic.List[PSObject]]::new()

    $pathArray | ForEach-Object {
        $requestBody = $null

    if ($_.Detail.requestBody) {
        $contentSchema = $_.Detail.requestBody.content.PSObject.Properties['application/json'].Value.schema
        
        if ($contentSchema.'$ref') {
            # Normal DTO ref
            $dtoName     = extractDtoName -refString $contentSchema.'$ref'
            $requestBody = BuildRequestBody -dtoName $dtoName -schemas $schemas
        } elseif ($contentSchema.type -eq 'array') {

            Add-Warning -type "Raw Array Body" -message "$($_.Method.ToUpper()) $($_.Path) has a raw array request body — ID injection is based on path keyword matching and may not be accurate"

            $itemType = $contentSchema.items.type
            $itemRef  = $contentSchema.items.'$ref'

            if ($itemRef) {
                $refName     = extractDtoName -refString $itemRef
                $requestBody = @(BuildRequestBody -dtoName $refName -schemas $schemas)
            } else {
                $requestBody = switch ($itemType) {
                    'integer' { @(1) }
                    'string'  { @('test') }
                    default   { @(1) }
                }
            }
        }
    }

        $requestArray.Add([PSCustomObject]@{
            Path        = $_.Path
            Method      = $_.Method
            RequestBody = $requestBody
            Parameters  = $_.Detail.parameters
            Responses   = $_.Detail.responses
            RequestBodyRef = if ($_.Detail.requestBody) {
                $_.Detail.requestBody.content.PSObject.Properties['application/json'].Value.schema.'$ref'
            } else { $null }
        })
    }

    return [PSCustomObject]@{
        Endpoints = $requestArray
        Schemas   = $schemas
    }
}


function Resolve-PropertyValue {
    param (
        $propSchema,
        $schemas
    )


    $ref  = $propSchema.'$ref'
    $type = $propSchema.type

    if ($ref) {
        $refName   = extractDtoName -refString $ref
        $refSchema = $schemas.PSObject.Properties[$refName].Value

        if ($refSchema.enum) {
            return $refSchema.enum[0]
        } elseif ($refSchema.type -eq 'object') {
            return BuildRequestBody -dtoName $refName -schemas $schemas
        }
        return $null
    }

    if ($propSchema.enum) {
        return $propSchema.enum[0]
    }

    $value = switch ($type) {
        'integer' { 1 }
        'number'  { 0.0 }
        'boolean' { $false }
        'string'  {
            switch -Wildcard ($propSchema.format) {
                'date-time' { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                'date'      { (Get-Date).ToString('yyyy-MM-dd') }
                default     { 'test' }
            }
        }
        'array' {
            $items    = $propSchema.items
            $itemType = if ($items) { $items.type } else { 'integer' }
            $itemRef  = if ($items) { $items.'$ref' } else { $null }

            $list = [System.Collections.Generic.List[object]]::new()

            if ($itemRef) {
                $refName = extractDtoName -refString $itemRef
                $null = $list.Add((BuildRequestBody -dtoName $refName -schemas $schemas))
            } elseif ($items -and $items.enum) {
                $null = $list.Add($items.enum[0])
            } else {
                switch ($itemType) {
                    'integer' { $null = $list.Add(1); $null = $list.Add(2) }
                    'number'  { $null = $list.Add(1.0) }
                    'string'  { $null = $list.Add('test') }
                    default   { $null = $list.Add(1) }
                }
            }
            ,$list
        }
        'object'  { @{} }
        default   { $null }
    }

    return ,$value
}

function extractDtoName {
    param (
        [string]$refString
    )
    if ($refString -match '#/components/schemas/(.+)') {
        return $matches[1]
    }
    return $null
}

function BuildRequestBody {
    param (
        [string]$dtoName,
        $schemas
    )

    $schema = $schemas.PSObject.Properties[$dtoName].Value

    $body = [ordered]@{}

    foreach ($prop in $schema.properties.PSObject.Properties) {

    # resolve
    $val = Resolve-PropertyValue -propSchema $prop.Value -schemas $schemas

    if ($val -is [System.Collections.Generic.List[object]]) {
        $body[$prop.Name] = $val
    } elseif ($val -is [System.Collections.ArrayList] -or $val -is [array]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $val) { $null = $list.Add($item) }
        $body[$prop.Name] = $list
    } else {
        $body[$prop.Name] = $val
    }
}
    return $body
}



function Resolve-QueryParameters {
    param ($parameters)

    if (-not $parameters) { return '' }

    $queryParams = $parameters | Where-Object { $_.in -eq 'query' }
    if (-not $queryParams) { return '' }

    $parts = foreach ($param in $queryParams) {
        $keyword = $param.name -replace 'Id$', ''

        # 1. Exact match (keyword = keyword)
        $match = $global:capturedIds.Keys | Where-Object { $_ -eq $keyword } | Select-Object -First 1

        # 2. Exact match ignoring case (kEyWoRd = keyword)
        if (-not $match) {
            $match = $global:capturedIds.Keys | Where-Object { $_ -ieq $keyword } | Select-Object -First 1
        }

        # 3. Prefer shortest key that contains the keyword (keywordId = keyword, someOtherKeywordId != keyword)")
        if (-not $match) {
            $match = $global:capturedIds.Keys |
                Where-Object { $_ -like "*$keyword*" } |
                Sort-Object Length |
                Select-Object -First 1
        }

        $captured = if ($match) { [string]$global:capturedIds[$match] } else { $null }

        $value = if ($captured) {
            $captured
        } else {
            switch ($param.schema.type) {
                'integer' { '1' }
                'number'  { '0.0' }
                'boolean' { 'true' }
                'string'  {
                    switch ($param.schema.format) {
                        'date-time' { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                        'date'      { (Get-Date).ToString('yyyy-MM-dd') }
                        default     {
                            if ($param.schema.enum) { [string]$param.schema.enum[0] }
                            else { $null }  # skip unknown strings — avoids invalid enum values
                        }
                    }
                }
                default { '1' }
            }
        }

        if ($null -ne $value) { "$($param.name)=$value" }
    }

    if ($parts) { return '?' + ($parts -join '&') } else { return '' }
}


function Resolve-PathParameters {
    param ([string]$path)

    return [regex]::Replace($path, '\{([^}]+)\}', {
        param($match)
        $paramName = $match.Groups[1].Value  # just the name, no braces
        return Get-CapturedId -paramName $paramName -path $path
    })
}

function Get-EndpointDependencies {
    param (
        [array]$endpoints,
        $schemas
    )

    $producers = @{}

foreach ($ep in $endpoints) {

    if ($ep.Method -ne 'post') { continue }

    $segments = $ep.Path.Split('/') | Where-Object { $_ -and $_ -notmatch '^api$' }
    if ($segments.Count -gt 0) {
        $resource = ([string]$segments[0]).ToLower().TrimEnd('s')

        # Only register plain POSTs as producers — skip action endpoints and parameterised paths
        $isPlain = $ep.Path -notmatch '\{' -and $segments.Count -eq 1
        $isCreate = $ep.Path -match 'create$' -and $ep.Path -notmatch '\{'

        if ($isPlain -or $isCreate) {
            if (-not $producers.ContainsKey($resource) -or $isCreate) {
                $producers[$resource] = $ep.Path
            }
        }
    }
}

    $dependencies = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()

    foreach ($ep in $endpoints) {
        $key  = "$($ep.Method):$($ep.Path)"
        $deps = [System.Collections.Generic.List[string]]::new()

        # Check path parameters
        $paramMatches = [regex]::Matches($ep.Path, '\{(\w+)\}')
        foreach ($match in $paramMatches) {
            $paramName = $match.Groups[1].Value.ToLower().TrimEnd('s') -replace 'id$', ''
            foreach ($resource in $producers.Keys) {
                if ($paramName -like "*$resource*" -or $resource -like "*$paramName*") {
                    $depPath = $producers[$resource]
                    if ($depPath -ne $ep.Path -and -not $deps.Contains($depPath)) {  # skip self
                        $null = $deps.Add($depPath)
                    }
                }
            }
        }

        # Check request body fields

        if ($ep.RequestBodyRef) {
            $dtoName = extractDtoName -refString $ep.RequestBodyRef
            $schema  = $schemas.PSObject.Properties[$dtoName].Value
            if ($schema -and $schema.properties) {
                                foreach ($prop in $schema.properties.PSObject.Properties) {
                    $propName = $prop.Name.ToLower()
                    if ($propName -notlike "*id*") { continue }
                    
                    # Strip 'id' suffix to get the resource name hint
                    $hint = $propName -replace 'id$', ''

                    # Also extract last camelCase word before 'Id' e.g. competitionRoundStageId -> stage
                    $shortHint = ($prop.Name -creplace '.*?([A-Z][a-z]+)Id$', '$1').ToLower()
                    
                    foreach ($resource in $producers.Keys) {
                        $normHint      = $hint.TrimEnd('s')
                        $normShortHint = $shortHint.TrimEnd('s')
                        $normResource  = $resource.TrimEnd('s')
                        
                        if ($normHint -eq $normResource -or 
                            $normResource -like "*$normHint*" -or 
                            $normHint -like "*$normResource*" -or
                            $normShortHint -eq $normResource) {
                            $depPath = $producers[$resource]
                            if ($depPath -ne $ep.Path -and -not $deps.Contains($depPath)) {
                                $null = $deps.Add($depPath)
                            }
                        }
                    }
                }
            }
        }


        # Action endpoints depend on their base resource creator
        $segments       = $ep.Path.Trim('/') -split '/'
        $resourceSegment = $segments | Where-Object { 
            $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' 
        } | Select-Object -First 1

  $actionWords   = 'create|add|update|remove|delete|report|advance|snapshot|refresh|register|activate|deactivate|change|set|list'
$actionSegment = $segments | Where-Object { $_ -match '-' -or $_ -match "^($actionWords)$" } | Select-Object -First 1

    if ($actionSegment -and $resourceSegment) {
        # Depend on base resource creator
        $creatorEp = $endpoints | Where-Object { 
            $_.Method -eq 'post' -and 
            $_.Path -match "/$resourceSegment/" -and 
            $_.Path -match 'create$'
        } | Select-Object -First 1

        if ($creatorEp -and -not $deps.Contains($creatorEp.Path)) {
            $null = $deps.Add($creatorEp.Path)
        }

        # PUTs also depend on GET for same resource — so ID is captured before PUT runs
        if ($ep.Method -eq 'put') {
            $getEps = $endpoints | Where-Object { $_.Method -eq 'get' } | Where-Object {
                $getResource = $_.Path.Trim('/') -split '/' | 
                            Where-Object { $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' } | 
                            Select-Object -First 1
                $getResource -eq $resourceSegment
            }
            
            foreach ($getEp in $getEps) {
                if (-not $deps.Contains($getEp.Path)) {
                    $null = $deps.Add($getEp.Path)
                }
            }
        }
    }

        $dependencies[$key] = $deps
    }
    

    return $dependencies
}

function Get-SortedEndpoints {
    param (
        [array]$endpoints,
        $schemas,
        [string[]]$postOrder = @()
    )
    
    $dependencies = Get-EndpointDependencies -endpoints $endpoints -schemas $schemas
    $sorted       = [System.Collections.Generic.List[object]]::new()
    $visited      = [System.Collections.Generic.HashSet[string]]::new()

    function Add-EndpointToSorted {
        param ($ep)
        $key = "$($ep.Method):$($ep.Path)"
        if ($visited.Contains($key)) { return }
        $null = $visited.Add($key)

        if ($dependencies.ContainsKey($key)) {
            foreach ($depPath in $dependencies[$key]) {
                $depEp = $endpoints | Where-Object { $_.Path -eq $depPath -and $_.Method -eq 'post' } | Select-Object -First 1
                if ($depEp) { Add-EndpointToSorted $depEp }
            }
        }

        $null = $sorted.Add($ep)
    }

# Phase 1 — plain POSTs in configured or dependency order

$plainPosts = $endpoints | Where-Object { 
    $_.Method -eq 'post' -and (Get-EndpointPriority -path $_.Path -method $_.Method) -lt 100 
}

if ($postOrder) {
    # Sort by position in configured list, unknowns go last
    $orderedPosts = $postOrder | ForEach-Object {
        $o = $_
        $plainPosts | Where-Object { $_.Path -eq $o } | Select-Object -First 1
    } | Where-Object { $_ }
    # Append any not in the list
    $remainder = $plainPosts | Where-Object { $_.Path -notin $postOrder }
    $orderedPosts = @($orderedPosts) + @($remainder)
} else {
    $orderedPosts = $plainPosts | Sort-Object { [int](Get-EndpointPriority -path $_.Path -method $_.Method) }
}

foreach ($ep in $orderedPosts) { 
    $key = "$($ep.Method):$($ep.Path)"
    if (-not $visited.Contains($key)) {
        $null = $visited.Add($key)
        $null = $sorted.Add($ep)  # bypass Add-EndpointToSorted entirely
    }
}

    # Phase 2 — everything else in priority order
    $rest = $endpoints |
        Where-Object { -not $visited.Contains("$($_.Method):$($_.Path)") } |
        Sort-Object { [int](Get-EndpointPriority -path $_.Path -method $_.Method) }

    foreach ($ep in $rest) { $null = $sorted.Add($ep) }

    return $sorted.ToArray()
}