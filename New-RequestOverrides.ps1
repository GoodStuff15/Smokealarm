function New-RequestOverrides {
    param (
        [string]$openApiSpecPath = ".\swagger.json",
        [string]$outputPath      = ".\requestOverrides.json"
    )

    . "$PSScriptRoot\ResolveEndpoints.ps1"

    $existingOverrides = @{}
    if (Test-Path $outputPath) {
        $existing = Get-Content -Raw -Path $outputPath | ConvertFrom-Json
        foreach ($entry in $existing) {
            $key = "$($entry.method.ToUpper()):$($entry.path)"
            $existingOverrides[$key] = $entry
        }
        Write-Host "Found existing overrides file — merging new endpoints only" -ForegroundColor DarkCyan
    }

    $spec    = Get-Content -Raw -Path $openApiSpecPath | ConvertFrom-Json
    $schemas = $spec.components.schemas
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($pathItem in $spec.paths.PSObject.Properties) {
        $path = $pathItem.Name

        foreach ($methodItem in $pathItem.Value.PSObject.Properties) {
            $method = $methodItem.Name
            $detail = $methodItem.Value
            $detail = $detail | ConvertTo-Json -Depth 20 | ConvertFrom-Json

            $key = "$($method.ToUpper()):$($path)"

            # Keep existing entry if it exists — preserves manual edits
            if ($existingOverrides.ContainsKey($key)) {
                $null = $entries.Add($existingOverrides[$key])
                continue
            }

            # Otherwise generate new entry
            $entry = [ordered]@{
                method  = $method.ToUpper()
                path    = $path
                enabled = $false
            }

            # Path parameters
            $pathParams = $detail.parameters | Where-Object { $_.in -eq 'path' }
            if ($pathParams) {
                $entry['pathParameters'] = [ordered]@{}
                foreach ($param in $pathParams) {
                    $entry['pathParameters'][$param.name] = switch ($param.schema.type) {
                        'integer' { 1 }
                        'string'  { 'value' }
                        default   { 1 }
                    }
                }
            }

            # Query parameters
            $queryParams = $detail.parameters | Where-Object { $_.in -eq 'query' }
            if ($queryParams) {
                $entry['queryParameters'] = [ordered]@{}
                foreach ($param in $queryParams) {
                    $entry['queryParameters'][$param.name] = switch ($param.schema.type) {
                        'integer' { 1 }
                        'string'  { 'value' }
                        'boolean' { $false }
                        default   { 'value' }
                    }
                }
            }

            # Request body
            try {
                $content = $detail.requestBody.content
                if ($content) {
                    $firstContent       = $content.PSObject.Properties | Select-Object -First 1
                    $requestBodyContent = $firstContent.Value.schema
                    if ($requestBodyContent.'$ref') {
                        $dtoName       = extractDtoName -refString $requestBodyContent.'$ref'
                        $entry['body'] = BuildRequestBody -dtoName $dtoName -schemas $schemas
                    } elseif ($requestBodyContent.type -eq 'array') {
                        $entry['body'] = @(1)
                    }
                }
            } catch {
                Write-Host "DEBUG body error for $method $path : $_" -ForegroundColor Red
            }

            $null = $entries.Add($entry)
        }
    }

    $entries | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputPath -Encoding utf8
    Write-Host "Request overrides generated: $outputPath" -ForegroundColor Cyan
    Write-Host "Set 'enabled: true' on any entry to use it instead of the auto-generated request." -ForegroundColor DarkCyan
}