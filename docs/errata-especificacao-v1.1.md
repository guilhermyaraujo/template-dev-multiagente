# Errata e registro de decisões da Especificação Técnica v1.1

Data do registro: 19 de outubro de 2026

Referência: [Especificação Técnica v1.1](especificacao-v1.md), de 19 de outubro de 2026.

Situação registrada: v1.1 aprovada como referência de implementação, com a correção documental E01 abaixo. A versão documental permanece 1.1 e o esquema de configuração permanece 1.0.

## Origem e alcance deste registro

A fonte humana é o pedido desta rodada de manutenção, que relata duas ressalvas da revisão independente da Etapa 33, solicita a correção da célula truncada e determina registrar a aprovação da v1.1 como referência de implementação. A aprovação é registrada por essa instrução humana, sem inferir aprovação de um marcador, manifesto ou parecer de agente.

A autorização desta rodada abrange apenas as correções documentais na branch `chore/manutencao`. Não autoriza implementar o instalador, alterar hooks, templates ou configurações Git, executar commit, push, merge ou rebase, modificar a main ou publicar. O manifesto e seus hashes não serão atualizados sem explicação prévia e autorização humana específica. Qualquer etapa seguinte depende de autorização humana.

## D01 — Aprovação como referência de implementação

A v1.1 passa a ser a referência aprovada para a implementação, lida em conjunto com esta errata. Isso não concede autorização operacional para implementar ou publicar: cada entrega continua sujeita ao escopo humano e à governança do projeto.

O metadado original “Situação: para revisão”, o parágrafo inicial que não concede autorização operacional e a declaração final sobre a entrega somente para revisão permanecem na especificação como histórico da versão recebida. Uma nota de registro posterior no início da especificação remete a este documento, sem substituir silenciosamente esses registros.

A nota editorial que registrou a truncagem também foi preservada, identificada como histórica e superada por E01. Não se afirma que o fragmento já estava completo ou aprovado quando foi recebido.

<a id="e01-escape-em-tabelas-markdown"></a>

## E01 — Escape em tabelas Markdown

Local: seção 7, tabela “Contexto / Contrato obrigatório”, linha “Células de tabela”.

Texto anterior, preservado exatamente como encontrado na fonte Markdown:

```markdown
| Células de tabela | Impedir criação de colunas; \` |
```

Texto corrigido na mesma linha da especificação:

```markdown
| Células de tabela | Impedir criação de colunas e linhas; em texto comum GFM, duplicar as barras invertidas originais antes de escapar cada pipe com uma barra invertida; em código inline, preservar as barras dos dados e aplicar a proteção de pipes da tabela com delimitadores seguros, sem reutilizar escape de prosa; não inserir quebras de linha físicas oriundas dos dados. Mantêm-se as rejeições da seção 2. Ver [detalhamento E01](errata-especificacao-v1.1.md#e01-escape-em-tabelas-markdown). |
```

O contrato é específico do renderizador e do contexto inline:

1. **Texto comum em células GFM:** representar cada barra invertida original por duas barras na fonte; proteger cada pipe com uma barra invertida. Tratar primeiro as barras originais e depois os pipes, sem voltar a escapar as barras de proteção acrescentadas. Assim, barras de dados não se confundem com escapes e pipes não se tornam separadores de coluna. Pontuação Markdown e HTML dos dados continuam sujeitos ao escape do contexto.
2. **Código inline em células:** usar delimitadores de crases seguros para o conteúdo e a proteção de pipes exigida pela etapa de análise da tabela GFM. As demais barras dos dados devem permanecer literais; não aplicar a duplicação de prosa indiscriminadamente. A combinação de barras e pipes deve preservar o valor renderizado, sem assumir que as regras de texto comum funcionam dentro de código.
3. **Quebras de linha:** não inserir CR, LF, CRLF ou separadores Unicode de linha/parágrafo provenientes dos dados como linhas físicas da tabela. Na v1, permanecem as rejeições da validação semântica da seção 2, inclusive para o nome de apresentação; a renderização não deve aceitá-las por substituição silenciosa. Este esclarecimento não cria suporte a configuração multilinha. Um contexto futuro que o permita precisará definir, em mudança autorizada, uma representação inline compatível com o renderizador e confinada a uma única linha física da fonte.
4. **Estrutura e contexto:** dados não podem criar colunas, linhas, cabeçalhos, blocos ou HTML ativo. Não existe escape universal; mudar de contexto ou renderizador exige conferir a preservação dos caracteres e da estrutura. Tokens inseridos como dados não são reinterpretados.

Exemplos de fonte GFM para leitura do contrato, sem gerador ou código de instalação:

```markdown
| Exemplo | Valor |
| --- | --- |
| Pipe em texto comum | a \| b |
| Barra em texto comum | C:\\Projetos\\Aurora |
| Barra seguida de pipe em texto comum | \\\| |
| Pipe em código inline | `a \| b` |
| Barras em código inline | `C:\Projetos\Aurora` |
```

A distinção entre proteção de pipes na tabela e tratamento de barras em inlines foi conferida nas fontes primárias: [GitHub Docs — Tables](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/organizing-information-with-tables), [GFM — Tables](https://github.github.com/gfm/#tables-extension-), [GFM — Backslash escapes](https://github.github.com/gfm/#backslash-escapes) e [GFM — Code spans](https://github.github.com/gfm/#code-spans). A rejeição de quebras de dados e os limites operacionais vêm da especificação deste projeto.

## Rastreabilidade documental

- `docs/especificacao-v1.md`: célula corrigida, ponte visível para o registro posterior de aprovação e identificação da nota editorial original como histórica, mantendo seu texto.
- `docs/templates.md`: referência à truncagem substituída por referência à correção E01.
- `docs/atualizacao.md`: antiga pendência de confirmação identificada como resolvida por E01.
- `docs/errata-especificacao-v1.1.md`: registro novo da aprovação, dos textos anterior e corrigido e do alcance autorizado.

## Impacto no manifesto

O `package.manifest.json` foi preservado. A alteração dos três documentos existentes torna seus hashes registrados anteriores aos novos bytes, e esta errata ainda não consta do inventário. O material documental atual, portanto, não deve ser apresentado como integralmente conferido por esse manifesto.

Uma atualização posterior precisará recalcular somente os hashes dos três documentos alterados e adicionar esta errata com seu hash e modo esperado `100644`, preservando as demais entradas. Essa operação aguarda autorização humana; este registro não a executa nem a concede.
