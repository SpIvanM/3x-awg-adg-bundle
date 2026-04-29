$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path (Split-Path -Parent $MyInvocation.MyCommand.Path -Resolve)) 'script-regressions.ps1'),
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -eq 0) {
    Write-Host 'Parse OK: no syntax errors'
} else {
    Write-Host "$($errors.Count) parse error(s):"
    foreach ($e in $errors) {
        Write-Host ("  Line {0} char {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
    }
}
