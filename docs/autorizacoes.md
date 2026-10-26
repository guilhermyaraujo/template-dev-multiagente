# Autorizações e evidências

Este documento descreve os contratos da [Especificação Técnica v1.1](especificacao-v1.md). A configuração JSON define identidade, localização e branches; não concede autorizações nem permite desativar regras de governança.

A autorização de 19 de outubro de 2026 cobriu somente a criação da estrutura inicial no diretório de manutenção atribuído, branch `chore/manutencao`, a partir da base `cf1fe177a4c6803211e042667e1f8d065c965674`. Seus limites continuam registrados como histórico daquela entrega; autorizações humanas posteriores e delimitadas permitiram a implementação e a homologação local das quatro fases. O README existente permanece preservado, com [proposta separada](proposta-readme.md).

Os metadados “para revisão” e o texto “não constitui autorização” são mantidos na transcrição da especificação. A aprovação posterior da v1.1 está na [errata](errata-especificacao-v1.1.md); cada operação depende de seu pedido humano específico, não de um marcador ou do documento normativo.

Em 26 de outubro de 2026, houve autorização específica para o fast-forward **local** de `chore/manutencao`, de `f67dc6132660578668b1cfef2a403342c18f6abe` até o commit homologado `a70e03c1aa44fdde218264fb22a1a9c921f4bd5b` de `feature/claude`. A operação não alterou `main` nem concedeu push, PR, merge remoto ou publicação. A autorização da Etapa 6 abrange somente `docs/instalacao.md`, `docs/atualizacao.md`, `docs/templates.md`, `docs/autorizacoes.md` (registro factual) e `docs/proposta-readme.md`, mais os hashes correspondentes do manifesto. Não concede commit ou alteração das regras abaixo.

## Regras permanentes

- Autorização humana poderá abranger um conjunto delimitado de operações. Dentro do escopo concedido, não haverá confirmação repetida.
- Delegação só transmitirá autorização humana identificável, com o mesmo alcance; não a ampliará.
- Revisão será realizada por agente distinto do autor e somente em leitura por padrão. Delegar a outro auxiliar Codex não comprova revisão cruzada Claude.
- Novo SHA de PR exigirá nova revisão e autorização. O HEAD completo avaliado deverá constar da evidência.
- Integração ocorrerá via PR. Merge remoto na coordenação será exclusivamente humano.
- Autorização de merge não delegará sua execução ao agente e não autorizará deploy.
- Não haverá bypass, descarte implícito, operação de força ou substituição silenciosa de arquivos e configurações.

## Matriz de operações do instalador implementado

| Operação | Regra | Tratamento previsto |
| --- | --- | --- |
| Inspeção local | Dentro da atribuição | `Plan` e `Validate`, somente leitura |
| Clone, criação de worktree ou branch ausente | Destinos, branches e SHA delimitados | Somente fases mutáveis autorizadas |
| Geração de governança | Escopo humano de manutenção e destinos sem conflito | Somente manutenção |
| Configuração compartilhada de hooks | Todos os ambientes e alcance identificados | Somente conclusão, após validação efetiva |
| Fetch | Conforme governança, sem mover branches alheias | Fora das etapas autônomas das fases |
| Fast-forward do ambiente de trabalho | Ambiente atribuído, upstream confirmado e árvore limpa | Fora do instalador |
| Sincronização da coordenação | Após integração, pelo responsável no próprio worktree | Fora do instalador |
| Preparação do índice e commit | Autorização correspondente de autoria | Fora do instalador |
| Push de trabalho | Autorização humana explícita | Fora do instalador |
| Abertura ou atualização de PR | Atribuição e escopo humano | Fora do instalador |
| Revisão cruzada | Agente distinto do autor; leitura por padrão | Fora do instalador |
| Merge remoto na coordenação | PR e SHA autorizados; execução humana | Nunca pelo instalador |
| Rebase ou integração entre branches | Autorização específica | Fora do instalador |
| Operação destrutiva ou de força | Autorização específica; execução separada | Nunca pelo instalador |
| Proteção de servidor e deploy | Autorizações próprias | Nunca pelo instalador |

## Conteúdo de uma autorização delimitada

O registro deverá identificar a pessoa responsável, o repositório, o papel executor, os caminhos e branches atingidos, as operações permitidas, a fase e o SHA completo aplicável. Também deverá indicar limites e verificações pendentes. Esse registro não deverá conter credenciais. `AuthorizationReference` apontará para evidência verificável; não será um booleano de aprovação.

Para integração, `IntegrationReference` deverá permitir conferir repositório e PR, branches de origem e destino, HEAD completo revisado, revisão independente, autorização humana vinculada ao PR e ao HEAD, resultado da integração, commit resultante e origem da comprovação do merge humano. A existência de arquivo, texto “aprovado” ou manifesto não satisfaz esse contrato.

O parâmetro efetivo é o caminho de um registro JSON de formato `1.0`, UTF-8, até 64 KiB, fora dos quatro worktrees; [Instalação](instalacao.md#registro-json-de-integração) mostra os campos obrigatórios. `CompleteWorktrees` exige também `-IntegratedCommit` e `-AuthorizationReference`. O instalador confere formato, relações internas e objetos Git locais, inclusive M (HEAD revisado) e I (commit integrado), mas **não consulta PR, autorização, revisão ou merge no servidor**. O campo `integration.method` registra um método externo; aceitar o valor `rebase` no JSON não autoriza um rebase pelo instalador ou pelo agente. `Validate` pode receber o mesmo registro para conferir relações locais, sem atribuir aprovação à evidência declarada.

## Configuração compartilhada e interrupções

Autorização para criar um ambiente não implica autorização para alterar a configuração compartilhada de todos. A ativação exigirá exatamente os quatro ambientes previstos, todos os contextos de `core.hooksPath` e a inspeção dos hooks atuais. Quinto worktree, registro indisponível, override mascarando o estado persistente, precedência inconclusiva ou configuração conflitante bloquearão o alcance.

Conflitos de arquivo serão resolvidos fora do instalador, em manutenção, sob escopo específico. Não haverá append, fusão, backup seguido de substituição ou exclusão automática. Falhas parciais preservarão o que tiver sido criado e deverão ser relatadas com ações realizadas, pendências e bloqueios.

## Evidências e limites

O relato deverá separar sucesso, incompletude, bloqueio e falha operacional, identificando fase, ações previstas ou realizadas e verificações pendentes. Deverá distinguir conformidade local, alterações de trabalho, evidência fornecida e proteção remota efetivamente verificada.

Hashes e manifestos auxiliarão a integridade, mas não provarão autenticidade sem origem confiável, nem autorização ou revisão. Comparação local, hooks presentes e inspeção estrutural não equivalem à homologação de autenticação, PR, proteção do servidor ou deploy.
