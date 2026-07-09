# Run-SmokeTests.ps1
# Drop this in your solution folder alongside testrunner.ps1
# First run: auto-discovers everything and saves config. After that: just runs.

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# -- Paths --------------------------------------------------------------------
$scriptRoot  = $PSScriptRoot
$configPath  = Join-Path $scriptRoot "smoketest.config.json"
$runnerPath  = Join-Path $scriptRoot "testrunner.ps1"

# -- Colours ------------------------------------------------------------------
function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  +======================================+" -ForegroundColor Cyan
    Write-Host "  |       API Smoke Test Launcher        |" -ForegroundColor Cyan
    Write-Host "  +======================================+" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green  }
function Write-Warn($msg) { Write-Host "  [WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [ERR] $msg" -ForegroundColor Red    }
function Write-Info($msg) { Write-Host "  [INFO]  $msg" -ForegroundColor Cyan   }
function Write-Blank      { Write-Host "" }

function Prompt-User($label, [switch]$secret) {
    Write-Host "  -> $label`: " -ForegroundColor White -NoNewline
    if ($secret) { Read-Host -AsSecureString | ForEach-Object {
        [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
    } else { Read-Host }
}

# -- Swagger / OpenAPI discovery -----------------------------------------------
$swaggerCandidateNames = @(
    # swagger.*
    "swagger.json", "swagger.yaml", "swagger.yml",
    # openapi.*
    "openapi.json", "openapi.yaml", "openapi.yml",
    # api-docs.*
    "api-docs.json", "api-docs.yaml", "api-docs.yml",
    # api.*
    "api.json", "api.yaml", "api.yml",
    # spec.*
    "spec.json", "spec.yaml", "spec.yml",
    # apispec.*
    "apispec.json", "apispec.yaml", "apispec.yml",
    # api-spec.*
    "api-spec.json", "api-spec.yaml", "api-spec.yml",
    # openapi-spec.*
    "openapi-spec.json", "openapi-spec.yaml", "openapi-spec.yml",
    # swagger-spec.*
    "swagger-spec.json", "swagger-spec.yaml", "swagger-spec.yml",
    # v1 / v2 / v3 variants
    "v1.json", "v2.json", "v3.json",
    "v1.yaml", "v2.yaml", "v3.yaml",
    # common .NET output locations
    "wwwroot\swagger.json", "wwwroot\openapi.json",
    "wwwroot\api-docs.json"
)

function Find-SwaggerSpec {
    # 1. Check well-known names at script root
    foreach ($name in $swaggerCandidateNames) {
        $p = Join-Path $scriptRoot $name
        if (Test-Path $p) { return $p }
    }
    # 2. Recurse the solution tree (skip node_modules / .git / bin / obj)
    $found = Get-ChildItem -Path $scriptRoot -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in ($swaggerCandidateNames | ForEach-Object { Split-Path $_ -Leaf }) -and
            $_.FullName -notmatch '\\(node_modules|\.git|bin|obj)\\'
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    return $found?.FullName
}

# -- launchSettings discovery --------------------------------------------------
function Find-BaseUrl {
    $ls = Get-ChildItem -Path $scriptRoot -Recurse -Filter "launchSettings.json" `
            -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -notmatch '\\(node_modules|\.git)\\' } |
          Select-Object -First 1

    if (-not $ls) { return $null }

    $settings = Get-Content $ls.FullName -Raw | ConvertFrom-Json
    $settings.profiles.PSObject.Properties.Value |
        Where-Object { $_.applicationUrl } |
        ForEach-Object { $_.applicationUrl -split ";" } |
        Where-Object { $_ -like "https://*" } |
        Select-Object -First 1
}

# -- Auth endpoint discovery ---------------------------------------------------
function Find-AuthEndpoint($spec) {
    # Look for common auth/login/token paths in the spec
    if (-not $spec) { return $null }
    try {
        $parsed = Get-Content $spec -Raw | ConvertFrom-Json
        $allAuthPaths = $parsed.paths.PSObject.Properties.Name |
            Where-Object { $_ -match '/(auth|login|token|signin|sign-in|account/login)' }
        # Prefer explicit login/token paths over register/logout/refresh/etc.
        $authPaths = $allAuthPaths |
            Where-Object { $_ -match '/(login|token|signin|sign-in)$' } |
            Select-Object -First 1
        if (-not $authPaths) { $authPaths = $allAuthPaths | Select-Object -First 1 }
        return $authPaths
    } catch { return $null }
}

# -- Config helpers ------------------------------------------------------------
$defaultConfig = [ordered]@{
    baseUrl           = ""
    openApiSpecPath   = ""
    accessToken       = ""        # fill this in for long-lasting tokens; skips login
    authEndpoint      = ""        # e.g. /auth/login  -- auto-detected if blank
    usernameEnvVar    = "SMOKETEST_USERNAME"   # env var names, not values
    passwordEnvVar    = "SMOKETEST_PASSWORD"
    reportLocation    = ".\reports\"
    failOnTestFailures= $true
    skipPaths         = @("auth")
    methods           = @("get","post","put","delete")
    postOrder         = @() 
    showDetailedErrors= $true
    saveReports       = $true
    maxReports        = 10
    maxAgeDays        = 10
}

function Load-Config {
    if (Test-Path $configPath) {
        $raw = Get-Content $configPath -Raw | ConvertFrom-Json
        # Merge with defaults so new keys are always present
        $merged = [ordered]@{}
        foreach ($key in $defaultConfig.Keys) {
            $merged[$key] = if ($null -ne $raw.$key) { $raw.$key } else { $defaultConfig[$key] }
        }
        return $merged
    }
    return $null
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Set-Content $configPath -Encoding UTF8
}

# -- First-run setup -----------------------------------------------------------
function Invoke-Setup {
    Write-Header
    Write-Host "  First-run setup -- this saves to smoketest.config.json" -ForegroundColor White
    Write-Blank

    $cfg = [ordered]@{} + $defaultConfig   # clone defaults

    # --- Swagger spec ---
    $found = Find-SwaggerSpec
    if ($found) {
        $displayPath = Resolve-Path -Path $found -Relative -ErrorAction SilentlyContinue
        if (-not $displayPath) { $displayPath = $found }
        Write-Ok "Found spec: $displayPath"
        $cfg.openApiSpecPath = $found
    } else {
        Write-Warn "Could not auto-detect OpenAPI spec."
        $cfg.openApiSpecPath = Prompt-User "Path to swagger/openapi file"
    }

    Write-Blank

    # --- Base URL ---
    $foundUrl = Find-BaseUrl
    if ($foundUrl) {
        Write-Ok "Found base URL from launchSettings.json: $foundUrl"
        $cfg.baseUrl = $foundUrl
    } else {
        Write-Warn "Could not auto-detect base URL."
        $cfg.baseUrl = Prompt-User "Base URL (e.g. https://localhost:7194)"
    }

    Write-Blank

    # --- Auth endpoint ---
    $foundAuth = Find-AuthEndpoint $cfg.openApiSpecPath
    if ($foundAuth) {
        Write-Ok "Found auth endpoint in spec: $foundAuth"
        $cfg.authEndpoint = $foundAuth
    } else {
        Write-Warn "Could not auto-detect auth endpoint."
        Write-Host "  -> Auth endpoint (leave blank to skip auth, e.g. /auth/login): " -NoNewline -ForegroundColor White
        $cfg.authEndpoint = Read-Host
    }

    Write-Blank

    # --- Credentials ---
    Write-Info "Credentials are read from environment variables at runtime."
    Write-Info "Default env var names: SMOKETEST_USERNAME / SMOKETEST_PASSWORD"
    Write-Host "  -> Username env var name (Enter to keep default): " -NoNewline -ForegroundColor White
    $uev = Read-Host
    if ($uev) { $cfg.usernameEnvVar = $uev }

    Write-Host "  -> Password env var name (Enter to keep default): " -NoNewline -ForegroundColor White
    $pev = Read-Host
    if ($pev) { $cfg.passwordEnvVar = $pev }

    Write-Blank

    # --- Save ---
    Save-Config $cfg

    Write-Blank
    Write-Ok "Config saved to smoketest.config.json"
    Write-Info "To use a long-lasting token instead of credentials, set 'accessToken' in the config file."
    Write-Blank

    return $cfg
}

# -- Token acquisition ---------------------------------------------------------
function Get-Token($cfg) {
    # 1. Long-lasting token in config
    if ($cfg.accessToken -and $cfg.accessToken -ne "") {
        Write-Ok "Using token from config file."
        return $cfg.accessToken
    }

    # 2. No auth endpoint -- skip
    if (-not $cfg.authEndpoint) {
        Write-Warn "No auth endpoint configured -- running without token."
        return $null
    }

    # 3. Env vars
    $username = [Environment]::GetEnvironmentVariable($cfg.usernameEnvVar)
    $password = [Environment]::GetEnvironmentVariable($cfg.passwordEnvVar)

    if (-not $username -or -not $password) {
        Write-Warn "Env vars '$($cfg.usernameEnvVar)' / '$($cfg.passwordEnvVar)' not set."
        Write-Host "  -> Username: " -NoNewline -ForegroundColor White
        $username = Read-Host
        $password = Prompt-User "Password" -secret
    }

    Write-Blank
    Write-Info "Authenticating..."

    try {
        $body = @{ username = $username; password = $password } | ConvertTo-Json
        $url  = "$($cfg.baseUrl)$($cfg.authEndpoint)"
        $r    = Invoke-RestMethod $url -Method POST -ContentType "application/json" -Body $body
        $token = $r.token ?? $r.access_token ?? $r.accessToken ?? $r.data?.token
        if ($token) { Write-Ok "Authenticated successfully."; return $token }
        Write-Err "Auth response did not contain a recognisable token field."
        return $null
    } catch {
        Write-Err "Authentication failed: $($_.Exception.Message)"
        return $null
    }
}

# -- Main ----------------------------------------------------------------------
Write-Header

# Sanity-check for testrunner
if (-not (Test-Path $runnerPath)) {
    Write-Err "testrunner.ps1 not found in $scriptRoot"
    Write-Blank; exit 1
}

# Load or create config
$cfg = Load-Config

if (-not $cfg) {
    $cfg = Invoke-Setup
    Write-Blank
    Write-Host "  Press Enter to run tests now, or close and re-run later..." -ForegroundColor White
    Read-Host | Out-Null
    Write-Header
}

# Show resolved settings
Write-Info "Base URL : $($cfg.baseUrl)"
Write-Info "Spec     : $($cfg.openApiSpecPath)"
Write-Info "Auth     : $(if ($cfg.authEndpoint) { $cfg.authEndpoint } else { '(none)' })"
Write-Blank

# Get credentials and token
$username = [Environment]::GetEnvironmentVariable($cfg.usernameEnvVar)
$password = [Environment]::GetEnvironmentVariable($cfg.passwordEnvVar)
$token = Get-Token $cfg
Write-Blank
Write-Host "CFG postOrder: $($cfg.postOrder -join ', ')" -ForegroundColor Yellow

# Build params for testrunner
$params = @{
    openApiSpecPath   = $cfg.openApiSpecPath
    baseUrl           = $cfg.baseUrl
    reportLocation    = $cfg.reportLocation
    failOnTestFailures= [bool]$cfg.failOnTestFailures
    skipPaths         = [string[]]$cfg.skipPaths
    methods           = [string[]]$cfg.methods
    showDetailedErrors= [bool]$cfg.showDetailedErrors
    saveReports       = [bool]$cfg.saveReports
    maxReports        = [int]$cfg.maxReports
    maxAgeDays        = [int]$cfg.maxAgeDays
    postOrder         = [string[]]$cfg.postOrder   # ← add this
}

if ($token)    { $params.accessToken = $token }
if ($username) { $params.username = $username }
if ($password) { $params.password = $password }

Write-Host "  ==========================================" -ForegroundColor Cyan
Write-Host "  Running tests..." -ForegroundColor White
Write-Host "  ==========================================" -ForegroundColor Cyan
Write-Blank

& $runnerPath @params