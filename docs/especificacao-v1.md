# Especificação Técnica v1.1 — template-dev-multiagente

Versão documental: 1.1

Data: 19 de outubro de 2026

Situação: para revisão

Substitui integralmente: Especificação Técnica v1.0

Versão do esquema de configuração: 1.0, preservada

> Registro posterior — 19 de outubro de 2026: a v1.1 foi aprovada como referência de implementação. A [errata e registro de decisões](errata-especificacao-v1.1.md) registra a aprovação e a correção E01. Os metadados originais e a declaração final foram mantidos como histórico da versão recebida; não descrevem a situação posterior.

Esta revisão incorpora A1–A4 sem alterar a arquitetura, os parâmetros de configuração ou as regras invariáveis aprovadas. Não constitui autorização para implementação ou publicação.

DEVE indica obrigação; NÃO DEVE, proibição; PODE, comportamento permitido.

| Esclarecimento | Seções alteradas | Critérios afetados |
| --- | --- | --- |
| A1 — Inicialização e conflitos | 5, 7, 8, 9 e 10 | AC09, AC10, AC12; novos AC23–AC24 |
| A2 — Configuração efetiva dos hooks | 5, 7, 8 e 9 | AC12, AC16, AC17; novos AC25–AC26 |
| A3 — Comparação após squash | 4, 5, 7, 8 e 9 | AC13, AC15, AC20; novos AC27–AC29 |
| A4 — Escape por contexto | 2, 7, 8 e 9 | AC05, AC06, AC18, AC19; novos AC30–AC32 |

## 1. A distribuição terá governança própria e material separado para os projetos consumidores.

A primeira versão DEVE suportar:

- Windows com Windows PowerShell 5.1 e PowerShell 7.
- Codex e Claude.
- Coordenação, Codex, Claude e manutenção.
- Um clone principal e três worktrees adicionais.
- Configuração JSON como fonte única.
- Plan como fase padrão, sem modificações.
- Instalação repetível e sem sobrescrita automática.

A estrutura definitiva será:

```text
template-dev-multiagente/
├── AGENTS.md
├── CLAUDE.md
├── README.md
├── .gitattributes
├── .githooks/
│   ├── pre-commit
│   └── pre-push
├── package.manifest.json
├── schema/
│   └── project.schema.json
├── config/
│   └── project.example.json
├── templates/
│   ├── AGENTS.md.tmpl
│   ├── CLAUDE.md.tmpl
│   ├── README.md.tmpl
│   ├── .gitattributes.tmpl
│   ├── .githooks/
│   │   ├── pre-commit.tmpl
│   │   └── pre-push.tmpl
│   └── docs/agentes/
│       ├── coordenacao.md.tmpl
│       ├── desenvolvimento.md.tmpl
│       ├── manutencao.md.tmpl
│       └── revisao.md.tmpl
├── scripts/
│   ├── Install-MultiAgentProject.ps1
│   └── MultiAgentTemplate.psm1
├── tests/
│   ├── Invoke-Tests.ps1
│   ├── unit/
│   ├── integration/
│   └── fixtures/
└── docs/
    ├── agentes/
    │   ├── coordenacao.md
    │   ├── desenvolvimento.md
    │   ├── manutencao.md
    │   └── revisao.md
    ├── especificacao-v1.md
    ├── instalacao.md
    ├── autorizacoes.md
    └── atualizacao.md
```

Os arquivos da raiz governam o desenvolvimento do próprio template. Os arquivos em templates/ são o material de geração.

O package.manifest.json DEVE registrar versão da distribuição, esquema compatível e integridade do material distribuído. Não será prova suficiente de autenticidade sem origem confiável.

O consumidor terá:

| Papel | Diretório | Branch padrão |
| --- | --- | --- |
| Coordenação | `<slug>` | main |
| Codex | `<slug>-codex` | feature/codex |
| Claude | `<slug>-claude` | feature/claude |
| Manutenção | `<slug>-manutencao` | chore/manutencao |

O diretório de coordenação será o clone principal. Os outros três serão worktrees vinculados ao mesmo repositório Git.

O conjunto gerado será:

```text
<worktree>/
├── AGENTS.md
├── CLAUDE.md
├── README.md
├── .gitattributes
├── .githooks/
│   ├── pre-commit
│   └── pre-push
├── .multiagente/
│   └── manifest.json
└── docs/agentes/
    ├── coordenacao.md
    ├── desenvolvimento.md
    ├── manutencao.md
    └── revisao.md
```

A instalação NÃO DEVE criar estrutura da aplicação, dependências de negócio, workflows de deploy ou integrações externas.

## 2. A configuração continuará pequena e terá validação estrutural e semântica. [A4]

O único arquivo editável de configuração será multiagente.config.json, mantido fora dos quatro worktrees.

Ele definirá identidade, localização e branches. Documentos e manifestos gerados serão derivados, sem constituir fontes alternativas de configuração.

| Campo | Obrigatório | Padrão ou restrição |
| --- | --- | --- |
| schemaVersion | Sim | `"1.0"` |
| project.name | Sim | Nome de apresentação |
| project.slug | Sim | Identificador ASCII para os diretórios |
| repository.url | Sim | URL HTTPS ou SSH do consumidor |
| workspace.parentDirectory | Sim | Diretório pai absoluto, existente e local |
| branches | Não | Padrões abaixo |
| branches.coordination | Não | main |
| branches.codex | Não | feature/codex |
| branches.claude | Não | feature/claude |
| branches.maintenance | Não | chore/manutencao |

Serão fixos na v1:

- Remoto origin.
- Agentes Codex e Claude.
- Nomes derivados dos diretórios.
- Diretório de hooks .githooks.
- Regras de autorização, revisão e integração.

Não existirão opções para desativar hooks, revisão, isolamento ou autorização humana.

O esquema permanece:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Configuração Multiagente v1.0",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schemaVersion",
    "project",
    "repository",
    "workspace"
  ],
  "properties": {
    "schemaVersion": {
      "const": "1.0"
    },
    "project": {
      "type": "object",
      "additionalProperties": false,
      "required": ["name", "slug"],
      "properties": {
        "name": {
          "type": "string",
          "minLength": 1,
          "maxLength": 120
        },
        "slug": {
          "type": "string",
          "minLength": 1,
          "maxLength": 48,
          "pattern": "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"
        }
      }
    },
    "repository": {
      "type": "object",
      "additionalProperties": false,
      "required": ["url"],
      "properties": {
        "url": {
          "type": "string",
          "minLength": 1
        }
      }
    },
    "workspace": {
      "type": "object",
      "additionalProperties": false,
      "required": ["parentDirectory"],
      "properties": {
        "parentDirectory": {
          "type": "string",
          "minLength": 3
        }
      }
    },
    "branches": {
      "type": "object",
      "additionalProperties": false,
      "default": {},
      "properties": {
        "coordination": {
          "type": "string",
          "minLength": 1,
          "maxLength": 100,
          "pattern": "^[A-Za-z0-9][A-Za-z0-9._/-]*$",
          "default": "main"
        },
        "codex": {
          "type": "string",
          "minLength": 1,
          "maxLength": 100,
          "pattern": "^[A-Za-z0-9][A-Za-z0-9._/-]*$",
          "default": "feature/codex"
        },
        "claude": {
          "type": "string",
          "minLength": 1,
          "maxLength": 100,
          "pattern": "^[A-Za-z0-9][A-Za-z0-9._/-]*$",
          "default": "feature/claude"
        },
        "maintenance": {
          "type": "string",
          "minLength": 1,
          "maxLength": 100,
          "pattern": "^[A-Za-z0-9][A-Za-z0-9._/-]*$",
          "default": "chore/manutencao"
        }
      }
    }
  }
}
```

O carregador DEVE aplicar os padrões explicitamente e produzir o mesmo modelo efetivo nos dois PowerShells.

A validação semântica DEVE:

- Rejeitar propriedades desconhecidas e chaves duplicadas, inclusive diferenças apenas de caixa.
- Rejeitar nomes vazios e caracteres de controle após decodificar o JSON.
- Rejeitar quebras de linha, separadores Unicode de linha/parágrafo e controles de direção no nome de apresentação.
- Validar branches pelo alfabeto restrito e por git check-ref-format --branch.
- Exigir quatro branches distintas, inclusive por comparação sem distinguir caixa.
- Rejeitar referências ambíguas, como HEAD e nomes iniciados por refs/.
- Aceitar somente transporte HTTPS ou SSH.
- Proibir senha, token, consulta, fragmento e protocolos de execução na URL.
- Permitir usuário de transporte SSH, como git@servidor.
- Não expandir variáveis nem avaliar expressões nos valores.
- Validar nomes reservados do Windows, colisões, contenção dos caminhos e redirecionamentos por links ou junctions.

Validação de dados e escape por contexto são etapas complementares. A aprovação pelo esquema não torna um valor seguro para qualquer formato de saída.

## 3. O exemplo de configuração permanece independente da instalação local do projeto de origem.

```json
{
  "schemaVersion": "1.0",
  "project": {
    "name": "Portal de Serviços Aurora",
    "slug": "portal-servicos-aurora"
  },
  "repository": {
    "url": "https://github.com/organizacao-exemplo/portal-servicos-aurora.git"
  },
  "workspace": {
    "parentDirectory": "C:\\Projetos Compartilhados\\Aurora"
  }
}
```

O resultado previsto será:

```text
C:\Projetos Compartilhados\Aurora\
├── portal-servicos-aurora\
├── portal-servicos-aurora-codex\
├── portal-servicos-aurora-claude\
└── portal-servicos-aurora-manutencao\
```

A URL é fictícia. As quatro branches padrão serão utilizadas.

## 4. As fases conservarão responsabilidades separadas e evidências explícitas. [A3]

O ponto de entrada terá os controles operacionais:

| Entrada | Contrato |
| --- | --- |
| Config | Caminho do JSON; obrigatório |
| Phase | Fase selecionada; padrão Plan |
| WhatIf | Simulação sem modificações |
| AuthorizationReference | Referência à autorização humana das operações mutáveis |
| BaseCommit | SHA completo autorizado para preparação |
| IntegratedCommit | SHA completo resultante da integração |
| IntegrationReference | Registro verificável do PR, revisão, autorização e integração |

SHAs e referências são evidências da execução, não parâmetros para alterar as regras de governança.

A evidência de integração DEVE identificar:

- Repositório e PR.
- Branch de origem e destino.
- HEAD completo revisado.
- Revisão independente.
- Autorização humana vinculada ao PR e ao HEAD revisado.
- Resultado da integração e commit resultante.
- Origem da comprovação da execução humana do merge.

O instalador NÃO DEVE inferir aprovação pela existência de um arquivo, texto “aprovado” ou campo booleano.

| Fase | Finalidade | Efeito permitido |
| --- | --- | --- |
| Plan | Inspecionar e apresentar ações | Nenhuma modificação |
| PrepareMaintenance | Preparar clone/manutenção e gerar governança | Criações autorizadas e geração na manutenção |
| CompleteWorktrees | Completar ambientes após integração | Criações ausentes e configuração autorizada dos hooks |
| Validate | Conferir conformidade | Nenhuma modificação |

Plan e Validate NÃO DEVEM realizar fetch, clone, gravação de relatórios, criação de temporários ou execução dos hooks do consumidor.

Leituras Git DEVEM evitar atualização incidental do índice, drivers externos e busca automática de objetos ausentes.

WhatIf DEVE impedir individualmente as operações mutáveis, inclusive chamadas nativas. O suporte ao parâmetro não será tratado como propagação automática para programas externos. Microsoft — ShouldProcess.

## 5. As fases terão pré-condições, pós-condições e interrupções obrigatórias. [A1, A2, A3]

As condições comuns serão:

- Pacote confiável e configuração válida.
- Git for Windows com os recursos exigidos.
- Shell compatível com sh, localizado explicitamente quando necessário.
- Diretório pai local existente.
- Caminhos e ambientes identificados.
- Nenhuma instalação automática de dependências.
- Nenhuma alteração global de configuração.
- Exclusão mútua entre fases mutáveis do mesmo repositório.

UNC, compartilhamentos de rede, clones bare, submódulos e configurações especiais que exijam migração ficam fora da instalação automática da v1.

Objetos necessários à comparação DEVEM estar presentes localmente. Partial clones ou mecanismos de obtenção automática que impeçam garantir leitura sem escrita interromperão a fase.

O comportamento de inicialização será:

| Cenário | Comportamento obrigatório |
| --- | --- |
| Repositório novo com commit inicial | Confirmar commit real, branch de coordenação, remoto e base autorizada; inspecionar todos os destinos |
| Repositório novo sem commit | Informar pré-requisito ausente; não criar commit inicial nem inicializar o servidor |
| Repositório existente sem conflitos | Reutilizar somente o estado compatível, sem reposicionar branches |
| Repositório existente com conflitos | Interromper; não migrar, mesclar ou substituir arquivos |
| Instalação parcialmente preparada | Reconhecer resultados idênticos e retomar somente operações ausentes autorizadas |

O commit inicial DEVE ser fornecido por preparação humana externa ao instalador. Pode conter arquivos fora do conjunto governado; sua existência não garante ausência de conflitos.

Um README criado na inicialização do remoto receberá a mesma verificação dos demais arquivos. Se diferir do README esperado, será conflito.

A resolução de conflitos ocorrerá fora do instalador, em manutenção e sob escopo humano específico. A coordenação não será editada para contornar essa condição.

A política não permite append, fusão, backup seguido de substituição ou exclusão automática.

O contrato de Plan será:

| Aspecto | Requisito |
| --- | --- |
| Pré-condições | Configuração válida e acesso de leitura |
| Operações | Resolver padrões; renderizar em memória; inspecionar ambientes, arquivos e configuração |
| Pós-condições | Plano com ações, conflitos e evidências pendentes |
| Interrupção | Configuração inválida, caminho inseguro ou inspeção inconclusiva |
| Preservação | Arquivos, índice, referências e configuração inalterados |

Ambientes ausentes serão apresentados como ações previstas. Verificações remotas não realizadas permanecerão explicitamente pendentes.

O contrato de PrepareMaintenance será:

| Aspecto | Requisito |
| --- | --- |
| Pré-condições | Autorização delimitada, BaseCommit completo e repositório inicializado |
| Operações | Clonar quando necessário; criar manutenção ausente na base autorizada; gerar nela |
| Pós-condições | Coordenação disponível e manutenção preparada, sem commit automático |
| Interrupção | Base divergente, branch ocupada, arquivo conflitante, alteração alheia ou configuração insegura |
| Proibições | Criar Codex/Claude, ativar hooks compartilhados, preparar índice, fazer commit, push ou PR |

Antes da primeira gravação de conteúdo governado, todos os destinos disponíveis DEVEM ser classificados como ausentes, idênticos ou conflitantes.

Se um conflito só puder ser descoberto depois de um clone necessário, o clone será preservado, a geração será bloqueada e o estado será informado como parcial. Não haverá remoção automática.

Na repetição anterior ao commit, arquivos gerados idênticos e alterações restritas ao conjunto esperado serão reconhecidos como preparação anterior. Arquivos parcialmente divergentes interromperão a fase.

O contrato de CompleteWorktrees será:

| Aspecto | Requisito |
| --- | --- |
| Pré-condições | Integração comprovada, coordenação já sincronizada, conteúdo governado verificado e autorização abrangente |
| Operações | Criar Codex/Claude ausentes na base integrada; verificar os quatro ambientes; ativar hooks quando permitido |
| Pós-condições | Quatro ambientes compatíveis e configuração efetiva dos hooks validada |
| Interrupção | Evidência insuficiente, conteúdo divergente, branch ocupada, conflito de configuração ou alcance adicional |
| Proibições | Sincronizar coordenação, reposicionar manutenção, integrar históricos ou publicar |

A sincronização da coordenação DEVE ocorrer previamente no próprio worktree, pelo responsável atribuído e conforme a governança. A fase não poderá executar um merge em outro worktree como atalho.

A comparação após squash seguirá o procedimento da seção 7. Não será exigida igualdade nem ancestralidade entre o commit revisado da manutenção e o commit integrado.

Branches existentes não serão reposicionadas. A manutenção conservará seu histórico.

A ativação dos hooks somente poderá ocorrer depois da verificação efetiva descrita na seção 7. Se Codex e Claude forem criados antes da descoberta de um conflito, permanecerão preservados; a ativação ficará bloqueada.

O contrato de Validate será:

| Aspecto | Requisito |
| --- | --- |
| Pré-condições | Configuração válida e leitura possível |
| Operações | Reconstruir o estado por arquivos, objetos Git, índice e configuração efetiva |
| Pós-condições | Relatório de conformidade, incompletude ou bloqueio |
| Interrupção | Impossibilidade de inspeção confiável |
| Proibições | Correção, fetch, troca de branch, execução de hooks e gravação |

A validação DEVE separar conformidade local, alterações de trabalho, evidência fornecida e proteção remota efetivamente verificada.

Nas fases mutáveis, o estado será revalidado imediatamente antes de cada alteração. Falhas após uma operação serão apresentadas como execução parcial, sem rollback destrutivo.

## 6. Autorizações e operações Git conservarão a governança aprovada.

| Operação | Regra | Execução pelo instalador |
| --- | --- | --- |
| Inspeções locais | Dentro da atribuição | Plan e Validate |
| Clone e criação de worktrees | Autorização com destinos e base | Fases mutáveis |
| Criação de branches ausentes | Autorização com nomes e SHA | Fases mutáveis |
| Geração da governança | Autorização de manutenção | Somente em manutenção |
| Configuração compartilhada | Autorização para todos os ambientes afetados | Somente na conclusão |
| Fetch | Conforme governança, sem mover branches locais alheias | Fora das etapas autônomas das fases |
| Fast-forward de trabalho | Ambiente atribuído, upstream confirmado e árvore limpa | Fora do instalador |
| Sincronização da coordenação | Pós-integração, no próprio worktree | Fora do instalador |
| Preparação do índice e commit | Autorização de autoria correspondente | Fora do instalador |
| Push de trabalho | Autorização humana explícita | Fora do instalador |
| Abertura ou atualização de PR | Atribuição e escopo humano | Fora do instalador |
| Revisão cruzada | Agente distinto do autor; somente leitura por padrão | Fora do instalador |
| Merge remoto na coordenação | PR e SHA autorizados; execução humana | Nunca |
| Rebase ou integração entre branches | Autorização específica | Fora do instalador |
| Operação destrutiva ou força | Autorização específica e execução separada | Nunca |
| Proteção do servidor e deploy | Autorizações próprias | Nunca |

Uma autorização humana poderá cobrir um conjunto delimitado de operações. Dentro dos limites concedidos, não haverá confirmação repetida.

Delegações só poderão transmitir autorização humana identificável.

Novo SHA do PR exigirá nova revisão e autorização. Autorizar merge não delega sua execução ao agente nem autoriza deploy.

## 7. A geração e a comprovação de integridade terão contratos explícitos. [A1–A4]

O processo será determinístico:

1. Validar pacote e configuração.
2. Aplicar padrões.
3. Construir o modelo efetivo em memória.
4. Renderizar todos os arquivos.
5. Verificar tokens, contextos, referências e invariantes.
6. Comparar todos os destinos.
7. Criar somente os destinos ausentes autorizados.

A política de arquivos será:

| Destino | Resultado |
| --- | --- |
| Ausente e seguro | Criação autorizada |
| Idêntico ao esperado | Nenhuma ação |
| Conteúdo ou tipo diferente | Interrupção |
| Link, redirecionamento ou contenção incerta | Interrupção |

README e atributos não terão exceção. A instalação não realizará migração de material preexistente.

As regras invariáveis continuarão sendo:

- Quatro papéis e isolamento.
- Coordenação sem edição, commits ou desenvolvimento.
- Sincronização somente nas condições documentadas.
- Revisão por agente distinto do autor.
- Revisão somente leitura por padrão.
- Autorização humana delimitada.
- Integração via PR.
- Merge remoto exclusivamente humano.
- Deploy separado.
- Proibição de bypass e descarte implícito.

A comprovação após squash será baseada no conteúdo real.

Serão fixados:

- M: SHA completo do HEAD revisado e autorizado do PR de manutenção.
- I: SHA completo resultante da integração remota comprovada.
- C: HEAD da coordenação, já sincronizado pelo responsável.

O vínculo de M com a fonte revisada DEVE ser conferido. Na conclusão inicial, o HEAD da manutenção deverá corresponder a essa fonte. Essa conferência não exige M = I, nem ancestralidade entre eles.

O procedimento obrigatório será:

1. Confirmar que M e I existem localmente e são commits.
2. Determinar o conjunto obrigatório de caminhos pelo pacote confiável, independentemente do manifesto do consumidor.
3. Enumerar os caminhos e entradas reais das árvores de M e I.
4. Comparar, por caminho, existência, tipo, modo e conteúdo.
5. Ler os bytes dos blobs diretamente do banco de objetos.
6. Compará-los entre si e com a renderização esperada.
7. Conferir o índice e os arquivos atuais da manutenção.
8. Conferir que a coordenação contém a integração comprovada e conserva o conteúdo governado correspondente.
9. Apresentar divergências por caminho e propriedade.

O conjunto obrigatório compreenderá os dez arquivos de governança e o manifesto gerado indicados na seção 1. Também serão enumerados os diretórios exclusivos .githooks/, docs/agentes/ e .multiagente/, para detectar entradas inesperadas.

A leitura das árvores e blobs poderá utilizar os recursos de ls-tree e cat-file, sem checkout e sem filtros de transformação. Git — ls-tree, Git — cat-file.

Serão obrigatórios:

- Comparação exata dos bytes dos blobs, sem normalização.
- Nomes completos e leitura com delimitação segura, inclusive NUL.
- Rejeição de links simbólicos e gitlinks nos caminhos governados.
- Modos 100755 para hooks e 100644 para documentos e manifesto.
- Inspeção sem substituição local de objetos.
- Nenhum lazy fetch para completar objetos ausentes.
- Nenhum driver externo, textconv ou filtro clean/smudge na comprovação.

Para o checkout atual, os bytes serão lidos diretamente. A verificação não dependerá apenas de git status ou de flags do índice.

Os arquivos gerados terão LF explícito nos atributos. Assim, a comparação local também poderá ser exata, sem normalização silenciosa.

O relatório de comparação DEVE identificar, por caminho, modos, objetos ou hashes calculados, resultado e motivo da divergência. Não precisa despejar o conteúdo dos arquivos.

Manifestos e marcadores serão informações auxiliares. Mesmo um manifesto aparentemente correto não permitirá aceitar documento alterado, hook ausente ou modo incorreto.

Diferenças fora do conjunto governado não serão avaliadas por essa comparação. A revisão do PR completo e a autorização humana permanecem requisitos independentes.

A verificação dos hooks será realizada em cada contexto.

Antes da ativação compartilhada, o instalador DEVE:

1. Enumerar todos os worktrees registrados, inclusive registros indisponíveis ou potencialmente removíveis.
2. Confirmar exatamente os quatro ambientes previstos.
3. Consultar core.hooksPath separadamente em cada worktree.
4. Obter os valores aplicáveis, suas origens e escopos, com includes habilitados.
5. Considerar configuração de sistema, global, local, por worktree e includes condicionais.
6. Identificar overrides herdados de configuração ou localização do repositório.
7. Inspecionar o diretório atualmente usado para hooks.
8. Inspecionar a .githooks de cada ambiente.
9. Revalidar o conjunto imediatamente antes da ativação.
10. Consultar novamente os quatro contextos após eventual escrita.

Uma consulta limitada a --local não comprova o valor efetivo. A resolução deve considerar as camadas e includes utilizados pelo Git. Git — configuração.

O relatório por worktree DEVE apresentar:

| Informação | Verificação |
| --- | --- |
| Raiz e branch | Correspondência com a configuração |
| Repositório comum | Mesmo repositório dos demais ambientes |
| Valores encontrados | Cadeia aplicável de core.hooksPath |
| Origem e escopo | Arquivo ou camada responsável |
| Valor efetivo | Resultado naquele contexto |
| Destino resolvido | .githooks da respectiva raiz |
| Arquivos | Presença, bytes, tipos e modos previstos |

A política antes da ativação será:

| Estado | Decisão |
| --- | --- |
| Configuração persistente compatível em todos os ambientes | Nenhuma substituição |
| Entrada local ausente, sem conflitos e com autorização abrangente | Permitir uma inserção de .githooks |
| Valor vazio, caminho distinto ou ocorrências conflitantes | Interromper |
| Precedência inconclusiva | Interromper |
| Override de processo mascarando o estado persistente | Interromper, sem removê-lo silenciosamente |
| Quinto worktree ou alcance incerto | Interromper |
| Hook preexistente que seria ocultado | Interromper |
| Arquivo inesperado ou alterado em .githooks | Interromper |

A ausência de core.hooksPath não significa ausência de hooks: o diretório padrão resolvido pelo Git também DEVE ser inspecionado. Hooks ativos nesse local impedem sua substituição automática. Arquivos de amostra inativos não equivalem a hooks ativos.

A v1 não fará composição de hooks, migração de diretórios, --replace-all, alteração global ou habilitação de extensions.worktreeConfig.

Configurações por worktree já existentes serão consideradas na leitura, mas não corrigidas automaticamente.

O comportamento dos hooks continuará:

| Hook | Obrigação |
| --- | --- |
| pre-commit | Bloquear commit na branch de coordenação |
| pre-push | Bloquear qualquer destino refs/heads/\<coordenação\>, inclusive exclusão e lote misto |

Os hooks não validarão identidade, revisão ou autorização. A limitação atual de HEAD destacado continuará documentada; o instalador recusará esse estado.

A renderização utilizará escape específico por contexto.

| Contexto | Contrato obrigatório |
| --- | --- |
| Prosa e títulos Markdown | Nome como dado de uma linha; pontuação e HTML escapados |
| Células de tabela | Impedir criação de colunas e linhas; em texto comum GFM, duplicar as barras invertidas originais antes de escapar cada pipe com uma barra invertida; em código inline, preservar as barras dos dados e aplicar a proteção de pipes da tabela com delimitadores seguros, sem reutilizar escape de prosa; não inserir quebras de linha físicas oriundas dos dados. Mantêm-se as rejeições da seção 2. Ver [detalhamento E01](errata-especificacao-v1.1.md#e01-escape-em-tabelas-markdown). |
| Links e âncoras | Estrutura derivada de identificadores e caminhos controlados; nome não cria destinos |
| Código Markdown | Delimitadores seguros para o conteúdo; não reutilizar escape de prosa |
| Comando PowerShell documentado | Valores em literais adequados; apóstrofes internos duplicados em literais de aspas simples |
| Código sh dos hooks | Somente branch/ref previamente validadas, inseridas como literais |
| Chamada de processo | Argumentos separados; nenhum comando concatenado |
| Operação de caminho | APIs de caminho e semântica literal, com validação de contenção |

O nome do projeto, URL e diretório pai NÃO DEVEM ser interpolados no código dos hooks.

git check-ref-format não substitui o alfabeto restrito: um nome aceito pelo Git ainda pode conter caracteres inadequados para inserção em shell.

Não haverá função universal de escape. Escape Markdown, literal PowerShell, literal sh e argumento nativo terão contratos distintos.

Serão proibidos:

- Invoke-Expression.
- Encaminhamento por cmd /c.
- Concatenação de dados para formar comandos.
- Expansão de variáveis presentes no JSON.
- Substituição recursiva de tokens.
- Substituição global de palavras como main em texto arbitrário.

Tokens serão identificados no template confiável antes da inserção. Valores inseridos nunca serão reinterpretados como novos tokens.

Por exemplo, {{BRANCH}} dentro do nome de apresentação deverá continuar dado literal. Uma busca cega no resultado não poderá tratá-lo como token pendente do template.

Caracteres válidos de caminho, como espaço, apóstrofe, $, & e colchetes, deverão chegar às operações como dados literais, sem expansão ou execução.

A integridade dos arquivos será:

| Material | Requisito |
| --- | --- |
| PowerShell com caracteres não ASCII | UTF-8 com BOM para compatibilidade com 5.1 |
| Hooks | UTF-8 sem BOM, LF e modo Git 100755 |
| Documentos e JSON gerados | UTF-8 sem BOM, LF e modo previsto |
| Atributos | Regras específicas para os caminhos gerados |

O tratamento dos scripts considera a diferença de leitura do Windows PowerShell 5.1. Microsoft — codificação.

O manifesto gerado registrará versão, configuração lógica resolvida, arquivos, hashes e modos. Não conterá caminhos absolutos locais, credenciais, aprovação humana nem hash de si próprio.

## 8. A suíte comprovará os contratos em ambientes isolados. [A1–A4]

A suíte utilizará Pester 5 com versão fixada na distribuição de testes e execução separada nos dois PowerShells.

O instalador de produção não instalará dependências de testes.

| Grupo | Casos obrigatórios |
| --- | --- |
| Esquema | Ausências, propriedades desconhecidas, duplicados, tipos e padrões |
| Inicialização | Repositório com commit, remoto vazio e HEAD sem commit |
| Conflitos | README, atributos, documento, hook e tipo de arquivo incompatíveis |
| Geração | Determinismo, tokens, links e invariantes |
| Somente leitura | Preservação em Plan, Validate e WhatIf |
| Idempotência | Repetição antes do commit e depois da instalação |
| Retomada | Interrupções sem descarte ou duplicação |
| Hooks efetivos | Camadas, includes condicionais e configuração por worktree |
| Alcance | Quinto worktree e registro indisponível |
| Hooks preexistentes | Diretório padrão ativo e arquivos extras em .githooks |
| Squash | Commits distintos, sem ancestralidade entre eles, com conteúdo igual |
| Conteúdo falso | Manifesto correto com blob alterado, arquivo ausente ou modo incorreto |
| Checkout | Arquivo divergente apesar de status ou flags aparentemente favoráveis |
| Renderização | Markdown, shell, caminhos e chamadas nativas adversariais |
| Compatibilidade | Espaços, acentos, BOM, LF e core.autocrlf |
| Privacidade | Ausência de credenciais em erros e relatórios |
| Concorrência | Mudança de estado entre inspeção e operação |

O corpus adversarial incluirá:

- Nome com |, colchetes, parênteses, HTML e texto semelhante a token.
- Caracteres de controle codificados em JSON.
- Branches Git válidas que contenham caracteres rejeitados pelo contrato de shell.
- Caminhos com espaços, apóstrofes, $, &, colchetes e ponto e vírgula.
- Entradas tentando encerrar delimitadores de código ou introduzir instruções.
- Overrides que aparentem corrigir temporariamente core.hooksPath.

Os testes DEVEM demonstrar que os valores são preservados como dados, rejeitados quando necessário e incapazes de criar sentinelas de execução.

A matriz de squash incluirá:

| Caso | Resultado |
| --- | --- |
| M e I distintos, conteúdo e modos iguais | Aceitar a equivalência governada |
| Manifesto idêntico e documento alterado | Rejeitar |
| Arquivo omitido do manifesto | Detectar pelo inventário independente |
| Hook com 100644 ou como link | Rejeitar |
| Arquivo inesperado em .githooks | Rejeitar |
| Checkout diferente do commit revisado | Rejeitar |
| Objetos ausentes | Interromper sem busca automática |

As fixtures serão descartáveis e pertencentes ao executor autorizado. Nunca apontarão para o projeto atual.

Commits e referências necessários aos testes pertencem ao executor de testes, não ao comportamento do instalador. Testes de hooks utilizarão entradas simuladas, sem push real.

Homologação remota de autenticação, PR e proteção de servidor será separada e autorizada. Resultados locais não comprovarão essas proteções.

## 9. Os critérios manterão sua numeração e receberão os acréscimos rastreáveis. [A1–A4]

| ID | Critério objetivo | Alteração |
| --- | --- | --- |
| AC01 | Mesma suíte funcional aprovada nos dois PowerShells | Preservado |
| AC02 | Configuração mínima produz exatamente quatro ambientes | Preservado |
| AC03 | Mesmo repositório Git comum nos quatro ambientes | Preservado |
| AC04 | Diretórios e branches consistentes em todos os documentos | Preservado |
| AC05 | Nenhum identificador de origem ou token real do template permanece; dados semelhantes a tokens não são reinterpretados | A4 |
| AC06 | Branches alternativas passam pela validação e proteção, sem caracteres proibidos de shell | A4 |
| AC07 | Plan, Validate e WhatIf preservam o estado observado | Preservado |
| AC08 | Nenhum commit, push, PR, merge, rebase ou deploy pelo instalador | Preservado |
| AC09 | Nenhum destino diferente é substituído, anexado ou mesclado, inclusive README e atributos | A1 |
| AC10 | Preparação repetida reconhece arquivos gerados ainda não commitados | A1 |
| AC11 | Instalação concluída repetida produz nenhuma alteração | Preservado |
| AC12 | Falha parcial preserva trabalho e distingue criação de ambientes de ativação dos hooks | A1, A2 |
| AC13 | Conclusão não sincroniza coordenação nem reposiciona manutenção; aceita squash conforme comparação de conteúdo | A3 |
| AC14 | Hooks bloqueiam pelo destino, incluindo exclusão e lote misto | Preservado |
| AC15 | Hooks e arquivos governados têm bytes, tipos e modos esperados nos objetos e checkouts | A3 |
| AC16 | Configuração efetiva conflitante é detectada sem substituição | A2 |
| AC17 | Nenhum alcance adicional é aceito silenciosamente | A2 |
| AC18 | Caminhos válidos com espaços, acentos e metacaracteres chegam literalmente às operações | A4 |
| AC19 | Nenhum segredo é exposto; entradas não causam execução ou expansão | A4 |
| AC20 | Requisitos têm evidências identificadas; comparação informa resultados por caminho | A3 |
| AC21 | Revisão independente registra o SHA completo avaliado | Preservado |
| AC22 | Ausência de defeitos críticos ou altos para publicação | Preservado |
| AC23 | Repositório sem commit bloqueia preparação sem criação de commit inicial | Novo — A1 |
| AC24 | Conflito em qualquer destino bloqueia a geração de conteúdo; resolução automática inexiste | Novo — A1 |
| AC25 | Valor, origem, escopo e destino efetivo de core.hooksPath são conferidos nos quatro worktrees | Novo — A2 |
| AC26 | Hook padrão preexistente, override, include conflitante ou quinto worktree bloqueia ativação | Novo — A2 |
| AC27 | Commits M e I distintos e sem ancestralidade entre si são aceitos quando o conteúdo governado corresponde | Novo — A3 |
| AC28 | Manifesto ou marcador isolado nunca basta; blobs alterados, faltantes ou extras são detectados | Novo — A3 |
| AC29 | Índice e bytes do checkout são conferidos sem depender somente de status ou flags | Novo — A3 |
| AC30 | Nome com Markdown, HTML e texto semelhante a token permanece dado literal, sem alterar estrutura ou regras | Novo — A4 |
| AC31 | Hooks recebem somente literais permitidos; entradas de shell proibidas são rejeitadas antes da geração | Novo — A4 |
| AC32 | Corpus adversarial passa nos dois PowerShells sem expansão, execução, sentinelas ou alterações em modos de inspeção | Novo — A4 |

A saída DEVE distinguir sucesso, incompletude, bloqueio e falha operacional. Também deverá identificar fase, ações previstas ou realizadas, evidências e verificações pendentes.

Uma execução parcial não poderá ser apresentada como concluída. Uma comparação local não poderá ser apresentada como comprovação de aprovação ou proteção remota.

## 10. Permanecerão decisões humanas de publicação e operação, sem transferi-las ao instalador. [A1]

| Decisão | Efeito |
| --- | --- |
| Propriedade, licença e visibilidade | Condições de manutenção e distribuição |
| Hospedagem e proteção remota | Regras efetivas de PR, revisão, push e novo SHA |
| Registro das autorizações | Local e responsabilidade pela conferência das evidências |
| Preparação inicial do consumidor | Fornecimento do commit inicial e base autorizada |
| Tratamento de conflitos preexistentes | Trabalho manual autorizado em manutenção |
| Origem confiável do pacote | Publicação, verificação e eventual assinatura |
| Política de execução Windows | Autorização corporativa sem bypass automático |
| Homologação remota | Repositório, contas e operações de teste autorizados |

A escolha de como preparar um repositório específico não altera o contrato: a v1 NÃO fará migração nem resolução automática de conflitos.

Também ficam fora da v1:

- Atualização automática.
- Migração de worktrees.
- Reconciliação de documentação personalizada.
- Composição ou migração de hooks.
- Alteração de política de execução.
- Criação de repositórios no servidor.
- Configuração de proteção remota.
- Endurecimento funcional adicional dos hooks.
- Transporte de credenciais.

Esta especificação foi entregue somente para revisão. Não houve implementação, alteração de arquivos ou configurações, nem criação de branches, commits, pushes ou PRs no projeto atual.

---

### Nota histórica de transcrição

O parágrafo a seguir registra a situação recebida antes desta correção. Sua pendência foi resolvida por [E01](errata-especificacao-v1.1.md#e01-escape-em-tabelas-markdown); o texto foi preservado como histórico.

Nota editorial de transcrição, sem alteração normativa: o texto fornecido para a célula “Células de tabela” da seção 7 termina em uma crase após “Impedir criação de colunas;”. O fragmento foi preservado; o restante não foi presumido. A redação integral dessa célula permanece pendente de confirmação humana. Os metadados e a declaração final acima reproduzem o estado documental da especificação recebida. A autorização específica para criar a estrutura inicial consta do pedido humano de manutenção; ela não converte o documento em autorização para outras entregas, instalação ou publicação.
