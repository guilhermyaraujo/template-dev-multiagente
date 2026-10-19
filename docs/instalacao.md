# Instalação: contrato previsto e estado da entrega

Esta entrega contém a estrutura inicial, a governança do template, os arquivos parametrizados, o esquema, o exemplo e os hooks. O instalador `scripts/Install-MultiAgentProject.ps1`, o módulo `scripts/MultiAgentTemplate.psm1` e o executor `tests/Invoke-Tests.ps1` ainda não estão implementados. Os comandos de instalação somente poderão ser documentados como executáveis depois da entrega correspondente e de sua validação.

A [Especificação Técnica v1.1](especificacao-v1.md) é a referência normativa. Seus metadados “para revisão” e a declaração de que o documento não autoriza implementação são preservados como recebidos. O pedido humano específico de manutenção autoriza exclusivamente esta estrutura inicial; não autoriza instalar em consumidores, criar ambientes, ativar hooks ou publicar.

## Modelo do consumidor

O futuro instalador terá como única configuração editável um `multiagente.config.json` fora dos quatro worktrees. O [exemplo fictício](../config/project.example.json) segue o [esquema 1.0](../schema/project.schema.json). O esquema estrutural não substitui as validações semânticas e de caminhos da especificação.

| Papel | Diretório derivado | Branch padrão |
| --- | --- | --- |
| Coordenação | `<slug>` | `main` |
| Codex | `<slug>-codex` | `feature/codex` |
| Claude | `<slug>-claude` | `feature/claude` |
| Manutenção | `<slug>-manutencao` | `chore/manutencao` |

A coordenação será o clone principal e os outros três ambientes serão worktrees do mesmo repositório. Esses ambientes são o resultado futuro esperado; esta entrega não os cria. A aplicação, dependências de negócio, deploy e integrações externas ficam fora da instalação.

## Fases planejadas

| Fase | Pré-condições e operações permitidas | Limites |
| --- | --- | --- |
| `Plan` (padrão) | Validar configuração; aplicar padrões; renderizar em memória; inspecionar arquivos, ambientes e configuração | Sem alterações, fetch, temporários, relatórios em disco ou execução de hooks |
| `PrepareMaintenance` | Autorização delimitada, commit inicial e `BaseCommit` completo; clone necessário, manutenção ausente e geração nela | Sem Codex/Claude, ativação compartilhada, preparação do índice, commit, push ou PR |
| `CompleteWorktrees` | Integração comprovada; coordenação sincronizada previamente pelo responsável; conteúdo governado conforme | Criar Codex/Claude ausentes e ativar hooks somente se todas as verificações e a autorização abrangente permitirem; sem reposicionar branches ou sincronizar coordenação |
| `Validate` | Reconstruir conformidade por arquivos, objetos Git, índice e configuração efetiva | Somente leitura; sem correções, fetch, troca de branch, temporários ou execução de hooks |

`WhatIf` impedirá individualmente cada operação mutável, inclusive chamadas nativas. Não se presume propagação automática para programas externos. As leituras Git deverão evitar atualização incidental do índice, drivers externos, substituição de objetos e busca automática de objetos ausentes.

O repositório consumidor precisa de commit inicial real, fornecido por preparação humana externa. Repositório sem commit bloqueia a preparação. UNC, compartilhamentos de rede, bare, submódulos, caminhos redirecionados e configurações que exijam migração não serão instalados automaticamente. Não haverá instalação automática de dependências ou alteração global de configuração.

## Conflitos e retomada — A1

Antes de gerar qualquer arquivo, todos os destinos disponíveis serão classificados como ausentes, idênticos ou conflitantes. Somente ausentes seguros e autorizados poderão ser criados. Arquivos idênticos serão preservados. Conteúdo ou tipo diferente, links ou contenção incerta bloquearão a geração completa.

README e `.gitattributes` terão a mesma política dos demais destinos. Não haverá append, fusão, backup seguido de substituição, exclusão automática ou migração. Um README inicial criado pelo servidor também poderá constituir conflito. Sua resolução exigirá escopo humano específico em manutenção, fora do instalador.

Uma preparação anterior com arquivos gerados idênticos poderá ser reconhecida e retomada apenas nas operações ausentes autorizadas. Divergências interromperão a fase. Clone ou worktrees criados antes de uma falha serão preservados e informados como estado parcial, sem rollback destrutivo. O estado será revalidado imediatamente antes de cada alteração.

O README existente deste repositório de template foi reservado à preservação nesta entrega. A [proposta separada](proposta-readme.md) não deve ser aplicada automaticamente.

## Hooks efetivos — A2

Os hooks distribuídos bloqueiam commit na branch de coordenação e push cujo destino seja a branch de coordenação, incluindo exclusão e lote misto. Não comprovam identidade, revisão, autorização ou proteção do servidor. A limitação de HEAD destacado permanece; o futuro instalador recusará esse estado.

Antes de uma eventual ativação, o instalador precisará identificar exatamente os quatro worktrees registrados, incluindo registros indisponíveis, e conferir cada contexto separadamente. Consultará a cadeia aplicável de `core.hooksPath`, com valor, origem, escopo e includes habilitados: sistema, global, local, por worktree e includes condicionais. Também inspecionará overrides de processo e de localização, o diretório efetivo atualmente utilizado e a `.githooks` de cada raiz.

Configuração compatível será preservada. Somente entrada local ausente, sem conflitos e com autorização para todo o alcance poderá receber uma inserção de `.githooks`. Valor vazio ou distinto, ocorrências conflitantes, precedência inconclusiva, override mascarando estado persistente, quinto worktree, hook ativo no diretório padrão ou arquivo inesperado bloquearão a ativação. Uma consulta apenas a `--local` é insuficiente. A ausência de `core.hooksPath` não comprova ausência de hooks.

Não haverá composição ou migração de hooks, `--replace-all`, alteração global nem habilitação de `extensions.worktreeConfig`. O conjunto deverá ser revalidado antes da escrita e consultado novamente nos quatro contextos depois dela. Esta entrega cria material; não configura nem ativa hooks.

## Comprovação após squash — A3

A conclusão futura fixará M (HEAD completo revisado e autorizado da manutenção), I (commit integrado comprovado) e C (HEAD da coordenação já sincronizada). M e I poderão ser distintos e sem ancestralidade entre si. A manutenção conservará seu histórico e, na conclusão inicial, seu HEAD deverá corresponder à fonte revisada.

A comparação determinará o inventário obrigatório pelo pacote confiável, enumerará as árvores reais de M e I e lerá os bytes dos blobs diretamente. Comparará existência, tipo, modo e bytes com a renderização esperada, sem normalização, filtros, textconv, drivers externos ou lazy fetch. Documentos e manifesto deverão ter modo `100644`; hooks, `100755`. Serão rejeitados links e gitlinks. Diretórios exclusivos serão enumerados para detectar entradas extras.

O índice e os bytes atuais da manutenção serão conferidos diretamente; `git status` e flags do índice não bastam. A coordenação deverá conter a integração comprovada e preservar o conteúdo correspondente. O relatório mostrará resultado, modos, objetos ou hashes e divergências por caminho. Manifesto correto isolado não comprova integridade, revisão ou aprovação remota.

## Renderização, codificação e modos — A4

O contrato de tokens e contextos será registrado em [templates](templates.md). A futura renderização identificará tokens no material confiável antes da inserção e nunca reinterpretará valores inseridos como tokens. Texto como `{{BRANCH}}` dentro do nome permanecerá dado literal.

Prosa, tabela, código Markdown, literal PowerShell, literal sh, argumento nativo e operação de caminho terão escapes próprios. Somente branches e refs previamente validadas poderão entrar nos hooks; nome, URL e diretório pai nunca serão interpolados no código sh. Não haverá `Invoke-Expression`, `cmd /c`, comandos concatenados, expansão dos dados JSON ou substituição global de palavras.

Documentos, JSON e hooks serão UTF-8 sem BOM com LF explícito. Hooks exigirão modo Git `100755`; documentos e manifesto, `100644`. Atributos controlam LF, mas não registram o modo executável. Os futuros scripts PowerShell com caracteres não ASCII exigirão UTF-8 com BOM para Windows PowerShell 5.1. Esta entrega não cria esses scripts; a comprovação funcional nos dois PowerShells permanece para a entrega de implementação.

## Verificação e pendências

A verificação desta estrutura não equivale à execução das fases do instalador, nem à homologação de consumidor ou servidor. O relatório da entrega deverá registrar separadamente a inspeção estrutural, a leitura de bytes, a validação do JSON, as evidências dos modos e as limitações que permanecerem.

Permanecem para autorização própria a implementação PowerShell, a suíte Pester 5 com versão fixada, seus ambientes descartáveis e a homologação remota. Testes não deverão apontar para este repositório ou qualquer projeto real. Uma execução parcial deverá ser relatada como parcial; proteções remotas só poderão ser alegadas quando efetivamente verificadas.
