# Parse do fishell.ps1 sem executá-lo.
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path ./src/powershell/fishell.ps1).Path, [ref]$null, [ref]$errors)
if ($errors) {
    $errors | ForEach-Object { Write-Host $_.ToString() }
    exit 1
}
Write-Host 'parse ok'
