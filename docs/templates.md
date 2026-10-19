# Contrato dos templates

Este contrato descreve o material declarativo desta entrega. O carregador, a
validação semântica, a renderização e o instalador ainda não foram implementados.
A referência normativa é a [Especificação Técnica v1.1](especificacao-v1.md).

## Fontes e destinos

O único arquivo editável de configuração do consumidor será
`multiagente.config.json`, fora dos quatro worktrees. O
[exemplo fictício](../config/project.example.json) e o
[esquema 1.0](../schema/project.schema.json) descrevem sua estrutura.
Defaults do JSON Schema são anotações: o carregador futuro deve aplicá-los
explicitamente. O esquema não substitui a validação semântica da seção 2.

| Template confiável | Destino relativo | Modo Git esperado no destino |
| --- | --- | --- |
| `templates/AGENTS.md.tmpl` | `AGENTS.md` | `100644` |
| `templates/CLAUDE.md.tmpl` | `CLAUDE.md` | `100644` |
| `templates/README.md.tmpl` | `README.md` | `100644` |
| `templates/.gitattributes.tmpl` | `.gitattributes` | `100644` |
| `templates/.githooks/pre-commit.tmpl` | `.githooks/pre-commit` | `100755` |
| `templates/.githooks/pre-push.tmpl` | `.githooks/pre-push` | `100755` |
| `templates/docs/agentes/coordenacao.md.tmpl` | `docs/agentes/coordenacao.md` | `100644` |
| `templates/docs/agentes/desenvolvimento.md.tmpl` | `docs/agentes/desenvolvimento.md` | `100644` |
| `templates/docs/agentes/manutencao.md.tmpl` | `docs/agentes/manutencao.md` | `100644` |
| `templates/docs/agentes/revisao.md.tmpl` | `docs/agentes/revisao.md` | `100644` |

Todos os destinos usam UTF-8 sem BOM e LF. O manifesto derivado
`.multiagente/manifest.json` será produzido pelo instalador futuro, em `100644`,
sem template literal, caminhos absolutos locais, credenciais, aprovação humana
ou hash de si próprio. Os dez templates e o manifesto formam os onze caminhos
obrigatórios do consumidor. A instalação também inspecionará entradas inesperadas
nos diretórios exclusivos `.githooks/`, `docs/agentes/` e `.multiagente/`.

Os arquivos `.tmpl` distribuídos são dados em modo `100644`, inclusive os modelos
de hooks. O modo `100755` pertence aos hooks gerados. A distribuição também
possui seus próprios hooks e documentos de governança na raiz.

## Tokens presentes nesta distribuição

| Token | Derivação do modelo validado | Contexto permitido |
| --- | --- | --- |
| `{{PROJECT_NAME_MD}}` | `project.name` após validação e escape Markdown/HTML | Prosa e título de uma linha |
| `{{WORKTREE_COORDINATION}}` | `project.slug` | Identificador ASCII em código Markdown e tabela |
| `{{WORKTREE_CODEX}}` | `project.slug` seguido de `-codex` | Identificador ASCII em código Markdown e tabela |
| `{{WORKTREE_CLAUDE}}` | `project.slug` seguido de `-claude` | Identificador ASCII em código Markdown e tabela |
| `{{WORKTREE_MAINTENANCE}}` | `project.slug` seguido de `-manutencao` | Identificador ASCII em código Markdown e tabela |
| `{{BRANCH_COORDINATION}}` | `branches.coordination`, padrão `main` | Branch restrita em Markdown ou conteúdo de literal sh |
| `{{BRANCH_CODEX}}` | `branches.codex`, padrão `feature/codex` | Branch restrita em Markdown |
| `{{BRANCH_CLAUDE}}` | `branches.claude`, padrão `feature/claude` | Branch restrita em Markdown |
| `{{BRANCH_MAINTENANCE}}` | `branches.maintenance`, padrão `chore/manutencao` | Branch restrita em Markdown |

Nome de apresentação não é inserido em tabelas, código ou comandos nestes
templates. URL e diretório pai não são interpolados nos documentos nem nos
hooks; continuam dados do modelo efetivo, necessários às operações futuras.
Nome, URL e diretório pai nunca entram em código sh.

As quatro branches devem satisfazer simultaneamente o alfabeto restrito da
especificação e `git check-ref-format --branch`, ser distintas inclusive por
comparação sem distinguir caixa e não usar `HEAD` ou prefixo `refs/`.
O alfabeto permite somente letra ou dígito inicial e depois letras, dígitos,
ponto, sublinhado, barra e hífen. Ele exclui apóstrofes, crases, espaços,
substituições de shell e outros delimitadores. Nos hooks, o token é o conteúdo
do literal entre aspas simples já presentes no template; não fornece as aspas.
`refs/heads/` é um prefixo fixo no `pre-push`.

## Renderização futura por contexto

O gerador deve identificar os tokens nos templates confiáveis antes de inserir
dados. Deve usar uma única passagem sobre essas ocorrências e rejeitar tokens
desconhecidos do próprio template. Não deve reexaminar valores inseridos como
tokens nem fazer substituição recursiva ou global de palavras como `main`.
Um nome contendo literalmente `{{BRANCH}}` permanece dado; uma busca cega no
resultado não pode classificá-lo como token pendente.

Para prosa e títulos, validar a linha única e escapar pontuação Markdown e HTML
de forma a preservar o valor como texto, sem criar links, tags, cabeçalhos ou
regras. Controles, quebras de linha, separadores Unicode de linha/parágrafo e
controles de direção são rejeitados após decodificar o JSON. A validação também
rejeita nome vazio, propriedades desconhecidas e chaves duplicadas, inclusive
diferenças apenas de caixa.

Se templates futuros precisarem de outros contextos, cada contexto terá contrato
próprio: células não podem criar colunas; links e âncoras derivam de caminhos e
identificadores controlados; código Markdown exige delimitadores seguros;
literais PowerShell de aspas simples duplicam apóstrofes internos. Não reutilizar
escape de prosa em código. Não existe função universal de escape. A antiga
truncagem da tabela normativa foi corrigida por [E01](errata-especificacao-v1.1.md#e01-escape-em-tabelas-markdown),
que detalha pipes, barras invertidas e quebras de linha por contexto.

Chamadas de processos usarão argumentos separados, sem formar comandos por
concatenação. Caminhos usarão APIs e semântica literal com validação de contenção,
reservados Windows e links/junctions. Espaços, acentos, apóstrofes, `$`, `&`,
colchetes e ponto e vírgula devem permanecer dados literais. Não usar
`Invoke-Expression`, `cmd /c`, expansão de valores do JSON nem filtros Git na
comprovação de bytes. A URL terá validação própria de transporte HTTPS/SSH,
sem senha, token, consulta, fragmento ou protocolos de execução.

## Integridade da distribuição inicial

`package.manifest.json` descreve esta distribuição `0.1.0-dev.1`, compatível com
o esquema `1.0` e vinculada à especificação `1.1`. A lista `files` é ordenada por
caminho relativo com barras `/`; cada entrada contém `path`, SHA-256 em
`sha256` e o modo Git esperado em `gitMode`. Inclui o README original preservado,
mas exclui o próprio manifesto e metadados Git. Não contém caminhos absolutos.

Os hashes são calculados sobre os bytes distribuídos, sem normalização. Este
inventário inicial não é uma versão publicada, assinatura ou prova de origem
confiável. Modos declarados devem ser conferidos no índice e nos objetos Git;
o manifesto não os configura. O instalador futuro não está incluído no pacote.
Qualquer mudança de material exige nova conferência da lista e dos hashes antes
de distribuição autorizada. O consumidor não pode usar seu próprio manifesto
para reduzir o inventário obrigatório definido pelo pacote confiável.
