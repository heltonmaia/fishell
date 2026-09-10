# Executa o port PowerShell de ponta a ponta.
#
# Ate' 2026-09-10 o ps1 so' era PARSEADO no CI. Isso deixa passar erro de
# runtime — o caso real foi `$host = ...`, que e' variavel automatica read-only
# e explodiria no keygen, justamente o comando cuja saida o aluno cola no
# formulario de cadastro do NPAD. Parser e PSScriptAnalyzer nao pegam isso.
#
# Roda no Linux: os caminhos que dependem de API do Windows (icacls em
# Restrict-KeyAcl) ja' estao dentro de try/catch no proprio script.

$ErrorActionPreference = 'Stop'
# Em pwsh 7.4+ isso faz exit code != 0 de comando nativo virar excecao — e o
# fishell sai com 1 de proposito em varios caminhos.
$PSNativeCommandUseErrorActionPreference = $false

$script = './src/powershell/fishell.ps1'
$env:NO_COLOR = '1'

function Invoke-Fishell {
    param([string[]]$Arguments = @())
    return (& pwsh -NoProfile -File $script @Arguments 2>&1 | Out-String)
}
function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$What)
    if ($Text -notmatch $Pattern) {
        Write-Host "--- saida ---"; Write-Host $Text; Write-Host "-------------"
        throw "$What : esperava /$Pattern/"
    }
    Write-Host "  ok: $What"
}

Remove-Item -Recurse -Force config.ps1, .ssh -ErrorAction SilentlyContinue

Write-Host 'help nas duas linguas'
Assert-Match (Invoke-Fishell @('help')) 'PAINEL' 'help pt'
$env:FISHELL_LANG = 'en'
Assert-Match (Invoke-Fishell @('help')) 'CONTROL PANEL' 'help en'
$env:FISHELL_LANG = 'pt'

Write-Host 'primeira execucao: gera a chave e mostra o roteiro'
$out = Invoke-Fishell
Assert-Match $out 'faltam tr' 'roteiro'
Assert-Match $out 'primeirospassos' 'link do cadastro'
if (-not (Test-Path '.ssh/id_rsa.pub')) { throw 'nao gerou a chave' }
$pub = (Get-Content '.ssh/id_rsa.pub' -Raw).Trim()
Assert-Match $pub '^ssh-rsa [A-Za-z0-9+/]{100,}=* fishell@' 'chave publica integra'
Remove-Item -Recurse -Force .ssh, config.ps1 -ErrorAction SilentlyContinue

Write-Host 'keygen avulso'
$out = Invoke-Fishell @('keygen')
if (-not (Test-Path '.ssh/id_rsa.pub')) { Write-Host $out; throw 'keygen nao gerou a chave' }
Assert-Match $out 'ssh-rsa ' 'keygen imprime a publica'

Write-Host 'setup'
Copy-Item config/config.ps1.example config.ps1 -Force
(Get-Content config.ps1) -replace 'seu_usuario_aqui', 'ci_user' | Set-Content config.ps1
Assert-Match (Invoke-Fishell @('setup')) 'npad' 'setup'
$sshCfg = Join-Path $HOME '.ssh/config'
if (-not (Select-String -Path $sshCfg -Pattern '^Host npad$' -Quiet)) { throw 'alias nao registrado' }

Write-Host 'setup repetido nao duplica o bloco'
Invoke-Fishell @('setup') | Out-Null
Invoke-Fishell @('setup') | Out-Null
$n = @(Select-String -Path $sshCfg -Pattern 'fishell: begin').Count
if ($n -ne 1) { Get-Content $sshCfg | Write-Host; throw "bloco duplicado ($n)" }
Write-Host "  ok: 1 bloco no ~/.ssh/config"

Write-Host 'status'
Assert-Match (Invoke-Fishell @('status')) 'fishell v' 'status'

Remove-Item -Recurse -Force config.ps1, .ssh -ErrorAction SilentlyContinue
Write-Host 'runtime do ps1: ok'
