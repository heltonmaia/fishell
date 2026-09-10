# fishell

Acesso rápido ao **NPAD/UFRN**, o supercomputador do IMD. Gera sua chave SSH,
configura o acesso e abre um painel para conectar, mandar e trazer arquivos —
sem decorar `ssh -p4422 usuario@sc2.npad.ufrn.br`.

[![ci](https://github.com/heltonmaia/fishell/actions/workflows/ci.yml/badge.svg)](https://github.com/heltonmaia/fishell/actions/workflows/ci.yml)

![painel do fishell](docs/screenshot.png)

---

## Começando

São três passos, e o próprio fishell te guia por eles.

### 1. Instale e rode

**Google Colab** — use o **Terminal** (ícone no canto inferior esquerdo), não
células. Monte o Drive antes, numa célula:
`from google.colab import drive; drive.mount('/content/drive')`

```bash
cd /content/drive/MyDrive/SuaPasta
git clone https://github.com/heltonmaia/fishell.git
cd fishell
bash bin/fishell.sh
```

**Linux · macOS · WSL**

```bash
git clone https://github.com/heltonmaia/fishell.git
cd fishell
chmod +x bin/fishell.sh src/bash/fishell.sh
./bin/fishell.sh
```

**Windows** — precisa do OpenSSH Client (já vem no Windows 10+).

```powershell
git clone https://github.com/heltonmaia/fishell.git
cd fishell
.\bin\fishell.cmd
```

> No Colab use sempre `bash bin/fishell.sh`, nunca `./bin/fishell.sh`: o Drive
> é montado sem permissão de execução, e o `chmod` ali não adianta.

### 2. Gere e cadastre sua chave

O NPAD exige uma chave **RSA**. Se você ainda não tem uma, gere no terminal —
dê enter em todas as perguntas:

```bash
mkdir -p .ssh
ssh-keygen -t rsa -f .ssh/id_rsa -C "seu-nome@colab"
```

O `-f .ssh/id_rsa` guarda a chave **dentro da pasta do fishell**, e não no
`~/.ssh` da máquina. No Colab isso é o que importa: o `~/.ssh` da VM é
descartado a cada reinício, enquanto o repo está no Drive e persiste. O `-C` é
opcional e serve só para você reconhecer a chave depois, na sua lista do NPAD —
sem ele o comentário vira algo como `root@366ea8542bb9`.

Rode o fishell de novo: ele mostra sua chave **pública**. Copie e cadastre em
**[npad.ufrn.br → Primeiros Passos](https://npad.ufrn.br/npad/primeirospassos)**.

Seu login chega por e-mail depois da aprovação.

> A chave **privada** (`.ssh/id_rsa`, sem o `.pub`) nunca sai do seu
> computador: não vai no formulário, no Git nem no WhatsApp.

### 3. Diga qual é o seu login

Abra o `config.sh` e troque `seu_usuario_aqui` pelo login que chegou por
e-mail.

**No Colab**, dois cliques no arquivo pelo painel **Arquivos** (barra da
esquerda) — o terminal do Colab não tem `nano`. Nas outras plataformas,
`nano config.sh` ou o editor que preferir.

Rode de novo e o painel abre. Pronto.

> A pasta `.ssh/` começa com ponto, então é **oculta**: para vê-la no painel
> Arquivos do Colab, ligue o ícone de olho (*mostrar arquivos ocultos*).

No Colab, **repita o `setup` toda vez que a VM reiniciar** — o `~/.ssh` da
máquina virtual é descartado junto com ela:

```bash
bash bin/fishell.sh setup
```

---

## O painel

Cada tecla é uma ação — não precisa dar ENTER.

| tecla | ação |
| --- | --- |
| `1` | abre o shell no NPAD |
| `2` | testa a conexão, sem abrir shell |
| `3` | envia arquivo ou pasta |
| `4` | baixa arquivo ou pasta |
| `5` | roda **um** comando no NPAD e mostra a saída |
| `6` | refaz a configuração do SSH |
| `7` | mostra a configuração atual |
| `l` | troca o idioma (pt ⇄ en) |
| `0` | sai |

---

## Comandos

Tudo que está no painel também funciona direto na linha de comando:

```bash
./bin/fishell.sh                  # painel
./bin/fishell.sh login            # conecta
./bin/fishell.sh test             # testa a conexão
./bin/fishell.sh upload           # envia (pergunta os caminhos)
./bin/fishell.sh download         # baixa
./bin/fishell.sh run "squeue"     # roda um comando no NPAD
./bin/fishell.sh setup            # refaz a configuração do SSH
./bin/fishell.sh help             # ajuda
```

Depois do `setup`, o SSH normal também funciona, de qualquer terminal:

```bash
ssh npad
scp dados.zip npad:~/
scp npad:~/resultado.h5 .
```

Para mudar o idioma de forma permanente, edite `FISHELL_LANG` no `config.sh`.

---

## Usando o NPAD

### Onde o seu programa roda

Esta é a distinção que mais derruba quem está começando:

| | **nó de login** | **nós de computação** |
| --- | --- | --- |
| é onde você cai ao conectar | sim | não |
| serve para | editar, compilar, **testar** | rodar de verdade |
| como executa | `./meuscript` | `sbatch meuscript` |
| limite | ~30 min com 1 core, e **bem menos** com mais CPUs — depois o processo é morto | horas, conforme o `--time` do script |

**Nunca** deixe um treinamento no nó de login: ele é derrubado, e você atrapalha
todo mundo que está logado.

### Submetendo um job

Um "script de job" é um shell script com diretivas `#SBATCH` no topo:

```bash
#!/bin/bash
#SBATCH --partition=amd-512     # onde rodar
#SBATCH --time=0-0:30           # tempo máximo (dias-horas:minutos)

python treina.py
```

```bash
sbatch meujob.sh        # → Submitted batch job 14518
cat slurm-14518.out     # a saída vai para este arquivo, não para a tela
```

### Partições

| partição | para quê |
| --- | --- |
| `amd-512` | uso geral — na dúvida, comece aqui |
| `intel-*` | uso geral (variantes Intel) |
| `gpu-8-v100` | 8 GPUs NVIDIA V100 |
| `gpu-4-a100` | 4 GPUs NVIDIA A100 |

### Job com GPU

```bash
#!/bin/bash
#SBATCH --partition=gpu-4-a100
#SBATCH --gpus-per-node=1
#SBATCH --cpus-per-task=6
#SBATCH --time=0-03:00

conda activate gpu      # ambiente com PyTorch para GPU já instalado
python treina.py
```

Por padrão o PyTorch usa **uma** GPU; para várias é preciso `DataParallel` ou
`DDP` no seu código.

### Acompanhando a fila

| comando | o que faz |
| --- | --- |
| `squeue -u SEU_LOGIN` | seus jobs |
| `squeue --start` | estimativa de quando cada job começa |
| `sinfo` | estado das partições |
| `scancel 14518` | cancela um job seu |

Dá para consultar sem abrir shell nenhum:

```bash
./bin/fishell.sh run "squeue -u SEU_LOGIN"
```

### Um fluxo típico

```bash
./bin/fishell.sh upload                 # manda o projeto
./bin/fishell.sh run "cd meu_projeto && sbatch meujob.sh"
./bin/fishell.sh run "squeue -u SEU_LOGIN"
./bin/fishell.sh download               # traz os resultados
```

> Não existe `sudo` no NPAD. Precisa de algo com privilégio de administrador?
> Fale com o `atendimento@npad.ufrn.br`.

---

## Problemas comuns

| Problema | Solução |
| --- | --- |
| `Permission denied (publickey)` | Confira o login no `config.sh` e se a chave **pública** foi cadastrada |
| `bad interpreter: Permission denied` | Falta permissão: `chmod +x bin/fishell.sh src/bash/fishell.sh` — ou, no Drive, use `bash bin/fishell.sh` |
| Não acho a pasta `.ssh/` no painel do Colab | Ela é oculta: ligue o ícone de olho (*mostrar arquivos ocultos*) |
| Conexão trava ou dá timeout | `./bin/fishell.sh test` mostra o erro do SSH e sugere a causa |
| `Host key verification failed` | O servidor trocou de chave. Confirme com o NPAD e rode `ssh-keygen -R '[sc2.npad.ufrn.br]:4422'` |
| O alias `npad` não foi registrado | Você já tinha um `Host npad` no `~/.ssh/config`. Remova o seu, ou troque `SSH_ALIAS` no `config.sh` |
| No Colab, parou depois de um tempo | A VM reiniciou: `bash bin/fishell.sh setup` |
| Job fica parado na fila | `squeue --start` mostra a previsão; `sinfo` mostra se a partição está cheia |

---

## Links

- Documentação oficial do NPAD: [npad.ufrn.br](https://npad.ufrn.br) · [tutoriais completos](https://github.com/NPAD-UFRN/Tutorials)
- Cadastro e adição de chave: [Primeiros Passos](https://npad.ufrn.br/npad/primeirospassos) · [Adição de Chave](https://npad.ufrn.br/npad/chave)
- Suporte do NPAD: `atendimento@npad.ufrn.br`
- Contribuir ou entender o código: [docs/desenvolvimento.md](docs/desenvolvimento.md)

Licença [MIT](LICENSE) · Mantido por **Helton Maia** ·
[heltonmaia.com](https://heltonmaia.com)
