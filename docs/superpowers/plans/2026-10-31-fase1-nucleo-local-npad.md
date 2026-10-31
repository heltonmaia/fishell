# Fase 1: núcleo, local e NPAD (plano de implementação)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** um comando `fishell` (Python, só Linux) que abre a tela de jobs com os destinos `local` e NPAD, e executa o ciclo enviar, montar ambiente, submeter, acompanhar e trazer a partir do `fishell.toml` de cada projeto, avisando por `notify-send` quando um job termina.

**Architecture:** núcleo sem interface (`fishell.core`), adaptadores por tipo de destino atrás de um `Protocol` comum (`fishell.adapters`), frentes por cima (tela Textual em `fishell.tui`, subcomandos em `fishell.cli`, vigia em `fishell.vigia`). Todo acesso ao NPAD passa por uma única conexão SSH multiplexada (`Conexao`). O MCP, o navegador de arquivos, o Colab, o HF e o SSH genérico são fases seguintes e não entram aqui.

**Tech Stack:** Python ≥ 3.11 (`tomllib`, `sqlite3`), Textual, `ssh`/`rsync`/`tmux`/`nvidia-smi`/`notify-send` do sistema via `subprocess`, pytest + pytest-asyncio, uv, hatchling.

**Spec:** `docs/superpowers/specs/2026-10-31-concentrador-de-jobs-design.md`

## Global Constraints

- Só Linux. `src/bash/`, `src/powershell/`, `bin/` e os jobs `bash`, `powershell` e `paridade` do CI **não mudam**.
- Código em `src/python/fishell/`, testes em `src/python/tests/`, `pyproject.toml` e `uv.lock` na raiz do repositório. Ambiente: `uvon --criar` na raiz (cria o link `.venv`, regra da máquina); nos comandos, `uvon >/dev/null && uv run ...` na mesma linha.
- Única dependência de execução nesta fase: `textual>=1.0`. Desenvolvimento: `pytest>=8`, `pytest-asyncio>=0.24`.
- Toda chamada `ssh` e todo `rsync -e` levam `-o ControlMaster=auto -o ControlPath=<state>/ctl/%C -o ControlPersist=600 -o BatchMode=yes -o ConnectTimeout=45 -o ServerAliveInterval=30`.
- Conexão recusada (`ssh` sai com 255 sem "Permission denied"): o destino fica indisponível por **30 minutos**, sem nova tentativa nesse intervalo. "Permission denied" no erro é falha de autenticação, não recusa.
- Nenhum código executa `rm`, `rsync --delete` ou `--remove-source-files` no remoto. `rsync` sempre `-a`.
- Atualização: `local` a cada **3 s**, NPAD a cada **60 s**.
- Configuração em `~/.config/fishell/` (sobrescrita por `FISHELL_CONFIG_DIR`), estado em `~/.local/state/fishell/` (sobrescrito por `FISHELL_STATE_DIR`). O fishell não guarda credencial nenhuma.
- Texto de interface em pt-BR, todo em `src/python/fishell/textos.py`.
- Saídas gravadas do NPAD vão para o repositório público: o usuário real vira `usuario` antes de salvar.
- Commits em pt-BR, **sem** `Co-Authored-By` e sem mencionar o Claude (regra do repositório).
- Versão: `3.0.0a1`, só no `pyproject.toml`; o código lê com `importlib.metadata.version("fishell")`.

## Review Focus

1. **NPAD some no meio da sessão** (socket mestre morto, bloqueio por taxa): o destino mostra "indisponível até HH:MM", os outros seguem atualizando e a tela não trava. Testes: Task 5 (`test_recusa_bloqueia_por_30_min`) e Task 9 (`test_adaptador_com_erro_nao_derruba_os_outros`).
2. **Array grande ou muitos jobs externos** (1000 tarefas): uma linha por array, contagem certa. Teste: Task 6 (`test_array_de_1000_tarefas_vira_uma_linha`).
3. **Caminho com espaço ou aspas** na receita, no remoto ou no comando local: tudo passa por `shlex.quote`. Testes: Task 7 (`test_submeter_cita_caminhos`) e Task 8 (`test_comando_com_aspas`).
4. **Envio longo (GB) com a tela aberta**: a ação roda num worker, a tela segue atualizando e não abre segunda conexão. Teste: Task 12 (`test_enviar_longo_nao_bloqueia_atualizacao`).
5. **Receita com erro** (TOML inválido, `job` e `submeter` juntos, `submeter` sem `log`): o projeto aparece marcado "receita com erro: <motivo>" e nada mais quebra. Testes: Task 2 (`test_erros_de_receita`) e Task 3 (`test_projeto_com_receita_invalida_fica_listado`).

---

### Task 1: Esqueleto do pacote, ambiente e CI

**Files:**
- Create: `pyproject.toml`, `src/python/fishell/__init__.py`, `src/python/fishell/__main__.py`, `src/python/fishell/cli.py`, `src/python/fishell/textos.py`, `src/python/tests/test_cli.py`
- Modify: `.gitignore` (acrescentar `.venv`, `__pycache__/`, `.pytest_cache/`), `.github/workflows/ci.yml` (job novo `python`)

**Interfaces:**
- Produces: `fishell.cli.main(argv: list[str] | None = None) -> int`; `fishell.__version__: str`.

- [ ] **Step 1: Criar o ambiente**

Run: `cd ~/work/github-projects/fishell && uvon --criar`
Expected: link `.venv` na raiz apontando para `uv-fishell`.

- [ ] **Step 2: `pyproject.toml`**

`[project] name="fishell" version="3.0.0a1" requires-python=">=3.11" dependencies=["textual>=1.0"]`, `[project.scripts] fishell="fishell.cli:main"`, `[dependency-groups] dev=["pytest>=8","pytest-asyncio>=0.24"]`, build com hatchling e `[tool.hatch.build.targets.wheel] packages=["src/python/fishell"]`, `[tool.pytest.ini_options] testpaths=["src/python/tests"] asyncio_mode="auto"`.

- [ ] **Step 3: Teste que falha**

```python
def test_versao(capsys):
    assert main(["--version"]) == 0
    assert capsys.readouterr().out.strip() == "fishell 3.0.0a1"

def test_subcomando_desconhecido():
    assert main(["xyz"]) == 2
```

- [ ] **Step 4: Rodar e ver falhar**

Run: `uvon >/dev/null && uv sync && uv run pytest src/python/tests/test_cli.py -q`
Expected: FAIL (`ImportError`).

- [ ] **Step 5: Implementar `main` com `argparse`** (subcomandos virão nas Tasks 10, 11 e 13) e `__main__.py` chamando `sys.exit(main())`.

- [ ] **Step 6: Rodar e ver passar**

Run: `uvon >/dev/null && uv run pytest -q`
Expected: 2 passed.

- [ ] **Step 7: Job `python` no CI**

Depois do job `paridade`: `runs-on: ubuntu-latest`, `actions/checkout@v4`, `astral-sh/setup-uv@v6`, `uv sync --locked`, `uv run pytest -q`.

- [ ] **Step 8: Commit**

```bash
git status   # sem config.sh, config.ps1, .ssh/, CLAUDE.md, .claude/
git add pyproject.toml uv.lock .gitignore .github/workflows/ci.yml src/python
git commit -m "feat(py): esqueleto da versao Python"
```

### Task 2: Modelos e receita

**Files:**
- Create: `src/python/fishell/core/__init__.py`, `src/python/fishell/core/modelos.py`, `src/python/fishell/core/receita.py`, `src/python/tests/test_receita.py`

**Interfaces:**
- Produces (em `modelos.py`):
  - `class EstadoJob(StrEnum)`: `FILA="fila"`, `RODANDO="rodando"`, `OK="ok"`, `FALHOU="falhou"`, `CANCELADO="cancelado"`, `DESCONHECIDO="desconhecido"`; `TERMINAIS = frozenset({OK, FALHOU, CANCELADO})`.
  - `@dataclass(frozen=True) Job(destino: str, id: str, nome: str, estado: EstadoJob, decorrido: str = "", projeto: str | None = None, ultima_linha: str = "", externo: bool = False, array_total: int | None = None, array_ok: int | None = None, log: str | None = None, motivo: str = "")`
  - `@dataclass(frozen=True) Recurso(rotulo: str, livres: int | None = None, total: int | None = None, texto: str = "")`
  - `@dataclass(frozen=True) Transferencia(de: str, para: str, incluir: tuple[str, ...] = (), excluir: tuple[str, ...] = ())`
  - `@dataclass(frozen=True) SecaoReceita(destino: str, remoto: str | None, enviar: tuple[Transferencia, ...], trazer: tuple[Transferencia, ...], ambiente: str | None, job: str | None, submeter: str | None, comando: str | None, particao: str | None, log: str | None)`
  - `@dataclass(frozen=True) Receita(raiz: Path, nome: str, secoes: dict[str, SecaoReceita], erro: str | None = None)`
  - `class ErroReceita(ValueError)`
- Produces (em `receita.py`): `ler_receita(raiz: Path) -> Receita | None` (`None` sem `fishell.toml`; com erro, devolve `Receita(..., secoes={}, erro=<motivo>)` em vez de levantar); `parse_transferencia(item: str | dict) -> Transferencia`.

Formato: uma tabela por destino (`[npad]`, `[local]`). Chaves aceitas: `remoto`, `enviar`, `trazer`, `ambiente`, `job`, `submeter`, `comando`, `particao`, `log`, e `nome` no topo (padrão: nome da pasta). Item de transferência: `"a/ -> b/"` ou `{de="a/", para="b/", incluir=[...], excluir=[...]}`. `trazer` com a mesma sintaxe, lida como remoto → local. Regras: `job` e `submeter` são exclusivos; `submeter` exige `log`; chave desconhecida é erro.

- [ ] **Step 1: Testes que falham**

```python
def test_receita_do_spec(tmp_path):        # o exemplo [npad] do spec
    r = ler_receita(proj(tmp_path, EXEMPLO_SPEC))
    s = r.secoes["npad"]
    assert s.remoto == "/scratch/global/$USER/pose"
    assert s.enviar == (Transferencia("scripts/", "code/"), Transferencia("configs/", "configs/"))
    assert s.trazer == (Transferencia("outputs/keypoints/", "outputs/keypoints/"),)
    assert (s.job, s.particao, s.submeter) == ("code/npad/extract_array.sbatch", "gpu-4-a100", None)

def test_transferencia_com_filtros():
    t = parse_transferencia({"de": "/dados/v/", "para": "videos/", "incluir": ["*/", "*.mp4"], "excluir": ["*_low*", "*"]})
    assert t.incluir == ("*/", "*.mp4") and t.excluir == ("*_low*", "*")

def test_sem_arquivo_devolve_none(tmp_path):
    assert ler_receita(tmp_path) is None

@pytest.mark.parametrize("toml,trecho", [
    ("[npad\n", "TOML"),
    ('[npad]\njob="a.sbatch"\nsubmeter="s.sh"\nlog="l"\n', "job e submeter"),
    ('[npad]\nsubmeter="s.sh"\n', "log"),
    ('[npad]\nfoo=1\n', "foo"),
])
def test_erros_de_receita(tmp_path, toml, trecho):
    r = ler_receita(proj(tmp_path, toml))
    assert r.secoes == {} and trecho in r.erro
```

(`trazer` de string `"x/"` sem seta significa `x/ -> x/`.)

- [ ] **Step 2: Rodar e ver falhar** — `uvon >/dev/null && uv run pytest src/python/tests/test_receita.py -q` → FAIL.
- [ ] **Step 3: Implementar** `modelos.py` e `receita.py` com `tomllib`.
- [ ] **Step 4: Rodar e ver passar** — mesmo comando → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(py): modelos e leitura do fishell.toml"`

### Task 3: Configuração de destinos e projetos; estado em SQLite

**Files:**
- Create: `src/python/fishell/core/config.py`, `src/python/fishell/core/estado.py`, `src/python/tests/test_config.py`, `src/python/tests/test_estado.py`

**Interfaces:**
- Consumes: `Receita`, `ler_receita`, `EstadoJob` (Task 2).
- Produces:
  - `@dataclass(frozen=True) DestinoConfig(nome: str, tipo: Literal["local", "slurm"], ssh: str | None = None, particoes: tuple[str, ...] = ())`
  - `@dataclass(frozen=True) Config(destinos: tuple[DestinoConfig, ...], projetos: tuple[Path, ...])`
  - `dir_config() -> Path`, `dir_estado() -> Path` (variáveis de ambiente da seção de restrições).
  - `ler_config(dir_cfg: Path | None = None) -> Config` lê `destinos.toml`: `projetos = ["~/..."]` e `[[destino]]` com `nome`, `tipo`, `ssh`, `particoes`. Sem arquivo: `local` + `npad` (`tipo="slurm"`, `ssh="npad"`), sem projetos.
  - `descobrir_receitas(cfg: Config, cwd: Path) -> list[Receita]`: as de `cfg.projetos` mais a do `cwd`, sem repetir, receitas com erro incluídas.
  - `@dataclass(frozen=True) RegistroJob(destino: str, job_id: str, projeto: str, nome: str, log: str | None, array_total: int | None, inicio: datetime, estado: EstadoJob, notificado: bool)`
  - `class Estado(arquivo: Path)`: `registrar(destino, job_id, projeto, nome, log, array_total) -> None`; `ativos(destino: str | None = None) -> list[RegistroJob]` (estado não terminal); `recentes(destino: str, desde: datetime) -> list[RegistroJob]`; `atualizar(destino, job_id, estado: EstadoJob) -> bool` (True só na primeira vez que chega a um estado terminal); `marcar_notificado(destino, job_id) -> None`.

- [ ] **Step 1: Testes que falham**

```python
def test_padrao_sem_arquivo(tmp_path):
    cfg = ler_config(tmp_path)
    assert [(d.nome, d.tipo, d.ssh) for d in cfg.destinos] == [("local", "local", None), ("npad", "slurm", "npad")]

def test_projeto_com_receita_invalida_fica_listado(tmp_path): ...  # erro preenchido, presente na lista
def test_cwd_nao_duplica_projeto_configurado(tmp_path): ...

def test_atualizar_avisa_uma_vez(tmp_path):
    e = Estado(tmp_path / "e.db"); e.registrar("npad", "123", "pose", "kp", None, 65)
    assert e.atualizar("npad", "123", EstadoJob.OK) is True
    assert e.atualizar("npad", "123", EstadoJob.OK) is False
    assert e.ativos() == []
```

- [ ] **Step 2: Ver falhar**, **Step 3: Implementar**, **Step 4: Ver passar** — `uvon >/dev/null && uv run pytest src/python/tests/test_config.py src/python/tests/test_estado.py -q`.
- [ ] **Step 5: Commit** — `git commit -m "feat(py): destinos, projetos e estado local"`

### Task 4: Interface dos adaptadores

**Files:**
- Create: `src/python/fishell/adapters/__init__.py`, `src/python/fishell/adapters/base.py`, `src/python/tests/fakes.py`

**Interfaces:**
- Produces:
  - `Saida = Callable[[str], None]` (recebe uma linha de saída de cada vez).
  - `class Adaptador(Protocol)`: `nome: str`, `intervalo: float`, `capacidades: frozenset[str]` (subconjunto de `{"enviar", "trazer", "ambiente", "submeter", "cancelar", "log"}`), `listar_jobs() -> list[Job]`, `recursos() -> list[Recurso]`, `enviar(receita: Receita, saida: Saida) -> None`, `trazer(receita: Receita, saida: Saida) -> None`, `montar_ambiente(receita: Receita, saida: Saida) -> int`, `submeter(receita: Receita, particao: str | None, array: str | None, saida: Saida) -> str`, `cancelar(job_id: str) -> None`, `log(job: Job, linhas: int = 40) -> list[str]`.
  - `class Indisponivel(Exception)` com atributo `ate: datetime`; `class ErroAutenticacao(Exception)`.
  - `tests/fakes.py`: `AdaptadorFalso` configurável (jobs, recursos, exceção a levantar, atraso por chamada, chamadas registradas), usado nas Tasks 9 a 12.

Sem teste próprio: é exercitada pelas Tasks 5 a 12. Commit junto com a Task 5.

### Task 5: Conexão SSH persistente

**Files:**
- Create: `src/python/fishell/adapters/conexao.py`, `src/python/tests/test_conexao.py`

**Interfaces:**
- Consumes: `Indisponivel`, `ErroAutenticacao`, `Saida` (Task 4); `dir_estado()` (Task 3).
- Produces:
  - `@dataclass(frozen=True) Resultado(codigo: int, saida: str, erro: str)`
  - `Executor = Callable[[list[str], float, Saida | None], Resultado]`; `executar_subprocess` é o padrão (com `saida`, entrega linha a linha).
  - `class Conexao(alias: str, dir_ctl: Path, executar: Executor = executar_subprocess, agora: Callable[[], datetime] = datetime.now)`:
    - `opcoes_ssh() -> list[str]` (exatamente as opções da seção de restrições, `ControlPath=<dir_ctl>/%C`);
    - `comando(remoto: str, timeout: float = 60, saida: Saida | None = None) -> Resultado`;
    - `resolver(caminho: str) -> str` (expande `$USER` e `~` com `printf %s` no remoto, guardado em cache);
    - `rsync(origem: str, destino: str, t: Transferencia, saida: Saida | None = None) -> Resultado` (um lado prefixado `alias:`, filtros na ordem `--include` … `--exclude` …);
    - `fechar() -> None` (`ssh -O exit`).

- [ ] **Step 1: Testes que falham** (com `executar` falso que registra `argv` e devolve resultados programados)

```python
def test_toda_chamada_usa_a_mesma_conexao(...):
    c.comando("squeue"); c.rsync("a/", "npad:b/", Transferencia("a/", "b/"))
    for argv in chamadas:
        juntos = " ".join(argv)
        assert "ControlMaster=auto" in juntos and f"ControlPath={ctl}/%C" in juntos and "ControlPersist=600" in juntos

def test_rsync_nunca_apaga(...):
    argv = ...  # das duas direções, com e sem filtros
    assert argv[:2] == ["rsync", "-a"]
    assert not {"--delete", "--remove-source-files"} & set(argv)
    assert not any(a.startswith("--delete") for a in argv)

def test_recusa_bloqueia_por_30_min(...):
    # 1ª chamada: codigo 255, erro "Connection closed by remote host"
    with pytest.raises(Indisponivel) as e: c.comando("squeue")
    assert e.value.ate == T0 + timedelta(minutes=30)
    relogio.avancar(minutes=29)
    with pytest.raises(Indisponivel): c.comando("squeue")
    assert len(chamadas) == 1          # nenhuma nova tentativa no intervalo

def test_permission_denied_e_autenticacao(...):
    # codigo 255, erro "Permission denied (publickey)"
    with pytest.raises(ErroAutenticacao): c.comando("squeue")

def test_resolver_expande_uma_vez(...):
    assert c.resolver("/scratch/global/$USER/pose") == "/scratch/global/usuario/pose"
    c.resolver("/scratch/global/$USER/pose"); assert len(chamadas) == 1
```

- [ ] **Step 2: Ver falhar**, **Step 3: Implementar**, **Step 4: Ver passar** — `uvon >/dev/null && uv run pytest src/python/tests/test_conexao.py -q`.
- [ ] **Step 5: Commit** — `git add src/python && git commit -m "feat(py): conexao SSH unica com o NPAD"`

### Task 6: Leitura das saídas do SLURM

**Files:**
- Create: `src/python/fishell/adapters/slurm_saidas.py`, `src/python/tests/test_slurm_saidas.py`, `src/python/tests/fixtures/npad/sinfo.txt`, `src/python/tests/fixtures/npad/sacct.txt`, `src/python/tests/fixtures/npad/squeue_array.txt`

**Interfaces:**
- Consumes: `Job`, `Recurso`, `EstadoJob` (Task 2); `RegistroJob` (Task 3).
- Produces:
  - Formatos, como constantes: `FMT_SQUEUE = "%i|%j|%T|%M|%P|%R"`, `CAMPOS_SACCT = "JobID,JobName,State,ExitCode,Elapsed"`, `FMT_SINFO = "%R|%F"`.
  - `@dataclass(frozen=True) LinhaSqueue(job_id: str, nome: str, estado: str, decorrido: str, particao: str, motivo: str)`; `@dataclass(frozen=True) LinhaSacct(job_id: str, nome: str, estado: str, codigo_saida: str, decorrido: str)`.
  - `ler_squeue(texto: str) -> list[LinhaSqueue]`, `ler_sacct(texto: str) -> list[LinhaSacct]` (`-P`, separador `|`), `ler_sinfo(texto: str) -> list[Recurso]` (`rotulo`=partição, `livres`=I, `total`=T de `A/I/O/T`).
  - `estado_slurm(texto: str) -> EstadoJob`: `PENDING`→FILA; `RUNNING`, `COMPLETING`, `CONFIGURING`→RODANDO; `COMPLETED`→OK; `FAILED`, `TIMEOUT`, `OUT_OF_MEMORY`, `NODE_FAIL`, `BOOT_FAIL`, `PREEMPTED`→FALHOU; qualquer `CANCELLED…` (inclusive `CANCELLED by 123`)→CANCELADO; outro→DESCONHECIDO.
  - `agrupar(destino: str, fila: list[LinhaSqueue], historico: list[LinhaSacct], registros: dict[str, RegistroJob]) -> list[Job]`: uma linha por job; tarefas de array (`123_4`, `123_[5-65%16]`) viram uma linha `id="123"`. `array_ok` = tarefas `COMPLETED` no histórico; `array_total` = o do registro, senão contagem de tudo o que apareceu (faixas pendentes expandidas pelo tamanho, sem o `%K`). Estado do array: RODANDO se alguma roda; FILA se só há pendentes; senão FALHOU se alguma falhou, senão OK. Jobs sem registro saem `externo=True`.

- [ ] **Step 1: Gravar as saídas reais** (uma conexão, só leitura)

```bash
ssh npad '{ sinfo -h -o "%R|%F"; echo ===; sacct -u $USER -S 2026-09-01 -X -n -P -o JobID,JobName,State,ExitCode,Elapsed; } | sed "s/$USER/usuario/g"'
```

Separar em `sinfo.txt` e `sacct.txt`. Conferir com `. ./config.sh && grep -c "$NPAD_USER" src/python/tests/fixtures/npad/*`, que tem de dar 0 em todos (o `config.sh` é local e guarda o usuário real; o nome nunca aparece escrito no repositório). O `squeue` estava vazio em 2026-10-31, então `squeue_array.txt` é escrito à mão no formato `FMT_SQUEUE`: um array `2200000_[48-65%16]` pendente (`(JobArrayTaskLimit)`), as tarefas `2200000_45`, `_46` e `_47` rodando, um job simples `2200100` pendente (`(Resources)`).

- [ ] **Step 2: Testes que falham**

```python
def test_sinfo_real():
    r = {x.rotulo: x for x in ler_sinfo(fixture("sinfo.txt"))}
    assert r["gpu-4-a100"].total == 1 and r["amd-512"].total == 56

def test_sacct_real_tem_falha_e_sucesso(): ...  # 2121048 FALHOU, 2121060 OK

def test_array_agrupado():
    jobs = agrupar("npad", ler_squeue(fixture("squeue_array.txt")), historico_com_44_ok, {"2200000": registro(array_total=65)})
    a = next(j for j in jobs if j.id == "2200000")
    assert (a.estado, a.array_ok, a.array_total, a.externo) == (EstadoJob.RODANDO, 44, 65, False)
    assert next(j for j in jobs if j.id == "2200100").externo is True

def test_array_de_1000_tarefas_vira_uma_linha():
    fila = [LinhaSqueue("9_[11-1000%50]", "big", "PENDING", "0:00", "amd-512", "(JobArrayTaskLimit)")] + rodando(9, range(1, 11))
    jobs = agrupar("npad", fila, [], {})
    assert len(jobs) == 1 and jobs[0].array_total == 1000

@pytest.mark.parametrize("txt,esp", [("CANCELLED by 1234", EstadoJob.CANCELADO), ("OUT_OF_MEMORY", EstadoJob.FALHOU), ("COMPLETING", EstadoJob.RODANDO)])
def test_estados(txt, esp): assert estado_slurm(txt) == esp
```

- [ ] **Step 3: Ver falhar**, **Step 4: Implementar**, **Step 5: Ver passar** — `uvon >/dev/null && uv run pytest src/python/tests/test_slurm_saidas.py -q`.
- [ ] **Step 6: Commit** — `git commit -m "feat(py): leitura de squeue, sacct e sinfo"` (antes, `. ./config.sh && git diff --cached | grep -c "$NPAD_USER"` dá 0).

### Task 7: Adaptador SLURM (NPAD)

**Files:**
- Create: `src/python/fishell/adapters/slurm.py`, `src/python/tests/test_slurm.py`

**Interfaces:**
- Consumes: `Conexao`, `Resultado` (Task 5); `ler_*`, `agrupar`, formatos (Task 6); `Estado` (Task 3); `Adaptador` (Task 4).
- Produces: `class AdaptadorSlurm(nome: str, conexao: Conexao, estado: Estado)`, que implementa `Adaptador` com `intervalo=60.0` e todas as capacidades.
  - `listar_jobs`: um único `comando` que roda `squeue -h -u $USER -o '<FMT_SQUEUE>'`, um separador e `sacct -u $USER -S now-1days -X -n -P -o <CAMPOS_SACCT>`; depois `agrupar` e `estado.atualizar` para cada registro que chegou a estado terminal. A `ultima_linha` de cada job ativo com `log` conhecido vem de um `tail -n 1` de todos esses logs no mesmo comando.
  - `recursos`: `sinfo -h -o '<FMT_SINFO>'`, filtrado por `DestinoConfig.particoes` quando houver.
  - `enviar`/`trazer`: um `conexao.rsync` por `Transferencia`, origem local relativa a `receita.raiz` e destino relativo a `resolver(secao.remoto)`; antes do envio, um único `mkdir -p` com todos os destinos remotos.
  - `montar_ambiente`: `cd <remoto> && bash <ambiente>`, com a saída em fluxo; devolve o código.
  - `submeter`, modo `job`: `cd <remoto> && sbatch --parsable -p <particao> [--array=<array>] -o <remoto>/<log> <job>`. O `log` padrão é `logs/fishell_%j.out`, ou `logs/fishell_%A_%a.out` com array, e o `mkdir -p` da pasta do log vai no mesmo comando. Modo `submeter`: `cd <remoto> && bash <submeter>`, procurando o id numa linha `^fishell-job:\s*(\d+)\s*$` (sem essa linha, levanta `ErroReceita` com a saída). Nos dois modos, `estado.registrar(...)` com o log já expandido (`%j`/`%A` → id; `%a` fica para a tarefa) e o `array_total` tirado de `--array` quando houver.
  - `cancelar`: `scancel <id>`.
  - `log`: `tail -n <linhas>`, com `%a` trocado pela tarefa mais recente rodando, ou pela última concluída. Job externo: `["(log indisponível para job externo)"]`.

- [ ] **Step 1: Testes que falham** (com `Conexao` falsa que devolve as fixtures da Task 6 e registra comandos)

```python
def test_listar_jobs_usa_um_comando(...): assert len(conexao.comandos) == 1
def test_submeter_job_com_array(...):
    id_ = a.submeter(receita_job, "gpu-4-a100", "1-65%16", saida=ignorar)
    cmd = conexao.comandos[-1]
    assert "sbatch --parsable -p gpu-4-a100 --array=1-65%16 -o" in cmd and id_ == "2200000"
    assert estado.ativos()[0].array_total == 65
def test_submeter_script_le_fishell_job(...): ...      # saída "...\nfishell-job: 2200001\n" → "2200001"
def test_submeter_script_sem_linha_de_id(...): ...     # ErroReceita, mensagem contém a saída
def test_submeter_cita_caminhos(...):
    # remoto "/scratch/global/usuario/meu projeto", job "code/run's.sbatch"
    assert shlex.quote("/scratch/global/usuario/meu projeto") in conexao.comandos[-1]
def test_nenhum_comando_apaga(...):
    # roda todas as ações; nenhum comando contém "rm " nem "--delete"
def test_conclusao_atualiza_estado(...): ...           # registro 2121060 → OK, atualizar devolveu True uma vez
```

- [ ] **Step 2: Ver falhar**, **Step 3: Implementar**, **Step 4: Ver passar** — `uvon >/dev/null && uv run pytest src/python/tests/test_slurm.py -q`.
- [ ] **Step 5: Commit** — `git commit -m "feat(py): adaptador SLURM"`

### Task 8: Adaptador local

**Files:**
- Create: `src/python/fishell/adapters/local.py`, `src/python/tests/test_local.py`, `src/python/tests/fixtures/local/nvidia_smi.txt`

**Interfaces:**
- Consumes: `Estado` (Task 3), `Adaptador`, `Saida` (Task 4), `Executor`, `executar_subprocess` (Task 5).
- Produces: `class AdaptadorLocal(estado: Estado, dir_jobs: Path, executar: Executor = executar_subprocess)`, `nome="local"`, `intervalo=3.0`, capacidades `{"ambiente", "submeter", "cancelar", "log"}`.
  - `submeter`: exige `secao.comando` (a seção `[local]` da receita). O id é `l` seguido de `AAAAMMDD-HHMMSS`, e a sessão `tmux` se chama `fishell-<id>`:

    ```
    tmux new-session -d -s fishell-<id> -c <raiz> bash -c '{ <comando> ; } > <dir_jobs>/<id>.log 2>&1; echo $? > <dir_jobs>/<id>.exit'
    ```

    O comando vai literal, porque é o comando do usuário dentro de `bash -c`; os caminhos passam por `shlex.quote`. Depois, `estado.registrar`.
  - `listar_jobs`: registros do estado do destino `local` nas últimas 24 h, cruzados com `tmux list-sessions -F '#{session_name}'`. Sessão viva → RODANDO; arquivo `.exit` com 0 → OK, com outro valor → FALHOU; nenhum dos dois → DESCONHECIDO (`motivo="sessão sumiu"`, por exemplo depois de reiniciar). `ultima_linha` = última linha não vazia do log.
  - `recursos`: `nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits` → `Recurso(rotulo=<nome curto>, texto="61% 9/16G")`; sem `nvidia-smi`, lista vazia.
  - `montar_ambiente`: `bash <ambiente>` com `cwd=raiz`, com a saída em fluxo.
  - `cancelar`: `tmux kill-session -t fishell-<id>`, depois `estado.atualizar(..., CANCELADO)`.

- [ ] **Step 1: Testes que falham**

```python
def test_recursos_da_gpu(): ...                      # fixture → texto "61% 9/16G"
def test_comando_com_aspas(...):
    argv = ...  # submeter com comando `python train.py --nome "a b"` e raiz "/tmp/meu proj"
    assert argv[:5] == ["tmux", "new-session", "-d", "-s", f"fishell-{id_}"]
    assert 'python train.py --nome "a b"' in argv[-1]
@pytest.mark.skipif(shutil.which("tmux") is None, reason="sem tmux")
def test_job_real_no_tmux(tmp_path):
    id_ = a.submeter(receita(comando="echo oi"), None, None, saida=ignorar)
    espera_ate(lambda: a.listar_jobs()[0].estado == EstadoJob.OK)
    assert a.listar_jobs()[0].ultima_linha == "oi"
def test_sessao_sumida_fica_desconhecido(...): ...
```

- [ ] **Step 2: Ver falhar**, **Step 3: Implementar**, **Step 4: Ver passar** — `uvon >/dev/null && uv run pytest src/python/tests/test_local.py -q`.
- [ ] **Step 5: Commit** — `git commit -m "feat(py): adaptador local com tmux"`

### Task 9: Hub (o núcleo que as frentes usam)

**Files:**
- Create: `src/python/fishell/core/hub.py`, `src/python/fishell/core/montagem.py`, `src/python/tests/test_hub.py`

**Interfaces:**
- Consumes: Tasks 2 a 8.
- Produces:
  - `@dataclass Visao(jobs: list[Job], recursos: dict[str, list[Recurso]], avisos: dict[str, str], receitas: list[Receita])`
  - `class Hub(adaptadores: dict[str, Adaptador], estado: Estado, receitas: list[Receita], relogio: Callable[[], float] = time.monotonic, iniciar_vigia: Callable[[], None] = ...)`:
    - `atualizar(forcar: bool = False) -> Visao`: consulta só os destinos cujo `intervalo` venceu e usa o cache dos outros. Uma exceção num adaptador vira texto em `avisos[destino]`, sem afetar os demais: `Indisponivel` → "indisponível até HH:MM", `ErroAutenticacao` → "sem acesso: chave não aceita ou ssh-agent ausente". Ordem dos jobs: ativos primeiro, depois por destino e id.
    - `receita(projeto: str) -> Receita`; `enviar(projeto, destino, saida)`, `trazer(projeto, destino, saida)`, `montar_ambiente(projeto, destino, saida) -> int`, `submeter(projeto, destino, particao=None, array=None, enviar_antes=True, saida) -> str`, `cancelar(destino, job_id)`, `log(job, linhas=40) -> list[str]`. Ação que o destino não oferece levanta `ValueError` com a mensagem de `textos.py`. Depois de `submeter`, chama `iniciar_vigia()`.
  - `montar_hub(dir_cfg: Path | None = None, dir_est: Path | None = None, cwd: Path | None = None, iniciar_vigia: Callable[[], None] | None = None) -> Hub`: lê a config e monta um `AdaptadorLocal` e um `AdaptadorSlurm` por destino, com `Conexao(alias, dir_est/"ctl")`. Sem `iniciar_vigia`, não faz nada; a Task 10 liga esse parâmetro.

- [ ] **Step 1: Testes que falham** (com `AdaptadorFalso` e relógio falso)

```python
def test_respeita_intervalos(): ...                 # local 3 s, npad 60 s: em t=5 só o local foi consultado de novo
def test_adaptador_com_erro_nao_derruba_os_outros():
    v = hub(npad=AdaptadorFalso(erro=Indisponivel(ate=T0 + 30min)), local=AdaptadorFalso(jobs=[J1])).atualizar(forcar=True)
    assert v.jobs == [J1] and v.avisos["npad"].startswith("indisponível até")
def test_submeter_envia_antes_e_inicia_vigia(): ... # ordem das chamadas: enviar, submeter; vigia chamado uma vez
def test_acao_sem_capacidade(): ...                 # trazer no local → ValueError
```

- [ ] **Step 2: Ver falhar**, **Step 3: Implementar**, **Step 4: Ver passar** — `uvon >/dev/null && uv run pytest src/python/tests/test_hub.py -q`.
- [ ] **Step 5: Commit** — `git commit -m "feat(py): hub que junta os destinos"`

### Task 10: Vigia e aviso de fim de job

**Files:**
- Create: `src/python/fishell/vigia.py`, `src/python/tests/test_vigia.py`
- Modify: `src/python/fishell/cli.py` (subcomando `vigia`; a tela e o `fishell jobs` montam o hub com `iniciar_vigia=lambda: garantir_vigia(dir_estado())`)

**Interfaces:**
- Consumes: `Hub`, `montar_hub` (Task 9), `Estado` (Task 3).
- Produces:
  - `rodar_vigia(hub: Hub, estado: Estado, notificar: Callable[[str, str], None], dormir: Callable[[float], None]) -> int`. Laço: enquanto `estado.ativos()` não estiver vazio, chama `hub.atualizar()` e, para cada registro terminal ainda não notificado, envia "`<nome>` terminou: ok / falhou / cancelado" e marca como notificado. Depois dorme o menor `intervalo` entre os destinos com job ativo. `Indisponivel` dorme até `ate`. `ErroAutenticacao` notifica "vigia parou: sem acesso ao <destino>" e sai com 1. Sem ativos, sai com 0.
  - `garantir_vigia(dir_est: Path) -> None`: se `flock` não bloqueante em `dir_est/vigia.lock` estiver livre, inicia `sys.executable -m fishell vigia` com `start_new_session=True` e saída em `dir_est/vigia.log`; se estiver ocupado, não faz nada.
  - `notificar_desktop(titulo: str, corpo: str) -> None`: `notify-send -a fishell <titulo> <corpo>`; sem `notify-send`, escreve no `vigia.log`.
  - `fishell vigia`: pega o lock, monta o hub e roda `rodar_vigia`.

- [ ] **Step 1: Testes que falham**

```python
def test_notifica_uma_vez_e_sai(): ...           # job passa a OK no 2º ciclo → 1 notificação, retorno 0
def test_sem_acesso_avisa_e_para(): ...           # ErroAutenticacao → notificação "vigia parou", retorno 1
def test_indisponivel_espera_ate_liberar(): ...   # dormir chamado com (ate - agora)
def test_segundo_vigia_nao_inicia(tmp_path): ...  # lock ocupado → Popen não chamado
```

- [ ] **Step 2: Ver falhar**, **Step 3: Implementar**, **Step 4: Ver passar** — `uvon >/dev/null && uv run pytest src/python/tests/test_vigia.py -q`.
- [ ] **Step 5: Commit** — `git commit -m "feat(py): vigia avisa quando o job termina"`

### Task 11: Tela de jobs

**Files:**
- Create: `src/python/fishell/tui/__init__.py`, `src/python/fishell/tui/app.py`, `src/python/fishell/tui/app.tcss`, `src/python/tests/test_tui.py`
- Modify: `src/python/fishell/cli.py` (sem subcomando, ou com `menu`, abre a tela), `src/python/fishell/textos.py`

**Interfaces:**
- Consumes: `Hub`, `Visao` (Task 9); `Job`, `EstadoJob` (Task 2).
- Produces: `class FishellApp(App)` com `__init__(self, hub: Hub)`, como no arranjo aprovado do spec:
  - barra lateral `#destinos` (`OptionList`): "todos" e um item por destino, com o símbolo dos estados ativos (`●` rodando, `◌` fila) e uma linha de recurso abaixo; quando há aviso, o texto do aviso no lugar do recurso;
  - `#jobs` (`DataTable`) com as colunas DESTINO, PROJETO, JOB, ESTADO, TEMPO, LOG. ESTADO mostra `● 47/65 ok` em arrays, `● rodando`, `◌ fila`, `✓ ok`, `✗ falhou` ou `⊘ cancelado`; job externo leva `*` depois do nome;
  - `#log` (`RichLog`) com as últimas 40 linhas do job destacado, recarregadas quando a seleção muda e a cada atualização;
  - teclas: `tab` alterna o foco, `enter` abre o log em tela cheia (`LogScreen`, 400 linhas), `n` / `p` / `c` / `m` (Task 12), `q` sai;
  - `set_interval(1.0)` dispara `hub.atualizar()` num worker (`thread=True`, `exclusive=True` no grupo `"atualizar"`), e o resultado repinta a tela pela thread principal.

- [ ] **Step 1: Testes que falham** (`async`, com `app.run_test()` e um `Hub` montado sobre `AdaptadorFalso`)

```python
async def test_mostra_jobs_de_todos_os_destinos(): ...   # 2 destinos, 3 jobs → 3 linhas na tabela
async def test_filtrar_por_destino(): ...                # selecionar "npad" → só as linhas do npad
async def test_array_mostra_progresso(): ...             # célula ESTADO == "● 47/65 ok"
async def test_aviso_aparece_na_barra(): ...             # Indisponivel → texto "indisponível até" em #destinos
async def test_enter_abre_log(): ...                     # LogScreen ativa com as linhas do falso
```

- [ ] **Step 2: Ver falhar**, **Step 3: Implementar**, **Step 4: Ver passar** — `uvon >/dev/null && uv run pytest src/python/tests/test_tui.py -q`.
- [ ] **Step 5: Ver de verdade** — `uvon >/dev/null && uv run fishell` num terminal de 100 colunas: a tela abre, o NPAD mostra as partições e `q` sai sem erro.
- [ ] **Step 6: Commit** — `git commit -m "feat(py): tela de jobs"`

### Task 12: Ações no painel

**Files:**
- Create: `src/python/fishell/tui/acoes.py`, `src/python/tests/test_tui_acoes.py`
- Modify: `src/python/fishell/tui/app.py`, `src/python/fishell/textos.py`

**Interfaces:**
- Consumes: `FishellApp` (Task 11), métodos de ação do `Hub` (Task 9).
- Produces:
  - `class NovoJobScreen(ModalScreen)`: `Select` de projeto (só os que têm receita válida; os com erro aparecem desabilitados, com o motivo), `Select` de destino (só as seções da receita), `Select` de partição (partições do `sinfo` com "livres I/T"; padrão = `secao.particao`; só para slurm), `Input` de array (só no modo `job`, validado por `^\d+-\d+(%\d+)?$`), `Checkbox` "enviar antes" (marcado, só se o destino tem `enviar`). Botões: Enviar, Montar ambiente, Submeter, Trazer, Fechar, mas só aparecem os que o destino escolhido declara em `capacidades`; o `local`, por exemplo, não mostra Enviar nem Trazer. A saída corre num `RichLog` dentro do modal, e cada ação roda num worker `thread=True`.
  - `n` abre o `NovoJobScreen`; `m` abre o mesmo modal já no projeto do job destacado; `p` traz os resultados do projeto e destino do job destacado (sem receita: aviso "job externo, sem receita"); `c` abre `ConfirmarScreen("Cancelar <nome> em <destino>?")` e só cancela com "sim".

- [ ] **Step 1: Testes que falham**

```python
async def test_submeter_pelo_modal(): ...          # escolhe projeto/destino/partição, array "1-65%16" → hub.submeter(..., "gpu-4-a100", "1-65%16", enviar_antes=True)
async def test_array_invalido_bloqueia(): ...      # "65" → mensagem de erro, submeter não chamado
async def test_cancelar_pede_confirmacao(): ...    # "não" → cancelar não chamado; "sim" → chamado uma vez
async def test_enviar_longo_nao_bloqueia_atualizacao():
    # AdaptadorFalso.enviar dorme 3 s; durante o envio, pilot.pause(2.5) → hub.atualizar foi chamado de novo
```

- [ ] **Step 2: Ver falhar**, **Step 3: Implementar**, **Step 4: Ver passar** — `uvon >/dev/null && uv run pytest src/python/tests/test_tui_acoes.py -q`.
- [ ] **Step 5: Commit** — `git commit -m "feat(py): enviar, montar ambiente, submeter, trazer e cancelar no painel"`

### Task 13: `fishell jobs` e teste de ponta a ponta no NPAD

**Files:**
- Modify: `src/python/fishell/cli.py`, `src/python/tests/test_cli.py`

**Interfaces:**
- Consumes: `montar_hub`, `Visao` (Task 9).
- Produces: `fishell jobs` imprime a mesma tabela da tela em texto puro, com colunas separadas por dois espaços, e depois uma linha `aviso <destino>: <texto>` para cada aviso. Retorna 0 mesmo com avisos.

- [ ] **Step 1: Teste que falha** — `test_jobs_em_texto`, com `montar_hub` trocado por um hub falso: cabeçalho, linhas e uma linha de aviso.
- [ ] **Step 2: Ver falhar**, **Step 3: Implementar**, **Step 4: Ver passar** — `uvon >/dev/null && uv run pytest -q` (a suíte inteira).
- [ ] **Step 5: Ponta a ponta real** (um job de CPU de 1 minuto; tudo pela conexão única)

Numa pasta temporária fora do repositório, criar um `fishell.toml` com `[npad] remoto="/scratch/global/$USER/fishell-teste"`, `enviar=["job.sbatch -> ./"]`, `trazer=["saida/"]`, `job="job.sbatch"` e `particao="intel-128"`. O `job.sbatch` pede `--time=00:01:00`, roda `hostname` e grava `saida/ok.txt`. Pelo painel: `n` → Submeter com "enviar antes" → a linha aparece em `◌ fila` / `● rodando` → `✓ ok` → `p` traz `saida/ok.txt`. Fechar o painel durante a execução e confirmar que o `notify-send` chegou. Ao final, `fishell jobs` mostra o job como `✓ ok`.

Expected: `saida/ok.txt` local com o nome do nó, e uma notificação. A pasta remota de teste fica no scratch; o fishell não apaga. Avisar o autor para apagá-la, se quiser.

- [ ] **Step 6: Commit** — `git commit -m "feat(py): fishell jobs em texto"`

### Task 14: Documentação

**Files:**
- Modify: `README.md`, `docs/desenvolvimento.md`, `CLAUDE.md` (local, fora do git), `~/work/github-projects/CLAUDE.md` (fora deste repositório)

- [ ] **Step 1: `README.md`** — seção nova `## 7. Painel de jobs (versão Python, só Linux)` antes de "Problemas comuns": o que é, `uv tool install` a partir do clone, a tela (um bloco de texto como o do spec, com `usuario`), um `fishell.toml` de exemplo e os subcomandos `fishell` e `fishell jobs`. As partes 1 a 6 não mudam. Sem mencionar o Claude (regra dos READMEs).
- [ ] **Step 2: `docs/desenvolvimento.md`** — seção `## Versão Python`: estrutura das pastas, as camadas (núcleo, adaptadores, frentes), a interface `Adaptador`, como acrescentar um destino, o formato completo da receita (incluindo `submeter` + `fishell-job:` + `log`), as regras inegociáveis (conexão única, 30 min depois de recusa, nada de apagar no remoto), como rodar os testes e regravar as fixtures sem o usuário real.
- [ ] **Step 3: `CLAUDE.md` local** — a tabela "Dois ports" ganha a versão Python como terceira implementação, fora da paridade; seção nova com comandos (`uvon >/dev/null && uv run pytest -q`, `uv run fishell`), o link `.venv` e as mesmas regras inegociáveis.
- [ ] **Step 4: `~/work/github-projects/CLAUDE.md`** — na linha do fishell em *Misc / data / utilities*, mencionar a versão Python (painel de jobs NPAD e local). Acrescentar o fishell à lista "`pyproject.toml` **with** `uv.lock`", à lista de suítes de teste (que passa a ter onze, com a nota de que os `test_*.py` em `.github/scripts/` continuam sendo checks) e aos links `.venv` (`fishell → uv-fishell`).
- [ ] **Step 5: Conferir** — `git status` sem arquivos sensíveis; `. ./config.sh && grep -rn "$NPAD_USER" README.md docs src/python` vazio.
- [ ] **Step 6: Commit** — `git add README.md docs/desenvolvimento.md && git commit -m "docs: painel de jobs da versao Python"` (o `CLAUDE.md` local e o da pasta `github-projects` ficam fora do commit).
