# Proposta de atualização do README

Este arquivo é uma proposta para revisão humana. O `README.md` existente na raiz permanece intacto na Etapa 6. O texto abaixo foi escrito para uma eventual atualização futura da raiz; seus links são relativos à raiz do repositório, não a este documento em `docs/`. Aplicá-lo exige autorização própria.

---

# template-dev-multiagente

Template de governança para projetos com coordenação, Codex, Claude e manutenção, usando um clone principal e três worktrees vinculados ao mesmo repositório Git.

A v1.0 tem as quatro fases funcionais `Plan`, `PrepareMaintenance`, `CompleteWorktrees` e `Validate`, além do material parametrizado, esquema de configuração, hooks e executor de testes. A homologação local foi aceita: nove suítes e 417/417 casos em cada um dos hosts Windows PowerShell 5.1 x64 e PowerShell 7.6.9 x64, com Pester 5.7.1 e saída 0; uma execução separada no 5.1 x86 também aprovou 417/417, mas saiu com código 2 por dois critérios que exigem ambos os hosts. O manifesto permanece em `0.1.0-dev.9` (`homologacao-local`), sem release `1.0.0` ou publicação remota autorizada.

| Papel | Diretório do consumidor | Branch padrão |
| --- | --- | --- |
| Coordenação | `<slug>` | `main` |
| Codex | `<slug>-codex` | `feature/codex` |
| Claude | `<slug>-claude` | `feature/claude` |
| Manutenção | `<slug>-manutencao` | `chore/manutencao` |

Os arquivos de governança da raiz e `docs/agentes/` regem o desenvolvimento deste template. O material em `templates/` é gerado para consumidores nas fases autorizadas. A única configuração editável do consumidor é `multiagente.config.json`, fora dos quatro worktrees; veja o [exemplo fictício](config/project.example.json) e o [esquema 1.0](schema/project.schema.json).

`Plan` é a fase padrão e somente lê; `Validate` também não modifica. `PrepareMaintenance` e `CompleteWorktrees` exigem autorizações humanas específicas, preservam destinos idênticos e bloqueiam conflitos, inclusive no README e nos atributos. Não há atualização ou resolução automática de conflitos. Revisão independente e autorização humana delimitada precedem a integração via PR; o merge remoto é exclusivamente humano e o deploy exige autorização separada.

Leia a [Especificação Técnica v1.1](docs/especificacao-v1.md) com sua [errata](docs/errata-especificacao-v1.1.md), os [comandos e requisitos de instalação](docs/instalacao.md), as [autorizações](docs/autorizacoes.md), os [limites de atualização](docs/atualizacao.md) e os [contratos de templates](docs/templates.md). O relatório `docs/homologacao-v1.0.md` está no repositório de trabalho e não integra o pacote distribuível. A especificação preserva o estado documental “para revisão”; ela não concede autorização operacional por si só.

Os hooks protegem a branch de coordenação contra commit e push por destino. Sua presença não comprova ativação, autorização ou proteção do servidor. A configuração efetiva é validada nos quatro contextos antes de uma ativação autorizada. Documentos, JSON e hooks exigem UTF-8 sem BOM e LF; os hooks exigem modo Git `100755`.

O instalador não faz commit, push, PR, merge, rebase, deploy, instalação automática de dependências, migração de hooks ou alteração global de configuração. A execução local foi comprovada no Windows 11 build 26300 com Git 2.52.0; Windows 10, Windows Server, Git 2.44 e proteções remotas ainda não foram homologados.
