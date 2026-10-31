from fishell.cli import main


def test_versao(capsys):
    assert main(["--version"]) == 0
    assert capsys.readouterr().out.strip() == "fishell 3.0.0a1"


def test_subcomando_desconhecido():
    assert main(["xyz"]) == 2
