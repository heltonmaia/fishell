# hmshell

Terminal SSH para acesso rápido ao **NPAD/UFRN** (supercomputador do IMD).
Um único script Bash: configura chaves, registra alias `npad` e abre um
painel interativo. Funciona em Linux, macOS, WSL e Google Colab.

![hmshell control panel](screenshot.png)

---

## Instalação

```bash
git clone https://github.com/heltonmaia/hmshell.git
cd hmshell

# 1. Chaves SSH do NPAD vão em ./.ssh/
mkdir -p .ssh
cp ~/.ssh/id_rsa ~/.ssh/id_rsa.pub .ssh/

# 2. Configure seu usuário NPAD
cp config.sh.example config.sh
sed -i 's/seu_usuario_aqui/SEU_USER_NPAD/' config.sh

# 3. Rode
./hmshell.sh
```

Na primeira execução, o script detecta que o SSH não está configurado,
faz o *setup* automaticamente e abre o painel.

---

## Comandos

```bash
./hmshell.sh              # painel interativo
./hmshell.sh setup        # (re)configura o SSH
./hmshell.sh login        # conecta (= ssh npad)
./hmshell.sh test         # testa conexão
./hmshell.sh upload       # scp push (interativo)
./hmshell.sh download     # scp pull (interativo)
./hmshell.sh status       # mostra configuração
./hmshell.sh help         # ajuda
```

Depois do `setup`, o alias fica em `~/.ssh/config` e você pode usar SSH
direto de qualquer shell:

```bash
ssh npad
scp dados.zip npad:~/
scp npad:~/resultado.h5 .
```

Variáveis de ambiente:

| Var                | Efeito                                   |
| ------------------ | ---------------------------------------- |
| `HMSHELL_NOANIM=1` | desativa typewriter/boot animation       |
| `NO_COLOR=1`       | desativa cores ANSI                      |

---

## Uso no Google Colab

Estrutura esperada no seu Google Drive:

```
Meu Drive/
└── visaocomputacional/
    └── .ssh/
        ├── id_rsa
        ├── id_rsa.pub
        └── known_hosts
```

No notebook:

```python
from google.colab import drive
drive.mount('/content/drive')

!git clone https://github.com/heltonmaia/hmshell.git /content/hmshell
%cd /content/hmshell
!cp config.sh.example config.sh
!sed -i 's/seu_usuario_aqui/SEU_USER/' config.sh
!bash hmshell.sh setup
```

O script detecta `/content/drive/MyDrive/visaocomputacional/.ssh`
automaticamente. Rode `bash hmshell.sh setup` sempre que a VM do Colab
reiniciar.

---

## Troubleshooting

| Problema                          | Solução                                                          |
| --------------------------------- | ---------------------------------------------------------------- |
| `Permission denied (publickey)`   | Confirme `NPAD_USER` no `config.sh` e se a pub foi enviada ao NPAD |
| `chave privada não encontrada`    | `.ssh/id_rsa` deve existir, ou defina `SSH_KEYS_DIR` no config     |
| `Host key verification failed`    | `ssh-keygen -R '[sc2.npad.ufrn.br]:4422'` e rode `setup` de novo   |
| Timeout / conexão trava            | `./hmshell.sh test` — se falhar, verifique firewall e porta 4422  |

---

## Segurança

`.ssh/`, `config.sh`, `*.zip`, `*.pem`, `*.key` estão no `.gitignore` —
**nunca** serão commitados. Se suspeitar de vazamento, gere um novo par
com `ssh-keygen` e atualize a pub no NPAD.

---

Mantido por **Helton Maia** · UFRN/IMD · `helton.maia@ufrn.br`
