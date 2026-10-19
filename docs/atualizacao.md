# Atualização, preservação e pendências

A v1 não fará atualização automática, migração de worktrees, reconciliação de documentos personalizados nem composição ou migração de hooks. A [Especificação Técnica v1.1](especificacao-v1.md) rege esses limites. Este documento não oferece um procedimento executável de atualização: o instalador e a suíte ainda não foram implementados nesta entrega inicial.

## Repetição e conflitos

Uma repetição futura deverá reconstruir o modelo esperado a partir do pacote confiável e da configuração JSON, sem usar documentos derivados como fonte alternativa. Antes de escrever, classificará todos os destinos como ausentes, idênticos ou conflitantes. Somente ausentes seguros e autorizados poderão ser criados; idênticos permanecerão intactos.

Conteúdo ou tipo diferente será conflito, inclusive no README e nos atributos. Links, redirecionamentos e contenção incerta também interromperão a geração. Não haverá append, fusão, backup seguido de substituição ou exclusão automática. A resolução será trabalho manual em manutenção, com autorização específica; não deverá editar a coordenação para contornar o conflito.

A repetição anterior ao commit poderá reconhecer arquivos gerados idênticos ainda não commitados, desde que as alterações se restrinjam ao conjunto esperado. Divergência parcial interromperá o processo. Repetição concluída conforme deverá produzir nenhuma alteração. Operações já realizadas antes de falha serão preservadas e declaradas como execução parcial, sem rollback destrutivo.

## Evolução do template

Mudanças no próprio template deverão ocorrer no ambiente atribuído de desenvolvimento ou manutenção. Coordenação não é ambiente de edição, commit ou desenvolvimento. Revisão independente deverá registrar o SHA completo avaliado; integração será via PR, com merge remoto exclusivamente humano. Um novo SHA exigirá nova revisão e autorização. Deploy e publicação exigirão decisões separadas.

A distribuição deverá registrar sua versão, o esquema compatível e a integridade do material no `package.manifest.json`. O manifesto auxilia a comparação; sua existência não substitui a origem confiável do pacote, a revisão ou a autorização de publicação. O esquema da configuração permanece `1.0` na especificação documental `1.1`.

Não alterar automaticamente um consumidor que já possua material diferente. A instalação repetível não é autorização para atualizar, personalizar ou migrar esse material.

## Conferência de conteúdo e modos após integração

M será o HEAD completo revisado e autorizado da manutenção; I, o commit integrado comprovado; C, o HEAD da coordenação sincronizada previamente pelo responsável. Squash poderá produzir M e I distintos e sem ancestralidade entre si. A comprovação será de conteúdo real, sem reposicionar a manutenção ou sincronizar a coordenação pelo instalador.

O inventário obrigatório virá do pacote confiável, independentemente do manifesto do consumidor. Árvores, blobs, índice e bytes atuais serão conferidos por caminho, existência, tipo, modo e conteúdo exato. A comparação não normalizará LF ou BOM, não executará filtros ou drivers e não buscará automaticamente objetos ausentes. Diretórios exclusivos serão enumerados para detectar entradas extras.

Hooks exigirão modo Git `100755`; documentos e manifesto, `100644`. Links e gitlinks nos caminhos governados serão rejeitados. Um manifesto idêntico não permitirá aceitar documento alterado, hook faltante ou modo incorreto. `git status` e flags do índice isolados não comprovarão os bytes do checkout. O relatório mostrará modos, objetos ou hashes, resultado e razão por caminho.

## Hooks e configuração efetiva

Nenhuma atualização deverá presumir que `core.hooksPath --local` representa todos os contextos. O futuro procedimento precisará considerar sistema, global, local, configuração por worktree, includes condicionais, origens, escopos, overrides e diretório resolvido em cada um dos quatro ambientes.

Hooks ativos no diretório padrão, quinto worktree, registro indisponível, arquivos extras, configuração conflitante ou precedência inconclusiva bloquearão uma ativação. Não haverá composição, migração, `--replace-all`, alteração global ou habilitação de `extensions.worktreeConfig`. Arquivos de amostra inativos não serão confundidos com hooks ativos. A inspeção será repetida imediatamente antes e depois de eventual escrita autorizada.

## Formatos e renderização

Documentos, JSON e hooks gerados terão UTF-8 sem BOM e LF explícito. Hooks terão modo executável Git próprio, que os atributos não conseguem registrar. Scripts PowerShell futuros com caracteres não ASCII exigirão UTF-8 com BOM para compatibilidade com Windows PowerShell 5.1.

O escape será específico de cada contexto: Markdown, código, PowerShell, sh, argumento de processo e caminho literal. Tokens serão identificados no template confiável antes de inserir dados, sem substituição recursiva ou global de palavras. Nome, URL e diretório pai não entrarão no código dos hooks. As validações semânticas e o corpus adversarial nos dois PowerShells permanecem requisitos da implementação futura.

## Pendências da estrutura inicial

- Implementação do instalador e módulo PowerShell, em entrega própria autorizada.
- Suíte Pester 5 com versão fixada, executor e fixtures descartáveis; sem testes em repositórios reais.
- Comprovação funcional separada em Windows PowerShell 5.1 e PowerShell 7.
- A antiga pendência do fragmento incompleto da célula “Células de tabela” foi resolvida documentalmente por [E01](errata-especificacao-v1.1.md#e01-escape-em-tabelas-markdown); permanece a futura validação da implementação conforme esse contrato.
- Revisão independente com SHA completo e decisões de propriedade, licença, visibilidade e origem confiável da distribuição.
- Publicação, ativação de hooks e homologação remota com autorizações próprias.

O README atual da raiz deverá permanecer intacto nesta entrega. A [proposta de substituição](proposta-readme.md) está separada para avaliação humana e não constitui autorização de aplicação.
