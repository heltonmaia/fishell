# PSScriptAnalyzer: só Error quebra o build. Os Warning mais comuns aqui são
# PSUseApprovedVerbs (Log-Ok, Action-Upload, ...), que é escolha de estilo.
Install-Module PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck
$r = Invoke-ScriptAnalyzer -Path ./fishell.ps1
if ($r) { $r | Format-Table -AutoSize | Out-String | Write-Host }
if ($r | Where-Object { $_.Severity -eq 'Error' }) { exit 1 }
Write-Host 'analyzer ok'
