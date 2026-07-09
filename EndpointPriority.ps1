# Optional manual overrides — edit these to force specific paths to run first
$script:priorityOverrides = @{
    '/api/Auth/register' = 1
    '/api/Auth/login'    = 2
}

function Get-EndpointPriority {
    param ([string]$path, [string]$method)

    if ($script:priorityOverrides.ContainsKey($path)) {
        return $script:priorityOverrides[$path]
    }

    $pathPriority = switch -Wildcard ($path) {
        '*/register*'          { 100 }
        '*/login*'             { 200 }
        '*/create*'            { 300 }
        '*/add*'               { 400 }
        '*/update*'            { 500 }
        '*/remove*'            { 600 }
        '*/delete*'            { 700 }
        '*/regenerate*'        { 800 }
        '*/snapshot*'          { 800 }
        '*/refresh*'           { 800 }
        '*/advance*'           { 800 }
        '*/activate*'          { 800 }
        '*/deactivate*'        { 800 }
        '*/changeactive*'      { 800 }
        '*/register-*'         { 800 }
        default {
            # Plain resource endpoint (no action word) — run early
            $segments = $path.Trim('/') -split '/'
            $hasAction = $segments | Where-Object { $_ -match '-' -or $_ -match '^(create|add|update|remove|delete|regenerate|snapshot|refresh|advance|list|register|activate|deactivate)$' }
            if ($hasAction) { 850 } else { 50 }
        }
    }

    $methodOffset = switch ($method) {
        'post'   { 10 }
        'get'    { 20 }
        'put'    { 30 }
        'delete' { 40 }
        default  { 50 }
    }

    return $pathPriority + $methodOffset
}