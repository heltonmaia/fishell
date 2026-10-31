# fishell

Acesso rápido ao **NPAD/UFRN**, o supercomputador do IMD. Registra o alias
`npad`, guarda suas chaves onde o Colab não apaga, e reúne conectar, enviar,
baixar e rodar comando num painel, sem repetir `-p4422` em tudo.

Comece pela **parte 1**: o acesso na mão, sem ferramenta nenhuma.

[![ci](https://github.com/heltonmaia/fishell/actions/workflows/ci.yml/badge.svg)](https://github.com/heltonmaia/fishell/actions/workflows/ci.yml)

![painel do fishell](docs/screenshot.png)

---

## Como funciona

```mermaid
flowchart LR
    A["<b>Sua máquina</b><br/>código · dados"]

    subgraph NPAD["NPAD · sc2.npad.ufrn.br:4422"]
        B["<b>nó de login</b><br/>editar · compilar · testar"]
        C["<b>nós de computação</b><br/>o treino roda aqui"]
        B -->|"<b>sbatch</b>"| C
    end

    A -->|"<b>ssh</b> · terminal remoto"| B
    A <-->|"<b>scp</b> · arquivos"| B
```

**`ssh`** te dá um terminal lá dentro; **`scp`** move arquivos. Você conecta no
*nó de login*. O trabalho pesado vai para os *nós de computação*, via
`sbatch`.

---

## 1. Acesso ao NPAD

Faça isso **na mão** primeiro. Se funcionar, o resto é conveniência; se não
funcionar, nenhuma ferramenta conserta.

### Gere sua chave

O NPAD só aceita login por chave, não existe senha. E a chave precisa ser
**RSA**. Dê enter em todas as perguntas:

```bash
ssh-keygen -t rsa
```

Se aparecer `already exists. Overwrite (y/n)?`, responda **n**: você já tem uma
chave e ela serve. Sobrescrever invalidaria os cadastros feitos com a antiga.

Isso cria `~/.ssh/id_rsa` (privada, nunca sai daí) e `~/.ssh/id_rsa.pub`
(pública, é a que você cadastra).

> O texto no fim da pública (`helton@notebook`) é só um rótulo, para você
> reconhecer a chave na lista do NPAD. Vai cadastrar mais de uma?
> `ssh-keygen -t rsa -C "colab"`.

### Cadastre a pública

```bash
cat ~/.ssh/id_rsa.pub
```

Copie a linha inteira e cadastre em
**[npad.ufrn.br → Primeiros Passos](https://npad.ufrn.br/npad/primeirospassos)**.
Se você já tem conta e está só adicionando uma máquina, o formulário é outro:
**[Adição de Chave](https://npad.ufrn.br/npad/chave)**.

Seu login chega por e-mail depois da aprovação.

> **O NPAD não te devolve nenhuma chave.** Ele guarda a sua pública no servidor;
> a privada fica só com você e é ela que responde ao servidor na hora de
> conectar. Não existe arquivo para baixar e salvar, diferente de senha ou
> certificado.

### Conecte

```bash
ssh -p4422 SEU_LOGIN@sc2.npad.ufrn.br
```

Não precisa apontar a chave: o `ssh` procura `~/.ssh/id_rsa` por conta própria,
que é onde o `ssh-keygen` acabou de salvar.

Deu certo? Você está no **nó de login**. Saia com `exit`.

Mandar e trazer arquivos é o mesmo endereço, com `-P` maiúsculo:

```bash
scp -P4422 dados.zip SEU_LOGIN@sc2.npad.ufrn.br:~/
scp -P4422 SEU_LOGIN@sc2.npad.ufrn.br:~/resultado.h5 .
```

> **No Colab**, o `~/.ssh` some quando a VM reinicia. Gere no Drive e aponte:
>
> ```bash
> ssh-keygen -t rsa -f /content/drive/MyDrive/SuaPasta/.ssh/id_rsa
> ssh -i /content/drive/MyDrive/SuaPasta/.ssh/id_rsa -p4422 SEU_LOGIN@sc2.npad.ufrn.br
> ```
>
> Repetir `-i` e `-p` em todo comando cansa, e é isso que a parte 3 resolve.

---

## 2. Por que o fishell

Com o acesso funcionando, o que sobra é repetição: a porta em todo comando, o
caminho longo em todo `scp`, e, no Colab, reinstalar a chave a cada reinício
da VM.

A [documentação do NPAD](https://github.com/NPAD-UFRN/Tutorials) já resolve a
primeira, ensinando a criar um alias no `~/.ssh/config`. O fishell escreve esse
bloco para você, guarda as chaves onde o Colab não apaga, e junta tudo num
painel.

Ele usa o mesmo `ssh` e o mesmo `scp`. Depois do `setup`, `ssh npad` funciona
até sem ele.

---

## 3. Instalar o fishell

**Google Colab**: abra o **Terminal** (ícone no canto inferior esquerdo) e
trabalhe por ele, com o Drive já montado. Daqui em diante é shell comum.

```bash
cd /content/drive/MyDrive/SuaPasta
git clone https://github.com/heltonmaia/fishell.git
cd fishell
cp config/config.sh.example config.sh
```

**Linux · macOS · WSL**

```bash
git clone https://github.com/heltonmaia/fishell.git
cd fishell
chmod +x bin/fishell.sh src/bash/fishell.sh
cp config/config.sh.example config.sh
```

**Windows**: precisa do OpenSSH Client (já vem no Windows 10+).

```powershell
git clone https://github.com/heltonmaia/fishell.git
cd fishell
Copy-Item config\config.ps1.example config.ps1
```

> No Colab use sempre `bash bin/fishell.sh`, nunca `./bin/fishell.sh`: o Drive
> é montado sem permissão de execução, e o `chmod` ali não adianta.

### Onde estão suas chaves

O clone traz uma pasta `.ssh/` vazia, e é ela que o `config.sh` usa por
padrão. Copie para lá a chave da parte 1:

```bash
cp ~/.ssh/id_rsa ~/.ssh/id_rsa.pub .ssh/
```

Prefere apontar em vez de copiar? O `config.sh` traz as alternativas
comentadas: `$HOME/.ssh` (onde o `ssh-keygen` salva por padrão) ou um caminho
completo qualquer.

**No Colab, use um caminho no Drive.** O `~/.ssh` fica na VM e some no
reinício, então as chaves precisam estar fora dela:

```bash
SSH_KEYS_DIR="/content/drive/MyDrive/SuaPasta/.ssh"
```

Assim o `setup` reinstala as chaves a cada sessão nova a partir do Drive, e
você não precisa cadastrar nada de novo no NPAD.

> **Mudou o `SSH_KEYS_DIR`? Rode o `setup` de novo.** Ele é quem instala as
> chaves no `~/.ssh`, e sem isso o `test` falha com
> `no such identity: ~/.ssh/id_rsa`, mesmo com o caminho certo no `config.sh`.

### Rode

```bash
./bin/fishell.sh
```

Na primeira vez ele mostra sua chave pública, o link do cadastro e pergunta
seu login do NPAD, que fica gravado no `config.sh`. Depois disso instala as
chaves, registra o alias `npad` e abre o painel.

Os mesmos passos em comandos diretos, se preferir:

```bash
./bin/fishell.sh setup     # instala as chaves e registra o alias npad
./bin/fishell.sh test      # confirma que conecta
./bin/fishell.sh           # abre o painel
```

No Colab, **repita o `setup` toda vez que a VM reiniciar**: o `~/.ssh` da
máquina virtual é descartado junto com ela, e é ele que o `ssh` consulta.

> `config.sh` e `.ssh/` são seus e não são versionados, de propósito, para o
> seu login e sua chave privada nunca irem parar num commit. A consequência:
> apagar e clonar o repo de novo leva os dois. Guardar as chaves fora da pasta
> do fishell, via `SSH_KEYS_DIR`, evita isso.

---

## 4. O painel

Cada tecla é uma ação, não precisa dar ENTER.

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

## 5. Comandos

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

## 6. Usando o NPAD

### Onde o seu programa roda

| | **nó de login** | **nós de computação** |
| --- | --- | --- |
| é onde você cai ao conectar | sim | não |
| serve para | editar, compilar, **testar** | rodar de verdade |
| como executa | `./meuscript` | `sbatch meuscript` |
| limite | ~30 min com 1 core, e **bem menos** com mais CPUs; depois o processo é morto | horas, conforme o `--time` do script |

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
| `amd-512` | uso geral; na dúvida, comece aqui |
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

## 7. Painel de jobs (versão Python, só Linux)

Além do painel das partes 1 a 6, existe uma versão em Python (`3.0.0a1`, em
desenvolvimento) que mostra **numa tela só os jobs de todos os destinos**: os
do NPAD (via Slurm) e os da sua própria máquina. Ela não substitui o `fishell.sh`
dos alunos, que continua igual. Por enquanto só roda em Linux.

### Instalar

Requer Python 3.11 ou mais novo e o [uv](https://docs.astral.sh/uv/). A partir
do clone:

```bash
uv tool install .
fishell --version
```

Para o NPAD funcionar, o alias `npad` precisa existir no `~/.ssh/config` (é o
que o `setup` das partes anteriores faz) e a chave precisa estar carregada no
`ssh-agent`: o painel nunca pergunta senha.

### A tela

`fishell` (ou `fishell menu`) abre o painel de jobs:

```
fishell  jobs
┌ DESTINOS ──────────┐┌ todos os destinos ───────────────────────────────────┐
│> todos          3  ││  DESTINO  PROJETO  JOB          ESTADO     LOG        │
│  npad          ●   ││> npad     pose     kp-extract   ● 47/65    === DONE   │
│  local         ●   ││  local    yolo     yolo-train   ✓ ok       mAP50 0.73 │
└────────────────────┘└──────────────────────────────────────────────────────┘
┌ log ao vivo ─────────────────────────────────────────────────────────────────┐
│ node : gpunode2   GPU 0: NVIDIA A100-SXM4-80GB                               │
└──────────────────────────────────────────────────────────────────────────────┘
tab destinos/jobs  enter log cheio  n novo job  m montar  p trazer  c cancelar  q sair
```

| tecla | ação |
| --- | --- |
| `tab` | alterna o foco entre a lista de destinos e a de jobs |
| `enter` | abre o log do job em tela cheia (`esc` volta) |
| `n` | novo job: escolhe o projeto (pela receita), o destino e a partição |
| `m` | monta o ambiente no destino, para o projeto do job destacado |
| `p` | traz os resultados do job para a máquina local |
| `c` | cancela o job (pede confirmação) |
| `q` | sai |

O destino `local` atualiza a cada 3 s; o NPAD, a cada 60 s.

### Receita do projeto: `fishell.toml`

Fica na raiz de cada projeto e diz ao fishell o que enviar, onde montar o
ambiente e como submeter. Uma tabela por destino:

```toml
nome = "pose"

[npad]
remoto   = "/scratch/global/$USER/pose"
enviar   = ["scripts/ -> code/", "configs/ -> configs/"]
trazer   = ["outputs/keypoints/"]
ambiente = "code/npad/setup_env.sh"
job      = "code/npad/extract_array.sbatch"
particao = "gpu-4-a100"

[local]
ambiente = "setup_env.sh"
comando  = "python treina.py"
```

- `enviar` e `trazer` são listas de itens `"origem/ -> destino/"`; um texto sem
  ` -> ` vale como o mesmo caminho nos dois lados. Para filtrar, use a forma
  de tabela: `{ de = "videos/", para = "videos/", incluir = ["*.mp4"], excluir = ["*_low.mp4"] }`.
- `job` aponta um `.sbatch`, que o fishell submete com `sbatch --parsable`.
  `submeter` aponta um script do projeto que monta o que precisar e chama o
  `sbatch`; ele deve **imprimir uma linha `fishell-job: <id>`** com o id do job,
  e a receita precisa declarar também o `log`. `job` e `submeter` não se
  combinam.
- No destino `local`, `ambiente` e `comando` rodam na pasta do projeto, e o
  `comando` numa sessão `tmux`.
- Projetos sem receita aparecem na lista, mas não oferecem enviar, montar,
  submeter nem trazer.

### Comandos

```bash
fishell            # abre o painel de jobs
fishell menu       # o mesmo
fishell jobs       # lista os jobs em texto, uma vez, e sai
fishell vigia      # o vigia de fim de job (normalmente automático)
fishell --version
```

Depois de submeter um job, o fishell inicia o **vigia** sozinho: um processo
que acompanha os jobs ativos, avisa com `notify-send` quando um termina ou
falha e sai quando não há mais nenhum.

### Configuração e estado

Sem configuração, o fishell conhece dois destinos: `local` e `npad` (o alias
SSH `npad`). Para ajustar, crie `~/.config/fishell/destinos.toml`:

```toml
projetos = ["~/work/pose", "~/work/yolo"]   # pastas com fishell.toml (a pasta atual também conta)

[[destino]]
nome = "npad"
tipo = "slurm"
ssh = "npad"
particoes = ["gpu-4-a100", "amd-512"]
```

O estado (banco de jobs, log do vigia, sockets) fica em `~/.local/state/fishell/`.
Os dois lugares podem ser trocados com `FISHELL_CONFIG_DIR` e `FISHELL_STATE_DIR`.

### Como o fishell trata o NPAD

- Uma só conexão SSH multiplexada serve para tudo, com no máximo dois canais
  (um para transferências, outro para consultas curtas).
- Se o servidor recusar a conexão, o destino fica **30 minutos** sem nenhuma
  nova tentativa. Falha de autenticação para a atualização automática até você
  forçar uma nova.
- `rsync` sempre com `-a`, nunca com `--delete` nem `--remove-source-files`. O
  fishell **não apaga nada no cluster**.
- Jobs do `local` rodam em sessões `tmux` chamadas `fishell-<id>`; jobs com mais
  de 24 h continuam na lista enquanto estiverem ativos.

---

## Problemas comuns

| Problema | Solução |
| --- | --- |
| `no such identity: ~/.ssh/id_rsa` | Falta rodar `./bin/fishell.sh setup`, que é quem instala a chave ali |
| `Permission denied (publickey)` | Confira o login no `config.sh` e se a chave **pública** foi cadastrada |
| Não acho a pasta `.ssh/` | Começa com ponto, então é oculta: `ls -a` |
| `bad interpreter: Permission denied` | Falta permissão: `chmod +x bin/fishell.sh src/bash/fishell.sh`, ou, no Drive, use `bash bin/fishell.sh` |
| Conexão trava ou dá timeout | `./bin/fishell.sh test` mostra o erro do SSH e sugere a causa |
| `Host key verification failed` | Falta o `known_hosts`, ou o servidor trocou de chave. Veja abaixo |
| O alias `npad` não foi registrado | Você já tinha um `Host npad` no `~/.ssh/config`. Remova o seu, ou troque `SSH_ALIAS` no `config.sh` |
| No Colab, parou depois de um tempo | A VM reiniciou: `bash bin/fishell.sh setup` |
| Job fica parado na fila | `squeue --start` mostra a previsão; `sinfo` mostra se a partição está cheia |

---

### `known_hosts` ausente

O `status` mostra `✗ known_hosts`? O `test` usa `BatchMode` e não consegue
confirmar a identidade do servidor sozinho. Gere e **confira**:

```bash
ssh-keyscan -p4422 sc2.npad.ufrn.br > .ssh/known_hosts 2>/dev/null
ssh-keygen -lf .ssh/known_hosts
```

| tipo | fingerprint esperada |
| --- | --- |
| ED25519 | `SHA256:Lfjr9sC3MnZJj/27hWtDsQF5wJ6rTU0j62T3qFxpUgM` |
| RSA | `SHA256:mUQ9ZrO4/2PYJHKx2Jh/OwN8LbPzPkfbiqzNv84be1E` |
| ECDSA | `SHA256:PAAyt3VUyhhmNyZBVuWQB3b4w5XRh8gDTiaD+2Q3ef8` |

O `ssh-keyscan` aceita qualquer chave que o servidor apresentar. É a
comparação com a tabela que vira verificação. Não bateu? Não prossiga; fale com
`atendimento@npad.ufrn.br`.

---

## Links

- Documentação oficial do NPAD: [npad.ufrn.br](https://npad.ufrn.br) · [tutoriais completos](https://github.com/NPAD-UFRN/Tutorials)
- Cadastro e adição de chave: [Primeiros Passos](https://npad.ufrn.br/npad/primeirospassos) · [Adição de Chave](https://npad.ufrn.br/npad/chave)
- Suporte do NPAD: `atendimento@npad.ufrn.br`
- Contribuir ou entender o código: [docs/desenvolvimento.md](docs/desenvolvimento.md)

Licença [MIT](LICENSE) · Mantido por **Helton Maia** ·
[heltonmaia.com](https://heltonmaia.com)
