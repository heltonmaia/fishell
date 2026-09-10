# Desenvolvimento

Notas para quem for mexer no código. Para **usar** o fishell, veja o
[README](../README.md), que vai do acesso ao NPAD na mão (parte 1) até o uso
do Slurm (parte 6).

Duas decisões do texto que é fácil desfazer sem querer: o README **começa pelo
`ssh` cru**, sem o fishell, porque isso separa "meu acesso está ok?" de "a
ferramenta está configurada?", as duas metades ficaram indistinguíveis no uso
real e custaram horas. E ele **não menciona o notebook do Colab** (células,
`%cd`, painel Arquivos): tudo é feito pelo terminal, para as instruções valerem
igual em Colab, Linux e WSL.

## Estrutura

```
bin/     entrypoints (wrappers finos, é por aqui que o usuário roda)
  fishell.sh     Linux / macOS / WSL / Colab
  fishell.cmd    Windows
src/     os dois ports de verdade
  bash/fishell.sh
  powershell/fishell.ps1
config/  os *.example commitados
docs/    screenshots e este arquivo
tools/   make-screenshot.py
```

`config.sh` / `config.ps1` (a config do usuário) e `.ssh/` (as chaves) ficam na
**raiz** do repo, não ao lado do script. Os dois ports resolvem isso subindo
dois níveis a partir do próprio diretório (`REPO_ROOT` no bash, `$RepoRoot` no
ps1), é o que mantém a config do usuário fora do `src/` e no lugar onde o
`.gitignore` a protege. Mexeu na profundidade das pastas? Esses dois cálculos
precisam acompanhar.

## Dois ports escritos à mão

Não há código compartilhado: o programa existe duas vezes, em Bash e em
PowerShell. **Toda mudança de comportamento, texto de UI ou subcomando precisa
entrar nos dois**, incluindo o número de versão. O CI falha se as versões
divergirem, se um subcomando existir só de um lado ou se as tabelas de idioma
saírem de paridade.

## Checks

```bash
bash -n src/bash/fishell.sh bin/fishell.sh          # sintaxe
shellcheck src/bash/fishell.sh bin/fishell.sh       # se disponível

for l in pt en; do
  FISHELL_LANG=$l NO_COLOR=1 ./bin/fishell.sh </dev/null \
    | python3 .github/scripts/check_panel.py        # a caixa tem 50 colunas
done

bash .github/scripts/test_validate_pubkey.sh        # validador da chave pública
python3 .github/scripts/check_i18n.py               # paridade das traduções

python3 tools/make-screenshot.py                    # docs/screenshot.png (pt)
python3 tools/make-screenshot.py --lang en -o docs/screenshot-en.png
```

O CI roda tudo isso mais o parser do PowerShell, o PSScriptAnalyzer e o
**runtime do ps1** (`.github/scripts/Test-Runtime.ps1`).

## Armadilhas que já causaram bug

Cada uma tem um check de CI. Não remova sem entender o que ele protege.

**O `fishell.ps1` precisa estar em UTF-8 com BOM.** O Windows PowerShell 5.1 lê
`.ps1` sem BOM como ANSI, o que destrói o banner, as bordas do painel e as
sentinelas do bloco no `~/.ssh/config`, fazendo cada `setup` duplicar o bloco.
Toda ferramenta que reescreva o arquivo precisa preservar o BOM
(`encoding='utf-8-sig'` em Python).

**O painel é medido em colunas, não em bytes.** No bash, `printf '%-20s'`
preenche por byte, e com `LC_ALL=C` até o `${#s}` conta bytes, "conexão"
desalinharia a caixa. Use os helpers `vlen`/`pad`, nunca `%-Ns`, em qualquer
coisa alinhada que possa ter acento. No PowerShell o `.PadRight()` já conta
caracteres.

**Parsear o ps1 não basta.** Parser e PSScriptAnalyzer não pegam erro de
runtime. Dois bugs reais passaram por eles: `$host = ...` (variável automática
read-only, explodia no `keygen`) e `$null -notmatch` num `~/.ssh/config` vazio,
que fazia o `setup` nunca registrar o alias no Windows. Por isso o CI
**executa** o port PowerShell.

**A chave pública vai colada num formulário oficial.** O fishell **não gera**
a chave, isso é um `ssh-keygen -t rsa`, no terminal, como manda a documentação
do NPAD. Mas ele *mostra* a pública para você copiar, e `validate_pubkey` /
`Test-PubKey` conferem a integridade antes de imprimir: uma chave truncada
cadastrada custa dias, porque o cadastro vai, o e-mail chega, e só na hora de
conectar é que falha.

**`clear` só em TTY.** Sem isso o `\033[H\033[2J` vaza cru na saída de pipe ou
de célula de notebook, e o banner sai três vezes.

**O bit de execução não sobrevive ao Drive.** O wrapper de `bin/` chama o
interpretador explicitamente em vez de dar `exec` no script, senão morre com
`Permission denied` num mount FUSE mesmo quando invocado como `bash bin/...`.

## Diferenças entre os ports que são deliberadas

- **Completar caminho com Tab** só existe no bash (`read -e`, do readline). O
  PowerShell precisaria do PSReadLine, que não está garantido num script solto.

## Idioma

`FISHELL_LANG=pt|en`, padrão **pt**. Precedência: tecla `[l]` do menu >
variável de ambiente > `config.sh`/`config.ps1` > `pt`. O ambiente é capturado
*antes* de sourcear a config, justamente para poder vencer depois.

Todas as strings de usuário ficam numa tabela única por idioma: `set_lang()`
atribui `L_*` no bash, `Set-Lang` preenche o hashtable `$L` no ps1, mesmas
chaves, mesma ordem nos dois arquivos. **String nova entra nas quatro tabelas**
(pt/en × bash/ps1), e as do painel respeitam os limites de 20/16 colunas.

## O menu é deliberadamente enxuto

O público são alunos acessando o NPAD pela primeira vez. Foram removidos de
propósito: `forget` (`ssh-keygen -R`), que era um botão de "ignorar aviso de
segurança" para um caso raro; a animação, que poluía a saída no Colab; e
`keygen`, porque gerar chave é um `ssh-keygen` de uma linha e não precisa de
embrulho, o fishell só mostra a pública já existente. Não readicione opção ao painel sem uma
razão de uso real, o custo é cognitivo, não de código.

## Screenshots

`docs/screenshot.png` é gerado da UI real por `tools/make-screenshot.py`, que
roda o fishell numa cópia temporária do repo com `NPAD_USER="usuario"`. **O
repo é público**: o print não pode mostrar um login NPAD real, então não
substitua o arquivo por uma captura da sua sessão.

## Segurança

`.ssh/`, `config.sh`, `config.ps1`, `*.zip`, `*.pem`, `*.key` estão no
`.gitignore`. Revise `git status` antes de qualquer commit e nunca remova essas
regras.

## Migrando de máquina

Depois do `git clone`, copie da máquina antiga o `config.sh` e a pasta `.ssh/`
inteira, os dois são gitignored de propósito. Ajuste as permissões, que o SSH
recusa se estiverem frouxas:

```bash
chmod 700 .ssh
chmod 600 .ssh/id_rsa .ssh/known_hosts
chmod 644 .ssh/id_rsa.pub
chmod +x bin/fishell.sh src/bash/fishell.sh
```
