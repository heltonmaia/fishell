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
FISHELL_VERSION="2.7"

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

# ─── Estado do terminal ───────────────────────────────────────
# `read -rsn1` deixa o tty em modo nao-canonico e precisa ser desfeito, senao
# o output de subprocesso sai corrompido. Mas `stty sane` DESCARTA a
# configuracao do terminal e impoe erase=^?; em terminais que mandam ^H no
# backspace (o do Colab, por exemplo) o usuario fica sem conseguir apagar.
# Guardar e restaurar o estado real resolve os dois lados.
TTY_STATE=""
[[ -t 0 ]] && TTY_STATE="$(stty -g 2>/dev/null || true)"

tty_restore() {
    [[ -t 0 ]] || return 0
    if [[ -n "$TTY_STATE" ]]; then
        stty "$TTY_STATE" 2>/dev/null || stty sane 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi
}

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
        L_PROMPT_KEYS="arrows + enter, or the key"
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
        L_HINT_NOKEY="the key is not installed in ~/.ssh. Run: ./bin/fishell.sh setup"
        L_HINT_HOSTKEY="missing known_hosts, or the server key changed. Veja o README"
        L_HINT_NET="no route to the server: firewall, or port 4422 blocked"
        L_HINT_DNS="could not resolve the host, check your connection"
        L_OPEN_SHELL="opening secure shell to"; L_EXIT_HINT="(type 'exit' to return to the control panel)"
        L_UPLOAD_STEP="upload // from your computer to npad"
        L_DOWNLOAD_STEP="download // from npad to your computer"
        L_UPLOAD_EX="e.g.  ./my_project  ->  ~/"
        L_PICK_PATH="folder:"; L_PICK_UP="(up one level)"
        L_PICK_EMPTY="(empty folder)"
        L_PICK_HELP="arrows move | enter open/choose | e use this folder | t type it | q cancel"
        L_PICK_SRC="choose what to send"; L_PICK_DST="choose where to save"
        L_DOWNLOAD_EX="e.g.  ~/result.h5  ->  ."
        L_FROM_HERE="from (here)"; L_TO_NPAD="to (npad)"
        L_FROM_NPAD="from (npad)"; L_TO_HERE="to (here)"
        # so' o ps1 usa: no bash o chmod nao falha
        L_ACL_WARN="could not tighten the key permission; ssh may still warn"
        L_SRC_MISSING="does not exist"; L_TRANSFERRING="transferring..."
        L_TRANSFER_OK="transfer complete"; L_TRANSFER_FAIL="transfer failed"
        L_REMOTE_EXEC="remote exec //"; L_CMD="cmd"; L_EMPTY_CMD="empty command, aborted."
        L_STDOUT_BEGIN="─── remote stdout ───"; L_STDOUT_END="─── end ─────────────"
        L_FIRSTRUN="first run, follow the steps:"
        L_STEP_REGISTER="register your public key (your login comes by e-mail)"
        L_ASK_LOGIN="your NPAD login"
        L_LOGIN_SAVED="login saved in"
        L_LOGIN_BAD="invalid login. letters, digits, dot, hyphen or _ only"
        L_STEP_RERUN="run again"
        L_KEY_FOUND="your public key:"
        L_KEY_INVALID="this public key does not look valid, do NOT register it"
        L_KEY_FILE="file:"
        L_STEP_KEYGEN="create your ssh key"
        L_STEP_COPYKEY="copy the key you already have into this folder"
        L_PRIV_INPLACE="using the key already in ~/.ssh, nothing to copy"
        L_STATUS_STEP="system readout"
        L_ST_USER="USER"; L_ST_HOST="HOST"; L_ST_PORT="PORT"
        L_ST_ALIAS="ALIAS"; L_ST_KEYS="KEYS_DIR"; L_ST_VERSION="VERSION"
        L_ST_OPTIONAL="optional: saves confirming the fingerprint each session"
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
        L_PROMPT_KEYS="setas + enter, ou a tecla"
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
        L_HINT_NOKEY="a chave não está instalada no ~/.ssh. Rode: ./bin/fishell.sh setup"
        L_HINT_HOSTKEY="falta o known_hosts, ou a chave do servidor mudou. Veja o README"
        L_HINT_NET="sem rota até o servidor: firewall, ou porta 4422 bloqueada"
        L_HINT_DNS="não consegui resolver o host, confira sua conexão"
        L_OPEN_SHELL="abrindo shell em"; L_EXIT_HINT="(digite 'exit' para voltar ao painel)"
        L_UPLOAD_STEP="envio // do seu computador para o npad"
        L_DOWNLOAD_STEP="download // do npad para o seu computador"
        L_UPLOAD_EX="ex.  ./meu_projeto  ->  ~/"
        L_PICK_PATH="pasta:"; L_PICK_UP="(subir um nível)"
        L_PICK_EMPTY="(pasta vazia)"
        L_PICK_HELP="setas movem | enter abre/escolhe | e usar esta pasta | t digitar | q cancelar"
        L_PICK_SRC="escolha o que enviar"; L_PICK_DST="escolha onde salvar"
        L_DOWNLOAD_EX="ex.  ~/resultado.h5  ->  ."
        L_FROM_HERE="de   (aqui)"; L_TO_NPAD="para (npad)"
        L_FROM_NPAD="de   (npad)"; L_TO_HERE="para (aqui)"
        L_ACL_WARN="não consegui restringir a permissão da chave; o ssh pode reclamar"
        L_SRC_MISSING="não existe"; L_TRANSFERRING="transferindo..."
        L_TRANSFER_OK="transferência concluída"; L_TRANSFER_FAIL="a transferência falhou"
        L_REMOTE_EXEC="comando remoto //"; L_CMD="comando"; L_EMPTY_CMD="comando vazio, cancelado."
        L_STDOUT_BEGIN="─── saída remota ────"; L_STDOUT_END="─── fim ─────────────"
        L_FIRSTRUN="primeira execução, siga os passos:"
        L_STEP_REGISTER="cadastre a chave pública (o login chega por e-mail)"
        L_ASK_LOGIN="seu login do NPAD"
        L_LOGIN_SAVED="login salvo em"
        L_LOGIN_BAD="login inválido. use só letras, números, ponto, hífen ou _"
        L_STEP_RERUN="rode de novo"
        L_KEY_FOUND="sua chave pública:"
        L_KEY_INVALID="esta chave pública não parece válida, NÃO cadastre ela"
        L_KEY_FILE="arquivo:"
        L_STEP_KEYGEN="gere sua chave ssh"
        L_STEP_COPYKEY="copie para cá a chave que você já tem"
        L_PRIV_INPLACE="usando a chave que já está em ~/.ssh, nada a copiar"
        L_STATUS_STEP="configuração atual"
        L_ST_USER="USUÁRIO"; L_ST_HOST="HOST"; L_ST_PORT="PORTA"
        L_ST_ALIAS="ALIAS"; L_ST_KEYS="CHAVES"; L_ST_VERSION="VERSÃO"
        L_ST_OPTIONAL="opcional: evita reconfirmar a fingerprint a cada sessão"
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

# Lê uma tecla do menu e devolve: up, down, enter, quit ou o caractere.
# Sem TTY, lê uma linha e devolve '0' no EOF, para pipe/CI não entrarem em loop.
menu_prompt_read() {
    local _var="$1"
    if [[ ! -t 0 || ! -t 1 ]]; then
        # shellcheck disable=SC2229  # atribuição indireta é intencional aqui
        read -r "$_var" || printf -v "$_var" '0'
        return
    fi
    local key="" rest=""
    if ! IFS= read -rsn1 key; then
        printf -v "$_var" 'quit'
    elif [[ "$key" == $'\e' ]]; then
        # Seta chega como ESC [ A/B. O timeout separa isso de um ESC solto.
        IFS= read -rsn2 -t 0.05 rest
        case "$rest" in
            '[A') printf -v "$_var" 'up' ;;
            '[B') printf -v "$_var" 'down' ;;
            *)    printf -v "$_var" '' ;;
        esac
    elif [[ -z "$key" ]]; then
        printf -v "$_var" 'enter'
    else
        printf -v "$_var" '%s' "$key"
        printf '%s\n' "$key"
    fi
    # read -rsn deixa o tty em modo não-canônico; sem isto o output de
    # subprocesso sai com o primeiro caractere de algumas linhas corrompido.
    tty_restore
}

# ─── Carrega configuração ─────────────────────────────────────
load_config() {
    local cfg="$REPO_ROOT/config.sh"
    local example="$REPO_ROOT/config/config.sh.example"
    NPAD_USER_SET=1

    if [[ ! -f "$cfg" ]]; then
        log_warn "$L_CFG_NOTFOUND $cfg"
        if [[ ! -f "$example" ]]; then
            log_err "$L_CFG_NOTEMPLATE"
            exit 1
        fi
        log_info "$L_CFG_COPY"
        cp "$example" "$cfg"
        # Segue o fluxo normal a partir daqui: sourceia o que acabou de ser
        # copiado e cai no mesmo roteiro da 2a execucao. Sem isso os dois
        # casos mostravam passos diferentes.
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

    # O roteiro pergunta o login e grava sozinho quando da'; so' sai quando
    # nao tem como perguntar (sem tty) ou quando o usuario nao respondeu.
    if [[ "$NPAD_USER_SET" == "0" ]]; then
        show_onboarding "$cfg" || exit 1
    fi

    resolve_keys_dir
}

resolve_keys_dir() {
    [[ -n "${SSH_KEYS_DIR:-}" ]] && return
    if [[ -d "/content/drive/MyDrive/visaocomputacional/.ssh" ]]; then
        SSH_KEYS_DIR="/content/drive/MyDrive/visaocomputacional/.ssh"
    elif [[ -f "$REPO_ROOT/.ssh/id_rsa" ]]; then
        SSH_KEYS_DIR="$REPO_ROOT/.ssh"
    elif [[ -f "$HOME/.ssh/id_rsa" ]]; then
        # Ja' existe chave onde o ssh procura por padrao: usa ela em vez de
        # pedir uma copia. So' falta escrever o alias.
        SSH_KEYS_DIR="$HOME/.ssh"
    else
        SSH_KEYS_DIR="$REPO_ROOT/.ssh"
    fi
}

# Roteiro de primeira execucao. Substitui o antigo "edite config.sh e defina
# NPAD_USER", que era um beco sem saida: nesse ponto o usuario ainda nao TEM
# um login do NPAD, ele so' existe depois de cadastrar a chave publica.
show_onboarding() {
    local cfg_path="$1" cfg="$1" have_key=0
    # Na raiz do repo mostra so' "config.sh": o caminho absoluto do Colab e'
    # enorme e nao cabe na linha.
    [[ "$PWD" == "$REPO_ROOT" ]] && cfg="config.sh"
    resolve_keys_dir
    local pub="$SSH_KEYS_DIR/id_rsa.pub"
    local n=1

    printf '\n%b  %s%b\n\n' "$G_BRIGHT$C_BOLD" "$L_FIRSTRUN" "$C_RESET"

    if [[ -f "$pub" ]]; then
        # Ja' tem chave: mostra a publica pra copiar, conferindo a integridade
        # antes, ela vai colada num formulario oficial do NPAD.
        if validate_pubkey "$pub"; then
            have_key=1
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
        # O mkdir so' entra quando a pasta nao existe: a .ssh do repo ja' vem
        # no clone, e sugerir criar o que ja' esta' la' e' ruido.
        local mk=""
        [[ -d "$SSH_KEYS_DIR" ]] || mk="mkdir -p $keys_disp && "
        if [[ -f "$HOME/.ssh/id_rsa" ]]; then
            # Ja' tem chave no ~/.ssh: copiar e' melhor que gerar outra, que
            # precisaria de um cadastro novo no NPAD.
            printf '  %b%d.%b %s\n     %b$ %scp ~/.ssh/id_rsa ~/.ssh/id_rsa.pub %s/%b\n' \
                "$YEL" "$n" "$C_RESET" "$L_STEP_COPYKEY" \
                "$G" "$mk" "$keys_disp" "$C_RESET"
        else
            printf '  %b%d.%b %s\n     %b$ %sssh-keygen -t rsa -f %s/id_rsa%b\n' \
                "$YEL" "$n" "$C_RESET" "$L_STEP_KEYGEN" \
                "$G" "$mk" "$keys_disp" "$C_RESET"
        fi
        n=$((n+1))
    fi

    printf '  %b%d.%b %s\n     %bhttps://npad.ufrn.br/npad/primeirospassos%b\n' \
        "$YEL" "$n" "$C_RESET" "$L_STEP_REGISTER" "$CYA" "$C_RESET"
    n=$((n+1))

    # Aqui havia um passo "edite o config.sh", com um `sed` pronto para
    # copiar. Confundia: o aluno acabava de colar a chave num formulario e
    # levava um comando de edicao de arquivo pela frente. Agora o proprio
    # fishell pergunta o login e grava. So' pergunta quando ja' existe chave
    # (sem chave nao ha' cadastro, logo nao ha' login) e quando ha' terminal.
    if (( have_key )) && [[ -t 0 ]]; then
        local ans=""
        printf '\n'
        read_local_path ans "$L_ASK_LOGIN"
        # So' apara as pontas: apagar todo espaco transformaria "nome errado"
        # num login plausivel e gravaria a besteira sem avisar.
        ans="${ans#"${ans%%[![:space:]]*}"}"
        ans="${ans%"${ans##*[![:space:]]}"}"
        if [[ -n "$ans" ]]; then
            if [[ "$ans" =~ ^[A-Za-z0-9._-]+$ ]]; then
                if write_npad_user "$cfg_path" "$ans"; then
                    NPAD_USER="$ans"
                    NPAD_USER_SET=1
                    printf '\n'
                    log_ok "$L_LOGIN_SAVED $cfg"
                    printf '\n'
                    return 0
                fi
            else
                printf '\n'
                log_err "$L_LOGIN_BAD"
            fi
        fi
        printf '\n'
    fi

    printf '  %b%d.%b %s\n     %b$ bash bin/fishell.sh%b\n\n' \
        "$YEL" "$n" "$C_RESET" "$L_STEP_RERUN" "$G" "$C_RESET"
    return 1
}

# Reescreve so' a linha do NPAD_USER, preservando comentarios e o resto da
# config. `cat >` em vez de `sed -i` de proposito: o sed troca o inode, e no
# Drive montado por FUSE isso as vezes falha.
write_npad_user() {
    local cfg="$1" user="$2" tmp
    tmp="$(mktemp)" || return 1
    if grep -q '^[[:space:]]*NPAD_USER=' "$cfg"; then
        awk -v u="$user" '
            !feito && /^[[:space:]]*NPAD_USER=/ { print "NPAD_USER=\"" u "\""; feito=1; next }
            { print }
        ' "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        { cat "$cfg"; printf 'NPAD_USER="%s"\n' "$user"; } > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    cat "$tmp" > "$cfg" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
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

    # Com SSH_KEYS_DIR == ~/.ssh a origem e o destino sao o mesmo arquivo, e
    # o install falharia. Nesse caso nao ha' o que copiar.
    if [[ "$priv" -ef "$home_ssh/id_rsa" ]]; then
        log_ok "$L_PRIV_INPLACE"
    else
        install -m 600 "$priv" "$home_ssh/id_rsa"
        log_ok "$L_PRIV_OK"
    fi

    if [[ -f "$SSH_KEYS_DIR/id_rsa.pub" ]] \
       && ! [[ "$SSH_KEYS_DIR/id_rsa.pub" -ef "$home_ssh/id_rsa.pub" ]]; then
        install -m 644 "$SSH_KEYS_DIR/id_rsa.pub" "$home_ssh/id_rsa.pub"
        log_ok "$L_PUB_OK"
    fi

    for kh in "$SSH_KEYS_DIR/known_hosts" "$SSH_KEYS_DIR/known_hosts.txt"; do
        if [[ -f "$kh" ]]; then
            [[ "$kh" -ef "$home_ssh/known_hosts" ]] && break
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
    tty_restore
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
    # "no such identity" antes de "Permission denied": o erro traz os dois, e
    # o primeiro e' a causa. Dizer "chave nao cadastrada" aqui manda o usuario
    # depurar o lado errado.
    case "$err" in
        *"no such identity"*)               hint="$L_HINT_NOKEY" ;;
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

# Navegador de arquivos LOCAL. Redesenha no lugar; setas movem, enter abre a
# pasta ou escolhe o arquivo, "e" aceita a pasta atual, "t" cai no modo de
# digitar e "q" cancela. So' vale pro lado local: navegar no NPAD exigiria um
# `ssh ls` por tecla.
#   $1 nome da variavel de saida   $2 titulo   $3 pasta inicial
pick_local_path() {
    local _var="$1" titulo="$2" cur
    cur="$(cd "${3:-$PWD}" 2>/dev/null && pwd)" || cur="$PWD"
    local idx=0 top=0 rows
    rows=$(( $(tput lines 2>/dev/null || echo 24) - 10 ))
    (( rows < 5 )) && rows=5

    while true; do
        local -a dirs=() files=() items=()
        local e
        shopt -s nullglob dotglob
        for e in "$cur"/*; do
            if [[ -d "$e" ]]; then dirs+=("$(basename "$e")/"); else files+=("$(basename "$e")"); fi
        done
        shopt -u nullglob dotglob
        items=(".." "${dirs[@]}" "${files[@]}")
        local total=${#items[@]}
        (( idx >= total )) && idx=$(( total - 1 ))
        (( idx < 0 )) && idx=0
        (( idx < top )) && top=$idx
        (( idx >= top + rows )) && top=$(( idx - rows + 1 ))

        [[ -t 1 ]] && { clear 2>/dev/null || true; }
        printf '\n  %b%s%b\n' "$G_BRIGHT$C_BOLD" "$titulo" "$C_RESET"
        printf '  %b%s%b %s\n\n' "$G_DIM" "$L_PICK_PATH" "$C_RESET" "$cur"
        if (( total == 1 )); then
            printf '  %b%s%b\n' "$G_DIM" "$L_PICK_EMPTY" "$C_RESET"
        fi
        local i nome cor mark
        for (( i = top; i < total && i < top + rows; i++ )); do
            nome="${items[i]}"
            if [[ "$nome" == ".." ]]; then
                nome=".. $L_PICK_UP"; cor="$CYA"
            elif [[ "$nome" == */ ]]; then cor="$CYA"; else cor="$C_RESET"; fi
            if (( i == idx )); then mark="$(printf '%b>%b' "$G_BRIGHT$C_BOLD" "$C_RESET")"; else mark=" "; fi
            printf '  %s %b%s%b\n' "$mark" "$cor" "$nome" "$C_RESET"
        done
        (( total > top + rows )) && printf '  %b...%b\n' "$G_DIM" "$C_RESET"
        printf '\n  %b%s%b\n' "$G_DIM" "$L_PICK_HELP" "$C_RESET"

        local k
        menu_prompt_read k
        case "$k" in
            up)    (( idx > 0 )) && idx=$(( idx - 1 )) ;;
            down)  (( idx < total - 1 )) && idx=$(( idx + 1 )) ;;
            enter)
                local sel="${items[idx]}"
                if [[ "$sel" == ".." ]]; then
                    cur="$(dirname "$cur")"; idx=0; top=0
                elif [[ "$sel" == */ ]]; then
                    cur="$cur/${sel%/}"; idx=0; top=0
                else
                    printf -v "$_var" '%s' "$cur/$sel"; return 0
                fi ;;
            e|E)   printf -v "$_var" '%s' "$cur"; return 0 ;;
            t|T)   printf -v "$_var" ''; return 2 ;;
            q|Q|quit) printf -v "$_var" ''; return 1 ;;
        esac
    done
}

# Lê um caminho LOCAL com completar de arquivo (Tab), via readline.
# Os \001/\002 marcam as sequências não imprimíveis para o readline calcular
# a largura do prompt; sem eles a linha se embaralha ao completar ou editar.
# Só serve para o lado local: completar caminho daqui num destino remoto
# induziria ao erro.
read_local_path() {
    local _var="$1" label="$2" default="${3:-}" p
    if [[ ! -t 0 ]]; then
        # shellcheck disable=SC2229  # atribuição indireta é intencional aqui
        read -r "$_var"
        return
    fi
    p=$(printf '  \001%s\002>\001%s\002 %s%s : ' \
        "$G" "$C_RESET" "$label" "${default:+ [$default]}")
    # shellcheck disable=SC2229
    read -e -r -p "$p" "$_var"
}

action_upload() {
    log_step "$L_UPLOAD_STEP"
    printf '  %b%s%b\n' "$G_DIM" "$L_UPLOAD_EX" "$C_RESET"
    local src dst
    # Rotulos dizem o papel (de/para) E o lado (aqui/npad): so' "caminho
    # local" e "caminho remoto" obriga o aluno a deduzir a direcao, e ela
    # inverte entre enviar e baixar.
    if [[ -t 0 && -t 1 ]]; then
        pick_local_path src "$L_PICK_SRC" "$PWD"
        case $? in
            1) return 0 ;;                                  # cancelou
            2) read_local_path src "$L_FROM_HERE" ;;         # pediu pra digitar
            *) printf '  %b>%b %s : %s\n' "$G" "$C_RESET" "$L_FROM_HERE" "$src" ;;
        esac
    else
        read_local_path src "$L_FROM_HERE"
    fi
    printf '  %b>%b %s [~/] : ' "$G" "$C_RESET" "$L_TO_NPAD"
    read -r dst
    [[ -z "$dst" ]] && dst="~/"
    if [[ ! -e "$src" ]]; then
        log_err "'$src' $L_SRC_MISSING"
        return 1
    fi
    tty_restore
    log_work "$L_TRANSFERRING"
    scp -P "$NPAD_PORT" -r "$src" "${SSH_ALIAS}:${dst}" \
        && log_ok "$L_TRANSFER_OK" || log_err "$L_TRANSFER_FAIL"
}

action_download() {
    log_step "$L_DOWNLOAD_STEP"
    printf '  %b%s%b\n' "$G_DIM" "$L_DOWNLOAD_EX" "$C_RESET"
    local src dst
    printf '  %b>%b %s : ' "$G" "$C_RESET" "$L_FROM_NPAD"
    read -r src
    if [[ -t 0 && -t 1 ]]; then
        pick_local_path dst "$L_PICK_DST" "$PWD"
        case $? in
            1) return 0 ;;
            2) read_local_path dst "$L_TO_HERE" "./" ;;
            *) printf '  %b>%b %s : %s\n' "$G" "$C_RESET" "$L_TO_HERE" "$dst" ;;
        esac
    else
        read_local_path dst "$L_TO_HERE" "./"
    fi

    [[ -z "$dst" ]] && dst="./"
    tty_restore
    log_work "$L_TRANSFERRING"
    scp -P "$NPAD_PORT" -r "${SSH_ALIAS}:${src}" "$dst" \
        && log_ok "$L_TRANSFER_OK" || log_err "$L_TRANSFER_FAIL"
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
    tty_restore
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
    # O known_hosts e' o unico opcional dos tres: sem ele o ssh so' pergunta a
    # fingerprint uma vez. Marcar com o mesmo ✗ vermelho dos outros faria
    # parecer que falta algo essencial.
    local f mark inv="" falta_kh=""
    for f in id_rsa id_rsa.pub known_hosts; do
        if [[ -f "$SSH_KEYS_DIR/$f" ]]; then
            mark="$(printf '%b✓%b' "$G_BRIGHT" "$C_RESET")"
        elif [[ "$f" == "known_hosts" ]]; then
            mark="$(printf '%b·%b' "$G_DIM" "$C_RESET")"; falta_kh=1
        else
            mark="$(printf '%b✗%b' "$RED" "$C_RESET")"
        fi
        inv+="$mark $f   "
    done
    printf '  %s%s\n' "$(pad 10 "")" "$inv"
    [[ -n "$falta_kh" ]] && printf '  %s%b%s%b\n' "$(pad 10 "")" "$G_DIM" "$L_ST_OPTIONAL" "$C_RESET"
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
    local flash="" sel=1
    # indice da linha destacada -> tecla equivalente
    local opts=(1 2 3 4 5 6 7 l 0)
    while true; do
        redraw
        menu_header
        if [[ -n "$flash" ]]; then
            printf '%s\n\n' "$flash"
            flash=""
        fi
        # Linha do painel: 50 chars entre as barras. Layout:
        #   "  [X]  <title:20> <hint:16>      " = 2+3+2+20+1+16+6 = 50
        # A linha selecionada troca os 2 espaços da esquerda por "> ", em vez
        # de acrescentar caracteres: as 50 colunas continuam valendo, e o
        # destaque aparece mesmo com NO_COLOR.
        _row() {
            local kc="$1" k="$2" title="$3" hint="$4" mark="  " tc="$G_BRIGHT"
            if [[ "$5" == "sel" ]]; then mark="$(printf '%b> %b' "$G_BRIGHT$C_BOLD" "$C_RESET")"; tc="$G_BRIGHT$C_BOLD"; fi
            printf '%b║%b%s%b%s%b  %b%s%b %b%s%b      %b║%b\n' \
                "$G" "$C_RESET" "$mark" \
                "$kc" "$k" "$C_RESET" \
                "$tc" "$(pad 20 "$title")" "$C_RESET" \
                "$CYA" "$(pad 16 "$hint")" "$C_RESET" \
                "$G" "$C_RESET"
        }
        _sel() { [[ "$sel" == "$1" ]] && printf 'sel'; }
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
        _row "$YEL" "[1]" "$L_M1_T" "$L_M1_H"            "$(_sel 1)"
        _row "$YEL" "[2]" "$L_M2_T" "$L_M2_H"            "$(_sel 2)"
        _row "$YEL" "[3]" "$L_M3_T" "$L_M3_H"            "$(_sel 3)"
        _row "$YEL" "[4]" "$L_M4_T" "$L_M4_H"            "$(_sel 4)"
        _row "$YEL" "[5]" "$L_M5_T" "$L_M5_H"            "$(_sel 5)"
        _row "$YEL" "[6]" "$L_M6_T" "$L_M6_H"            "$(_sel 6)"
        _row "$YEL" "[7]" "$L_M7_T" "$L_M7_H"            "$(_sel 7)"
        _row "$CYA" "[l]" "$L_ML_T" "( $FISHELL_LANG )"  "$(_sel 8)"
        _row "$RED" "[0]" "$L_M0_T" "$L_M0_H"            "$(_sel 9)"
        printf '%b╚══════════════════════════════════════════════════╝%b\n' "$G" "$C_RESET"
        local opt
        # Prompt pede a opção em vez de imitar um shell: um "fishell@npad:~#"
        # dá a impressão de que dá pra digitar comando ali.
        printf '\n  %b>%b %b%s%b %b(%s)%b : ' \
            "$G" "$C_RESET" "$G_BRIGHT" "$L_PROMPT" "$C_RESET" \
            "$G_DIM" "$L_PROMPT_KEYS" "$C_RESET"
        menu_prompt_read opt
        case "$opt" in
            up)   sel=$(( sel > 1 ? sel - 1 : ${#opts[@]} )); continue ;;
            down) sel=$(( sel < ${#opts[@]} ? sel + 1 : 1 ));  continue ;;
            enter) opt="${opts[$((sel-1))]}" ;;
            quit)  opt=0 ;;
        esac
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
