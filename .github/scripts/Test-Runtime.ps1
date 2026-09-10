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

Write-Host 'primeira execucao: roteiro, sem gerar chave'
$out = Invoke-Fishell
Assert-Match $out 'siga os passos' 'roteiro'
Assert-Match $out 'ssh-keygen -t rsa' 'instrucao do ssh-keygen'
Assert-Match $out 'primeirospassos' 'link do cadastro'
if (Test-Path '.ssh') { throw 'nao deveria ter gerado chave' }
Remove-Item -Force config.ps1 -ErrorAction SilentlyContinue

Write-Host 'com chave no ~/.ssh: manda copiar, e cria a pasta de chaves'
$homeKey = Join-Path $HOME '.ssh/id_rsa'
Remove-Item -Force $homeKey, "$homeKey.pub" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $HOME '.ssh') -Force | Out-Null
& ssh-keygen -t rsa -b 2048 -N '' -f $homeKey | Out-Null
$out = Invoke-Fishell
Assert-Match $out 'copie para c' 'sugere copiar'
if (-not (Test-Path .ssh)) { throw 'nao criou a pasta de chaves' }
Remove-Item -Recurse -Force .ssh, config.ps1 -ErrorAction SilentlyContinue
Remove-Item -Force $homeKey, "$homeKey.pub" -ErrorAction SilentlyContinue

Write-Host 'com chave existente: mostra a publica'
New-Item -ItemType Directory -Path .ssh -Force | Out-Null
& ssh-keygen -t rsa -b 2048 -N '' -f .ssh/id_rsa | Out-Null
$out = Invoke-Fishell
Assert-Match $out 'ssh-rsa ' 'mostra a publica'
Remove-Item -Recurse -Force .ssh, config.ps1 -ErrorAction SilentlyContinue

Write-Host 'setup'
New-Item -ItemType Directory -Path .ssh -Force | Out-Null
& ssh-keygen -t rsa -b 2048 -N '' -f .ssh/id_rsa | Out-Null
Copy-Item config/config.ps1.example config.ps1 -Force
(Get-Content config.ps1) -replace 'seu_usuario_aqui', 'ci_user' | Set-Content config.ps1
$out = Invoke-Fishell @('setup')
Write-Host '--- saida do setup ---'; Write-Host $out; Write-Host '----------------------'
# Casa a linha de sucesso, nao so' "npad" — o banner tambem contem "npad".
Assert-Match $out "alias 'npad'" 'setup registrou o alias'
$sshCfg = Join-Path $HOME '.ssh/config'
if (-not (Test-Path $sshCfg)) { throw "nao criou $sshCfg" }
Write-Host "--- $sshCfg ---"; Get-Content $sshCfg | Write-Host; Write-Host '----------------------'
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
