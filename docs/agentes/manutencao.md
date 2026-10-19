# Papel: Manutenção

Ambiente: worktree `template-dev-multiagente-manutencao`, branch `chore/manutencao`.

Objetivo: manter a governança e as ferramentas que sustentam o desenvolvimento.

Responsabilidades:

- Atualizar documentação, instruções de agentes e configurações compartilhadas
  conforme o escopo autorizado.
- Manter hooks, automações de desenvolvimento, CI e infraestrutura autorizada.
- Preservar compatibilidade entre `AGENTS.md`, `CLAUDE.md` e os papéis, mantendo
  regras comuns em `AGENTS.md` e detalhes nos documentos específicos.
- Validar consistência, links e `git diff --check`, além das verificações
  pertinentes à mudança; informar resultados, impactos e limitações.
- Submeter as mudanças ao fluxo de [Revisão](revisao.md). Codex revisa Claude e
  Claude revisa Codex também em manutenção; o revisor não pode ser autor.

Restrições:

- Trabalhar exclusivamente no worktree e na branch atribuídos, sem desenvolver
  funcionalidades da aplicação ou modificar arquivos de outros ambientes.
- Obter autorização humana prévia para mudanças de governança, instruções,
  políticas Git ou hooks. O papel de manutenção não concede autorização geral.
- Fazer revisões em somente leitura por padrão. Correções autorizadas atribuem
  autoria e exigem revisão independente das novas alterações.
- Somente o humano autoriza commit, push, merge e operações sensíveis, para uma
  operação ou conjunto delimitado e seu escopo. Delegações de agentes apenas
  reproduzem autorização humana anterior identificável, sem criar ou ampliar
  permissões. Confira sua origem conforme
  [AGENTS.md](../../AGENTS.md#autorizações-humanas-e-delegações).
- Inspecionar o alcance antes de alterar configurações Git: `--local` pode ser
  compartilhada entre worktrees. Não alterá-la se afetar ambientes fora do escopo
  autorizado. Configuração com `--worktree` exige suporte e alcance confirmados;
  não habilite configurações compartilhadas como atalho para o isolamento.
- Mudanças em infraestrutura externa, segredos, proteções do servidor e deploys
  precisam de autorização humana explícita para o alvo e o efeito pretendidos;
  manutenção local não concede essa permissão.
- Seguir [AGENTS.md](../../AGENTS.md) para fetch, fast-forward seguro, merges,
  rebases e operações destrutivas. A `main` permanece sem edição, commits ou
  desenvolvimento; sua sincronização local após PR integrado é a
  [exceção documentada](../../AGENTS.md#sincronizacao-da-coordenacao), somente no
  worktree atribuído a essa operação. Não a execute a partir de manutenção.
- Autorização para manter hooks não permite enfraquecê-los para contornar bloqueios.

A configuração da aplicação necessária à feature pode permanecer no ambiente de
desenvolvimento, dentro do escopo aprovado. A fronteira depende do efeito da
mudança, conforme [Desenvolvimento](desenvolvimento.md#configuração-da-feature-e-infraestrutura-compartilhada).
A adaptação dos nomes para outros projetos está na
[documentação de atualização](../atualizacao.md) e também exige autorização prévia
quando alterar a governança.

## Limitações dos hooks

Os scripts atuais fazem duas verificações locais:

- `.githooks/pre-commit` bloqueia commits quando a branch atual é `main`.
- `.githooks/pre-push` bloqueia atualizações com destino a `refs/heads/main`,
  independentemente da branch de origem, inclusive exclusão dessa referência.

Esses scripts não impedem edição de arquivos na `main`, não validam identidade
do agente, worktree autorizado, escopo, testes, revisão, PR, SHA ou autorização
humana. Saída zero em branch de trabalho não autoriza commit ou push.
Não há verificação dedicada de merge ou rebase; eles não garantem o bloqueio de
merges locais, inclusive fast-forward. O `pre-commit` também não trata HEAD
destacado como se fosse a `main`.

Os hooks dependem de configuração, presença e condições de execução dos scripts
em cada checkout. Podem estar inativos ou ser contornados tecnicamente, embora
o contorno seja proibido pela governança. A instalação, o compartilhamento de
configuração entre worktrees e os testes sem commit ou push estão no
[Instalação](../instalacao.md).

Merges pela interface do servidor, por API ou por ferramentas como `gh pr merge`
não executam esses hooks locais. Proteções remotas devem exigir PR, revisão e
autorização humana; sua existência e eficácia precisam ser verificadas no servidor,
não podem ser inferidas dos scripts locais. Esta documentação não configura tais
proteções nem garante validação automática do vínculo entre PR, SHA e autorização.

Mesmo com autorização humana, o `pre-push` continua bloqueando o destino `main`.
O humano responsável executa o merge remoto do PR, após revisão e autorização
vinculadas ao PR e SHA, conforme [Revisão](revisao.md). Agentes não executam esse
merge nem desativam ou ignoram os hooks. Merge não autoriza deploy.

## Configuração efetiva e ativação dos hooks

A existência dos arquivos não ativa os hooks. Antes da ativação compartilhada,
conferir exatamente os quatro worktrees registrados e inspecionar, em cada um,
os valores aplicáveis, origens, escopos, includes e o destino efetivo de
core.hooksPath. A leitura limitada a --local não comprova a configuração efetiva.

Inspecionar também os hooks do diretório padrão resolvido pelo Git e a .githooks
de cada ambiente. Valor vazio ou distinto, override de processo, include
conflitante, precedência inconclusiva, quinto worktree, registro indisponível,
hook ativo preexistente ou arquivo inesperado bloqueiam a ativação.
Amostras inativas não equivalem a hooks ativos.

A v1 permite somente inserção local ausente de .githooks, com autorização para
todos os ambientes afetados e ausência de conflitos. Não compõe nem migra hooks,
não usa --replace-all, não altera configuração global e não habilita
extensions.worktreeConfig. Configuração por worktree existente é lida, sem
correção automática. Revalidar antes da escrita e consultar novamente os quatro
contextos depois dela. As fases Plan e Validate nunca executam hooks.
