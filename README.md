# template-dev-multiagente

Template de governança para projetos com coordenação, Codex, Claude e manutenção. Usa um clone principal e três worktrees vinculados ao mesmo repositório Git.

O instalador PowerShell implementa quatro fases: `Plan`, `PrepareMaintenance`, `CompleteWorktrees` e `Validate`. O pacote também contém templates, esquema de configuração, hooks e executor de testes. Seu estado é **pré-release `0.1.0-dev.9` (`homologacao-local`)**: não houve release `1.0.0` nem publicação remota autorizada.

## Ambientes do consumidor

| Papel | Diretório | Branch padrão |
| --- | --- | --- |
| Coordenação | `<slug>` | `main` |
| Codex | `<slug>-codex` | `feature/codex` |
| Claude | `<slug>-claude` | `feature/claude` |
| Manutenção | `<slug>-manutencao` | `chore/manutencao` |

A única configuração editável do consumidor é `multiagente.config.json`, fora dos quatro worktrees. Consulte o [exemplo fictício](config/project.example.json) e o [esquema 1.0](schema/project.schema.json).

## Requisitos básicos

- Windows 10 ou 11 x64 com Job Objects; Windows PowerShell 5.1 ou PowerShell 7.
- Git for Windows 2.44 ou superior, com `sh.exe` e `ssh.exe` da própria instalação.
- Política de execução que permita scripts locais; diretório pai local, absoluto e existente; repositório remoto com commit inicial na branch de coordenação.
- Transporte HTTPS ou SSH configurado pelo usuário. O instalador não instala dependências nem gerencia credenciais.
- Pester 5.7.1 é necessário **somente para executar os testes**, não para usar o instalador.

A compatibilidade foi comprovada localmente no Windows 11 build 26300, com Git 2.52.0, Windows PowerShell 5.1 e PowerShell 7.6.9. Consulte os [requisitos e limites completos](docs/instalacao.md#requisitos).

## Primeiros comandos

Use a raiz de uma cópia isolada e íntegra dos 47 arquivos inventariados e do `package.manifest.json`. O worktree de desenvolvimento pode conter arquivos extras e não é o pacote distribuível. O caminho de configuração abaixo é fictício:

```powershell
powershell -NoProfile -File .\scripts\Install-MultiAgentProject.ps1 -Config 'C:\Projetos Compartilhados\multiagente.config.json' -Phase Plan
powershell -NoProfile -File .\scripts\Install-MultiAgentProject.ps1 -Config 'C:\Projetos Compartilhados\multiagente.config.json' -Phase Validate
```

`Plan` é a fase padrão; ela e `Validate` somente inspecionam. `PrepareMaintenance` prepara a manutenção e `CompleteWorktrees` conclui os ambientes e, quando autorizado, a configuração dos hooks. Essas duas fases podem modificar o consumidor e exigem autorizações humanas próprias, parâmetros e pré-condições descritos no [fluxo completo](docs/instalacao.md#fluxo-completo). Destinos idênticos são preservados; conflitos, inclusive no README e nos atributos, bloqueiam a geração. Não há atualização ou resolução automática de conflitos.

## Homologação e limites

A homologação **local** aceita registrou nove suítes e 417/417 casos em cada host x64: Windows PowerShell 5.1 e PowerShell 7.6.9, com Pester 5.7.1 e código de saída 0. Uma execução separada no 5.1 x86 também aprovou 417/417 casos, mas terminou com código 2 porque dois critérios exigem ambos os hosts. Isso não comprova instalação em um consumidor real. Windows 10, Windows Server, Git 2.44, outras versões do PowerShell 7 e proteções remotas não foram homologados.

O instalador não faz commit, push, PR, merge, rebase ou deploy. Revisão cruzada independente e autorização humana delimitada regem a integração; somente o humano responsável executa o merge remoto na `main`. Os hooks locais não substituem proteção do servidor.

## Documentação

- [Instalação, integridade do pacote e testes](docs/instalacao.md)
- [Especificação Técnica v1.1](docs/especificacao-v1.md) e [errata](docs/errata-especificacao-v1.1.md)
- [Autorizações](docs/autorizacoes.md), [atualização e preservação](docs/atualizacao.md) e [contrato dos templates](docs/templates.md)
- [Regras dos agentes](AGENTS.md) e [revisão cruzada](docs/agentes/revisao.md)

O relatório de homologação é uma evidência interna do repositório de desenvolvimento e não integra o pacote distribuível. O manifesto registra integridade, mas não comprova origem confiável nem autoriza publicação.
