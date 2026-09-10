# ═══════════════════════════════════════════════════════════════════════════
#  fishell.ps1, porta Windows/PowerShell do fishell
#  Acesso SSH rápido ao NPAD/UFRN (sc2.npad.ufrn.br:4422).
#
#  Requisitos:
#    - Windows 10+ com OpenSSH Client (já vem ativado por padrão; se não,
#      Settings → Apps → Optional features → "OpenSSH Client")
#    - PowerShell 5.1 (padrão) ou PowerShell 7+
#    - Windows Terminal recomendado (cores/ANSI + Unicode)
#
#  ATENÇÃO: este arquivo PRECISA ser salvo em UTF-8 COM BOM. O Windows
#  PowerShell 5.1 lê .ps1 sem BOM como ANSI/Windows-1252, o que destrói a
#  arte do banner, as bordas do painel E o regex das sentinelas
#  "# ── fishell: begin ──" (fazendo cada setup duplicar o bloco no
#  ~/.ssh/config a cada execução). O CI tem um guard contra isso.
# ═══════════════════════════════════════════════════════════════════════════

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'setup', 'login', 'test', 'upload', 'download',
                 'run', 'status', 'help', '')]
    [string]$Action = 'menu',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$FishellVersion = '2.6'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# O codigo vive em src/powershell/, mas config.ps1 e .ssh/ sao do usuario e
# ficam na raiz do repo, dois niveis acima.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

# UTF-8 no console pra Unicode (blocos, box drawing, ·, °).
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch {}

# ─── Paleta ───────────────────────────────────────────────────────────────
$UseColor = -not $env:NO_COLOR -and $Host.UI.SupportsVirtualTerminal
# $E é o ESC e precisa existir SEMPRE: as sequências de posicionamento de
# cursor (\e[H, \e7, \e8) são usadas mesmo com as cores desligadas.
$E = [char]27
if ($UseColor) {
    $R = "$E[0m"; $B = "$E[1m"
    $G = "$E[38;5;46m"; $GD = "$E[38;5;28m"; $GB = "$E[38;5;118m"
    $RED = "$E[38;5;196m"; $YEL = "$E[38;5;226m"
    $CYA = "$E[38;5;51m"; $GRAY = "$E[38;5;240m"
} else {
    $R=''; $B=''; $G=''; $GD=''; $GB=''; $RED=''; $YEL=''; $CYA=''; $GRAY=''
}

function Write-Raw { param([string]$s) [Console]::Out.Write($s) }
function Write-Line { param([string]$s) [Console]::Out.WriteLine($s) }

function Log-Info { param($m) Write-Line "${CYA}[*]${R} $m" }
function Log-Ok   { param($m) Write-Line "${GB}[+]${R} $m" }
function Log-Warn { param($m) Write-Line "${YEL}[!]${R} $m" }
function Log-Err  { param($m) [Console]::Error.WriteLine("${RED}[x]${R} $m") }
function Log-Step { param($m) Write-Line ""; Write-Line "${G}[»]${R} ${B}$m${R}" }
function Log-Work { param($m) Write-Line "${GD}[~]${R} $m" }

# ─── i18n ─────────────────────────────────────────────────────────────────
# FISHELL_LANG=pt|en (padrão pt). Vem do ambiente ou do config.ps1, e pode ser
# trocado em runtime pela tecla [l] do menu.
# Regra do painel: M*_T no máximo 20 colunas, M*_H no máximo 16.
$script:FISHELL_LANG = if ($env:FISHELL_LANG) { $env:FISHELL_LANG } else { 'pt' }
$script:FishellLangEnv = $env:FISHELL_LANG

function Set-Lang {
    if ($script:FISHELL_LANG -eq 'en') {
        $script:L = @{
            TAGLINE='npad/ufrn secure access terminal'; TARGET='target'
            HDR_TYPE='type'; HDR_OR='or'; HDR_EXIT='to exit'
            PANEL='CONTROL PANEL'
            M1_T='open secure shell';    M1_H='( ssh npad )'
            M2_T='probe connection';     M2_H='( dry-run test )'
            M3_T='upload payload';       M3_H='( scp push )'
            M4_T='download payload';     M4_H='( scp pull )'
            M5_T='exec remote command';  M5_H='( one-shot )'
            M6_T='redeploy ssh payload'; M6_H='( re-setup )'
            M7_T='system readout';       M7_H='( status )'
            ML_T='language'
            M0_T='logout';               M0_H='( exit )'
            PROMPT='select option'; PAUSE='press ENTER to return to control panel... '
            INVALID='invalid opcode:'; BYE='session terminated.'; BYE2='goodbye.'
            LANGSET='language:'
            CFG_NOTFOUND='configuration file not found:'
            CFG_COPY='copying template from config/config.ps1.example...'
            CFG_EDIT='edit {0} and set $NPAD_USER before running again.'
            CFG_NOTEMPLATE='template config/config.ps1.example missing too. aborting.'
            CFG_PLACEHOLDER='NPAD_USER is still the default placeholder.'; CFG_EDITPATH='edit:'
            SETUP_INIT='initializing ssh payload for user'
            KEYS_NOTFOUND='keys directory not found:'; KEYS_CHECK='check $SSH_KEYS_DIR in config.ps1'
            PRIV_NOTFOUND='private key not found in'; PRIV_EXPECT='expected: id_rsa (or id_rsa.txt)'
            PRIV_KEYGEN='create one with: ssh-keygen -t rsa -f .ssh/id_rsa'
            PRIV_OK='private key deployed -> ~/.ssh/id_rsa'
            PUB_OK='public key deployed -> ~/.ssh/id_rsa.pub'; KH_OK='known_hosts deployed'
            ALIAS_UPD='updated in ~/.ssh/config'; ALIAS_REG='registered in ~/.ssh/config'
            ALIAS_KEPT='exists in ~/.ssh/config but was not created by fishell - kept as is'
            READY='payload ready. connect with:'
            PROBE='probing target'; HANDSHAKE='dispatching handshake (10s timeout)...'
            TUNNEL_OK='tunnel established ::'; HANDSHAKE_FAIL='handshake failed:'
            HINT_KEY='your public key is not registered at NPAD yet, or $NPAD_USER is wrong'
            HINT_NOKEY='the key is not installed in ~/.ssh. Run: bin\fishell.cmd setup'
            HINT_HOSTKEY='missing known_hosts, or the server key changed - see the README'
            HINT_NET='no route to the server - firewall, or port 4422 blocked'
            HINT_DNS='could not resolve the host - check your connection'
            OPEN_SHELL='opening secure shell to'; EXIT_HINT="(type 'exit' to return to the control panel)"
            UPLOAD_STEP='upload // from your computer to npad'
            DOWNLOAD_STEP='download // from npad to your computer'
            UPLOAD_EX='e.g.  ./my_project  ->  ~/'
            DOWNLOAD_EX='e.g.  ~/result.h5  ->  .'
            FROM_HERE='from (here)'; TO_NPAD='to (npad)'
            FROM_NPAD='from (npad)'; TO_HERE='to (here)'
            ACL_WARN='could not tighten the key permission; ssh may still warn'
            SRC_MISSING='does not exist'; TRANSFERRING='transferring...'
            TRANSFER_OK='transfer complete'; TRANSFER_FAIL='transfer failed'
            REMOTE_EXEC='remote exec //'; CMD='cmd'; EMPTY_CMD='empty command, aborted.'
            STDOUT_BEGIN='─── remote stdout ───'; STDOUT_END='─── end ─────────────'
            FIRSTRUN='first run - follow the steps:'
            STEP_REGISTER='register your public key (your login comes by e-mail)'
            STEP_KEYGEN='create your ssh key'
            STEP_COPYKEY='copy the key you already have into this folder'
            PRIV_INPLACE='using the key already in ~/.ssh, nothing to copy'
            STEP_CONFIG='put that login in $NPAD_USER'
            STEP_RERUN='run again'; KEY_FOUND='your public key:'
            KEY_INVALID='this public key does not look valid - do NOT register it'
            KEY_FILE='file:'
            STATUS_STEP='system readout'
            ST_USER='USER'; ST_HOST='HOST'; ST_PORT='PORT'
            ST_ALIAS='ALIAS'; ST_KEYS='KEYS_DIR'; ST_VERSION='VERSION'
        }
    } else {
        $script:FISHELL_LANG = 'pt'
        $script:L = @{
            TAGLINE='terminal de acesso ao npad/ufrn'; TARGET='alvo'
            HDR_TYPE='tecle'; HDR_OR='ou'; HDR_EXIT='para sair'
            PANEL='PAINEL DE CONTROLE'
            M1_T='abrir shell seguro';  M1_H='( ssh npad )'
            M2_T='testar conexão';      M2_H='( sem conectar )'
            M3_T='enviar arquivos';     M3_H='( scp push )'
            M4_T='baixar arquivos';     M4_H='( scp pull )'
            M5_T='executar comando';    M5_H='( uma vez )'
            M6_T='reinstalar chaves';   M6_H='( refazer )'
            M7_T='ver configuração';    M7_H='( status )'
            ML_T='idioma'
            M0_T='sair';                M0_H='( exit )'
            PROMPT='escolha uma opção'; PAUSE='tecle ENTER para voltar ao painel... '
            INVALID='opção inválida:'; BYE='sessão encerrada.'; BYE2='até mais.'
            LANGSET='idioma:'
            CFG_NOTFOUND='arquivo de configuração não encontrado:'
            CFG_COPY='copiando o modelo de config/config.ps1.example...'
            CFG_EDIT='edite {0} e defina $NPAD_USER antes de rodar de novo.'
            CFG_NOTEMPLATE='o modelo config/config.ps1.example também não existe. abortando.'
            CFG_PLACEHOLDER='NPAD_USER ainda é o placeholder padrão.'; CFG_EDITPATH='edite:'
            SETUP_INIT='preparando o ssh para o usuário'
            KEYS_NOTFOUND='pasta de chaves não encontrada:'; KEYS_CHECK='confira $SSH_KEYS_DIR no config.ps1'
            PRIV_NOTFOUND='chave privada não encontrada em'; PRIV_EXPECT='esperado: id_rsa (ou id_rsa.txt)'
            PRIV_KEYGEN='gere uma com: ssh-keygen -t rsa -f .ssh/id_rsa'
            PRIV_OK='chave privada instalada -> ~/.ssh/id_rsa'
            PUB_OK='chave pública instalada -> ~/.ssh/id_rsa.pub'; KH_OK='known_hosts instalado'
            ALIAS_UPD='atualizado no ~/.ssh/config'; ALIAS_REG='registrado no ~/.ssh/config'
            ALIAS_KEPT='já existe no ~/.ssh/config e não foi criado pelo fishell - mantido como está'
            READY='tudo pronto. conecte com:'
            PROBE='testando'; HANDSHAKE='enviando handshake (limite de 10s)...'
            TUNNEL_OK='conexão estabelecida ::'; HANDSHAKE_FAIL='falhou:'
            HINT_KEY='sua chave pública ainda não está cadastrada no NPAD, ou o $NPAD_USER está errado'
            HINT_NOKEY='a chave não está instalada no ~/.ssh. Rode: bin\fishell.cmd setup'
            HINT_HOSTKEY='falta o known_hosts, ou a chave do servidor mudou - veja o README'
            HINT_NET='sem rota até o servidor - firewall, ou porta 4422 bloqueada'
            HINT_DNS='não consegui resolver o host - confira sua conexão'
            OPEN_SHELL='abrindo shell em'; EXIT_HINT="(digite 'exit' para voltar ao painel)"
            UPLOAD_STEP='envio // do seu computador para o npad'
            DOWNLOAD_STEP='download // do npad para o seu computador'
            UPLOAD_EX='ex.  ./meu_projeto  ->  ~/'
            DOWNLOAD_EX='ex.  ~/resultado.h5  ->  .'
            FROM_HERE='de   (aqui)'; TO_NPAD='para (npad)'
            FROM_NPAD='de   (npad)'; TO_HERE='para (aqui)'
            ACL_WARN='não consegui restringir a permissão da chave; o ssh pode reclamar'
            SRC_MISSING='não existe'; TRANSFERRING='transferindo...'
            TRANSFER_OK='transferência concluída'; TRANSFER_FAIL='a transferência falhou'
            REMOTE_EXEC='comando remoto //'; CMD='comando'; EMPTY_CMD='comando vazio, cancelado.'
            STDOUT_BEGIN='─── saída remota ────'; STDOUT_END='─── fim ─────────────'
            FIRSTRUN='primeira execução - siga os passos:'
            STEP_REGISTER='cadastre a chave pública (o login chega por e-mail)'
            STEP_KEYGEN='gere sua chave ssh'
            STEP_COPYKEY='copie para cá a chave que você já tem'
            PRIV_INPLACE='usando a chave que já está em ~/.ssh, nada a copiar'
            STEP_CONFIG='ponha esse login em $NPAD_USER'
            STEP_RERUN='rode de novo'; KEY_FOUND='sua chave pública:'
            KEY_INVALID='esta chave pública não parece válida - NÃO cadastre ela'
            KEY_FILE='arquivo:'
            STATUS_STEP='configuração atual'
            ST_USER='USUÁRIO'; ST_HOST='HOST'; ST_PORT='PORTA'
            ST_ALIAS='ALIAS'; ST_KEYS='CHAVES'; ST_VERSION='VERSÃO'
        }
    }
}
Set-Lang

# ─── Carrega config ───────────────────────────────────────────────────────
$script:NPAD_USER = $null
$script:NPAD_HOST = 'sc2.npad.ufrn.br'
$script:NPAD_PORT = '4422'
$script:SSH_ALIAS = 'npad'
$script:SSH_KEYS_DIR = ''
$script:SetupOk = $false
$script:Onboarding = $false

# Roteiro de primeira execucao. Substitui o antigo "edite config.ps1 e defina
# NPAD_USER", que era um beco sem saida: nesse ponto o usuario ainda nao TEM um
# login do NPAD, ele so' existe depois de cadastrar a chave publica.
function Show-Onboarding {
    param([string]$Cfg)
    # Por definicao so' chegamos aqui sem usuario configurado.
    $script:NPAD_USER_SET = $false
    if ((Get-Location).Path -eq $RepoRoot) { $Cfg = 'config.ps1' }
    if (-not $script:SSH_KEYS_DIR) { $script:SSH_KEYS_DIR = Join-Path $RepoRoot '.ssh' }
    $pub = Join-Path $script:SSH_KEYS_DIR 'id_rsa.pub'
    $n = 1

    Write-Line ""
    Write-Line "  ${GB}${B}$($L.FIRSTRUN)${R}"
    Write-Line ""

    if (Test-Path $pub) {
        # Ja' tem chave: mostra a publica pra copiar, conferindo a integridade
        # antes, ela vai colada num formulario oficial do NPAD.
        if (Test-PubKey $pub) {
            Write-Line "  ${GD}$($L.KEY_FOUND)${R}"
            Write-Line ""
            Write-Line "${GB}$((Get-Content $pub -Raw).Trim())${R}"
            Write-Line ""
            Write-Line "  ${GD}$($L.KEY_FILE) $pub${R}"
            Write-Line ""
        } else {
            Log-Err $L.KEY_INVALID
            Write-Line "  ${GD}$pub${R}"
            Write-Line ""
        }
    } else {
        # So' encurta para ".ssh" quando e' mesmo a pasta padrao do repo: com
        # SSH_KEYS_DIR customizado o caminho curto mandaria o usuario gerar a
        # chave onde o fishell nao vai procurar.
        $keysDisp = $script:SSH_KEYS_DIR
        if ((Get-Location).Path -eq $RepoRoot -and
            $script:SSH_KEYS_DIR -eq (Join-Path $RepoRoot '.ssh')) { $keysDisp = '.ssh' }

        # O mkdir so' entra quando a pasta nao existe: a .ssh do repo ja' vem
        # no clone, e sugerir criar o que ja' esta' la' e' ruido.
        $mk = if (Test-Path $script:SSH_KEYS_DIR) { '' } else { "mkdir $keysDisp; " }
        if (Test-Path (Join-Path $HOME '.ssh/id_rsa')) {
            # Ja' tem chave no ~/.ssh: copiar e' melhor que gerar outra, que
            # precisaria de um cadastro novo no NPAD.
            Write-Line "  ${YEL}$n.${R} $($L.STEP_COPYKEY)"
            Write-Line "     ${G}PS> ${mk}copy `$HOME\.ssh\id_rsa*  $keysDisp\${R}"
        } else {
            Write-Line "  ${YEL}$n.${R} $($L.STEP_KEYGEN)"
            Write-Line "     ${G}PS> ${mk}ssh-keygen -t rsa -f $keysDisp/id_rsa${R}"
        }
        $n++
    }

    Write-Line "  ${YEL}$n.${R} $($L.STEP_REGISTER)"
    Write-Line "     ${CYA}https://npad.ufrn.br/npad/primeirospassos${R}"
    $n++
    Write-Line "  ${YEL}$n.${R} $($L.STEP_CONFIG)"
    Write-Line "     ${G}PS> notepad $Cfg${R}"
    $n++
    Write-Line "  ${YEL}$n.${R} $($L.STEP_RERUN)"
    Write-Line "     ${G}PS> bin\fishell.cmd${R}"
    Write-Line ""
}

# -Lenient: nao aborta se $NPAD_USER ainda nao estiver preenchido. Usado pelo
# `keygen`, que roda ANTES de o usuario ter conta no NPAD, exigir NPAD_USER ali
# seria um impasse, ja que a chave e' pre-requisito do cadastro que gera o
# usuario.
function Load-Config {
    $script:NPAD_USER_SET = $true
    $cfg = Join-Path $RepoRoot 'config.ps1'
    $example = Join-Path (Join-Path $RepoRoot 'config') 'config.ps1.example'
    if (-not (Test-Path $cfg)) {
        Log-Warn "$($L.CFG_NOTFOUND) $cfg"
        if (Test-Path $example) {
            Log-Info $L.CFG_COPY
            Copy-Item $example $cfg
            # Dot-source o que acabou de ser copiado: sem isso o roteiro da 1a
            # execucao usaria o fallback e mostraria um passo diferente do da
            # 2a, quando o mesmo config ja' existe.
            . $cfg
            if ($SSH_KEYS_DIR) { $script:SSH_KEYS_DIR = $SSH_KEYS_DIR }
            Show-Onboarding $cfg
            exit 1
        } else {
            Log-Err $L.CFG_NOTEMPLATE
            exit 1
        }
    }
    if (Test-Path $cfg) { . $cfg }
    if ([string]::IsNullOrWhiteSpace($NPAD_USER) -or $NPAD_USER -eq 'seu_usuario_aqui') {
        $script:NPAD_USER_SET = $false
        Show-Onboarding $cfg
        exit 1
    }
    $script:NPAD_USER = $NPAD_USER
    if ($NPAD_HOST) { $script:NPAD_HOST = $NPAD_HOST }
    if ($NPAD_PORT) { $script:NPAD_PORT = $NPAD_PORT }
    if ($SSH_ALIAS) { $script:SSH_ALIAS = $SSH_ALIAS }
    # Ambiente vence o config.ps1; reaplica a tabela de strings depois.
    if ($FISHELL_LANG) { $script:FISHELL_LANG = $FISHELL_LANG }
    if ($script:FishellLangEnv) { $script:FISHELL_LANG = $script:FishellLangEnv }
    Set-Lang
    if (-not [string]::IsNullOrWhiteSpace($SSH_KEYS_DIR)) {
        $script:SSH_KEYS_DIR = $SSH_KEYS_DIR
    } elseif (Test-Path (Join-Path $RepoRoot '.ssh/id_rsa')) {
        $script:SSH_KEYS_DIR = Join-Path $RepoRoot '.ssh'
    } elseif (Test-Path (Join-Path $HOME '.ssh/id_rsa')) {
        # Ja' existe chave onde o ssh procura por padrao: usa ela em vez de
        # pedir uma copia. So' falta escrever o alias.
        $script:SSH_KEYS_DIR = Join-Path $HOME '.ssh'
    } else {
        $script:SSH_KEYS_DIR = Join-Path $RepoRoot '.ssh'
    }
}

# ─── Banner + animação ────────────────────────────────────────────────────
$script:FishArt = @(
    '███████╗██╗███████╗██╗  ██╗███████╗██╗     ██╗',
    '██╔════╝██║██╔════╝██║  ██║██╔════╝██║     ██║',
    '█████╗  ██║███████╗███████║█████╗  ██║     ██║',
    '██╔══╝  ██║╚════██║██╔══██║██╔══╝  ██║     ██║',
    '██║     ██║███████║██║  ██║███████╗███████╗███████╗',
    '╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝'
)

function Draw-LogoScene {
    param([int]$t)
    $fishCol = [math]::Floor($t / 2) % 14
    $rows = @(); for ($i = 0; $i -lt 6; $i++) { $rows += (' ' * 16) }
    $bCols = @(3, 8, 12, 5, 14, 10)
    $bPhs  = @(0, 3, 1, 5, 2, 4)
    $bChr  = @('o', 'O', '*', '°', 'o', '*')
    for ($i = 0; $i -lt 6; $i++) {
        $r = (($bPhs[$i] - ($t % 6) + 6) % 6)
        $c = $bCols[$i]
        $rows[$r] = $rows[$r].Substring(0, $c) + $bChr[$i] + $rows[$r].Substring($c + 1)
    }
    $rows[3] = $rows[3].Substring(0, $fishCol) + '·' + $rows[3].Substring($fishCol + 1)

    Write-Raw $G
    for ($i = 0; $i -lt 6; $i++) {
        Write-Line ("  " + $rows[$i] + "  " + $GB + $script:FishArt[$i] + $G)
    }
    Write-Raw $R
}

function Print-InfoLine {
    Write-Line "${GD}  » $($L.TAGLINE.PadRight(31))  ::  v${FishellVersion}${R}"
    $target = "$($script:NPAD_HOST):$($script:NPAD_PORT)"
    Write-Line "${GD}  » $($L.TARGET): $($target.PadRight(28))::  imd/ufrn${R}"
    Write-Line ""
}

# Banner estático. O frame é fixo de propósito: saída determinística ajuda o
# check do painel no CI e o gerador do screenshot.
function Print-Logo {
    Draw-LogoScene -t 2
    Print-InfoLine
}

# ─── Setup SSH ────────────────────────────────────────────────────────────
function Setup-SSH {
    $script:SetupOk = $false
    Log-Step "$($L.SETUP_INIT) '$($script:NPAD_USER)'"
    $homeSsh = Join-Path $HOME '.ssh'
    if (-not (Test-Path $homeSsh)) { New-Item -ItemType Directory -Path $homeSsh -Force | Out-Null }

    if (-not (Test-Path $script:SSH_KEYS_DIR)) {
        Log-Err "$($L.KEYS_NOTFOUND) $($script:SSH_KEYS_DIR)"
        Log-Info $L.KEYS_CHECK
        return
    }

    $priv = $null
    foreach ($cand in @('id_rsa', 'id_rsa.txt')) {
        $p = Join-Path $script:SSH_KEYS_DIR $cand
        if (Test-Path $p) { $priv = $p; break }
    }
    if (-not $priv) {
        Log-Err "$($L.PRIV_NOTFOUND) $($script:SSH_KEYS_DIR)"
        Log-Info $L.PRIV_EXPECT
        Log-Info $L.PRIV_KEYGEN
        return
    }
    $dstPriv = Join-Path $homeSsh 'id_rsa'
    # Com SSH_KEYS_DIR == ~/.ssh a origem e o destino sao o mesmo arquivo, e o
    # Copy-Item falharia. Nesse caso nao ha' o que copiar.
    if ([IO.Path]::GetFullPath($priv) -eq [IO.Path]::GetFullPath($dstPriv)) {
        Log-Ok $L.PRIV_INPLACE
    } else {
        Copy-Item $priv $dstPriv -Force
        Restrict-KeyAcl $dstPriv
        Log-Ok $L.PRIV_OK
    }

    $pub = Join-Path $script:SSH_KEYS_DIR 'id_rsa.pub'
    $dstPub = Join-Path $homeSsh 'id_rsa.pub'
    if ((Test-Path $pub) -and
        ([IO.Path]::GetFullPath($pub) -ne [IO.Path]::GetFullPath($dstPub))) {
        Copy-Item $pub $dstPub -Force
        Log-Ok $L.PUB_OK
    }

    foreach ($kh in @('known_hosts', 'known_hosts.txt')) {
        $p = Join-Path $script:SSH_KEYS_DIR $kh
        if (Test-Path $p) {
            $dstKh = Join-Path $homeSsh 'known_hosts'
            if ([IO.Path]::GetFullPath($p) -ne [IO.Path]::GetFullPath($dstKh)) {
                Copy-Item $p $dstKh -Force
                Log-Ok $L.KH_OK
            }
            break
        }
    }

    $sshCfg = Join-Path $homeSsh 'config'
    if (-not (Test-Path $sshCfg)) { New-Item -ItemType File -Path $sshCfg -Force | Out-Null }

    # Normaliza para string: num arquivo vazio o Get-Content -Raw devolve $null,
    # e $null/@() com -match/-notmatch nao produzem um booleano confiavel, era
    # o que fazia o setup achar que ja' existia um "Host npad" num config vazio
    # e recusar-se a registrar o alias.
    $existing = [string](Get-Content $sshCfg -Raw -ErrorAction SilentlyContinue)
    $block = @"

# ── fishell: begin ──
Host $($script:SSH_ALIAS)
    HostName $($script:NPAD_HOST)
    Port $($script:NPAD_PORT)
    User $($script:NPAD_USER)
    IdentityFile ~/.ssh/id_rsa
    ServerAliveInterval 60
    ServerAliveCountMax 3
# ── fishell: end ──
"@
    # [regex]::IsMatch sempre devolve booleano, o operador -match muda de
    # semantica conforme o tipo do lado esquerdo.
    $hasBlock = [regex]::IsMatch(
        $existing, '(?ms)^# ── fishell: begin ──\s*?\r?\n.*?^# ── fishell: end ──\s*?\r?\n?')
    $hasAlias = [regex]::IsMatch(
        $existing, "(?m)^Host $([regex]::Escape($script:SSH_ALIAS))\s*$")
    if ($hasBlock) {
        # bloco gerenciado pelo fishell já existe: remove e reescreve com a config atual
        $stripped = [regex]::Replace(
            $existing,
            '(?ms)(\r?\n)?^# ── fishell: begin ──\s*?\r?\n.*?^# ── fishell: end ──\s*?\r?\n?',
            ''
        )
        # TrimEnd pelo mesmo motivo do awk no bash: o bloco e' reanexado
        # sempre precedido de uma linha em branco, que se acumularia.
        Set-Content -Path $sshCfg -Value $stripped.TrimEnd("`r", "`n") -NoNewline
        Add-Content -Path $sshCfg -Value $block
        Log-Ok "alias '$($script:SSH_ALIAS)' $($L.ALIAS_UPD)"
    } elseif (-not $hasAlias) {
        Add-Content -Path $sshCfg -Value $block
        Log-Ok "alias '$($script:SSH_ALIAS)' $($L.ALIAS_REG)"
    } else {
        Log-Warn "alias '$($script:SSH_ALIAS)' $($L.ALIAS_KEPT)"
    }

    Write-Line ""
    Log-Ok "$($L.READY) ${GB}${B}ssh $($script:SSH_ALIAS)${R}"
    $script:SetupOk = $true
}

# Restringe ACL da chave privada ao usuário atual (equivalente a chmod 600).
function Restrict-KeyAcl {
    param([string]$Path)
    try {
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        icacls $Path /inheritance:r /grant:r "${user}:(F)" | Out-Null
    } catch {
        Log-Warn $L.ACL_WARN
    }
}

function Test-Connection-Npad {
    Log-Step "$($L.PROBE) $($script:NPAD_HOST):$($script:NPAD_PORT)"
    Log-Work $L.HANDSHAKE
    $err = (& ssh -o ConnectTimeout=10 -o BatchMode=yes $script:SSH_ALIAS true 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
        Log-Ok "$($L.TUNNEL_OK) $($script:NPAD_USER)@$($script:NPAD_HOST)"
        return
    }

    # Mostrar o erro cru do ssh e traduzi-lo: "confira usuario, chave e rede"
    # nao diz qual dos tres, e o aluno fica sem saber por onde comecar.
    Log-Err $L.HANDSHAKE_FAIL
    if ($err) { Write-Line "${GD}  $err${R}" }
    # 'no such identity' antes de 'Permission denied': o erro traz os dois, e
    # o primeiro e' a causa.
    $hint = switch -Regex ($err) {
        'no such identity'             { $L.HINT_NOKEY;   break }
        'Permission denied'            { $L.HINT_KEY;     break }
        'Host key verification failed' { $L.HINT_HOSTKEY; break }
        'Could not resolve'            { $L.HINT_DNS;     break }
        'timed out|Connection refused|No route to host' { $L.HINT_NET; break }
        default { $null }
    }
    if ($hint) { Log-Info $hint }
}

function Action-Login {
    Log-Step "$($L.OPEN_SHELL) $($script:SSH_ALIAS)"
    Log-Work $L.EXIT_HINT
    & ssh $script:SSH_ALIAS
}

function Prompt-Value {
    param([string]$Label, [string]$Default = '')
    Write-Raw "  ${G}>${R} ${Label}"
    if ($Default) { Write-Raw " [$Default]" }
    Write-Raw " : "
    $v = [Console]::In.ReadLine()
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v
}

function Action-Upload {
    Log-Step $L.UPLOAD_STEP
    Write-Line "  ${GD}$($L.UPLOAD_EX)${R}"
    # Rotulos dizem o papel (de/para) E o lado (aqui/npad): so' "caminho
    # local" e "caminho remoto" obriga o usuario a deduzir a direcao, e ela
    # inverte entre enviar e baixar.
    $src = Prompt-Value -Label $L.FROM_HERE
    $dst = Prompt-Value -Label $L.TO_NPAD -Default '~/'
    if (-not (Test-Path $src)) { Log-Err "'$src' $($L.SRC_MISSING)"; return }
    Log-Work $L.TRANSFERRING
    & scp -P $script:NPAD_PORT -r $src "$($script:SSH_ALIAS):$dst"
    if ($LASTEXITCODE -eq 0) { Log-Ok $L.TRANSFER_OK } else { Log-Err $L.TRANSFER_FAIL }
}

function Action-Download {
    Log-Step $L.DOWNLOAD_STEP
    Write-Line "  ${GD}$($L.DOWNLOAD_EX)${R}"
    $src = Prompt-Value -Label $L.FROM_NPAD
    $dst = Prompt-Value -Label $L.TO_HERE -Default './'
    Log-Work $L.TRANSFERRING
    & scp -P $script:NPAD_PORT -r "$($script:SSH_ALIAS):$src" $dst
    if ($LASTEXITCODE -eq 0) { Log-Ok $L.TRANSFER_OK } else { Log-Err $L.TRANSFER_FAIL }
}

function Action-RunRemote {
    param([string]$Command = '')
    Log-Step "$($L.REMOTE_EXEC) $($script:SSH_ALIAS)"
    $cmd = $Command
    if ([string]::IsNullOrWhiteSpace($cmd)) { $cmd = Prompt-Value -Label $L.CMD }
    if ([string]::IsNullOrWhiteSpace($cmd)) { Log-Warn $L.EMPTY_CMD; return }
    Write-Line "${GD}$($L.STDOUT_BEGIN)${R}"
    # -T: não aloca pseudo-tty (evita scripts server-side /etc/profile ou
    # ~/.bashrc falharem com "Input/output error" ao escrever no stderr).
    & ssh -T $script:SSH_ALIAS $cmd
    Write-Line "${GD}$($L.STDOUT_END)${R}"
}

# A publica cadastrada no NPAD tem que estar integra: uma linha, prefixo
# ssh-rsa, e aceita pelo proprio ssh-keygen.
function Test-PubKey {
    param([string]$Pub)
    if (-not (Test-Path $Pub)) { return $false }
    $lines = @(Get-Content $Pub | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) { return $false }
    if ($lines[0] -notmatch '^ssh-rsa [A-Za-z0-9+/]{100,}=* ') { return $false }
    & ssh-keygen -lf $Pub 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Show-Status {
    Log-Step $L.STATUS_STEP
    $line = '─' * 50
    Write-Line "${GD}$line${R}"
    foreach ($row in @(
        @($L.ST_USER,    $script:NPAD_USER),
        @($L.ST_HOST,    $script:NPAD_HOST),
        @($L.ST_PORT,    $script:NPAD_PORT),
        @($L.ST_ALIAS,   $script:SSH_ALIAS),
        @($L.ST_KEYS,    $script:SSH_KEYS_DIR),
        @($L.ST_VERSION, "fishell v$FishellVersion"))) {
        Write-Line ("  ${GB}" + $row[0].PadRight(10) + "${R} " + $row[1])
    }
    # Dizer só ONDE procura não ajuda: o que trava o usuário é não saber se os
    # arquivos estão lá. Mostra o inventário da pasta.
    $inv = ''
    foreach ($f in @('id_rsa', 'id_rsa.pub', 'known_hosts')) {
        $mark = if (Test-Path (Join-Path $script:SSH_KEYS_DIR $f)) { "${GB}v${R}" } else { "${RED}x${R}" }
        $inv += "$mark $f   "
    }
    Write-Line ("  " + (' ' * 10) + " $inv")
    Write-Line "${GD}$line${R}"
}

function Show-Help {
    if ($script:FISHELL_LANG -eq 'en') {
@"

${GB}USAGE${R}
  ${G}cmd>${R} bin\fishell.cmd [command]
  ${G}PS>${R}  .\src\powershell\fishell.ps1 [command]

${GB}COMMANDS${R}
  ${G}(none)${R}     launch interactive control panel
  ${G}setup${R}      configure ssh (copy keys + register alias)
  ${G}login${R}      open secure shell to npad
  ${G}test${R}       probe connection (no shell)
  ${G}upload${R}     scp file/folder to npad (interactive)
  ${G}download${R}   scp file/folder from npad (interactive)
  ${G}run${R} <cmd>  run one command on npad and print the output
  ${G}status${R}     show current configuration
  ${G}help${R}       display this panel

${GB}CONTROL PANEL${R}
  ${G}1${R} shell    ${G}2${R} test     ${G}3${R} upload   ${G}4${R} download
  ${G}5${R} run      ${G}6${R} setup    ${G}7${R} status
  ${G}l${R} language                          ${G}0${R}/${G}q${R} exit

${GB}ENV${R}
  ${GRAY}FISHELL_LANG=pt|en${R}  interface language (default: pt)
  ${GRAY}NO_COLOR=1${R}          disable ansi colors

${GB}CONFIG${R}
  edit ${G}config.ps1${R} (created from config/config.ps1.example on first run)

"@ | Write-Host
    } else {
@"

${GB}USO${R}
  ${G}cmd>${R} bin\fishell.cmd [comando]
  ${G}PS>${R}  .\src\powershell\fishell.ps1 [comando]

${GB}COMANDOS${R}
  ${G}(nenhum)${R}   abre o painel interativo
  ${G}setup${R}      configura o ssh (copia as chaves + registra o alias)
  ${G}login${R}      abre um shell no npad
  ${G}test${R}       testa a conexão (sem abrir shell)
  ${G}upload${R}     envia arquivo/pasta pro npad (interativo)
  ${G}download${R}   baixa arquivo/pasta do npad (interativo)
  ${G}run${R} <cmd>  roda um comando no npad e mostra a saída
  ${G}status${R}     mostra a configuração atual
  ${G}help${R}       mostra esta ajuda

${GB}PAINEL${R}
  ${G}1${R} shell    ${G}2${R} testar   ${G}3${R} enviar   ${G}4${R} baixar
  ${G}5${R} comando  ${G}6${R} setup    ${G}7${R} config
  ${G}l${R} idioma                            ${G}0${R}/${G}q${R} sair

${GB}AMBIENTE${R}
  ${GRAY}FISHELL_LANG=pt|en${R}  idioma da interface (padrão: pt)
  ${GRAY}NO_COLOR=1${R}          desliga as cores

${GB}CONFIG${R}
  edite ${G}config.ps1${R} (criado a partir de config/config.ps1.example)

"@ | Write-Host
    }
}

function Pause-Return {
    Write-Raw "`n${GD}[*]${R} $($L.PAUSE)"
    [void][Console]::In.ReadLine()
}

function Menu-Header {
    Write-Line ("${GD}  fishell v${FishellVersion}${R}  ${G}::${R}  ${GB}$($script:NPAD_USER)@$($script:NPAD_HOST)${R}  ${G}::${R}  $($L.HDR_TYPE) ${GB}0${R} $($L.HDR_OR) ${GB}q${R} $($L.HDR_EXIT)")
    Write-Line ""
}

# Linha do painel: "  [X]  <title:20> <hint:16>      " = 50 chars entre ║ e ║.
function Panel-Row {
    param([string]$KeyColor, [string]$Key, [string]$Title, [string]$Hint)
    $titlePad = $Title.PadRight(20)
    $hintPad  = $Hint.PadRight(16)
    Write-Line ("${G}║${R}  ${KeyColor}${Key}${R}  ${GB}${titlePad}${R} ${CYA}${hintPad}${R}      ${G}║${R}")
}

function Draw-Panel {
    param([string]$Flash = '')
    if (-not [Console]::IsOutputRedirected) { Write-Raw "${E}[H" }
    Print-Logo
    Menu-Header
    if ($Flash) { Write-Line $Flash; Write-Line '' }
    Write-Line "${G}╔══════════════════════════════════════════════════╗${R}"
    # 3 espaços + ░ + espaço + título + espaço + ░ + preenchimento = 50
    $fill = ' ' * (43 - $L.PANEL.Length)
    Write-Line ("${G}║${R}   ${CYA}░${R} ${GB}${B}$($L.PANEL)${R} ${CYA}░${R}${fill}${G}║${R}")
    Write-Line "${G}╠══════════════════════════════════════════════════╣${R}"
    Panel-Row $YEL '[1]' $L.M1_T $L.M1_H
    Panel-Row $YEL '[2]' $L.M2_T $L.M2_H
    Panel-Row $YEL '[3]' $L.M3_T $L.M3_H
    Panel-Row $YEL '[4]' $L.M4_T $L.M4_H
    Panel-Row $YEL '[5]' $L.M5_T $L.M5_H
    Panel-Row $YEL '[6]' $L.M6_T $L.M6_H
    Panel-Row $YEL '[7]' $L.M7_T $L.M7_H
    Panel-Row $CYA '[l]' $L.ML_T "( $($script:FISHELL_LANG) )"
    Panel-Row $RED '[0]' $L.M0_T $L.M0_H
    Write-Line "${G}╚══════════════════════════════════════════════════╝${R}"
    # Prompt pede a opção em vez de imitar um shell: um "fishell@npad:~#"
    # dá a impressão de que dá pra digitar comando ali.
    Write-Raw "`n  ${G}>${R} ${GB}$($L.PROMPT)${R} ${GD}[1-7, l, 0]${R} : "
}

# Lê 1 tecla (sem ENTER). Sem TTY, lê uma linha e devolve '0' no EOF, para
# pipe/CI não entrarem em loop.
function Read-MenuKey {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $s = [Console]::In.ReadLine()
        if ($null -eq $s) { return '0' }
        return $s.Trim()
    }
    $k = [Console]::ReadKey($false)
    if ($k.Key -eq 'Enter') { Write-Line ''; return '' }
    return "$($k.KeyChar)"
}

# Sem TTY (pipe, CI) o Clear-Host/cursor-home só sujaria a saída, e o banner já
# saiu uma vez no entry point.
function Redraw {
    if ([Console]::IsOutputRedirected) { return }
    Clear-Host
    Print-Logo
}

function Menu-Loop {
    $flash = ''
    while ($true) {
        if (-not [Console]::IsOutputRedirected) { Clear-Host }
        Draw-Panel -Flash $flash
        $flash = ''
        $opt = Read-MenuKey
        Redraw
        switch -Regex ($opt) {
            '^1$'                  { Action-Login }
            '^2$'                  { Test-Connection-Npad; Pause-Return }
            '^3$'                  { Action-Upload;        Pause-Return }
            '^4$'                  { Action-Download;      Pause-Return }
            '^5$'                  { Action-RunRemote;     Pause-Return }
            '^6$'                  { Setup-SSH;            Pause-Return }
            '^7$'                  { Show-Status;          Pause-Return }
            '^[lL]$' {
                $script:FISHELL_LANG = if ($script:FISHELL_LANG -eq 'en') { 'pt' } else { 'en' }
                $env:FISHELL_LANG = $script:FISHELL_LANG
                Set-Lang
                $flash = "${G}[*]${R} $($L.LANGSET) ${GB}$($script:FISHELL_LANG)${R}"
            }
            '^(0|q|exit|logout)$' {
                Write-Line ""
                Write-Line "${G}[*]${R} $($L.BYE) ${GD}$($L.BYE2)${R}"
                Write-Line ""
                exit 0
            }
            '^$' { }
            default { $flash = "${YEL}[!]${R} $($L.INVALID) $opt" }
        }
    }
}

# ─── Entry point ─────────────────────────────────────────────────────────
# `help` roda antes do Load-Config: precisa funcionar sem config.ps1 ainda
# preenchido (é assim no bash também).
if ($Action -eq 'help') {
    Print-Logo
    Show-Help
    exit 0
}

Load-Config

switch ($Action) {
    'setup'    { Print-Logo; Setup-SSH }
    'login'    { Print-Logo; Action-Login }
    'test'     { Print-Logo; Test-Connection-Npad }
    'upload'   { Print-Logo; Action-Upload }
    'download' { Print-Logo; Action-Download }
    'run'      { Print-Logo; Action-RunRemote -Command ($Rest -join ' ') }
    'status'   { Print-Logo; Show-Status }
    default    {
        Print-Logo
        # auto-setup na primeira execução se ~/.ssh/config não tem alias
        $sshCfg = Join-Path $HOME '.ssh/config'
        $needSetup = $true
        if (Test-Path $sshCfg) {
            if ((Get-Content $sshCfg -Raw) -match "(?m)^Host $([regex]::Escape($script:SSH_ALIAS))\s*$") {
                $needSetup = $false
            }
        }
        if ($needSetup) {
            Setup-SSH
            if (-not $script:SetupOk) { exit 1 }
            Pause-Return
        }
        Menu-Loop
    }
}
