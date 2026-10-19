# Proposta de atualização do README

Este arquivo é uma proposta para revisão humana. O `README.md` existente na raiz deve permanecer intacto nesta entrega. O texto abaixo foi escrito para ocupar futuramente a raiz; seus links são relativos à raiz do repositório, não a este documento em `docs/`.

---

# template-dev-multiagente

Template de governança para projetos com coordenação, Codex, Claude e manutenção, usando um clone principal e três worktrees vinculados ao mesmo repositório Git.

Esta versão entrega a estrutura inicial, a governança do próprio template, o material parametrizado, o esquema de configuração e os hooks. O instalador PowerShell e a suíte de testes ainda não estão implementados. Nenhum consumidor é instalado e nenhum hook é ativado automaticamente por esta entrega.

| Papel | Diretório do consumidor | Branch padrão |
| --- | --- | --- |
| Coordenação | `<slug>` | `main` |
| Codex | `<slug>-codex` | `feature/codex` |
| Claude | `<slug>-claude` | `feature/claude` |
| Manutenção | `<slug>-manutencao` | `chore/manutencao` |

Os arquivos de governança da raiz e `docs/agentes/` regem o desenvolvimento deste template. O material em `templates/` destina-se à geração futura para consumidores. A única configuração editável do consumidor será `multiagente.config.json`, fora dos quatro worktrees; veja o [exemplo fictício](config/project.example.json) e o [esquema 1.0](schema/project.schema.json).

A futura instalação terá `Plan` como padrão, sem modificações. Destinos idênticos serão preservados; arquivos diferentes, inclusive README e atributos, bloquearão a geração. Não haverá atualização ou resolução automática de conflitos. Revisão independente e autorização humana delimitada precederão a integração via PR; o merge remoto será exclusivamente humano e o deploy terá autorização separada.

Leia a [Especificação Técnica v1.1](docs/especificacao-v1.md), os [contratos de instalação](docs/instalacao.md), as [autorizações](docs/autorizacoes.md), os [limites de atualização](docs/atualizacao.md) e os [contratos de templates](docs/templates.md). A especificação preserva o estado documental “para revisão”; ela não concede autorização operacional por si só.

Os hooks protegem a branch de coordenação contra commit e push por destino. Sua presença não comprova ativação, autorização ou proteção do servidor. A configuração efetiva deverá ser validada nos quatro contextos antes de uma ativação autorizada. Documentos, JSON e hooks exigem UTF-8 sem BOM e LF; os hooks exigem modo Git `100755`.

O instalador, quando implementado, não fará commit, push, PR, merge, rebase, deploy, instalação automática de dependências, migração de hooks ou alteração global de configuração.
