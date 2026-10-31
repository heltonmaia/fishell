import shlex
from pathlib import Path

import pytest

from fishell.adapters.conexao import Resultado
from fishell.adapters.slurm import (
    LOG_EXTERNO,
    MARCA_LOG,
    SEP_ANTIGOS,
    SEP_LOGS,
    SEP_SACCT,
    AdaptadorSlurm,
)
from fishell.core.estado import Estado
from fishell.core.modelos import (
    ErroReceita,
    EstadoJob,
    Job,
    Receita,
    SecaoReceita,
    Transferencia,
)

FIXTURES = Path(__file__).parent / "fixtures" / "npad"


def fixture(nome):
    return (FIXTURES / nome).read_text(encoding="utf-8")


def ignorar(_linha):
    pass


class ConexaoFalsa:
    alias = "npad"

    def __init__(self):
        self.comandos = []
        self.sinks = []
        self.rsyncs = []
        self.respostas = []  # fila de Resultado
        self.padrao = Resultado(0, "", "")

    def comando(self, remoto, timeout=60, saida=None):
        self.comandos.append(remoto)
        self.sinks.append(saida)
        return self.respostas.pop(0) if self.respostas else self.padrao

    def resolver(self, caminho):
        return caminho.replace("$USER", "usuario").replace("~", "/home/usuario")

    def rsync(self, origem, destino, t, saida=None):
        self.rsyncs.append((origem, destino, t, saida))
        return Resultado(0, "", "")


def secao(**kw):
    base = dict(
        destino="npad", remoto="/scratch/global/$USER/pose", enviar=(), trazer=(),
        ambiente=None, job=None, submeter=None, comando=None,
        particao="amd-512", log=None,
    )
    base.update(kw)
    return SecaoReceita(**base)


def receita(**kw):
    return Receita(Path("/proj"), "pose", {"npad": secao(**kw)})


@pytest.fixture
def conexao():
    return ConexaoFalsa()


@pytest.fixture
def estado(tmp_path):
    return Estado(tmp_path / "estado.db")


@pytest.fixture
def adaptador(conexao, estado):
    return AdaptadorSlurm("npad", conexao, estado)


def saida_lista(squeue="", sacct="", logs="", antigos=""):
    return Resultado(
        0, f"{squeue}\n{SEP_SACCT}\n{sacct}\n{SEP_ANTIGOS}\n{antigos}\n{SEP_LOGS}\n{logs}", ""
    )


def test_listar_jobs_usa_um_comando(adaptador, conexao):
    conexao.respostas.append(
        saida_lista(fixture("squeue_array.txt"), fixture("sacct.txt"))
    )
    jobs = adaptador.listar_jobs()
    assert len(conexao.comandos) == 1
    assert conexao.sinks == [None]
    cmd = conexao.comandos[0]
    assert "squeue -h -u" in cmd and "sacct -u" in cmd and SEP_SACCT in cmd
    assert {j.id for j in jobs} >= {"2200000", "2121060"}
    assert all(j.externo for j in jobs)


def test_ultima_linha_vem_do_tail(adaptador, conexao, estado):
    estado.registrar("npad", "2200100", "pose", "infer", "/l/a b/infer_2200100.out", None)
    estado.registrar("npad", "2200000", "pose", "treino", None, None)
    conexao.respostas.append(
        saida_lista(
            fixture("squeue_array.txt"), "",
            f"{MARCA_LOG}2200100\nepoca 3 loss 0.2\n",
        )
    )
    jobs = {j.id: j for j in adaptador.listar_jobs()}
    cmd = conexao.comandos[0]
    assert cmd.count("tail -n 1") == 1
    assert shlex.quote("/l/a b/infer_2200100.out") in cmd and "2>/dev/null" in cmd
    assert jobs["2200100"].ultima_linha == "epoca 3 loss 0.2"
    assert jobs["2200000"].ultima_linha == ""


def test_tail_de_log_com_tarefa_usa_o_mais_recente(adaptador, conexao, estado):
    estado.registrar("npad", "2200000", "pose", "treino", "/l/t_2200000_%a.out", 65)
    conexao.respostas.append(saida_lista(fixture("squeue_array.txt"), "", ""))
    adaptador.listar_jobs()
    assert "ls -t" in conexao.comandos[0]


def test_recursos_filtra_particoes(conexao, estado):
    conexao.respostas.append(Resultado(0, fixture("sinfo.txt"), ""))
    a = AdaptadorSlurm("npad", conexao, estado, particoes=("gpu-4-a100", "amd-512"))
    assert {r.rotulo for r in a.recursos()} == {"gpu-4-a100", "amd-512"}
    assert conexao.comandos[0].startswith("sinfo -h -o")


def test_recursos_sem_filtro(adaptador, conexao):
    conexao.respostas.append(Resultado(0, fixture("sinfo.txt"), ""))
    assert len(adaptador.recursos()) == 10


def test_enviar_faz_mkdir_unico_e_um_rsync_por_transferencia(adaptador, conexao):
    r = receita(enviar=(
        Transferencia("code/", "code/", excluir=(".git",)),
        Transferencia("data/x.csv", "data/x.csv"),
    ))
    adaptador.enviar(r, ignorar)
    assert len(conexao.comandos) == 1
    assert conexao.comandos[0].startswith("mkdir -p ")
    assert "/scratch/global/usuario/pose/code/" in conexao.comandos[0]
    assert "/scratch/global/usuario/pose/data" in conexao.comandos[0]
    assert len(conexao.rsyncs) == 2
    origem, destino, t, saida = conexao.rsyncs[0]
    assert origem == "/proj/code/"
    assert destino == "npad:/scratch/global/usuario/pose/code/"
    assert saida is ignorar


def test_enviar_remoto_com_espaco_sem_aspas_no_rsync(adaptador, conexao):
    r = receita(remoto="/scratch/global/usuario/meu projeto",
                enviar=(Transferencia("meus dados/", "dados/"),))
    adaptador.enviar(r, ignorar)
    assert shlex.quote("/scratch/global/usuario/meu projeto/dados/") in conexao.comandos[0]
    assert conexao.rsyncs[0][1] == "npad:/scratch/global/usuario/meu projeto/dados/"


def test_trazer_remoto_com_espaco_sem_aspas_no_rsync(adaptador, conexao, tmp_path):
    r = Receita(tmp_path, "pose", {"npad": secao(
        remoto="/scratch/global/usuario/meu projeto",
        trazer=(Transferencia("meus dados/", "dados/"),))})
    adaptador.trazer(r, ignorar)
    assert conexao.rsyncs[0][0] == "npad:/scratch/global/usuario/meu projeto/meus dados/"


def test_trazer_inverte_origem_e_destino(adaptador, conexao, tmp_path):
    r = Receita(tmp_path, "pose", {"npad": secao(trazer=(Transferencia("out/", "resultados/"),))})
    adaptador.trazer(r, ignorar)
    origem, destino, _, _ = conexao.rsyncs[0]
    assert origem == "npad:/scratch/global/usuario/pose/out/"
    assert destino == f"{tmp_path}/resultados/"
    assert (tmp_path / "resultados").is_dir()


def test_montar_ambiente_em_fluxo(adaptador, conexao):
    conexao.respostas.append(Resultado(3, "", ""))
    codigo = adaptador.montar_ambiente(receita(ambiente="setup.sh"), ignorar)
    assert codigo == 3
    assert conexao.comandos[-1] == (
        "{ cd /scratch/global/usuario/pose && bash setup.sh; } 2>&1; "
        'e=$?; [ "$e" -eq 255 ] && e=254; exit "$e"'
    )
    assert conexao.sinks[-1] is ignorar


def test_submeter_job_com_array(adaptador, conexao, estado):
    conexao.respostas.append(Resultado(0, "2200000\n", ""))
    r = receita(job="train.sbatch", log="logs/fishell_%A_%a.out")
    id_ = adaptador.submeter(r, "gpu-4-a100", "1-65%16", ignorar)
    cmd = conexao.comandos[-1]
    assert "sbatch --parsable -p gpu-4-a100 --array=1-65%16 -o" in cmd and id_ == "2200000"
    assert "logs/fishell_%A_%a.out" in cmd and "mkdir -p /scratch/global/usuario/pose/logs" in cmd
    assert conexao.sinks[-1] is None
    reg = estado.ativos()[0]
    assert reg.array_total == 65
    assert reg.log == "/scratch/global/usuario/pose/logs/fishell_2200000_%a.out"
    assert reg.projeto == "pose" and reg.nome == "train"


def test_submeter_job_simples_expande_o_log(adaptador, conexao, estado):
    conexao.respostas.append(Resultado(0, "77;npad\n", ""))
    r = receita(job="t.sbatch", log="logs/fishell_%j.out")
    assert adaptador.submeter(r, None, None, ignorar) == "77"
    assert "-p amd-512" in conexao.comandos[-1] and "--array" not in conexao.comandos[-1]
    assert estado.ativos()[0].log == "/scratch/global/usuario/pose/logs/fishell_77.out"
    assert estado.ativos()[0].array_total is None


def test_submeter_script_le_fishell_job(adaptador, conexao, estado):
    conexao.respostas.append(Resultado(0, "montando\nfishell-job: 2200001\nfim", ""))
    id_ = adaptador.submeter(receita(submeter="go.sh"), None, None, ignorar)
    assert id_ == "2200001"
    assert conexao.comandos[-1].startswith(
        "{ cd /scratch/global/usuario/pose && bash go.sh; } 2>&1; "
    )
    assert conexao.sinks[-1] is ignorar
    assert estado.ativos()[0].job_id == "2200001"


def test_submeter_script_sem_linha_de_id(adaptador, conexao, estado):
    conexao.respostas.append(Resultado(0, "nada util aqui", ""))
    with pytest.raises(ErroReceita, match="nada util aqui"):
        adaptador.submeter(receita(submeter="go.sh"), None, None, ignorar)
    assert estado.ativos() == []


def test_submeter_cita_caminhos(adaptador, conexao):
    conexao.respostas.append(Resultado(0, "5", ""))
    r = receita(remoto="/scratch/global/usuario/meu projeto", job="code/run's.sbatch")
    adaptador.submeter(r, "amd-512", None, ignorar)
    cmd = conexao.comandos[-1]
    assert shlex.quote("/scratch/global/usuario/meu projeto") in cmd
    assert shlex.quote("code/run's.sbatch") in cmd


def test_receita_sem_secao_do_destino(adaptador):
    r = Receita(Path("/proj"), "pose", {})
    with pytest.raises(ErroReceita, match="npad"):
        adaptador.submeter(r, None, None, ignorar)


def test_cancelar(adaptador, conexao):
    adaptador.cancelar("2200000")
    assert conexao.comandos[-1] == "scancel 2200000"


def test_log_externo(adaptador):
    j = Job("npad", "1", "x", EstadoJob.RODANDO, externo=True)
    assert adaptador.log(j) == [LOG_EXTERNO]


def test_log_simples(adaptador, conexao):
    conexao.respostas.append(Resultado(0, "a\nb\n", ""))
    j = Job("npad", "9", "x", EstadoJob.RODANDO, log="/l/a b.out")
    assert adaptador.log(j, 10) == ["a", "b"]
    assert conexao.comandos[-1] == f"tail -n 10 -- {shlex.quote('/l/a b.out')}"


def test_log_de_array_usa_a_tarefa_rodando_mais_recente(adaptador, conexao):
    conexao.respostas.append(
        Resultado(0, f"{fixture('squeue_array.txt')}\n{SEP_SACCT}\n", "")
    )
    conexao.respostas.append(Resultado(0, "linha", ""))
    j = Job("npad", "2200000", "treino", EstadoJob.RODANDO, log="/l/t_2200000_%a.out")
    assert adaptador.log(j) == ["linha"]
    assert conexao.comandos[-1].endswith("/l/t_2200000_47.out")


def test_log_de_array_sem_rodando_usa_a_ultima_concluida(adaptador, conexao):
    sacct = "5_1|x|COMPLETED|0:0|00:01:00\n5_3|x|COMPLETED|0:0|00:01:00\n5_2|x|FAILED|1:0|00:01:00"
    conexao.respostas.append(Resultado(0, f"\n{SEP_SACCT}\n{sacct}", ""))
    conexao.respostas.append(Resultado(0, "z", ""))
    j = Job("npad", "5", "x", EstadoJob.OK, log="/l/x_5_%a.out")
    adaptador.log(j)
    assert conexao.comandos[-1].endswith("/l/x_5_3.out")


def test_nenhum_comando_apaga(adaptador, conexao, estado, tmp_path):
    r = Receita(tmp_path, "pose", {"npad": secao(
        enviar=(Transferencia("a/", "a/"),), trazer=(Transferencia("o/", "o/"),),
        ambiente="s.sh", job="j.sbatch",
    )})
    conexao.respostas = [
        Resultado(0, "", ""), Resultado(0, "", ""),
        Resultado(0, "10", ""), Resultado(0, "", ""),
        saida_lista(fixture("squeue_array.txt"), fixture("sacct.txt")),
        Resultado(0, fixture("sinfo.txt"), ""),
    ]
    adaptador.enviar(r, ignorar)
    adaptador.trazer(r, ignorar)
    adaptador.montar_ambiente(r, ignorar)
    adaptador.submeter(r, None, "1-3", ignorar)
    adaptador.cancelar("10")
    adaptador.listar_jobs()
    adaptador.recursos()
    adaptador.log(Job("npad", "10", "j", EstadoJob.OK, log="/l/x.out"))
    textos = [*conexao.comandos] + [
        f"{o} {d} {' '.join(t.incluir + t.excluir)}" for o, d, t, _ in conexao.rsyncs
    ]
    for c in textos:
        assert "rm " not in c and "--delete" not in c and "--remove-source-files" not in c


def test_conclusao_atualiza_estado(adaptador, conexao, estado):
    estado.registrar("npad", "2121060", "pose", "desenhos", "/l/x.out", None)
    conexao.respostas = [
        saida_lista("", fixture("sacct.txt")),
        saida_lista("", fixture("sacct.txt")),
    ]
    jobs = {j.id: j for j in adaptador.listar_jobs()}
    assert jobs["2121060"].estado == EstadoJob.OK
    assert estado.ativos() == []
    assert estado.atualizar("npad", "2121060", EstadoJob.OK) is False


# --- F1: job registrado que terminou sem ser visto --------------------
def test_job_fora_da_fila_e_da_janela_e_resolvido_sem_janela(adaptador, conexao, estado):
    estado.registrar("npad", "1900000", "pose", "antigo", None, None)
    conexao.respostas.append(
        saida_lista(
            fixture("squeue_array.txt"), fixture("sacct.txt"),
            antigos="1900000|antigo|COMPLETED|0:0|30:00:00",
        )
    )
    jobs = {j.id: j for j in adaptador.listar_jobs()}
    assert len(conexao.comandos) == 1
    cmd = conexao.comandos[0]
    assert "sacct -j" in cmd and "1900000" in cmd
    trecho = cmd[cmd.index(SEP_ANTIGOS):cmd.index(SEP_LOGS)]
    assert "now-1days" not in trecho
    assert jobs["1900000"].estado == EstadoJob.OK
    assert jobs["1900000"].externo is False
    assert estado.ativos() == []


def test_sem_job_registrado_nao_consulta_sem_janela(adaptador, conexao):
    conexao.respostas.append(saida_lista(fixture("squeue_array.txt"), fixture("sacct.txt")))
    adaptador.listar_jobs()
    assert "sacct -j" not in conexao.comandos[0]


def test_consulta_sem_janela_so_pede_os_que_sairam_da_fila(tmp_path, adaptador, conexao, estado):
    """Roda o comando de verdade num bash local, com squeue e sacct falsos."""
    import os
    import stat
    import subprocess

    bin_ = tmp_path / "bin"
    bin_.mkdir()
    registro = tmp_path / "sacct.args"
    fila = fixture("squeue_array.txt")
    (bin_ / "squeue").write_text(f"#!/bin/sh\ncat <<'FIM'\n{fila}FIM\n")
    (bin_ / "sacct").write_text(
        f"#!/bin/sh\necho \"$*\" >> {registro}\n"
        "case \"$*\" in *-j*) echo '1900000|antigo|TIMEOUT|0:0|48:00:00';; esac\n"
    )
    for f in ("squeue", "sacct"):
        (bin_ / f).chmod((bin_ / f).stat().st_mode | stat.S_IEXEC)
    for id_ in ("2200000", "2200100", "1900000"):
        estado.registrar("npad", id_, "pose", "j" + id_, None, None)
    conexao.respostas.append(saida_lista())
    adaptador.listar_jobs()
    env = dict(os.environ, PATH=f"{bin_}:{os.environ['PATH']}", USER="usuario")
    r = subprocess.run(["bash", "-c", conexao.comandos[0]], capture_output=True, text=True, env=env)
    chamadas = registro.read_text().splitlines()
    sem_janela = [c for c in chamadas if "-j" in c.split()]
    assert len(sem_janela) == 1
    assert "1900000" in sem_janela[0]
    assert "2200000" not in sem_janela[0] and "2200100" not in sem_janela[0]
    assert "-S" not in sem_janela[0].split()
    _, _, resto = r.stdout.partition(SEP_ANTIGOS)
    assert "1900000|antigo|TIMEOUT" in resto.partition(SEP_LOGS)[0]


# --- F4: saída de erro do script e código 255 --------------------------
def _conexao_local(tmp_path):
    """Conexão de verdade cujo "ssh" roda o comando remoto num bash local."""
    from fishell.adapters.conexao import Conexao, executar_subprocess

    chamadas = []

    def executar(argv, timeout, saida):
        chamadas.append(argv)
        if argv[0] == "ssh" and "-O" not in argv:
            return executar_subprocess(["bash", "-c", argv[-1]], timeout, saida)
        return Resultado(0, "", "")

    return Conexao("npad", tmp_path / "ctl", executar), chamadas


def _projeto_com_script(tmp_path, nome, corpo, **kw):
    raiz = tmp_path / "proj"
    raiz.mkdir(exist_ok=True)
    (raiz / nome).write_text(corpo)
    return Receita(raiz, "pose", {"npad": secao(remoto=str(raiz), **kw)})


def test_script_com_stderr_e_saida_255_nao_bloqueia_o_destino(tmp_path, estado):
    c, chamadas = _conexao_local(tmp_path)
    a = AdaptadorSlurm("npad", c, estado)
    r = _projeto_com_script(
        tmp_path, "setup.sh", "echo para-stdout\necho para-stderr >&2\nexit 255\n",
        ambiente="setup.sh",
    )
    linhas = []
    assert a.montar_ambiente(r, linhas.append) == 254
    assert linhas == ["para-stdout", "para-stderr"]
    n = len(chamadas)
    assert c.comando("true").codigo == 0  # sem bloqueio
    assert len(chamadas) == n + 1
    assert not (tmp_path / "ctl" / "npad.bloqueio").exists()


def test_submeter_script_que_falha_traz_a_saida_no_erro(tmp_path, estado):
    c, _ = _conexao_local(tmp_path)
    a = AdaptadorSlurm("npad", c, estado)
    r = _projeto_com_script(
        tmp_path, "go.sh",
        "echo preparando\necho 'sbatch: error: invalid partition specified: xyz' >&2\nexit 1\n",
        submeter="go.sh", log="l.out",
    )
    linhas = []
    with pytest.raises(ErroReceita) as e:
        a.submeter(r, None, None, linhas.append)
    assert "invalid partition specified" in str(e.value)
    assert "preparando" in str(e.value)
    assert "sbatch: error: invalid partition specified: xyz" in linhas
    assert estado.ativos() == []


# --- F8: a saída do próprio projeto vale ------------------------------
BASE = "/scratch/global/usuario/pose"


def _com_sbatch(tmp_path, caminho, corpo, **kw):
    arq = tmp_path / caminho
    arq.parent.mkdir(parents=True, exist_ok=True)
    arq.write_text(corpo)
    return Receita(tmp_path, "pose", {"npad": secao(**kw)})


def test_log_da_receita_passa_o_o(adaptador, conexao, estado, tmp_path):
    r = _com_sbatch(tmp_path, "t.sbatch", "#!/bin/bash\n#SBATCH --output=nao/%j.out\n",
                    job="t.sbatch", log="logs/meu_%j.out")
    conexao.respostas.append(Resultado(0, "77\n", ""))
    adaptador.submeter(r, None, None, ignorar)
    cmd = conexao.comandos[-1]
    assert f"-o {BASE}/logs/meu_%j.out" in cmd
    assert f"mkdir -p {BASE}/logs" in cmd
    assert estado.ativos()[0].log == f"{BASE}/logs/meu_77.out"


def test_sem_log_na_receita_vale_o_output_do_sbatch(adaptador, conexao, estado, tmp_path):
    corpo = (
        "#!/bin/bash\n"
        "#SBATCH --partition=amd-512     # onde rodar\n"
        "#SBATCH -J treino\n"
        "#SBATCH --output=saidas/%x_%j.out   # log do projeto\n"
        "\n"
        "python treino.py\n"
        "#SBATCH --output=ignorado.out\n"
    )
    r = _com_sbatch(tmp_path, "code/t.sbatch", corpo, job="code/t.sbatch")
    conexao.respostas.append(Resultado(0, "77\n", ""))
    adaptador.submeter(r, None, None, ignorar)
    cmd = conexao.comandos[-1]
    assert " -o " not in cmd and "mkdir" not in cmd
    assert cmd == f"cd {BASE} && sbatch --parsable -p amd-512 code/t.sbatch"
    assert estado.ativos()[0].log == f"{BASE}/saidas/treino_77.out"


def test_output_absoluto_e_array(adaptador, conexao, estado, tmp_path):
    corpo = "#!/bin/bash\n#SBATCH -o /scratch/global/usuario/logs/r_%A_%a.out\n"
    r = _com_sbatch(tmp_path, "t.sbatch", corpo, job="t.sbatch")
    conexao.respostas.append(Resultado(0, "9\n", ""))
    adaptador.submeter(r, None, "1-4", ignorar)
    assert estado.ativos()[0].log == "/scratch/global/usuario/logs/r_9_%a.out"


def test_sbatch_achado_pelo_mapa_do_enviar(adaptador, conexao, estado, tmp_path):
    r = _com_sbatch(
        tmp_path, "scripts/npad/x.sbatch", "#!/bin/bash\n#SBATCH -oout/%x-%j.log\n",
        job="code/npad/x.sbatch", enviar=(Transferencia("scripts/", "code/"),),
    )
    conexao.respostas.append(Resultado(0, "5\n", ""))
    adaptador.submeter(r, None, None, ignorar)
    assert estado.ativos()[0].log == f"{BASE}/out/x.sbatch-5.log"


def test_chdir_muda_a_pasta_do_output_relativo(adaptador, conexao, estado, tmp_path):
    corpo = "#!/bin/bash\n#SBATCH --chdir=run\n#SBATCH --output out.txt\n"
    r = _com_sbatch(tmp_path, "t.sbatch", corpo, job="t.sbatch")
    conexao.respostas.append(Resultado(0, "6\n", ""))
    adaptador.submeter(r, None, None, ignorar)
    assert estado.ativos()[0].log == f"{BASE}/run/out.txt"


def test_sem_output_vale_o_padrao_do_slurm(adaptador, conexao, estado, tmp_path):
    r = _com_sbatch(tmp_path, "t.sbatch", "#!/bin/bash\n#SBATCH -p amd-512\necho oi\n",
                    job="t.sbatch")
    conexao.respostas += [Resultado(0, "7\n", ""), Resultado(0, "8\n", "")]
    adaptador.submeter(r, None, None, ignorar)
    adaptador.submeter(r, None, "1-3", ignorar)
    logs = {x.job_id: x.log for x in estado.ativos()}
    assert logs == {"7": f"{BASE}/slurm-7.out", "8": f"{BASE}/slurm-8_%a.out"}
    assert all(" -o " not in c for c in conexao.comandos)


def test_sbatch_ausente_no_local_vale_o_padrao(adaptador, conexao, estado):
    conexao.respostas.append(Resultado(0, "3\n", ""))
    adaptador.submeter(receita(job="sumiu.sbatch"), None, None, ignorar)
    assert estado.ativos()[0].log == f"{BASE}/slurm-3.out"
