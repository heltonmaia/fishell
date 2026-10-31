import pytest

from fishell.core.receita import ler_receita, parse_transferencia
from fishell.core.modelos import Transferencia

EXEMPLO_SPEC = """
[npad]
remoto   = "/scratch/global/$USER/pose"
enviar   = ["scripts/ -> code/", "configs/ -> configs/"]
trazer   = ["outputs/keypoints/"]
ambiente = "code/npad/setup_env.sh"
job      = "code/npad/extract_array.sbatch"
particao = "gpu-4-a100"
"""


def proj(tmp_path, texto):
    (tmp_path / "fishell.toml").write_text(texto, encoding="utf-8")
    return tmp_path


def test_receita_do_spec(tmp_path):
    r = ler_receita(proj(tmp_path, EXEMPLO_SPEC))
    s = r.secoes["npad"]
    assert s.remoto == "/scratch/global/$USER/pose"
    assert s.enviar == (Transferencia("scripts/", "code/"), Transferencia("configs/", "configs/"))
    assert s.trazer == (Transferencia("outputs/keypoints/", "outputs/keypoints/"),)
    assert (s.job, s.particao, s.submeter) == ("code/npad/extract_array.sbatch", "gpu-4-a100", None)
    assert r.nome == tmp_path.name


def test_transferencia_com_filtros():
    t = parse_transferencia({"de": "/dados/v/", "para": "videos/", "incluir": ["*/", "*.mp4"], "excluir": ["*_low*", "*"]})
    assert t.incluir == ("*/", "*.mp4") and t.excluir == ("*_low*", "*")


def test_sem_arquivo_devolve_none(tmp_path):
    assert ler_receita(tmp_path) is None


def test_nome_no_topo(tmp_path):
    r = ler_receita(proj(tmp_path, 'nome = "pose"\n[local]\ncomando = "python x.py"\n'))
    assert r.nome == "pose" and r.secoes["local"].comando == "python x.py"


@pytest.mark.parametrize("toml,trecho", [
    ("[npad\n", "TOML"),
    ('[npad]\njob="a.sbatch"\nsubmeter="s.sh"\nlog="l"\n', "job e submeter"),
    ('[npad]\nsubmeter="s.sh"\n', "log"),
    ('[npad]\nfoo=1\n', "foo"),
    ('bar = 1\n[npad]\njob="a"\n', "bar"),
])
def test_erros_de_receita(tmp_path, toml, trecho):
    r = ler_receita(proj(tmp_path, toml))
    assert r.secoes == {} and trecho in r.erro
