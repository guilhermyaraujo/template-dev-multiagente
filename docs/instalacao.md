# Instalação

Este documento descreve a implementação funcional da v1.0, homologada localmente. O manifesto ainda registra `0.1.0-dev.9` (`homologacao-local`): não houve release `1.0.0` nem autorização de publicação remota. Os comandos mutáveis abaixo são exemplos para um consumidor fictício e dependem das autorizações e pré-condições indicadas. A [Especificação Técnica v1.1](especificacao-v1.md), lida com a [errata](errata-especificacao-v1.1.md), é a referência normativa; as regras de autorização estão em [Autorizações](autorizacoes.md) e o contrato de renderização em [templates](templates.md).

O instalador prepara governança e worktrees. Não cria a aplicação, não instala dependências, não altera configuração global, não faz commit, push, PR, merge, rebase nem deploy, e não consulta o servidor para comprovar revisão, aprovação ou proteção remota.

## Requisitos

| Requisito | Situação na v1.0 |
| --- | --- |
| Windows 10 ou 11 (x64), com Job Objects | Homologado localmente somente no Windows 11 build 26300 |
| Windows PowerShell 5.1 | Homologado localmente em x64 e x86 (as nove suítes, 417 casos, pelo Pester 5.7.1); a chamada x86 de host único terminou com código 2 por AC01 e AC32 pendentes, sem falhas |
| PowerShell 7 | Homologado localmente somente com 7.6.9 x64 (as nove suítes, 417 casos, pelo Pester 5.7.1); outras versões 7.x não verificadas |
| Pester 5.7.1 (somente para os testes) | Versão exata fixada em `tests\PesterRequirement.psd1`; instalada por usuário em cada PowerShell usado nos testes |
| Git for Windows 2.44 ou superior, com `sh.exe` e `ssh.exe` da própria instalação | Homologado localmente com 2.52.0 |
| Política de execução que permita scripts locais (por exemplo `RemoteSigned`) | O instalador não altera a política nem usa bypass |
| Diretório pai local, absoluto e existente | UNC, compartilhamentos de rede, links e junctions são recusados |
| Repositório remoto com commit inicial na branch de coordenação | Fornecido por preparação humana externa |
| Transporte HTTPS ou SSH | Credenciais e chaves são responsabilidade do Git do usuário; o instalador não as transporta |

O instalador não instala dependências. Se um requisito faltar, a fase termina bloqueada ou com falha operacional, sem instalação automática.

## Obter e conferir o pacote

Use uma cópia do pacote formada exclusivamente pelos 47 arquivos inventariados em `package.manifest.json` e pelo próprio manifesto. Cada fase confere SHA-256, modo declarado e codificação dos arquivos inventariados e recusa arquivo presente e não inventariado, link ou junction no pacote. A integridade do manifesto não comprova a origem: a origem confiável, a publicação e uma eventual assinatura são decisões humanas.

Antes de entregar uma cópia, confira os SHA-256 dos 47 arquivos da origem contra o manifesto; o worktree de desenvolvimento pode conter arquivos extras e não deve ser confundido com o pacote. Monte uma cópia isolada somente com o inventário e o manifesto, sem `.git`, `poc/`, arquivos temporários ou propostas fora do inventário. Na raiz dessa cópia, use a função exportada pelo módulo. O resultado deve ter `Valid = True`, 47 entradas válidas e `DistributionVersion = 0.1.0-dev.9`. Este comando **somente lê** a cópia:

```powershell
Import-Module .\scripts\MultiAgentTemplate.psm1 -Force
$resultado = Test-MaPackageIntegrity -PackageRoot (Get-Location).Path
$resultado | Select-Object Valid, DistributionVersion, @{Name='Arquivos';Expression={$_.Files.Count}}, Issues
```

Verifique separadamente a origem confiável e os modos Git esperados: o manifesto declara modos, mas não os aplica nem constitui assinatura. O executor de testes com `-Package` também monta e verifica uma cópia isolada, mas executar sua suíte não é necessário para conferir somente os bytes do pacote.

O pacote não deve ficar dentro dos quatro worktrees do consumidor.

## Configuração

A única configuração editável é `multiagente.config.json`, fora dos quatro worktrees. Ela segue o [esquema 1.0](../schema/project.schema.json); o [exemplo](../config/project.example.json) é fictício.

```json
{
  "schemaVersion": "1.0",
  "project": { "name": "Portal de Serviços Aurora", "slug": "portal-servicos-aurora" },
  "repository": { "url": "https://github.com/organizacao-exemplo/portal-servicos-aurora.git" },
  "workspace": { "parentDirectory": "C:\\Projetos Compartilhados\\Aurora" }
}
```

| Papel | Diretório | Branch padrão |
| --- | --- | --- |
| Coordenação (clone principal) | `<slug>` | `main` |
| Codex | `<slug>-codex` | `feature/codex` |
| Claude | `<slug>-claude` | `feature/claude` |
| Manutenção | `<slug>-manutencao` | `chore/manutencao` |

As branches podem ser alteradas em `branches`, sujeitas ao alfabeto restrito, a `git check-ref-format --branch`, à distinção sem caixa e à ausência de hierarquia entre elas.

## Fluxo completo

Os comandos abaixo partem da raiz do pacote. Valores entre apóstrofos são literais do PowerShell; um apóstrofo interno é duplicado. Em PowerShell 7, substitua `powershell` por `pwsh` quando esse executável estiver disponível; os parâmetros do script são os mesmos.

### 1. Plan (padrão, somente leitura)

```powershell
powershell -NoProfile -File .\scripts\Install-MultiAgentProject.ps1 -Config 'C:\Projetos Compartilhados\multiagente.config.json'
```

Valida pacote e configuração, renderiza em memória e inspeciona os quatro destinos. Não grava arquivos, relatórios ou temporários, não faz fetch nem clone e não executa hooks. Ambientes ausentes aparecem como ações previstas.

### 2. PrepareMaintenance (mutável, autorização humana)

Simule primeiro e depois execute com a mesma autorização:

```powershell
powershell -NoProfile -File .\scripts\Install-MultiAgentProject.ps1 -Config 'C:\Projetos Compartilhados\multiagente.config.json' -Phase PrepareMaintenance -AuthorizationReference 'registro-humano#preparacao' -BaseCommit '<SHA completo da base autorizada>' -WhatIf
powershell -NoProfile -File .\scripts\Install-MultiAgentProject.ps1 -Config 'C:\Projetos Compartilhados\multiagente.config.json' -Phase PrepareMaintenance -AuthorizationReference 'registro-humano#preparacao' -BaseCommit '<SHA completo da base autorizada>'
```

`-BaseCommit` deve ser o SHA completo de um commit disponível localmente na coordenação, com 40 ou 64 caracteres hexadecimais minúsculos conforme o formato de objetos do repositório. Na criação da manutenção, deve coincidir com o HEAD da coordenação e com a ponta de uma branch de manutenção preexistente. Se a manutenção já existir, um checkout pendente exige HEAD igual à base; após um commit da preparação, o HEAD pode avançar desde que derive da base e não haja destinos governados ausentes a gerar. Clona a coordenação quando ausente (sem checkout até conferir filtros, hooks, submódulos e atributos), cria a manutenção na base autorizada e gera nela somente os onze destinos governados ausentes. Não cria Codex/Claude, não ativa hooks, não prepara o índice e não faz commit.

### 3. Etapas humanas fora do instalador

1. Revisar os arquivos gerados na manutenção.
2. Com autorização humana específica de commit, preparar somente os caminhos aprovados no índice da manutenção, conferir os modos `100755` dos hooks e registrar o commit. Essa operação é externa ao instalador.

3. Com autorização de push, publicar a manutenção e abrir o PR para a coordenação.
4. Revisão independente do HEAD completo do PR (M) por agente distinto do autor.
5. Autorização humana do merge vinculada ao PR e a M; merge remoto executado pelo humano responsável. M e o commit integrado (I) podem ser distintos (squash).
6. No worktree da coordenação, pelo responsável atribuído: `git fetch origin` e `git merge --ff-only --no-autostash origin/<coordenação>`, conforme [AGENTS.md](../AGENTS.md#sincronizacao-da-coordenacao). A referência `refs/remotes/origin/<coordenação>` precisa conter I.
7. Registrar a evidência da integração e a autorização da conclusão no registro JSON descrito abaixo, fora dos quatro worktrees.

### 4. CompleteWorktrees (mutável, autorização humana)

Simule primeiro e depois execute com a mesma autorização, o mesmo I e o mesmo registro:

```powershell
powershell -NoProfile -File .\scripts\Install-MultiAgentProject.ps1 -Config 'C:\Projetos Compartilhados\multiagente.config.json' -Phase CompleteWorktrees -AuthorizationReference 'registro-humano#conclusao' -IntegratedCommit '<I completo>' -IntegrationReference 'C:\Projetos Compartilhados\registros\integracao.json' -WhatIf
powershell -NoProfile -File .\scripts\Install-MultiAgentProject.ps1 -Config 'C:\Projetos Compartilhados\multiagente.config.json' -Phase CompleteWorktrees -AuthorizationReference 'registro-humano#conclusao' -IntegratedCommit '<I completo>' -IntegrationReference 'C:\Projetos Compartilhados\registros\integracao.json'
```

Com `-WhatIf`, nada é criado nem configurado: o relatório lista as ações previstas e termina com código 2 se houver ações simuladas ou pendências, 3 se houver bloqueio e 0 se não houver ações pendentes nem impedimentos. A execução efetiva (segundo comando) cria Codex e Claude ausentes em I, sem reposicionar branches, confere o conteúdo governado de M, I e da coordenação por bytes, tipo e modo, e insere `core.hooksPath=.githooks` na configuração local somente se os quatro ambientes permitirem e a autorização registrar `configure-hooks`. Termina com código 0 quando os quatro ambientes ficam concluídos e os hooks ativados; com 2 quando algo permanece pendente (por exemplo, registro sem `configure-hooks`: worktrees criados e ativação dos hooks pendente); com 3 quando uma pré-condição, a evidência ou o alcance bloqueia; com 4 em falha operacional, preservando e relatando o que já foi feito. Não faz fetch e não sincroniza a coordenação. Em seguida, confirme com Validate informando o mesmo I e o mesmo registro.

### 5. Validate (somente leitura)

```powershell
powershell -NoProfile -File .\scripts\Install-MultiAgentProject.ps1 -Config 'C:\Projetos Compartilhados\multiagente.config.json' -Phase Validate
powershell -NoProfile -File .\scripts\Install-MultiAgentProject.ps1 -Config 'C:\Projetos Compartilhados\multiagente.config.json' -Phase Validate -IntegratedCommit '<I completo>' -IntegrationReference 'C:\Projetos Compartilhados\registros\integracao.json'
```

Reconstrói o estado por arquivos, objetos Git, índice e configuração efetiva e separa a conformidade local (Conforme, Incompleta, Divergente ou Inconclusiva), as alterações de trabalho, a evidência fornecida e a proteção remota, que nunca é verificada.

## Autorizações humanas exigidas

| Etapa | Autorização | Parâmetro ou registro |
| --- | --- | --- |
| Plan e Validate | Nenhuma além da atribuição de leitura | — |
| PrepareMaintenance | Clone, criação da manutenção e geração, com destinos e base | `-AuthorizationReference`, `-BaseCommit` |
| Commit e push da manutenção, PR | Autorizações humanas próprias | Fora do instalador |
| Merge remoto | Humano responsável, vinculado ao PR e a M | Fora do instalador; registrado na evidência |
| Sincronização da coordenação | Responsável no próprio worktree | Fora do instalador |
| CompleteWorktrees | Criação dos ambientes listados e, se for o caso, configuração dos hooks nos quatro | `-AuthorizationReference`, `-IntegratedCommit`, `-IntegrationReference` |

`AuthorizationReference` é uma referência de uma linha, sem controles, com até 500 caracteres, para a autorização humana verificável. Ela é registrada como evidência; o instalador não infere aprovação de sua existência.

## Registro JSON de integração

Formato 1.0, UTF-8, até 64 KiB, fora dos quatro worktrees. Todos os campos são obrigatórios e conferidos por grafia exata; textos têm uma linha, sem controles, com até 500 caracteres. Booleanos ou textos de aprovação não são aceitos. Nenhum texto do registro é reproduzido nos relatórios; somente seu SHA-256.

```json
{
  "evidenceVersion": "1.0",
  "repository": "https://github.com/organizacao-exemplo/portal-servicos-aurora.git",
  "pullRequest": "https://github.com/organizacao-exemplo/portal-servicos-aurora/pull/1",
  "sourceBranch": "chore/manutencao",
  "targetBranch": "main",
  "reviewedHead": "<M completo>",
  "review": { "reviewer": "Codex", "author": "Claude", "reference": "<link do parecer>", "reviewedHead": "<M completo>" },
  "mergeAuthorization": { "authorizedBy": "<responsável>", "reference": "<link da autorização>", "pullRequest": "https://github.com/organizacao-exemplo/portal-servicos-aurora/pull/1", "reviewedHead": "<M completo>" },
  "integration": { "result": "merged", "method": "squash", "resultingCommit": "<I completo>", "executedBy": "<responsável>", "proofSource": "<link do merge no servidor>" },
  "completionAuthorization": {
    "authorizedBy": "<responsável>",
    "reference": "registro-humano#conclusao",
    "integratedCommit": "<I completo>",
    "environments": ["portal-servicos-aurora", "portal-servicos-aurora-codex", "portal-servicos-aurora-claude", "portal-servicos-aurora-manutencao"],
    "operations": ["create-worktrees", "configure-hooks"]
  }
}
```

Regras conferidas: `repository` igual à URL configurada; `sourceBranch` e `targetBranch` iguais às branches de manutenção e coordenação; `reviewedHead` repetido em `review` e `mergeAuthorization`; `reviewer` distinto de `author`, inclusive por caixa e espaços; `method` entre `merge`, `squash` e `rebase`; `resultingCommit` igual a `-IntegratedCommit` e a `completionAuthorization.integratedCommit`; `completionAuthorization.reference` igual a `-AuthorizationReference`; `configure-hooks` exige os quatro diretórios em `environments`. O registro é evidência declarada e conferida somente contra os objetos Git locais.

## Resultados, códigos de saída e erros

| Código | Resultado | Significado |
| --- | --- | --- |
| 0 | Sucesso | Fase concluída sem pendências |
| 2 | Incompleto | Nada bloqueou, mas há ações previstas, simuladas (`-WhatIf`) ou pendentes |
| 3 | Bloqueado | Pré-condição, conflito, evidência ou alcance impediu a fase |
| 4 | Falha operacional | Erro de execução; operações já realizadas são preservadas e relatadas |

O relatório identifica fase, resultado, ações previstas ou realizadas, ocorrências com código `MA_*`, verificações pendentes e, nas fases mutáveis, se houve execução parcial. Famílias exemplificativas: `MA_CONFIG_*`, `MA_JSON_*`, `MA_SCHEMA_*`, `MA_PROJECT_*` e `MA_BRANCH_*` (configuração); `MA_REPOSITORY_*` e `MA_REMOTE_*` (repositório e transporte); `MA_PACKAGE_*`, `MA_TEMPLATE_*` e `MA_RENDER_*` (pacote e renderização); `MA_PATH_*` (caminhos); `MA_GIT_*` e `MA_NATIVE_*` (Git e processos); `MA_ENV_*`, `MA_WORKTREE_*` e `MA_FILE_*` (ambientes e destinos); `MA_HOOKS_*` (configuração efetiva dos hooks); `MA_PREPARE_*`, `MA_COMPLETE_*`, `MA_INTEGRATION_*` e `MA_VALIDATE_*` (fases). Há também códigos específicos de autorização e commits, entre outros. Uma exceção não prevista termina com código 4 e `MA_<FASE>_UNEXPECTED_FAILURE` na saída de erro.

## Autenticação, SSH e verificações remotas

- O clone usa o Git localizado, com transportes restritos a HTTPS e SSH. Reescritas `url.*.insteadOf` para outros protocolos, remote helpers, `remote.origin.vcs` e `alias.remote-ssh` são recusados.
- SSH usa somente o `ssh.exe` da instalação do Git. `core.sshCommand`, `GIT_SSH` e `GIT_SSH_COMMAND` são recusados na v1.0. Chaves, agentes e `known_hosts` são do usuário; o instalador não os cria nem os transporta.
- HTTPS usa os helpers da instalação do Git; credenciais ficam no gerenciador de credenciais do usuário e nunca aparecem nos relatórios.
- Nenhuma fase faz fetch. A sincronização da coordenação e a atualização das referências remotas são etapas humanas.
- PR, revisão, merge, proteção de branch e permissões do servidor não são consultados. Validate informa a proteção remota como não verificada. A homologação remota exige repositório, contas e autorização próprios.

## Retomada segura e preservação de dados

- Antes da primeira gravação, todos os destinos são classificados como ausentes, idênticos ou conflitantes. Somente ausentes seguros e autorizados são criados; idênticos permanecem; conflitos bloqueiam a geração, inclusive em README e `.gitattributes`.
- Não há append, fusão, backup seguido de substituição, exclusão automática, migração ou reposicionamento de branches.
- O estado é revalidado imediatamente antes de cada alteração. Uma falha posterior a uma operação é relatada como execução parcial, sem rollback destrutivo: clone, worktrees e arquivos já criados são preservados.
- Clone ou worktree sem checkout deixados por interrupção são reconhecidos e concluídos na repetição, depois de conferir filtros, hooks e atributos.
- A repetição antes do commit reconhece arquivos gerados idênticos; após a instalação concluída, a repetição não produz alteração.
- Fases mutáveis do mesmo repositório se excluem mutuamente; Validate consulta essa exclusão sem obtê-la.
- Conflitos são resolvidos fora do instalador, em manutenção, sob escopo humano específico.

## Testes

```powershell
powershell -NoProfile -File .\tests\Invoke-Tests.ps1
powershell -NoProfile -File .\tests\Invoke-Tests.ps1 -Package
powershell -NoProfile -File .\tests\Invoke-Tests.ps1 -Engine Harness
```

Por padrão, as suítes rodam no Windows PowerShell 5.1 do System32 e no PowerShell 7 encontrado no PATH (`pwsh`); um PowerShell ausente fica pendente. Com `powershell -File`, `-Suite` e `-PowerShellPath` aceitam um único valor por chamada (a lista separada por vírgula chega como um texto só e é recusada). A rodada local aceita usou `-Package -TimeoutMinutes 120` e o motor padrão Pester; o relatório `docs/homologacao-v1.0.md` está no repositório de trabalho, fora do pacote distribuível. Repetir a suíte integral pode demorar horas; para conferir apenas o pacote, use o procedimento de integridade acima.

O executor roda as suítes em série, cada uma em processo próprio contido em Job Object, nas fixtures descartáveis criadas sob o TEMP, nunca no projeto atual. Antes de executar, obtém da AST de cada suíte os casos esperados; uma suíte só é aprovada quando cada caso esperado é contabilizado exatamente uma vez e resumo, linhas `[PRE-REQ]` e código de saída concordam — execução truncada, caso ausente, repetido ou desconhecido deixa a suíte inconclusiva. Prazo, descendente ativo após a suíte ou interrupção encerram todos os processos do job e conferem o término; somente processos da árvore da suíte são encerrados. Informa Windows, PowerShell, Git e Pester utilizados, o resultado por suíte e total (aprovados, falhas, ignorados, bloqueados por pré-requisito e não executados), os processos e a cobertura dos critérios de aceitação. `-Package` monta e confere a cópia isolada do pacote e executa a partir dela. Códigos: 0 aprovado; 1 falha ou suíte inconclusiva; 2 pendente (por exemplo, PowerShell 7 ou Pester 5 ausente); 3 execução recusada.

Pester: a especificação exige Pester 5 com versão fixada. A versão exata é `5.7.1`, declarada em `tests\PesterRequirement.psd1`. O motor padrão (`-Engine Pester`) executa e avalia cada caso de cada suíte por um `It` do Pester 5.7.1: o adaptador `tests\pester\NativeSuite.Tests.ps1` monta, a partir da AST da suíte e sem alterá-la, um teste Pester por caso esperado, que executa o bloco do próprio caso no processo Pester (contido em Job Object). Um caso é aprovado somente se o Pester o aprovar; a suíte, somente com resultado global `Passed`, código 0, versão carregada igual à fixada, cada caso esperado exatamente uma vez e contagens coerentes. Sem o Pester 5.7.1 instalado no PowerShell, o motor fica pendente; o executor não instala, não baixa e não carrega outra versão. `-Engine Harness` é auxiliar: executa o mini-harness autocontido das suítes e deixa o resultado pendente quanto à seção 8.

O Pester 5.7.1 é dependência somente dos testes, não do instalador. Instale-o por usuário, a partir da PowerShell Gallery, em cada PowerShell usado (por exemplo `Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser`, que exige o PowerShellGet), e confira a versão com `Get-Module -ListAvailable Pester`. No Windows PowerShell 5.1, o Pester 3.4.0 embutido permanece instalado; com o 5.7.1 por usuário, `Import-Module Pester` sem versão passa a carregar o 5.7.1.

Interrupção: Ctrl+C durante a execução para o executor em até cerca de meio segundo durante a espera de uma suíte (até cerca de 30 s se ocorrer na leitura final da saída); os processos da suíte em andamento são encerrados e o encerramento é conferido antes do retorno; o executor informa no erro padrão os encerramentos confirmados e não emite resultado geral. O encerramento abrupto do próprio executor (processo encerrado, console fechado, desligamento) não executa a limpeza: o Windows encerra os processos da suíte ao fechar o Job Object (`KILL_ON_JOB_CLOSE`), sem confirmação nem relatório. Em toda interrupção, fixtures da suíte interrompida podem restar sob o TEMP.

## Limitações conhecidas

- Compatibilidade comprovada localmente somente no Windows 11 build 26300, Windows PowerShell 5.1 (x64 e x86), PowerShell 7.6.9 x64, Git 2.52.0 e Pester 5.7.1. Windows 10, Windows Server, Git 2.44 e outras versões não foram homologados. Proteções remotas também não foram verificadas.
- Hooks locais bloqueiam commit na coordenação e push para ela; não validam identidade, revisão ou autorização e não substituem proteção do servidor. HEAD destacado continua não tratado pelos hooks e é recusado pelo instalador.
- UNC, compartilhamentos de rede, bare, clones rasos, partial clones, submódulos e configurações que exijam migração ficam fora da instalação automática.
- Não há atualização automática, composição ou migração de hooks, `--replace-all`, alteração global ou habilitação de `extensions.worktreeConfig`.
