    
    function Add-Warning {
    param ([string]$type, [string]$message)
        
    $exists = $script:warnings | Where-Object { $_.Type -eq $type -and $_.Message -eq $message }
    if (-not $exists) {
        $null = $script:warnings.Add([PSCustomObject]@{
            Type    = $type
            Message = $message
        })
    }

}


function Test-EndpointWarnings {
    param ([array]$endpoints)

    foreach ($ep in $endpoints) {
        # Check for ambiguous {id} parameters
        $paramMatches = [regex]::Matches($ep.Path, '\{(\w+)\}')
        foreach ($match in $paramMatches) {
            $paramName = $match.Groups[1].Value
            if ($paramName -eq 'id' -or $paramName -eq 'Id') {
                Add-Warning -type "Ambiguous Path Parameter" -message "Ambiguous path parameter '{id}' in $($ep.Method.ToUpper()) $($ep.Path) — rename to a specific name like '{entityNameId}' to improve test accuracy"
            }
        }

        # Check for POST create endpoints with no corresponding DELETE
        if ($ep.Method -eq 'post' -and $ep.Path -match 'create$') {
            $resource = $ep.Path.Trim('/') -split '/' | 
                        Where-Object { $_ -notmatch '^api$|create' } | 
                        Select-Object -First 1
            $hasDelete = $endpoints | Where-Object { 
                $_.Method -eq 'delete' -and $_.Path -match "/$resource/"
            }
            if (-not $hasDelete) {
                Add-Warning -type "Missing DELETE Endpoint" -message "No DELETE endpoint found for resource '$resource' — created resources will not be cleaned up"
            }
        }

        # Check for PUT endpoints with no corresponding GET
        if ($ep.Method -eq 'put') {
            $resource = $ep.Path.Trim('/') -split '/' | 
                        Where-Object { $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' } | 
                        Select-Object -First 1
            $hasGet = $endpoints | Where-Object {
                $_.Method -eq 'get' -and $_.Path -match "/$resource/"
            }
            if (-not $hasGet) {
                Add-Warning -type "Missing GET Endpoint" -message "No GET endpoint found for resource '$resource' — PUT request body cannot be pre-populated with real values"
            }
        }

        # Check for GET endpoints with no corresponding POST create, ignoring common collection endpoints
        if ($ep.Method -ne 'get') { continue }

        $segments = $ep.Path.Trim('/') -split '/'
        $resource = $segments | Where-Object {
            $_ -notmatch '^api$|^\{' -and $_ -notmatch '^\d+$' -and
            $_ -notmatch 'create|add|update|remove|delete|get|list|by|register'
        } | Select-Object -First 1

        if (-not $resource) { continue }

        $hasPost = $endpoints | Where-Object {
            $_.Method -eq 'post' -and
            $_.Path -match "/$resource/" -and
            $_.Path -match 'create$'
        }

        if (-not $hasPost) {
            Add-Warning -type "No Post For Get" -message "$($ep.Path) — no corresponding POST create endpoint found for resource '$resource'"
        }
    }
}