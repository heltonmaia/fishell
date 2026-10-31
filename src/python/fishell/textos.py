"""Todo texto de interface (pt-BR) fica aqui."""

DESCRICAO = "Concentrador de jobs para o cluster NPAD/UFRN"

# --- hub ---
HUB_PROJETO_DESCONHECIDO = "projeto desconhecido: {projeto}"
HUB_DESTINO_DESCONHECIDO = "destino desconhecido: {destino}"
HUB_SEM_CAPACIDADE = "o destino {destino} não oferece a ação: {acao}"
HUB_INDISPONIVEL_ATE = "indisponível até {hora}"
HUB_SEM_ACESSO = "sem acesso: chave não aceita ou ssh-agent ausente"
HUB_ERRO_CONSULTA = "erro ao consultar: {erro}"

# --- vigia ---
VIGIA_TERMINOU = "{nome} terminou: {estado}"
VIGIA_TITULO = "fishell"
VIGIA_PAROU = "vigia parou: sem acesso ao {destino}"
AJUDA_VIGIA = "avisa quando os jobs terminam (uso interno)"

# --- tela de jobs ---
TUI_TITULO = "fishell  jobs"
TUI_TODOS = "todos"
TUI_DESTINOS = "DESTINOS"
TUI_COLUNAS = ("DESTINO", "PROJETO", "JOB", "ESTADO", "TEMPO", "LOG")
TUI_LOG_TITULO = "log ao vivo · {destino}:{job}"
TUI_LOG_SEM_JOB = "log ao vivo"
TUI_LOG_CHEIO = "log · {destino}:{job} · esc volta"
TUI_ERRO = "erro: {erro}"
TUI_ERRO_LOG = "não foi possível ler o log: {erro}"
TUI_TECLA_ALTERNAR = "destinos/jobs"
TUI_TECLA_LOG = "log cheio"
TUI_TECLA_SAIR = "sair"
TUI_TECLA_VOLTAR = "voltar"
TUI_ESTADO_RODANDO = "● rodando"
TUI_ESTADO_ARRAY = "● {ok}/{total} ok"
TUI_ESTADO_FILA = "◌ fila"
TUI_ESTADO_OK = "✓ ok"
TUI_ESTADO_FALHOU = "✗ falhou"
TUI_ESTADO_CANCELADO = "⊘ cancelado"
TUI_ESTADO_DESCONHECIDO = "? desconhecido"
AJUDA_MENU = "abre a tela de jobs (padrão)"
