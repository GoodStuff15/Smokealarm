# Optional manual overrides — edit these to force specific paths to run first
$script:priorityOverrides = @{
    '/api/Auth/register' = 1
    '/api/Auth/login'    = 2
    '/api/Competition/create' = 3
    '/api/CompetitionRound/create' = 4
    '/api/CompetitionRoundStage/create' = 5
    '/api/Schedule/create' = 6
    '/api/Player/create' = 7
}

function Get-EndpointPriority {
    param ([string]$path, [string]$method)

    if ($script:priorityOverrides.ContainsKey($path)) {
        return $script:priorityOverrides[$path]
    }

    $pathPriority = switch -Wildcard ($path) {
        '*/register*' { 100 }
        '*/login*'    { 200 }
        '*/create*'   { 300 }
        '*/add*'      { 400 }
        '*/update*'   { 500 }
        '*/remove*'   { 600 }
        '*/delete*'   { 700 }
        default       { 900 }
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