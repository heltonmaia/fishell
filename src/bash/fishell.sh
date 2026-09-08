#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  FISHELL — NPAD/UFRN SSH access terminal
#  https://github.com/heltonmaia/fishell
# ═══════════════════════════════════════════════════════════════
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# O codigo vive em src/bash/, mas config.sh e .ssh/ sao do usuario e ficam na
# raiz do repo — dois niveis acima.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FISHELL_VERSION="2.4"

# Idioma escolhido pelo ambiente vence o do config.sh; guardado antes de
# sourcear a config justamente pra poder reaplicar depois.
FISHELL_LANG_ENV="${FISHELL_LANG:-}"

# Defaults sobrescritos por config.sh em load_config(). Ficam aqui, e não
# só lá dentro, porque o banner é desenhado antes de a config ser lida.
NPAD_HOST="sc2.npad.ufrn.br"
NPAD_PORT="4422"
SSH_ALIAS="npad"

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

# ─── Largura visível ──────────────────────────────────────────
# Conta code points removendo os bytes de continuação UTF-8 (0x80-0xBF).
# Necessário porque printf '%-20s' preenche por BYTE, e com LC_ALL=C até o
# ${#s} do bash conta bytes — qualquer acento desalinharia o painel de 50
# colunas. Este cálculo dá o mesmo resultado em qualquer locale.
vlen() {
    local s="${1//[$'\x80'-$'\xBF']/}"
    printf '%s' "${#s}"
}

# Preenche $2 com espaços até $1 colunas.
pad() {
    local w="$1" s="$2" n
    n=$(vlen "$s")
    (( n >= w )) && { printf '%s' "$s"; return; }
    printf '%s%*s' "$s" "$((w - n))" ""
}

# ─── i18n ─────────────────────────────────────────────────────
# FISHELL_LANG=pt|en (padrão pt). Vem do ambiente ou do config.sh, e pode ser
# trocado em runtime pela tecla [l] do menu.
# Regra do painel: L_M*_T no máximo 20 colunas, L_M*_H no máximo 16.
set_lang() {
    case "${FISHELL_LANG:-pt}" in
      en)
        FISHELL_LANG=en
        L_TAGLINE="npad/ufrn secure access terminal"; L_TARGET="target"
        L_BOOT1="loading fishell runtime..."; L_BOOT2="scanning local environment..."
        L_BOOT3="checking credentials path...";  L_BOOT4="ready."
        L_HDR_TYPE="type"; L_HDR_OR="or"; L_HDR_EXIT="to exit"
        L_PANEL="CONTROL PANEL"
        L_M1_T="open secure shell";    L_M1_H="( ssh npad )"
        L_M2_T="probe connection";     L_M2_H="( dry-run test )"
        L_M3_T="upload payload";       L_M3_H="( scp push )"
        L_M4_T="download payload";     L_M4_H="( scp pull )"
        L_M5_T="exec remote command";  L_M5_H="( one-shot )"
        L_M6_T="redeploy ssh payload"; L_M6_H="( re-setup )"
        L_M7_T="system readout";       L_M7_H="( status )"
        L_M8_T="generate keypair";     L_M8_H="( ssh-keygen )"
        L_ML_T="language";             L_MA_T="toggle animation"
        L_M0_T="logout";               L_M0_H="( exit )"
        L_PROMPT="select option"
        L_PAUSE="press %bENTER%b to return to control panel... "
        L_INVALID="invalid opcode:"; L_BYE="session terminated."; L_BYE2="goodbye."
        L_ANIM="animation:"; L_LANGSET="language:"; L_ON="on"; L_OFF="off"
        L_CFG_NOTFOUND="configuration file not found:"
        L_CFG_COPY="copying template from config/config.sh.example..."
        L_CFG_EDIT="edit %s and set NPAD_USER before running again."
        L_CFG_NOTEMPLATE="template config/config.sh.example missing too. aborting."
        L_CFG_PLACEHOLDER="NPAD_USER is still the default placeholder."
        L_CFG_EDITPATH="edit:"
        L_SETUP_INIT="initializing ssh payload for user"
        L_KEYS_NOTFOUND="keys directory not found:"; L_KEYS_CHECK="check SSH_KEYS_DIR in config.sh"
        L_PRIV_NOTFOUND="private key not found in"; L_PRIV_EXPECT="expected: id_rsa (or id_rsa.txt)"
        L_PRIV_KEYGEN="run './bin/fishell.sh keygen' to create one"
        L_PRIV_OK="private key deployed -> ~/.ssh/id_rsa"
        L_PUB_OK="public key deployed -> ~/.ssh/id_rsa.pub"; L_KH_OK="known_hosts deployed"
        L_ALIAS_UPD="updated in ~/.ssh/config"; L_ALIAS_REG="registered in ~/.ssh/config"
        L_ALIAS_KEPT="exists in ~/.ssh/config but was not created by fishell — kept as is"
        L_READY="payload ready. connect with:"
        L_PROBE="probing target"; L_HANDSHAKE="dispatching handshake (10s timeout)..."
        L_TUNNEL_OK="tunnel established ::"; L_HANDSHAKE_FAIL="handshake failed. verify user, key, network."
        L_OPEN_SHELL="opening secure shell to"; L_EXIT_HINT="(type 'exit' to return to the control panel)"
        L_UPLOAD_STEP="upload // local -> npad"; L_DOWNLOAD_STEP="download // npad -> local"
        L_LOCAL_PATH="local path"; L_REMOTE_PATH="remote path"
        L_SRC_MISSING="does not exist"; L_TRANSFERRING="transferring..."
        L_TRANSFER_OK="transfer complete"; L_TRANSFER_FAIL="transfer failed"
        L_REMOTE_EXEC="remote exec //"; L_CMD="cmd"; L_EMPTY_CMD="empty command, aborted."
        L_STDOUT_BEGIN="─── remote stdout ───"; L_STDOUT_END="─── end ─────────────"
        L_KEYGEN_STEP="generating ssh keypair in"; L_KEY_EXISTS="keypair already exists:"
        L_KEY_REMOVE="remove it by hand first if you really want a new one."
        L_KEYGEN_FAIL="ssh-keygen failed"; L_KEY_CREATED="keypair created ->"
        L_APPEND_PUB="append this public key to"; L_THEN_SETUP="then run: ./bin/fishell.sh setup"
        L_STATUS_STEP="system readout"
        L_ST_USER="USER"; L_ST_HOST="HOST"; L_ST_PORT="PORT"
        L_ST_ALIAS="ALIAS"; L_ST_KEYS="KEYS_DIR"; L_ST_VERSION="VERSION"
        ;;
      *)
        FISHELL_LANG=pt
        L_TAGLINE="terminal de acesso ao npad/ufrn"; L_TARGET="alvo"
        L_BOOT1="carregando o fishell..."; L_BOOT2="verificando o ambiente local..."
        L_BOOT3="procurando as credenciais..."; L_BOOT4="pronto."
        L_HDR_TYPE="tecle"; L_HDR_OR="ou"; L_HDR_EXIT="para sair"
        L_PANEL="PAINEL DE CONTROLE"
        L_M1_T="abrir shell seguro";  L_M1_H="( ssh npad )"
        L_M2_T="testar conexão";      L_M2_H="( sem conectar )"
        L_M3_T="enviar arquivos";     L_M3_H="( scp push )"
        L_M4_T="baixar arquivos";     L_M4_H="( scp pull )"
        L_M5_T="executar comando";    L_M5_H="( uma vez )"
        L_M6_T="reinstalar chaves";   L_M6_H="( refazer )"
        L_M7_T="ver configuração";    L_M7_H="( status )"
        L_M8_T="gerar par de chaves"; L_M8_H="( ssh-keygen )"
        L_ML_T="idioma";              L_MA_T="animação"
        L_M0_T="sair";                L_M0_H="( exit )"
        L_PROMPT="escolha uma opção"
        L_PAUSE="tecle %bENTER%b para voltar ao painel... "
        L_INVALID="opção inválida:"; L_BYE="sessão encerrada."; L_BYE2="até mais."
        L_ANIM="animação:"; L_LANGSET="idioma:"; L_ON="on"; L_OFF="off"
        L_CFG_NOTFOUND="arquivo de configuração não encontrado:"
        L_CFG_COPY="copiando o modelo de config/config.sh.example..."
        L_CFG_EDIT="edite %s e defina NPAD_USER antes de rodar de novo."
        L_CFG_NOTEMPLATE="o modelo config/config.sh.example também não existe. abortando."
        L_CFG_PLACEHOLDER="NPAD_USER ainda é o placeholder padrão."
        L_CFG_EDITPATH="edite:"
        L_SETUP_INIT="preparando o ssh para o usuário"
        L_KEYS_NOTFOUND="pasta de chaves não encontrada:"; L_KEYS_CHECK="confira SSH_KEYS_DIR no config.sh"
        L_PRIV_NOTFOUND="chave privada não encontrada em"; L_PRIV_EXPECT="esperado: id_rsa (ou id_rsa.txt)"
        L_PRIV_KEYGEN="rode './bin/fishell.sh keygen' para gerar uma"
        L_PRIV_OK="chave privada instalada -> ~/.ssh/id_rsa"
        L_PUB_OK="chave pública instalada -> ~/.ssh/id_rsa.pub"; L_KH_OK="known_hosts instalado"
        L_ALIAS_UPD="atualizado no ~/.ssh/config"; L_ALIAS_REG="registrado no ~/.ssh/config"
        L_ALIAS_KEPT="já existe no ~/.ssh/config e não foi criado pelo fishell — mantido como está"
        L_READY="tudo pronto. conecte com:"
        L_PROBE="testando"; L_HANDSHAKE="enviando handshake (limite de 10s)..."
        L_TUNNEL_OK="conexão estabelecida ::"; L_HANDSHAKE_FAIL="falhou. confira usuário, chave e rede."
        L_OPEN_SHELL="abrindo shell em"; L_EXIT_HINT="(digite 'exit' para voltar ao painel)"
        L_UPLOAD_STEP="envio // local -> npad"; L_DOWNLOAD_STEP="download // npad -> local"
        L_LOCAL_PATH="caminho local"; L_REMOTE_PATH="caminho remoto"
        L_SRC_MISSING="não existe"; L_TRANSFERRING="transferindo..."
        L_TRANSFER_OK="transferência concluída"; L_TRANSFER_FAIL="a transferência falhou"
        L_REMOTE_EXEC="comando remoto //"; L_CMD="comando"; L_EMPTY_CMD="comando vazio, cancelado."
        L_STDOUT_BEGIN="─── saída remota ────"; L_STDOUT_END="─── fim ─────────────"
        L_KEYGEN_STEP="gerando par de chaves em"; L_KEY_EXISTS="já existe um par de chaves:"
        L_KEY_REMOVE="apague à mão primeiro se quiser mesmo gerar outro."
        L_KEYGEN_FAIL="o ssh-keygen falhou"; L_KEY_CREATED="par de chaves criado ->"
        L_APPEND_PUB="adicione esta chave pública em"; L_THEN_SETUP="depois rode: ./bin/fishell.sh setup"
        L_STATUS_STEP="configuração atual"
        L_ST_USER="USUÁRIO"; L_ST_HOST="HOST"; L_ST_PORT="PORTA"
        L_ST_ALIAS="ALIAS"; L_ST_KEYS="CHAVES"; L_ST_VERSION="VERSÃO"
        ;;
    esac
}
set_lang

# Typewriter — efeito opcional; desativado se FISHELL_NOANIM=1
typewrite() {
    local text="$1" delay="${2:-0.008}"
    if [[ "${FISHELL_NOANIM:-0}" == "1" || ! -t 1 ]]; then
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

# Desenha uma cena do logo (aquário + FISHELL) para o frame t.
# Bolhas sobem de baixo para cima, peixinho (·) nada da esquerda p/ direita.
draw_logo_scene() {
    local t="$1"
    local fish_col=$(( (t / 2) % 14 ))

    # 6 linhas × 16 colunas de "água"
    local rows=("                " "                " "                " \
                "                " "                " "                ")

    # Bolhas: (col, fase inicial, char)
    local b_cols=(3 8 12 5 14 10)
    local b_phs=(0 3 1 5 2 4)
    local b_chr=("o" "O" "*" "°" "o" "*")
    local i p c ch r before after
    for i in 0 1 2 3 4 5; do
        p=${b_phs[i]}; c=${b_cols[i]}; ch=${b_chr[i]}
        r=$(( (p - t % 6 + 6) % 6 ))
        before="${rows[r]:0:$c}"
        after="${rows[r]:$((c+1))}"
        rows[r]="${before}${ch}${after}"
    done

    # Peixinho (pontinho) na linha central
    r=3; c=$fish_col
    before="${rows[r]:0:$c}"
    after="${rows[r]:$((c+1))}"
    rows[r]="${before}·${after}"

    local -a fs=(
        "███████╗██╗███████╗██╗  ██╗███████╗██╗     ██╗"
        "██╔════╝██║██╔════╝██║  ██║██╔════╝██║     ██║"
        "█████╗  ██║███████╗███████║█████╗  ██║     ██║"
        "██╔══╝  ██║╚════██║██╔══██║██╔══╝  ██║     ██║"
        "██║     ██║███████║██║  ██║███████╗███████╗███████╗"
        "╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝"
    )

    printf '%b' "$G"
    for i in 0 1 2 3 4 5; do
        printf '  %s  %b%s%b\n' "${rows[i]}" "$G_BRIGHT" "${fs[i]}" "$G"
    done
    printf '%b' "$C_RESET"
}

print_info_line() {
    printf '%b  » %s  ::  v%s%b\n' "$G_DIM" "$(pad 31 "$L_TAGLINE")" "$FISHELL_VERSION" "$C_RESET"
    printf '%b  » %s: %s::  imd/ufrn%b\n\n' "$G_DIM" "$L_TARGET" "$(pad 28 "$NPAD_HOST:$NPAD_PORT")" "$C_RESET"
}

# Logo estático — usado em cada redraw do menu (não anima).
# Varia o frame com base em $SECONDS pra dar leve variação entre redraws.
print_logo() {
    local frame=$(( SECONDS % 6 ))
    draw_logo_scene "$frame"
    print_info_line
}

# Lê uma tecla do menu mantendo o aquário animando no topo.
# Com FISHELL_NOANIM=1 ou sem TTY, cai num read normal.
menu_prompt_read() {
    local _var="$1"
    if [[ "${FISHELL_NOANIM:-0}" == "1" || ! -t 0 || ! -t 1 ]]; then
        # EOF (stdin fechado/pipe): devolve '0' pra sair em vez de loopar.
        # shellcheck disable=SC2229  # atribuição indireta é intencional aqui
        read -r "$_var" || printf -v "$_var" '0'
        return
    fi
    printf '\0337'   # DECSC: salva posição do cursor (no prompt)
    local t=0 key=""
    while true; do
        printf '\033[H'           # vai pro canto superior esquerdo
        draw_logo_scene "$t"      # redesenha só as 6 linhas do banner
        printf '\0338'            # DECRC: volta o cursor ao prompt
        if IFS= read -rs -t 0.12 -N 1 key; then
            if [[ "$key" == $'\n' || "$key" == $'\r' ]]; then
                printf -v "$_var" ''
                echo
            else
                printf -v "$_var" '%s' "$key"
                printf '%s\n' "$key"
            fi
            # Garante que o tty saia em modo canônico (o read -rs -N normalmente
            # restaura, mas em timeout forçado ou sinal pode sobrar state).
            stty sane 2>/dev/null || true
            return
        fi
        t=$((t+1))
    done
}

# Animação de entrada: peixinho nada + bolhas sobem (~1.5s).
animate_intro() {
    if [[ "${FISHELL_NOANIM:-0}" == "1" || ! -t 1 ]]; then
        print_logo
        return
    fi
    clear 2>/dev/null || true
    local t frames=16 delay=0.08
    for (( t=0; t<frames; t++ )); do
        tput cup 0 0 2>/dev/null || printf '\033[H'
        draw_logo_scene "$t"
        sleep "$delay"
    done
    print_info_line
}

print_banner() {
    animate_intro
}

# Boot sequence curta (rodada 1x por sessão)
boot_sequence() {
    [[ "${FISHELL_NOANIM:-0}" == "1" || ! -t 1 ]] && return
    printf '%b' "$G_DIM"
    typewrite "  [boot] $L_BOOT1" 0.004
    typewrite "  [boot] $L_BOOT2" 0.004
    typewrite "  [boot] $L_BOOT3" 0.004
    typewrite "  [boot] $L_BOOT4" 0.004
    printf '%b\n' "$C_RESET"
}

# ─── Carrega configuração ─────────────────────────────────────
load_config() {
    local cfg="$REPO_ROOT/config.sh"
    local example="$REPO_ROOT/config/config.sh.example"

    if [[ ! -f "$cfg" ]]; then
        log_warn "$L_CFG_NOTFOUND $cfg"
        if [[ -f "$example" ]]; then
            log_info "$L_CFG_COPY"
            cp "$example" "$cfg"
            log_warn "$(printf "$L_CFG_EDIT" "$cfg")"
            printf '\n  %b$%b nano %s\n\n' "$G" "$C_RESET" "$cfg"
            exit 1
        else
            log_err "$L_CFG_NOTEMPLATE"
            exit 1
        fi
    fi

    # shellcheck source=/dev/null
    source "$cfg"

    : "${NPAD_USER:?NPAD_USER não definido em config.sh}"
    : "${NPAD_HOST:=sc2.npad.ufrn.br}"
    : "${NPAD_PORT:=4422}"
    : "${SSH_ALIAS:=npad}"

    # Ambiente vence o config.sh; reaplica a tabela de strings depois.
    [[ -n "$FISHELL_LANG_ENV" ]] && FISHELL_LANG="$FISHELL_LANG_ENV"
    set_lang

    if [[ "$NPAD_USER" == "seu_usuario_aqui" ]]; then
        log_err "$L_CFG_PLACEHOLDER"
        log_info "$L_CFG_EDITPATH $cfg"
        exit 1
    fi

    if [[ -z "${SSH_KEYS_DIR:-}" ]]; then
        if [[ -d "/content/drive/MyDrive/visaocomputacional/.ssh" ]]; then
            SSH_KEYS_DIR="/content/drive/MyDrive/visaocomputacional/.ssh"
        else
            SSH_KEYS_DIR="$REPO_ROOT/.ssh"
        fi
    fi
}

# ─── Setup SSH ────────────────────────────────────────────────
setup_ssh() {
    log_step "$L_SETUP_INIT '$NPAD_USER'"
    local home_ssh="$HOME/.ssh"
    mkdir -p "$home_ssh"
    chmod 700 "$home_ssh"

    if [[ ! -d "$SSH_KEYS_DIR" ]]; then
        log_err "$L_KEYS_NOTFOUND $SSH_KEYS_DIR"
        log_info "$L_KEYS_CHECK"
        return 1
    fi

    local priv=""
    for cand in "$SSH_KEYS_DIR/id_rsa" "$SSH_KEYS_DIR/id_rsa.txt"; do
        [[ -f "$cand" ]] && { priv="$cand"; break; }
    done
    if [[ -z "$priv" ]]; then
        log_err "$L_PRIV_NOTFOUND $SSH_KEYS_DIR"
        log_info "$L_PRIV_EXPECT"
        log_info "$L_PRIV_KEYGEN"
        return 1
    fi

    install -m 600 "$priv" "$home_ssh/id_rsa"
    log_ok "$L_PRIV_OK"

    if [[ -f "$SSH_KEYS_DIR/id_rsa.pub" ]]; then
        install -m 644 "$SSH_KEYS_DIR/id_rsa.pub" "$home_ssh/id_rsa.pub"
        log_ok "$L_PUB_OK"
    fi

    for kh in "$SSH_KEYS_DIR/known_hosts" "$SSH_KEYS_DIR/known_hosts.txt"; do
        if [[ -f "$kh" ]]; then
            install -m 600 "$kh" "$home_ssh/known_hosts"
            log_ok "$L_KH_OK"
            break
        fi
    done

    local tmp_block="$home_ssh/.fishell.block"
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
    if grep -q '^# ── fishell: begin ──$' "$home_ssh/config" 2>/dev/null; then
        # bloco gerenciado pelo fishell já existe: remove e reescreve com a config atual
        local cfg_tmp="$home_ssh/.config.fishell.tmp"
        # Guarda as linhas e imprime ate' a ultima nao-vazia: sem isso cada
        # setup repetido deixa mais uma linha em branco no topo do arquivo,
        # porque o bloco e' reanexado sempre precedido de um echo "".
        awk '
            /^# ── fishell: begin ──$/ { skip=1; next }
            /^# ── fishell: end ──$/   { skip=0; next }
            !skip { lines[++n] = $0; if (NF) last = n }
            END   { for (i = 1; i <= last; i++) print lines[i] }
        ' "$home_ssh/config" > "$cfg_tmp"
        mv "$cfg_tmp" "$home_ssh/config"
        chmod 600 "$home_ssh/config"
        {
            echo ""
            echo "# ── fishell: begin ──"
            cat "$tmp_block"
            echo "# ── fishell: end ──"
        } >> "$home_ssh/config"
        log_ok "alias '$SSH_ALIAS' $L_ALIAS_UPD"
    elif ! grep -q "^Host $SSH_ALIAS\$" "$home_ssh/config" 2>/dev/null; then
        {
            echo ""
            echo "# ── fishell: begin ──"
            cat "$tmp_block"
            echo "# ── fishell: end ──"
        } >> "$home_ssh/config"
        log_ok "alias '$SSH_ALIAS' $L_ALIAS_REG"
    else
        log_warn "alias '$SSH_ALIAS' $L_ALIAS_KEPT"
    fi
    rm -f "$tmp_block"

    printf '\n'
    log_ok "$L_READY ${G_BRIGHT}${C_BOLD}ssh ${SSH_ALIAS}${C_RESET}"
}

test_connection() {
    log_step "$L_PROBE $NPAD_HOST:$NPAD_PORT"
    log_work "$L_HANDSHAKE"
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_ALIAS" true 2>/dev/null; then
        log_ok "$L_TUNNEL_OK $NPAD_USER@$NPAD_HOST"
    else
        log_err "$L_HANDSHAKE_FAIL"
        return 1
    fi
}

action_login() {
    log_step "$L_OPEN_SHELL $SSH_ALIAS"
    log_work "$L_EXIT_HINT"
    ssh "$SSH_ALIAS"
}

action_upload() {
    log_step "$L_UPLOAD_STEP"
    local src dst
    printf '  %b>%b %s : ' "$G" "$C_RESET" "$L_LOCAL_PATH"
    read -r src
    printf '  %b>%b %s [~/] : ' "$G" "$C_RESET" "$L_REMOTE_PATH"
    read -r dst
    [[ -z "$dst" ]] && dst="~/"
    if [[ ! -e "$src" ]]; then
        log_err "'$src' $L_SRC_MISSING"
        return 1
    fi
    stty sane 2>/dev/null || true
    log_work "$L_TRANSFERRING"
    scp -P "$NPAD_PORT" -r "$src" "${SSH_ALIAS}:${dst}" \
        && log_ok "$L_TRANSFER_OK" || log_err "$L_TRANSFER_FAIL"
}

action_download() {
    log_step "$L_DOWNLOAD_STEP"
    local src dst
    printf '  %b>%b %s : ' "$G" "$C_RESET" "$L_REMOTE_PATH"
    read -r src
    printf '  %b>%b %s [./] : ' "$G" "$C_RESET" "$L_LOCAL_PATH"
    read -r dst
    [[ -z "$dst" ]] && dst="./"
    stty sane 2>/dev/null || true
    log_work "transferring..."
    scp -P "$NPAD_PORT" -r "${SSH_ALIAS}:${src}" "$dst" \
        && log_ok "transfer complete" || log_err "transfer failed"
}

action_run_remote() {
    log_step "$L_REMOTE_EXEC $SSH_ALIAS"
    local cmd="$*"
    if [[ -z "$cmd" ]]; then
        # Prompt separado do read (ANSI escapes em read -rp confundem o readline).
        printf '  %b>%b %s : ' "$G" "$C_RESET" "$L_CMD"
        read -r cmd
    fi
    [[ -z "$cmd" ]] && { log_warn "$L_EMPTY_CMD"; return 1; }
    # Reseta estado do terminal (o loop de animação do menu pode ter deixado
    # o tty em modo não-canônico). Sem isso, algumas linhas do output remoto
    # chegam com o primeiro char corrompido.
    stty sane 2>/dev/null || true
    printf '%b%s%b\n' "$G_DIM" "$L_STDOUT_BEGIN" "$C_RESET"
    # -T: não aloca pseudo-tty (evita warning "stdin is not a tty" e reduz
    # chance de scripts server-side (/etc/profile, ~/.bashrc) produzirem
    # erros de escrita em stderr).
    ssh -T "$SSH_ALIAS" "$cmd"
    printf '%b%s%b\n' "$G_DIM" "$L_STDOUT_END" "$C_RESET"
}

action_keygen() {
    log_step "$L_KEYGEN_STEP $SSH_KEYS_DIR"
    local key="$SSH_KEYS_DIR/id_rsa"
    if [[ -f "$key" ]]; then
        log_warn "$L_KEY_EXISTS $key"
        log_info "$L_KEY_REMOVE"
        return 1
    fi
    mkdir -p "$SSH_KEYS_DIR"
    chmod 700 "$SSH_KEYS_DIR"
    stty sane 2>/dev/null || true
    if ! ssh-keygen -t rsa -b 4096 -N '' -C "${NPAD_USER}@fishell" -f "$key" >/dev/null; then
        log_err "$L_KEYGEN_FAIL"
        return 1
    fi
    chmod 600 "$key"
    chmod 644 "$key.pub"
    log_ok "$L_KEY_CREATED $key"
    printf '\n%b  %s %s@%s:~/.ssh/authorized_keys%b\n\n' \
        "$G_DIM" "$L_APPEND_PUB" "$NPAD_USER" "$NPAD_HOST" "$C_RESET"
    printf '%b%s%b\n\n' "$G_BRIGHT" "$(cat "$key.pub")" "$C_RESET"
    log_info "$L_THEN_SETUP"
}

show_status() {
    log_step "$L_STATUS_STEP"
    hline 50 ─
    _st() { printf '  %b%s%b %s\n' "$G_BRIGHT" "$(pad 10 "$1")" "$C_RESET" "$2"; }
    _st "$L_ST_USER"    "$NPAD_USER"
    _st "$L_ST_HOST"    "$NPAD_HOST"
    _st "$L_ST_PORT"    "$NPAD_PORT"
    _st "$L_ST_ALIAS"   "$SSH_ALIAS"
    _st "$L_ST_KEYS"    "$SSH_KEYS_DIR"
    _st "$L_ST_VERSION" "fishell v$FISHELL_VERSION"
    hline 50 ─
}

show_help() {
    if [[ "$FISHELL_LANG" == "en" ]]; then
        cat <<EOF

${G_BRIGHT}USAGE${C_RESET}
  ${G}\$${C_RESET} ./bin/fishell.sh [command]

${G_BRIGHT}COMMANDS${C_RESET}
  ${G}(none)${C_RESET}     launch interactive control panel
  ${G}setup${C_RESET}      configure ssh (copy keys + register alias)
  ${G}login${C_RESET}      open secure shell to npad
  ${G}test${C_RESET}       probe connection (no shell)
  ${G}upload${C_RESET}     scp file/folder to npad (interactive)
  ${G}download${C_RESET}   scp file/folder from npad (interactive)
  ${G}run${C_RESET} <cmd>  run one command on npad and print the output
  ${G}keygen${C_RESET}     generate a new keypair in the keys dir
  ${G}status${C_RESET}     show current configuration
  ${G}help${C_RESET}       display this panel

${G_BRIGHT}CONTROL PANEL${C_RESET}
  ${G}1${C_RESET} shell    ${G}2${C_RESET} test     ${G}3${C_RESET} upload   ${G}4${C_RESET} download
  ${G}5${C_RESET} run      ${G}6${C_RESET} setup    ${G}7${C_RESET} status   ${G}8${C_RESET} keygen
  ${G}l${C_RESET} language         ${G}a${C_RESET} animation        ${G}0${C_RESET}/${G}q${C_RESET} exit

${G_BRIGHT}ENV${C_RESET}
  ${GRAY}FISHELL_LANG=pt|en${C_RESET}  interface language (default: pt)
  ${GRAY}FISHELL_NOANIM=1${C_RESET}    disable typewriter/boot animation
  ${GRAY}NO_COLOR=1${C_RESET}          disable ansi colors

${G_BRIGHT}CONFIG${C_RESET}
  edit ${G}config.sh${C_RESET} (created from config/config.sh.example on first run)

EOF
    else
        cat <<EOF

${G_BRIGHT}USO${C_RESET}
  ${G}\$${C_RESET} ./bin/fishell.sh [comando]

${G_BRIGHT}COMANDOS${C_RESET}
  ${G}(nenhum)${C_RESET}   abre o painel interativo
  ${G}setup${C_RESET}      configura o ssh (copia as chaves + registra o alias)
  ${G}login${C_RESET}      abre um shell no npad
  ${G}test${C_RESET}       testa a conexão (sem abrir shell)
  ${G}upload${C_RESET}     envia arquivo/pasta pro npad (interativo)
  ${G}download${C_RESET}   baixa arquivo/pasta do npad (interativo)
  ${G}run${C_RESET} <cmd>  roda um comando no npad e mostra a saída
  ${G}keygen${C_RESET}     gera um par de chaves novo
  ${G}status${C_RESET}     mostra a configuração atual
  ${G}help${C_RESET}       mostra esta ajuda

${G_BRIGHT}PAINEL${C_RESET}
  ${G}1${C_RESET} shell    ${G}2${C_RESET} testar   ${G}3${C_RESET} enviar   ${G}4${C_RESET} baixar
  ${G}5${C_RESET} comando  ${G}6${C_RESET} setup    ${G}7${C_RESET} config   ${G}8${C_RESET} chaves
  ${G}l${C_RESET} idioma           ${G}a${C_RESET} animação         ${G}0${C_RESET}/${G}q${C_RESET} sair

${G_BRIGHT}AMBIENTE${C_RESET}
  ${GRAY}FISHELL_LANG=pt|en${C_RESET}  idioma da interface (padrão: pt)
  ${GRAY}FISHELL_NOANIM=1${C_RESET}    desliga a animação
  ${GRAY}NO_COLOR=1${C_RESET}          desliga as cores

${G_BRIGHT}CONFIG${C_RESET}
  edite ${G}config.sh${C_RESET} (criado a partir de config/config.sh.example)

EOF
    fi
}

pause_return() {
    printf "\n%b[*]%b $L_PAUSE" "$G_DIM" "$C_RESET" "$G_BRIGHT" "$C_RESET"
    read -r _ || true
}

menu_header() {
    printf '%b  fishell v%s%b  %b::%b  %b%s@%s%b  %b::%b  %s %b0%b %s %bq%b %s%b\n\n' \
        "$G_DIM" "$FISHELL_VERSION" "$C_RESET" \
        "$G" "$C_RESET" \
        "$G_BRIGHT" "$NPAD_USER" "$NPAD_HOST" "$C_RESET" \
        "$G" "$C_RESET" "$L_HDR_TYPE" \
        "$G_BRIGHT" "$C_RESET" "$L_HDR_OR" \
        "$G_BRIGHT" "$C_RESET" "$L_HDR_EXIT" "$C_RESET"
}

menu() {
    local flash=""
    while true; do
        clear 2>/dev/null || true
        print_logo
        menu_header
        if [[ -n "$flash" ]]; then
            printf '%s\n\n' "$flash"
            flash=""
        fi
        # Linha do painel: 50 chars entre as barras. Layout:
        #   "  [X]  <title:20> <hint:16>      " = 2+3+2+20+1+16+6 = 50
        _row() {
            local kc="$1" k="$2" title="$3" hint="$4"
            printf '%b║%b  %b%s%b  %b%s%b %b%s%b      %b║%b\n' \
                "$G" "$C_RESET" \
                "$kc" "$k" "$C_RESET" \
                "$G_BRIGHT" "$(pad 20 "$title")" "$C_RESET" \
                "$CYA" "$(pad 16 "$hint")" "$C_RESET" \
                "$G" "$C_RESET"
        }
        printf '%b╔══════════════════════════════════════════════════╗%b\n' "$G" "$C_RESET"
        # Header: "   ░ CONTROL PANEL ░                              " = 3+1+1+13+1+1+30 = 50
        # 3 espaços + ░ + espaço + título + espaço + ░ + preenchimento = 50
        local _fill=$(( 43 - $(vlen "$L_PANEL") ))
        printf '%b║%b   %b░%b %b%s%b %b░%b%*s%b║%b\n' \
            "$G" "$C_RESET" \
            "$CYA" "$C_RESET" \
            "$G_BRIGHT$C_BOLD" "$L_PANEL" "$C_RESET" \
            "$CYA" "$C_RESET" \
            "$_fill" "" \
            "$G" "$C_RESET"
        printf '%b╠══════════════════════════════════════════════════╣%b\n' "$G" "$C_RESET"
        _row "$YEL" "[1]" "$L_M1_T" "$L_M1_H"
        _row "$YEL" "[2]" "$L_M2_T" "$L_M2_H"
        _row "$YEL" "[3]" "$L_M3_T" "$L_M3_H"
        _row "$YEL" "[4]" "$L_M4_T" "$L_M4_H"
        _row "$YEL" "[5]" "$L_M5_T" "$L_M5_H"
        _row "$YEL" "[6]" "$L_M6_T" "$L_M6_H"
        _row "$YEL" "[7]" "$L_M7_T" "$L_M7_H"
        _row "$YEL" "[8]" "$L_M8_T" "$L_M8_H"
        local _anim
        if [[ "${FISHELL_NOANIM:-0}" == "1" ]]; then _anim="$L_OFF"; else _anim="$L_ON"; fi
        _row "$CYA" "[l]" "$L_ML_T" "( $FISHELL_LANG )"
        _row "$CYA" "[a]" "$L_MA_T" "( $_anim )"
        _row "$RED" "[0]" "$L_M0_T" "$L_M0_H"
        printf '%b╚══════════════════════════════════════════════════╝%b\n' "$G" "$C_RESET"
        local opt
        # Prompt pede a opção em vez de imitar um shell: um "fishell@npad:~#"
        # dá a impressão de que dá pra digitar comando ali.
        printf '\n  %b>%b %b%s%b %b[1-8, l, a, 0]%b : ' \
            "$G" "$C_RESET" "$G_BRIGHT" "$L_PROMPT" "$C_RESET" "$G_DIM" "$C_RESET"
        menu_prompt_read opt
        clear 2>/dev/null || true
        print_logo
        case "$opt" in
            1|01) action_login ;;
            2|02) test_connection;  pause_return ;;
            3|03) action_upload;    pause_return ;;
            4|04) action_download;  pause_return ;;
            5|05) action_run_remote; pause_return ;;
            6|06) setup_ssh;        pause_return ;;
            7|07) show_status;      pause_return ;;
            8|08) action_keygen;     pause_return ;;
            a|A)
                if [[ "${FISHELL_NOANIM:-0}" == "1" ]]; then
                    export FISHELL_NOANIM=0
                    flash="$(printf '%b[*]%b %s %b%s%b' "$G" "$C_RESET" "$L_ANIM" "$G_BRIGHT" "$L_ON" "$C_RESET")"
                else
                    export FISHELL_NOANIM=1
                    flash="$(printf '%b[*]%b %s %b%s%b' "$G" "$C_RESET" "$L_ANIM" "$G_DIM" "$L_OFF" "$C_RESET")"
                fi
                ;;
            l|L)
                if [[ "$FISHELL_LANG" == "en" ]]; then FISHELL_LANG=pt; else FISHELL_LANG=en; fi
                export FISHELL_LANG
                set_lang
                flash="$(printf '%b[*]%b %s %b%s%b' "$G" "$C_RESET" "$L_LANGSET" "$G_BRIGHT" "$FISHELL_LANG" "$C_RESET")"
                ;;
            0|00|q|exit|logout)
                printf '\n%b[*]%b %s %b%s%b\n\n' "$G" "$C_RESET" "$L_BYE" "$G_DIM" "$L_BYE2" "$C_RESET"
                exit 0 ;;
            "") ;; # ENTER vazio: só redesenha
            *) flash="$(printf '%b[!]%b %s %s' "$YEL" "$C_RESET" "$L_INVALID" "$opt")" ;;
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
        run)      shift; action_run_remote "$@" ;;
        keygen)   action_keygen ;;
        status)   show_status ;;
        menu)
            if ! grep -q "^Host $SSH_ALIAS\$" "$HOME/.ssh/config" 2>/dev/null; then
                setup_ssh || exit 1
                pause_return
            fi
            menu
            ;;
        *) log_err "unknown command: $1"; show_help; exit 2 ;;
    esac
}

main "$@"
