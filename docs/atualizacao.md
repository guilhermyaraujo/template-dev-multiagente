# Atualização e preservação na v1.0

A implementação funcional das quatro fases está concluída e a homologação local foi aceita. O manifesto permanece em `0.1.0-dev.9` (`homologacao-local`); não há release `1.0.0` nem publicação remota autorizada. A v1 não oferece atualização automática, migração de worktrees, reconciliação de documentos personalizados nem composição ou migração de hooks. A [Especificação Técnica v1.1](especificacao-v1.md), com sua [errata](errata-especificacao-v1.1.md), rege esses limites. Os comandos e parâmetros efetivos estão em [Instalação](instalacao.md).

## Repetição e conflitos

Uma repetição reconstrói o modelo esperado a partir do pacote confiável e da configuração JSON, sem usar documentos derivados como fonte alternativa. `Plan` (fase padrão) e `Validate` apenas inspecionam. `PrepareMaintenance` e `CompleteWorktrees` exigem autorizações humanas próprias e os parâmetros completos descritos em [Instalação](instalacao.md#fluxo-completo); `-WhatIf` simula sem gravar. Antes de escrever, a fase mutável classifica os destinos como ausentes, idênticos ou conflitantes. Somente ausentes seguros e autorizados podem ser criados; idênticos permanecem intactos.

Conteúdo ou tipo diferente será conflito, inclusive no README e nos atributos. Links, redirecionamentos e contenção incerta também interromperão a geração. Não haverá append, fusão, backup seguido de substituição ou exclusão automática. A resolução será trabalho manual em manutenção, com autorização específica; não deverá editar a coordenação para contornar o conflito.

A repetição anterior ao commit reconhece arquivos gerados idênticos ainda não commitados, desde que as alterações se restrinjam ao conjunto esperado. Divergência parcial interrompe o processo. A repetição de uma instalação concluída e conforme não produz alteração. Operações já realizadas antes de falha são preservadas e declaradas como execução parcial, sem rollback destrutivo. Após qualquer bloqueio ou código 4, confira o relatório e rode `Plan` e `Validate` em leitura antes de decidir uma nova operação; não use limpeza ou reset para forçar a retomada.

## Evolução do template

Mudanças no próprio template deverão ocorrer no ambiente atribuído de desenvolvimento ou manutenção. Coordenação não é ambiente de edição, commit ou desenvolvimento. Revisão independente deverá registrar o SHA completo avaliado; integração será via PR, com merge remoto exclusivamente humano. Um novo SHA exigirá nova revisão e autorização. Deploy e publicação exigirão decisões separadas.

A distribuição registra versão `0.1.0-dev.9`, estado `homologacao-local`, esquema compatível `1.0` e SHA-256 dos 47 arquivos em `package.manifest.json`. O manifesto auxilia a comparação; sua existência não substitui a origem confiável do pacote, a revisão ou a autorização de publicação. Ao alterar material inventariado, recalcule apenas os hashes das entradas alteradas, preserve versão, estado, ordem, caminhos e modos, e confira todas as entradas e uma cópia isolada pelo procedimento de [integridade do pacote](instalacao.md#obter-e-conferir-o-pacote). O manifesto não inclui a si próprio.

Não alterar automaticamente um consumidor que já possua material diferente. A instalação repetível não é autorização para atualizar, personalizar ou migrar esse material.

## Conferência de conteúdo e modos após integração

M será o HEAD completo revisado e autorizado da manutenção; I, o commit integrado comprovado; C, o HEAD da coordenação sincronizada previamente pelo responsável. Squash poderá produzir M e I distintos e sem ancestralidade entre si. A comprovação será de conteúdo real, sem reposicionar a manutenção ou sincronizar a coordenação pelo instalador.

O inventário obrigatório virá do pacote confiável, independentemente do manifesto do consumidor. Árvores, blobs, índice e bytes atuais serão conferidos por caminho, existência, tipo, modo e conteúdo exato. A comparação não normalizará LF ou BOM, não executará filtros ou drivers e não buscará automaticamente objetos ausentes. Diretórios exclusivos serão enumerados para detectar entradas extras.

Hooks exigirão modo Git `100755`; documentos e manifesto, `100644`. Links e gitlinks nos caminhos governados serão rejeitados. Um manifesto idêntico não permitirá aceitar documento alterado, hook faltante ou modo incorreto. `git status` e flags do índice isolados não comprovarão os bytes do checkout. O relatório mostrará modos, objetos ou hashes, resultado e razão por caminho.

## Hooks e configuração efetiva

Nenhuma atualização presume que `core.hooksPath --local` representa todos os contextos. `CompleteWorktrees` considera sistema, global, local, configuração por worktree, includes condicionais, origens, escopos, overrides e diretório resolvido em cada um dos quatro ambientes.

Hooks ativos no diretório padrão, quinto worktree, registro indisponível, arquivos extras, configuração conflitante ou precedência inconclusiva bloqueiam uma ativação. Não há composição, migração, `--replace-all`, alteração global ou habilitação de `extensions.worktreeConfig`. Arquivos de amostra inativos não são confundidos com hooks ativos. A inspeção é repetida imediatamente antes e depois de eventual escrita autorizada. A v1 também recusa `core.sshCommand`, `GIT_SSH` e `GIT_SSH_COMMAND` personalizados para clone SSH; preserve essa configuração e resolva a política de confiança fora do instalador, sem desativá-la silenciosamente.

## Formatos e renderização

Documentos, JSON e hooks gerados usam UTF-8 sem BOM e LF explícito. Hooks exigem modo executável Git próprio, que os atributos não conseguem registrar. Scripts PowerShell com caracteres não ASCII exigem UTF-8 com BOM para compatibilidade com Windows PowerShell 5.1; os scripts atuais são ASCII.

O escape é específico de cada contexto: Markdown, código, PowerShell, sh, argumento de processo e caminho literal. Tokens são identificados no template confiável antes de inserir dados, sem substituição recursiva ou global de palavras. Nome, URL e diretório pai não entram no código dos hooks. A homologação local executou o corpus adversarial nos dois PowerShells previstos; mudanças futuras de renderização exigem nova validação.

## Estado e limites de homologação

- Implementação funcional concluída: `Plan`, `PrepareMaintenance`, `CompleteWorktrees` e `Validate`, com executor em `tests/Invoke-Tests.ps1` e Pester 5.7.1 fixado. A homologação local aceita registrou 417/417 casos em cada host x64 (5.1 e 7.6.9), com saída 0, e 417/417 em 5.1 x86, em pacote isolado. A chamada x86 de host único saiu com código 2 porque AC01 e AC32 exigem dois hosts, sem falhas de casos. O relatório `docs/homologacao-v1.0.md` está no repositório de trabalho, fora do pacote distribuível; as evidências foram arquivadas separadamente. Isso não comprova instalação em consumidor real.
- Ambiente comprovado: Windows 11 build 26300 e Git for Windows 2.52.0. Windows 10, Windows Server, Git 2.44, outras versões 7.x e proteções remotas não foram homologados.
- A pendência textual da célula “Células de tabela” foi resolvida por [E01](errata-especificacao-v1.1.md#e01-escape-em-tabelas-markdown).
- Publicação remota, release `1.0.0`, decisões de propriedade, licença, visibilidade e origem confiável da distribuição continuam sujeitos a decisões próprias. O README existente permanece preservado; há somente uma [proposta separada](proposta-readme.md).

Uma mudança futura de governança ou de requisitos exige autorização específica. Atualizar estes documentos operacionais não altera as regras de `AGENTS.md` nem autoriza publicar, instalar em consumidor ou ativar hooks.
