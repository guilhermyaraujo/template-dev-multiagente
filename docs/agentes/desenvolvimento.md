# Papel: Desenvolvimento

Ambientes: `template-dev-multiagente-codex` / `feature/codex` para o Codex e
`template-dev-multiagente-claude` / `feature/claude` para o Claude.

Objetivo: implementar funcionalidades aprovadas. A revisão cruzada é simétrica:
Codex revisa Claude e Claude revisa Codex, em somente leitura por padrão. O revisor
não pode ser autor das alterações, conforme [Revisão](revisao.md).

Responsabilidades:

- Desenvolver código exclusivamente no worktree atribuído.
- Seguir requisitos documentados.
- Executar testes pertinentes e registrar resultados e limitações.
- Informar alterações e preparar evidências para revisão cruzada e PR.
- Corrigir apontamentos no próprio ambiente de autoria e solicitar nova revisão
  das alterações pelo outro agente.

## Configuração da feature e infraestrutura compartilhada

A configuração versionada necessária à funcionalidade pode acompanhar a feature
quando estiver no escopo aprovado e restrita à aplicação em desenvolvimento.
Exemplos: parâmetros da funcionalidade, manifesto da aplicação, dependências e
configuração dos testes da feature, sem mudar políticas ou serviços compartilhados.

Encaminhe à manutenção mudanças de governança, instruções de agentes, hooks,
políticas Git, CI, segredos, proteções de branch e infraestrutura compartilhada.
Uma dependência da feature não autoriza alterar esses recursos nem ambientes
externos. Arquivos que misturem configuração da aplicação e infraestrutura devem
ter o escopo discriminado e autorizado antes da alteração.

Configurações Git `--local` podem afetar todos os worktrees. Não as trate como
configuração isolada da feature. A avaliação do alcance e a autorização seguem
[Manutenção](manutencao.md); o nome ou caminho do arquivo não define a fronteira.

Restrições:

- Não editar arquivos nem desenvolver diretamente na `main`.
- Não modificar arquivos de outros worktrees.
- Não modificar requisitos sem aprovação humana.
- Não alterar governança sem autorização humana prévia; encaminhar a execução
  para manutenção.
- Somente o humano autoriza commit, push, merge e operações sensíveis, para uma
  operação ou conjunto delimitado e seu escopo. Delegação de agente só reproduz
  autorização humana anterior identificável, sem criar ou ampliar permissões,
  conforme [AGENTS.md](../../AGENTS.md#autorizações-humanas-e-delegações).
- Fetch e sincronização fast-forward segura são permitidos nas condições de
  [AGENTS.md](../../AGENTS.md#operações-git-e-autorizações). Isso não autoriza
  rebase, merge não fast-forward ou integração entre branches. A sincronização
  da `main` após PR integrado segue sua
  [exceção específica](../../AGENTS.md#sincronizacao-da-coordenacao), sem autorizar
  atuação no worktree de outro agente.
- Seguir [AGENTS.md](../../AGENTS.md) para operações destrutivas, hooks e deploy,
  e o fluxo de [Revisão](revisao.md) para integração. Concluir o desenvolvimento
  não autoriza integrar ou publicar. Somente o humano responsável executa o
  merge remoto do PR na `main`, após revisão e autorização vinculadas ao SHA.
