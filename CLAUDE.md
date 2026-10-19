# Instruções para Claude Code

Este projeto utiliza [AGENTS.md](AGENTS.md) como fonte central das regras de
colaboração, dos quatro ambientes e das autorizações humanas.

Antes de iniciar uma tarefa:

1. Leia `AGENTS.md` e confirme o diretório, o worktree e a branch com
   `git branch --show-current`.
2. Consulte o documento do papel atribuído em `docs/agentes/`.
3. Respeite o escopo autorizado e o fluxo de revisão, PR e autorização humana.

Não assuma que está na `feature/claude`. No worktree
`template-dev-multiagente`, branch `main`, atue exclusivamente em
coordenação, sem editar arquivos, fazer commits ou desenvolver. A sincronização
local após PR integrado é a exceção operacional descrita em
[AGENTS.md](AGENTS.md#sincronizacao-da-coordenacao). O Claude desenvolve em
`template-dev-multiagente-claude` / `feature/claude`; o Codex desenvolve em
`template-dev-multiagente-codex` / `feature/codex`. Tarefas de manutenção pertencem a
`template-dev-multiagente-manutencao` / `chore/manutencao`, conforme
[Manutenção](docs/agentes/manutencao.md).

A revisão é simétrica e somente leitura por padrão: Claude revisa Codex e Codex
revisa Claude, inclusive em manutenção. O revisor não pode ser autor das
alterações. Siga [Revisão](docs/agentes/revisao.md); uma correção autorizada gera
autoria e exige revisão independente das novas alterações.

Não modifique outros worktrees. Alterações de governança exigem autorização
humana prévia. Somente o humano autoriza commit, push, merge e operações
sensíveis, para uma operação ou conjunto delimitado. Delegações de agentes apenas
reproduzem autorização humana anterior identificável, sem ampliar os limites,
conforme [AGENTS.md](AGENTS.md#autorizações-humanas-e-delegações).

Fetch e sincronização fast-forward segura seguem as condições de `AGENTS.md`,
inclusive a exceção da `main` após PR integrado, somente no worktree atribuído
à sincronização. Merges não fast-forward, rebases e operações destrutivas dependem
de autorização humana explícita. O merge remoto na `main` é executado somente
pelo humano responsável, após revisão e autorização vinculadas ao PR e SHA
completo. Agentes não executam esse merge; merge não autoriza deploy.

As restrições de hooks de `AGENTS.md` também se aplicam ao Claude Code. Para
outros projetos, adapte os nomes em conjunto conforme o
[documentação de atualização](docs/atualizacao.md), preservando as regras.
