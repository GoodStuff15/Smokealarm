param(
    [string]$openApiSpecPath = "$PSScriptRoot\swagger.json",
    [string]$overridesPath = "$PSScriptRoot\requestOverrides.json"
)
. "$PSScriptRoot\ResolveEndpoints.ps1"
. "$PSScriptRoot\New-RequestOverrides.ps1"



New-RequestOverrides -openApiSpecPath $openApiSpecPath -outputPath $overridesPath