from fishell.cli import main


def test_versao(capsys):
    assert main(["--version"]) == 0
    assert capsys.readouterr().out.strip() == "fishell 3.0.0a1"


def test_subcomando_desconhecido():
    assert main(["xyz"]) == 2


def test_jobs_em_texto(monkeypatch, capsys):
    from fishell import cli
    from fishell.core.hub import Visao
    from fishell.core.modelos import EstadoJob, Job

    class HubFalso:
        def garantir_vigia_se_preciso(self):
            return None

        def atualizar(self, forcar=False):
            assert forcar is True
            return Visao(
                jobs=[
                    Job(id="7", destino="npad", nome="treino", estado=EstadoJob.OK,
                        projeto="demo", decorrido="00:01:02", ultima_linha="fim"),
                    Job(id="8", destino="local", nome="x", estado=EstadoJob.RODANDO,
                        externo=True, decorrido="5s"),
                ],
                avisos={"npad": "sem acesso"},
            )

    monkeypatch.setattr(cli, "_hub", lambda: HubFalso())
    assert main(["jobs"]) == 0
    linhas = capsys.readouterr().out.splitlines()
    assert linhas[0] == "DESTINO  PROJETO  JOB  ESTADO  TEMPO  LOG"
    assert linhas[1] == "npad  demo  treino  ✓ ok  00:01:02  fim"
    assert linhas[2] == "local    x *  ● rodando  5s"
    assert linhas[-1] == "aviso npad: sem acesso"


def test_jobs_garante_o_vigia(monkeypatch, capsys):
    from fishell import cli
    from fishell.core.hub import Visao

    chamadas = []

    class HubFalso:
        erro = None

        def atualizar(self, forcar=False):
            chamadas.append("atualizar")
            return Visao()

        def garantir_vigia_se_preciso(self):
            chamadas.append("vigia")
            return self.erro

    h = HubFalso()
    monkeypatch.setattr(cli, "_hub", lambda: h)
    assert main(["jobs"]) == 0
    assert chamadas == ["atualizar", "vigia"]
    assert capsys.readouterr().err == ""
    h.erro = OSError("sem permissão")
    assert main(["jobs"]) == 0
    err = capsys.readouterr().err
    assert "sem permissão" in err and len(err.strip().splitlines()) == 1
