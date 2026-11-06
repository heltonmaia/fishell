# Desenvolvimento

Notas para quem for mexer no código. Para **usar** o fishell, veja o
[README](../README.md), que vai do acesso ao NPAD na mão (parte 1) até o uso
do Slurm (parte 6).

Duas decisões do texto que é fácil desfazer sem querer: o README **começa pelo
`ssh` cru**, sem o fishell, porque isso separa "meu acesso está ok?" de "a
ferramenta está configurada?", as duas metades ficaram indistinguíveis no uso
real e custaram horas. E ele **não menciona o notebook do Colab** (células,
`%cd`, painel Arquivos): tudo é feito pelo terminal, para as instruções valerem
igual em Colab, Linux e WSL.

## Estrutura

```
bin/     entrypoints (wrappers finos, é por aqui que o usuário roda)
  fishell.sh     Linux / macOS / WSL / Colab
  fishell.cmd    Windows
src/     os dois ports de verdade
  bash/fishell.sh
  powershell/fishell.ps1
config/  os *.example commitados
docs/    screenshots e este arquivo
tools/   make-screenshot.py
```

`config.sh` / `config.ps1` (a config do usuário) e `.ssh/` (as chaves) ficam na
**raiz** do repo, não ao lado do script. Os dois ports resolvem isso subindo
dois níveis a partir do próprio diretório (`REPO_ROOT` no bash, `$RepoRoot` no
ps1), é o que mantém a config do usuário fora do `src/` e no lugar onde o
`.gitignore` a protege. Mexeu na profundidade das pastas? Esses dois cálculos
precisam acompanhar.

## Dois ports escritos à mão

Não há código compartilhado: o programa existe duas vezes, em Bash e em
PowerShell. **Toda mudança de comportamento, texto de UI ou subcomando precisa
entrar nos dois**, incluindo o número de versão. O CI falha se as versões
divergirem, se um subcomando existir só de um lado ou se as tabelas de idioma
saírem de paridade.

## Checks

```bash
bash -n src/bash/fishell.sh bin/fishell.sh          # sintaxe
shellcheck src/bash/fishell.sh bin/fishell.sh       # se disponível

for l in pt en; do
  FISHELL_LANG=$l NO_COLOR=1 ./bin/fishell.sh </dev/null \
    | python3 .github/scripts/check_panel.py        # a caixa tem 50 colunas
done

bash .github/scripts/test_validate_pubkey.sh        # validador da chave pública
python3 .github/scripts/check_i18n.py               # paridade das traduções
python3 .github/scripts/test_onboarding_login.py    # 1ª execução pergunta o login

python3 tools/make-screenshot.py                    # docs/screenshot.png (pt)
python3 tools/make-screenshot.py --lang en -o docs/screenshot-en.png
```

O CI roda tudo isso mais o parser do PowerShell, o PSScriptAnalyzer e o
**runtime do ps1** (`.github/scripts/Test-Runtime.ps1`).

## Armadilhas que já causaram bug

Cada uma tem um check de CI. Não remova sem entender o que ele protege.

**O `fishell.ps1` precisa estar em UTF-8 com BOM.** O Windows PowerShell 5.1 lê
`.ps1` sem BOM como ANSI, o que destrói o banner, as bordas do painel e as
sentinelas do bloco no `~/.ssh/config`, fazendo cada `setup` duplicar o bloco.
Toda ferramenta que reescreva o arquivo precisa preservar o BOM
(`encoding='utf-8-sig'` em Python).

**O painel é medido em colunas, não em bytes.** No bash, `printf '%-20s'`
preenche por byte, e com `LC_ALL=C` até o `${#s}` conta bytes, "conexão"
desalinharia a caixa. Use os helpers `vlen`/`pad`, nunca `%-Ns`, em qualquer
coisa alinhada que possa ter acento. No PowerShell o `.PadRight()` já conta
caracteres.

**Parsear o ps1 não basta.** Parser e PSScriptAnalyzer não pegam erro de
runtime. Dois bugs reais passaram por eles: `$host = ...` (variável automática
read-only, explodia no `keygen`) e `$null -notmatch` num `~/.ssh/config` vazio,
que fazia o `setup` nunca registrar o alias no Windows. Por isso o CI
**executa** o port PowerShell.

**No PowerShell, `continue` dentro de `switch` não volta ao laço.** O `switch`
é ele mesmo um laço sobre a entrada, e `continue` ou `break` sem rótulo agem
nele, não no `while` em volta. Foi assim que cada seta do menu passou a cair
no `default` do segundo `switch` e a aparecer como "opção inválida: up" no
Windows, enquanto no bash, onde `case` não é laço, funcionava. Para controlar o
laço de dentro de um `switch`, rotule-o (`:menu while`, `continue menu`). O
`Test-Runtime.ps1` passa pelo menu com as setas.

**A chave pública vai colada num formulário oficial.** O fishell **não gera**
a chave, isso é um `ssh-keygen -t rsa`, no terminal, como manda a documentação
do NPAD. Mas ele *mostra* a pública para você copiar, e `validate_pubkey` /
`Test-PubKey` conferem a integridade antes de imprimir: uma chave truncada
cadastrada custa dias, porque o cadastro vai, o e-mail chega, e só na hora de
conectar é que falha.

**`clear` só em TTY.** Sem isso o `\033[H\033[2J` vaza cru na saída de pipe ou
de célula de notebook, e o banner sai três vezes.

**O bit de execução não sobrevive ao Drive.** O wrapper de `bin/` chama o
interpretador explicitamente em vez de dar `exec` no script, senão morre com
`Permission denied` num mount FUSE mesmo quando invocado como `bash bin/...`.

## Diferenças entre os ports que são deliberadas

- **Completar caminho com Tab** só existe no bash (`read -e`, do readline). O
  PowerShell precisaria do PSReadLine, que não está garantido num script solto.

## Idioma

`FISHELL_LANG=pt|en`, padrão **pt**. Precedência: tecla `[l]` do menu >
variável de ambiente > `config.sh`/`config.ps1` > `pt`. O ambiente é capturado
*antes* de sourcear a config, justamente para poder vencer depois.

Todas as strings de usuário ficam numa tabela única por idioma: `set_lang()`
atribui `L_*` no bash, `Set-Lang` preenche o hashtable `$L` no ps1, mesmas
chaves, mesma ordem nos dois arquivos. **String nova entra nas quatro tabelas**
(pt/en × bash/ps1), e as do painel respeitam os limites de 20/16 colunas.

## A primeira execução pergunta, não manda editar

Sem `NPAD_USER` preenchido o script mostra a chave pública, o link do cadastro
e **pergunta o login**, gravando-o no `config.sh` (`write_npad_user` no bash,
`Write-NpadUser` no ps1) antes de seguir para o setup. No lugar disso havia um
passo `sed -i 's/seu_usuario_aqui/SEU_LOGIN/' config.sh`, retirado em
2026-09-10: chegava logo depois de o aluno colar a chave num formulário
oficial, e virava um comando de edição de arquivo no meio do caminho.

Três recusas que precisam continuar valendo, todas cobertas por
`test_onboarding_login.py`:

- **sem chave, não pergunta.** O login só existe depois do cadastro, e o
  cadastro exige a chave. Perguntar ali seria um beco sem saída.
- **sem tty, não pergunta.** No CI e em `| pipe` o `read` não tem quem
  responda; o roteiro volta a terminar com "rode de novo".
- **login fora de `[A-Za-z0-9._-]` não entra no arquivo.** A resposta só é
  aparada nas pontas, nunca "limpa": apagar os espaços de "nome errado"
  gravaria um login plausível e errado sem avisar.

## O menu é deliberadamente enxuto

O público são alunos acessando o NPAD pela primeira vez. Foram removidos de
propósito: `forget` (`ssh-keygen -R`), que era um botão de "ignorar aviso de
segurança" para um caso raro; a animação, que poluía a saída no Colab; e
`keygen`, porque gerar chave é um `ssh-keygen` de uma linha e não precisa de
embrulho, o fishell só mostra a pública já existente. Não readicione opção ao painel sem uma
razão de uso real, o custo é cognitivo, não de código.

## Screenshots

`docs/screenshot.png` é gerado da UI real por `tools/make-screenshot.py`, que
roda o fishell numa cópia temporária do repo com `NPAD_USER="usuario"`. **O
repo é público**: o print não pode mostrar um login NPAD real, então não
substitua o arquivo por uma captura da sua sessão.

## Segurança

`.ssh/`, `config.sh`, `config.ps1`, `*.zip`, `*.pem`, `*.key` estão no
`.gitignore`. Revise `git status` antes de qualquer commit e nunca remova essas
regras.

## Migrando de máquina

Depois do `git clone`, copie da máquina antiga o `config.sh` e a pasta `.ssh/`
inteira, os dois são gitignored de propósito. Ajuste as permissões, que o SSH
recusa se estiverem frouxas:

```bash
chmod 700 .ssh
chmod 600 .ssh/id_rsa .ssh/known_hosts
chmod 644 .ssh/id_rsa.pub
chmod +x bin/fishell.sh src/bash/fishell.sh
```

## Versão Python

Terceira implementação, **fora da paridade** com o bash e o PowerShell: só
Linux, com outro escopo (painel de jobs de vários destinos). Os dois ports
acima não mudam por causa dela, e o CI de paridade não a enxerga. O que ela faz
para quem usa está na parte 7 do [README](../README.md).

### Estrutura

```
pyproject.toml, uv.lock   na raiz (entrypoint: fishell = fishell.cli:main)
src/python/fishell/
  core/       modelos, receita, config, estado, hub, montagem
  adapters/   base (interface), conexao, slurm_saidas, slurm, local
  vigia.py    processo de aviso de fim de job
  formato.py  linha de job para texto
  textos.py   todo texto de interface (pt-BR)
  tui/        app.py (telas) e acoes.py (fluxos de enviar, montar, submeter...)
  cli.py      fishell, menu, jobs, vigia
src/python/tests/   pytest; fixtures/ guarda saídas gravadas das ferramentas
```

### Camadas

- **Núcleo** (`core/`): não conhece SSH nem Slurm. `modelos` define `Job`,
  `Receita`, `Recurso`; `receita` lê o `fishell.toml`; `config` lê e
  valida o `destinos.toml` (erro vira `ErroConfig`, uma linha no stderr e
  saída 1); `estado` é o SQLite dos jobs iniciados pelo fishell; `hub` reúne
  os adaptadores, aplica os intervalos de atualização e entrega a visão (jobs
  e avisos por destino); `montagem` liga tudo (`montar_hub`).
- **Hub por destino**: `atualizar_destino(nome, forcar)` consulta um destino
  só e `visao()` devolve o retrato sem consultar; a TUI roda uma thread por
  destino, cada uma com sua trava, e um NPAD lento não segura o `local`.
  `atualizar()` (todos, em sequência) serve ao vigia e ao `fishell jobs`. Num
  erro, o destino mantém a última lista conhecida e os jobs ativos dela saem
  com `motivo = "(desatualizado)"`.
- **Adaptadores** (`adapters/`): um por tipo de destino. `slurm` fala com o NPAD
  por `conexao` (a conexão SSH única); `slurm_saidas` só interpreta o texto de
  `squeue`, `sinfo` e `sacct`; `local` roda jobs em `tmux`.
- **Frentes**: a TUI (`tui/`) e a linha de comando (`cli.py`) chamam o `Hub`,
  nunca um adaptador direto. O vigia (`vigia.py`) é outra frente: não carrega a
  interface.
- **Threads da TUI**: todo trabalho de fundo (atualizações, logs, ações, o
  vigia) passa por `FishellApp._em_fundo`, threads daemon e não workers do
  Textual, que rodam no executor padrão do asyncio e prendem a saída até
  terminar. A tela muda só pela `_na_principal`. Ações do usuário entram com
  `acao=True`: enquanto houver uma, o modal não fecha e `q` pede confirmação.
  Nos testes, `_esperar` espera os workers e `app.em_fundo()`.
- **Vigia**: nasce no submeter e também pelo `Hub.garantir_vigia_se_preciso`
  (painel ao abrir e `fishell jobs`), porque não sobrevive a reboot nem a
  logout. Sai sozinho sem job ativo; com todos os destinos ativos 30 min sem
  resposta, avisa "vigia parou: <destino> sem resposta" e sai 0.

### Interface `Adaptador`

Definida em `adapters/base.py` (`Protocol`): atributos `nome`, `intervalo` (s
entre atualizações) e `capacidades` (subconjunto de `ambiente`, `submeter`,
`cancelar`, `log`, `enviar`, `trazer`), e os métodos `listar_jobs`, `recursos`,
`enviar`, `trazer`, `montar_ambiente`, `submeter`, `cancelar` e `log`. Um
adaptador sinaliza destino bloqueado com `Indisponivel(ate)` e falha de
autenticação com `ErroAutenticacao`; o hub cuida do resto.

**Para acrescentar um destino:** escreva o adaptador em `adapters/`, com um
teste contra saídas gravadas ou falsas (`tests/fakes.py`); registre-o em
`core/montagem.py` conforme o `tipo` do `[[destino]]` e acrescente o tipo ao
`core/config.py`. Nada em `tui/` ou `cli.py` deve mudar.

### Formato da receita

Arquivo `fishell.toml` na raiz do projeto. Topo: `nome` (opcional). Uma tabela
por nome de destino (`[npad]`, `[local]`), com as chaves:

| chave | tipo | sentido |
| --- | --- | --- |
| `remoto` | texto | pasta do projeto no destino (aceita `$USER`) |
| `enviar`, `trazer` | lista | itens de transferência |
| `ambiente` | texto | script que monta o ambiente; relativo a `remoto` no slurm e à raiz do projeto no local |
| `job` | texto | `.sbatch` submetido com `sbatch --parsable` |
| `submeter` | texto | script do projeto que chama o `sbatch` |
| `log` | texto | caminho do log do job (com `job`, opcional: ver abaixo) |
| `comando` | texto | comando do destino `local` (autocontido: sem ambiente ativado) |
| `particao` | texto | partição padrão (só no modo `job`) |

Regras que o `receita.py` impõe: chave desconhecida é erro; `job` e `submeter`
são exclusivos; `submeter` exige `log`. Um item de transferência é
`"origem/ -> destino/"`, um texto sem ` -> ` (mesmo caminho nos dois lados) ou
uma tabela `{de, para, incluir, excluir}`.

**Convenção do `submeter`:** o script roda no remoto e precisa imprimir uma
linha `fishell-job: <id>` com o id do job Slurm. O fishell usa esse id para
acompanhar e cancelar, e o `log` da receita para mostrar a saída. Quem constrói
a lista de entradas, a partição e o tamanho do array fica por conta do script
(a janela de ações não os mostra nesse modo).

**Log no modo `job`:** com `log` na receita, o `sbatch` recebe `-o <log>` (e a
pasta é criada antes). Sem ele, o fishell não passa `-o`: lê o `#SBATCH
-o/--output` (e `-J/--job-name`, `-D/--chdir`, `-a/--array`) do `.sbatch`
local, achado pelo mapa do `enviar` ou no mesmo caminho relativo, e registra
esse caminho, relativo a `remoto` (ou ao `--chdir`), com `%j`/`%A` trocados
pelo id, `%x` pelo nome do job e `%a` mantido para o `tail`. Sem `--output`,
vale o padrão do SLURM: `slurm-%j.out` (array: `slurm-%A_%a.out`) em
`remoto`.

**Scripts do usuário no remoto** (`ambiente`, `submeter`) rodam como
`{ cd <remoto> && bash <script>; } 2>&1; e=$?; [ "$e" -eq 255 ] && e=254;
exit "$e"`: o stderr chega à saída ao vivo, e um 255 do script não é lido
como recusa da conexão (para o `ssh`, 255 é erro dele). No local, o ambiente
roda com `2>&1` também.

**Jobs locais** rodam num servidor tmux só do fishell, `tmux -L fishell -f
/dev/null` (em toda chamada, para o `tmux.conf` do usuário não valer; um
`destroy-unattached` mataria o job ao nascer). Para entrar: `tmux -L fishell
attach -t fishell-<id>`. O `listar_jobs` lê o registro antes das sessões e o
`cancelar` grava CANCELADO antes do `kill-session`, para outro processo não
ver "sessão sumiu" no meio.

### Regras inegociáveis (NPAD)

O NPAD bloqueia a conta por cerca de 30 minutos depois de muitas conexões novas
em poucos minutos. É daí que vêm as duas primeiras regras.

- **Uma só conexão SSH** (`ControlMaster=auto`, `ControlPersist=600`) para
  tudo, com no máximo dois canais: um para transferências e streaming, outro
  para consultas curtas. Se o servidor recusar o segundo, o fishell cai para
  modo serial.
- **Conexão recusada** (`ssh` sai com 255 sem "Permission denied") bloqueia o
  destino por **30 minutos**, sem nova tentativa. O bloqueio fica em
  `ctl/<alias>.bloqueio` (a hora de liberar, em ISO), e o painel, o vigia e o
  `fishell jobs` (processos diferentes) respeitam o mesmo arquivo; vencido, é
  ignorado. Erro que nem chegou ao cluster (DNS, rede inalcançável, alias
  desconhecido, `ControlPath too long`, tempo esgotado no connect, que só
  acontece sem mestre vivo) espera **2 minutos**; erro desconhecido, 30.
  "Permission denied" é falha de autenticação: para a atualização automática
  até uma atualização forçada (tecla `r` no painel; o `fishell jobs` sempre
  força a sua).
- **Job que terminou sem ser visto:** o `listar_jobs` pede, no mesmo comando
  remoto, `sacct -j` sem janela de tempo para os jobs registrados que saíram
  do `squeue` (o filtro roda no remoto, sobre a saída do `squeue` guardada
  em `$q`). `DEADLINE` e `REVOKED` contam como falha.
- **Nada apaga no cluster.** `rsync` sempre `-a -s`; nunca `--delete` nem
  `--remove-source-files`; nenhum `rm` remoto.
- Intervalos: `local` a cada 3 s, NPAD a cada 60 s.
- O fishell não guarda credencial. Config em `~/.config/fishell/`
  (`FISHELL_CONFIG_DIR`), estado em `~/.local/state/fishell/`
  (`FISHELL_STATE_DIR`: `estado.db`, `jobs/`, `ctl/` com os sockets e os
  `<alias>.bloqueio`, `vigia.lock`, `vigia.log`).
- Limitação conhecida: um `FISHELL_STATE_DIR` longo estoura o limite de 108
  bytes do caminho do socket SSH (`ctl/`). O caminho padrão cabe.

### Testes

Da raiz do repo, com o ambiente do projeto ativo:

```bash
uv sync                  # instala textual e as ferramentas de teste
uv run pytest -q         # toda a suíte (sem rede)
uv run pytest -q src/python/tests/test_slurm.py   # um arquivo
```

A suíte não usa rede: os adaptadores são testados contra saídas gravadas
(`tests/fixtures/`) e contra falsos, e o núcleo contra adaptadores falsos. O CI
tem um job `python` que roda `uv sync --locked` e `uv run pytest -q`.

**Rodar o fishell à mão fala com o NPAD.** A suíte não usa rede, mas `uv run
fishell` e `uv run fishell jobs` usam: sem `destinos.toml`, os destinos padrão
são `local` e `npad`, e o `jobs` sempre força a consulta. Para testar sem o
cluster, use uma config só com o local:

```bash
mkdir -p /tmp/fc && printf '[[destino]]\nnome = "local"\ntipo = "local"\n' > /tmp/fc/destinos.toml
FISHELL_CONFIG_DIR=/tmp/fc FISHELL_STATE_DIR=/tmp/fs uv run fishell jobs
```

**Regravar uma fixture:** rode o comando de leitura no destino (por exemplo
`squeue`, `sinfo`, `sacct` no NPAD, pela conexão única e poucas vezes), salve a
saída em `tests/fixtures/` e **troque o usuário real por `usuario` antes de
salvar**: o repo é público. Confira com `grep` pelo login (sem imprimi-lo) antes
de commitar.
