# Name: build setup bundle
# Description: Собирает публичный setup.sh из source-модулей в src/setup.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sourceRoot = Join-Path $repoRoot 'src\setup'
$outputPath = Join-Path $repoRoot 'setup.sh'

$modules = @(
    '00-bootstrap.sh'
    '10-helpers.sh'
    '20-system.sh'
    '30-xray.sh'
    '40-awg.sh'
    '50-adguard.sh'
    '60-firewall.sh'
    '70-output.sh'
)

$missing = @()
foreach ($module in $modules) {
    $path = Join-Path $sourceRoot $module
    if (-not (Test-Path -LiteralPath $path)) {
        $missing += $path
    }
}

if ($missing.Count -gt 0) {
    throw "Missing setup source modules:`n$($missing -join [Environment]::NewLine)"
}

$encoding = [System.Text.UTF8Encoding]::new($false)
$contents = foreach ($module in $modules) {
    [System.IO.File]::ReadAllText((Join-Path $sourceRoot $module))
}

[System.IO.File]::WriteAllText($outputPath, ($contents -join [Environment]::NewLine), $encoding)

Write-Host "Built $outputPath from $($modules.Count) source modules."
