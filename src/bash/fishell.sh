#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  FISHELL: NPAD/UFRN SSH access terminal
#  https://github.com/heltonmaia/fishell
# ═══════════════════════════════════════════════════════════════
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# O codigo vive em src/bash/, mas config.sh e .ssh/ sao do usuario e ficam na
# raiz do repo, dois niveis acima.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FISHELL_VERSION="2.6"

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
# ${#s} do bash conta bytes, qualquer acento desalinharia o painel de 50
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
        L_HDR_TYPE="type"; L_HDR_OR="or"; L_HDR_EXIT="to exit"
        L_PANEL="CONTROL PANEL"
        L_M1_T="open secure shell";    L_M1_H="( ssh npad )"
        L_M2_T="probe connection";     L_M2_H="( dry-run test )"
        L_M3_T="upload payload";       L_M3_H="( scp push )"
        L_M4_T="download payload";     L_M4_H="( scp pull )"
        L_M5_T="exec remote command";  L_M5_H="( one-shot )"
        L_M6_T="redeploy ssh payload"; L_M6_H="( re-setup )"
        L_M7_T="system readout";       L_M7_H="( status )"
        L_ML_T="language"
        L_M0_T="logout";               L_M0_H="( exit )"
        L_PROMPT="select option"
        L_PAUSE="press %bENTER%b to return to control panel... "
        L_INVALID="invalid opcode:"; L_BYE="session terminated."; L_BYE2="goodbye."
        L_LANGSET="language:"
        L_CFG_NOTFOUND="configuration file not found:"
        L_CFG_COPY="copying template from config/config.sh.example..."
        L_CFG_EDIT="edit %s and set NPAD_USER before running again."
        L_CFG_NOTEMPLATE="template config/config.sh.example missing too. aborting."
        L_CFG_PLACEHOLDER="NPAD_USER is still the default placeholder."
        L_CFG_EDITPATH="edit:"
        L_SETUP_INIT="initializing ssh payload for user"
        L_KEYS_NOTFOUND="keys directory not found:"; L_KEYS_CHECK="check SSH_KEYS_DIR in config.sh"
        L_PRIV_NOTFOUND="private key not found in"; L_PRIV_EXPECT="expected: id_rsa (or id_rsa.txt)"
        L_PRIV_KEYGEN="create one with: ssh-keygen -t rsa -f .ssh/id_rsa"
        L_PRIV_OK="private key deployed -> ~/.ssh/id_rsa"
        L_PUB_OK="public key deployed -> ~/.ssh/id_rsa.pub"; L_KH_OK="known_hosts deployed"
        L_ALIAS_UPD="updated in ~/.ssh/config"; L_ALIAS_REG="registered in ~/.ssh/config"
        L_ALIAS_KEPT="exists in ~/.ssh/config but was not created by fishell, kept as is"
        L_READY="payload ready. connect with:"
        L_PROBE="probing target"; L_HANDSHAKE="dispatching handshake (10s timeout)..."
        L_TUNNEL_OK="tunnel established ::"; L_HANDSHAKE_FAIL="handshake failed:"
        L_HINT_KEY="your public key is not registered at NPAD yet, or NPAD_USER is wrong"
        L_HINT_HOSTKEY="missing known_hosts, or the server key changed. Veja o README"
        L_HINT_NET="no route to the server: firewall, or port 4422 blocked"
        L_HINT_DNS="could not resolve the host, check your connection"
        L_OPEN_SHELL="opening secure shell to"; L_EXIT_HINT="(type 'exit' to return to the control panel)"
        L_UPLOAD_STEP="upload // local -> npad"; L_DOWNLOAD_STEP="download // npad -> local"
        L_LOCAL_PATH="local path"; L_REMOTE_PATH="remote path"
        L_SRC_MISSING="does not exist"; L_TRANSFERRING="transferring..."
        L_TRANSFER_OK="transfer complete"; L_TRANSFER_FAIL="transfer failed"
        L_REMOTE_EXEC="remote exec //"; L_CMD="cmd"; L_EMPTY_CMD="empty command, aborted."
        L_STDOUT_BEGIN="─── remote stdout ───"; L_STDOUT_END="─── end ─────────────"
        L_FIRSTRUN="first run, follow the steps:"
        L_STEP_REGISTER="register your public key (your login comes by e-mail)"
        L_STEP_CONFIG="put that login in NPAD_USER"
        L_STEP_RERUN="run again"
        L_KEY_FOUND="your public key:"
        L_KEY_INVALID="this public key does not look valid, do NOT register it"
        L_KEY_FILE="file:"
        L_STEP_KEYGEN="create your ssh key"
        L_STEP_COPYKEY="copy the key you already have into this folder"
        L_KEYS_DIR_MADE="keys folder created:"
        L_STATUS_STEP="system readout"
        L_ST_USER="USER"; L_ST_HOST="HOST"; L_ST_PORT="PORT"
        L_ST_ALIAS="ALIAS"; L_ST_KEYS="KEYS_DIR"; L_ST_VERSION="VERSION"
        ;;
      *)
        FISHELL_LANG=pt
        L_TAGLINE="terminal de acesso ao npad/ufrn"; L_TARGET="alvo"
        L_HDR_TYPE="tecle"; L_HDR_OR="ou"; L_HDR_EXIT="para sair"
        L_PANEL="PAINEL DE CONTROLE"
        L_M1_T="abrir shell seguro";  L_M1_H="( ssh npad )"
        L_M2_T="testar conexão";      L_M2_H="( sem conectar )"
        L_M3_T="enviar arquivos";     L_M3_H="( scp push )"
        L_M4_T="baixar arquivos";     L_M4_H="( scp pull )"
        L_M5_T="executar comando";    L_M5_H="( uma vez )"
        L_M6_T="reinstalar chaves";   L_M6_H="( refazer )"
        L_M7_T="ver configuração";    L_M7_H="( status )"
        L_ML_T="idioma"
        L_M0_T="sair";                L_M0_H="( exit )"
        L_PROMPT="escolha uma opção"
        L_PAUSE="tecle %bENTER%b para voltar ao painel... "
        L_INVALID="opção inválida:"; L_BYE="sessão encerrada."; L_BYE2="até mais."
        L_LANGSET="idioma:"
        L_CFG_NOTFOUND="arquivo de configuração não encontrado:"
        L_CFG_COPY="copiando o modelo de config/config.sh.example..."
        L_CFG_EDIT="edite %s e defina NPAD_USER antes de rodar de novo."
        L_CFG_NOTEMPLATE="o modelo config/config.sh.example também não existe. abortando."
        L_CFG_PLACEHOLDER="NPAD_USER ainda é o placeholder padrão."
        L_CFG_EDITPATH="edite:"
        L_SETUP_INIT="preparando o ssh para o usuário"
        L_KEYS_NOTFOUND="pasta de chaves não encontrada:"; L_KEYS_CHECK="confira SSH_KEYS_DIR no config.sh"
        L_PRIV_NOTFOUND="chave privada não encontrada em"; L_PRIV_EXPECT="esperado: id_rsa (ou id_rsa.txt)"
        L_PRIV_KEYGEN="gere uma com: ssh-keygen -t rsa -f .ssh/id_rsa"
        L_PRIV_OK="chave privada instalada -> ~/.ssh/id_rsa"
        L_PUB_OK="chave pública instalada -> ~/.ssh/id_rsa.pub"; L_KH_OK="known_hosts instalado"
        L_ALIAS_UPD="atualizado no ~/.ssh/config"; L_ALIAS_REG="registrado no ~/.ssh/config"
        L_ALIAS_KEPT="já existe no ~/.ssh/config e não foi criado pelo fishell, mantido como está"
        L_READY="tudo pronto. conecte com:"
        L_PROBE="testando"; L_HANDSHAKE="enviando handshake (limite de 10s)..."
        L_TUNNEL_OK="conexão estabelecida ::"; L_HANDSHAKE_FAIL="falhou:"
        L_HINT_KEY="sua chave pública ainda não está cadastrada no NPAD, ou o NPAD_USER está errado"
        L_HINT_HOSTKEY="falta o known_hosts, ou a chave do servidor mudou. Veja o README"
        L_HINT_NET="sem rota até o servidor: firewall, ou porta 4422 bloqueada"
        L_HINT_DNS="não consegui resolver o host, confira sua conexão"
        L_OPEN_SHELL="abrindo shell em"; L_EXIT_HINT="(digite 'exit' para voltar ao painel)"
        L_UPLOAD_STEP="envio // local -> npad"; L_DOWNLOAD_STEP="download // npad -> local"
        L_LOCAL_PATH="caminho local"; L_REMOTE_PATH="caminho remoto"
        L_SRC_MISSING="não existe"; L_TRANSFERRING="transferindo..."
        L_TRANSFER_OK="transferência concluída"; L_TRANSFER_FAIL="a transferência falhou"
        L_REMOTE_EXEC="comando remoto //"; L_CMD="comando"; L_EMPTY_CMD="comando vazio, cancelado."
        L_STDOUT_BEGIN="─── saída remota ────"; L_STDOUT_END="─── fim ─────────────"
        L_FIRSTRUN="primeira execução, siga os passos:"
        L_STEP_REGISTER="cadastre a chave pública (o login chega por e-mail)"
        L_STEP_CONFIG="ponha esse login em NPAD_USER"
        L_STEP_RERUN="rode de novo"
        L_KEY_FOUND="sua chave pública:"
        L_KEY_INVALID="esta chave pública não parece válida, NÃO cadastre ela"
        L_KEY_FILE="arquivo:"
        L_STEP_KEYGEN="gere sua chave ssh"
        L_STEP_COPYKEY="copie para cá a chave que você já tem"
        L_KEYS_DIR_MADE="pasta de chaves criada:"
        L_STATUS_STEP="configuração atual"
        L_ST_USER="USUÁRIO"; L_ST_HOST="HOST"; L_ST_PORT="PORTA"
        L_ST_ALIAS="ALIAS"; L_ST_KEYS="CHAVES"; L_ST_VERSION="VERSÃO"
        ;;
    esac
}
set_lang

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

# Banner estático. O frame é fixo de propósito: saída determinística ajuda o
# check do painel no CI e o gerador do screenshot.
print_logo() {
    draw_logo_scene 2
    print_info_line
}

# Lê uma tecla do menu (sem ENTER). Sem TTY, cai num read de linha e devolve
# '0' no EOF, para pipe/CI não entrarem em loop.
menu_prompt_read() {
    local _var="$1"
    if [[ ! -t 0 || ! -t 1 ]]; then
        # shellcheck disable=SC2229  # atribuição indireta é intencional aqui
        read -r "$_var" || printf -v "$_var" '0'
        return
    fi
    local key=""
    if IFS= read -rsn1 key; then
        if [[ -z "$key" ]]; then
            printf -v "$_var" ''
            echo
        else
            printf -v "$_var" '%s' "$key"
            printf '%s\n' "$key"
        fi
    else
        printf -v "$_var" '0'
    fi
    # read -rsn1 deixa o tty em modo não-canônico; sem isto o output de
    # subprocesso sai com o primeiro caractere de algumas linhas corrompido.
    stty sane 2>/dev/null || true
}

# ─── Carrega configuração ─────────────────────────────────────
load_config() {
    local cfg="$REPO_ROOT/config.sh"
    local example="$REPO_ROOT/config/config.sh.example"
    NPAD_USER_SET=1

    if [[ ! -f "$cfg" ]]; then
        log_warn "$L_CFG_NOTFOUND $cfg"
        if [[ -f "$example" ]]; then
            log_info "$L_CFG_COPY"
            cp "$example" "$cfg"
            show_onboarding "$cfg"
            exit 1
        else
            log_err "$L_CFG_NOTEMPLATE"
            exit 1
        fi
    fi

    # shellcheck source=/dev/null
    source "$cfg"

    if [[ -z "${NPAD_USER:-}" || "$NPAD_USER" == "seu_usuario_aqui" ]]; then
        NPAD_USER_SET=0
    fi
    : "${NPAD_HOST:=sc2.npad.ufrn.br}"
    : "${NPAD_PORT:=4422}"
    : "${SSH_ALIAS:=npad}"

    # Ambiente vence o config.sh; reaplica a tabela de strings depois.
    [[ -n "$FISHELL_LANG_ENV" ]] && FISHELL_LANG="$FISHELL_LANG_ENV"
    set_lang

    if [[ "$NPAD_USER_SET" == "0" ]]; then
        show_onboarding "$cfg"
        exit 1
    fi

    resolve_keys_dir
}

resolve_keys_dir() {
    [[ -n "${SSH_KEYS_DIR:-}" ]] && return
    if [[ -d "/content/drive/MyDrive/visaocomputacional/.ssh" ]]; then
        SSH_KEYS_DIR="/content/drive/MyDrive/visaocomputacional/.ssh"
    else
        SSH_KEYS_DIR="$REPO_ROOT/.ssh"
    fi
}

# Roteiro de primeira execucao. Substitui o antigo "edite config.sh e defina
# NPAD_USER", que era um beco sem saida: nesse ponto o usuario ainda nao TEM
# um login do NPAD, ele so' existe depois de cadastrar a chave publica.
show_onboarding() {
    local cfg="$1"
    # Na raiz do repo mostra so' "config.sh": o caminho absoluto do Colab e'
    # enorme e nao cabe na linha.
    [[ "$PWD" == "$REPO_ROOT" ]] && cfg="config.sh"
    resolve_keys_dir
    local pub="$SSH_KEYS_DIR/id_rsa.pub"
    local n=1

    # Cria a pasta de chaves: e' um passo a menos, e criar pasta oculta pelo
    # painel de arquivos do Colab e' incomodo.
    if [[ ! -d "$SSH_KEYS_DIR" ]] && mkdir -p "$SSH_KEYS_DIR" 2>/dev/null; then
        chmod 700 "$SSH_KEYS_DIR" 2>/dev/null || true
        log_ok "$L_KEYS_DIR_MADE $SSH_KEYS_DIR"
    fi

    printf '\n%b  %s%b\n\n' "$G_BRIGHT$C_BOLD" "$L_FIRSTRUN" "$C_RESET"

    if [[ -f "$pub" ]]; then
        # Ja' tem chave: mostra a publica pra copiar, conferindo a integridade
        # antes, ela vai colada num formulario oficial do NPAD.
        if validate_pubkey "$pub"; then
            printf '  %b%s%b\n\n' "$G_DIM" "$L_KEY_FOUND" "$C_RESET"
            printf '%b%s%b\n\n' "$G_BRIGHT" "$(cat "$pub")" "$C_RESET"
            printf '  %b%s %s%b\n\n' "$G_DIM" "$L_KEY_FILE" "$pub" "$C_RESET"
        else
            log_err "$L_KEY_INVALID"
            printf '  %b%s%b\n\n' "$G_DIM" "$pub" "$C_RESET"
        fi
    else
        # So' encurta para ".ssh" quando e' mesmo a pasta padrao do repo: com
        # SSH_KEYS_DIR customizado o caminho curto mandaria o usuario gerar a
        # chave onde o fishell nao vai procurar.
        local keys_disp="$SSH_KEYS_DIR"
        [[ "$PWD" == "$REPO_ROOT" && "$SSH_KEYS_DIR" == "$REPO_ROOT/.ssh" ]] && keys_disp=".ssh"
        if [[ -f "$HOME/.ssh/id_rsa" ]]; then
            # Ja' tem chave no ~/.ssh: copiar e' melhor que gerar outra, que
            # precisaria de um cadastro novo no NPAD.
            printf '  %b%d.%b %s\n     %b$ cp ~/.ssh/id_rsa ~/.ssh/id_rsa.pub %s/%b\n' \
                "$YEL" "$n" "$C_RESET" "$L_STEP_COPYKEY" "$G" "$keys_disp" "$C_RESET"
        else
            printf '  %b%d.%b %s\n     %b$ ssh-keygen -t rsa -f %s/id_rsa%b\n' \
                "$YEL" "$n" "$C_RESET" "$L_STEP_KEYGEN" "$G" "$keys_disp" "$C_RESET"
        fi
        n=$((n+1))
    fi

    printf '  %b%d.%b %s\n     %bhttps://npad.ufrn.br/npad/primeirospassos%b\n' \
        "$YEL" "$n" "$C_RESET" "$L_STEP_REGISTER" "$CYA" "$C_RESET"
    n=$((n+1))
    # Um `sed` em vez de sugerir editor: o terminal do Colab nao tem nano, e
    # apontar o painel Arquivos so' serviria la'.
    printf '  %b%d.%b %s\n     %b$ sed -i '"'"'s/seu_usuario_aqui/SEU_LOGIN/'"'"' %s%b\n' \
        "$YEL" "$n" "$C_RESET" "$L_STEP_CONFIG" "$G" "$cfg" "$C_RESET"
    n=$((n+1))
    printf '  %b%d.%b %s\n     %b$ bash bin/fishell.sh%b\n\n' \
        "$YEL" "$n" "$C_RESET" "$L_STEP_RERUN" "$G" "$C_RESET"
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
    stty sane 2>/dev/null || true
    local err
    if err=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_ALIAS" true 2>&1); then
        log_ok "$L_TUNNEL_OK $NPAD_USER@$NPAD_HOST"
        return 0
    fi

    # Mostrar o erro cru do ssh e traduzi-lo: "confira usuario, chave e rede"
    # nao diz qual dos tres, e o aluno fica sem saber por onde comecar.
    log_err "$L_HANDSHAKE_FAIL"
    [[ -n "$err" ]] && printf '%b  %s%b\n' "$G_DIM" "$err" "$C_RESET"
    local hint=""
    case "$err" in
        *"Permission denied"*)              hint="$L_HINT_KEY" ;;
        *"Host key verification failed"*)   hint="$L_HINT_HOSTKEY" ;;
        *"Could not resolve"*)              hint="$L_HINT_DNS" ;;
        *"timed out"*|*"Connection refused"*|*"No route to host"*) hint="$L_HINT_NET" ;;
    esac
    [[ -n "$hint" ]] && log_info "$hint"
    return 1
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

# A publica cadastrada no NPAD tem que estar integra: uma linha, prefixo
# ssh-rsa, e aceita pelo proprio ssh-keygen.
validate_pubkey() {
    local pub="$1"
    [[ -s "$pub" ]] || return 1
    [[ "$(wc -l < "$pub")" -eq 1 ]] || return 1
    grep -q '^ssh-rsa [A-Za-z0-9+/]\{100,\}=* ' "$pub" || return 1
    ssh-keygen -lf "$pub" >/dev/null 2>&1 || return 1
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
    # Dizer so' ONDE procura nao ajuda: o que trava o aluno e' nao saber se os
    # arquivos estao la'. Mostra o inventario da pasta.
    local f mark inv=""
    for f in id_rsa id_rsa.pub known_hosts; do
        if [[ -f "$SSH_KEYS_DIR/$f" ]]; then
            mark="$(printf '%b✓%b' "$G_BRIGHT" "$C_RESET")"
        else
            mark="$(printf '%b✗%b' "$RED" "$C_RESET")"
        fi
        inv+="$mark $f   "
    done
    printf '  %s%s\n' "$(pad 10 "")" "$inv"
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
  ${G}status${C_RESET}     show current configuration
  ${G}help${C_RESET}       display this panel

${G_BRIGHT}CONTROL PANEL${C_RESET}
  ${G}1${C_RESET} shell    ${G}2${C_RESET} test     ${G}3${C_RESET} upload   ${G}4${C_RESET} download
  ${G}5${C_RESET} run      ${G}6${C_RESET} setup    ${G}7${C_RESET} status
  ${G}l${C_RESET} language                          ${G}0${C_RESET}/${G}q${C_RESET} exit

${G_BRIGHT}ENV${C_RESET}
  ${GRAY}FISHELL_LANG=pt|en${C_RESET}  interface language (default: pt)
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
  ${G}status${C_RESET}     mostra a configuração atual
  ${G}help${C_RESET}       mostra esta ajuda

${G_BRIGHT}PAINEL${C_RESET}
  ${G}1${C_RESET} shell    ${G}2${C_RESET} testar   ${G}3${C_RESET} enviar   ${G}4${C_RESET} baixar
  ${G}5${C_RESET} comando  ${G}6${C_RESET} setup    ${G}7${C_RESET} config
  ${G}l${C_RESET} idioma                            ${G}0${C_RESET}/${G}q${C_RESET} sair

${G_BRIGHT}AMBIENTE${C_RESET}
  ${GRAY}FISHELL_LANG=pt|en${C_RESET}  idioma da interface (padrão: pt)
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

# Sem TTY (pipe, célula de notebook, CI) o `clear` só vazaria escape na saída,
# e o banner já foi impresso uma vez pelo main, então nada de redesenhar.
redraw() {
    [[ -t 1 ]] || return 0
    clear 2>/dev/null || true
    print_logo
}

menu() {
    local flash=""
    while true; do
        redraw
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
        _row "$CYA" "[l]" "$L_ML_T" "( $FISHELL_LANG )"
        _row "$RED" "[0]" "$L_M0_T" "$L_M0_H"
        printf '%b╚══════════════════════════════════════════════════╝%b\n' "$G" "$C_RESET"
        local opt
        # Prompt pede a opção em vez de imitar um shell: um "fishell@npad:~#"
        # dá a impressão de que dá pra digitar comando ali.
        printf '\n  %b>%b %b%s%b %b[1-7, l, 0]%b : ' \
            "$G" "$C_RESET" "$G_BRIGHT" "$L_PROMPT" "$C_RESET" "$G_DIM" "$C_RESET"
        menu_prompt_read opt
        redraw
        case "$opt" in
            1|01) action_login ;;
            2|02) test_connection;  pause_return ;;
            3|03) action_upload;    pause_return ;;
            4|04) action_download;  pause_return ;;
            5|05) action_run_remote; pause_return ;;
            6|06) setup_ssh;        pause_return ;;
            7|07) show_status;      pause_return ;;
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
            print_logo
            show_help
            return 0 ;;
    esac

    print_logo
    load_config

    case "${1:-menu}" in
        setup)    setup_ssh ;;
        login)    action_login ;;
        test)     test_connection ;;
        upload)   action_upload ;;
        download) action_download ;;
        run)      shift; action_run_remote "$@" ;;
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
