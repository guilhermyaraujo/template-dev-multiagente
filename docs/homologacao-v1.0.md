# Homologação local da versão 1.0 — relatório

Relatório de trabalho para a revisão independente, preparado em `template-dev-multiagente-claude` / `feature/claude` a partir do checkpoint funcional `eb70b901aaa749237ea91abf63d3b256e786fbe2`. Não é documento governado nem faz parte do inventário do `package.manifest.json`. Não constitui aprovação, homologação remota ou autorização de publicação.

Rodadas:

- Rodada 1 — 24 de outubro de 2026: executor central, suíte do executor, manifesto e propostas. Revisão independente (Codex): BLOQUEAR HOMOLOGAÇÃO LOCAL.
- Rodada 2 — 25 de outubro de 2026: completude pelo catálogo AST, Job Object e preparação do Pester 5. Revisão independente (Codex): ACEITAR PARCIALMENTE AS CORREÇÕES LOCAIS; quatro fases funcionais aprovadas.
- Rodada 3 — 25 e 26 de outubro de 2026 (este relatório): falso positivo do motor Pester, Pester 5.7.1 executando nativamente os casos, PowerShell 7, Ctrl+C e evidências.

## Situação dos impedimentos da rodada 2

| # | Impedimento | Situação | Síntese |
| --- | --- | --- | --- |
| 1 | Falso positivo em `Get-PesterVerdict` | Corrigido | Aprovação somente com resultado global `Passed`, código 0, versão carregada igual à fixada, cada caso esperado exatamente uma vez e contagens coerentes. Resultado global `Failed` com casos `Passed` reprova: teste simulado e execução real do Pester com `AfterAll` falho |
| 2 | Pester 5.7.1 executando e avaliando os casos (§8) | Atendido | Pester 5.7.1 e PowerShell 7.6.9 instalados por usuário, de fonte oficial. Cada caso é executado pelo próprio bloco dentro de um `It` do Pester, sem reescrever as suítes. É o motor padrão do executor |
| 3 | Controle de processos | Corrigido e documentado | Job Object preservado. Espera fatiada para atender Ctrl+C; quatro motivos de encerramento distintos; parada do pipeline testada com processos descartáveis; término abrupto documentado, sem teste invasivo |
| 4 | Homologação e evidências | Atendido localmente | Rodada integral ininterrupta a partir do pacote isolado: 417/417 casos no Windows PowerShell 5.1 x64 e no PowerShell 7.6.9 x64. Rodada separada no 5.1 x86: 417/417 |

## Ambiente efetivamente utilizado

| Item | Valor observado |
| --- | --- |
| Windows | 10.0.26300 (DisplayVersion 26H2), x64; sessão sem privilégio administrativo |
| Windows PowerShell | 5.1.26100.9711 Desktop, x64 (System32) e x86 (SysWOW64); política efetiva `RemoteSigned` (inalterada) |
| PowerShell 7 | 7.6.9 Core x64, instalação isolada por usuário em `%LOCALAPPDATA%\Programs\PowerShell\7.6.9`; política `RemoteSigned` |
| Pester | 5.7.1 (fixado), por usuário, para 5.1 e 7; o 3.4.0 embutido do Windows permanece instalado |
| Git | Git for Windows 2.52.0.windows.1 |

## Instalações realizadas (autorizadas nesta rodada)

Antes da instalação: `pwsh` ausente, Pester somente 3.4.0, sessão sem privilégio administrativo. Nenhuma das instalações exigiu privilégio, alterou política de execução, registro, PATH persistente ou o Windows PowerShell 5.1.

**PowerShell 7.6.9** — versão estável mais recente no repositório oficial `PowerShell/PowerShell` (release `v7.6.9`, não pré-lançamento, publicado em 25/10/2026 17:26 UTC).

- Pacote: `PowerShell-7.6.9-win-x64.zip` (109.620.855 bytes), baixado de `github.com/PowerShell/PowerShell/releases/download/v7.6.9/`.
- SHA-256 `ce7484804c0f0ad4dda10c958e71acdaf7eebfb22505c1b480f89e0e9f1da94d`, idêntico em três fontes: arquivo calculado, `hashes.sha256` do release e `digest` da API do GitHub.
- Assinatura Authenticode válida da Microsoft Corporation (emissor Microsoft Code Signing PCA 2024) em todos os 517 executáveis e DLLs extraídos.
- Instalação: ZIP extraído em `%LOCALAPPDATA%\Programs\PowerShell\7.6.9`, sem MSI e sem entrada no PATH. Nas execuções, o `pwsh` foi incluído somente no PATH do processo que iniciou o executor.

**Pester 5.7.1** — PowerShell Gallery: pacote `Pester` 5.7.1, publicado em 08/01/2025, proprietários `nohwnd` e `fflaten` (mantenedores do Pester). O release `5.7.1` do repositório oficial `pester/Pester` não traz anexos; a distribuição é pela Gallery.

- `pester.5.7.1.nupkg` (325.233 bytes), baixado de `www.powershellgallery.com/api/v2/package/Pester/5.7.1`.
- SHA-512 idêntico ao `PackageHash` publicado pela Gallery (`TZlqSN2UgW0m…TCc8oAg==`).
- Assinatura Authenticode válida de Jakub Jareš (autor do Pester; emissor DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1) em `Pester.psd1`, `Pester.psm1`, `Pester.ps1`, nos arquivos de formatação e nas duas `Pester.dll`.
- Instalação: conteúdo do pacote, sem os metadados NuGet (como faz o `Install-Module`), copiado para `Documents\WindowsPowerShell\Modules\Pester\5.7.1` (5.1 x64 e x86) e `Documents\PowerShell\Modules\Pester\5.7.1` (7). As duas cópias foram conferidas arquivo a arquivo (18 arquivos, SHA-256 idênticos aos do pacote verificado). Não foram usados PowerShellGet nem o provedor NuGet.
- Efeito colateral: no Windows PowerShell 5.1, `Import-Module Pester` sem versão passa a carregar o 5.7.1 em vez do 3.4.0. O 3.4.0 continua instalado e pode ser importado com `-RequiredVersion 3.4.0`.

`tests/PesterRequirement.psd1` agora fixa `RequiredVersion = '5.7.1'`.

## Correções realizadas

### 1. Veredito do motor Pester (`Get-PesterVerdict`)

Defeito: com resultado global `Failed`, os casos individuais `Passed`, sem falha de contêiner ou de bloco contabilizada e código 0, a suíte era aprovada.

Regras atuais, nesta ordem:

1. Falha do processo (não iniciado, prazo, interrupção, descendente persistente, saída incompleta, encerramento não confirmado): **Falha**.
2. Catálogo indeterminado: **Inconclusiva**.
3. Versão carregada recusada pelo processo Pester (código 3) ou `PESTER-ERRO`: **Falha**.
4. Resumo `PESTER-FIM` ausente, repetido, malformado ou com campos diferentes dos esperados; linha de caso malformada: **Inconclusiva**.
5. Versão carregada (`PESTER-VERSAO`) ausente, repetida ou diferente da fixada; versão fixada vazia: **Inconclusiva**.
6. Falha de contêiner ou de bloco (`BeforeAll`, `AfterAll`, descoberta): **Falha**.
7. Código de saída incoerente com o resultado global (`Passed` exige 0; `Failed` exige 1): **Falha**. Resultado global diferente de `Passed` e `Failed`: **Inconclusiva**.
8. Caso esperado ausente, duplicado, teste sem caso ou não catalogado, nome do teste diferente do caso, `NotRun`, `Inconclusive` ou outro resultado, e `Skipped` sem pré-requisito declarado: **Inconclusiva**.
9. Contagens do resumo (`Total`, `Passed`, `Failed`, `Skipped`, `NotRun`, `Inconclusive`) diferentes das dos testes emitidos: **Inconclusiva**.
10. Bloqueio da suíte inteira por pré-requisito: **Pendente** somente com todos os casos `Skipped` e resultado global `Passed`; caso executado: **Inconclusiva**.
11. Caso `Failed`: **Falha** com resultado global `Failed`; com `Passed`, **Inconclusiva**.
12. Resultado global `Failed` sem caso, bloco ou contêiner com falha: **Inconclusiva** (incoerente).
13. Caso `Skipped` com `-Requires` declarado: **Pendente**.
14. **Aprovada** somente com todos os casos esperados `Passed` e nenhuma das condições acima.

O processo Pester sai com 0 para `Passed`, 1 para `Failed`, 3 para versão carregada diferente da fixada e 4 para outro resultado ou erro. Também emite as falhas de bloco e de contêiner.

Testes negativos em `InvokeTests.Unit`, todos aprovados:

- reprodução do defeito apontado pela revisão: `Failed` com casos `Passed` e código 0 resulta em **Falha**; com código 1, **Inconclusiva**; com falha de bloco, **Falha**;
- 22 situações de incoerência ou incompletude, listadas nas regras acima;
- execução real do Pester 5.7.1 sobre uma suíte descartável: aprovação normal; caso falho reprova; falha na limpeza da suíte (`AfterAll`) com os três casos `Passed` reprova com resultado global `Failed`.

### 2. Execução nativa pelo Pester 5.7.1

Na rodada 2, o adaptador executava a suíte pelo harness antigo no `BeforeAll` e os testes Pester apenas conferiam o resultado de outro executor. Agora o Pester executa e avalia cada caso.

Solução (sem reescrever as suítes nem alterar sua arquitetura):

- As nove suítes têm forma uniforme: preâmbulo; mini-harness `It`; um único `try { casos } finally { limpeza }`; resumo. `Get-SuitePlan` obtém dessa forma, pela AST e sem executar o arquivo, as partes do plano:

  | Parte | O que é |
  | --- | --- |
  | Preâmbulo | Sem o mini-harness e sem o bloqueio da suíte |
  | Bloqueio da suíte | `if` do preâmbulo terminado em `exit`: condição e corpo, sem o `exit` |
  | Definições intercaladas | Funções e atribuições do bloco de casos, na ordem |
  | `finally` do mini-harness | Limpeza por caso |
  | `finally` da suíte | Limpeza da suíte |
  | Casos | Um bloco por caso do catálogo, com as variáveis do laço literal e o `-Requires` literal |

  Os trechos são reconstituídos do próprio arquivo, mascarando o restante, de modo que linhas, nome do arquivo e `$PSScriptRoot` continuam os da suíte.
- O adaptador `tests/pester/NativeSuite.Tests.ps1` (substitui `HarnessAdapter.Tests.ps1`) monta:

  | Bloco Pester | O que executa |
  | --- | --- |
  | `BeforeAll` | Preâmbulo, bloqueio e definições |
  | Um `It` por caso | O bloco do próprio caso; qualquer exceção falha o teste |
  | `AfterEach` | `finally` do mini-harness |
  | `AfterAll` | `finally` da suíte |
  | `Set-ItResult -Skipped` | Pré-requisito por caso ausente em `$script:Prereq`, com o mesmo critério do mini-harness |

  O mini-harness não executa nada.
- O harness roda a suíte com `powershell -File`, no escopo global. O adaptador reproduz isso: publica no escopo global do processo Pester as variáveis e funções definidas no nível do arquivo, porque blocos executados no escopo do módulo (`InModule`) as leem por ali. Variáveis de preferência ficam de fora. Sem isso, um caso de `Validate.Unit` falhava no Pester (`$I` não definido no escopo do módulo).
- Forma fora do contrato (try ausente ou repetido, catch, instrução não suportada no bloco de casos, caso fora dele, `exit` fora do bloqueio, mini-harness ausente ou com parâmetros inesperados) deixa o plano indeterminado. A suíte fica **Inconclusiva** sem ser executada.
- `-Engine Pester` é o motor padrão; `-Engine Harness` permanece como motor auxiliar explícito e deixa o resultado PENDENTE quanto à §8.
- TestDrive e TestRegistry do Pester ficam desligados: nenhum efeito fora das fixtures das suítes.

Equivalência verificada: o motor nativo e o harness produziram as mesmas duas falhas no Plan.Unit sob PowerShell 7 antes da correção do ambiente (seção seguinte), e os mesmos resultados aprovados nas demais suítes.

### 3. Defeito demonstrado no PowerShell 7 (código de teste)

No PowerShell 7, `[Environment]::SetEnvironmentVariable(nome, $null)` chega ao .NET como texto vazio e deixa a variável **definida e vazia**; no 5.1 ela é removida. As suítes limpavam ou restauravam variáveis assim, e a variável vazia contaminava os casos seguintes:

- `GIT_DIR=` e `GIT_CONFIG_PARAMETERS=` vazias: o instalador bloqueia corretamente com `MA_GIT_ENV_OVERRIDE`;
- `GIT_ALLOW_PROTOCOL=` vazia: o Git recusa `file://` nas fixtures.

Efeito observado: 2 falhas em Plan.Unit, iguais pelo Pester e pelo harness, e 44 falhas em três suítes de integração na primeira rodada integral.

Correção, autorizada para todas as ocorrências:

- 15 limpezas com `$null` literal passaram a usar `[NullString]::Value`;
- 7 restaurações de valor possivelmente nulo passaram a usar `[NullString]::Value` quando o valor salvo é nulo;
- os arquivos alterados são as suítes Plan.Unit, PrepareMaintenance.Unit e as quatro de integração, cerca de 25 linhas;
- as restaurações `[string]$SavedGitEnvironment[...]` não mudaram: os valores vêm da listagem de `Env:` e nunca são nulos.

O módulo do instalador não usa `SetEnvironmentVariable` e não foi alterado. Caso de regressão em `InvokeTests.Unit`: nenhuma suíte limpa ou restaura variável de ambiente com `$null`.

### 4. Controle de processos e interrupção

Job Object preservado sem mudança no módulo. No executor:

- A espera da suíte agora é feita em fatias de 250 ms. Antes era uma única espera nativa pelo prazo inteiro, e um Ctrl+C só seria atendido no fim da suíte ou no prazo (até 60 min).
- O registro de cada processo distingue o motivo do encerramento do job, e o resumo final mostra a contagem por motivo:

| Situação | Mecanismo | Encerramento | Relato |
| --- | --- | --- | --- |
| Prazo | Fim do prazo da suíte | Job encerrado e término conferido antes de devolver; `NaoConfirmado` é falha | Suíte reprovada; motivo `prazo` |
| Descendente ativo | Processo vivo após o fim da suíte | Idem | Suíte reprovada; motivo `descendente ativo` ou `saida retida por descendente` |
| Interrupção controlada | Exceção no executor, inclusive o ponto de interrupção dos testes | Idem, antes de propagar a exceção | Motivo `interrupcao controlada`; resultado geral FALHA se a execução continuar |
| Ctrl+C (parada do pipeline) | PowerShell para o pipeline; atendido entre as fatias da espera (até ~30 s se ocorrer na leitura final da saída) | Idem, no `finally`, antes de devolver | Sem resultado geral; mensagem no erro padrão com encerramentos confirmados e não confirmados |
| Término abrupto do executor | Processo encerrado, console fechado, desligamento | Nenhum `finally` executa; o fechamento do último handle aciona `KILL_ON_JOB_CLOSE`, que encerra os membros | O executor não confirma nem relata; não há evidência de encerramento |

Em toda interrupção, o `finally` da suíte interrompida não executa e fixtures podem restar sob o TEMP.

Verificação:

- **Teste automatizado** (`InvokeTests.Unit`): árvore descartável pai → filho → neto e prazo da suíte de 600 s. O pipeline parado por `PowerShell.Stop()`, o mesmo mecanismo que o console usa no Ctrl+C, terminou em menos de 30 s. O motivo registrado foi `parada do pipeline (Ctrl+C)`, sem marcar interrupção controlada nem prazo. Encerramento `Confirmado`, os três níveis ausentes e um processo descartável fora do job intacto.
- **Verificação única do executor inteiro**, fora da suíte, porque o executor em execução detém o mutex: cópia do executor com uma suíte descartável que apenas espera, parada pelo mesmo mecanismo. Parada concluída em 0,13 s; o processo da suíte não estava mais ativo. A mensagem no erro padrão foi "Execucao interrompida (parada do pipeline, por exemplo Ctrl+C) antes do resultado: sem resultado geral; 3 execucoes em Job Object; processos em execucao na interrupcao: 1 job(s), 1 com encerramento confirmado, 0 nao confirmados…". Mutex liberado; diretório de trabalho do executor removido.
- **Não verificado:**
  - o sinal de console real (`CTRL_C_EVENT`): exigiria API nativa de console, não usada;
  - o término abrupto do executor: não foi executado teste de morte abrupta, por restrição;
  - o comportamento do prazo durante suspensão do Windows com a espera fatiada (Stopwatch).

## Reconciliação dos casos de teste

| Suíte | Rodada 2 | Rodada 3 | Diferença |
| --- | --- | --- | --- |
| InvokeTests.Unit | 32 | 41 | +9 |
| Plan.Unit | 110 | 110 | — |
| PrepareMaintenance.Unit | 47 | 47 | — |
| CompleteWorktrees.Unit | 36 | 36 | — |
| Validate.Unit | 14 | 14 | — |
| Plan.Integration | 42 | 42 | — |
| PrepareMaintenance.Integration | 59 | 59 | — |
| CompleteWorktrees.Integration | 41 | 41 | — |
| Validate.Integration | 27 | 27 | — |
| **Total** | **408** | **417** | **+9** |

As oito suítes funcionais continuam com 376 casos; nenhum caso funcional foi acrescentado, removido ou renomeado. Os 9 casos novos de `InvokeTests.Unit`:

| # | Caso novo |
| --- | --- |
| 1 | `-Requires` literal no catálogo |
| 2 | Compatibilidade das suítes com o PowerShell 7 (restauração com `$null`) |
| 3 | Parada do pipeline (Ctrl+C) |
| 4 | Plano nativo das nove suítes |
| 5 | Preâmbulo mascarado (linhas, `;`, `$PSScriptRoot`) |
| 6 | Plano nativo indeterminado (14 formas) |
| 7 | Falso positivo corrigido |
| 8 | Pré-requisito e bloqueio no motor Pester |
| 9 | Motor Pester real (5.7.1) |

Também foram reescritos três casos existentes: requisito distribuído, adaptador nativo (no lugar do adaptador antigo) e veredito do motor Pester.

## Execuções

### Rodada integral (evidência principal)

| Item | Valor |
| --- | --- |
| Comando | `powershell -NoProfile -File tests\Invoke-Tests.ps1 -Package -TimeoutMinutes 120`, com o `pwsh` 7.6.9 no PATH do processo; motor padrão (Pester) |
| Pacote | Cópia isolada com os 47 arquivos inventariados + manifesto, versão `0.1.0-dev.9`; 10 de 10 checagens: integridade pelo módulo da cópia, sem `poc/`, `.git` ou links, ponto de entrada Plan, Validate e PrepareMaintenance `-WhatIf` com código 2, consumidor e pacote inalterados |
| Período | 25/10/2026 23:46:24 a 26/10/2026 03:01:19 (horário local), uma única invocação |
| Continuidade | Nenhum evento de suspensão, retomada ou desligamento no log do Sistema no período (Kernel-Power 41/42/107/109/506/507, Power-Troubleshooter 1, User32 1074, EventLog 6005/6006/6008). SHA-256 dos arquivos do worktree iguais no início e no fim |
| Resultado | **APROVADO**, código 0 |

| Suíte | 5.1 x64 | Tempo 5.1 | 7.6.9 x64 | Tempo 7 | Processos por execução |
| --- | --- | --- | --- | --- | --- |
| InvokeTests.Unit | 41/41 | 89 s | 41/41 | 90 s | 56 |
| Plan.Unit | 110/110 | 127 s | 110/110 | 128 s | 248 |
| PrepareMaintenance.Unit | 47/47 | 28 s | 47/47 | 29 s | 17 |
| CompleteWorktrees.Unit | 36/36 | 7 s | 36/36 | 6 s | 4 |
| Validate.Unit | 14/14 | 5 s | 14/14 | 5 s | 4 |
| Plan.Integration | 42/42 | 336 s | 42/42 | 321 s | 4.578 |
| PrepareMaintenance.Integration | 59/59 | 960 s | 59/59 | 891 s | 13.383 |
| CompleteWorktrees.Integration | 41/41 | 3.055 s | 41/41 | 2.889 s | 48.029 |
| Validate.Integration | 27/27 | 1.389 s | 27/27 | 1.318 s | 21.359 |
| **Total** | **417/417, 9/9 suítes** | 5.995 s | **417/417, 9/9 suítes** | 5.677 s | 175.432 no total |

Contagens separadas em cada suíte e em cada PowerShell: 0 falhas, 0 ignorados, 0 bloqueados por pré-requisito, 0 não executados. 25 execuções em Job Object, 0 encerramentos pelo executor, 0 não confirmados.

Critérios de aceitação: AC01 e AC32 (dois PowerShells) cobertos e aprovados em Desktop e Core. AC02 a AC20 e AC23 a AC31 cobertos e aprovados pelos casos das suítes. AC21 e AC22 são externos (revisão independente).

### Rodada x86

| Item | Valor |
| --- | --- |
| Comando | `powershell -NoProfile -File tests\Invoke-Tests.ps1 -Package -PowerShellPath C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -TimeoutMinutes 120`; motor padrão (Pester) |
| Pacote | Mesmo `0.1.0-dev.9`, mesmos arquivos da integral 2 (SHA-256 conferidos); 10 de 10 checagens, ponto de entrada no 5.1 x86 |
| Período | 26/10/2026 03:01:51 a 04:57:05 (horário local), uma única invocação, iniciada depois do fim da integral 2; nenhum evento de suspensão, retomada ou desligamento |
| Resultado | 9 de 9 suítes, **417/417** casos aprovados pelo Pester 5.7.1 no Windows PowerShell 5.1 x86 (inclusive as quatro suítes de integração, inéditas em x86); 0 falhas, ignorados, bloqueados ou não executados; 87.752 processos em 15 execuções em Job Object, 0 encerramentos pelo executor; 6.895 s |
| Código | 2 (PENDENTE), por desenho: com um único PowerShell, AC01 e AC32, que exigem os dois, ficam pendentes |

### Rodadas anteriores desta rodada 3 (não valem como evidência final)

| Execução | Resultado | Destino |
| --- | --- | --- |
| Integral 1, motor Pester, pacote `0.1.0-dev.8`, 25/10 19:55–22:56, sem eventos de suspensão | 5.1 x64: 9/9 suítes, 416/416. 7.6.9: 6/9 suítes, 372/416, com 44 falhas em PrepareMaintenance.Integration (31), Validate.Integration (9) e CompleteWorktrees.Integration (4) | Defeito de ambiente do PowerShell 7 diagnosticado e corrigido; rodada repetida |
| Dirigidas, 7.6.9, do worktree, depois da correção | PrepareMaintenance.Integration 59/59; Validate.Integration 27/27; InvokeTests.Unit 41/41 (5.1 e 7) | Antecedem a integral 2 |
| Dirigidas durante o desenvolvimento | Unitárias pelo Pester nos dois PowerShells; Plan.Unit no 7 com 2 falhas, iguais pelo harness e pelo Pester, antes da correção | — |

O harness auxiliar não teve rodada completa nesta rodada 3. Sua última rodada completa é a da rodada 2, no 5.1 x64, com os arquivos daquela versão.

## Situação dos requisitos

| Requisito | Situação |
| --- | --- |
| Windows PowerShell 5.1 x64 | Atendido: 417/417 pelo Pester 5.7.1, a partir do pacote isolado |
| Windows PowerShell 5.1 x86 | Atendido: 417/417 pelo Pester 5.7.1, a partir do pacote isolado, numa invocação separada |
| PowerShell 7 (§1, §8; AC01, AC32) | Atendido no 7.6.9 x64: 417/417 pelo Pester 5.7.1. Outras versões 7.x não verificadas |
| Pester 5 com versão fixada (§8) | Atendido: 5.7.1 fixado; casos executados e avaliados pelo Pester; versão carregada conferida em cada suíte |
| Execução padronizada `tests/Invoke-Tests.ps1` | Atendido; motor padrão Pester |
| Fixtures descartáveis; pacote íntegro e isolado | Atendido; integridade conferida pelo módulo da cópia |
| Versões de Windows | Comprovado somente no Windows 11 build 26300 |
| Git for Windows ≥ 2.44 | Comprovado somente com 2.52.0 |
| Documentação de instalação (`docs/instalacao.md` e demais) | Não atendido: proposta em `docs/proposta-instalacao-v1.0.md`, pendente de autorização de manutenção |
| Revisão independente (AC21, AC22) | Pendente: revisão do Codex sobre esta rodada |
| Homologação remota e decisões de publicação (§10) | Não verificado; fora do escopo |

## Limitações restantes

- **Ambientes:**
  - comprovados somente no Windows 11 build 26300 x64, com Git 2.52.0, PowerShell 7.6.9 e Pester 5.7.1;
  - não verificados: Windows 10, Windows Server, outras versões do PowerShell 7 e do Git, e PowerShell 7 x86 ou ARM64.
- **Interrupção:**
  - não verificados: o Ctrl+C por sinal real de console e o término abrupto do executor (ver controle de processos);
  - fixtures de suítes interrompidas podem restar sob o TEMP.
- **Processos fora da árvore:** processos criados fora da árvore de criação (WMI, Agendador, serviços, COM fora do processo) não herdam o job.
- **Execução nativa pelo Pester:**
  - depende da forma uniforme das suítes, conferida pelo plano: qualquer desvio torna a suíte Inconclusiva, sem execução;
  - nomes do nível do arquivo são publicados no escopo global do processo Pester, como faz o `-File` do harness;
  - o processo Pester é dedicado a uma suíte.
- **Lista de valores com `-File`:** com `powershell -File`, `-Suite` e `-PowerShellPath` aceitam um único valor por chamada.
- **Instalação por usuário:** o Pester 5.7.1 em `Documents\WindowsPowerShell\Modules` passa a ser a versão importada por padrão no 5.1 deste usuário.
- **Arquivos versionados alterados nesta rodada:**
  - as seis suítes funcionais acima, somente na restauração de ambiente (defeito demonstrado no 7);
  - `package.manifest.json`.

  O módulo, o ponto de entrada e os demais arquivos dos quatro marcos não foram alterados.
- **Documentação desatualizada:** `docs/instalacao.md`, `docs/atualizacao.md`, `docs/templates.md`, `docs/autorizacoes.md`, `docs/proposta-readme.md`, `README.md` e o preâmbulo de `AGENTS.md` continuam desatualizados. Sua alteração depende de autorização de manutenção ou de governança.

## Próxima ação mínima recomendada

Revisão independente pelo Codex do delta desta rodada:

- executor e veredito Pester;
- plano e adaptador nativos;
- correção de ambiente das seis suítes;
- requisito, manifesto e propostas.

Em seguida, as decisões humanas sobre manutenção, documentação e publicação.
