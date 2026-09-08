# ═══════════════════════════════════════════════════════════════════════════
#  fishell.ps1 — porta Windows/PowerShell do fishell
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
                 'run', 'keygen', 'status', 'help', '')]
    [string]$Action = 'menu',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$FishellVersion = '2.4'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# O codigo vive em src/powershell/, mas config.ps1 e .ssh/ sao do usuario e
# ficam na raiz do repo — dois niveis acima.
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
            # BOOT* ficam aqui só para a tabela ser idêntica à do bash; o port
            # PowerShell não tem boot sequence.
            BOOT1='loading fishell runtime...'; BOOT2='scanning local environment...'
            BOOT3='checking credentials path...';  BOOT4='ready.'
            HDR_TYPE='type'; HDR_OR='or'; HDR_EXIT='to exit'
            PANEL='CONTROL PANEL'
            M1_T='open secure shell';    M1_H='( ssh npad )'
            M2_T='probe connection';     M2_H='( dry-run test )'
            M3_T='upload payload';       M3_H='( scp push )'
            M4_T='download payload';     M4_H='( scp pull )'
            M5_T='exec remote command';  M5_H='( one-shot )'
            M6_T='redeploy ssh payload'; M6_H='( re-setup )'
            M7_T='system readout';       M7_H='( status )'
            M8_T='generate keypair';     M8_H='( ssh-keygen )'
            ML_T='language';             MA_T='toggle animation'
            M0_T='logout';               M0_H='( exit )'
            PROMPT='select option'; PAUSE='press ENTER to return to control panel... '
            INVALID='invalid opcode:'; BYE='session terminated.'; BYE2='goodbye.'
            ANIM='animation:'; LANGSET='language:'; ON='on'; OFF='off'
            CFG_NOTFOUND='configuration file not found:'
            CFG_COPY='copying template from config/config.ps1.example...'
            CFG_EDIT='edit {0} and set $NPAD_USER before running again.'
            CFG_NOTEMPLATE='template config/config.ps1.example missing too. aborting.'
            CFG_PLACEHOLDER='NPAD_USER is still the default placeholder.'; CFG_EDITPATH='edit:'
            SETUP_INIT='initializing ssh payload for user'
            KEYS_NOTFOUND='keys directory not found:'; KEYS_CHECK='check $SSH_KEYS_DIR in config.ps1'
            PRIV_NOTFOUND='private key not found in'; PRIV_EXPECT='expected: id_rsa (or id_rsa.txt)'
            PRIV_KEYGEN="run 'bin\fishell.cmd keygen' to create one"
            PRIV_OK='private key deployed -> ~/.ssh/id_rsa'
            PUB_OK='public key deployed -> ~/.ssh/id_rsa.pub'; KH_OK='known_hosts deployed'
            ALIAS_UPD='updated in ~/.ssh/config'; ALIAS_REG='registered in ~/.ssh/config'
            ALIAS_KEPT='exists in ~/.ssh/config but was not created by fishell - kept as is'
            READY='payload ready. connect with:'
            PROBE='probing target'; HANDSHAKE='dispatching handshake (10s timeout)...'
            TUNNEL_OK='tunnel established ::'; HANDSHAKE_FAIL='handshake failed. verify user, key, network.'
            OPEN_SHELL='opening secure shell to'; EXIT_HINT="(type 'exit' to return to the control panel)"
            UPLOAD_STEP='upload // local -> npad'; DOWNLOAD_STEP='download // npad -> local'
            LOCAL_PATH='local path'; REMOTE_PATH='remote path'
            SRC_MISSING='does not exist'; TRANSFERRING='transferring...'
            TRANSFER_OK='transfer complete'; TRANSFER_FAIL='transfer failed'
            REMOTE_EXEC='remote exec //'; CMD='cmd'; EMPTY_CMD='empty command, aborted.'
            STDOUT_BEGIN='─── remote stdout ───'; STDOUT_END='─── end ─────────────'
            KEYGEN_STEP='generating ssh keypair in'; KEY_EXISTS='keypair already exists:'
            KEY_REMOVE='remove it by hand first if you really want a new one.'
            KEYGEN_FAIL='ssh-keygen failed'; KEY_CREATED='keypair created ->'
            APPEND_PUB='append this public key to'; THEN_SETUP="then run: bin\fishell.cmd setup"
            STATUS_STEP='system readout'
            ST_USER='USER'; ST_HOST='HOST'; ST_PORT='PORT'
            ST_ALIAS='ALIAS'; ST_KEYS='KEYS_DIR'; ST_VERSION='VERSION'
        }
    } else {
        $script:FISHELL_LANG = 'pt'
        $script:L = @{
            TAGLINE='terminal de acesso ao npad/ufrn'; TARGET='alvo'
            BOOT1='carregando o fishell...'; BOOT2='verificando o ambiente local...'
            BOOT3='procurando as credenciais...'; BOOT4='pronto.'
            HDR_TYPE='tecle'; HDR_OR='ou'; HDR_EXIT='para sair'
            PANEL='PAINEL DE CONTROLE'
            M1_T='abrir shell seguro';  M1_H='( ssh npad )'
            M2_T='testar conexão';      M2_H='( sem conectar )'
            M3_T='enviar arquivos';     M3_H='( scp push )'
            M4_T='baixar arquivos';     M4_H='( scp pull )'
            M5_T='executar comando';    M5_H='( uma vez )'
            M6_T='reinstalar chaves';   M6_H='( refazer )'
            M7_T='ver configuração';    M7_H='( status )'
            M8_T='gerar par de chaves'; M8_H='( ssh-keygen )'
            ML_T='idioma';              MA_T='animação'
            M0_T='sair';                M0_H='( exit )'
            PROMPT='escolha uma opção'; PAUSE='tecle ENTER para voltar ao painel... '
            INVALID='opção inválida:'; BYE='sessão encerrada.'; BYE2='até mais.'
            ANIM='animação:'; LANGSET='idioma:'; ON='on'; OFF='off'
            CFG_NOTFOUND='arquivo de configuração não encontrado:'
            CFG_COPY='copiando o modelo de config/config.ps1.example...'
            CFG_EDIT='edite {0} e defina $NPAD_USER antes de rodar de novo.'
            CFG_NOTEMPLATE='o modelo config/config.ps1.example também não existe. abortando.'
            CFG_PLACEHOLDER='NPAD_USER ainda é o placeholder padrão.'; CFG_EDITPATH='edite:'
            SETUP_INIT='preparando o ssh para o usuário'
            KEYS_NOTFOUND='pasta de chaves não encontrada:'; KEYS_CHECK='confira $SSH_KEYS_DIR no config.ps1'
            PRIV_NOTFOUND='chave privada não encontrada em'; PRIV_EXPECT='esperado: id_rsa (ou id_rsa.txt)'
            PRIV_KEYGEN="rode 'bin\fishell.cmd keygen' para gerar uma"
            PRIV_OK='chave privada instalada -> ~/.ssh/id_rsa'
            PUB_OK='chave pública instalada -> ~/.ssh/id_rsa.pub'; KH_OK='known_hosts instalado'
            ALIAS_UPD='atualizado no ~/.ssh/config'; ALIAS_REG='registrado no ~/.ssh/config'
            ALIAS_KEPT='já existe no ~/.ssh/config e não foi criado pelo fishell - mantido como está'
            READY='tudo pronto. conecte com:'
            PROBE='testando'; HANDSHAKE='enviando handshake (limite de 10s)...'
            TUNNEL_OK='conexão estabelecida ::'; HANDSHAKE_FAIL='falhou. confira usuário, chave e rede.'
            OPEN_SHELL='abrindo shell em'; EXIT_HINT="(digite 'exit' para voltar ao painel)"
            UPLOAD_STEP='envio // local -> npad'; DOWNLOAD_STEP='download // npad -> local'
            LOCAL_PATH='caminho local'; REMOTE_PATH='caminho remoto'
            SRC_MISSING='não existe'; TRANSFERRING='transferindo...'
            TRANSFER_OK='transferência concluída'; TRANSFER_FAIL='a transferência falhou'
            REMOTE_EXEC='comando remoto //'; CMD='comando'; EMPTY_CMD='comando vazio, cancelado.'
            STDOUT_BEGIN='─── saída remota ────'; STDOUT_END='─── fim ─────────────'
            KEYGEN_STEP='gerando par de chaves em'; KEY_EXISTS='já existe um par de chaves:'
            KEY_REMOVE='apague à mão primeiro se quiser mesmo gerar outro.'
            KEYGEN_FAIL='o ssh-keygen falhou'; KEY_CREATED='par de chaves criado ->'
            APPEND_PUB='adicione esta chave pública em'; THEN_SETUP="depois rode: bin\fishell.cmd setup"
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

function Load-Config {
    $cfg = Join-Path $RepoRoot 'config.ps1'
    $example = Join-Path (Join-Path $RepoRoot 'config') 'config.ps1.example'
    if (-not (Test-Path $cfg)) {
        Log-Warn "$($L.CFG_NOTFOUND) $cfg"
        if (Test-Path $example) {
            Log-Info $L.CFG_COPY
            Copy-Item $example $cfg
            Log-Warn ($L.CFG_EDIT -f $cfg)
            Write-Line ""
            Write-Line "  ${G}PS>${R} notepad $cfg"
            Write-Line ""
            exit 1
        } else {
            Log-Err $L.CFG_NOTEMPLATE
            exit 1
        }
    }
    . $cfg
    if ([string]::IsNullOrWhiteSpace($NPAD_USER) -or $NPAD_USER -eq 'seu_usuario_aqui') {
        Log-Err $L.CFG_PLACEHOLDER
        Log-Info "$($L.CFG_EDITPATH) $cfg"
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
    if ([string]::IsNullOrWhiteSpace($SSH_KEYS_DIR)) {
        $script:SSH_KEYS_DIR = Join-Path $RepoRoot '.ssh'
    } else {
        $script:SSH_KEYS_DIR = $SSH_KEYS_DIR
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

function Print-Logo {
    $frame = ((Get-Date).Second) % 6
    Draw-LogoScene -t $frame
    Print-InfoLine
}

function Animate-Intro {
    if ($env:FISHELL_NOANIM -eq '1' -or [Console]::IsOutputRedirected) {
        Print-Logo
        return
    }
    Clear-Host
    for ($t = 0; $t -lt 16; $t++) {
        Write-Raw "$E[H"
        Draw-LogoScene -t $t
        Start-Sleep -Milliseconds 80
    }
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
    Copy-Item $priv $dstPriv -Force
    Restrict-KeyAcl $dstPriv
    Log-Ok $L.PRIV_OK

    $pub = Join-Path $script:SSH_KEYS_DIR 'id_rsa.pub'
    if (Test-Path $pub) {
        Copy-Item $pub (Join-Path $homeSsh 'id_rsa.pub') -Force
        Log-Ok $L.PUB_OK
    }

    foreach ($kh in @('known_hosts', 'known_hosts.txt')) {
        $p = Join-Path $script:SSH_KEYS_DIR $kh
        if (Test-Path $p) {
            Copy-Item $p (Join-Path $homeSsh 'known_hosts') -Force
            Log-Ok $L.KH_OK
            break
        }
    }

    $sshCfg = Join-Path $homeSsh 'config'
    if (-not (Test-Path $sshCfg)) { New-Item -ItemType File -Path $sshCfg -Force | Out-Null }

    $existing = Get-Content $sshCfg -Raw -ErrorAction SilentlyContinue
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
    if ($existing -match '(?ms)^# ── fishell: begin ──\s*?\r?\n.*?^# ── fishell: end ──\s*?\r?\n?') {
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
    } elseif ($existing -notmatch "(?m)^Host $([regex]::Escape($script:SSH_ALIAS))\s*$") {
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
        Log-Warn "could not tighten ACL on $Path (ssh may still warn)"
    }
}

function Test-Connection-Npad {
    Log-Step "$($L.PROBE) $($script:NPAD_HOST):$($script:NPAD_PORT)"
    Log-Work $L.HANDSHAKE
    & ssh -o ConnectTimeout=10 -o BatchMode=yes $script:SSH_ALIAS true 2>$null
    if ($LASTEXITCODE -eq 0) {
        Log-Ok "$($L.TUNNEL_OK) $($script:NPAD_USER)@$($script:NPAD_HOST)"
    } else {
        Log-Err $L.HANDSHAKE_FAIL
    }
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
    $src = Prompt-Value -Label $L.LOCAL_PATH
    $dst = Prompt-Value -Label $L.REMOTE_PATH -Default '~/'
    if (-not (Test-Path $src)) { Log-Err "'$src' $($L.SRC_MISSING)"; return }
    Log-Work $L.TRANSFERRING
    & scp -P $script:NPAD_PORT -r $src "$($script:SSH_ALIAS):$dst"
    if ($LASTEXITCODE -eq 0) { Log-Ok $L.TRANSFER_OK } else { Log-Err $L.TRANSFER_FAIL }
}

function Action-Download {
    Log-Step $L.DOWNLOAD_STEP
    $src = Prompt-Value -Label $L.REMOTE_PATH
    $dst = Prompt-Value -Label $L.LOCAL_PATH -Default './'
    Log-Work "transferring..."
    & scp -P $script:NPAD_PORT -r "$($script:SSH_ALIAS):$src" $dst
    if ($LASTEXITCODE -eq 0) { Log-Ok "transfer complete" } else { Log-Err "transfer failed" }
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

function Action-Keygen {
    Log-Step "$($L.KEYGEN_STEP) $($script:SSH_KEYS_DIR)"
    $key = Join-Path $script:SSH_KEYS_DIR 'id_rsa'
    if (Test-Path $key) {
        Log-Warn "$($L.KEY_EXISTS) $key"
        Log-Info $L.KEY_REMOVE
        return
    }
    if (-not (Test-Path $script:SSH_KEYS_DIR)) {
        New-Item -ItemType Directory -Path $script:SSH_KEYS_DIR -Force | Out-Null
    }
    # -N '' = sem passphrase (o fluxo BatchMode/Colab depende disso).
    & ssh-keygen -t rsa -b 4096 -N '' -C "$($script:NPAD_USER)@fishell" -f $key | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $key)) {
        Log-Err $L.KEYGEN_FAIL
        return
    }
    Restrict-KeyAcl $key
    Log-Ok "$($L.KEY_CREATED) $key"
    Write-Line ""
    Write-Line "${GD}  $($L.APPEND_PUB) $($script:NPAD_USER)@$($script:NPAD_HOST):~/.ssh/authorized_keys${R}"
    Write-Line ""
    Write-Line "${GB}$(Get-Content "$key.pub" -Raw)${R}"
    Log-Info $L.THEN_SETUP
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
  ${G}keygen${R}     generate a new keypair in the keys dir
  ${G}status${R}     show current configuration
  ${G}help${R}       display this panel

${GB}CONTROL PANEL${R}
  ${G}1${R} shell    ${G}2${R} test     ${G}3${R} upload   ${G}4${R} download
  ${G}5${R} run      ${G}6${R} setup    ${G}7${R} status   ${G}8${R} keygen
  ${G}l${R} language         ${G}a${R} animation        ${G}0${R}/${G}q${R} exit

${GB}ENV${R}
  ${GRAY}FISHELL_LANG=pt|en${R}  interface language (default: pt)
  ${GRAY}FISHELL_NOANIM=1${R}    disable banner animation
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
  ${G}keygen${R}     gera um par de chaves novo
  ${G}status${R}     mostra a configuração atual
  ${G}help${R}       mostra esta ajuda

${GB}PAINEL${R}
  ${G}1${R} shell    ${G}2${R} testar   ${G}3${R} enviar   ${G}4${R} baixar
  ${G}5${R} comando  ${G}6${R} setup    ${G}7${R} config   ${G}8${R} chaves
  ${G}l${R} idioma           ${G}a${R} animação         ${G}0${R}/${G}q${R} sair

${GB}AMBIENTE${R}
  ${GRAY}FISHELL_LANG=pt|en${R}  idioma da interface (padrão: pt)
  ${GRAY}FISHELL_NOANIM=1${R}    desliga a animação
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
    Write-Raw "${E}[H"  # cursor (0,0)
    Draw-LogoScene -t ((Get-Date).Second)
    Print-InfoLine
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
    Panel-Row $YEL '[8]' $L.M8_T $L.M8_H
    $anim = if ($env:FISHELL_NOANIM -eq '1') { $L.OFF } else { $L.ON }
    Panel-Row $CYA '[l]' $L.ML_T "( $($script:FISHELL_LANG) )"
    Panel-Row $CYA '[a]' $L.MA_T "( $anim )"
    Panel-Row $RED '[0]' $L.M0_T $L.M0_H
    Write-Line "${G}╚══════════════════════════════════════════════════╝${R}"
    # Prompt pede a opção em vez de imitar um shell: um "fishell@npad:~#"
    # dá a impressão de que dá pra digitar comando ali.
    Write-Raw "`n  ${G}>${R} ${GB}$($L.PROMPT)${R} ${GD}[1-8, l, a, 0]${R} : "
}

# Lê 1 tecla mantendo o aquário animado no topo.
function Read-MenuKey {
    if ($env:FISHELL_NOANIM -eq '1' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $s = [Console]::In.ReadLine()
        if ($null -eq $s) { return '0' }
        return $s.Trim()
    }
    # Salva posição do cursor (no prompt)
    Write-Raw "${E}7"
    $t = 0
    while ($true) {
        Write-Raw "${E}[H"
        Draw-LogoScene -t $t
        Write-Raw "${E}8"
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($false)
            if ($k.Key -eq 'Enter') { Write-Line ''; return '' }
            return "$($k.KeyChar)"
        }
        Start-Sleep -Milliseconds 120
        $t++
    }
}

function Menu-Loop {
    $flash = ''
    while ($true) {
        Clear-Host
        Draw-Panel -Flash $flash
        $flash = ''
        $opt = Read-MenuKey
        Clear-Host
        Print-Logo
        switch -Regex ($opt) {
            '^1$'                  { Action-Login }
            '^2$'                  { Test-Connection-Npad; Pause-Return }
            '^3$'                  { Action-Upload;        Pause-Return }
            '^4$'                  { Action-Download;      Pause-Return }
            '^5$'                  { Action-RunRemote;     Pause-Return }
            '^6$'                  { Setup-SSH;            Pause-Return }
            '^7$'                  { Show-Status;          Pause-Return }
            '^8$'                  { Action-Keygen;        Pause-Return }
            '^[aA]$' {
                if ($env:FISHELL_NOANIM -eq '1') {
                    $env:FISHELL_NOANIM = '0'
                    $flash = "${G}[*]${R} $($L.ANIM) ${GB}$($L.ON)${R}"
                } else {
                    $env:FISHELL_NOANIM = '1'
                    $flash = "${G}[*]${R} $($L.ANIM) ${GD}$($L.OFF)${R}"
                }
            }
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
    Animate-Intro
    Show-Help
    exit 0
}

Load-Config

switch ($Action) {
    'setup'    { Animate-Intro; Setup-SSH }
    'login'    { Animate-Intro; Action-Login }
    'test'     { Animate-Intro; Test-Connection-Npad }
    'upload'   { Animate-Intro; Action-Upload }
    'download' { Animate-Intro; Action-Download }
    'run'      { Animate-Intro; Action-RunRemote -Command ($Rest -join ' ') }
    'keygen'   { Animate-Intro; Action-Keygen }
    'status'   { Animate-Intro; Show-Status }
    default    {
        Animate-Intro
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
