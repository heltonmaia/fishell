from fishell.core.config import dir_config, dir_estado, descobrir_receitas, ler_config


def test_padrao_sem_arquivo(tmp_path):
    cfg = ler_config(tmp_path)
    assert [(d.nome, d.tipo, d.ssh) for d in cfg.destinos] == [("local", "local", None), ("npad", "slurm", "npad")]
    assert cfg.projetos == ()


def test_le_destinos_e_projetos(tmp_path):
    (tmp_path / "destinos.toml").write_text(
        'projetos = ["~/x", "/abs/y"]\n'
        '[[destino]]\nnome = "local"\ntipo = "local"\n'
        '[[destino]]\nnome = "lab"\ntipo = "slurm"\nssh = "lab"\nparticoes = ["a", "b"]\n'
    )
    cfg = ler_config(tmp_path)
    assert [d.nome for d in cfg.destinos] == ["local", "lab"]
    assert cfg.destinos[1].particoes == ("a", "b")
    assert cfg.projetos[0].is_absolute() and cfg.projetos[0].name == "x"
    assert str(cfg.projetos[1]) == "/abs/y"


def test_dirs_respeitam_ambiente(tmp_path, monkeypatch):
    monkeypatch.setenv("FISHELL_CONFIG_DIR", str(tmp_path / "c"))
    monkeypatch.setenv("FISHELL_STATE_DIR", str(tmp_path / "s"))
    assert dir_config() == tmp_path / "c"
    assert dir_estado() == tmp_path / "s"
    monkeypatch.delenv("FISHELL_CONFIG_DIR")
    monkeypatch.delenv("FISHELL_STATE_DIR")
    assert dir_config().parts[-2:] == (".config", "fishell")
    assert dir_estado().parts[-3:] == (".local", "state", "fishell")


def _projeto(raiz, conteudo):
    raiz.mkdir()
    (raiz / "fishell.toml").write_text(conteudo)
    return raiz


def test_projeto_com_receita_invalida_fica_listado(tmp_path):
    p = _projeto(tmp_path / "ruim", "isto não é toml [[[")
    (tmp_path / "destinos.toml").write_text(f'projetos = ["{p}"]\n')
    receitas = descobrir_receitas(ler_config(tmp_path), tmp_path / "outro")
    assert len(receitas) == 1
    assert receitas[0].erro


def test_cwd_nao_duplica_projeto_configurado(tmp_path):
    p = _projeto(tmp_path / "bom", '[npad]\nremoto = "/x"\n')
    (tmp_path / "destinos.toml").write_text(f'projetos = ["{p}"]\n')
    receitas = descobrir_receitas(ler_config(tmp_path), p)
    assert len(receitas) == 1


def test_cwd_com_receita_entra(tmp_path):
    p = _projeto(tmp_path / "bom", '[npad]\nremoto = "/x"\n')
    receitas = descobrir_receitas(ler_config(tmp_path), p)
    assert [r.raiz for r in receitas] == [p]
    assert descobrir_receitas(ler_config(tmp_path), tmp_path) == []
