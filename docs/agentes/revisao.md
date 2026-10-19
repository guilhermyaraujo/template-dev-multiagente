# Papel: Revisão Cruzada

Objetivo: avaliar de forma independente alterações do outro agente antes da
integração na `main`, inclusive documentação, configuração e infraestrutura.

A revisão é simétrica: Codex revisa Claude e Claude revisa Codex, também para
alterações de manutenção. O revisor não pode ser autor das alterações avaliadas.
Autorrevisão ou checagem auxiliar pelo próprio agente não substitui a revisão
cruzada independente.

Toda revisão é somente leitura por padrão. O agente atua no ambiente atribuído e
consulta o PR, os diffs e as referências necessárias sem editar outro worktree.

Responsabilidades:

- Verificar qualidade e funcionamento do código e aderência aos requisitos.
- Identificar falhas, riscos de segurança e oportunidades de melhoria.
- Registrar problemas com arquivo, evidência, impacto e recomendação.
- Registrar o PR e o SHA completo do HEAD avaliado no parecer.
- Separar verificações executadas de verificações pendentes; não declarar
  validação em produção com base somente em testes locais.

Restrições:

- Devolver apontamentos ao autor. Corrigir exige autorização humana explícita e
  atribuição de autoria em worktree de trabalho permitido. Quem produzir uma
  correção não pode revisar a própria alteração; exija revisão pelo outro agente.
- Não modificar código, documentação ou governança durante uma revisão somente
  leitura. Mudanças de governança exigem autorização humana prévia e execução no
  ambiente de manutenção.
- Consultar arquivos de outra branch em somente leitura, sem trocar de branch
  ou modificar o worktree do autor.
- Somente o humano pode autorizar commit, push, merge e operações sensíveis, para
  uma operação ou conjunto delimitado. Delegações de agentes apenas reproduzem
  autorização humana anterior identificável, sem ampliar seu escopo, conforme
  [AGENTS.md](../../AGENTS.md#autorizações-humanas-e-delegações).
- Não aprovar em nome do humano. Agentes não executam nem programam o merge remoto
  na `main`; essa execução cabe ao humano responsável.

## Fluxo de integração

1. O autor prepara a alteração no ambiente atribuído e registra escopo, arquivos,
   validações, riscos e pendências. Commit e push dependem de autorização
   exclusivamente humana para a operação ou conjunto delimitado; se transmitida
   por um agente, a delegação deve identificar a autorização humana de origem.
2. Prepare ou atualize o PR da branch de origem para `main`, com resumo e
   evidências. O outro agente revisa o PR e registra o SHA completo avaliado.
   Abrir o PR antes da revisão é permitido, mas não dispensa a etapa independente.
3. O autor trata os apontamentos no próprio ambiente, dentro do escopo autorizado.
   Qualquer novo SHA exige nova revisão do conjunto atualizado antes de integrar.
4. O humano autoriza explicitamente o merge, identificando o número ou URL do PR
   e o SHA completo revisado. Registre essa autorização de forma rastreável no
   contexto da delegação ou do PR; parecer de agente não é autorização humana.
   Exemplo de identificação: `Autorizo o merge do PR #[NÚMERO], HEAD
   [SHA COMPLETO REVISADO], na main.` Substitua os marcadores pelos valores reais;
   o exemplo não representa uma autorização.
5. Antes do merge, confira o PR, o destino `main`, o parecer independente e se o
   HEAD atual coincide com o SHA revisado e autorizado. Se o SHA mudar, pare:
   a autorização anterior não cobre o novo conjunto; obtenha nova revisão e
   nova autorização humana.
6. O humano responsável executa o merge remoto do PR na `main`, respeitando
   as proteções remotas e o SHA revisado e autorizado. A autorização de merge não
   delega sua execução a um agente. Não integre outra branch localmente na `main`,
   não faça push direto e não contorne hooks.
7. Registre o resultado e o SHA integrado. Depois da integração no servidor, o
   responsável pelo worktree da `main`, atribuído à sincronização, pode executar
   fetch e fast-forward de `origin/main`, nas
   [condições de sincronização](../../AGENTS.md#sincronizacao-da-coordenacao).
   Essa atualização não cria commit de merge nem substitui a integração do PR.
8. Deploy é uma ação separada e exige autorização humana explícita para a versão
   e o ambiente; merge não o autoriza.

As regras de operações Git e de autorização estão centralizadas em
[AGENTS.md](../../AGENTS.md). Nenhuma etapa autoriza edição, commits ou
desenvolvimento na `main`, nem alteração do worktree de outro agente. A
sincronização local pós-integração segue apenas a exceção indicada acima.

## Evidência de integração após squash

O HEAD completo revisado e autorizado da manutenção é M; o commit resultante da
integração humana comprovada é I; o HEAD da coordenação já sincronizada é C.
M e I podem ser distintos e sem ancestralidade entre si. A manutenção conserva
seu histórico; a conclusão não sincroniza a coordenação nem reposiciona branches.

A equivalência exige comparar, por caminho, as entradas reais das árvores de M
e I, seus tipos, modos e bytes dos blobs, a renderização esperada, o índice e os
bytes atuais dos checkouts. O inventário obrigatório vem do pacote confiável,
não apenas do manifesto do consumidor. Conferir os dez arquivos governados e o
manifesto, além de entradas extras em .githooks/, docs/agentes/ e .multiagente/.

Exigir modos 100755 nos hooks e 100644 nos demais arquivos governados; rejeitar
links e gitlinks. Ler blobs diretamente dos objetos, sem substituições locais,
drivers, textconv, filtros ou busca automática de objetos ausentes. Registrar
resultado e divergência por caminho, com modo e objeto ou hash calculado.
Manifestos e status favoráveis não bastam. Essa comparação local não comprova
autorização, revisão do PR completo, execução humana do merge ou proteção remota.
