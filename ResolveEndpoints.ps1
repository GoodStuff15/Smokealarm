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
            $refString = $_.Detail.requestBody.content."application/json".schema.'$ref'
            if ($refString) {
                $dtoName = extractDtoName -refString $refString
                $requestBody = BuildRequestBody -dtoName $dtoName -schemas $schemas
            }
        }

        $requestArray.Add([PSCustomObject]@{
            Path        = $_.Path
            Method      = $_.Method
            RequestBody = $requestBody
            Parameters  = $_.Detail.parameters
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

    $value = switch ($type) {
        'integer' { 2 }
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
            $itemType = if ($propSchema.items) { $propSchema.items.type } else { 'integer' }

            $list = [System.Collections.Generic.List[object]]::new()
            switch ($itemType) {
                'integer' { $null = $list.Add(1); $null = $list.Add(2) }
                'number'  { $list.Add(1.0) }
                'string'  { $list.Add('test') }
                default   { $list.Add(1) }
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
                'integer' { '2' }
                'number'  { '0.0' }
                'boolean' { 'true' }
                'string'  {
                    switch ($param.schema.format) {
                        'date-time' { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                        'date'      { (Get-Date).ToString('yyyy-MM-dd') }
                        default     { 'test' }
                    }
                }
                default { '2' }
            }
        }

        "$($param.name)=$value"
    }

    return '?' + ($parts -join '&')
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
            $resource = $segments[0].ToLower()
            $producers[$resource] = $ep.Path
        }

        if ($ep.Method -eq 'put' -and $actionSegment) {
            $getEp = $endpoints | Where-Object {
                $_.Method -eq 'get' -and
                $_.Path -match "/$resourceSegment/" -or $_.Path -match "/$resourceSegment$"
            } | Select-Object -First 1

            if ($getEp -and -not $deps.Contains($getEp.Path)) {
                $null = $deps.Add($getEp.Path)
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
            $paramName = $match.Groups[1].Value.ToLower()
            foreach ($resource in $producers.Keys) {
                if ($paramName -like "*$resource*") {
                    $null = $deps.Add($producers[$resource])
                }
            }
        }

        # Check request body fields
        if ($ep.Detail.requestBody) {
            $refString = $ep.Detail.requestBody.content."application/json".schema.'$ref'
            if ($refString) {
                $dtoName = extractDtoName -refString $refString
                $schema  = $schemas.PSObject.Properties[$dtoName].Value
                if ($schema -and $schema.properties) {
                    foreach ($prop in $schema.properties.PSObject.Properties) {
                        $propName = $prop.Name.ToLower()
                        foreach ($resource in $producers.Keys) {
                            if ($propName -like "*$resource*" -and $propName -like "*id*") {
                                $null = $deps.Add($producers[$resource])
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

        $actionSegment = $segments | Where-Object { $_ -match '-' } | Select-Object -First 1

        if ($actionSegment -and $resourceSegment) {
            $creatorEp = $endpoints | Where-Object { 
                $_.Method -eq 'post' -and 
                $_.Path -match "/$resourceSegment/" -and 
                $_.Path -match 'create$'
            } | Select-Object -First 1

            if ($creatorEp -and -not $deps.Contains($creatorEp.Path)) {
                $null = $deps.Add($creatorEp.Path)
            }
        }

        $dependencies[$key] = $deps
    }

    return $dependencies
}

function Get-SortedEndpoints {
    param (
        [array]$endpoints,
        $schemas
    )

    $dependencies = Get-EndpointDependencies -endpoints $endpoints -schemas $schemas
    $sorted       = [System.Collections.Generic.List[object]]::new()
    $visited      = [System.Collections.Generic.HashSet[string]]::new()

    function Visit-Endpoint {
        param ($ep)
        $key = "$($ep.Method):$($ep.Path)"
        if ($visited.Contains($key)) { return }
        $null = $visited.Add($key)

        if ($dependencies.ContainsKey($key)) {
            foreach ($depPath in $dependencies[$key]) {
                $depEp = $endpoints | Where-Object { $_.Path -eq $depPath -and $_.Method -eq 'post' } | Select-Object -First 1
                if ($depEp) { Visit-Endpoint $depEp }
            }
        }

        $null = $sorted.Add($ep)
    }

    # Manual priorities first
    $manualEps = $endpoints | Where-Object {
        (Get-EndpointPriority -path $_.Path -method $_.Method) -ne 999
    } | Sort-Object { Get-EndpointPriority -path $_.Path -method $_.Method }

    foreach ($ep in $manualEps) { Visit-Endpoint $ep }

    # Non-delete endpoints in dependency order
    # Introduce keyword-based sorting (e.g. register/login/create/add before update/remove/delete)
    $keywordOrder = @('register','login','create','add','get','list','update','remove','delete')
    $keywordPriority = @{ }
    for ($i = 0; $i -lt $keywordOrder.Count; $i++) { $keywordPriority[$keywordOrder[$i]] = $i }

    function Get-KeywordPriority {
        param([string]$path)
        $lower = $path.ToLower()
        foreach ($kw in $keywordOrder) {
            if ($lower -like "*${kw}*") { return $keywordPriority[$kw] }
        }
        return [int]$keywordOrder.Count
    }

    # Keep method ordering as a secondary key (POST -> GET -> PUT -> DELETE)
    $methodOrder = @{ 'post' = 1; 'get' = 2; 'put' = 3; 'delete' = 4 }
    function Get-MethodPriority { param([string]$m) return ($methodOrder[$m] -as [int]) }
    

    $nonDeleteSorted = $endpoints |
        Where-Object { $_.Method -ne 'delete' } |
        Sort-Object -Property @{Expression = { Get-KeywordPriority $_.Path }; Descending = $false}, @{Expression = { Get-MethodPriority $_.Method }; Descending = $false }

    foreach ($ep in $nonDeleteSorted) { Visit-Endpoint $ep }

    # Delete endpoints — reverse of their corresponding POST order
    $postPaths   = $endpoints | Where-Object { $_.Method -eq 'post' } | ForEach-Object { $_.Path }
    $deleteEps   = $endpoints | Where-Object { $_.Method -eq 'delete' }

    # Match each delete to its corresponding post path and sort in reverse
    $orderedDeletes = $postPaths | ForEach-Object {
        $postPath = $_
        # Find a delete endpoint whose path shares the same resource segment
        $deleteEps | Where-Object {
            $delSegments  = $_.Path.Trim('/') -split '/'
                $postSegments = $postPath.Trim('/') -split '/'
            $delResource  = $delSegments | Where-Object { $_ -notmatch '^api$|^\{|\d+|create|add|delete|update' } | Select-Object -First 1
            $postResource = $postSegments | Where-Object { $_ -notmatch '^api$|^\{|\d+|create|add|delete|update' } | Select-Object -First 1
            $delResource -eq $postResource
        } | Select-Object -First 1
    } | Where-Object { $_ } | Sort-Object { $postPaths.IndexOf($_.Path) } -Descending

    # Add any deletes that didn't match a post last
    $unmatchedDeletes = $deleteEps | Where-Object { 
        $ep = $_
        -not ($orderedDeletes | Where-Object { $_.Path -eq $ep.Path })
    }

    foreach ($ep in ($orderedDeletes + $unmatchedDeletes)) { 
        Visit-Endpoint $ep 
    }

    return $sorted.ToArray()
}