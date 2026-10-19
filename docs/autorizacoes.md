# Autorizações e evidências

Este documento descreve os contratos da [Especificação Técnica v1.1](especificacao-v1.md). A configuração JSON define identidade, localização e branches; não concede autorizações nem permite desativar regras de governança.

A autorização recebida para esta entrega cobre a criação da estrutura inicial no diretório de manutenção atribuído, branch `chore/manutencao`, a partir da base `cf1fe177a4c6803211e042667e1f8d065c965674`. Não cobre o desenvolvimento do instalador, alterações no projeto de origem, modificações em `main`, configuração Git, criação de worktrees, testes em repositórios reais, commit, push, PR, merge ou rebase. O README existente deve ser preservado, com proposta separada.

Os metadados “para revisão” e o texto “não constitui autorização” são mantidos na transcrição da especificação. A autorização desta entrega vem do pedido humano específico; não é inferida do documento ou de um marcador.

## Regras permanentes

- Autorização humana poderá abranger um conjunto delimitado de operações. Dentro do escopo concedido, não haverá confirmação repetida.
- Delegação só transmitirá autorização humana identificável, com o mesmo alcance; não a ampliará.
- Revisão será realizada por agente distinto do autor e somente em leitura por padrão. Delegar a outro auxiliar Codex não comprova revisão cruzada Claude.
- Novo SHA de PR exigirá nova revisão e autorização. O HEAD completo avaliado deverá constar da evidência.
- Integração ocorrerá via PR. Merge remoto na coordenação será exclusivamente humano.
- Autorização de merge não delegará sua execução ao agente e não autorizará deploy.
- Não haverá bypass, descarte implícito, operação de força ou substituição silenciosa de arquivos e configurações.

## Matriz de operações do futuro instalador

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

## Configuração compartilhada e interrupções

Autorização para criar um ambiente não implica autorização para alterar a configuração compartilhada de todos. A ativação exigirá exatamente os quatro ambientes previstos, todos os contextos de `core.hooksPath` e a inspeção dos hooks atuais. Quinto worktree, registro indisponível, override mascarando o estado persistente, precedência inconclusiva ou configuração conflitante bloquearão o alcance.

Conflitos de arquivo serão resolvidos fora do instalador, em manutenção, sob escopo específico. Não haverá append, fusão, backup seguido de substituição ou exclusão automática. Falhas parciais preservarão o que tiver sido criado e deverão ser relatadas com ações realizadas, pendências e bloqueios.

## Evidências e limites

O relato deverá separar sucesso, incompletude, bloqueio e falha operacional, identificando fase, ações previstas ou realizadas e verificações pendentes. Deverá distinguir conformidade local, alterações de trabalho, evidência fornecida e proteção remota efetivamente verificada.

Hashes e manifestos auxiliarão a integridade, mas não provarão autenticidade sem origem confiável, nem autorização ou revisão. Comparação local, hooks presentes e inspeção estrutural não equivalem à homologação de autenticação, PR, proteção do servidor ou deploy.
