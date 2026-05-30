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
        $requestBody = $null  # <-- reset each iteration!

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
            Parameters = $_.Detail.parameters
        })
    }

    return $requestArray
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
        # Check captured IDs first
        $keyword  = $param.name -replace 'id$', '' -replace 'Id$', ''
        $match    = $global:capturedIds.Keys | Where-Object { $_ -like "*$keyword*" } | Select-Object -First 1
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
