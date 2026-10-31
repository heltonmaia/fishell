import fcntl
import subprocess
from datetime import datetime, timedelta

from fishell import cli, vigia
from fishell.adapters.base import ErroAutenticacao, Indisponivel
from fishell.core.estado import Estado
from fishell.core.hub import Hub
from fishell.core.modelos import EstadoJob, Job
from tests.fakes import AdaptadorFalso


class Falso(AdaptadorFalso):
    """Adaptador que grava no Estado o que listar_jobs devolve."""

    def __init__(self, estado, **kw):
        super().__init__(**kw)
        self.estado = estado
        self.novo = None

    def listar_jobs(self):
        if self.novo is not None:
            self.estado.atualizar(self.nome, "1", self.novo)
        return super().listar_jobs()




def test_notifica_uma_vez_e_sai(tmp_path):
    estado = Estado(tmp_path / "e.db")
    estado.registrar("local", "1", "p", "treino", None, None)
    ad = Falso(estado, nome="local", intervalo=3)
    t = [0.0]
    hub = Hub({"local": ad}, estado, [], relogio=lambda: t[0])
    avisos, sonos = [], []

    def dormir(s):
        sonos.append(s)
        t[0] += s
        ad.novo = EstadoJob.OK

    assert vigia.rodar_vigia(hub, estado, lambda a, b: avisos.append((a, b)), dormir) == 0
    assert avisos == [("fishell", "treino terminou: ok")]
    assert sonos == [3]
    assert estado.pendentes_de_aviso() == []


def test_sem_acesso_avisa_e_para(tmp_path):
    estado = Estado(tmp_path / "e.db")
    estado.registrar("npad", "1", "p", "treino", None, None)
    hub = Hub({"npad": AdaptadorFalso("npad", erro=ErroAutenticacao())}, estado, [])
    avisos = []
    code = vigia.rodar_vigia(hub, estado, lambda a, b: avisos.append((a, b)), lambda s: None)
    assert code == 1
    assert avisos == [("fishell", "vigia parou: sem acesso ao npad")]


def test_indisponivel_espera_ate_liberar(tmp_path):
    estado = Estado(tmp_path / "e.db")
    estado.registrar("npad", "1", "p", "treino", None, None)
    ate = datetime.now() + timedelta(minutes=30)
    ad = AdaptadorFalso("npad", erro=Indisponivel(ate), intervalo=60)
    hub = Hub({"npad": ad}, estado, [])
    sonos = []

    def dormir(s):
        sonos.append(s)
        estado.atualizar("npad", "1", EstadoJob.OK)

    vigia.rodar_vigia(hub, estado, lambda a, b: None, dormir)
    assert len(sonos) == 1
    assert abs(sonos[0] - 1800) < 5


def test_segundo_vigia_nao_inicia(tmp_path, monkeypatch):
    chamadas = []
    monkeypatch.setattr(subprocess, "Popen", lambda *a, **k: chamadas.append((a, k)))
    with open(tmp_path / "vigia.lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        vigia.garantir_vigia(tmp_path)
    assert chamadas == []


def test_vigia_livre_inicia_destacado(tmp_path, monkeypatch):
    chamadas = []
    monkeypatch.setattr(subprocess, "Popen", lambda *a, **k: chamadas.append((a, k)))
    vigia.garantir_vigia(tmp_path)
    (args,), kw = chamadas[0]
    assert args[-2:] == ["fishell", "vigia"] and args[1] == "-m"
    assert kw["start_new_session"] is True
    assert kw["stdin"] == subprocess.DEVNULL


def test_notificar_sem_notify_send_grava_no_log(tmp_path, monkeypatch):
    monkeypatch.setenv("FISHELL_STATE_DIR", str(tmp_path))
    monkeypatch.setattr("shutil.which", lambda _: None)
    vigia.notificar_desktop("fishell", "x terminou: ok")
    assert "x terminou: ok" in (tmp_path / "vigia.log").read_text()


def test_notificar_usa_notify_send(monkeypatch):
    chamadas = []
    monkeypatch.setattr("shutil.which", lambda _: "/usr/bin/notify-send")
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: chamadas.append(a[0]))
    vigia.notificar_desktop("t", "c")
    assert chamadas == [["notify-send", "-a", "fishell", "t", "c"]]


def test_subcomando_vigia_com_lock_ocupado_sai_0(tmp_path, monkeypatch):
    monkeypatch.setenv("FISHELL_STATE_DIR", str(tmp_path))
    with open(tmp_path / "vigia.lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert cli.main(["vigia"]) == 0


def test_cli_hub_passa_garantir_vigia(tmp_path, monkeypatch):
    monkeypatch.setenv("FISHELL_STATE_DIR", str(tmp_path / "est"))
    monkeypatch.setenv("FISHELL_CONFIG_DIR", str(tmp_path / "cfg"))
    chamadas = []
    monkeypatch.setattr(vigia, "garantir_vigia", lambda d: chamadas.append(d))
    h = cli._hub()
    h._iniciar_vigia()
    assert chamadas == [tmp_path / "est"]


AGORA = datetime(2026, 10, 31, 12, 0)


def _dormida(tmp_path, destinos):
    """Roda um ciclo com destinos {nome: (intervalo, ate|None)} e devolve a espera pedida."""
    estado = Estado(tmp_path / "e.db")
    ads = {}
    for nome, (intervalo, ate) in destinos.items():
        estado.registrar(nome, "1", "p", "n", None, None)
        ads[nome] = AdaptadorFalso(
            nome, intervalo=intervalo, erro=Indisponivel(ate) if ate else None
        )
    hub = Hub(ads, estado, [])
    sonos = []

    def dormir(s):
        sonos.append(s)
        for nome in destinos:
            estado.atualizar(nome, "1", EstadoJob.OK)

    vigia.rodar_vigia(hub, estado, lambda a, b: None, dormir, agora=lambda: AGORA)
    return sonos[0]


def test_ate_no_passado_dorme_o_intervalo(tmp_path):
    assert _dormida(tmp_path, {"npad": (60, AGORA - timedelta(minutes=1))}) == 60


def test_indisponivel_nao_atrasa_outro_destino(tmp_path):
    espera = _dormida(
        tmp_path,
        {"npad": (60, AGORA + timedelta(minutes=30)), "local": (3, None)},
    )
    assert espera == 3


def test_espera_minima_de_um_segundo(tmp_path):
    assert _dormida(tmp_path, {"npad": (60, AGORA + timedelta(seconds=0.5))}) == 1
