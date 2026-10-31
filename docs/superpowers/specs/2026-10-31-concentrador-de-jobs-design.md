# fishell: concentrador de jobs (design)

**Status:** rascunho para aprovação, 2026-10-31.

## Pedido

Nas palavras do autor, ao longo da conversa que gerou este documento:

- "evoluir o fishell para ter um editor e gerenciador de files, onde posso executar tanto no npad quanto no colab";
- "seria mais sobre o gerenciador desses processos e concentrador de tarefas, do que editor. mas é sempre bom poder ver a árvore de arquivos, visualizar code e mesmo imagens no futuro";
- "quero um lugar de visualização dos jobs, no npad, colab, e outros lugares. mesmo local ele pode servir"; "hugging face, outros servidores via ssh, etc";
- "inclua também a possibilidade de pedir ao claude que o acesse via MCP", "assim como fizemos no hmtasks";
- "vamos focar em ter uma versão linux, e futuramente a versão web"; "vamos focar em local por agora";
- "atualize também a documentação da ferramenta".

## Por que

O ciclo de hoje, para rodar algo em GPU remota, é manual e se repete em cada projeto: editar no editor local, enviar com `rsync`/`scp`, montar o ambiente no nó de login, submeter com `sbatch`, repetir `squeue` até terminar e trazer o resultado com outro `rsync`. Cada projeto de pesquisa carrega a sua cópia desse ciclo em scripts próprios (`sync.sh push|pull`, `setup_env.sh`, um script que monta e submete o `.sbatch`). Não existe um lugar que mostre o que está rodando em todos os lugares ao mesmo tempo.

O fishell de hoje (bash e PowerShell, versão 2.7) resolve só o começo: instalar a chave, registrar o alias `npad` no `~/.ssh/config`, testar a conexão, enviar e baixar arquivos avulsos e rodar um comando remoto.

## Para quem

1. **Primeiro, o autor**, no uso diário de pesquisa: vários projetos, jobs no NPAD, treinos na GPU local, eventualmente Colab e Hugging Face.
2. **Depois, os alunos** da disciplina, que hoje usam o fishell no terminal do Colab para chegar ao NPAD. Para eles o painel precisa continuar simples. Até a versão nova cobrir o que a atual faz, os alunos continuam nas versões bash e PowerShell, que não mudam.

## Objetivos

1. **Uma tela única de jobs**, com tudo o que roda em qualquer destino: estado, tempo, última linha do log e o log ao vivo do job destacado.
2. **O ciclo de projeto em ações**: enviar, montar ambiente, submeter, acompanhar e trazer resultados, dirigido por uma receita que mora no próprio projeto.
3. **Vários destinos atrás de uma interface comum**: local, NPAD (SLURM por SSH), Colab, Hugging Face Jobs e servidores SSH genéricos.
4. **Navegador de arquivos** local e remoto, com visualização de código.
5. **Acesso do Claude por MCP**, local, com as ações sensíveis virando pedidos que o autor aprova no painel.
6. **Núcleo sem nada de interface**, para que a versão web futura e o MCP sejam só outras frentes sobre o mesmo código.

## Fora do escopo agora

- Windows. A versão PowerShell atual fica como está, sem as novidades.
- A versão web (o núcleo é desenhado para ela, mas ela não é construída agora).
- Conector MCP remoto, acesso pelo celular, OAuth.
- Editor de texto. O autor edita no editor dele; o fishell só mostra código.
- Visualização de imagens (fica para depois).
- Gerar chave SSH (continua a regra atual: é um `ssh-keygen` que o usuário roda).
- Instalar pacotes ou criar ambientes por conta própria: a receita aponta o script de ambiente do projeto, e o fishell só o executa.

## O que faria isto fracassar, mesmo funcionando

- **Apagar qualquer coisa no remoto sem pedido explícito.** O scratch do NPAD guarda dados de pesquisa que só o dono manda apagar. Os scripts de hoje não têm modo de remoção de propósito.
- **Ser bloqueado pelo NPAD.** O cluster recusou novas conexões depois de cerca de 9 conexões em poucos minutos (medido em 2026-08-18), com bloqueio de cerca de 30 minutos. Uma tela que consulta o NPAD periodicamente, abrindo uma conexão por consulta, fica bloqueada.
- **Gastar créditos pagos (Colab, Hugging Face) por iniciativa do Claude** sem aprovação.
- **Vazar para este repositório**, que é público, o usuário do NPAD, caminhos pessoais ou dados de pesquisa. Receitas e estado ficam fora do repositório.
- **Quebrar as versões bash e PowerShell** que os alunos usam, ou o CI que as mantém em paridade.
- **Um painel que assusta quem está começando.** O princípio de menu enxuto do fishell continua valendo.

## Decisões

| Decisão | Escolha | Quem decidiu |
|---|---|---|
| Plataforma | Só Linux | autor |
| Versão web | Depois; o núcleo já nasce sem interface | autor (web depois), construtor do desenho (núcleo sem interface) |
| Linguagem | Python | proposta aceita pelo autor ("isso") |
| Biblioteca de tela | Textual: a tela tem barra lateral, tabela, log ao vivo e faixa de pedidos ao mesmo tempo, e o Textual traz essas peças; também roda no navegador com `textual serve`, o que adianta a versão web | escolha do desenho, aceita ("tudo ok") |
| Arranjo da tela de jobs | Lista única no estilo htop, com a barra de destinos à esquerda | autor ("gostei da A, com a barra de destinos da B") |
| MCP | Local, por stdio, iniciado pelo Claude Code nesta máquina; remoto só junto com a versão web | autor ("vamos focar em local por agora") |
| Trava das ações sensíveis | Igual ao hmtasks: a ação vira pedido guardado pelo fishell e aprovado no painel; a trava fica no fishell, não no "Permitir?" do app do Claude, que some no modo automático e em rotinas | autor ("assim como fizemos no hmtasks") |
| Credenciais | O fishell não guarda nenhuma: NPAD e SSH pelo `~/.ssh/config`, Colab pelo login da ferramenta `colab`, Hugging Face pelo `hf auth` | escolha do desenho, aceita |
| Onde o código vive | Neste repositório, numa pasta Python nova ao lado de `src/bash` e `src/powershell`, que não mudam | escolha do desenho, aceita |
| Receita do projeto | Um `fishell.toml` na raiz de cada projeto | escolha do desenho, aceita |
| Aviso de fim de job | Notificação na própria máquina (`notify-send`), por um processo vigia que só existe enquanto houver job ativo | escolha do desenho, aceita |
| Ordem | NPAD e local primeiro; depois Colab, Hugging Face e SSH genérico | escolha do desenho, aceita |
| Aprovação | Só no painel; subcomandos sem terminal interativo viram pedido; é trava do fishell, não barreira contra o shell | escolha do desenho, depois da revisão |
| Sobrescrever no envio | `rsync -a` como os scripts de hoje; sobrescrever não conta como apagar | escolha do desenho, depois da revisão |
| Alcance do Claude | Montar ambiente e copiar arquivos livres; tudo limitado ao que a receita declara | escolha do desenho, depois da revisão |
| Arrays | `job` (`.sbatch` com `--array` opcional) ou `submeter` (script do projeto que calcula o N) | escolha do desenho, depois da revisão |
| NPAD em desenvolvimento | Pode conectar para gravar saídas, com o usuário trocado por `usuario` | escolha do desenho, depois da revisão |

## Arquitetura

Quatro camadas, nesta direção de dependência:

1. **Núcleo**, sem nenhuma importação de interface: os modelos (`Destino`, `Receita`, `Job`, `Pedido`), o estado local, o serviço de pedidos e o laço de atualização.
2. **Adaptadores**, um por tipo de destino, todos com a mesma interface.
3. **Frentes**: a tela (Textual), o MCP (stdio), os subcomandos de linha de comando (para scripts e para o vigia) e, no futuro, a web.
4. **Configuração**: a lista de destinos do usuário e as receitas dos projetos.

Nenhuma frente fala direto com SSH, `colab` ou `hf`: tudo passa pelo núcleo. É isso que faz o MCP herdar as travas sem duplicar regra (mesma lição do hmtasks, onde as ferramentas do MCP chamam a API do próprio app e nunca o banco).

### Interface comum dos adaptadores

O que cada destino precisa oferecer, em termos de comportamento (nomes e assinaturas ficam com o construtor):

- **listar jobs** (inclusive os que o fishell não iniciou, quando o destino permitir vê-los, marcados como externos);
- **recursos** (o que mostrar na barra lateral: GPUs livres por partição, uso da GPU local, créditos);
- **enviar** e **trazer** os caminhos da receita;
- **montar ambiente** (executar o script da receita e mostrar a saída);
- **submeter**, **cancelar**, **ler o log** (final e acompanhamento ao vivo);
- **arquivos**: listar uma pasta, ler um arquivo, copiar entre local e remoto.

Um destino que não oferece alguma capacidade declara isso, e a tela esconde a ação.

### Destinos

| Tipo | Como roda um job | Como lista | Observações |
|---|---|---|---|
| `local` | processo dentro de uma sessão `tmux` com prefixo do fishell, saída em arquivo de log | sessões `tmux` do fishell e o estado salvo | recursos por `nvidia-smi`; só aparece o que o fishell iniciou |
| `slurm` (o NPAD) | `sbatch --parsable` no remoto | `squeue`, e `sacct` para o estado final | **uma única conexão SSH persistente** (`ControlMaster`/`ControlPersist`) para tudo; consulta a cada minuto, mais ou menos; jobs submetidos à mão aparecem como externos; recursos por `sinfo` |
| `ssh` | como o `local`, mas com `tmux` no servidor remoto | sessões `tmux` remotas do fishell | mesma regra da conexão única |
| `colab` | a ferramenta oficial `colab` (pacote `google-colab-cli`): `colab run` para script com máquina descartável, ou sessão criada com `colab new` | `colab sessions`, `colab status` | créditos por `colab usage`; a ferramenta só roda em Linux e macOS |
| `hf` | `hf jobs run` / `hf jobs uv` | `hf jobs ps`, `hf jobs inspect` | log por `hf jobs logs`, cancelamento por `hf jobs cancel`, hardware por `hf jobs hardware` |

A lista de destinos do usuário (nome, tipo, alias SSH, partições a mostrar) fica num arquivo de configuração em `~/.config/fishell/`, fora do repositório.

### O que já se sabe do NPAD

- **Multiplexação SSH funciona**: os scripts de envio de hoje usam `ControlMaster` com vários `rsync` e comandos pela mesma conexão desde 2026-08.
- **`sacct` está liberado** para usuários e devolve estado final e código de saída de jobs antigos (conferido em 2026-10-31, Slurm 22.05.11). É a fonte do estado final; o marcador no fim do log é só complemento.
- **O limite de sessões por conexão é desconhecido** (`sshd_config` não é legível para usuários). O adaptador não pode depender de muitos canais simultâneos: se um canal extra for recusado, serializa as operações em vez de abrir conexão nova.
- **Autenticação sem pessoa presente**: a chave está no `ssh-agent` da sessão gráfica, e processos iniciados nela (o painel, o vigia, o MCP iniciado pelo Claude Code) entram com `BatchMode` (conferido em 2026-10-31). Sem o agente, por exemplo depois de sair da sessão, o vigia para e avisa, sem insistir.

### Estado local

Um banco SQLite em `~/.local/state/fishell/` com os jobs que o fishell iniciou (destino, projeto, identificador remoto, caminho do log, hora de início) e a fila de pedidos do Claude. Jobs externos não são gravados: são lidos do destino a cada atualização.

## A tela de jobs

Arranjo aprovado (o conteúdo é ilustrativo):

```
fishell  jobs                                                                         sex 31/10 10:14
[!] Claude pede: iniciar job no Colab (A100, ~2 créditos/h) para sam-bench      [a] aprovar  [r] recusar
┌ DESTINOS ───────────┐┌ todos os destinos ─────────────────────────────────────────────────────────┐
│> todos          5   ││  DESTINO  PROJETO      JOB             ESTADO        TEMPO     LOG                 │
│                     ││> npad     pose         kp-extract[65]  ● 47/65 ok    00:11:52  === DONE 47 ===     │
│  npad          ●◌   ││  npad     sam-bench    sam3-bench      ◌ fila        00:23:10  (Resources)         │
│   a100 0/1 h200 0/2 ││  local    yolo         yolo-train      ● ép. 34/100  01:42:05  mAP50 0.731         │
│   cpu amd 13/56     ││  colab    sam-bench    sam3-a100       ✓ ok          00:06:41  bench salvo         │
│  local         ●    ││  hf       curso        ch8-demo        ✗ falhou      00:00:38  CUDA out of memory  │
│   5060Ti 61% 9/16G  ││                                                                            │
│  colab         ✓    ││                                                                            │
│   84 créditos       ││                                                                            │
│  hf            ✗    ││                                                                            │
│  lab-ssh       —    ││                                                                            │
└─────────────────────┘└────────────────────────────────────────────────────────────────────────────┘
┌ log ao vivo · npad:/scratch/global/$USER/pose/logs/extract_2121060_47.out ─────────────────────────┐
│ node : gpunode2   GPU 0: NVIDIA A100-SXM4-80GB                                                     │
│ === DONE 47 ===                                                                                    │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
tab destinos/jobs  ↑↓ mover  enter log cheio  n novo job  p trazer resultados  c cancelar  f arquivos  q sair
```

- **Barra de destinos**: "todos" mostra a lista inteira; um destino filtra a lista. Embaixo de cada destino, o recurso que importa nele.
- **Lista**: uma linha por job, de qualquer destino, com a última linha do log.
- **Log ao vivo** do job destacado, sempre visível; `enter` abre em tela cheia.
- **Faixa de pedidos** do Claude no topo, só quando há algo esperando.
- **Novo job** (`n`): escolhe o projeto (pela receita) e o destino; no NPAD, a partição, mostrando o que está livre.
- **Atualização**: o local a cada poucos segundos; o NPAD e os demais remotos por volta de um minuto, sempre pela conexão persistente.

## Receita do projeto (`fishell.toml`)

Fica na raiz de cada projeto e transforma em configuração o que hoje está nos scripts de envio e submissão. Uma seção por destino em que o projeto roda. Exemplo, a partir de um projeto real de extração em array:

```toml
[npad]
remoto   = "/scratch/global/$USER/pose"
enviar   = ["scripts/ -> code/", "configs/ -> configs/"]
trazer   = ["outputs/keypoints/"]
ambiente = "code/npad/setup_env.sh"
job      = "code/npad/extract_array.sbatch"
particao = "gpu-4-a100"
```

- **enviar** e **trazer** usam `rsync -a` pela conexão persistente, com a mesma semântica dos scripts de hoje: arquivo alterado é sobrescrito no destino, e isso não conta como apagar. Nunca `--delete` nem `--remove-source-files`, nos dois sentidos. Filtros de inclusão e exclusão (os scripts de hoje enviam só vídeos, sem versões de baixa resolução) precisam caber na receita.
- **Duas formas de submeter**, porque o caso real mais pesado calcula o tamanho do array a partir dos dados:
  - `job = "<arquivo>.sbatch"`: o fishell submete com `sbatch --parsable -p <partição>`, e o diálogo de novo job (ou o Claude) pode acrescentar `--array=1-N%K`;
  - `submeter = "<script>"`: o script de submissão do próprio projeto, executado no remoto, que monta o que precisar (por exemplo, a lista de entradas e o N) e chama o `sbatch`. Ele precisa imprimir o id do job numa linha reconhecível; a convenção exata fica com quem constrói e vai para a documentação. Os scripts de hoje precisam de uma linha a mais para segui-la.
- O `.sbatch` continua sendo do projeto; a receita só diz qual é e qual partição usar por padrão.
- Projetos sem receita continuam aparecendo na lista de jobs (como externos), mas não oferecem enviar, ambiente, submeter e trazer.

## Arquivos (`f`)

Duas colunas, local e remoto (o destino do job destacado ou um escolhido), para navegar, ver código com cores e copiar de um lado para o outro. Somente leitura para o conteúdo. Apagar no remoto pede confirmação no painel; vindo do Claude, vira pedido. A navegação remota usa a conexão persistente, então listar uma pasta por tecla não abre conexão nova.

## MCP

- Um subcomando (`fishell mcp`) que o Claude Code inicia nesta máquina, por stdio. Sem servidor exposto, sem OAuth.
- As ferramentas chamam o núcleo, nunca os adaptadores diretamente.
- **Livres para o Claude**: listar jobs e destinos, ler log, ver recursos, listar projetos com receita, navegar e ler arquivos, enviar e trazer, copiar no navegador de arquivos, montar ambiente (é o script do próprio projeto, sem custo), submeter no `local`, no `ssh` e no NPAD.
- **Viram pedido**: iniciar job no Colab ou no Hugging Face (gastam créditos), cancelar job (mata trabalho em andamento) e apagar qualquer coisa no remoto.
- **Limitado à receita**: pelo MCP, o Claude escolhe projeto, destino, partição e tamanho do array, mas só executa o que a receita do projeto declara (caminhos, script de ambiente, `.sbatch` ou script de submissão). Não existe ferramenta MCP para rodar comando arbitrário.
- **Só o autor aprova, e só no painel** (a faixa no topo). Não existe ferramenta de aprovação no MCP nem subcomando de aprovação: o painel exige um terminal interativo, que o Claude não tem.
- **Os subcomandos de linha de comando seguem a mesma trava**: rodados sem terminal interativo, os que iniciariam job pago, cancelariam ou apagariam criam um pedido em vez de agir.
- **Isto é uma trava do fishell, não uma barreira de segurança contra o Claude.** Com acesso ao shell, o Claude pode chamar `ssh`, `colab` ou `hf` diretamente; isso fica com as permissões do próprio Claude Code. O fishell garante que nenhum caminho dele, MCP ou subcomando, faça essas ações sem o autor.
- Cada pedido diz o que será feito, onde e quanto deve custar, quando houver custo.

## Aviso de fim de job

Quando um job iniciado pelo fishell termina (ou falha) com o painel fechado, o autor recebe uma notificação na própria máquina (`notify-send`). Quem verifica é um processo vigia que nasce quando há job ativo e termina sozinho quando não há mais nenhum; não é um serviço permanente. Ele obedece à mesma regra da conexão persistente.

## Fases

Cada fase termina com o fishell utilizável e com a documentação atualizada (seção abaixo).

1. **Núcleo, `local` e NPAD**: tela de jobs, receita, enviar, montar ambiente, submeter, acompanhar, trazer, aviso de fim de job.
2. **MCP local** com a fila de pedidos e a aprovação no painel.
3. **Arquivos**: navegador local e remoto com visualização de código.
4. **Colab.**
5. **Hugging Face Jobs e SSH genérico.**
6. **Futuro, fora deste desenho**: versão web, MCP remoto, imagens, migração dos alunos para a versão nova.

## Documentação

O autor pediu a documentação atualizada. A regra do repositório é que a documentação descreve só o que existe ("um README errado sobre a máquina é pior que um README omisso"). Então, **em cada fase**:

- **`README.md`** (para quem usa): seção da versão Python com instalação, a tela e os subcomandos do que a fase entregou. O tutorial do NPAD para alunos continua, e as instruções das versões bash e PowerShell não mudam.
- **`docs/desenvolvimento.md`** (para quem mantém): arquitetura do núcleo, a interface dos adaptadores, como acrescentar um destino, o formato da receita, como rodar os testes da versão Python.
- **`CLAUDE.md`** (local, fora do git): seção da versão Python com comandos, armadilhas e as regras inegociáveis (conexão persistente com o NPAD, nada de apagar no remoto, pedidos de aprovação). Hoje ele descreve só os dois ports; deixa de dizer que o programa é "escrito duas vezes" sem ressalva.
- **Fora do repositório**: a linha que descreve o fishell no `CLAUDE.md` da pasta `github-projects` ("SSH panel for students... the same program written twice") passa a mencionar a versão Python quando a fase 1 for entregue.

## Testes

- Sem rede nos testes. Cada adaptador é testado contra saídas gravadas das ferramentas (`squeue`, `sinfo`, `sacct`, `tmux`, `nvidia-smi`, `colab`, `hf`), e o núcleo contra adaptadores falsos.
- **Durante o desenvolvimento, conectar no NPAD é permitido** para gravar essas saídas e conferir o adaptador: só pela conexão persistente, poucas sessões por dia, comandos de leitura e, no máximo, jobs de teste curtos. As saídas gravadas vão para o repositório público, então o usuário real é trocado por `usuario` antes de salvar, como o `tools/make-screenshot.py` já faz com a imagem do README.
- A tela é testada com o modo de teste do próprio Textual.
- A regra da conexão persistente e a regra de nunca apagar no remoto têm teste próprio cada uma.
- Um job novo no CI para a versão Python; os jobs `bash`, `powershell` e `paridade` não mudam.

## Restrições do ambiente

- Linux, Python 3.12 disponível. `tmux`, `notify-send` e `hf` já instalados na máquina do autor; a ferramenta `colab` não.
- O disco do sistema está quase cheio; nesta máquina os ambientes Python ficam no disco externo (ver o `CLAUDE.md` local). Instalação e ambiente de desenvolvimento seguem essa regra.
- Commits deste repositório não levam coautoria nem menção ao Claude.

## Deixado para quem constrói

- Estrutura de pastas e nome do pacote Python, nomes e assinaturas da interface dos adaptadores, nomes das ferramentas MCP.
- Esquema do SQLite, formato exato do arquivo de destinos, campos opcionais da receita além dos listados.
- Intervalos exatos de atualização (respeitando a conexão única no NPAD), cores e teclas não citadas.
- Como empacotar e instalar (`uv tool install` a partir do repositório é o caminho esperado).

## Riscos

- **A ferramenta `colab` é nova** e pode mudar de interface; o adaptador do Colab deve depender do mínimo dela.
- **O limite de conexões do NPAD** não é documentado; o número acima foi medido uma vez. A conexão persistente é a defesa, e o adaptador precisa tratar a recusa sem tentar de novo em sequência.
- **Jobs externos no NPAD** podem ser muitos (arrays grandes); a lista precisa agrupar arrays numa linha, como no exemplo (`kp-extract[65]`, `47/65 ok`).
