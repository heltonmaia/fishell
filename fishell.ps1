#!/usr/bin/env pwsh
# ═══════════════════════════════════════════════════════════════════════════
#  fishell.ps1 — porta Windows/PowerShell do fishell
#  Acesso SSH rápido ao NPAD/UFRN (sc2.npad.ufrn.br:4422).
#
#  Requisitos:
#    - Windows 10+ com OpenSSH Client (já vem ativado por padrão; se não,
#      Settings → Apps → Optional features → "OpenSSH Client")
#    - PowerShell 5.1 (padrão) ou PowerShell 7+
#    - Windows Terminal recomendado (cores/ANSI + Unicode)
# ═══════════════════════════════════════════════════════════════════════════

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'setup', 'login', 'test', 'upload', 'download', 'status', 'help', '')]
    [string]$Action = 'menu'
)

$ErrorActionPreference = 'Stop'
$FishellVersion = '2.1'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# UTF-8 no console pra Unicode (blocos, box drawing, ·, °).
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} catch {}

# ─── Paleta ───────────────────────────────────────────────────────────────
$UseColor = -not $env:NO_COLOR -and $Host.UI.SupportsVirtualTerminal
if ($UseColor) {
    $E = [char]27
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

# ─── Carrega config ───────────────────────────────────────────────────────
$script:NPAD_USER = $null
$script:NPAD_HOST = 'sc2.npad.ufrn.br'
$script:NPAD_PORT = '4422'
$script:SSH_ALIAS = 'npad'
$script:SSH_KEYS_DIR = ''

function Load-Config {
    $cfg = Join-Path $ScriptDir 'config.ps1'
    $example = Join-Path $ScriptDir 'config.ps1.example'
    if (-not (Test-Path $cfg)) {
        Log-Warn "configuration file not found: $cfg"
        if (Test-Path $example) {
            Log-Info "copying template from config.ps1.example..."
            Copy-Item $example $cfg
            Log-Warn "edit $cfg and set `$NPAD_USER before running again."
            Write-Line ""
            Write-Line "  ${G}PS>${R} notepad $cfg"
            Write-Line ""
            exit 1
        } else {
            Log-Err "template config.ps1.example missing too. aborting."
            exit 1
        }
    }
    . $cfg
    if ([string]::IsNullOrWhiteSpace($NPAD_USER) -or $NPAD_USER -eq 'seu_usuario_aqui') {
        Log-Err "NPAD_USER ainda é o placeholder padrão."
        Log-Info "edite: $cfg"
        exit 1
    }
    $script:NPAD_USER = $NPAD_USER
    if ($NPAD_HOST) { $script:NPAD_HOST = $NPAD_HOST }
    if ($NPAD_PORT) { $script:NPAD_PORT = $NPAD_PORT }
    if ($SSH_ALIAS) { $script:SSH_ALIAS = $SSH_ALIAS }
    if ([string]::IsNullOrWhiteSpace($SSH_KEYS_DIR)) {
        $script:SSH_KEYS_DIR = Join-Path $ScriptDir '.ssh'
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
    Write-Line "${GD}  » npad/ufrn secure access terminal  ::  v${FishellVersion}${R}"
    Write-Line "${GD}  » target: ${script:NPAD_HOST}:${script:NPAD_PORT}       ::  imd/ufrn${R}"
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
    Log-Step "initializing ssh payload for user '$($script:NPAD_USER)'"
    $homeSsh = Join-Path $HOME '.ssh'
    if (-not (Test-Path $homeSsh)) { New-Item -ItemType Directory -Path $homeSsh -Force | Out-Null }

    if (-not (Test-Path $script:SSH_KEYS_DIR)) {
        Log-Err "keys directory not found: $($script:SSH_KEYS_DIR)"
        Log-Info "check `$SSH_KEYS_DIR in config.ps1"
        return
    }

    $priv = $null
    foreach ($cand in @('id_rsa', 'id_rsa.txt')) {
        $p = Join-Path $script:SSH_KEYS_DIR $cand
        if (Test-Path $p) { $priv = $p; break }
    }
    if (-not $priv) {
        Log-Err "private key not found in $($script:SSH_KEYS_DIR)"
        Log-Info "expected: id_rsa (or id_rsa.txt)"
        return
    }
    $dstPriv = Join-Path $homeSsh 'id_rsa'
    Copy-Item $priv $dstPriv -Force
    Restrict-KeyAcl $dstPriv
    Log-Ok "private key deployed -> ~/.ssh/id_rsa"

    $pub = Join-Path $script:SSH_KEYS_DIR 'id_rsa.pub'
    if (Test-Path $pub) {
        Copy-Item $pub (Join-Path $homeSsh 'id_rsa.pub') -Force
        Log-Ok "public key deployed -> ~/.ssh/id_rsa.pub"
    }

    foreach ($kh in @('known_hosts', 'known_hosts.txt')) {
        $p = Join-Path $script:SSH_KEYS_DIR $kh
        if (Test-Path $p) {
            Copy-Item $p (Join-Path $homeSsh 'known_hosts') -Force
            Log-Ok "known_hosts deployed"
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
        Set-Content -Path $sshCfg -Value $stripped -NoNewline
        Add-Content -Path $sshCfg -Value $block
        Log-Ok "ssh alias '$($script:SSH_ALIAS)' updated in ~/.ssh/config"
    } elseif ($existing -notmatch "(?m)^Host $([regex]::Escape($script:SSH_ALIAS))\s*$") {
        Add-Content -Path $sshCfg -Value $block
        Log-Ok "ssh alias '$($script:SSH_ALIAS)' registered in ~/.ssh/config"
    } else {
        Log-Warn "alias '$($script:SSH_ALIAS)' exists in ~/.ssh/config but was not created by fishell - kept as is"
    }

    Write-Line ""
    Log-Ok "payload ready. connect with: ${GB}${B}ssh $($script:SSH_ALIAS)${R}"
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
    Log-Step "probing target $($script:NPAD_HOST):$($script:NPAD_PORT)"
    Log-Work "dispatching handshake (10s timeout)..."
    & ssh -o ConnectTimeout=10 -o BatchMode=yes $script:SSH_ALIAS true 2>$null
    if ($LASTEXITCODE -eq 0) {
        Log-Ok "tunnel established :: $($script:NPAD_USER)@$($script:NPAD_HOST)"
    } else {
        Log-Err "handshake failed. verify user, key, network."
    }
}

function Action-Login {
    Log-Step "opening secure shell to $($script:SSH_ALIAS)"
    Log-Work "(type 'exit' to return to the control panel)"
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
    Log-Step "upload // local -> npad"
    $src = Prompt-Value -Label 'local path'
    $dst = Prompt-Value -Label 'remote path' -Default '~/'
    if (-not (Test-Path $src)) { Log-Err "local path '$src' does not exist"; return }
    Log-Work "transferring..."
    & scp -P $script:NPAD_PORT -r $src "$($script:SSH_ALIAS):$dst"
    if ($LASTEXITCODE -eq 0) { Log-Ok "transfer complete" } else { Log-Err "transfer failed" }
}

function Action-Download {
    Log-Step "download // npad -> local"
    $src = Prompt-Value -Label 'remote path'
    $dst = Prompt-Value -Label 'local path ' -Default './'
    Log-Work "transferring..."
    & scp -P $script:NPAD_PORT -r "$($script:SSH_ALIAS):$src" $dst
    if ($LASTEXITCODE -eq 0) { Log-Ok "transfer complete" } else { Log-Err "transfer failed" }
}

function Action-RunRemote {
    Log-Step "remote exec // $($script:SSH_ALIAS)"
    $cmd = Prompt-Value -Label 'cmd'
    if ([string]::IsNullOrWhiteSpace($cmd)) { Log-Warn "empty command, aborted."; return }
    Write-Line "${GD}─── remote stdout ───${R}"
    # -T: não aloca pseudo-tty (evita scripts server-side /etc/profile ou
    # ~/.bashrc falharem com "Input/output error" ao escrever no stderr).
    & ssh -T $script:SSH_ALIAS $cmd
    Write-Line "${GD}─── end ─────────────${R}"
}

function Show-Status {
    Log-Step "system readout"
    $line = '─' * 50
    Write-Line "${GD}$line${R}"
    Write-Line ("  ${GB}USER      ${R} " + $script:NPAD_USER)
    Write-Line ("  ${GB}HOST      ${R} " + $script:NPAD_HOST)
    Write-Line ("  ${GB}PORT      ${R} " + $script:NPAD_PORT)
    Write-Line ("  ${GB}ALIAS     ${R} " + $script:SSH_ALIAS)
    Write-Line ("  ${GB}KEYS_DIR  ${R} " + $script:SSH_KEYS_DIR)
    Write-Line ("  ${GB}VERSION   ${R} fishell v" + $FishellVersion)
    Write-Line "${GD}$line${R}"
}

function Show-Help {
@"

${GB}USAGE${R}
  ${G}PS>${R} .\fishell.ps1 [command]
  ${G}cmd>${R} fishell.cmd [command]

${GB}COMMANDS${R}
  ${G}(none)${R}     launch interactive control panel
  ${G}setup${R}      configure ssh (copy keys + register alias)
  ${G}login${R}      open secure shell to npad
  ${G}test${R}       probe connection (no shell)
  ${G}upload${R}     scp file/folder to npad (interactive)
  ${G}download${R}   scp file/folder from npad (interactive)
  ${G}status${R}     show current configuration
  ${G}help${R}       display this panel

${GB}ENV${R}
  ${GRAY}FISHELL_NOANIM=1${R}   disable banner animation
  ${GRAY}NO_COLOR=1${R}         disable ansi colors

${GB}CONFIG${R}
  edit ${G}config.ps1${R} (created from config.ps1.example on first run)

"@ | Write-Host
}

function Pause-Return {
    Write-Raw "`n${GD}[*]${R} press ${GB}ENTER${R} to return to control panel... "
    [void][Console]::In.ReadLine()
}

function Menu-Header {
    Write-Line ("${GD}  fishell v${FishellVersion}${R}  ${G}::${R}  ${GB}$($script:NPAD_USER)@$($script:NPAD_HOST)${R}  ${G}::${R}  type ${GB}0${R} or ${GB}q${R} to exit")
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
    $label = 'CONTROL PANEL'.PadRight(13)
    Write-Line ("${G}║${R}   ${CYA}░${R} ${GB}${B}${label}${R} ${CYA}░${R}                              ${G}║${R}")
    Write-Line "${G}╠══════════════════════════════════════════════════╣${R}"
    Panel-Row $YEL '[1]' 'open secure shell'    '( ssh npad )'
    Panel-Row $YEL '[2]' 'probe connection'     '( dry-run test )'
    Panel-Row $YEL '[3]' 'upload payload'       '( scp push )'
    Panel-Row $YEL '[4]' 'download payload'     '( scp pull )'
    Panel-Row $YEL '[5]' 'exec remote command'  '( one-shot )'
    Panel-Row $YEL '[6]' 'redeploy ssh payload' '( re-setup )'
    Panel-Row $YEL '[7]' 'system readout'       '( status )'
    if ($env:FISHELL_NOANIM -eq '1') { $al = 'off'; $ac = $GD } else { $al = 'on '; $ac = $GB }
    $ttl = 'toggle animation'.PadRight(20)
    Write-Line ("${G}║${R}  ${CYA}[a]${R}  ${GB}${ttl}${R} ${CYA}(${R} ${ac}${al}${R} ${CYA})${R}               ${G}║${R}")
    Panel-Row $RED '[0]' 'logout'               '( exit )'
    Write-Line "${G}╚══════════════════════════════════════════════════╝${R}"
    Write-Raw "`n${GB}fishell${R}@${CYA}npad${R}:${GD}~${R}${GB}#${R} "
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
            '^[aA]$' {
                if ($env:FISHELL_NOANIM -eq '1') {
                    $env:FISHELL_NOANIM = '0'
                    $flash = "${G}[*]${R} animation: ${GB}on${R}"
                } else {
                    $env:FISHELL_NOANIM = '1'
                    $flash = "${G}[*]${R} animation: ${GD}off${R}"
                }
            }
            '^(0|q|exit|logout)$' {
                Write-Line ""
                Write-Line "${G}[*]${R} session terminated. ${GD}goodbye.${R}"
                Write-Line ""
                exit 0
            }
            '^$' { }
            default { $flash = "${YEL}[!]${R} invalid opcode: $opt" }
        }
    }
}

# ─── Entry point ─────────────────────────────────────────────────────────
Load-Config

switch ($Action) {
    'setup'    { Animate-Intro; Setup-SSH }
    'login'    { Animate-Intro; Action-Login }
    'test'     { Animate-Intro; Test-Connection-Npad }
    'upload'   { Animate-Intro; Action-Upload }
    'download' { Animate-Intro; Action-Download }
    'status'   { Animate-Intro; Show-Status }
    'help'     { Show-Help }
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
        if ($needSetup) { Setup-SSH; Pause-Return }
        Menu-Loop
    }
}
