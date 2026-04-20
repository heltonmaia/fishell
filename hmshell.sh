#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  HMSHELL — NPAD/UFRN SSH access terminal
#  https://github.com/heltonmaia/hmshell
# ═══════════════════════════════════════════════════════════════
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HMSHELL_VERSION="2.0"

# ─── Paleta "terminal hacker" (verde matrix) ──────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_BLINK=$'\033[5m'

    # Matrix green palette
    G=$'\033[38;5;46m'     # neon green (principal)
    G_DIM=$'\033[38;5;28m' # green escurecido
    G_BRIGHT=$'\033[38;5;118m'

    # Alertas
    RED=$'\033[38;5;196m'
    YEL=$'\033[38;5;226m'
    CYA=$'\033[38;5;51m'
    GRAY=$'\033[38;5;240m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_BLINK=''
    G='' G_DIM='' G_BRIGHT=''
    RED='' YEL='' CYA='' GRAY=''
fi

# ─── Helpers de log (estilo hacker) ───────────────────────────
log_info()  { printf '%b[*]%b %s\n' "$CYA"        "$C_RESET" "$*"; }
log_ok()    { printf '%b[+]%b %s\n' "$G_BRIGHT"   "$C_RESET" "$*"; }
log_warn()  { printf '%b[!]%b %s\n' "$YEL"        "$C_RESET" "$*"; }
log_err()   { printf '%b[x]%b %s\n' "$RED"        "$C_RESET" "$*" >&2; }
log_step()  { printf '\n%b[»]%b %b%s%b\n' "$G"    "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
log_work()  { printf '%b[~]%b %s\n' "$G_DIM"      "$C_RESET" "$*"; }

# Typewriter — efeito opcional; desativado se HMSHELL_NOANIM=1
typewrite() {
    local text="$1" delay="${2:-0.008}"
    if [[ "${HMSHELL_NOANIM:-0}" == "1" || ! -t 1 ]]; then
        printf '%s\n' "$text"
        return
    fi
    local i ch
    for (( i=0; i<${#text}; i++ )); do
        ch="${text:i:1}"
        printf '%s' "$ch"
        sleep "$delay"
    done
    printf '\n'
}

# Linha de "scanline" decorativa (largura N)
hline() {
    local n="${1:-62}" ch="${2:-═}"
    local line=""
    local i
    for (( i=0; i<n; i++ )); do line+="$ch"; done
    printf '%b%s%b\n' "$G_DIM" "$line" "$C_RESET"
}

print_banner() {
    clear 2>/dev/null || true
    printf '%b' "$G"
    cat <<'EOF'
  ██╗  ██╗███╗   ███╗███████╗██╗  ██╗███████╗██╗     ██╗
  ██║  ██║████╗ ████║██╔════╝██║  ██║██╔════╝██║     ██║
  ███████║██╔████╔██║███████╗███████║█████╗  ██║     ██║
  ██╔══██║██║╚██╔╝██║╚════██║██╔══██║██╔══╝  ██║     ██║
  ██║  ██║██║ ╚═╝ ██║███████║██║  ██║███████╗███████╗███████╗
  ╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝
EOF
    printf '%b' "$C_RESET"
    printf '%b  » npad/ufrn secure access terminal  ::  v%s%b\n' "$G_DIM" "$HMSHELL_VERSION" "$C_RESET"
    printf '%b  » target: sc2.npad.ufrn.br:4422       ::  imd/ufrn%b\n\n' "$G_DIM" "$C_RESET"
}

# Boot sequence curta (rodada 1x por sessão)
boot_sequence() {
    [[ "${HMSHELL_NOANIM:-0}" == "1" || ! -t 1 ]] && return
    printf '%b' "$G_DIM"
    typewrite "  [boot] loading hmshell runtime..." 0.004
    typewrite "  [boot] scanning local environment..." 0.004
    typewrite "  [boot] checking credentials path..." 0.004
    typewrite "  [boot] ready." 0.004
    printf '%b\n' "$C_RESET"
}

# ─── Carrega configuração ─────────────────────────────────────
load_config() {
    local cfg="$SCRIPT_DIR/config.sh"
    local example="$SCRIPT_DIR/config.sh.example"

    if [[ ! -f "$cfg" ]]; then
        log_warn "configuration file not found: $cfg"
        if [[ -f "$example" ]]; then
            log_info "copying template from config.sh.example..."
            cp "$example" "$cfg"
            log_warn "edit $cfg and set NPAD_USER before running again."
            printf '\n  %b$%b nano %s\n\n' "$G" "$C_RESET" "$cfg"
            exit 1
        else
            log_err "template config.sh.example missing too. aborting."
            exit 1
        fi
    fi

    # shellcheck source=/dev/null
    source "$cfg"

    : "${NPAD_USER:?NPAD_USER não definido em config.sh}"
    : "${NPAD_HOST:=sc2.npad.ufrn.br}"
    : "${NPAD_PORT:=4422}"
    : "${SSH_ALIAS:=npad}"

    if [[ "$NPAD_USER" == "seu_usuario_aqui" ]]; then
        log_err "NPAD_USER ainda é o placeholder padrão."
        log_info "edite: $cfg"
        exit 1
    fi

    if [[ -z "${SSH_KEYS_DIR:-}" ]]; then
        if [[ -d "/content/drive/MyDrive/visaocomputacional/.ssh" ]]; then
            SSH_KEYS_DIR="/content/drive/MyDrive/visaocomputacional/.ssh"
        else
            SSH_KEYS_DIR="$SCRIPT_DIR/.ssh"
        fi
    fi
}

# ─── Setup SSH ────────────────────────────────────────────────
setup_ssh() {
    log_step "initializing ssh payload for user '$NPAD_USER'"
    local home_ssh="$HOME/.ssh"
    mkdir -p "$home_ssh"
    chmod 700 "$home_ssh"

    if [[ ! -d "$SSH_KEYS_DIR" ]]; then
        log_err "keys directory not found: $SSH_KEYS_DIR"
        log_info "check SSH_KEYS_DIR in config.sh"
        return 1
    fi

    local priv=""
    for cand in "$SSH_KEYS_DIR/id_rsa" "$SSH_KEYS_DIR/id_rsa.txt"; do
        [[ -f "$cand" ]] && { priv="$cand"; break; }
    done
    if [[ -z "$priv" ]]; then
        log_err "private key not found in $SSH_KEYS_DIR"
        log_info "expected: id_rsa (or id_rsa.txt)"
        return 1
    fi

    install -m 600 "$priv" "$home_ssh/id_rsa"
    log_ok "private key deployed -> ~/.ssh/id_rsa"

    if [[ -f "$SSH_KEYS_DIR/id_rsa.pub" ]]; then
        install -m 644 "$SSH_KEYS_DIR/id_rsa.pub" "$home_ssh/id_rsa.pub"
        log_ok "public key deployed -> ~/.ssh/id_rsa.pub"
    fi

    for kh in "$SSH_KEYS_DIR/known_hosts" "$SSH_KEYS_DIR/known_hosts.txt"; do
        if [[ -f "$kh" ]]; then
            install -m 600 "$kh" "$home_ssh/known_hosts"
            log_ok "known_hosts deployed"
            break
        fi
    done

    local tmp_block="$home_ssh/.hmshell.block"
    cat > "$tmp_block" <<EOF
Host $SSH_ALIAS
    HostName $NPAD_HOST
    Port $NPAD_PORT
    User $NPAD_USER
    IdentityFile ~/.ssh/id_rsa
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
    touch "$home_ssh/config"
    chmod 600 "$home_ssh/config"
    if ! grep -q "^Host $SSH_ALIAS\$" "$home_ssh/config" 2>/dev/null; then
        {
            echo ""
            echo "# ── hmshell: begin ──"
            cat "$tmp_block"
            echo "# ── hmshell: end ──"
        } >> "$home_ssh/config"
        log_ok "ssh alias '$SSH_ALIAS' registered in ~/.ssh/config"
    else
        log_info "alias '$SSH_ALIAS' already present (kept)"
    fi
    rm -f "$tmp_block"

    printf '\n'
    log_ok "payload ready. connect with: %bssh %s%b\n" "$G_BRIGHT$C_BOLD" "$SSH_ALIAS" "$C_RESET"
}

test_connection() {
    log_step "probing target $NPAD_HOST:$NPAD_PORT"
    log_work "dispatching handshake (10s timeout)..."
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_ALIAS" true 2>/dev/null; then
        log_ok "tunnel established :: $NPAD_USER@$NPAD_HOST"
    else
        log_err "handshake failed. verify user, key, network."
        return 1
    fi
}

action_login() {
    log_step "opening secure shell to $SSH_ALIAS"
    log_work "(type 'exit' to return to the control panel)"
    ssh "$SSH_ALIAS"
}

action_upload() {
    log_step "upload // local -> npad"
    local src dst
    read -rp "  $(printf '%b>%b' "$G" "$C_RESET") local path : " src
    read -rp "  $(printf '%b>%b' "$G" "$C_RESET") remote path [~/] : " dst
    [[ -z "$dst" ]] && dst="~/"
    if [[ ! -e "$src" ]]; then
        log_err "local path '$src' does not exist"
        return 1
    fi
    log_work "transferring..."
    scp -P "$NPAD_PORT" -r "$src" "${SSH_ALIAS}:${dst}" \
        && log_ok "transfer complete" || log_err "transfer failed"
}

action_download() {
    log_step "download // npad -> local"
    local src dst
    read -rp "  $(printf '%b>%b' "$G" "$C_RESET") remote path : " src
    read -rp "  $(printf '%b>%b' "$G" "$C_RESET") local path  [./] : " dst
    [[ -z "$dst" ]] && dst="./"
    log_work "transferring..."
    scp -P "$NPAD_PORT" -r "${SSH_ALIAS}:${src}" "$dst" \
        && log_ok "transfer complete" || log_err "transfer failed"
}

action_run_remote() {
    log_step "remote exec // $SSH_ALIAS"
    local cmd
    read -rp "  $(printf '%b>%b' "$G" "$C_RESET") cmd : " cmd
    [[ -z "$cmd" ]] && { log_warn "empty command, aborted."; return; }
    printf '%b─── remote stdout ───%b\n' "$G_DIM" "$C_RESET"
    ssh "$SSH_ALIAS" "$cmd"
    printf '%b─── end ─────────────%b\n' "$G_DIM" "$C_RESET"
}

show_status() {
    log_step "system readout"
    hline 50 ─
    printf '  %bUSER      %b %s\n' "$G_BRIGHT" "$C_RESET" "$NPAD_USER"
    printf '  %bHOST      %b %s\n' "$G_BRIGHT" "$C_RESET" "$NPAD_HOST"
    printf '  %bPORT      %b %s\n' "$G_BRIGHT" "$C_RESET" "$NPAD_PORT"
    printf '  %bALIAS     %b %s\n' "$G_BRIGHT" "$C_RESET" "$SSH_ALIAS"
    printf '  %bKEYS_DIR  %b %s\n' "$G_BRIGHT" "$C_RESET" "$SSH_KEYS_DIR"
    printf '  %bVERSION   %b hmshell v%s\n' "$G_BRIGHT" "$C_RESET" "$HMSHELL_VERSION"
    hline 50 ─
}

show_help() {
    cat <<EOF

${G_BRIGHT}USAGE${C_RESET}
  ${G}\$${C_RESET} ./hmshell.sh [command]

${G_BRIGHT}COMMANDS${C_RESET}
  ${G}(none)${C_RESET}     launch interactive control panel
  ${G}setup${C_RESET}      configure ssh (copy keys + register alias)
  ${G}login${C_RESET}      open secure shell to npad
  ${G}test${C_RESET}       probe connection (no shell)
  ${G}upload${C_RESET}     scp file/folder to npad (interactive)
  ${G}download${C_RESET}   scp file/folder from npad (interactive)
  ${G}status${C_RESET}     show current configuration
  ${G}help${C_RESET}       display this panel

${G_BRIGHT}ENV${C_RESET}
  ${GRAY}HMSHELL_NOANIM=1${C_RESET}   disable typewriter/boot animation
  ${GRAY}NO_COLOR=1${C_RESET}         disable ansi colors

${G_BRIGHT}CONFIG${C_RESET}
  edit ${G}config.sh${C_RESET} (created from config.sh.example on first run)

EOF
}

pause_return() {
    printf '\n%b[*]%b press %bENTER%b to return to control panel... ' "$G_DIM" "$C_RESET" "$G_BRIGHT" "$C_RESET"
    read -r _ || true
}

menu_header() {
    printf '%b  hmshell v%s%b  %b::%b  %b%s@%s%b  %b::%b  type %b0%b or %bq%b to exit%b\n\n' \
        "$G_DIM" "$HMSHELL_VERSION" "$C_RESET" \
        "$G" "$C_RESET" \
        "$G_BRIGHT" "$NPAD_USER" "$NPAD_HOST" "$C_RESET" \
        "$G" "$C_RESET" \
        "$G_BRIGHT" "$C_RESET" \
        "$G_BRIGHT" "$C_RESET" "$C_RESET"
}

menu() {
    local flash=""
    while true; do
        clear 2>/dev/null || true
        menu_header
        if [[ -n "$flash" ]]; then
            printf '%s\n\n' "$flash"
            flash=""
        fi
        printf '%b╔══════════════════════════════════════════════════╗%b\n' "$G" "$C_RESET"
        printf '%b║%b   %b░ CONTROL PANEL ░%b                              %b║%b\n' "$G" "$C_RESET" "$G_BRIGHT$C_BOLD" "$C_RESET" "$G" "$C_RESET"
        printf '%b╠══════════════════════════════════════════════════╣%b\n' "$G" "$C_RESET"
        printf '%b║%b  %b[1]%b  open secure shell      ( ssh npad )       %b║%b\n' "$G" "$C_RESET" "$G_BRIGHT" "$C_RESET" "$G" "$C_RESET"
        printf '%b║%b  %b[2]%b  probe connection       ( dry-run test )    %b║%b\n' "$G" "$C_RESET" "$G_BRIGHT" "$C_RESET" "$G" "$C_RESET"
        printf '%b║%b  %b[3]%b  upload payload         ( scp push )        %b║%b\n' "$G" "$C_RESET" "$G_BRIGHT" "$C_RESET" "$G" "$C_RESET"
        printf '%b║%b  %b[4]%b  download payload       ( scp pull )        %b║%b\n' "$G" "$C_RESET" "$G_BRIGHT" "$C_RESET" "$G" "$C_RESET"
        printf '%b║%b  %b[5]%b  exec remote command    ( one-shot )        %b║%b\n' "$G" "$C_RESET" "$G_BRIGHT" "$C_RESET" "$G" "$C_RESET"
        printf '%b║%b  %b[6]%b  redeploy ssh payload   ( re-setup )        %b║%b\n' "$G" "$C_RESET" "$G_BRIGHT" "$C_RESET" "$G" "$C_RESET"
        printf '%b║%b  %b[7]%b  system readout         ( status )          %b║%b\n' "$G" "$C_RESET" "$G_BRIGHT" "$C_RESET" "$G" "$C_RESET"
        printf '%b║%b  %b[0]%b  logout                 ( exit )            %b║%b\n' "$G" "$C_RESET" "$RED" "$C_RESET" "$G" "$C_RESET"
        printf '%b╚══════════════════════════════════════════════════╝%b\n' "$G" "$C_RESET"
        local opt
        read -rp "$(printf '\n%bhmshell%b@%bnpad%b:%b~%b%b#%b ' "$G_BRIGHT" "$C_RESET" "$CYA" "$C_RESET" "$G_DIM" "$C_RESET" "$G_BRIGHT" "$C_RESET")" opt
        clear 2>/dev/null || true
        case "$opt" in
            1|01) action_login ;;
            2|02) test_connection;  pause_return ;;
            3|03) action_upload;    pause_return ;;
            4|04) action_download;  pause_return ;;
            5|05) action_run_remote; pause_return ;;
            6|06) setup_ssh;        pause_return ;;
            7|07) show_status;      pause_return ;;
            0|00|q|exit|logout)
                printf '\n%b[*]%b session terminated. %bgoodbye.%b\n\n' "$G" "$C_RESET" "$G_DIM" "$C_RESET"
                exit 0 ;;
            "") ;; # ENTER vazio: só redesenha
            *) flash="$(printf '%b[!]%b invalid opcode: %s' "$YEL" "$C_RESET" "$opt")" ;;
        esac
    done
}

main() {
    case "${1:-menu}" in
        help|-h|--help)
            print_banner
            show_help
            return 0 ;;
    esac

    print_banner
    boot_sequence
    load_config

    case "${1:-menu}" in
        setup)    setup_ssh ;;
        login)    action_login ;;
        test)     test_connection ;;
        upload)   action_upload ;;
        download) action_download ;;
        status)   show_status ;;
        menu)
            if ! grep -q "^Host $SSH_ALIAS\$" "$HOME/.ssh/config" 2>/dev/null; then
                setup_ssh || exit 1
            fi
            menu
            ;;
        *) log_err "unknown command: $1"; show_help; exit 2 ;;
    esac
}

main "$@"
