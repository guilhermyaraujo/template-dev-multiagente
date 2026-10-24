#Requires -Version 5.1
# Modulo do instalador multiagente. Esta entrega implementa as fases Plan
# (leitura, validacao, renderizacao em memoria e inspecao, sem modificacoes),
# PrepareMaintenance (clone, manutencao ausente na base autorizada e geracao nela,
# sem preparar indice, commit, push ou PR), CompleteWorktrees (Codex e Claude
# ausentes na base integrada comprovada e ativacao local dos hooks quando a
# politica permitir, sem sincronizar a coordenacao, fetch, commit, push, PR ou merge)
# e Validate (conformidade dos quatro ambientes, somente leitura).
# Fonte ASCII: dispensa BOM no Windows PowerShell 5.1.

Set-StrictMode -Version 2.0

$script:MaRoles = @('coordination', 'codex', 'claude', 'maintenance')
$script:MaDefaultBranches = [ordered]@{
    coordination = 'main'
    codex        = 'feature/codex'
    claude       = 'feature/claude'
    maintenance  = 'chore/manutencao'
}
$script:MaDirectorySuffixes = @{ coordination = ''; codex = '-codex'; claude = '-claude'; maintenance = '-manutencao' }
$script:MaExpectedConfigName = 'multiagente.config.json'
$script:MaExpectedSpecificationVersion = '1.1'
$script:MaMinimumGitVersion = New-Object Version 2, 44, 0
$script:MaExclusiveDirectories = @('.githooks', 'docs/agentes', '.multiagente')
$script:MaManifestPath = '.multiagente/manifest.json'
$script:MaHookPaths = @('.githooks/pre-commit', '.githooks/pre-push')
$script:MaGitTimeoutMilliseconds = 60000
# Clone acessa o remoto e transfere objetos: prazo proprio.
$script:MaCloneTimeoutMilliseconds = 600000
# Transportes que o Git do instalador pode usar (GIT_ALLOW_PROTOCOL, ver
# Invoke-MaGit): somente HTTPS e SSH, como na URL configurada.
$script:MaAllowedProtocols = 'https:ssh'
$script:MaAuthorizationReferenceMaxLength = 500
# Variaveis de processo que redirecionam repositorio, indice ou configuracao.
# Sua presenca torna a inspecao inconclusiva; nunca sao removidas silenciosamente.
$script:MaGitOverrideVariables = @(
    'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
    'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS',
    'GIT_CONFIG_COUNT', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM',
    'GIT_REPLACE_REF_BASE', 'GIT_SHALLOW_FILE', 'GIT_GRAFT_FILE', 'GIT_DISCOVERY_ACROSS_FILESYSTEM'
)
# Substituivel apenas pelos testes unitarios (escopo do modulo).
$script:MaGitInvoker = $null
$script:MaGitPath = $null
# Ambiente de transporte do clone (Get-MaGitTransport), definido por
# Get-MaGitContext somente com o Git real e o exec-path confiavel.
$script:MaGitTransport = $null
# Somente testes de integracao: argumentos -c acrescentados ao clone e a
# verificacao previa do seu transporte, como uma configuracao do consumidor (por
# exemplo core.sshCommand de um ssh ficticio local). Nao alteram a politica de
# protocolos, fixada no ambiente do processo. A URL registrada no origin continua
# a configurada. Vazio por padrao.
$script:MaCloneTestArguments = @()
# Somente testes de integracao: comando do ssh ficticio local que substitui, no
# clone, o cliente SSH fixado da instalacao (GIT_SSH_COMMAND). Nao vem da
# configuracao nem do ambiente; core.sshCommand do consumidor continua recusado.
# $null por padrao.
$script:MaSshTestCommand = $null
# API kernel32 emitida em memoria ($false: indisponivel; os testes usam $false
# para simular a indisponibilidade).
$script:MaNativeApi = $null
# API de abertura vinculada a handles (ntdll/kernel32), com a mesma convencao.
$script:MaFileApi = $null
# Somente testes: pontos nomeados de injecao de falhas do executor (nome ->
# scriptblock que recebe o contexto do ponto). Se a acao lancar, simula excecao
# inesperada no ponto; se devolver $true, a operacao nativa do ponto e tratada
# como falha e nao e executada. Vazio por padrao. Ver Test-MaNativeFault.
# Os mesmos pontos servem as operacoes de arquivo, a PrepareMaintenance
# (ChainComponent, GovernedFileChain, GovernedFileCreate, PrepareLocked), a
# CompleteWorktrees (CompleteBeforeWorktree, CompleteBeforeHooks) e a Validate
# (ValidateBeforeRecheck), onde a acao simula concorrencia e o retorno e ignorado.
$script:MaNativeFaults = @{}
# Somente testes: recebe a evidencia da associacao e devolve a evidencia usada.
$script:MaNativeAssociationProbe = $null
# Prazo para conferir encerramentos e para o job esvaziar apos a saida normal.
$script:MaTerminationConfirmMilliseconds = 5000
$script:MaJobSettleMilliseconds = 1000

$script:MaMessages = @{
    MA_UTF8_READ_INVALID                 = 'Arquivo ilegivel ou com UTF-8 invalido.'
    MA_JSON_STRING_EXPECTED              = 'JSON invalido: texto esperado.'
    MA_JSON_STRING_CONTROL               = 'JSON invalido: caractere de controle sem escape.'
    MA_JSON_ESCAPE_INVALID               = 'JSON invalido: escape desconhecido.'
    MA_JSON_UNICODE_INVALID              = 'JSON invalido: escape Unicode incorreto.'
    MA_JSON_STRING_UNCLOSED              = 'JSON invalido: texto sem fechamento.'
    MA_JSON_SURROGATE_INVALID            = 'JSON invalido: par substituto Unicode incompleto.'
    MA_JSON_DEPTH_EXCEEDED               = 'JSON invalido: profundidade excessiva.'
    MA_JSON_VALUE_EXPECTED               = 'JSON invalido: valor esperado.'
    MA_JSON_DUPLICATE_KEY                = 'JSON invalido: chave duplicada, inclusive por diferenca de caixa.'
    MA_JSON_COLON_EXPECTED               = 'JSON invalido: dois-pontos esperado.'
    MA_JSON_OBJECT_UNCLOSED              = 'JSON invalido: objeto sem fechamento.'
    MA_JSON_ARRAY_UNCLOSED               = 'JSON invalido: lista sem fechamento.'
    MA_JSON_COMMA_EXPECTED               = 'JSON invalido: virgula esperada.'
    MA_JSON_VALUE_INVALID                = 'JSON invalido: valor desconhecido.'
    MA_JSON_NUMBER_INVALID               = 'JSON invalido: numero fora do intervalo.'
    MA_JSON_TRAILING_CONTENT             = 'JSON invalido: conteudo apos o valor principal.'
    MA_SCHEMA_UNSUPPORTED                = 'Esquema de configuracao nao suportado.'
    MA_SCHEMA_VERSION_UNSUPPORTED        = 'Versao do esquema de configuracao nao suportada.'
    MA_CONFIG_TYPE                       = 'Configuracao: tipo incorreto.'
    MA_CONFIG_CONST                      = 'Configuracao: valor fixo divergente.'
    MA_CONFIG_LENGTH                     = 'Configuracao: tamanho fora do limite.'
    MA_CONFIG_PATTERN                    = 'Configuracao: formato invalido.'
    MA_CONFIG_REQUIRED                   = 'Configuracao: propriedade obrigatoria ausente.'
    MA_CONFIG_UNKNOWN_PROPERTY           = 'Configuracao: propriedade desconhecida.'
    MA_CONFIG_INSIDE_WORKTREE            = 'A configuracao deve ficar fora dos quatro worktrees.'
    MA_CONFIG_NAME_UNEXPECTED            = 'O nome previsto da configuracao e multiagente.config.json.'
    MA_PROJECT_NAME_INVALID              = 'Nome do projeto vazio ou com controles, quebras ou separadores de linha.'
    MA_PROJECT_SLUG_INVALID              = 'Slug do projeto invalido.'
    MA_REPOSITORY_URL_INVALID            = 'URL do repositorio invalida: somente HTTPS ou SSH, sem credenciais, consulta ou fragmento.'
    MA_BRANCH_INVALID                    = 'Nome de branch fora do alfabeto restrito ou das regras de referencia Git.'
    MA_BRANCH_AMBIGUOUS                  = 'Nome de branch ambiguo (HEAD ou prefixo refs/).'
    MA_BRANCH_DUPLICATE                  = 'As quatro branches devem ser distintas, inclusive sem distinguir caixa.'
    MA_BRANCH_HIERARCHY_CONFLICT         = 'Uma branch nao pode ser prefixo hierarquico de outra.'
    MA_BRANCH_GIT_REJECTED               = 'git check-ref-format --branch rejeitou o nome.'
    MA_PATH_LOCAL_ABSOLUTE_REQUIRED      = 'Caminho deve ser local, absoluto e sem controles.'
    MA_PATH_COMPONENT_UNSAFE             = 'Componente de caminho inseguro ou reservado no Windows.'
    MA_PATH_DRIVE_UNSAFE                 = 'Unidade nao local.'
    MA_PATH_REPARSE_POINT                = 'Link, junction ou ponto de redirecionamento no caminho.'
    MA_PATH_UNSUPPORTED_ENTRY            = 'Entrada de sistema de arquivos nao suportada.'
    MA_PATH_PARENT_NOT_DIRECTORY         = 'Componente intermediario do caminho nao e diretorio.'
    MA_PATH_NOT_FOUND                    = 'Caminho inexistente.'
    MA_PATH_DIRECTORY_REQUIRED           = 'Diretorio esperado.'
    MA_PATH_FILE_REQUIRED                = 'Arquivo esperado.'
    MA_PATH_INSPECTION_FAILED            = 'Inspecao de caminho inconclusiva.'
    MA_PATH_CONTAINMENT_FAILED           = 'Destino fora do diretorio pai configurado.'
    MA_PACKAGE_INSIDE_WORKTREE           = 'Pacote e destinos se sobrepoem.'
    MA_PACKAGE_REPARSE_POINT             = 'Pacote contem link ou junction.'
    MA_PACKAGE_MANIFEST_INVALID          = 'package.manifest.json invalido ou incompativel.'
    MA_PACKAGE_ENTRY_INVALID             = 'Entrada invalida no manifesto do pacote.'
    MA_PACKAGE_MODE_INVALID              = 'Modo Git declarado divergente do previsto.'
    MA_PACKAGE_HASH_MISMATCH             = 'Hash SHA-256 divergente do manifesto do pacote.'
    MA_PACKAGE_ENCODING_INVALID          = 'Codificacao invalida (CR, BOM indevido ou PowerShell nao ASCII sem BOM).'
    MA_PACKAGE_FILE_UNREADABLE           = 'Arquivo do pacote ausente ou ilegivel.'
    MA_PACKAGE_REQUIRED_NOT_INVENTORIED  = 'Arquivo obrigatorio ausente do inventario do pacote.'
    MA_PACKAGE_FILE_NOT_INVENTORIED      = 'Arquivo presente no pacote e ausente do inventario.'
    MA_PACKAGE_INSPECTION_FAILED         = 'Inspecao do pacote inconclusiva.'
    MA_TEMPLATE_ENCODING_INVALID         = 'Template com BOM ou CR.'
    MA_TEMPLATE_TOKEN_UNKNOWN            = 'Template com token desconhecido.'
    MA_TEMPLATE_TOKEN_MALFORMED          = 'Template com delimitador de token malformado.'
    MA_TEMPLATE_CONTEXT_INVALID          = 'Token em contexto nao permitido.'
    MA_TEMPLATE_ORIGIN_IDENTIFIER        = 'Template contem identificador do projeto de origem.'
    MA_RENDER_VALUE_UNSAFE               = 'Valor inadequado para o contexto de insercao.'
    MA_GIT_NOT_FOUND                     = 'Git for Windows nao localizado.'
    MA_GIT_VERSION_UNSUPPORTED           = 'Versao do Git inferior a minima exigida (2.44.0).'
    MA_GIT_EXECUTION_FAILED              = 'Falha ao executar o Git.'
    MA_GIT_ENV_OVERRIDE                  = 'Variavel de ambiente Git redireciona repositorio ou configuracao; inspecao inconclusiva.'
    MA_GIT_EXEC_PATH_UNTRUSTED           = 'Diretorio de execucao do Git (exec-path) fora da instalacao localizada ou sem git-remote-https.exe; origem dos helpers de transporte nao comprovada.'
    MA_GIT_EXEC_PATH_IGNORED             = 'GIT_EXEC_PATH do ambiente ignorado: os processos Git do instalador usam o exec-path da propria instalacao.'
    MA_GIT_TRANSPORT_UNTRUSTED           = 'Ambiente de transporte do clone nao comprovado (git.exe da instalacao ausente ou git-remote-ssh no exec-path ou no PATH restrito); clone nao executado.'
    MA_GIT_SSH_CLIENT_UNTRUSTED          = 'Cliente SSH da instalacao Git (usr\bin\ssh.exe) ausente ou de origem nao comprovada; transporte SSH recusado e clone nao executado.'
    MA_NATIVE_TIMEOUT                    = 'Processo nativo excedeu o tempo limite.'
    MA_NATIVE_CONTAINMENT_UNAVAILABLE    = 'Job Object indisponivel, nao criado ou sem os limites conferidos (KILL_ON_JOB_CLOSE, sem breakaway, handle nao herdavel); nenhum processo foi iniciado e a chamada foi recusada.'
    MA_NATIVE_CONTAINMENT_FAILED         = 'Associacao ao Job Object nao confirmada antes da execucao; processo criado suspenso, encerrado sem executar (conferido) e chamada recusada.'
    MA_NATIVE_CONTAINMENT_FAILED_UNTERMINATED = 'Associacao ao Job Object nao confirmada e encerramento do processo suspenso nao confirmado; chamada recusada. O processo nao chegou a executar.'
    MA_NATIVE_TERMINATION_UNCONFIRMED    = 'Encerramento dos processos do Job Object nao confirmado (processos ativos ou consulta falhou); resta o fechamento do job (KILL_ON_JOB_CLOSE), que nao gera confirmacao.'
    MA_NATIVE_DESCENDANT_PERSISTED       = 'Processo do Job Object permaneceu ativo apos a conclusao; processos do job encerrados (conferido) e chamada recusada.'
    MA_NATIVE_CLEANUP_FAILED             = 'Falha ao liberar handles ou streams do processo nativo; resultado recusado.'
    MA_NATIVE_JOB_QUERY_FAILED           = 'Consulta da lista de processos do Job Object recusada.'
    MA_NATIVE_CLOSE_FAILED               = 'CloseHandle recusado; o handle nao e fechado novamente.'
    MA_GIT_OBJECT_MISSING                = 'Objeto Git ausente localmente, comprovado por duas consultas sem busca remota.'
    MA_GIT_OBJECT_UNREADABLE             = 'Objeto Git presente, mas ilegivel.'
    MA_GIT_OBJECT_CORRUPT                = 'Conteudo do objeto Git nao corresponde ao identificador.'
    MA_GIT_OBJECT_TYPE_MISMATCH          = 'Objeto Git presente com tipo diferente de blob.'
    MA_GIT_OBJECT_UNVERIFIED             = 'Presenca ou leitura do objeto Git nao pode ser determinada.'
    MA_SH_NOT_FOUND                      = 'Shell sh do Git for Windows nao localizado.'
    MA_ENV_NOT_DIRECTORY                 = 'Destino do ambiente existe e nao e diretorio.'
    MA_ENV_NOT_REPOSITORY                = 'Destino existe, nao esta vazio e nao e repositorio Git.'
    MA_ENV_COORDINATION_NOT_MAIN_CLONE   = 'Coordenacao deve ser o clone principal (.git diretorio).'
    MA_ENV_NOT_LINKED_WORKTREE           = 'Ambiente deve ser worktree vinculado (.git arquivo).'
    MA_ENV_GIT_UNREADABLE                = 'Repositorio ilegivel pelo Git (permissao, safe.directory ou estado invalido).'
    MA_ENV_TOPLEVEL_MISMATCH             = 'Raiz do repositorio diferente do destino previsto.'
    MA_ENV_COMMON_DIR_MISMATCH           = 'Ambiente nao pertence ao repositorio comum da coordenacao.'
    MA_ENV_BARE                          = 'Repositorio bare nao suportado.'
    MA_ENV_SHALLOW                       = 'Clone raso nao suportado: objetos podem estar ausentes.'
    MA_ENV_PARTIAL_CLONE                 = 'Partial clone ou promisor nao suportado: leitura sem escrita nao garantida.'
    MA_ENV_SUBMODULES_UNSUPPORTED        = 'Submodulos nao suportados na instalacao automatica.'
    MA_ENV_DETACHED_HEAD                 = 'HEAD destacado; o instalador recusa esse estado.'
    MA_ENV_BRANCH_MISMATCH               = 'Branch atual diferente da configurada para o papel.'
    MA_ENV_OBJECT_FORMAT_UNSUPPORTED     = 'Formato de objetos Git nao suportado.'
    MA_REPOSITORY_NO_COMMIT              = 'Repositorio sem commit inicial; pre-requisito ausente.'
    MA_REMOTE_ORIGIN_MISSING             = 'Remoto origin ausente.'
    MA_REMOTE_ORIGIN_AMBIGUOUS           = 'Remoto origin com multiplas URLs.'
    MA_REMOTE_ORIGIN_MISMATCH            = 'URL do origin diferente da configurada.'
    MA_WORKTREE_UNEXPECTED               = 'Worktree registrado fora dos quatro ambientes previstos.'
    MA_WORKTREE_PRUNABLE                 = 'Registro de worktree indisponivel ou removivel.'
    MA_WORKTREE_NOT_REGISTERED           = 'Ambiente existente nao registrado no repositorio comum.'
    MA_BRANCH_OCCUPIED                   = 'Branch configurada ocupada por outro worktree.'
    MA_FILE_CONFLICT                     = 'Destino governado com conteudo, tipo ou modo diferente do esperado.'
    MA_FILE_UNSAFE                       = 'Destino governado com link, junction ou contencao incerta.'
    MA_FILE_UNEXPECTED_ENTRY             = 'Entrada inesperada em diretorio exclusivo.'
    MA_FILE_UNCOMMITTED_OUTSIDE_MAINTENANCE = 'Arquivo governado nao commitado fora da manutencao.'
    MA_HOOKS_PATH_PRESENT                = 'core.hooksPath ja definido; sera reavaliado antes de qualquer ativacao.'
    MA_HOOKS_DEFAULT_ACTIVE              = 'Hooks ativos no diretorio padrao; bloquearao a ativacao automatica.'
    MA_HOOKS_EFFECTIVE_ACTIVE            = 'Hooks ativos no diretorio efetivo de core.hooksPath; bloquearao a ativacao automatica.'
    MA_COMMIT_FORMAT_INVALID             = 'SHA deve ser completo (40 ou 64 hexadecimais minusculos).'
    MA_BASECOMMIT_NOT_LOCAL              = 'BaseCommit nao encontrado localmente como commit.'
    MA_PLAN_UNEXPECTED_FAILURE           = 'Falha operacional inesperada durante o planejamento.'
    MA_AUTHORIZATION_REFERENCE_REQUIRED  = 'AuthorizationReference obrigatoria para fase mutavel; e registrada como evidencia, sem inferir aprovacao.'
    MA_AUTHORIZATION_REFERENCE_INVALID   = 'AuthorizationReference invalida: uma linha, sem controles, com ate 500 caracteres.'
    MA_BASECOMMIT_REQUIRED               = 'BaseCommit completo obrigatorio para PrepareMaintenance.'
    MA_BASECOMMIT_FORMAT_MISMATCH        = 'BaseCommit com comprimento incompativel com o formato de objetos do repositorio.'
    MA_PREPARE_BASE_DIVERGENT            = 'Base divergente: o BaseCommit autorizado nao corresponde ao estado do repositorio; nenhuma branch e reposicionada.'
    MA_PREPARE_BRANCH_CASE_CONFLICT      = 'Branch existente difere da configurada somente por caixa.'
    MA_PREPARE_HOOKS_WOULD_RUN           = 'Hooks do consumidor seriam executados pela operacao Git; operacao recusada sem alterar a configuracao.'
    MA_PREPARE_FOREIGN_CHANGE            = 'Alteracao alheia no worktree de manutencao, fora do conjunto governado.'
    MA_PREPARE_FOREIGN_CHANGE_UNVERIFIED = 'Alteracoes da manutencao nao verificaveis sem executar driver externo (atributo filter em caminho rastreado).'
    MA_PREPARE_PATH_IGNORED              = 'Caminho governado ausente e ignorado por regra de exclusao; a preparacao do indice nao o incluiria.'
    MA_PREPARE_LOCKED                    = 'Outra fase mutavel em execucao para o mesmo repositorio; nenhuma operacao realizada.'
    MA_PREPARE_LOCK_UNAVAILABLE          = 'Exclusao mutua indisponivel; nenhuma operacao realizada.'
    MA_PREPARE_LOCK_RELEASE_FAILED       = 'Liberacao da exclusao mutua falhou; o sistema a libera ao fim do processo.'
    MA_PREPARE_LOCK_ABANDONED            ='Exclusao mutua abandonada por execucao anterior interrompida; estado revalidado antes de prosseguir.'
    MA_PREPARE_STATE_CHANGED             = 'Estado mudou entre a inspecao e a operacao; operacao nao executada.'
    MA_PREPARE_TARGET_CHANGED            = 'Destino governado surgiu ou mudou antes da gravacao; nada foi sobrescrito.'
    MA_PREPARE_TARGET_NOT_GOVERNED       = 'Destino fora do conjunto governado ou da manutencao; gravacao recusada.'
    MA_PREPARE_WRITE_FAILED              = 'Falha ao gravar destino governado.'
    MA_PREPARE_WRITE_VERIFY_FAILED       = 'Bytes gravados divergem dos renderizados.'
    MA_PREPARE_RENDER_UNAVAILABLE        = 'Renderizacao indisponivel; nenhuma gravacao.'
    MA_PREPARE_COORDINATION_UNAVAILABLE  = 'Coordenacao indisponivel ou nao inspecionada.'
    MA_PREPARE_MAINTENANCE_UNAVAILABLE   = 'Manutencao indisponivel ou nao inspecionada.'
    MA_REMOTE_BRANCH_NOT_FOUND           = 'Branch de coordenacao inexistente no remoto (remoto vazio ou sem a branch); pre-requisito ausente, nada foi criado.'
    MA_REPOSITORY_TRANSPORT_UNSAFE       = 'Transporte efetivo do clone fora de HTTPS ou SSH (reescrita url.*.insteadOf, remote helper, remote.origin.vcs, alias.remote-ssh ou remote.origin.url de outra camada); clone nao executado e configuracao preservada.'
    MA_REPOSITORY_SSH_COMMAND_UNSUPPORTED = 'Comando SSH personalizado (core.sshCommand, GIT_SSH ou GIT_SSH_COMMAND) nao suportado na v1.0: o clone usa somente o cliente SSH da instalacao Git; clone nao executado e configuracao preservada.'
    MA_REPOSITORY_TRANSPORT_UNVERIFIED   = 'Transporte efetivo do clone nao determinado (git ls-remote --get-url, remote.origin.vcs ou remote.origin.url ilegivel); clone nao executado.'
    MA_REPOSITORY_TRANSPORT_REWRITTEN    = 'URL do repositorio reescrita pela configuracao Git (url.*.insteadOf); transporte efetivo permitido, configuracao preservada.'
    MA_PREPARE_CLONE_FAILED              = 'Falha no clone.'
    MA_PREPARE_CLONE_RESIDUE             = 'Clone falhou e deixou conteudo no destino; preservado sem remocao automatica.'
    MA_PREPARE_WORKTREE_FAILED           = 'Falha ao criar o worktree de manutencao.'
    MA_PREPARE_VERIFY_FAILED             = 'Verificacao final da manutencao divergente.'
    MA_PREPARE_UNEXPECTED_FAILURE        = 'Falha operacional inesperada durante PrepareMaintenance.'
    MA_PATH_HANDLE_UNAVAILABLE           = 'Abertura vinculada a handles (NtCreateFile) indisponivel; nenhuma operacao mutavel realizada.'
    MA_PATH_HANDLE_CLOSE_FAILED          = 'Falha ao fechar handle de diretorio fixado; resultado recusado.'
    MA_PATH_PIN_FAILED                   ='Caminho nao fixado por handle sem compartilhamento de exclusao (entrada em uso ou acesso negado); operacao recusada.'
    MA_PREPARE_CONFIG_CHANGED            = 'Configuracao relida difere da usada na exclusao mutua; nenhuma operacao no destino relido.'
    MA_PREPARE_TARGET_REDIRECTED         = 'Ponto de reparse surgiu no destino durante a operacao Git; estado preservado e fase interrompida.'
    MA_PREPARE_CHECKOUT_FILTER           = 'Checkout executaria filtro externo (atributo filter); checkout nao realizado e configuracao preservada.'
    MA_PREPARE_CHECKOUT_UNSUPPORTED      = 'Origem alternativa de atributos (attr.tree ou GIT_ATTR_SOURCE) nao suportada no checkout; checkout nao realizado.'
    MA_PREPARE_CHECKOUT_PENDING          = 'Checkout pendente com conteudo alem de .git no destino; retomada recusada sem alterar o conteudo.'
    MA_PREPARE_CHECKOUT_FAILED           = 'Falha no checkout posterior ao clone ou worktree sem checkout.'
    MA_PREPARE_FSMONITOR_DISABLED        = 'core.fsmonitor configurado; o instalador executa o Git com core.fsmonitor=false, sem alterar a configuracao.'
    MA_ENV_CHECKOUT_PENDING              = 'Clone ou worktree sem checkout (indice ausente); PrepareMaintenance conclui o checkout somente apos verificar filtros, hooks e atributos.'
    MA_INTEGRATEDCOMMIT_REQUIRED         = 'IntegratedCommit completo obrigatorio para CompleteWorktrees.'
    MA_INTEGRATION_REFERENCE_REQUIRED    = 'IntegrationReference obrigatoria para CompleteWorktrees: caminho local do registro JSON da integracao.'
    MA_INTEGRATION_REFERENCE_INVALID     = 'Registro de integracao ilegivel, incompleto ou fora do formato 1.0; nenhuma aprovacao e inferida.'
    MA_INTEGRATION_REFERENCE_INSIDE_WORKTREE = 'O registro de integracao deve ficar fora dos quatro worktrees.'
    MA_INTEGRATION_EVIDENCE_MISMATCH     = 'Registro de integracao inconsistente com a configuracao, os parametros ou o estado local.'
    MA_INTEGRATION_REVIEW_NOT_INDEPENDENT = 'Revisao registrada pelo proprio autor; revisao independente nao comprovada.'
    MA_COMPLETE_PREREQUISITE_MISSING     = 'Coordenacao ou manutencao ausente ou nao inspecionada; CompleteWorktrees exige ambas preparadas.'
    MA_COMPLETE_COMMIT_UNAVAILABLE       = 'Commit revisado (M) ou integrado (I) ausente, ilegivel ou de outro tipo no banco de objetos local; nenhuma busca remota realizada.'
    MA_COMPLETE_COORDINATION_NOT_SYNCED  = 'Coordenacao nao contem o commit integrado; a sincronizacao cabe ao responsavel, no proprio worktree, fora do instalador.'
    MA_COMPLETE_MAINTENANCE_NOT_REVIEWED = 'HEAD da manutencao diferente do HEAD revisado (M); a manutencao nao e reposicionada.'
    MA_COMPLETE_GOVERNED_DIVERGENT       = 'Conteudo governado divergente do esperado (existencia, tipo, modo ou bytes).'
    MA_COMPLETE_AUTHORIZATION_SCOPE      = 'Autorizacao registrada nao abrange a operacao ou todos os ambientes afetados; operacao nao executada.'
    MA_COMPLETE_HOOKS_NOT_AUTHORIZED     = 'Ativacao dos hooks fora da autorizacao registrada (operacao configure-hooks com os quatro ambientes); configuracao preservada.'
    MA_COMPLETE_BRANCH_NOT_FROM_INTEGRATION = 'Branch de agente cujo HEAD nao contem o commit integrado na ancestralidade; nao e reutilizada nem reposicionada.'
    MA_COMPLETE_REMOTE_TRACKING_UNCONFIRMED = 'Referencia de acompanhamento remoto da coordenacao ausente ou sem o commit integrado; estado remoto nao verificado (sem fetch).'
    MA_COMPLETE_WORKTREE_FAILED          = 'Falha ao criar worktree de agente.'
    MA_COMPLETE_VERIFY_FAILED            = 'Verificacao final dos quatro ambientes divergente.'
    MA_COMPLETE_UNEXPECTED_FAILURE       = 'Falha operacional inesperada durante CompleteWorktrees.'
    MA_HOOKS_SCOPE_INCOMPLETE            = 'Alcance da configuracao compartilhada diferente dos quatro ambientes previstos (registro ausente, extra ou indisponivel).'
    MA_HOOKS_CONFIG_CONFLICT             = 'core.hooksPath com valor vazio, caminho distinto, escopo diferente do local ou ocorrencias conflitantes.'
    MA_HOOKS_PROCESS_OVERRIDE            = 'core.hooksPath definido pelo processo (escopo command) mascarando o estado persistente; nada e removido.'
    MA_HOOKS_PRECEDENCE_INCONCLUSIVE     = 'Diretorio de hooks efetivo diferente do previsto pela cadeia de core.hooksPath; precedencia inconclusiva.'
    MA_HOOKS_DEFAULT_WOULD_BE_HIDDEN     = 'Hooks ativos no diretorio padrao seriam ocultados pela ativacao; nada e alterado.'
    MA_HOOKS_GOVERNED_INVALID            = '.githooks do ambiente ausente, alterada ou com arquivo inesperado.'
    MA_HOOKS_ACTIVATION_FAILED           = 'Falha ao inserir core.hooksPath na configuracao local.'
    MA_HOOKS_VERIFY_FAILED               = 'Configuracao efetiva dos hooks divergente apos a escrita.'
    MA_VALIDATE_UNEXPECTED_FAILURE       = 'Falha operacional inesperada durante Validate.'
    MA_VALIDATE_COORDINATION_CHANGED     = 'Alteracao de trabalho na coordenacao (arquivo alterado, preparado no indice ou nao rastreado); a coordenacao nao recebe edicoes.'
    MA_VALIDATE_WORKING_CHANGES          = 'Alteracoes de trabalho fora do conjunto governado; informativo, sem efeito na conformidade governada.'
    MA_VALIDATE_CHANGES_UNVERIFIED       = 'Alteracoes de trabalho nao verificaveis sem executar driver externo (atributo filter em caminho rastreado).'
    MA_VALIDATE_CONCURRENT_PHASE         = 'Fase mutavel do instalador em execucao para o mesmo repositorio; inspecao nao confiavel.'
    MA_VALIDATE_CONCURRENCY_UNVERIFIED   = 'Exclusao mutua das fases mutaveis nao consultada; execucao concorrente nao descartada.'
    MA_VALIDATE_STATE_CHANGED            = 'Estado mudou durante a validacao (HEAD, branch, worktrees, branches locais ou core.hooksPath); resultado inconclusivo.'
    MA_VALIDATE_NOT_CONFIRMED            = 'Conformidade nao confirmada: condicao obrigatoria sem verificacao conclusiva.'
}

function Get-MaMessage {
    param([string]$Code)
    if ($script:MaMessages.ContainsKey($Code)) { return $script:MaMessages[$Code] }
    return 'Falha sem descricao registrada.'
}

function New-MaIssue {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [ValidateSet('Falha', 'Bloqueio', 'Aviso')][string]$Severity = 'Bloqueio',
        [string]$Role = '',
        [string]$Path = '',
        [string]$Detail = ''
    )
    return [pscustomobject]@{ Code = $Code; Severity = $Severity; Role = $Role; Path = $Path; Message = (Get-MaMessage $Code); Detail = $Detail }
}

function Get-MaErrorCode {
    param($ErrorRecord, [string]$Fallback)
    $message = [string]$ErrorRecord.Exception.Message
    if ($message -cmatch '\AMA_[A-Z0-9_]+\z') { return $message }
    return $Fallback
}

# Etapa, erro Win32, causa e falhas de limpeza registrados pelo executor nativo,
# para o detalhe do impedimento. Sem dados, devolve texto vazio.
function Get-MaErrorDetail {
    param($ErrorRecord)
    $data = $ErrorRecord.Exception.Data
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('Stage', 'Win32Error', 'Cause')) {
        if ($data.Contains($key) -and $null -ne $data[$key] -and [string]$data[$key] -cne '' -and [string]$data[$key] -cne '0') { $parts.Add($key + '=' + [string]$data[$key]) }
    }
    if ($data.Contains('CleanupFailures')) { $parts.Add('CleanupFailures=' + (@($data['CleanupFailures']) -join ',')) }
    return ($parts -join '; ')
}

# --- Bytes, hashes e UTF-8 (base: Codex) ---------------------------------------

function Get-MaSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

# Identificador do blob Git calculado sem executar o Git e sem filtros.
function Get-MaGitBlobId {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes, [ValidateSet('sha1', 'sha256')][string]$ObjectFormat = 'sha1')
    return (Get-MaGitObjectId $Bytes $ObjectFormat 'blob')
}

# Identificador de um objeto Git (blob ou commit) calculado sobre os bytes lidos.
function Get-MaGitObjectId {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes, [ValidateSet('sha1', 'sha256')][string]$ObjectFormat = 'sha1', [ValidateSet('blob', 'commit')][string]$Type = 'blob')
    $header = [Text.Encoding]::ASCII.GetBytes($Type + ' ' + $Bytes.Length + [char]0)
    $buffer = New-Object byte[] ($header.Length + $Bytes.Length)
    [Array]::Copy($header, 0, $buffer, 0, $header.Length)
    [Array]::Copy($Bytes, 0, $buffer, $header.Length, $Bytes.Length)
    if ($ObjectFormat -ceq 'sha256') { $algorithm = [System.Security.Cryptography.SHA256]::Create() }
    else { $algorithm = [System.Security.Cryptography.SHA1]::Create() }
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($buffer))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Test-MaBytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) { if ($Left[$index] -ne $Right[$index]) { return $false } }
    return $true
}

function Test-MaHasUtf8Bom {
    param([byte[]]$Bytes)
    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191)
}

function ConvertFrom-MaUtf8Bytes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $offset = 0
    if (Test-MaHasUtf8Bom $Bytes) { $offset = 3 }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    try { return $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset) }
    catch { throw 'MA_UTF8_READ_INVALID' }
}

function Read-MaUtf8 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    try { $bytes = [IO.File]::ReadAllBytes($LiteralPath) } catch { throw 'MA_UTF8_READ_INVALID' }
    return (ConvertFrom-MaUtf8Bytes $bytes)
}

# --- JSON estrito (base: Codex, sem alteracao funcional) ----------------------

function Skip-MaJsonWhitespace {
    param($State)
    while ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -in @(32, 9, 10, 13)) { $State.Index++ }
}

function Read-MaJsonString {
    param($State)
    if ($State.Index -ge $State.Text.Length -or $State.Text[$State.Index] -ne '"') { throw 'MA_JSON_STRING_EXPECTED' }
    $State.Index++
    $builder = New-Object System.Text.StringBuilder
    $closed = $false
    while ($State.Index -lt $State.Text.Length) {
        $character = $State.Text[$State.Index]; $State.Index++
        if ($character -eq '"') { $closed = $true; break }
        if ([int][char]$character -lt 32) { throw 'MA_JSON_STRING_CONTROL' }
        if ($character -eq '\') {
            if ($State.Index -ge $State.Text.Length) { throw 'MA_JSON_ESCAPE_INVALID' }
            $escape = $State.Text[$State.Index]; $State.Index++
            switch -CaseSensitive ($escape) {
                '"' { [void]$builder.Append('"') }
                '\' { [void]$builder.Append('\') }
                '/' { [void]$builder.Append('/') }
                'b' { [void]$builder.Append([char]8) }
                'f' { [void]$builder.Append([char]12) }
                'n' { [void]$builder.Append([char]10) }
                'r' { [void]$builder.Append([char]13) }
                't' { [void]$builder.Append([char]9) }
                'u' {
                    if ($State.Index + 4 -gt $State.Text.Length) { throw 'MA_JSON_UNICODE_INVALID' }
                    $hex = $State.Text.Substring($State.Index, 4)
                    if ($hex -cnotmatch '\A[0-9a-fA-F]{4}\z') { throw 'MA_JSON_UNICODE_INVALID' }
                    [void]$builder.Append([char][Convert]::ToInt32($hex, 16)); $State.Index += 4
                }
                default { throw 'MA_JSON_ESCAPE_INVALID' }
            }
        } else { [void]$builder.Append($character) }
    }
    if (-not $closed) { throw 'MA_JSON_STRING_UNCLOSED' }
    $value = $builder.ToString()
    for ($index = 0; $index -lt $value.Length; $index++) {
        if ([char]::IsHighSurrogate($value[$index])) {
            if ($index + 1 -ge $value.Length -or -not [char]::IsLowSurrogate($value[$index + 1])) { throw 'MA_JSON_SURROGATE_INVALID' }
            $index++
        } elseif ([char]::IsLowSurrogate($value[$index])) { throw 'MA_JSON_SURROGATE_INVALID' }
    }
    return $value
}

function Read-MaJsonValue {
    param($State, [int]$Depth)
    if ($Depth -gt $State.MaxDepth) { throw 'MA_JSON_DEPTH_EXCEEDED' }
    Skip-MaJsonWhitespace $State
    if ($State.Index -ge $State.Text.Length) { throw 'MA_JSON_VALUE_EXPECTED' }
    $character = $State.Text[$State.Index]
    if ($character -eq '"') { return (Read-MaJsonString $State) }
    if ($character -eq '{') {
        $State.Index++; Skip-MaJsonWhitespace $State
        # Chaves sem distincao de caixa: duplicatas por caixa sao rejeitadas.
        $object = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq '}') { $State.Index++; return , $object }
        while ($true) {
            Skip-MaJsonWhitespace $State
            $key = Read-MaJsonString $State
            if ($object.ContainsKey($key)) { throw 'MA_JSON_DUPLICATE_KEY' }
            Skip-MaJsonWhitespace $State
            if ($State.Index -ge $State.Text.Length -or $State.Text[$State.Index] -ne ':') { throw 'MA_JSON_COLON_EXPECTED' }
            $State.Index++
            $value = Read-MaJsonValue $State ($Depth + 1)
            $object.Add($key, $value)
            Skip-MaJsonWhitespace $State
            if ($State.Index -ge $State.Text.Length) { throw 'MA_JSON_OBJECT_UNCLOSED' }
            $delimiter = $State.Text[$State.Index]; $State.Index++
            if ($delimiter -eq '}') { return , $object }
            if ($delimiter -ne ',') { throw 'MA_JSON_COMMA_EXPECTED' }
        }
    }
    if ($character -eq '[') {
        $State.Index++; Skip-MaJsonWhitespace $State
        $array = New-Object System.Collections.ArrayList
        if ($State.Index -lt $State.Text.Length -and $State.Text[$State.Index] -eq ']') { $State.Index++; return , ([object[]]$array.ToArray()) }
        while ($true) {
            $value = Read-MaJsonValue $State ($Depth + 1)
            [void]$array.Add($value)
            Skip-MaJsonWhitespace $State
            if ($State.Index -ge $State.Text.Length) { throw 'MA_JSON_ARRAY_UNCLOSED' }
            $delimiter = $State.Text[$State.Index]; $State.Index++
            if ($delimiter -eq ']') { return , ([object[]]$array.ToArray()) }
            if ($delimiter -ne ',') { throw 'MA_JSON_COMMA_EXPECTED' }
        }
    }
    foreach ($literal in @('true', 'false', 'null')) {
        if ($State.Text.Length - $State.Index -ge $literal.Length -and $State.Text.Substring($State.Index, $literal.Length) -ceq $literal) {
            $State.Index += $literal.Length
            if ($literal -ceq 'null') { return $null }
            return ($literal -ceq 'true')
        }
    }
    $match = [regex]::Match($State.Text.Substring($State.Index), '\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?')
    if (-not $match.Success) { throw 'MA_JSON_VALUE_INVALID' }
    $State.Index += $match.Length
    $number = 0.0
    if (-not [double]::TryParse($match.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or [double]::IsInfinity($number) -or [double]::IsNaN($number)) { throw 'MA_JSON_NUMBER_INVALID' }
    return $number
}

function Read-MaJsonStrict {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text, [ValidateRange(1, 256)][int]$MaxDepth = 64)
    $state = @{ Text = $Text; Index = 0; MaxDepth = $MaxDepth }
    $result = Read-MaJsonValue $state 0
    Skip-MaJsonWhitespace $state
    if ($state.Index -ne $Text.Length) { throw 'MA_JSON_TRAILING_CONTENT' }
    return , $result
}

# Serializacao JSON deterministica, identica nos dois PowerShells.
# ConvertTo-Json foi evitado: indentacao e escapes diferem entre 5.1 e 7.
function ConvertTo-MaJsonString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        $code = [int]$character
        if ($code -eq 34) { [void]$builder.Append('\"') }
        elseif ($code -eq 92) { [void]$builder.Append('\\') }
        elseif ($code -eq 10) { [void]$builder.Append('\n') }
        elseif ($code -eq 13) { [void]$builder.Append('\r') }
        elseif ($code -eq 9) { [void]$builder.Append('\t') }
        elseif ($code -lt 32 -or $code -eq 0x2028 -or $code -eq 0x2029) { [void]$builder.Append('\u' + $code.ToString('x4')) }
        else { [void]$builder.Append($character) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-MaJsonText {
    param([AllowNull()]$Value, [int]$Indent = 0)
    $pad = '  ' * $Indent
    $inner = '  ' * ($Indent + 1)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-MaJsonString $Value) }
    if ($Value -is [int] -or $Value -is [long]) { return ([string]$Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return '{}' }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($key in $Value.Keys) { $parts.Add($inner + (ConvertTo-MaJsonString ([string]$key)) + ': ' + (ConvertTo-MaJsonText $Value[$key] ($Indent + 1))) }
        return "{`n" + ($parts -join ",`n") + "`n" + $pad + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $items) { $parts.Add($inner + (ConvertTo-MaJsonText $item ($Indent + 1))) }
        return "[`n" + ($parts -join ",`n") + "`n" + $pad + ']'
    }
    throw 'MA_RENDER_VALUE_UNSAFE'
}

# --- Esquema (base: Codex; corrigidos comprimento e ancora de pattern) --------

function Test-MaExactKey {
    param([System.Collections.IDictionary]$Object, [string]$Key)
    foreach ($existing in $Object.Keys) { if ([string]::Equals([string]$existing, $Key, [StringComparison]::Ordinal)) { return $true } }
    return $false
}

# JSON Schema conta pontos de codigo, nao unidades UTF-16.
function Get-MaCodePointLength {
    param([string]$Value)
    $count = 0
    for ($index = 0; $index -lt $Value.Length; $index++) {
        if ([char]::IsHighSurrogate($Value[$index]) -and $index + 1 -lt $Value.Length -and [char]::IsLowSurrogate($Value[$index + 1])) { $index++ }
        $count++
    }
    return $count
}

# Em .NET, '$' aceita uma quebra de linha final; em ECMA-262 (JSON Schema), nao.
function Test-MaSchemaPattern {
    param([string]$Value, [string]$Pattern)
    if (-not [regex]::IsMatch($Value, $Pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) { return $false }
    if ($Pattern.EndsWith('$') -and $Value.EndsWith("`n")) { return $false }
    return $true
}

function Assert-MaSchema {
    param($Value, [System.Collections.IDictionary]$Schema)
    $allowed = @('$schema', 'title', 'type', 'additionalProperties', 'required', 'properties', 'const', 'default', 'minLength', 'maxLength', 'pattern')
    foreach ($key in $Schema.Keys) { if ($key -cnotin $allowed) { throw 'MA_SCHEMA_UNSUPPORTED' } }
    if ($Schema.Contains('type')) {
        switch -CaseSensitive ($Schema.type) {
            'object' { if ($Value -isnot [System.Collections.IDictionary]) { throw 'MA_CONFIG_TYPE' } }
            'string' { if ($Value -isnot [string]) { throw 'MA_CONFIG_TYPE' } }
            default { throw 'MA_SCHEMA_UNSUPPORTED' }
        }
    }
    if ($Schema.Contains('const') -and ($Value -isnot [string] -or $Value -cne $Schema.const)) { throw 'MA_CONFIG_CONST' }
    if ($Value -is [string]) {
        $length = Get-MaCodePointLength $Value
        if ($Schema.Contains('minLength') -and $length -lt $Schema.minLength) { throw 'MA_CONFIG_LENGTH' }
        if ($Schema.Contains('maxLength') -and $length -gt $Schema.maxLength) { throw 'MA_CONFIG_LENGTH' }
        if ($Schema.Contains('pattern') -and -not (Test-MaSchemaPattern $Value ([string]$Schema.pattern))) { throw 'MA_CONFIG_PATTERN' }
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Schema.Contains('additionalProperties') -and $Schema.additionalProperties -ne $false) { throw 'MA_SCHEMA_UNSUPPORTED' }
        if ($Schema.Contains('required')) {
            foreach ($required in $Schema.required) { if (-not (Test-MaExactKey $Value $required)) { throw 'MA_CONFIG_REQUIRED' } }
        }
        foreach ($key in $Value.Keys) {
            if (-not $Schema.Contains('properties') -or -not (Test-MaExactKey $Schema.properties $key)) { throw 'MA_CONFIG_UNKNOWN_PROPERTY' }
            Assert-MaSchema $Value[$key] $Schema.properties[$key]
        }
    }
}

# --- Caminhos (base: Codex; acrescidos CONIN$/CONOUT$ e pai nao diretorio) ----

function Test-MaWindowsComponent {
    param([string]$Component)
    if ($Component -in @('.', '..')) { return $false }
    if ($Component -match '[<>:"|?*\\/]' -or $Component -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]') { return $false }
    if ($Component -match '[. ]\z') { return $false }
    if ($Component -match '\A(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9\xB9\xB2\xB3]|LPT[1-9\xB9\xB2\xB3])(?:\.|\z)') { return $false }
    return $true
}

function Assert-MaSafePath {
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [ValidateSet('Any', 'File', 'Directory')][string]$Kind = 'Any', [switch]$AllowMissing)
    if ($LiteralPath -notmatch '\A[A-Za-z]:[\\/]' -or $LiteralPath -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]' -or $LiteralPath.Substring(2).Contains(':')) { throw 'MA_PATH_LOCAL_ABSOLUTE_REQUIRED' }
    $normalized = $LiteralPath.Replace('/', '\')
    $components = @($normalized.Substring(3).Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))
    foreach ($component in $components) { if (-not (Test-MaWindowsComponent $component)) { throw 'MA_PATH_COMPONENT_UNSAFE' } }
    try {
        $canonical = [IO.Path]::GetFullPath($normalized)
        $pathRoot = [IO.Path]::GetPathRoot($canonical)
        $drive = New-Object IO.DriveInfo($pathRoot)
        if ($drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable)) { throw 'MA_PATH_DRIVE_UNSAFE' }
        $current = $pathRoot
        $rootItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'MA_PATH_REPARSE_POINT' }
        $missing = $false
        for ($index = 0; $index -lt $components.Count; $index++) {
            $current = [IO.Path]::Combine($current, $components[$index])
            if ($missing) { continue }
            if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'MA_PATH_REPARSE_POINT' }
                if (-not $item.PSIsContainer -and $index -lt $components.Count - 1) { throw 'MA_PATH_PARENT_NOT_DIRECTORY' }
            } else {
                # Get-Item tambem revela entradas de redirecionamento pendentes ocultadas por Exists.
                $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
                if ($null -ne $item) { throw 'MA_PATH_UNSUPPORTED_ENTRY' }
                $missing = $true
            }
        }
        $fileExists = [IO.File]::Exists($canonical); $directoryExists = [IO.Directory]::Exists($canonical)
        if (-not $fileExists -and -not $directoryExists -and -not $AllowMissing) { throw 'MA_PATH_NOT_FOUND' }
        if ($fileExists -and $Kind -eq 'Directory') { throw 'MA_PATH_DIRECTORY_REQUIRED' }
        if ($directoryExists -and $Kind -eq 'File') { throw 'MA_PATH_FILE_REQUIRED' }
        return $canonical.TrimEnd('\') + $(if ($canonical.Length -eq 3) { '\' } else { '' })
    } catch {
        throw (Get-MaErrorCode $_ 'MA_PATH_INSPECTION_FAILED')
    }
}

function Test-MaPathWithin {
    param([string]$Path, [string]$Container)
    $Path = $Path.TrimEnd('\'); $Container = $Container.TrimEnd('\')
    return ($Path.Equals($Container, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Container + '\', [StringComparison]::OrdinalIgnoreCase))
}

function ConvertTo-MaWindowsPath {
    param([string]$Path)
    $value = $Path.Replace('/', '\')
    if ($value.Length -gt 3) { $value = $value.TrimEnd('\') }
    return $value
}

# --- URL e branches ------------------------------------------------------------

function Assert-MaRepositoryUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -match '[\s\p{Cc}\p{Cf}\p{Zl}\p{Zp}\\?#]' -or $Url -match '%(?:0[0-9a-f]|1[0-9a-f]|7f|2[03f]|5c)') { throw 'MA_REPOSITORY_URL_INVALID' }
    $hostPattern = '\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\z'
    if ($Url -cmatch '\Ahttps://') {
        $uri = $null
        if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -eq '/') { throw 'MA_REPOSITORY_URL_INVALID' }
        if ($uri.HostNameType -eq [UriHostNameType]::Dns -and $uri.Host -notmatch $hostPattern) { throw 'MA_REPOSITORY_URL_INVALID' }
        if ($uri.HostNameType -notin @([UriHostNameType]::Dns, [UriHostNameType]::IPv4, [UriHostNameType]::IPv6)) { throw 'MA_REPOSITORY_URL_INVALID' }
        return
    }
    if ($Url -cmatch '\Assh://') {
        $uri = $null
        if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'ssh' -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -eq '/') { throw 'MA_REPOSITORY_URL_INVALID' }
        # Usuario de transporte permitido; senha (':') proibida.
        if ($uri.UserInfo -and $uri.UserInfo -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z') { throw 'MA_REPOSITORY_URL_INVALID' }
        if ($uri.HostNameType -eq [UriHostNameType]::Dns -and $uri.Host -notmatch $hostPattern) { throw 'MA_REPOSITORY_URL_INVALID' }
        if ($uri.HostNameType -notin @([UriHostNameType]::Dns, [UriHostNameType]::IPv4, [UriHostNameType]::IPv6)) { throw 'MA_REPOSITORY_URL_INVALID' }
        return
    }
    # Forma scp: usuario@host:caminho relativo, sem '..'.
    if ($Url -cmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*:[A-Za-z0-9_][A-Za-z0-9_./-]*\z' -and $Url -notmatch '(?:\A|[:/])\.\.(?:/|\z)') { return }
    throw 'MA_REPOSITORY_URL_INVALID'
}

# Alfabeto restrito e regras de git check-ref-format reproduzidas localmente.
# A confirmacao pelo proprio Git ocorre no Plan (Test-MaBranchesWithGit).
function Get-MaBranchNameIssue {
    param([string]$Branch)
    if ($Branch -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._/-]{0,99}\z') { return 'MA_BRANCH_INVALID' }
    if ($Branch -ieq 'HEAD' -or $Branch -imatch '\Arefs/') { return 'MA_BRANCH_AMBIGUOUS' }
    if ($Branch.Contains('..') -or $Branch.Contains('//') -or $Branch.EndsWith('/') -or $Branch.EndsWith('.')) { return 'MA_BRANCH_INVALID' }
    foreach ($component in $Branch.Split('/')) {
        if ($component.StartsWith('.') -or $component -imatch '\.lock\z') { return 'MA_BRANCH_INVALID' }
        # Referencias soltas viram arquivos: nomes reservados do Windows sao recusados.
        if (-not (Test-MaWindowsComponent $component)) { return 'MA_BRANCH_INVALID' }
    }
    return $null
}

function Get-MaBranchSetIssues {
    param([System.Collections.IDictionary]$Branches)
    $issues = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($role in $script:MaRoles) {
        $code = Get-MaBranchNameIssue $Branches[$role]
        if ($code) { $issues.Add((New-MaIssue $code -Role $role)); continue }
        if (-not $seen.Add($Branches[$role])) { $issues.Add((New-MaIssue 'MA_BRANCH_DUPLICATE' -Role $role)) }
    }
    foreach ($left in $script:MaRoles) {
        foreach ($right in $script:MaRoles) {
            if ($left -ne $right -and ([string]$Branches[$right]).StartsWith([string]$Branches[$left] + '/', [StringComparison]::OrdinalIgnoreCase)) {
                $issues.Add((New-MaIssue 'MA_BRANCH_HIERARCHY_CONFLICT' -Role $right -Detail $left))
            }
        }
    }
    return , $issues.ToArray()
}

# --- Configuracao ----------------------------------------------------------------

# SchemaSha256: hash conferido pela integridade do pacote. Quando informado, os
# bytes efetivamente lidos precisam corresponder a ele (sem janela entre a
# verificacao e o uso).
function Read-MaConfiguration {
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [Parameter(Mandatory = $true)][string]$SchemaPath, [string]$SchemaSha256 = '')
    $configurationPath = Assert-MaSafePath $LiteralPath 'File'
    $checkedSchemaPath = Assert-MaSafePath $SchemaPath 'File'
    try { $schemaBytes = [IO.File]::ReadAllBytes($checkedSchemaPath) } catch { throw 'MA_UTF8_READ_INVALID' }
    if ($SchemaSha256 -and (Get-MaSha256 $schemaBytes) -cne $SchemaSha256) { throw 'MA_PACKAGE_HASH_MISMATCH' }
    $schema = Read-MaJsonStrict (ConvertFrom-MaUtf8Bytes $schemaBytes)
    if ($schema -isnot [System.Collections.IDictionary] -or $schema['$schema'] -cne 'http://json-schema.org/draft-07/schema#') { throw 'MA_SCHEMA_UNSUPPORTED' }
    $data = Read-MaJsonStrict (Read-MaUtf8 $configurationPath)
    Assert-MaSchema $data $schema
    if ($data.schemaVersion -cne '1.0') { throw 'MA_SCHEMA_VERSION_UNSUPPORTED' }
    $name = [string]$data.project.name
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]') { throw 'MA_PROJECT_NAME_INVALID' }
    $slug = [string]$data.project.slug
    if ($slug -cnotmatch '\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z' -or $slug.Length -gt 48) { throw 'MA_PROJECT_SLUG_INVALID' }
    Assert-MaRepositoryUrl $data.repository.url
    $parent = Assert-MaSafePath $data.workspace.parentDirectory 'Directory'
    # Padroes aplicados explicitamente, na mesma ordem nos dois PowerShells.
    $branches = [ordered]@{}
    foreach ($role in $script:MaRoles) { $branches[$role] = $script:MaDefaultBranches[$role] }
    if ($data.ContainsKey('branches')) { foreach ($role in $script:MaRoles) { if ($data.branches.ContainsKey($role)) { $branches[$role] = [string]$data.branches[$role] } } }
    $branchIssues = Get-MaBranchSetIssues $branches
    if ($branchIssues.Count -gt 0) { throw $branchIssues[0].Code }
    $directories = [ordered]@{}
    $worktrees = [ordered]@{}
    foreach ($role in $script:MaRoles) {
        $directories[$role] = $slug + $script:MaDirectorySuffixes[$role]
        $destination = [IO.Path]::GetFullPath([IO.Path]::Combine($parent, $directories[$role]))
        if (-not $destination.StartsWith($parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'MA_PATH_CONTAINMENT_FAILED' }
        if (Test-MaPathWithin $configurationPath $destination) { throw 'MA_CONFIG_INSIDE_WORKTREE' }
        $worktrees[$role] = $destination
    }
    return [pscustomobject]@{
        SchemaVersion   = '1.0'
        Name            = $name
        Slug            = $slug
        RepositoryUrl   = [string]$data.repository.url
        ParentDirectory = $parent
        Branches        = $branches
        Directories     = $directories
        Worktrees       = $worktrees
        ConfigPath      = $configurationPath
    }
}

# --- Escape por contexto ---------------------------------------------------------

# Prosa e titulos Markdown: cada pontuacao ASCII recebe barra invertida (CommonMark),
# o que tambem neutraliza HTML e entidades. Espacos nas bordas viram entidade para
# nao formar bloco indentado nem serem descartados.
# Corrige o original do Codex, que emitia '&amp;\&' e '&lt;\<' (continue em switch).
function ConvertTo-MaMarkdownProse {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '[\p{Cc}\p{Zl}\p{Zp}]') { throw 'MA_RENDER_VALUE_UNSAFE' }
    $first = 0; while ($first -lt $Value.Length -and $Value[$first] -eq ' ') { $first++ }
    $last = $Value.Length - 1; while ($last -ge $first -and $Value[$last] -eq ' ') { $last-- }
    $builder = New-Object Text.StringBuilder
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        $code = [int]$character
        if ($code -eq 32 -and ($index -lt $first -or $index -gt $last)) { [void]$builder.Append('&#32;'); continue }
        if (($code -ge 33 -and $code -le 47) -or ($code -ge 58 -and $code -le 64) -or ($code -ge 91 -and $code -le 96) -or ($code -ge 123 -and $code -le 126)) { [void]$builder.Append('\') }
        [void]$builder.Append($character)
    }
    return $builder.ToString()
}

# Identificadores (slug derivado e branches) ja validados; usados em codigo
# Markdown e em literais sh somente se restritos ao alfabeto seguro.
function Assert-MaIdentifierValue {
    param([string]$Value)
    if ($Value -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._/-]*\z') { throw 'MA_RENDER_VALUE_UNSAFE' }
}

# --- Templates e renderizacao ----------------------------------------------------

function Get-MaTemplateMap {
    return @(
        'AGENTS.md', 'CLAUDE.md', 'README.md', '.gitattributes', '.githooks/pre-commit', '.githooks/pre-push',
        'docs/agentes/coordenacao.md', 'docs/agentes/desenvolvimento.md', 'docs/agentes/manutencao.md', 'docs/agentes/revisao.md'
    )
}

function Get-MaGovernedPaths {
    return @((Get-MaTemplateMap) + $script:MaManifestPath)
}

function Get-MaExpectedMode {
    param([string]$RelativePath)
    if ($RelativePath -cin $script:MaHookPaths) { return '100755' }
    return '100644'
}

# Localiza tokens no template confiavel, antes de qualquer insercao, e classifica
# o contexto de cada ocorrencia. Valores inseridos nunca sao reexaminados.
function Get-MaTemplateTokens {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][string]$RelativePath)
    $tokens = New-Object System.Collections.Generic.List[object]
    $isHook = $RelativePath.StartsWith('.githooks/')
    $isMarkdown = $RelativePath.EndsWith('.md')
    $inFence = $false; $inCode = $false; $offset = 0
    foreach ($line in $Text.Split([char]10)) {
        $trimmed = $line.Trim()
        $isFenceLine = $false
        if ($isMarkdown) {
            if ($trimmed.Length -eq 0) { $inCode = $false }
            if ($trimmed.StartsWith('```') -or $trimmed.StartsWith('~~~')) { $inFence = -not $inFence; $isFenceLine = $true }
        }
        $isTable = $isMarkdown -and $trimmed.StartsWith('|')
        $index = 0
        while ($index -lt $line.Length) {
            $character = $line[$index]
            if ($isMarkdown -and -not $inFence -and -not $isFenceLine -and $character -eq [char]96) {
                while ($index -lt $line.Length -and $line[$index] -eq [char]96) { $index++ }
                $inCode = -not $inCode
                continue
            }
            if ($character -eq [char]123 -and $index + 1 -lt $line.Length -and $line[$index + 1] -eq [char]123) {
                $end = $line.IndexOf('}}', $index + 2, [StringComparison]::Ordinal)
                if ($end -lt 0) { throw 'MA_TEMPLATE_TOKEN_MALFORMED' }
                $key = $line.Substring($index + 2, $end - $index - 2)
                if ($key -cnotmatch '\A[A-Z][A-Z_]*\z') { throw 'MA_TEMPLATE_TOKEN_MALFORMED' }
                if ($isFenceLine) { throw 'MA_TEMPLATE_CONTEXT_INVALID' }
                if ($isHook) { $context = 'Sh' }
                elseif (-not $isMarkdown) { $context = 'Text' }
                elseif ($inFence -or $inCode) { if ($isTable) { $context = 'TableCode' } else { $context = 'Code' } }
                else { if ($isTable) { $context = 'TableProse' } else { $context = 'Prose' } }
                $tokens.Add([pscustomobject]@{ Key = $key; Index = $offset + $index; Length = $end + 2 - $index; Context = $context; Line = $line })
                $index = $end + 2
                continue
            }
            if ($character -eq [char]125 -and $index + 1 -lt $line.Length -and $line[$index + 1] -eq [char]125) { throw 'MA_TEMPLATE_TOKEN_MALFORMED' }
            $index++
        }
        $offset += $line.Length + 1
    }
    return , $tokens.ToArray()
}

function Get-MaTokenValue {
    param($Token, [string]$Text, [System.Collections.IDictionary]$Values, [string]$RawName)
    $key = $Token.Key
    if ($key -ceq 'PROJECT_NAME_MD') {
        # Nome como dado de uma linha: paragrafo isolado ou titulo.
        $placeholder = '{{PROJECT_NAME_MD}}'
        if ($Token.Context -cne 'Prose' -or ($Token.Line -cne $placeholder -and $Token.Line -cne ('# ' + $placeholder))) { throw 'MA_TEMPLATE_CONTEXT_INVALID' }
        return (ConvertTo-MaMarkdownProse $RawName)
    }
    if (-not $Values.Contains($key)) { throw 'MA_TEMPLATE_TOKEN_UNKNOWN' }
    $value = [string]$Values[$key]
    Assert-MaIdentifierValue $value
    switch -CaseSensitive ($Token.Context) {
        'Code' { return $value }
        'TableCode' { return $value }
        'Prose' { return (ConvertTo-MaMarkdownProse $value) }
        'TableProse' { return (ConvertTo-MaMarkdownProse $value) }
        'Sh' {
            # Somente a branch de coordenacao, como conteudo de literal sh entre apostrofos.
            if ($key -cne 'BRANCH_COORDINATION') { throw 'MA_TEMPLATE_CONTEXT_INVALID' }
            $before = $Text.Substring(0, $Token.Index)
            $afterIndex = $Token.Index + $Token.Length
            if (-not ($before.EndsWith("'") -or $before.EndsWith("'refs/heads/")) -or $afterIndex -ge $Text.Length -or $Text[$afterIndex] -ne [char]39) { throw 'MA_TEMPLATE_CONTEXT_INVALID' }
            if ($value.Contains("'")) { throw 'MA_RENDER_VALUE_UNSAFE' }
            return $value
        }
        default { throw 'MA_TEMPLATE_CONTEXT_INVALID' }
    }
}

function ConvertTo-MaRenderedText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][string]$RelativePath, [Parameter(Mandatory = $true)]$Configuration)
    if ($Text.IndexOf('template-dev-multiagente', [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'MA_TEMPLATE_ORIGIN_IDENTIFIER' }
    $values = @{
        WORKTREE_COORDINATION = $Configuration.Directories.coordination
        WORKTREE_CODEX        = $Configuration.Directories.codex
        WORKTREE_CLAUDE       = $Configuration.Directories.claude
        WORKTREE_MAINTENANCE  = $Configuration.Directories.maintenance
        BRANCH_COORDINATION   = $Configuration.Branches.coordination
        BRANCH_CODEX          = $Configuration.Branches.codex
        BRANCH_CLAUDE         = $Configuration.Branches.claude
        BRANCH_MAINTENANCE    = $Configuration.Branches.maintenance
    }
    $tokens = Get-MaTemplateTokens -Text $Text -RelativePath $RelativePath
    $builder = New-Object Text.StringBuilder
    $position = 0
    foreach ($token in $tokens) {
        [void]$builder.Append($Text.Substring($position, $token.Index - $position))
        [void]$builder.Append((Get-MaTokenValue -Token $token -Text $Text -Values $values -RawName $Configuration.Name))
        $position = $token.Index + $token.Length
    }
    [void]$builder.Append($Text.Substring($position))
    return $builder.ToString()
}

# VerifiedHashes: caminho do pacote -> SHA-256 conferido por Test-MaPackageIntegrity.
# Quando informado, cada template e renderizado somente se os bytes lidos aqui
# corresponderem ao hash conferido; uma troca posterior a verificacao e recusada.
function Get-MaRenderedFiles {
    param([Parameter(Mandatory = $true)][string]$PackageRoot, [Parameter(Mandatory = $true)]$Configuration, [Parameter(Mandatory = $true)][string]$DistributionVersion, [System.Collections.IDictionary]$VerifiedHashes = $null)
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($relative in (Get-MaTemplateMap)) {
        $source = Assert-MaSafePath ([IO.Path]::Combine($PackageRoot, 'templates', ($relative + '.tmpl').Replace('/', '\'))) 'File'
        $bytes = [IO.File]::ReadAllBytes($source)
        if ($null -ne $VerifiedHashes) {
            $packagePath = 'templates/' + $relative + '.tmpl'
            if (-not $VerifiedHashes.Contains($packagePath) -or (Get-MaSha256 $bytes) -cne [string]$VerifiedHashes[$packagePath]) { throw 'MA_PACKAGE_HASH_MISMATCH' }
        }
        if ((Test-MaHasUtf8Bom $bytes) -or ([Array]::IndexOf($bytes, [byte]13) -ge 0)) { throw 'MA_TEMPLATE_ENCODING_INVALID' }
        $text = ConvertFrom-MaUtf8Bytes $bytes
        $rendered = $encoding.GetBytes((ConvertTo-MaRenderedText -Text $text -RelativePath $relative -Configuration $Configuration))
        $files.Add([pscustomobject]@{ Path = $relative; Bytes = $rendered; Sha256 = (Get-MaSha256 $rendered); GitMode = (Get-MaExpectedMode $relative) })
    }
    $entries = @($files | ForEach-Object { [ordered]@{ path = $_.Path; sha256 = $_.Sha256; gitMode = $_.GitMode } })
    # Configuracao logica resolvida, sem caminhos absolutos, credenciais ou aprovacao.
    $logical = [ordered]@{
        schemaVersion = '1.0'
        project       = [ordered]@{ name = $Configuration.Name; slug = $Configuration.Slug }
        repository    = [ordered]@{ url = $Configuration.RepositoryUrl }
        branches      = $Configuration.Branches
        directories   = $Configuration.Directories
    }
    $manifest = [ordered]@{ distributionVersion = $DistributionVersion; configuration = $logical; files = $entries }
    $manifestBytes = $encoding.GetBytes((ConvertTo-MaJsonText $manifest) + "`n")
    $files.Add([pscustomobject]@{ Path = $script:MaManifestPath; Bytes = $manifestBytes; Sha256 = (Get-MaSha256 $manifestBytes); GitMode = '100644' })
    return , $files.ToArray()
}

# --- Integridade do pacote (base: Codex) ------------------------------------------

function Get-MaPackageFiles {
    param([string]$Root, [string]$Relative = '')
    $directory = $Root; if ($Relative) { $directory = [IO.Path]::Combine($Root, $Relative.Replace('/', '\')) }
    foreach ($entry in (Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
        $name = $entry.Name
        if (-not $Relative -and $name -ieq '.git') { continue }
        $path = $name; if ($Relative) { $path = $Relative + '/' + $name }
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'MA_PACKAGE_REPARSE_POINT' }
        if ($entry.PSIsContainer) { Get-MaPackageFiles $Root $path } else { $path }
    }
}

function Test-MaPackageIntegrity {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)
    $issues = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    $version = $null
    try {
        $root = Assert-MaSafePath $PackageRoot 'Directory'
        $manifestPath = Assert-MaSafePath ([IO.Path]::Combine($root, 'package.manifest.json')) 'File'
        $manifest = Read-MaJsonStrict (Read-MaUtf8 $manifestPath)
        if ($manifest -isnot [System.Collections.IDictionary] -or $manifest['integrityAlgorithm'] -cne 'SHA-256' -or $manifest['files'] -isnot [array] -or
            $manifest['distributionVersion'] -isnot [string] -or $manifest['distributionVersion'] -cnotmatch '\A[0-9A-Za-z][0-9A-Za-z.+-]*\z' -or
            $manifest['specificationVersion'] -cne $script:MaExpectedSpecificationVersion -or @($manifest['compatibleSchemaVersions']) -cnotcontains '1.0') { throw 'MA_PACKAGE_MANIFEST_INVALID' }
        $version = $manifest['distributionVersion']
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $manifest['files']) {
            if ($entry -isnot [System.Collections.IDictionary] -or $entry['path'] -isnot [string] -or $entry['path'] -cnotmatch '\A(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\z' -or
                $entry['path'] -match '(?:\A|/)\.{1,2}(?:/|\z)' -or $entry['path'] -imatch '\A(?:\.git(?:/|\z)|package\.manifest\.json\z)' -or
                $entry['sha256'] -isnot [string] -or $entry['sha256'] -cnotmatch '\A[0-9a-f]{64}\z' -or -not $seen.Add($entry['path'])) { throw 'MA_PACKAGE_ENTRY_INVALID' }
            $relative = [string]$entry['path']
            $mode = '100644'; if ($relative -cin @('.githooks/pre-commit', '.githooks/pre-push')) { $mode = '100755' }
            $actualHash = $null; $valid = $true
            try {
                $path = Assert-MaSafePath ([IO.Path]::Combine($root, $relative.Replace('/', '\'))) 'File'
                $bytes = [IO.File]::ReadAllBytes($path)
                $actualHash = Get-MaSha256 $bytes
                if ($entry['gitMode'] -cne $mode) { $issues.Add((New-MaIssue 'MA_PACKAGE_MODE_INVALID' -Path $relative)); $valid = $false }
                if ($actualHash -cne $entry['sha256']) { $issues.Add((New-MaIssue 'MA_PACKAGE_HASH_MISMATCH' -Path $relative)); $valid = $false }
                $text = ConvertFrom-MaUtf8Bytes $bytes
                $isPowerShell = $relative -match '\.(?:ps1|psm1)\z'
                $hasBom = Test-MaHasUtf8Bom $bytes
                $hasNonAscii = $text -match '[^\u0000-\u007f]'
                if ([Array]::IndexOf($bytes, [byte]13) -ge 0 -or (-not $isPowerShell -and $hasBom) -or ($isPowerShell -and $hasNonAscii -and -not $hasBom)) { $issues.Add((New-MaIssue 'MA_PACKAGE_ENCODING_INVALID' -Path $relative)); $valid = $false }
            } catch { $issues.Add((New-MaIssue 'MA_PACKAGE_FILE_UNREADABLE' -Path $relative -Detail (Get-MaErrorCode $_ ''))); $valid = $false }
            $files.Add([pscustomobject]@{ Path = $relative; ExpectedHash = $entry['sha256']; ActualHash = $actualHash; GitMode = $mode; Valid = $valid })
        }
        $required = @('schema/project.schema.json', 'AGENTS.md', 'CLAUDE.md', '.gitattributes', '.githooks/pre-commit', '.githooks/pre-push', 'docs/especificacao-v1.md', 'docs/errata-especificacao-v1.1.md', 'scripts/Install-MultiAgentProject.ps1', 'scripts/MultiAgentTemplate.psm1')
        foreach ($relative in (Get-MaTemplateMap)) { $required += 'templates/' + $relative + '.tmpl' }
        foreach ($role in @('coordenacao', 'desenvolvimento', 'manutencao', 'revisao')) { $required += 'docs/agentes/' + $role + '.md' }
        foreach ($path in $required) { if (-not $seen.Contains($path)) { $issues.Add((New-MaIssue 'MA_PACKAGE_REQUIRED_NOT_INVENTORIED' -Path $path)) } }
        foreach ($path in @(Get-MaPackageFiles $root)) { if ($path -cne 'package.manifest.json' -and -not $seen.Contains($path)) { $issues.Add((New-MaIssue 'MA_PACKAGE_FILE_NOT_INVENTORIED' -Path $path)) } }
    } catch {
        $issues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PACKAGE_INSPECTION_FAILED')))
    }
    return [pscustomobject]@{ Valid = ($issues.Count -eq 0); Files = $files.ToArray(); Issues = $issues.ToArray(); DistributionVersion = $version }
}

# --- Processos nativos e Git -----------------------------------------------------

# Argumento nativo do Windows (regras de CommandLineToArgvW/MSVCRT). Contrato
# distinto dos escapes Markdown, PowerShell e sh; nenhum shell e envolvido.
function ConvertTo-MaNativeArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $backslashes++; continue }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (2 * $backslashes + 1)); [void]$builder.Append([char]34); $backslashes = 0; continue
        }
        if ($backslashes -gt 0) { [void]$builder.Append([char]92, $backslashes); $backslashes = 0 }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append([char]92, (2 * $backslashes)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

# --- Executor seguro de processos nativos -----------------------------------------
# Integrado da prova de conceito das Etapas 92, 96 e 98. Cada chamada:
#   1. Cria um job novo, sem nome e com handle nao herdavel, com
#      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE como unico limite. O limite, a ausencia
#      de BREAKAWAY_OK/SILENT_BREAKAWAY_OK e a nao herdabilidade do handle sao
#      conferidos por consulta antes de qualquer criacao; sem isso, nenhum
#      processo e criado (MA_NATIVE_CONTAINMENT_UNAVAILABLE).
#   2. Cria tres pipes anonimos; somente as extremidades do filho sao herdaveis.
#   3. Chama CreateProcessW com CREATE_SUSPENDED, caminho absoluto do executavel
#      (sem busca no PATH), linha de comando em buffer gravavel, ambiente explicito
#      e lista de atributos com PROC_THREAD_ATTRIBUTE_JOB_LIST (o processo nasce
#      dentro do job) e PROC_THREAD_ATTRIBUTE_HANDLE_LIST (herda so os tres pipes).
#   4. Confere a associacao antes da retomada: IsProcessInJob verdadeiro e a lista
#      de PIDs do job contendo exatamente o PID criado. Sem confirmacao, o processo
#      suspenso, que nao executou nenhuma instrucao do programa e portanto nao
#      criou descendentes, e encerrado, o termino e conferido pelo sinal do handle
#      e a chamada e recusada (MA_NATIVE_CONTAINMENT_FAILED).
#   5. Retoma a thread inicial (contagem anterior 1) e segue com escrita do stdin,
#      espera, drenagem de stdout/stderr e job vazio, todos com prazo.
#   6. Qualquer falha posterior a criacao do job, antes ou depois da retomada,
#      encerra o job inteiro e confere o termino: contagem do job em zero e sinal
#      de cada membro conhecido. Sem confirmacao, MA_NATIVE_TERMINATION_UNCONFIRMED
#      com Data['Stage'], Data['Win32Error'] e a falha original em Data['Cause'].
#   7. O finally libera streams e handles, cada handle uma unica vez, e fecha o
#      job. Com KILL_ON_JOB_CLOSE, fechar o ultimo handle encerra qualquer membro
#      restante, inclusive na morte abrupta do host; e a garantia final, mas nao
#      gera confirmacao. Nenhuma falha de limpeza e descartada: com falha
#      principal, ela prevalece e as de limpeza ficam em Data['CleanupFailures'];
#      sem falha principal, a chamada falha com MA_NATIVE_CLEANUP_FAILED.
# As APIs do kernel32 sao declaradas por System.Reflection.Emit, somente em
# memoria: sem Add-Type (que no 5.1 chama csc.exe e grava temporarios) e sem
# binario distribuido. Cada funcao publica e um wrapper IL que grava o ultimo erro
# Win32 num campo [ThreadStatic]; Marshal.GetLastWin32Error lido pelo script nao e
# confiavel, pois o proprio PowerShell faz P/Invokes entre as instrucoes.
# Comprovado somente no Windows PowerShell 5.1 x64 e x86, no Windows 11.
# PowerShell 7, Windows 10 e Windows Server 2016 nao foram testados.
# PROC_THREAD_ATTRIBUTE_JOB_LIST exige Windows 10 / Server 2016 ou superior.
#
# Limitacoes conhecidas:
#   - Job Object nao e sandbox: processos criados por outro processo a pedido do
#     contido (WMI, Agendador de Tarefas, servicos, COM fora do processo) nao
#     herdam o job. A contencao cobre a arvore de criacao direta, caso do Git.
#   - ActiveProcesses zera alguns milissegundos antes do sinal do processo. Um
#     membro criado entre a enumeracao e o TerminateJobObject, ou nao aberto por
#     falha da enumeracao, e confirmado somente pela contagem do job.
#   - Se o CloseHandle do job falhar, a falha e relatada e o handle segue aberto ate
#     o fim do host; so entao ocorre a garantia de KILL_ON_JOB_CLOSE.
#   - A falha do CloseHandle interno de um FileStream nao e observavel (SafeHandle).
#   - Interrupcao do pipeline (Ctrl+C) pode pular o catch; resta o fechamento do
#     job no finally, sem confirmacao (caminho nao testado).
#   - As extremidades do filho sao herdaveis entre CreatePipe e seu fechamento;
#     outra thread do mesmo processo que crie processos sem HANDLE_LIST poderia
#     herda-las. O executor e sequencial.
#   - Se o encerramento do suspenso nao for confirmado, o erro conservador
#     permanece mesmo que o encerramento do job confirme depois.

$script:MaNativeConstants = @{
    CreateSuspended            = [uint32]0x00000004
    CreateUnicodeEnvironment   = [uint32]0x00000400
    ExtendedStartupInfoPresent = [uint32]0x00080000
    CreateNoWindow             = [uint32]0x08000000
    StartfUseStdHandles        = 0x00000100
    AttributeHandleList        = 0x00020002
    AttributeJobList           = 0x0002000D
    HandleFlagInherit          = [uint32]1
    WaitObject0                = [uint32]0
    WaitTimeout                = [uint32]0x102
    ErrorMoreData              = 234
    JobBasicAccounting         = 1
    JobBasicProcessIdList      = 3
    JobExtendedLimit           = 9
    LimitBreakawayOk           = 0x00000800
    LimitSilentBreakawayOk     = 0x00001000
    LimitKillOnJobClose        = 0x00002000
    MaxCommandLine             = 32766
}

# Excecao com o codigo como mensagem (lida por Get-MaErrorCode) e dados auxiliares.
function New-MaNativeError {
    param([string]$Code, [int]$Win32Error = 0, [string]$Stage = '')
    $exception = New-Object System.Exception $Code
    $exception.Data['Win32Error'] = $Win32Error
    if ($Stage) { $exception.Data['Stage'] = $Stage }
    return $exception
}

# Encerramento nao confirmado. Stage: TerminateProcess, ProcessWait, NoHandle,
# TerminateJobObject, JobQuery, JobActive ou Unexpected. Cause: codigo da falha
# original. Code permite o codigo proprio da associacao nao confirmada.
function New-MaNativeTerminationError {
    param([string]$Stage, [int]$Win32Error = 0, [System.Exception]$Cause = $null, [long]$ProcessId = 0, [string]$Code = 'MA_NATIVE_TERMINATION_UNCONFIRMED')
    $exception = New-MaNativeError $Code $Win32Error $Stage
    $exception.Data['Cause'] = $(if ($null -ne $Cause) { $Cause.Message } else { $null })
    $exception.Data['ProcessId'] = $ProcessId
    return $exception
}

function Get-MaNativeWin32Error {
    param([System.Exception]$Exception)
    if ($Exception.Data.Contains('Win32Error')) { return [int]$Exception.Data['Win32Error'] }
    return 0
}

# $true se o teste registrou falha simulada no ponto; propaga a excecao da acao.
function Test-MaNativeFault {
    param([string]$Point, $Context = $null)
    if (-not $script:MaNativeFaults.ContainsKey($Point)) { return $false }
    return [bool](& $script:MaNativeFaults[$Point] $Context)
}

# P/Invoke emitido com DllImportAttribute (SetLastError, Unicode, nome exato).
# Cada funcao publica e um wrapper IL que chama o P/Invoke privado e grava
# Marshal.GetLastWin32Error() no campo [ThreadStatic] LastError antes de retornar.
# Cada definicao: nome, retorno, parametros e, opcionalmente, a DLL (padrao
# kernel32.dll). Lanca se a emissao falhar.
function New-MaEmittedApi {
    param([Parameter(Mandatory = $true)][string]$AssemblyName, [Parameter(Mandatory = $true)][string]$TypeName, [Parameter(Mandatory = $true)][object[]]$Definitions)
    $assembly = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly((New-Object System.Reflection.AssemblyName $AssemblyName), [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    $type = $assembly.DefineDynamicModule($AssemblyName).DefineType($TypeName, [System.Reflection.TypeAttributes]'Public, Abstract, Sealed')
    $dllImport = [System.Runtime.InteropServices.DllImportAttribute]
    $constructor = $dllImport.GetConstructor([Type[]]@([string]))
    $fields = [System.Reflection.FieldInfo[]]@($dllImport.GetField('SetLastError'), $dllImport.GetField('CharSet'), $dllImport.GetField('CallingConvention'), $dllImport.GetField('EntryPoint'), $dllImport.GetField('ExactSpelling'))
    $lastError = $type.DefineField('LastError', [int], [System.Reflection.FieldAttributes]'Public, Static')
    $lastError.SetCustomAttribute((New-Object System.Reflection.Emit.CustomAttributeBuilder([ThreadStaticAttribute].GetConstructor([Type]::EmptyTypes), [object[]]@())))
    $getLastError = [System.Runtime.InteropServices.Marshal].GetMethod('GetLastWin32Error')
    $opCodes = [System.Reflection.Emit.OpCodes]
    foreach ($definition in $Definitions) {
        $library = 'kernel32.dll'; if ($definition.Count -gt 3) { $library = [string]$definition[3] }
        $parameters = [Type[]]@($definition[2])
        $native = $type.DefineMethod('Native' + $definition[0], [System.Reflection.MethodAttributes]'Private, Static, PinvokeImpl, HideBySig', $definition[1], $parameters)
        $values = [object[]]@($true, [System.Runtime.InteropServices.CharSet]::Unicode, [System.Runtime.InteropServices.CallingConvention]::Winapi, $definition[0], $true)
        $native.SetCustomAttribute((New-Object System.Reflection.Emit.CustomAttributeBuilder($constructor, [object[]]@($library), $fields, $values)))
        $wrapper = $type.DefineMethod($definition[0], [System.Reflection.MethodAttributes]'Public, Static, HideBySig', $definition[1], $parameters)
        $il = $wrapper.GetILGenerator()
        for ($index = 0; $index -lt $parameters.Length; $index++) { $il.Emit($opCodes::Ldarg, [int16]$index) }
        $il.Emit($opCodes::Call, $native)
        $il.Emit($opCodes::Call, $getLastError)
        $il.Emit($opCodes::Stsfld, $lastError)
        $il.Emit($opCodes::Ret)
    }
    return $type.CreateType()
}

# Falha na emissao fica registrada ($false) e recusa toda chamada posterior.
function Get-MaNativeApi {
    if ($script:MaNativeApi -is [bool]) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' 0 'Api') }
    if ($null -ne $script:MaNativeApi) { return $script:MaNativeApi }
    $p = [IntPtr]; $u = [uint32]; $b = [bool]
    $definitions = @(
        @('CreateJobObjectW', $p, @($p, $p)),
        @('IsProcessInJob', $b, @($p, $p, $p)),
        @('QueryInformationJobObject', $b, @($p, [int], $p, $u, $p)),
        @('SetInformationJobObject', $b, @($p, [int], $p, $u)),
        @('TerminateJobObject', $b, @($p, $u)),
        @('InitializeProcThreadAttributeList', $b, @($p, [int], [int], $p)),
        @('UpdateProcThreadAttribute', $b, @($p, $u, $p, $p, $p, $p, $p)),
        @('DeleteProcThreadAttributeList', [void], @($p)),
        @('CreateProcessW', $b, @([string], $p, $p, $p, $b, $u, $p, [string], $p, $p)),
        @('ResumeThread', $u, @($p)),
        @('SuspendThread', $u, @($p)),
        @('TerminateProcess', $b, @($p, $u)),
        @('WaitForSingleObject', $u, @($p, $u)),
        @('GetExitCodeProcess', $b, @($p, $p)),
        @('CreatePipe', $b, @($p, $p, $p, $u)),
        @('SetHandleInformation', $b, @($p, $u, $u)),
        @('GetHandleInformation', $b, @($p, $p)),
        @('OpenProcess', $p, @($u, $b, $u)),
        @('CloseHandle', $b, @($p))
    )
    try { $script:MaNativeApi = New-MaEmittedApi 'MaNativeProcess' 'MaNativeProcess.Kernel32' $definitions }
    catch {
        $script:MaNativeApi = $false
        throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' 0 'Api')
    }
    return $script:MaNativeApi
}

# Ultimo erro Win32 capturado pelo wrapper da chamada nativa mais recente nesta thread.
function Get-MaNativeLastError { return (Get-MaNativeApi)::LastError }

# Fecha o handle uma unica vez e nunca lanca: devolve $null ou o descritor
# 'Nome:MA_NATIVE_CLOSE_FAILED:Win32'. Quem chama zera o campo antes, mesmo que
# falhe: repetir CloseHandle nao resolve (handle invalido ou protegido continua
# assim) e o valor ja invalido pode ter sido reutilizado por outro handle do
# processo, que seria fechado por engano.
function Close-MaNativeHandle {
    param([IntPtr]$Handle, [string]$Name)
    if ($Handle -eq [IntPtr]::Zero) { return $null }
    try {
        $code = 0
        if (Test-MaNativeFault 'CloseHandle' ([pscustomobject]@{ Name = $Name; Handle = $Handle })) { $closed = $false }
        else { $closed = [bool](Get-MaNativeApi)::CloseHandle($Handle); $code = Get-MaNativeLastError }
        if ($closed) { return $null }
        return ($Name + ':MA_NATIVE_CLOSE_FAILED:' + $code)
    } catch { return ($Name + ':' + $_.Exception.Message + ':' + (Get-MaNativeWin32Error $_.Exception)) }
}

# Registra falhas secundarias de limpeza na excecao principal sem substitui-la.
function Add-MaNativeCleanupFailure {
    param([System.Exception]$Exception, $Failures)
    $items = @($Failures | Where-Object { $null -ne $_ })
    if ($null -eq $Exception -or $items.Count -eq 0) { return }
    $existing = @()
    if ($Exception.Data.Contains('CleanupFailures')) { $existing = @($Exception.Data['CleanupFailures']) }
    $Exception.Data['CleanupFailures'] = [string[]]($existing + $items)
}

# Falha de limpeza sem falha principal (ou com encerramento ja confirmado):
# MA_NATIVE_CLEANUP_FAILED, com os descritores e o Win32 do primeiro.
function New-MaNativeCleanupError {
    param([string[]]$Failures, [System.Exception]$Cause = $null)
    $code = 0
    if ($Failures.Count -gt 0) { [void][int]::TryParse(($Failures[0] -split ':')[-1], [ref]$code) }
    $exception = New-MaNativeError 'MA_NATIVE_CLEANUP_FAILED' $code
    $exception.Data['Cause'] = $(if ($null -ne $Cause) { $Cause.Message } else { $null })
    Add-MaNativeCleanupFailure $exception $Failures
    return $exception
}

# Descritores de uma falha de limpeza capturada: os registrados nela ou, para
# excecao inesperada, um descritor com Name e a mensagem.
function Get-MaNativeCleanupFailures {
    param([System.Exception]$Exception, [string]$Name)
    if ($Exception.Message -ceq 'MA_NATIVE_CLEANUP_FAILED' -and $Exception.Data.Contains('CleanupFailures')) { return [string[]]$Exception.Data['CleanupFailures'] }
    return [string[]]@($Name + ':' + $Exception.Message + ':' + (Get-MaNativeWin32Error $Exception))
}

# Deslocamentos de STARTUPINFOEXW, PROCESS_INFORMATION, SECURITY_ATTRIBUTES e
# JOBOBJECT_EXTENDED_LIMIT_INFORMATION calculados pelo tamanho do ponteiro
# (x64: 112/24/24/144 bytes; x86: 72/16/12/112). No limite estendido, a parte
# basica ocupa 4 ponteiros + 32 bytes, seguida de IO_COUNTERS (48) e 4 SIZE_T;
# LimitFlags fica no byte 16 nas duas arquiteturas.
function Get-MaNativeLayout {
    $pointer = [IntPtr]::Size
    $reserved2 = 4 * $pointer + 36
    if (($reserved2 % $pointer) -ne 0) { $reserved2 += $pointer - ($reserved2 % $pointer) }
    $stdInput = $reserved2 + $pointer
    $startupSize = $stdInput + 3 * $pointer
    return [pscustomobject]@{
        Pointer           = $pointer
        Flags             = 4 * $pointer + 28
        StdInput          = $stdInput
        StdOutput         = $stdInput + $pointer
        StdError          = $stdInput + 2 * $pointer
        StartupInfoSize   = $startupSize
        AttributeList     = $startupSize
        StartupInfoExSize = $startupSize + $pointer
        ProcessInfoSize   = 2 * $pointer + 8
        SecuritySize      = 3 * $pointer
        JobLimitSize      = (4 * $pointer + 32) + 48 + 4 * $pointer
        JobLimitFlags     = 16
    }
}

function New-MaNativeZeroMemory {
    param([int]$Size)
    $memory = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($Size)
    for ($offset = 0; $offset -lt $Size; $offset++) { [System.Runtime.InteropServices.Marshal]::WriteByte($memory, $offset, 0) }
    return $memory
}

# Bloco de ambiente Unicode: ambiente atual com substituicoes; valor $null remove.
# Ordenado sem diferenciar maiusculas, terminado por dois NUL.
function New-MaNativeEnvironmentBlock {
    param([hashtable]$Overrides = @{})
    $map = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $current = [Environment]::GetEnvironmentVariables()
    foreach ($key in $current.Keys) { $map[[string]$key] = [string]$current[$key] }
    foreach ($key in $Overrides.Keys) {
        $name = [string]$key
        if ($name.Length -eq 0 -or $name.IndexOf([char]'=') -ge 0 -or $name.IndexOf([char]0) -ge 0) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' 0 'Environment') }
        if ($null -eq $Overrides[$key]) { [void]$map.Remove($name); continue }
        $value = [string]$Overrides[$key]
        if ($value.IndexOf([char]0) -ge 0) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' 0 'Environment') }
        $map[$name] = $value
    }
    $builder = New-Object Text.StringBuilder
    foreach ($entry in $map.GetEnumerator()) { [void]$builder.Append($entry.Key).Append('=').Append($entry.Value).Append([char]0) }
    if ($map.Count -eq 0) { [void]$builder.Append([char]0) }
    # StringToHGlobalUni acrescenta o NUL final do bloco.
    return [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($builder.ToString())
}

# Pipe anonimo: a extremidade do filho e herdavel; a do pai nao.
function New-MaNativePipe {
    param([bool]$ChildReads)
    $api = Get-MaNativeApi
    $layout = Get-MaNativeLayout
    $security = New-MaNativeZeroMemory $layout.SecuritySize
    $handles = New-MaNativeZeroMemory (2 * $layout.Pointer)
    try {
        [System.Runtime.InteropServices.Marshal]::WriteInt32($security, 0, $layout.SecuritySize)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($security, 2 * $layout.Pointer, 1)
        if (-not $api::CreatePipe($handles, [IntPtr]::Add($handles, $layout.Pointer), $security, [uint32]0)) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' (Get-MaNativeLastError) 'Pipe') }
        $read = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($handles, 0)
        $write = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($handles, $layout.Pointer)
        if ($ChildReads) { $parent = $write; $child = $read } else { $parent = $read; $child = $write }
        if (-not $api::SetHandleInformation($parent, $script:MaNativeConstants.HandleFlagInherit, [uint32]0)) {
            $failure = New-MaNativeError 'MA_GIT_EXECUTION_FAILED' (Get-MaNativeLastError) 'Pipe'
            Add-MaNativeCleanupFailure $failure @((Close-MaNativeHandle $read 'PipeRead'), (Close-MaNativeHandle $write 'PipeWrite'))
            throw $failure
        }
        return [pscustomobject]@{ Parent = $parent; Child = $child }
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($security)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($handles)
    }
}

# LimitFlags de JOBOBJECT_EXTENDED_LIMIT_INFORMATION; $null se a consulta falhar.
function Get-MaNativeJobLimitFlags {
    param([IntPtr]$Job)
    if (Test-MaNativeFault 'JobLimitQuery' $Job) { return $null }
    $layout = Get-MaNativeLayout
    $info = New-MaNativeZeroMemory $layout.JobLimitSize
    try {
        if (-not (Get-MaNativeApi)::QueryInformationJobObject($Job, $script:MaNativeConstants.JobExtendedLimit, $info, [uint32]$layout.JobLimitSize, [IntPtr]::Zero)) { return $null }
        return [System.Runtime.InteropServices.Marshal]::ReadInt32($info, $layout.JobLimitFlags)
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info) }
}

# Conferido antes de qualquer criacao: KILL_ON_JOB_CLOSE ativo, nenhum limite de
# breakaway e handle do job nao herdavel. Lanca se algo nao puder ser confirmado.
function Assert-MaNativeJobSafety {
    param([IntPtr]$Job)
    $c = $script:MaNativeConstants
    $flags = Get-MaNativeJobLimitFlags $Job
    if ($null -eq $flags) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' (Get-MaNativeLastError) 'JobLimit') }
    if (($flags -band $c.LimitKillOnJobClose) -eq 0 -or ($flags -band ($c.LimitBreakawayOk -bor $c.LimitSilentBreakawayOk)) -ne 0) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' 0 'JobLimit') }
    $cell = New-MaNativeZeroMemory 4
    try {
        if (-not (Get-MaNativeApi)::GetHandleInformation($Job, $cell)) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' (Get-MaNativeLastError) 'JobInheritable') }
        if (([System.Runtime.InteropServices.Marshal]::ReadInt32($cell, 0) -band $c.HandleFlagInherit) -ne 0) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' 0 'JobInheritable') }
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($cell) }
}

# Cria um job sem nome, com handle nao herdavel (sem SECURITY_ATTRIBUTES) e com
# JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE como unico limite, conferido por consulta.
# Qualquer falha fecha o job e lanca antes de qualquer processo existir.
function New-MaNativeJob {
    $api = Get-MaNativeApi
    $job = [IntPtr]::Zero
    try { $job = [IntPtr]($api::CreateJobObjectW([IntPtr]::Zero, [IntPtr]::Zero)) } catch { $job = [IntPtr]::Zero }
    if ($job -eq [IntPtr]::Zero) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' (Get-MaNativeLastError) 'JobCreate') }
    $layout = Get-MaNativeLayout
    $info = New-MaNativeZeroMemory $layout.JobLimitSize
    try {
        [System.Runtime.InteropServices.Marshal]::WriteInt32($info, $layout.JobLimitFlags, $script:MaNativeConstants.LimitKillOnJobClose)
        $code = 0
        if (Test-MaNativeFault 'JobLimitSet' $job) { $set = $false }
        else {
            $set = [bool]$api::SetInformationJobObject($job, $script:MaNativeConstants.JobExtendedLimit, $info, [uint32]$layout.JobLimitSize)
            $code = Get-MaNativeLastError
        }
        if (-not $set) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' $code 'JobLimit') }
        Assert-MaNativeJobSafety $job
    } catch {
        Add-MaNativeCleanupFailure $_.Exception @(Close-MaNativeHandle $job 'Job')
        throw
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info) }
    return $job
}

# $true/$false conforme IsProcessInJob; $null se a consulta falhar.
function Test-MaNativeProcessInJob {
    param([IntPtr]$ProcessHandle, [IntPtr]$Job)
    $cell = New-MaNativeZeroMemory 4
    try {
        if (-not (Get-MaNativeApi)::IsProcessInJob($ProcessHandle, $Job, $cell)) { return $null }
        return ([System.Runtime.InteropServices.Marshal]::ReadInt32($cell, 0) -ne 0)
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($cell) }
}

# JOBOBJECT_BASIC_ACCOUNTING_INFORMATION (48 bytes, sem ponteiros, identica em x86
# e x64): Total em 36, Active em 40, Terminated em 44. $null se a consulta falhar.
function Get-MaNativeJobAccounting {
    param([IntPtr]$Job)
    if (Test-MaNativeFault 'JobAccounting' $Job) { return $null }
    $size = 48
    $info = New-MaNativeZeroMemory $size
    try {
        if (-not (Get-MaNativeApi)::QueryInformationJobObject($Job, $script:MaNativeConstants.JobBasicAccounting, $info, [uint32]$size, [IntPtr]::Zero)) { return $null }
        return [pscustomobject]@{
            Total      = [System.Runtime.InteropServices.Marshal]::ReadInt32($info, 36)
            Active     = [System.Runtime.InteropServices.Marshal]::ReadInt32($info, 40)
            Terminated = [System.Runtime.InteropServices.Marshal]::ReadInt32($info, 44)
        }
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info) }
}

# JOBOBJECT_BASIC_PROCESS_ID_LIST: dois DWORD e ULONG_PTR[] a partir do byte 8.
# Retorna objeto com Ids (processos ativos no job) ou $null se a consulta falhar.
function Get-MaNativeJobProcessIds {
    param([IntPtr]$Job)
    $pointer = [IntPtr]::Size
    $capacity = 16
    while ($capacity -le 65536) {
        $size = 8 + $capacity * $pointer
        $info = New-MaNativeZeroMemory $size
        try {
            $ok = (Get-MaNativeApi)::QueryInformationJobObject($Job, $script:MaNativeConstants.JobBasicProcessIdList, $info, [uint32]$size, [IntPtr]::Zero)
            $code = Get-MaNativeLastError
            $assigned = [System.Runtime.InteropServices.Marshal]::ReadInt32($info, 0)
            $listed = [System.Runtime.InteropServices.Marshal]::ReadInt32($info, 4)
            if ($ok -and $assigned -eq $listed) {
                $ids = New-Object System.Collections.Generic.List[long]
                for ($index = 0; $index -lt $listed; $index++) { $ids.Add([System.Runtime.InteropServices.Marshal]::ReadIntPtr($info, 8 + $index * $pointer).ToInt64()) }
                return [pscustomobject]@{ Ids = $ids.ToArray() }
            }
            if (-not $ok -and $code -ne $script:MaNativeConstants.ErrorMoreData) { return $null }
            $capacity = [Math]::Max(2 * $capacity, $assigned + 8)
        } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info) }
    }
    return $null
}

# Associacao confirmada somente se IsProcessInJob for verdadeiro e o job novo
# contiver exatamente o PID criado. Um job reaproveitado nao e aceito.
function Get-MaNativeAssociationEvidence {
    param([IntPtr]$Job, [IntPtr]$ProcessHandle, [long]$ProcessId)
    $inJob = Test-MaNativeProcessInJob $ProcessHandle $Job
    $list = Get-MaNativeJobProcessIds $Job
    $ids = @(); if ($null -ne $list) { $ids = @($list.Ids) }
    $confirmed = ($inJob -eq $true) -and ($null -ne $list) -and ($ids.Count -eq 1) -and ($ids[0] -eq $ProcessId)
    return [pscustomobject]@{ Confirmed = $confirmed; InJob = $inJob; JobProcessIds = $ids }
}

# Status: Empty (zero processos ativos), Active (prazo esgotado) ou QueryFailed
# (consulta recusada: nao ha como afirmar que o job esvaziou).
function Wait-MaNativeJobEmpty {
    param([IntPtr]$Job, [int]$TimeoutMilliseconds)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $accounting = Get-MaNativeJobAccounting $Job
        if ($null -eq $accounting) { return [pscustomobject]@{ Status = 'QueryFailed'; Win32Error = (Get-MaNativeLastError) } }
        if ($accounting.Active -eq 0) { return [pscustomobject]@{ Status = 'Empty'; Win32Error = 0 } }
        if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) { return [pscustomobject]@{ Status = 'Active'; Win32Error = 0 } }
        Start-Sleep -Milliseconds 20
    }
}

# Acrescenta a $Handles (lista do chamador, que fecha o que ja estiver nela mesmo
# se esta funcao lancar) handles de sincronizacao dos membros atuais do job. O
# PID so e aceito se o processo aberto pertencer ao job (protege contra reuso de
# PID); membro que ja saiu e ignorado. Lanca MA_NATIVE_JOB_QUERY_FAILED se a
# enumeracao falhar; falhas ao fechar handles descartados vao para $Failures.
function Open-MaNativeJobMembers {
    param([IntPtr]$Job, [System.Collections.Generic.List[IntPtr]]$Handles, [System.Collections.Generic.List[string]]$Failures)
    $api = Get-MaNativeApi
    $list = $null
    if (-not (Test-MaNativeFault 'JobMembers' $Job)) { $list = Get-MaNativeJobProcessIds $Job }
    if ($null -eq $list) { throw (New-MaNativeError 'MA_NATIVE_JOB_QUERY_FAILED' (Get-MaNativeLastError)) }
    foreach ($id in $list.Ids) {
        # SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION
        $handle = [IntPtr]$api::OpenProcess([uint32](0x00100000 -bor 0x1000), $false, [uint32]$id)
        if ($handle -eq [IntPtr]::Zero) { continue }
        $inJob = $null
        try { $inJob = Test-MaNativeProcessInJob $handle $Job }
        finally {
            if ($inJob -eq $true) { $Handles.Add($handle) }
            else { $closeFailure = Close-MaNativeHandle $handle 'NonMember'; if ($null -ne $closeFailure) { $Failures.Add($closeFailure) } }
        }
        [void](Test-MaNativeFault 'JobMemberOpened' $Handles)
    }
}

# Encerra todos os processos do job, suspensos ou nao, e confirma no prazo: zero
# processos ativos na contagem do job e, para cada membro conhecido antes do
# encerramento, o sinal do processo. Sem confirmacao, lanca
# MA_NATIVE_TERMINATION_UNCONFIRMED com a etapa, o erro Win32 e a falha original.
# A enumeracao dos membros so serve a confirmacao: se falhar, inclusive por
# excecao inesperada, TerminateJobObject ainda e tentado. Encerramento confirmado
# com falha operacional (enumeracao ou fechamento de handles) lanca
# MA_NATIVE_CLEANUP_FAILED; nao confirmado, os mesmos descritores vao em
# Data['CleanupFailures'].
function Stop-MaNativeJob {
    param([IntPtr]$Job, [int]$TimeoutMilliseconds = $script:MaTerminationConfirmMilliseconds, [System.Exception]$Cause = $null)
    $api = Get-MaNativeApi
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $members = New-Object System.Collections.Generic.List[IntPtr]
    $failures = New-Object System.Collections.Generic.List[string]
    $unconfirmed = $null
    try {
        try { Open-MaNativeJobMembers $Job $members $failures }
        catch { $failures.Add('MemberEnumeration:' + $_.Exception.Message + ':' + (Get-MaNativeWin32Error $_.Exception)) }
        $code = 0
        if (Test-MaNativeFault 'TerminateJobObject' $Job) { $terminated = $false }
        else {
            $terminated = [bool]$api::TerminateJobObject($Job, [uint32]1)
            $code = Get-MaNativeLastError
        }
        if (-not $terminated) { throw (New-MaNativeTerminationError 'TerminateJobObject' $code $Cause) }
        $wait = Wait-MaNativeJobEmpty $Job $TimeoutMilliseconds
        if ($wait.Status -eq 'QueryFailed') { throw (New-MaNativeTerminationError 'JobQuery' $wait.Win32Error $Cause) }
        if ($wait.Status -ne 'Empty') { throw (New-MaNativeTerminationError 'JobActive' 0 $Cause) }
        foreach ($member in $members) {
            $remaining = [uint32][Math]::Max(0, $TimeoutMilliseconds - $clock.ElapsedMilliseconds)
            if ($api::WaitForSingleObject($member, $remaining) -ne $script:MaNativeConstants.WaitObject0) { throw (New-MaNativeTerminationError 'ProcessWait' (Get-MaNativeLastError) $Cause) }
        }
    } catch {
        # Excecao inesperada tambem e encerramento nao confirmado; o detalhe e mantido.
        $unconfirmed = $_.Exception
        if ($unconfirmed.Message -cne 'MA_NATIVE_TERMINATION_UNCONFIRMED') {
            $unconfirmed = New-MaNativeTerminationError 'Unexpected' (Get-MaNativeWin32Error $_.Exception) $Cause
            $unconfirmed.Data['Detail'] = $_.Exception.Message
        }
        throw $unconfirmed
    } finally {
        for ($index = 0; $index -lt $members.Count; $index++) {
            $member = $members[$index]; $members[$index] = [IntPtr]::Zero
            $closeFailure = Close-MaNativeHandle $member 'Member'
            if ($null -ne $closeFailure) { $failures.Add($closeFailure) }
        }
        Add-MaNativeCleanupFailure $unconfirmed $failures
    }
    if ($failures.Count -gt 0) { throw (New-MaNativeCleanupError $failures.ToArray() $Cause) }
}

# Encerra o processo de $State, ainda suspenso, e confirma o termino pelo sinal do
# handle. Usado so antes da retomada: sem ter executado, o processo nao criou
# descendentes. Sem confirmacao, lanca MA_NATIVE_TERMINATION_UNCONFIRMED ou, se a
# causa for a associacao nao confirmada, MA_NATIVE_CONTAINMENT_FAILED_UNTERMINATED.
function Stop-MaNativeSuspendedProcess {
    param($State, [System.Exception]$Cause = $null)
    $api = Get-MaNativeApi
    $c = $script:MaNativeConstants
    $errorCode = 'MA_NATIVE_TERMINATION_UNCONFIRMED'
    if ($null -ne $Cause -and $Cause.Message -ceq 'MA_NATIVE_CONTAINMENT_FAILED') { $errorCode = 'MA_NATIVE_CONTAINMENT_FAILED_UNTERMINATED' }
    if ($State.ProcessHandle -eq [IntPtr]::Zero) { throw (New-MaNativeTerminationError 'NoHandle' 0 $Cause $State.ProcessId $errorCode) }
    $code = 0
    if (Test-MaNativeFault 'TerminateProcess' $State) { $killed = $false }
    else { $killed = [bool]$api::TerminateProcess($State.ProcessHandle, [uint32]1); $code = Get-MaNativeLastError }
    if (Test-MaNativeFault 'ProcessWait' $State) { $wait = $c.WaitTimeout }
    else {
        $wait = $api::WaitForSingleObject($State.ProcessHandle, [uint32]$script:MaTerminationConfirmMilliseconds)
        if ($wait -ne $c.WaitObject0 -and $killed) { $code = Get-MaNativeLastError }
    }
    # O sinal do handle e a confirmacao; TerminateProcess aceito nao basta.
    if ($wait -eq $c.WaitObject0) { return }
    $stage = $(if ($killed) { 'ProcessWait' } else { 'TerminateProcess' })
    throw (New-MaNativeTerminationError $stage $code $Cause $State.ProcessId $errorCode)
}

# Cria o processo suspenso ja dentro do job e confere a associacao. Retorna o
# estado com handles do processo, da thread inicial e das extremidades do pai.
# Nao retoma a execucao: isso cabe a Resume-MaNativeProcess.
function Start-MaNativeSuspendedProcess {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Job,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = $null
    )
    if (-not [IO.Path]::IsPathRooted($FilePath) -or -not [IO.File]::Exists($FilePath)) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' 0 'FilePath') }
    if (-not [IO.Path]::IsPathRooted($WorkingDirectory) -or -not [IO.Directory]::Exists($WorkingDirectory)) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' 0 'WorkingDirectory') }
    $commandText = (@((ConvertTo-MaNativeArgument $FilePath)) + @($Arguments | ForEach-Object { ConvertTo-MaNativeArgument $_ })) -join ' '
    if ($commandText.Length -gt $script:MaNativeConstants.MaxCommandLine) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' 0 'CommandLine') }
    # O job pode vir do chamador: o limite e o handle sao conferidos antes da criacao.
    Assert-MaNativeJobSafety $Job

    $api = Get-MaNativeApi
    $layout = Get-MaNativeLayout
    $pointer = $layout.Pointer
    $marshal = [System.Runtime.InteropServices.Marshal]
    $state = [pscustomobject]@{
        ProcessHandle = [IntPtr]::Zero; ThreadHandle = [IntPtr]::Zero; ProcessId = 0; ThreadId = 0
        StdInWrite = [IntPtr]::Zero; StdOutRead = [IntPtr]::Zero; StdErrRead = [IntPtr]::Zero
        Evidence = $null; Resumed = $false
    }
    $memory = New-Object System.Collections.Generic.List[IntPtr]
    $childEnds = New-Object System.Collections.Generic.List[IntPtr]
    $attributeList = [IntPtr]::Zero
    $attributesReady = $false
    $environmentBlock = [IntPtr]::Zero
    $succeeded = $false
    $failure = $null
    $cleanup = New-Object System.Collections.Generic.List[string]
    try {
        $stdin = New-MaNativePipe $true; $state.StdInWrite = $stdin.Parent; $childEnds.Add($stdin.Child)
        $stdout = New-MaNativePipe $false; $state.StdOutRead = $stdout.Parent; $childEnds.Add($stdout.Child)
        $stderr = New-MaNativePipe $false; $state.StdErrRead = $stderr.Parent; $childEnds.Add($stderr.Child)

        # Primeira chamada apenas informa o tamanho (falha esperada com ERROR_INSUFFICIENT_BUFFER).
        # Falha nos atributos significa contencao indisponivel: nenhum processo existe.
        $sizeCell = New-MaNativeZeroMemory $pointer; $memory.Add($sizeCell)
        [void]$api::InitializeProcThreadAttributeList([IntPtr]::Zero, 2, 0, $sizeCell)
        $attributeSize = $marshal::ReadIntPtr($sizeCell, 0).ToInt64()
        if ($attributeSize -le 0) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' (Get-MaNativeLastError) 'Attributes') }
        $attributeList = New-MaNativeZeroMemory ([int]$attributeSize); $memory.Add($attributeList)
        if (-not $api::InitializeProcThreadAttributeList($attributeList, 2, 0, $sizeCell)) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' (Get-MaNativeLastError) 'Attributes') }
        $attributesReady = $true

        # Os valores precisam permanecer validos ate DeleteProcThreadAttributeList.
        $jobCell = New-MaNativeZeroMemory $pointer; $memory.Add($jobCell)
        $marshal::WriteIntPtr($jobCell, 0, $Job)
        if (-not $api::UpdateProcThreadAttribute($attributeList, [uint32]0, [IntPtr]$script:MaNativeConstants.AttributeJobList, $jobCell, [IntPtr]$pointer, [IntPtr]::Zero, [IntPtr]::Zero)) {
            throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' (Get-MaNativeLastError) 'Attributes')
        }
        $handleCell = New-MaNativeZeroMemory (3 * $pointer); $memory.Add($handleCell)
        for ($index = 0; $index -lt 3; $index++) { $marshal::WriteIntPtr($handleCell, $index * $pointer, $childEnds[$index]) }
        if (-not $api::UpdateProcThreadAttribute($attributeList, [uint32]0, [IntPtr]$script:MaNativeConstants.AttributeHandleList, $handleCell, [IntPtr](3 * $pointer), [IntPtr]::Zero, [IntPtr]::Zero)) {
            throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' (Get-MaNativeLastError) 'Attributes')
        }

        $startup = New-MaNativeZeroMemory $layout.StartupInfoExSize; $memory.Add($startup)
        $marshal::WriteInt32($startup, 0, $layout.StartupInfoExSize)
        $marshal::WriteInt32($startup, $layout.Flags, $script:MaNativeConstants.StartfUseStdHandles)
        $marshal::WriteIntPtr($startup, $layout.StdInput, $childEnds[0])
        $marshal::WriteIntPtr($startup, $layout.StdOutput, $childEnds[1])
        $marshal::WriteIntPtr($startup, $layout.StdError, $childEnds[2])
        $marshal::WriteIntPtr($startup, $layout.AttributeList, $attributeList)
        $processInfo = New-MaNativeZeroMemory $layout.ProcessInfoSize; $memory.Add($processInfo)
        # CreateProcessW pode alterar a linha de comando: buffer gravavel proprio.
        $commandLine = $marshal::StringToHGlobalUni($commandText); $memory.Add($commandLine)
        if ($null -ne $Environment) { $environmentBlock = New-MaNativeEnvironmentBlock $Environment; $memory.Add($environmentBlock) }

        $c = $script:MaNativeConstants
        $flags = [uint32]($c.CreateSuspended -bor $c.CreateUnicodeEnvironment -bor $c.ExtendedStartupInfoPresent -bor $c.CreateNoWindow)
        $created = $api::CreateProcessW($FilePath, $commandLine, [IntPtr]::Zero, [IntPtr]::Zero, $true, $flags, $environmentBlock, $WorkingDirectory, $startup, $processInfo)
        $createError = Get-MaNativeLastError
        if (-not $created) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' $createError 'CreateProcess') }
        try {
            $state.ProcessHandle = $marshal::ReadIntPtr($processInfo, 0)
            $state.ThreadHandle = $marshal::ReadIntPtr($processInfo, $pointer)
            $state.ProcessId = $marshal::ReadInt32($processInfo, 2 * $pointer)
            $state.ThreadId = $marshal::ReadInt32($processInfo, 2 * $pointer + 4)
            [void](Test-MaNativeFault 'AfterCreate' $state)

            $evidence = Get-MaNativeAssociationEvidence $Job $state.ProcessHandle $state.ProcessId
            if ($null -ne $script:MaNativeAssociationProbe) { $evidence = & $script:MaNativeAssociationProbe $evidence }
            $state.Evidence = $evidence
            if (-not $evidence.Confirmed) { throw (New-MaNativeError 'MA_NATIVE_CONTAINMENT_FAILED' 0 'Association') }
            # O pai nunca mantem as extremidades do filho: sem isso o EOF nao chega.
            # Fechadas ainda com o processo suspenso; se alguma falhar, a chamada e
            # recusada aqui em vez de terminar por prazo depois.
            for ($index = 0; $index -lt $childEnds.Count; $index++) {
                $handle = $childEnds[$index]; $childEnds[$index] = [IntPtr]::Zero
                $closeFailure = Close-MaNativeHandle $handle 'ChildEnd'
                if ($null -ne $closeFailure) { $cleanup.Add($closeFailure) }
            }
            # Os descritores sao registrados no finally, na falha que prevalecer.
            if ($cleanup.Count -gt 0) { throw (New-MaNativeError 'MA_NATIVE_CLEANUP_FAILED') }
        } catch {
            # Qualquer falha depois da criacao: a thread inicial nunca executou,
            # entao encerrar o processo suspenso e confirmar o termino basta. Sem
            # confirmacao, o erro de encerramento nao confirmado substitui o original.
            Stop-MaNativeSuspendedProcess $state $_.Exception
            throw
        }
        $succeeded = $true
    } catch {
        $failure = $_.Exception
        throw
    } finally {
        if ($attributesReady) { $api::DeleteProcThreadAttributeList($attributeList) }
        # Caminho de falha: extremidades ainda nao fechadas acima.
        for ($index = 0; $index -lt $childEnds.Count; $index++) {
            $handle = $childEnds[$index]; $childEnds[$index] = [IntPtr]::Zero
            $closeFailure = Close-MaNativeHandle $handle 'ChildEnd'
            if ($null -ne $closeFailure) { $cleanup.Add($closeFailure) }
        }
        foreach ($block in $memory) { $marshal::FreeHGlobal($block) }
        if (-not $succeeded) {
            try { Close-MaNativeProcess $state } catch { $cleanup.AddRange([string[]]@(Get-MaNativeCleanupFailures $_.Exception 'Process')) }
        }
        # A falha original prevalece; as de limpeza ficam registradas nela.
        Add-MaNativeCleanupFailure $failure $cleanup.ToArray()
    }
    return $state
}

# Retoma a thread inicial. ResumeThread devolve a contagem anterior: 1 confirma
# que o processo estava suspenso exatamente pela criacao.
function Resume-MaNativeProcess {
    param([Parameter(Mandatory = $true)]$State)
    $previous = (Get-MaNativeApi)::ResumeThread($State.ThreadHandle)
    if ($previous -ne 1) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' (Get-MaNativeLastError) 'Resume') }
    $State.Resumed = $true
}

# Fecha os handles do estado, cada um uma unica vez: o campo e zerado antes da
# tentativa, mesmo que ela falhe (ver Close-MaNativeHandle). Tenta todos e, se
# algum falhar, lanca MA_NATIVE_CLEANUP_FAILED com os descritores.
function Close-MaNativeProcess {
    param($State)
    if ($null -eq $State) { return }
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('StdInWrite', 'StdOutRead', 'StdErrRead', 'ThreadHandle', 'ProcessHandle')) {
        $handle = $State.$name
        $State.$name = [IntPtr]::Zero
        $closeFailure = Close-MaNativeHandle $handle $name
        if ($null -ne $closeFailure) { $failures.Add($closeFailure) }
    }
    if ($failures.Count -gt 0) { throw (New-MaNativeCleanupError $failures.ToArray()) }
}

# Converte a extremidade do pai em FileStream. A posse passa do estado para o
# SafeFileHandle (campo zerado so depois de ele existir) e dele para o stream so
# quando o construtor conclui. Se o construtor falhar, o SafeFileHandle ainda e o
# dono e e descartado aqui: o handle fecha uma vez e Close-MaNativeProcess nao o
# ve mais.
function ConvertTo-MaNativeStream {
    param($State, [string]$Name, [System.IO.FileAccess]$Access, [int]$BufferSize = 4096)
    $handle = New-Object Microsoft.Win32.SafeHandles.SafeFileHandle($State.$Name, $true)
    $State.$Name = [IntPtr]::Zero
    $stream = $null
    try {
        [void](Test-MaNativeFault 'StreamCreate' ([pscustomobject]@{ Name = $Name; Handle = $handle }))
        $stream = New-Object System.IO.FileStream($handle, $Access, $BufferSize, $false)
    } finally {
        if ($null -eq $stream) { $handle.Dispose() }
    }
    return $stream
}

# Executa o processo nativo contido e devolve ExitCode, StdOut e StdErr (texto
# UTF-8, BOM inicial removido) ou, com -BinaryOutput, StdOut vazio e StdOutBytes
# com os bytes exatos. InputText e enviado ao stdin (UTF-8 sem BOM), de forma
# assincrona e com prazo. Um job novo por chamada; o processo so executa depois
# de associacao confirmada. Stderr e mantido somente em memoria.
function Invoke-MaNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$TimeoutMilliseconds = $script:MaGitTimeoutMilliseconds,
        # Captura stdout como bytes exatos (sem decodificacao nem remocao de BOM).
        [switch]$BinaryOutput,
        # Texto enviado ao stdin (UTF-8 sem BOM), escrito de forma assincrona e com prazo.
        [AllowNull()][string]$InputText = $null
    )
    $api = Get-MaNativeApi
    $confirm = $script:MaTerminationConfirmMilliseconds
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $inputBytes = $null
    if (-not [string]::IsNullOrEmpty($InputText)) { $inputBytes = $utf8.GetBytes($InputText) }
    if ($null -eq $Environment) { $Environment = @{} }
    # Job com KILL_ON_JOB_CLOSE configurado e conferido; se falhar, nenhum processo e criado.
    $job = New-MaNativeJob
    $state = $null
    $streams = New-Object System.Collections.Generic.List[System.IDisposable]
    $failure = $null
    $cleanup = New-Object System.Collections.Generic.List[string]
    $result = $null
    try {
        $state = Start-MaNativeSuspendedProcess -Job $job -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -Environment $Environment
        # Ate a retomada o processo esta suspenso; uma falha cai no catch, que
        # encerra o job inteiro, suspenso ou nao, e confirma. Stdin sem buffer: a
        # escrita so conclui quando os bytes chegam ao pipe.
        $stdinStream = ConvertTo-MaNativeStream $state 'StdInWrite' ([System.IO.FileAccess]::Write) 1; $streams.Add($stdinStream)
        [void](Test-MaNativeFault 'StreamSetup' $state)
        $stdoutStream = ConvertTo-MaNativeStream $state 'StdOutRead' ([System.IO.FileAccess]::Read); $streams.Add($stdoutStream)
        $stderrStream = ConvertTo-MaNativeStream $state 'StdErrRead' ([System.IO.FileAccess]::Read); $streams.Add($stderrStream)
        # Drenagem simultanea dos dois fluxos: pipe cheio nao bloqueia o filho.
        if ($BinaryOutput) {
            $buffer = New-Object System.IO.MemoryStream; $streams.Add($buffer)
            $stdoutTask = $stdoutStream.CopyToAsync($buffer)
        } else { $stdoutTask = (New-Object System.IO.StreamReader($stdoutStream, $utf8, $true, 4096)).ReadToEndAsync() }
        $stderrTask = (New-Object System.IO.StreamReader($stderrStream, $utf8, $true, 4096)).ReadToEndAsync()
        [void](Test-MaNativeFault 'BeforeResume' $state)
        Resume-MaNativeProcess $state
        [void](Test-MaNativeFault 'AfterResume' $state)
        if ($null -ne $inputBytes) {
            # Escrita assincrona: um filho que nao le o stdin nao bloqueia o chamador.
            $writing = $stdinStream.WriteAsync($inputBytes, 0, $inputBytes.Length)
            $written = $false
            try { $written = $writing.Wait([int][Math]::Max(0, $TimeoutMilliseconds - $clock.ElapsedMilliseconds)) } catch { $written = $false }
            if (-not $written) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' 0 'StdIn') }
        }
        $stdinStream.Dispose()
        $remaining = [uint32][Math]::Max(0, $TimeoutMilliseconds - $clock.ElapsedMilliseconds)
        if ($api::WaitForSingleObject($state.ProcessHandle, $remaining) -ne $script:MaNativeConstants.WaitObject0) { throw (New-MaNativeError 'MA_NATIVE_TIMEOUT' 0 'ProcessWait') }
        # O fim dos fluxos tambem tem prazo: um descendente que herdou os pipes pode
        # mante-los abertos depois da saida do processo.
        $remaining = [int][Math]::Max(0, $TimeoutMilliseconds - $clock.ElapsedMilliseconds)
        $drained = $false
        try { $drained = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), $remaining) }
        catch { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' 0 'Drain') }
        if (-not $drained) { throw (New-MaNativeError 'MA_NATIVE_TIMEOUT' 0 'Drain') }
        # Descendente que liberou os pipes e segue ativo: encerrado e chamada recusada.
        # Sem a consulta do job nao ha como afirmar o termino: tambem e falha.
        $settled = Wait-MaNativeJobEmpty $job $script:MaJobSettleMilliseconds
        if ($settled.Status -eq 'QueryFailed') { throw (New-MaNativeError 'MA_NATIVE_TERMINATION_UNCONFIRMED' $settled.Win32Error 'JobQuery') }
        if ($settled.Status -ne 'Empty') { throw (New-MaNativeError 'MA_NATIVE_DESCENDANT_PERSISTED' 0 'JobActive') }
        $exitCell = New-MaNativeZeroMemory 4
        try {
            if (-not $api::GetExitCodeProcess($state.ProcessHandle, $exitCell)) { throw (New-MaNativeError 'MA_GIT_EXECUTION_FAILED' (Get-MaNativeLastError) 'ExitCode') }
            $exitCode = [System.Runtime.InteropServices.Marshal]::ReadInt32($exitCell, 0)
        } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($exitCell) }
        if ($BinaryOutput) { $result = [pscustomobject]@{ ExitCode = $exitCode; StdOut = ''; StdOutBytes = $buffer.ToArray(); StdErr = $stderrTask.Result } }
        else { $result = [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdoutTask.Result; StdErr = $stderrTask.Result } }
    } catch {
        # Qualquer falha depois da criacao do job, antes ou depois da retomada:
        # encerra todos os membros e confirma. Sem confirmacao, o erro passa a ser
        # MA_NATIVE_TERMINATION_UNCONFIRMED, com a falha original em Data['Cause'].
        # Encerramento confirmado com falha operacional de limpeza: o erro original
        # prevalece e registra essa falha.
        $failure = $_.Exception
        try { Stop-MaNativeJob $job $confirm $failure }
        catch {
            if ($_.Exception.Message -ceq 'MA_NATIVE_CLEANUP_FAILED') { Add-MaNativeCleanupFailure $failure (Get-MaNativeCleanupFailures $_.Exception 'Stop') }
            else { $failure = $_.Exception }
        }
    } finally {
        foreach ($stream in $streams) {
            try { $stream.Dispose() } catch { $cleanup.Add('Stream:' + $_.Exception.GetType().Name + ':0') }
        }
        try { Close-MaNativeProcess $state } catch { $cleanup.AddRange([string[]]@(Get-MaNativeCleanupFailures $_.Exception 'Process')) }
        # Garantia final: com KILL_ON_JOB_CLOSE, fechar o ultimo handle encerra
        # qualquer membro restante, inclusive se o catch nao executou (pipeline
        # interrompido) ou nao confirmou. Isso nao produz confirmacao. Se o
        # CloseHandle do job falhar, a falha e relatada e o handle nao e fechado
        # de novo (ver Close-MaNativeHandle).
        $jobHandle = $job; $job = [IntPtr]::Zero
        $closeFailure = Close-MaNativeHandle $jobHandle 'Job'
        if ($null -ne $closeFailure) { $cleanup.Add($closeFailure) }
        Add-MaNativeCleanupFailure $failure $cleanup.ToArray()
    }
    if ($null -ne $failure) { throw $failure }
    # Sem falha principal, uma falha de limpeza recusa o resultado: nao ha sucesso
    # falso com handle do job (ou outro) nao liberado.
    if ($cleanup.Count -gt 0) { throw (New-MaNativeCleanupError $cleanup.ToArray()) }
    return $result
}

# Leituras Git sem lock opcional (sem refresh do indice), sem lazy fetch, sem
# objetos de substituicao, sem fsmonitor, sem prompt e sem subir alem do destino.
# Transporte restrito a HTTPS e SSH por GIT_ALLOW_PROTOCOL: prevalece sobre
# protocol.allow e protocol.<nome>.allow de qualquer escopo (inclusive -c) e sobre
# o valor do consumidor, so no processo filho. Vale para reescritas insteadOf,
# remote helpers (<nome>::, remote.<nome>.vcs) e caminhos locais (file).
# GIT_ALLOW_PROTOCOL nao autentica o executavel do helper: GIT_EXEC_PATH e
# removido do processo filho, e o Git resolve git-remote-<nome> primeiro no
# exec-path da propria instalacao (RUNTIME_PREFIX, conferido em
# Get-MaTrustedExecPath), propagado por ele aos seus descendentes.
# -Transport (somente o clone): git.exe real da instalacao, PATH restrito e
# cliente SSH fixado, conforme Get-MaGitTransport. GIT_SSH e removido;
# GIT_SSH_COMMAND e GIT_SSH_VARIANT do processo filho prevalecem sobre
# core.sshCommand e ssh.variant de qualquer camada, inclusive valores surgidos
# depois da verificacao do transporte.
function Invoke-MaGit {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory, [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments, [switch]$Binary, [AllowNull()][string]$InputText = $null,
        [int]$TimeoutMilliseconds = $script:MaGitTimeoutMilliseconds,
        # Somente para comandos que recusam a magia 'literal' (check-ignore), com
        # caminhos fixos do conjunto governado, sem curingas.
        [switch]$NoLiteralPathspecs,
        [switch]$Transport
    )
    if ($null -ne $script:MaGitInvoker) { return (& $script:MaGitInvoker $WorkingDirectory $Arguments ([bool]$Binary) $InputText ([bool]$Transport)) }
    if (-not $script:MaGitPath) { throw 'MA_GIT_NOT_FOUND' }
    $gitPath = $script:MaGitPath
    $ceiling = [IO.Path]::GetDirectoryName($WorkingDirectory.TrimEnd('\'))
    if (-not $ceiling) { $ceiling = $WorkingDirectory }
    $environment = @{
        GIT_OPTIONAL_LOCKS      = '0'
        GIT_NO_LAZY_FETCH       = '1'
        GIT_NO_REPLACE_OBJECTS  = '1'
        GIT_TERMINAL_PROMPT     = '0'
        GIT_LITERAL_PATHSPECS   = '1'
        GIT_ALLOW_PROTOCOL      = $script:MaAllowedProtocols
        GIT_EXEC_PATH           = $null
        GIT_CEILING_DIRECTORIES = $ceiling
        GCM_INTERACTIVE         = 'never'
        GIT_PAGER               = 'cat'
        LC_ALL                  = 'C'
    }
    # Rastreamento desligado no processo filho: GIT_TRACE* do ambiente e destinos
    # trace2 da configuracao global ou de sistema gravariam arquivos, inclusive no
    # repositorio inspecionado. Valor $null remove a variavel; '0' desliga trace2.
    foreach ($variable in @(Get-ChildItem Env: -ErrorAction SilentlyContinue)) { if ($variable.Name -match '\AGIT_TRACE') { $environment[$variable.Name] = $null } }
    foreach ($name in @('GIT_TRACE2', 'GIT_TRACE2_EVENT', 'GIT_TRACE2_PERF')) { $environment[$name] = '0' }
    if ($NoLiteralPathspecs) { $environment['GIT_LITERAL_PATHSPECS'] = '0' }
    if ($Transport) {
        if ($null -eq $script:MaGitTransport) { throw 'MA_GIT_TRANSPORT_UNTRUSTED' }
        $gitPath = $script:MaGitTransport.GitPath
        $environment['PATH'] = $script:MaGitTransport.Path
        $environment['GIT_SSH'] = $null
        $environment['GIT_SSH_COMMAND'] = $script:MaGitTransport.SshCommand
        if ($null -ne $script:MaSshTestCommand) { $environment['GIT_SSH_COMMAND'] = $script:MaSshTestCommand }
        $environment['GIT_SSH_VARIANT'] = 'ssh'
    }
    $all = @('-c', 'core.fsmonitor=false') + $Arguments
    return (Invoke-MaNativeProcess -FilePath $gitPath -Arguments $all -WorkingDirectory $WorkingDirectory -Environment $environment -TimeoutMilliseconds $TimeoutMilliseconds -BinaryOutput:$Binary -InputText $InputText)
}

# Comprova presenca, tipo e legibilidade de um blob no banco de objetos local e
# que seus bytes correspondem ao identificador. Sem filtros, textconv, checkout
# ou busca remota (GIT_NO_LAZY_FETCH). Nao depende de o Git validar o hash na
# leitura: o identificador e recalculado sobre os bytes lidos.
#   'Ok'           presente, blob, bytes conferem.
#   'Missing'      ausencia comprovada: cat-file --batch-check responde "missing"
#                  e cat-file -e confirma com codigo 1, ambos sem erro no stderr.
#                  O batch-check tambem responde "missing" para objeto corrompido,
#                  por isso a resposta isolada nao prova ausencia.
#   'Unreadable'   o objeto existe (cat-file -e = 0), mas tipo ou bytes nao sao legiveis.
#   'TypeMismatch' presente com tipo diferente de blob.
#   'Corrupt'      lido, mas os bytes nao correspondem ao identificador.
#   'Undetermined' qualquer outro resultado: a causa nao foi determinada.
# Todos os resultados diferentes de 'Ok' sao bloqueantes no Plan.
function Test-MaGitBlobObject {
    param([string]$Root, [string]$ObjectId, [string]$ObjectFormat)
    return (Read-MaGitObject $Root $ObjectId $ObjectFormat 'blob').Status
}

# Como Test-MaGitBlobObject, para blob ou commit, devolvendo tambem os bytes
# lidos do banco de objetos (Bytes, somente com Status 'Ok').
function Read-MaGitObject {
    param([string]$Root, [string]$ObjectId, [string]$ObjectFormat, [ValidateSet('blob', 'commit')][string]$Type = 'blob')
    $outcome = { param([string]$Status, $Bytes = $null) [pscustomobject]@{ Status = $Status; Bytes = $Bytes } }
    if ($ObjectId -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') { return (& $outcome 'Undetermined') }
    $check = Invoke-MaGit $Root @('cat-file', '--batch-check') -InputText ($ObjectId + "`n")
    $clean = ($check.ExitCode -eq 0 -and [string]::IsNullOrEmpty([string]$check.StdErr))
    $lines = Split-MaLines ([string]$check.StdOut)
    $answer = ''
    if ($clean -and $lines.Count -eq 1) { $answer = $lines[0] }
    if ($answer -ceq ($ObjectId + ' missing')) {
        $exists = Invoke-MaGit $Root @('cat-file', '-e', $ObjectId)
        $quiet = [string]::IsNullOrEmpty([string]$exists.StdErr)
        if ($exists.ExitCode -eq 1 -and $quiet) { return (& $outcome 'Missing') }
        if ($exists.ExitCode -eq 0) { return (& $outcome 'Unreadable') }
        return (& $outcome 'Undetermined')
    }
    $match = [regex]::Match($answer, ('\A' + $ObjectId + ' ([a-z]+) ([0-9]+)\z'))
    if (-not $match.Success) {
        # Resposta ausente, com erro ou malformada: so a existencia pode ser conferida.
        $exists = Invoke-MaGit $Root @('cat-file', '-e', $ObjectId)
        if ($exists.ExitCode -eq 0) { return (& $outcome 'Unreadable') }
        return (& $outcome 'Undetermined')
    }
    if ($match.Groups[1].Value -cne $Type) { return (& $outcome 'TypeMismatch') }
    $read = Invoke-MaGit $Root @('cat-file', $Type, $ObjectId) -Binary
    if ($read.ExitCode -ne 0) { return (& $outcome 'Unreadable') }
    $bytes = [byte[]]$read.StdOutBytes
    if ($null -eq $bytes) { return (& $outcome 'Unreadable') }
    if ((Get-MaGitObjectId $bytes $ObjectFormat $Type) -cne $ObjectId) { return (& $outcome 'Corrupt') }
    return (& $outcome 'Ok' $bytes)
}

function Split-MaNullFields {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return , @() }
    $fields = $Text.Split([char]0)
    if ($fields[$fields.Length - 1] -eq '') { $fields = $fields[0..($fields.Length - 2)] }
    return , @($fields)
}

function Split-MaLines {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return , @() }
    return , @($Text.Replace("`r", '').TrimEnd("`n").Split([char]10))
}

function Get-MaGitOverrideIssues {
    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($variable in (Get-ChildItem Env: -ErrorAction SilentlyContinue)) {
        if ($variable.Name -in $script:MaGitOverrideVariables -or $variable.Name -match '\AGIT_CONFIG_(?:KEY|VALUE)_[0-9]+\z') {
            $issues.Add((New-MaIssue 'MA_GIT_ENV_OVERRIDE' -Detail $variable.Name))
        }
    }
    return , $issues.ToArray()
}

function Find-MaShell {
    param([string]$GitPath)
    $directory = [IO.Path]::GetDirectoryName($GitPath)
    for ($level = 0; $level -lt 4 -and $directory; $level++) {
        foreach ($candidate in @('usr\bin\sh.exe', 'bin\sh.exe')) {
            $path = [IO.Path]::Combine($directory, $candidate)
            if ([IO.File]::Exists($path)) { return $path }
        }
        $directory = [IO.Path]::GetDirectoryName($directory)
    }
    return $null
}

# Exec-path informado pelo Git localizado (consultado sem GIT_EXEC_PATH), aceito
# somente no layout da propria instalacao: <prefixo>\libexec\git-core, com
# <prefixo> igual ao pai do diretorio do git.exe (bin\git.exe) ou um nivel abaixo
# dele (cmd\git.exe do Git for Windows -> mingw64), sem segmentos relativos, e com
# git-remote-https.exe presente, resolvido antes do PATH. O helper ssh nao faz
# parte da instalacao: o SSH nativo nao usa helper. Devolve o caminho ou $null.
function Get-MaTrustedExecPath {
    param([string]$GitPath, [string]$ExecPath)
    if ([string]::IsNullOrEmpty($GitPath) -or [string]::IsNullOrEmpty($ExecPath)) { return $null }
    if ($ExecPath -inotmatch '\A[A-Za-z]:\\(?:[^\\]+\\)*libexec\\git-core\z') { return $null }
    try { if (-not [IO.Path]::GetFullPath($ExecPath).Equals($ExecPath, [StringComparison]::OrdinalIgnoreCase)) { return $null } } catch { return $null }
    $prefix = $ExecPath.Substring(0, $ExecPath.Length - '\libexec\git-core'.Length)
    $root = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($GitPath))
    if (-not $root) { return $null }
    $parent = [IO.Path]::GetDirectoryName($prefix)
    if (-not ($prefix.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or ($parent -and $parent.Equals($root, [StringComparison]::OrdinalIgnoreCase)))) { return $null }
    if (-not [IO.File]::Exists([IO.Path]::Combine($ExecPath, 'git-remote-https.exe'))) { return $null }
    return $ExecPath
}

# Ambiente de transporte do clone (alternativa B da v1.0), derivado do exec-path
# conferido por Get-MaTrustedExecPath. O clone e seus descendentes recebem PATH
# restrito a <prefixo>\bin, <instalacao>\usr\bin e aos diretorios do Windows, e o
# executavel e o git.exe real da instalacao (<prefixo>\bin\git.exe): o wrapper
# cmd\git.exe acrescenta %HOME%\bin ao PATH dos descendentes. O Git antepoe o
# exec-path ao PATH, entao git-remote-<nome> resolve no exec-path e depois nesses
# diretorios; git-remote-ssh nao faz parte da instalacao e, presente em qualquer
# um deles, torna a origem dos helpers nao comprovada. O cliente SSH e o OpenSSH
# da instalacao (usr\bin\ssh.exe), fixado por GIT_SSH_COMMAND mesmo se ausente:
# sem ele o transporte SSH e recusado antes do clone (Ssh = $null) e uma
# reescrita tardia para SSH falha sem executar outro programa. Devolve
# Transport (ou $null) e, na recusa, o caminho que a motivou em Detail.
function Get-MaGitTransport {
    param([Parameter(Mandatory = $true)][string]$ExecPath)
    $prefix = $ExecPath.Substring(0, $ExecPath.Length - '\libexec\git-core'.Length)
    # Git for Windows: prefixo MinGW (mingw64, clangarm64...) abaixo da instalacao.
    $install = $prefix
    if ([IO.Path]::GetFileName($prefix) -imatch '\A(?:mingw32|mingw64|clang32|clang64|clangarm64|ucrt64)\z') { $install = [IO.Path]::GetDirectoryName($prefix) }
    $isFile = { param([string]$Path) [IO.File]::Exists($Path) -and -not ([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) }
    $gitPath = [IO.Path]::Combine($prefix, 'bin', 'git.exe')
    if (-not (& $isFile $gitPath)) { return [pscustomobject]@{ Transport = $null; Detail = $gitPath } }
    $tools = [IO.Path]::Combine($install, 'usr', 'bin')
    $directories = New-Object System.Collections.Generic.List[string]
    foreach ($directory in @([IO.Path]::Combine($prefix, 'bin'), $tools, [Environment]::GetFolderPath('System'), [Environment]::GetFolderPath('Windows'))) {
        if ($directory -and [IO.Directory]::Exists($directory) -and -not ($directories -icontains $directory)) { $directories.Add($directory) }
    }
    foreach ($directory in @(@($ExecPath) + $directories.ToArray())) {
        $helpers = $null
        try { $helpers = @([IO.Directory]::GetFiles($directory, 'git-remote-ssh*')) } catch { return [pscustomobject]@{ Transport = $null; Detail = $directory } }
        if ($helpers.Count -gt 0) { return [pscustomobject]@{ Transport = $null; Detail = $helpers[0] } }
    }
    $ssh = [IO.Path]::Combine($tools, 'ssh.exe')
    $client = $null; if (& $isFile $ssh) { $client = $ssh }
    $transport = [pscustomobject]@{
        GitPath = $gitPath; Path = ($directories.ToArray() -join ';'); Ssh = $client
        # Literal entre aspas simples para o sh da instalacao, com barras normais.
        SshCommand = ("'" + $ssh.Replace('\', '/').Replace("'", "'\''") + "'")
    }
    return [pscustomobject]@{ Transport = $transport; Detail = '' }
}

function Get-MaGitContext {
    param([string]$WorkingDirectory)
    $issues = New-Object System.Collections.Generic.List[object]
    $context = [ordered]@{ Available = $false; Path = $null; Version = $null; Shell = $null; ExecPath = $null }
    if ($null -eq $script:MaGitInvoker) {
        $script:MaGitTransport = $null
        $command = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) {
            $issues.Add((New-MaIssue 'MA_GIT_NOT_FOUND'))
            return [pscustomobject]@{ Context = [pscustomobject]$context; Issues = $issues.ToArray() }
        }
        $script:MaGitPath = $command.Path
        $context.Path = $command.Path
        $context.Shell = Find-MaShell $command.Path
        if (-not $context.Shell) { $issues.Add((New-MaIssue 'MA_SH_NOT_FOUND' -Severity 'Aviso')) }
    } else { $context.Path = '(simulado)'; $context.Shell = '(simulado)' }
    try {
        $result = Invoke-MaGit -WorkingDirectory $WorkingDirectory -Arguments @('--version')
        $match = [regex]::Match([string]$result.StdOut, 'git version ([0-9]+)\.([0-9]+)\.([0-9]+)')
        if ($result.ExitCode -ne 0 -or -not $match.Success) { $issues.Add((New-MaIssue 'MA_GIT_EXECUTION_FAILED' -Severity 'Falha')) }
        else {
            $context.Version = New-Object Version ([int]$match.Groups[1].Value), ([int]$match.Groups[2].Value), ([int]$match.Groups[3].Value)
            if ($context.Version -lt $script:MaMinimumGitVersion) { $issues.Add((New-MaIssue 'MA_GIT_VERSION_UNSUPPORTED' -Detail $context.Version.ToString())) }
            else { $context.Available = $true }
        }
        # Origem dos helpers de transporte (somente com o Git real localizado).
        if ($context.Available -and $null -eq $script:MaGitInvoker) {
            $exec = Invoke-MaGit -WorkingDirectory $WorkingDirectory -Arguments @('--exec-path')
            $lines = Split-MaLines ([string]$exec.StdOut)
            $reported = $null
            if ($exec.ExitCode -eq 0 -and $lines.Count -eq 1) { $reported = ConvertTo-MaWindowsPath $lines[0] }
            $context.ExecPath = Get-MaTrustedExecPath $context.Path $reported
            if (-not $context.ExecPath) { $issues.Add((New-MaIssue 'MA_GIT_EXEC_PATH_UNTRUSTED' -Detail ([string]$reported))) }
            else {
                $built = Get-MaGitTransport $context.ExecPath
                $script:MaGitTransport = $built.Transport
                if ($null -eq $built.Transport) { $issues.Add((New-MaIssue 'MA_GIT_TRANSPORT_UNTRUSTED' -Detail $built.Detail)) }
            }
            $variable = [Environment]::GetEnvironmentVariable('GIT_EXEC_PATH')
            if (-not [string]::IsNullOrEmpty($variable) -and -not ($context.ExecPath -and (ConvertTo-MaWindowsPath $variable).Equals($context.ExecPath, [StringComparison]::OrdinalIgnoreCase))) {
                $issues.Add((New-MaIssue 'MA_GIT_EXEC_PATH_IGNORED' -Severity 'Aviso' -Detail 'GIT_EXEC_PATH'))
            }
        }
    } catch { $issues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_GIT_EXECUTION_FAILED') -Severity 'Falha' -Detail (Get-MaErrorDetail $_))) }
    return [pscustomobject]@{ Context = [pscustomobject]$context; Issues = $issues.ToArray() }
}

function Test-MaBranchesWithGit {
    param([System.Collections.IDictionary]$Branches, [string]$WorkingDirectory)
    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($role in $script:MaRoles) {
        $result = Invoke-MaGit -WorkingDirectory $WorkingDirectory -Arguments @('check-ref-format', '--branch', [string]$Branches[$role])
        if ($result.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_BRANCH_GIT_REJECTED' -Role $role)) }
        elseif ((Split-MaLines $result.StdOut) -cnotcontains [string]$Branches[$role]) { $issues.Add((New-MaIssue 'MA_BRANCH_GIT_REJECTED' -Role $role -Detail 'normalizado')) }
    }
    return , $issues.ToArray()
}

# --- Inspecao de ambientes ---------------------------------------------------------

# Dicionario com a identidade exata dos caminhos (comparacao ordinal, sensivel a
# caixa): .githooks/Pre-Commit nao e .githooks/pre-commit.
function New-MaPathMap {
    return , (New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal))
}

# Caminhos relevantes ao conjunto governado: arquivos de primeiro nivel e
# diretorios exclusivos, reconhecidos sem distinguir caixa para que grafias que
# diferem somente por caixa (colidiriam no checkout do Windows) sejam enumeradas e
# recusadas pela comparacao ordinal.
function Get-MaGovernedPathPattern {
    param([string[]]$Governed)
    $prefixes = @(@($Governed | Where-Object { $_.IndexOf('/') -lt 0 }) + $script:MaExclusiveDirectories | ForEach-Object { [regex]::Escape($_) })
    return (New-Object regex (('\A(?:' + ($prefixes -join '|') + ')(?:/|\z)'), ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)))
}

# Entradas de ls-tree ou ls-files -s por caminho exato (New-MaPathMap); um caminho
# pode ter varias entradas (estagios de conflito). Com Filter, somente os caminhos
# que o atendem.
function Get-MaGitEntries {
    param([string]$Text, [ValidateSet('Tree', 'Index')][string]$Kind, [regex]$Filter = $null)
    $entries = New-MaPathMap
    foreach ($record in (Split-MaNullFields $Text)) {
        $tab = $record.IndexOf([char]9)
        if ($tab -lt 0) { throw 'MA_ENV_GIT_UNREADABLE' }
        $meta = $record.Substring(0, $tab).Split(' ')
        $path = $record.Substring($tab + 1)
        if ($meta.Length -ne 3) { throw 'MA_ENV_GIT_UNREADABLE' }
        if ($null -ne $Filter -and -not $Filter.IsMatch($path)) { continue }
        if ($Kind -eq 'Tree') { $entry = [pscustomobject]@{ Mode = $meta[0]; Type = $meta[1]; ObjectId = $meta[2]; Stage = '0' } }
        else { $entry = [pscustomobject]@{ Mode = $meta[0]; Type = 'index'; ObjectId = $meta[1]; Stage = $meta[2] } }
        if ($entries.ContainsKey($path)) { $entries[$path] = @($entries[$path]) + $entry } else { $entries[$path] = @($entry) }
    }
    return , $entries
}

function Get-MaWorktreeRecords {
    param([string]$Text)
    $records = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($field in ([string]$Text).Split([char]0)) {
        if ($field -eq '') { if ($null -ne $current) { $records.Add([pscustomobject]$current); $current = $null }; continue }
        if ($field.StartsWith('worktree ')) { $current = [ordered]@{ Path = (ConvertTo-MaWindowsPath $field.Substring(9)); Branch = $null; Detached = $false; Bare = $false; Prunable = $false; Locked = $false }; continue }
        if ($null -eq $current) { continue }
        if ($field.StartsWith('branch refs/heads/')) { $current.Branch = $field.Substring(18) }
        elseif ($field -ceq 'detached') { $current.Detached = $true }
        elseif ($field -ceq 'bare') { $current.Bare = $true }
        elseif ($field.StartsWith('prunable')) { $current.Prunable = $true }
        elseif ($field.StartsWith('locked')) { $current.Locked = $true }
    }
    if ($null -ne $current) { $records.Add([pscustomobject]$current) }
    return , $records.ToArray()
}

function Get-MaEnvironmentInspection {
    param([Parameter(Mandatory = $true)][string]$Role, [Parameter(Mandatory = $true)]$Configuration, [bool]$GitAvailable)
    $root = $Configuration.Worktrees[$Role]
    $issues = New-Object System.Collections.Generic.List[object]
    $state = [ordered]@{
        Role = $Role; Path = $root; ExpectedBranch = $Configuration.Branches[$Role]; State = 'Ausente'
        Exists = $false; IsRepository = $false; Inspected = $false; TopLevel = $null; CommonDir = $null; Branch = $null; Head = $null
        ObjectFormat = 'sha1'; HooksPath = @(); DefaultHooks = @(); AuxiliaryHookFiles = @(); Worktrees = @(); Tree = (New-MaPathMap); Index = (New-MaPathMap); Objects = @{}
        CheckoutPending = $false
        # Diretorio de hooks efetivo resolvido pelo Git neste worktree e hooks ativos nele.
        HooksDirectory = $null; EffectiveHooks = @()
    }
    $finish = {
        $blocking = @($issues | Where-Object { $_.Severity -ne 'Aviso' })
        if ($blocking.Count -gt 0 -and $state.State -notin @('Inseguro', 'Conflitante', 'NaoInspecionado')) { $state.State = 'Conflitante' }
        $state.Issues = $issues.ToArray()
        return [pscustomobject]$state
    }
    try { [void](Assert-MaSafePath $root 'Directory' -AllowMissing) }
    catch {
        $code = Get-MaErrorCode $_ 'MA_PATH_INSPECTION_FAILED'
        if ($code -eq 'MA_PATH_DIRECTORY_REQUIRED') { $code = 'MA_ENV_NOT_DIRECTORY'; $state.State = 'Conflitante' } else { $state.State = 'Inseguro' }
        $state.Exists = $true
        $issues.Add((New-MaIssue $code -Role $Role -Path $root))
        return (& $finish)
    }
    if (-not [IO.Directory]::Exists($root)) { return (& $finish) }
    $state.Exists = $true
    $state.State = 'Existente'
    $gitEntry = Get-Item -LiteralPath ([IO.Path]::Combine($root, '.git')) -Force -ErrorAction SilentlyContinue
    if ($null -eq $gitEntry) {
        if (@(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop).Count -eq 0) { $state.State = 'VazioSemRepositorio' }
        else { $issues.Add((New-MaIssue 'MA_ENV_NOT_REPOSITORY' -Role $Role -Path $root)) }
        return (& $finish)
    }
    if (($gitEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $state.State = 'Inseguro'; $issues.Add((New-MaIssue 'MA_PATH_REPARSE_POINT' -Role $Role -Path $gitEntry.FullName)); return (& $finish) }
    if ($Role -eq 'coordination' -and -not $gitEntry.PSIsContainer) { $issues.Add((New-MaIssue 'MA_ENV_COORDINATION_NOT_MAIN_CLONE' -Role $Role -Path $root)); return (& $finish) }
    if ($Role -ne 'coordination' -and $gitEntry.PSIsContainer) { $issues.Add((New-MaIssue 'MA_ENV_NOT_LINKED_WORKTREE' -Role $Role -Path $root)); return (& $finish) }
    $state.IsRepository = $true
    if ([IO.File]::Exists([IO.Path]::Combine($root, '.gitmodules'))) { $issues.Add((New-MaIssue 'MA_ENV_SUBMODULES_UNSUPPORTED' -Role $Role -Path $root)) }
    if (-not $GitAvailable) { $state.State = 'NaoInspecionado'; return (& $finish) }

    $parse = Invoke-MaGit $root @('rev-parse', '--path-format=absolute', '--show-toplevel', '--git-common-dir', '--is-bare-repository', '--is-shallow-repository', '--show-object-format')
    $lines = Split-MaLines $parse.StdOut
    if ($parse.ExitCode -ne 0 -or $lines.Count -ne 5) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root)); $state.State = 'NaoInspecionado'; return (& $finish) }
    $state.TopLevel = ConvertTo-MaWindowsPath $lines[0]
    $state.CommonDir = ConvertTo-MaWindowsPath $lines[1]
    if (-not $state.TopLevel.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { $issues.Add((New-MaIssue 'MA_ENV_TOPLEVEL_MISMATCH' -Role $Role -Path $root -Detail $state.TopLevel)) }
    if ($lines[2] -ceq 'true') { $issues.Add((New-MaIssue 'MA_ENV_BARE' -Role $Role -Path $root)) }
    if ($lines[3] -ceq 'true') { $issues.Add((New-MaIssue 'MA_ENV_SHALLOW' -Role $Role -Path $root)) }
    if ($lines[4] -cnotin @('sha1', 'sha256')) { $issues.Add((New-MaIssue 'MA_ENV_OBJECT_FORMAT_UNSUPPORTED' -Role $Role -Path $root)); return (& $finish) }
    $state.ObjectFormat = $lines[4]

    $partial = Invoke-MaGit $root @('config', '-z', '--get-regexp', '^(extensions\.partialclone|remote\..*\.promisor|remote\..*\.partialclonefilter)$')
    if ($partial.ExitCode -eq 0 -and $partial.StdOut) { $issues.Add((New-MaIssue 'MA_ENV_PARTIAL_CLONE' -Role $Role -Path $root)) }
    elseif ($partial.ExitCode -notin @(0, 1)) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'config')) }

    $symbolic = Invoke-MaGit $root @('symbolic-ref', '--quiet', 'HEAD')
    if ($symbolic.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_DETACHED_HEAD' -Role $Role -Path $root)) }
    else {
        $reference = (Split-MaLines $symbolic.StdOut)[0]
        if ($reference.StartsWith('refs/heads/')) { $state.Branch = $reference.Substring(11) }
        if ($state.Branch -cne $state.ExpectedBranch) { $issues.Add((New-MaIssue 'MA_ENV_BRANCH_MISMATCH' -Role $Role -Path $root -Detail ([string]$state.Branch))) }
    }

    $head = Invoke-MaGit $root @('rev-parse', '--verify', '--quiet', 'HEAD^{commit}')
    if ($head.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_REPOSITORY_NO_COMMIT' -Role $Role -Path $root)) }
    else { $state.Head = (Split-MaLines $head.StdOut)[0] }

    # Clone ou worktree criado sem checkout e nao concluido: indice ausente com
    # HEAD nao vazio. Estado intermediario de PrepareMaintenance, retomado por ela.
    if ($state.Head) {
        $indexPath = Invoke-MaGit $root @('rev-parse', '--path-format=absolute', '--git-path', 'index')
        $indexLines = Split-MaLines $indexPath.StdOut
        if ($indexPath.ExitCode -ne 0 -or $indexLines.Count -ne 1) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'git-path index')) }
        elseif (-not [IO.File]::Exists((ConvertTo-MaWindowsPath $indexLines[0]))) {
            $headTree = Invoke-MaGit $root @('rev-parse', '--verify', '--quiet', 'HEAD^{tree}')
            $emptyTrees = @('4b825dc642cb6eb9a060e54bf8d69288fbee4904', '6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321')
            if ($headTree.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'HEAD^{tree}')) }
            elseif ((Split-MaLines $headTree.StdOut)[0] -cnotin $emptyTrees) {
                $state.CheckoutPending = $true
                $state.State = 'CheckoutPendente'
                $issues.Add((New-MaIssue 'MA_ENV_CHECKOUT_PENDING' -Severity 'Aviso' -Role $Role -Path $root))
            }
        }
    }

    if ($Role -eq 'coordination') {
        $origin = Invoke-MaGit $root @('config', '-z', '--get-all', 'remote.origin.url')
        $urls = Split-MaNullFields $origin.StdOut
        if ($origin.ExitCode -eq 1 -or $urls.Count -eq 0) { $issues.Add((New-MaIssue 'MA_REMOTE_ORIGIN_MISSING' -Role $Role -Path $root)) }
        elseif ($origin.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'origin')) }
        elseif ($urls.Count -gt 1) { $issues.Add((New-MaIssue 'MA_REMOTE_ORIGIN_AMBIGUOUS' -Role $Role -Path $root)) }
        elseif ($urls[0] -cne $Configuration.RepositoryUrl) { $issues.Add((New-MaIssue 'MA_REMOTE_ORIGIN_MISMATCH' -Role $Role -Path $root)) }
        $list = Invoke-MaGit $root @('worktree', 'list', '--porcelain', '-z')
        if ($list.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'worktree')) }
        else { $state.Worktrees = Get-MaWorktreeRecords $list.StdOut }
    }

    # Configuracao de hooks: registrada para a futura ativacao; nada e alterado.
    $hooks = Invoke-MaGit $root @('config', '-z', '--show-scope', '--show-origin', '--get-all', 'core.hooksPath')
    if ($hooks.ExitCode -eq 0) {
        $fields = Split-MaNullFields $hooks.StdOut
        $values = New-Object System.Collections.Generic.List[object]
        if ($fields.Count % 3 -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'core.hooksPath')) }
        for ($index = 0; $index + 2 -lt $fields.Count; $index += 3) { $values.Add([pscustomobject]@{ Scope = $fields[$index]; Origin = $fields[$index + 1]; Value = $fields[$index + 2] }) }
        $state.HooksPath = $values.ToArray()
        if ($values.Count -gt 0) { $issues.Add((New-MaIssue 'MA_HOOKS_PATH_PRESENT' -Severity 'Aviso' -Role $Role -Path $root -Detail ((@($values | ForEach-Object { $_.Scope + '=' + $_.Value })) -join '; '))) }
    } elseif ($hooks.ExitCode -ne 1) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'core.hooksPath')) }
    # Inspeciona o diretorio padrao (<comum>/hooks) e o efetivo: com core.hooksPath
    # definido, --git-path hooks devolve o valor configurado, nao o padrao.
    $hookDirectories = [ordered]@{}
    $hookDirectories[(ConvertTo-MaWindowsPath ([IO.Path]::Combine($state.CommonDir, 'hooks')))] = 'MA_HOOKS_DEFAULT_ACTIVE'
    $hooksDir = Invoke-MaGit $root @('rev-parse', '--path-format=absolute', '--git-path', 'hooks')
    if ($hooksDir.ExitCode -eq 0) {
        $effective = ConvertTo-MaWindowsPath (Split-MaLines $hooksDir.StdOut)[0]
        if (-not [IO.Path]::IsPathRooted($effective)) { $effective = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $effective)) }
        $state.HooksDirectory = $effective
        $known = $false
        foreach ($key in $hookDirectories.Keys) { if ($key.Equals($effective, [StringComparison]::OrdinalIgnoreCase)) { $known = $true } }
        if (-not $known) { $hookDirectories[$effective] = 'MA_HOOKS_EFFECTIVE_ACTIVE' }
    } else { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'git-path hooks')) }
    # A .githooks governada do proprio ambiente ja e conferida byte a byte na
    # classificacao dos destinos; nao e tratada como hook preexistente.
    $governedHooks = [IO.Path]::Combine($root, '.githooks')
    foreach ($directory in $hookDirectories.Keys) {
        if (-not [IO.Directory]::Exists($directory)) { continue }
        $inventory = Get-MaHookInventory $directory
        if ($hookDirectories[$directory] -eq 'MA_HOOKS_DEFAULT_ACTIVE') { $state.DefaultHooks = $inventory.Active; $state.AuxiliaryHookFiles = $inventory.Auxiliary }
        if ($state.HooksDirectory -and $directory.Equals($state.HooksDirectory, [StringComparison]::OrdinalIgnoreCase)) { $state.EffectiveHooks = $inventory.Active }
        if ($hookDirectories[$directory] -eq 'MA_HOOKS_EFFECTIVE_ACTIVE' -and $directory.Equals($governedHooks, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($inventory.Active.Count -gt 0) { $issues.Add((New-MaIssue $hookDirectories[$directory] -Severity 'Aviso' -Role $Role -Path $directory -Detail ($inventory.Active -join ', '))) }
    }

    # Entradas governadas no HEAD e no indice, lidas sem checkout nem filtros. Os
    # pathspecs do Git distinguem caixa: a listagem e completa e filtrada aqui, para
    # que grafias que diferem somente por caixa tambem sejam conferidas.
    $relevant = Get-MaGovernedPathPattern (Get-MaTemplateMap)
    if ($state.Head) {
        $tree = Invoke-MaGit $root @('ls-tree', '-r', '-z', '--full-tree', 'HEAD')
        if ($tree.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'ls-tree')) }
        else { $state.Tree = Get-MaGitEntries $tree.StdOut 'Tree' $relevant }
    }
    $index = Invoke-MaGit $root @('ls-files', '-s', '-z')
    if ($index.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'ls-files')) }
    else { $state.Index = Get-MaGitEntries $index.StdOut 'Index' $relevant }

    # Identificadores iguais nao provam que o objeto existe e e legivel: cada blob
    # referenciado pelos caminhos governados e lido e conferido uma unica vez.
    # Gitlinks (commit de outro repositorio) nao tem objeto local a ler.
    $objectCodes = @{ Missing = 'MA_GIT_OBJECT_MISSING'; Unreadable = 'MA_GIT_OBJECT_UNREADABLE'; Corrupt = 'MA_GIT_OBJECT_CORRUPT'; TypeMismatch = 'MA_GIT_OBJECT_TYPE_MISMATCH'; Undetermined = 'MA_GIT_OBJECT_UNVERIFIED' }
    foreach ($source in @(@('HEAD', $state.Tree), @('indice', $state.Index))) {
        foreach ($path in @($source[1].Keys | Sort-Object)) {
            foreach ($entry in @($source[1][$path])) {
                if ($entry.Mode -ceq '160000' -or $entry.Type -ceq 'commit') { continue }
                if (-not $state.Objects.ContainsKey($entry.ObjectId)) { $state.Objects[$entry.ObjectId] = Test-MaGitBlobObject $root $entry.ObjectId $state.ObjectFormat }
                $status = $state.Objects[$entry.ObjectId]
                if ($status -cne 'Ok') {
                    $code = 'MA_GIT_OBJECT_UNVERIFIED'
                    if ($objectCodes.ContainsKey([string]$status)) { $code = $objectCodes[[string]$status] }
                    $issues.Add((New-MaIssue $code -Role $Role -Path $path -Detail ($source[0] + ' ' + $entry.ObjectId)))
                }
            }
        }
    }
    $state.Inspected = $true
    return (& $finish)
}

# Nomes de hooks reconhecidos pelo Git (githooks(5), Git 2.52). Arquivos com
# outros nomes, inclusive *.sample, copias e scripts auxiliares, nao sao
# executados como hooks.
$script:MaGitHookNames = @(
    'applypatch-msg', 'pre-applypatch', 'post-applypatch', 'pre-commit', 'pre-merge-commit', 'prepare-commit-msg',
    'commit-msg', 'post-commit', 'pre-rebase', 'post-checkout', 'post-merge', 'pre-push', 'pre-receive', 'update',
    'proc-receive', 'post-receive', 'post-update', 'reference-transaction', 'push-to-checkout', 'pre-auto-gc',
    'post-rewrite', 'sendemail-validate', 'fsmonitor-watchman', 'p4-changelist', 'p4-prepare-changelist',
    'p4-post-changelist', 'p4-pre-submit', 'post-index-change'
)

# Classifica entradas de um diretorio de hooks. No Windows o Git localiza o hook
# pelo nome exato ou com o sufixo .exe (STRIP_EXTENSION), sem exigir bit
# executavel, e o sistema de arquivos nao distingue caixa. Entrada com nome de
# hook que nao seja arquivo comum (diretorio ou link) e tratada como ativa, de
# forma conservadora, pois o Git tentaria executa-la.
function Get-MaHookInventory {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $active = New-Object System.Collections.Generic.List[string]
    $auxiliary = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction Stop | Sort-Object Name)) {
        $name = $entry.Name
        $hookName = $name
        if ($hookName -imatch '\.exe\z') { $hookName = $hookName.Substring(0, $hookName.Length - 4) }
        $recognized = $false
        foreach ($known in $script:MaGitHookNames) { if ($known.Equals($hookName, [StringComparison]::OrdinalIgnoreCase)) { $recognized = $true } }
        if (-not $recognized) { $auxiliary.Add($name); continue }
        if ($entry.PSIsContainer) { $active.Add($name + '/') } else { $active.Add($name) }
    }
    return [pscustomobject]@{ Active = $active.ToArray(); Auxiliary = $auxiliary.ToArray() }
}

function Get-MaWorktreeScopeIssues {
    param($Coordination, [object[]]$Environments, $Configuration)
    $issues = New-Object System.Collections.Generic.List[object]
    $expected = @{}
    foreach ($role in $script:MaRoles) { $expected[$Configuration.Worktrees[$role].ToUpperInvariant()] = $role }
    $registered = @{}
    foreach ($record in $Coordination.Worktrees) {
        $key = $record.Path.ToUpperInvariant()
        $registered[$key] = $record
        if ($record.Prunable) { $issues.Add((New-MaIssue 'MA_WORKTREE_PRUNABLE' -Path $record.Path)) }
        if (-not $expected.ContainsKey($key)) { $issues.Add((New-MaIssue 'MA_WORKTREE_UNEXPECTED' -Path $record.Path)); continue }
        $role = $expected[$key]
        foreach ($other in $script:MaRoles) {
            if ($other -ne $role -and $record.Branch -and [string]::Equals($record.Branch, $Configuration.Branches[$other], [StringComparison]::OrdinalIgnoreCase)) {
                $issues.Add((New-MaIssue 'MA_BRANCH_OCCUPIED' -Role $other -Path $record.Path))
            }
        }
    }
    foreach ($record in $Coordination.Worktrees) {
        if ($expected.ContainsKey($record.Path.ToUpperInvariant())) { continue }
        foreach ($role in $script:MaRoles) {
            if ($record.Branch -and [string]::Equals($record.Branch, $Configuration.Branches[$role], [StringComparison]::OrdinalIgnoreCase)) { $issues.Add((New-MaIssue 'MA_BRANCH_OCCUPIED' -Role $role -Path $record.Path)) }
        }
    }
    foreach ($environment in $Environments) {
        if ($environment.Role -eq 'coordination' -or -not $environment.IsRepository) { continue }
        if (-not $registered.ContainsKey($environment.Path.ToUpperInvariant())) { $issues.Add((New-MaIssue 'MA_WORKTREE_NOT_REGISTERED' -Role $environment.Role -Path $environment.Path)) }
        if ($environment.CommonDir -and $Coordination.CommonDir -and -not $environment.CommonDir.Equals($Coordination.CommonDir, [StringComparison]::OrdinalIgnoreCase)) {
            $issues.Add((New-MaIssue 'MA_ENV_COMMON_DIR_MISMATCH' -Role $environment.Role -Path $environment.Path))
        }
    }
    return , $issues.ToArray()
}

# --- Classificacao dos destinos governados ------------------------------------------

# Entrada do checkout para um caminho relativo. O sistema de arquivos do Windows
# localiza nomes sem distinguir caixa: cada componente e conferido com o nome
# gravado no diretorio pai, e uma grafia diferente resulta em CaseMismatch, com
# Actual (caminho como esta gravado), sem leitura do conteudo.
function Get-MaFilesystemEntry {
    param([string]$Root, [string]$RelativePath)
    $current = $Root
    $components = $RelativePath.Split('/')
    $actual = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $components.Length; $index++) {
        $parent = $current
        $current = [IO.Path]::Combine($current, $components[$index])
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) { return [pscustomobject]@{ Kind = 'Unsafe'; Bytes = $null } }
            return [pscustomobject]@{ Kind = 'Missing'; Bytes = $null }
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return [pscustomobject]@{ Kind = 'Unsafe'; Bytes = $null } }
        $stored = @([IO.Directory]::GetFileSystemEntries($parent) | ForEach-Object { [IO.Path]::GetFileName($_) } | Where-Object { $_.Equals($components[$index], [StringComparison]::OrdinalIgnoreCase) })
        if ($stored -ccontains $components[$index]) { $actual.Add($components[$index]) }
        elseif ($stored.Count -gt 0) { $actual.Add($stored[0]) }
        else { return [pscustomobject]@{ Kind = 'Unsafe'; Bytes = $null } }
        if ($index -lt $components.Length - 1 -and -not $item.PSIsContainer) { return [pscustomobject]@{ Kind = 'TypeConflict'; Bytes = $null } }
    }
    $actualPath = $actual -join '/'
    if ($actualPath -cne $RelativePath) { return [pscustomobject]@{ Kind = 'CaseMismatch'; Bytes = $null; Actual = $actualPath } }
    if ($item.PSIsContainer) { return [pscustomobject]@{ Kind = 'Directory'; Bytes = $null } }
    return [pscustomobject]@{ Kind = 'File'; Bytes = [IO.File]::ReadAllBytes($current) }
}

function Get-MaUnexpectedEntries {
    param([string]$Root, [string[]]$Expected)
    $found = New-Object System.Collections.Generic.List[string]
    $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in $Expected) { [void]$expectedSet.Add($path) }
    foreach ($directory in $script:MaExclusiveDirectories) {
        $entry = Get-MaFilesystemEntry $Root $directory
        if ($entry.Kind -eq 'Missing') { continue }
        if ($entry.Kind -eq 'CaseMismatch') { $found.Add($entry.Actual); continue }
        if ($entry.Kind -ne 'Directory') { $found.Add($directory); continue }
        $pending = New-Object System.Collections.Generic.Queue[string]
        $pending.Enqueue($directory)
        while ($pending.Count -gt 0) {
            $relative = $pending.Dequeue()
            foreach ($child in (Get-ChildItem -LiteralPath ([IO.Path]::Combine($Root, $relative.Replace('/', '\'))) -Force -ErrorAction Stop)) {
                $childPath = $relative + '/' + $child.Name
                $isLink = ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                if ($child.PSIsContainer -and -not $isLink) { $pending.Enqueue($childPath); continue }
                if ($isLink -or -not $expectedSet.Contains($childPath)) { $found.Add($childPath) }
            }
        }
    }
    return , $found.ToArray()
}

function Get-MaFileClassification {
    param($Environment, [object[]]$RenderedFiles)
    $results = New-Object System.Collections.Generic.List[object]
    $issues = New-Object System.Collections.Generic.List[object]
    $role = $Environment.Role
    # Checkout pendente: indice e checkout ainda nao existem; o HEAD e a referencia
    # e qualquer conteudo no checkout e divergente.
    $pendingCheckout = [bool]$Environment.CheckoutPending
    foreach ($file in $RenderedFiles) {
        $expectedId = Get-MaGitBlobId $file.Bytes $Environment.ObjectFormat
        $fs = Get-MaFilesystemEntry $Environment.Path $file.Path
        $treeEntries = @(); if ($Environment.Tree.ContainsKey($file.Path)) { $treeEntries = @($Environment.Tree[$file.Path]) }
        $indexEntries = @(); if ($Environment.Index.ContainsKey($file.Path)) { $indexEntries = @($Environment.Index[$file.Path]) }
        $reasons = New-Object System.Collections.Generic.List[string]
        $classification = $null
        if ($fs.Kind -in @('Unsafe', 'TypeConflict')) { $classification = 'Inseguro'; $reasons.Add('link, junction ou componente intermediario nao diretorio') }
        else {
            if ($fs.Kind -eq 'CaseMismatch') { $reasons.Add('checkout: grafia divergente por caixa (' + $fs.Actual + ')') }
            elseif ($fs.Kind -eq 'Directory') { $reasons.Add('checkout: diretorio no lugar de arquivo') }
            elseif ($pendingCheckout -and $fs.Kind -eq 'File') { $reasons.Add('checkout pendente: arquivo presente antes do checkout') }
            elseif ($fs.Kind -eq 'File' -and -not (Test-MaBytesEqual $fs.Bytes $file.Bytes)) { $reasons.Add('checkout: bytes divergentes') }
            foreach ($entry in $treeEntries) {
                if ($entry.Type -cne 'blob' -or $entry.Mode -cne $file.GitMode) { $reasons.Add('HEAD: tipo ou modo ' + $entry.Mode + ' ' + $entry.Type) }
                elseif ($entry.ObjectId -cne $expectedId) { $reasons.Add('HEAD: blob divergente') }
            }
            if ($indexEntries.Count -gt 1) { $reasons.Add('indice: conflito de mesclagem') }
            foreach ($entry in $indexEntries) {
                if ($entry.Mode -cne $file.GitMode) { $reasons.Add('indice: modo ' + $entry.Mode) }
                elseif ($entry.ObjectId -cne $expectedId) { $reasons.Add('indice: blob divergente') }
            }
            if ($reasons.Count -gt 0) { $classification = 'Conflitante' }
            elseif ($pendingCheckout -and $treeEntries.Count -eq 0) { $classification = 'Ausente' }
            elseif ($pendingCheckout) { $classification = 'Identico'; $reasons.Add('checkout pendente: conferido no HEAD') }
            elseif ($fs.Kind -eq 'Missing' -and $treeEntries.Count -eq 0 -and $indexEntries.Count -eq 0) { $classification = 'Ausente' }
            elseif ($fs.Kind -eq 'Missing') { $classification = 'Conflitante'; $reasons.Add('removido do checkout') }
            elseif (-not $Environment.IsRepository -or -not $Environment.Inspected) { $classification = 'Identico' }
            elseif ($treeEntries.Count -eq 1 -and $indexEntries.Count -eq 1) { $classification = 'Identico' }
            elseif ($treeEntries.Count -eq 1) { $classification = 'Conflitante'; $reasons.Add('removido do indice') }
            elseif ($role -eq 'maintenance') { $classification = 'PreparadoNaoCommitado' }
            else { $classification = 'Conflitante'; $reasons.Add('arquivo governado nao commitado fora da manutencao') }
            # Igualdade de identificador so vale com o objeto lido e conferido.
            $unverified = New-Object System.Collections.Generic.List[string]
            foreach ($pair in @(@('HEAD', $treeEntries), @('indice', $indexEntries))) {
                foreach ($entry in @($pair[1])) {
                    if ($entry.Mode -ceq '160000' -or $entry.Type -ceq 'commit') { continue }
                    $status = 'NaoVerificado'
                    if ($Environment.Objects.ContainsKey($entry.ObjectId)) { $status = $Environment.Objects[$entry.ObjectId] }
                    if ($status -cne 'Ok') { $unverified.Add($pair[0] + ': objeto ' + $status) }
                }
            }
            if ($unverified.Count -gt 0) {
                foreach ($reason in $unverified) { $reasons.Add($reason) }
                if ($classification -cne 'Conflitante') { $classification = 'Inconclusivo' }
            }
        }
        $results.Add([pscustomobject]@{ Role = $role; Path = $file.Path; Classification = $classification; Reason = ($reasons -join '; '); ExpectedSha256 = $file.Sha256; ExpectedMode = $file.GitMode; ExpectedObjectId = $expectedId })
        if ($classification -eq 'Inseguro') { $issues.Add((New-MaIssue 'MA_FILE_UNSAFE' -Role $role -Path $file.Path)) }
        elseif ($classification -eq 'Conflitante') { $issues.Add((New-MaIssue 'MA_FILE_CONFLICT' -Role $role -Path $file.Path -Detail ($reasons -join '; '))) }
    }
    $expectedPaths = @($RenderedFiles | ForEach-Object { $_.Path })
    $fsUnexpected = Get-MaUnexpectedEntries $Environment.Path $expectedPaths
    $gitUnexpected = @(@($Environment.Tree.Keys) + @($Environment.Index.Keys) | Where-Object { $expectedPaths -cnotcontains $_ } | Sort-Object -Unique -CaseSensitive)
    foreach ($path in (@($fsUnexpected) + @($gitUnexpected) | Sort-Object -Unique -CaseSensitive)) { $issues.Add((New-MaIssue 'MA_FILE_UNEXPECTED_ENTRY' -Role $role -Path $path)) }
    return [pscustomobject]@{ Files = $results.ToArray(); Issues = $issues.ToArray() }
}

# --- Plan --------------------------------------------------------------------------

function Test-MaFullCommit {
    param([string]$Value)
    return ($Value -cmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z')
}

function ConvertTo-MaConfigurationSummary {
    param($Configuration)
    if ($null -eq $Configuration) { return $null }
    return [pscustomobject]@{ Name = $Configuration.Name; Slug = $Configuration.Slug; RepositoryUrl = $Configuration.RepositoryUrl; ParentDirectory = $Configuration.ParentDirectory; Branches = $Configuration.Branches; Worktrees = $Configuration.Worktrees }
}

function ConvertTo-MaEnvironmentSummary {
    param([object[]]$Environments)
    foreach ($environment in @($Environments | Where-Object { $null -ne $_ })) {
        [pscustomobject]@{ Role = $environment.Role; Path = $environment.Path; ExpectedBranch = $environment.ExpectedBranch; State = $environment.State; Branch = $environment.Branch; Head = $environment.Head; HooksPath = $environment.HooksPath; DefaultHooks = $environment.DefaultHooks; AuxiliaryHookFiles = $environment.AuxiliaryHookFiles; CheckoutPending = $environment.CheckoutPending }
    }
}

function Get-MaPlanStatus {
    param([object[]]$Issues, [bool]$Incomplete)
    if (@($Issues | Where-Object { $_.Severity -eq 'Falha' }).Count -gt 0) { return 'Falha' }
    if (@($Issues | Where-Object { $_.Severity -eq 'Bloqueio' }).Count -gt 0) { return 'Bloqueado' }
    if ($Incomplete) { return 'Incompleto' }
    return 'Sucesso'
}

# Estado apurado pela inspecao comum, preenchido progressivamente: numa excecao,
# o chamador conserva o que ja foi apurado.
function New-MaInspectionState {
    return [pscustomobject]@{
        Issues          = (New-Object System.Collections.Generic.List[object])
        Pending         = (New-Object System.Collections.Generic.List[string])
        Files           = (New-Object System.Collections.Generic.List[object])
        Package         = $null
        Configuration   = $null
        Git             = $null
        Rendered        = $null
        Environments    = @()
        BaseCommitLocal = $null
    }
}

# Inspecao comum as fases, somente leitura: pacote, configuracao, Git,
# renderizacao em memoria, ambientes, alcance, destinos e presenca local do
# BaseCommit. Sem fetch, clone, temporarios ou gravacao.
function Invoke-MaInspection {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$BaseCommit = '',
        [string]$IntegratedCommit = '',
        [string]$FallbackCode = 'MA_PLAN_UNEXPECTED_FAILURE'
    )
    $issues = $State.Issues
    $pending = $State.Pending
    $files = $State.Files
    # 1. Pacote confiavel.
    $package = Test-MaPackageIntegrity $PackageRoot
    $State.Package = $package
    foreach ($issue in $package.Issues) { $issues.Add($issue) }
    # Hashes conferidos: esquema e templates sao usados somente se os bytes lidos
    # depois continuarem iguais aos verificados.
    $verifiedHashes = $null
    if ($package.Valid) {
        $verifiedHashes = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $package.Files) { $verifiedHashes[$file.Path] = $file.ActualHash }
    }

    # 2. Configuracao e padroes.
    $configuration = $null
    try {
        $schemaPath = [IO.Path]::Combine($PackageRoot, 'schema', 'project.schema.json')
        $schemaHash = ''
        if ($null -ne $verifiedHashes) { $schemaHash = [string]$verifiedHashes['schema/project.schema.json'] }
        $configuration = Read-MaConfiguration -LiteralPath $ConfigPath -SchemaPath $schemaPath -SchemaSha256 $schemaHash
        if (-not [IO.Path]::GetFileName($configuration.ConfigPath).Equals($script:MaExpectedConfigName, [StringComparison]::OrdinalIgnoreCase)) {
            $issues.Add((New-MaIssue 'MA_CONFIG_NAME_UNEXPECTED' -Severity 'Aviso' -Path $configuration.ConfigPath))
        }
        $packagePath = [IO.Path]::GetFullPath($PackageRoot)
        foreach ($role in $script:MaRoles) {
            $destination = $configuration.Worktrees[$role]
            if ((Test-MaPathWithin $packagePath $destination) -or (Test-MaPathWithin $destination $packagePath)) { $issues.Add((New-MaIssue 'MA_PACKAGE_INSIDE_WORKTREE' -Role $role -Path $destination)) }
        }
    } catch {
        $issues.Add((New-MaIssue (Get-MaErrorCode $_ $FallbackCode) -Path $ConfigPath))
        $configuration = $null
    }
    $State.Configuration = $configuration

    foreach ($pair in @(@('BaseCommit', $BaseCommit), @('IntegratedCommit', $IntegratedCommit))) {
        if ($pair[1] -and -not (Test-MaFullCommit $pair[1])) { $issues.Add((New-MaIssue 'MA_COMMIT_FORMAT_INVALID' -Detail $pair[0])) }
    }
    if ($null -eq $configuration) { return }

    # 3. Git, ambiente de processo e validacao das branches pelo proprio Git.
    foreach ($issue in (Get-MaGitOverrideIssues)) { $issues.Add($issue) }
    $git = Get-MaGitContext -WorkingDirectory $configuration.ParentDirectory
    $gitContext = $git.Context
    $State.Git = $gitContext
    foreach ($issue in $git.Issues) { $issues.Add($issue) }
    if ($gitContext.Available) { foreach ($issue in (Test-MaBranchesWithGit $configuration.Branches $configuration.ParentDirectory)) { $issues.Add($issue) } }

    # 4. Renderizacao em memoria, somente a partir de pacote integro.
    $rendered = $null
    if ($package.Valid) {
        try {
            $rendered = Get-MaRenderedFiles -PackageRoot $PackageRoot -Configuration $configuration -DistributionVersion $package.DistributionVersion -VerifiedHashes $verifiedHashes
        } catch { $issues.Add((New-MaIssue (Get-MaErrorCode $_ $FallbackCode))) }
    } else { $pending.Add('Renderizacao e classificacao dos destinos nao executadas: pacote sem integridade comprovada.') }
    $State.Rendered = $rendered

    # 5. Ambientes, alcance e destinos.
    $environments = @(foreach ($role in $script:MaRoles) { Get-MaEnvironmentInspection -Role $role -Configuration $configuration -GitAvailable ([bool]$gitContext.Available) })
    $State.Environments = $environments
    foreach ($environment in $environments) { foreach ($issue in $environment.Issues) { $issues.Add($issue) } }
    $coordination = $environments[0]
    if ($coordination.Inspected) { foreach ($issue in (Get-MaWorktreeScopeIssues $coordination $environments $configuration)) { $issues.Add($issue) } }
    elseif (@($environments | Where-Object { $_.Role -ne 'coordination' -and $_.Exists }).Count -gt 0 -and -not $coordination.Exists) {
        foreach ($environment in @($environments | Where-Object { $_.Role -ne 'coordination' -and $_.IsRepository })) { $issues.Add((New-MaIssue 'MA_WORKTREE_NOT_REGISTERED' -Role $environment.Role -Path $environment.Path)) }
    }
    if ($null -ne $rendered) {
        foreach ($environment in $environments) {
            if (-not $environment.Exists -or $environment.State -in @('Inseguro', 'VazioSemRepositorio') -or -not [IO.Directory]::Exists($environment.Path)) { continue }
            $classified = Get-MaFileClassification $environment $rendered
            foreach ($file in $classified.Files) { $files.Add($file) }
            foreach ($issue in $classified.Issues) { $issues.Add($issue) }
        }
    }

    # BaseCommit: presenca local, sem fetch.
    if ($BaseCommit -and (Test-MaFullCommit $BaseCommit) -and $coordination.Inspected) {
        $base = Invoke-MaGit $coordination.Path @('cat-file', '-e', ($BaseCommit + '^{commit}'))
        $State.BaseCommitLocal = ($base.ExitCode -eq 0)
    }
}

function Invoke-MaPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$AuthorizationReference = '',
        [string]$BaseCommit = '',
        [string]$IntegratedCommit = '',
        [string]$IntegrationReference = '',
        [switch]$WhatIfRequested
    )
    $inspection = New-MaInspectionState
    $issues = $inspection.Issues
    $actions = New-Object System.Collections.Generic.List[object]
    $pending = $inspection.Pending
    $files = $inspection.Files
    $incomplete = $false
    $evidence = [ordered]@{
        AuthorizationReference = $(if ($AuthorizationReference) { 'fornecida; nao verificada (Plan nao infere aprovacao)' } else { 'nao fornecida' })
        BaseCommit             = $(if ($BaseCommit) { 'fornecido; pendente de conferencia' } else { 'nao fornecido' })
        IntegratedCommit       = $(if ($IntegratedCommit) { 'fornecido; nao utilizado no Plan' } else { 'nao fornecido' })
        IntegrationReference   = $(if ($IntegrationReference) { 'fornecida; nao verificada' } else { 'nao fornecida' })
    }
    $addAction = {
        param([string]$Phase, [string]$Role, [string]$Description)
        $actions.Add([pscustomobject]@{ Order = $actions.Count + 1; Phase = $Phase; Role = $Role; Description = $Description })
    }
    try {
        # 1 a 5. Pacote, configuracao, Git, renderizacao, ambientes e destinos.
        Invoke-MaInspection -State $inspection -ConfigPath $ConfigPath -PackageRoot $PackageRoot -BaseCommit $BaseCommit -IntegratedCommit $IntegratedCommit
        $configuration = $inspection.Configuration
        if ($inspection.BaseCommitLocal -eq $true) { $evidence.BaseCommit = 'presente localmente como commit; autorizacao nao verificada' }
        elseif ($inspection.BaseCommitLocal -eq $false) { $issues.Add((New-MaIssue 'MA_BASECOMMIT_NOT_LOCAL' -Severity 'Aviso' -Role 'coordination')) }

        if ($null -ne $configuration) {
            $environments = $inspection.Environments
            # 6. Acoes previstas (nenhuma executada nesta fase).
            $byRole = @{}; foreach ($environment in $environments) { $byRole[$environment.Role] = $environment }
            if (-not $byRole.coordination.Exists -or $byRole.coordination.State -eq 'VazioSemRepositorio') {
                & $addAction 'PrepareMaintenance' 'coordination' ('Clonar origin em ' + $configuration.Worktrees.coordination + ' (branch ' + $configuration.Branches.coordination + ').')
                $incomplete = $true
                $pending.Add('Conteudo do repositorio remoto desconhecido sem clone: conflitos (inclusive README criado pelo servidor) so poderao ser classificados apos o clone.')
            }
            foreach ($environment in @($environments | Where-Object { $_.CheckoutPending })) {
                & $addAction 'PrepareMaintenance' $environment.Role ('Concluir o checkout pendente de ' + $environment.Path + ' somente se nenhum filtro, hook, submodulo ou origem alternativa de atributos se aplicar.')
                $incomplete = $true
            }
            if (-not $byRole.maintenance.Exists -or $byRole.maintenance.State -eq 'VazioSemRepositorio') {
                & $addAction 'PrepareMaintenance' 'maintenance' ('Criar worktree ' + $configuration.Worktrees.maintenance + ' na branch ' + $configuration.Branches.maintenance + ' a partir do BaseCommit autorizado, sem reposicionar branch existente.')
                & $addAction 'PrepareMaintenance' 'maintenance' 'Gerar os onze arquivos governados na manutencao, somente se todos os destinos forem ausentes ou identicos.'
            } else {
                foreach ($file in @($files | Where-Object { $_.Role -eq 'maintenance' -and $_.Classification -eq 'Ausente' })) {
                    & $addAction 'PrepareMaintenance' 'maintenance' ('Gerar ' + $file.Path + ' (' + $file.ExpectedMode + ').')
                }
            }
            foreach ($role in @('codex', 'claude')) {
                if (-not $byRole[$role].Exists -or $byRole[$role].State -eq 'VazioSemRepositorio') {
                    & $addAction 'CompleteWorktrees' $role ('Criar worktree ' + $configuration.Worktrees[$role] + ' na branch ' + $configuration.Branches[$role] + ' a partir do commit integrado comprovado.')
                }
            }
            & $addAction 'CompleteWorktrees' '' 'Verificar core.hooksPath efetivo nos quatro worktrees e inserir .githooks somente se a politica e a autorizacao abrangente permitirem.'
            & $addAction 'Fora do instalador' '' 'Preparacao do indice, commit, push, PR, revisao cruzada, merge humano e sincronizacao da coordenacao.'
        }

        $pending.Add('Estado remoto, protecao de branches e PRs nao verificados: Plan nao realiza fetch nem acesso remoto.')
        $pending.Add('Autorizacao humana nao verificada pelo instalador; referencias sao registradas apenas como evidencia fornecida.')
        $pending.Add('Configuracao efetiva de hooks sera conferida em CompleteWorktrees, por worktree e camada, antes de qualquer ativacao.')
        $pending.Add('Origem confiavel do pacote nao comprovada pelo manifesto; modos Git do pacote nao conferidos no indice de origem.')
        if (-not $BaseCommit) { $pending.Add('BaseCommit completo exigido para PrepareMaintenance.') }
        if (-not $AuthorizationReference) { $pending.Add('AuthorizationReference exigida para PrepareMaintenance (registrada como evidencia, sem inferir aprovacao).') }
    } catch {
        $issues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PLAN_UNEXPECTED_FAILURE') -Severity 'Falha' -Detail (Get-MaErrorDetail $_)))
    }
    $issueArray = $issues.ToArray()
    $status = Get-MaPlanStatus $issueArray $incomplete
    return [pscustomobject]@{
        Phase         = 'Plan'
        Status        = $status
        WhatIf        = [bool]$WhatIfRequested
        Modified      = $false
        Package       = $inspection.Package
        Configuration = (ConvertTo-MaConfigurationSummary $inspection.Configuration)
        Git           = $inspection.Git
        Environments  = @(ConvertTo-MaEnvironmentSummary $inspection.Environments)
        Files         = $files.ToArray()
        Actions       = $actions.ToArray()
        Issues        = $issueArray
        Pending       = $pending.ToArray()
        Evidence      = [pscustomobject]$evidence
    }
}

function Format-MaPlanReport {
    param([Parameter(Mandatory = $true)]$Plan)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Fase: ' + $Plan.Phase)
    $lines.Add('Resultado: ' + $Plan.Status)
    if ($Plan.WhatIf) { $lines.Add('WhatIf: sem efeito adicional; Plan nao executa operacoes mutaveis.') }
    if ($null -ne $Plan.Package) {
        $integrity = 'invalida'; if ($Plan.Package.Valid) { $integrity = 'valida' }
        $lines.Add('Pacote: versao ' + [string]$Plan.Package.DistributionVersion + '; integridade ' + $integrity + ' (nao comprova origem).')
    }
    if ($null -ne $Plan.Configuration) {
        $lines.Add('Projeto: ' + $Plan.Configuration.Slug + ' | repositorio: ' + $Plan.Configuration.RepositoryUrl)
        $lines.Add('Diretorio pai: ' + $Plan.Configuration.ParentDirectory)
    }
    if ($null -ne $Plan.Git) { $lines.Add('Git: ' + [string]$Plan.Git.Path + ' ' + [string]$Plan.Git.Version + ' | sh: ' + [string]$Plan.Git.Shell) }
    if (@($Plan.Environments).Count -gt 0) {
        $lines.Add(''); $lines.Add('Ambientes:')
        foreach ($environment in $Plan.Environments) { $lines.Add('  [' + $environment.Role + '] ' + $environment.Path + ' | branch ' + $environment.ExpectedBranch + ' | ' + $environment.State) }
    }
    if (@($Plan.Files).Count -gt 0) {
        $lines.Add(''); $lines.Add('Destinos governados:')
        foreach ($file in $Plan.Files) {
            $line = '  [' + $file.Role + '] ' + $file.Path + ' | ' + $file.Classification
            if ($file.Reason) { $line += ' | ' + $file.Reason }
            $lines.Add($line)
        }
    }
    if (@($Plan.Actions).Count -gt 0) {
        $lines.Add(''); $lines.Add('Acoes previstas (nenhuma executada):')
        foreach ($action in $Plan.Actions) {
            $prefix = '  ' + $action.Order + '. [' + $action.Phase + ']'
            if ($action.Role) { $prefix += ' [' + $action.Role + ']' }
            $lines.Add($prefix + ' ' + $action.Description)
        }
    }
    foreach ($group in @(@('Falha', 'Falhas operacionais:'), @('Bloqueio', 'Impedimentos:'), @('Aviso', 'Avisos:'))) {
        $selected = @($Plan.Issues | Where-Object { $_.Severity -eq $group[0] })
        if ($selected.Count -eq 0) { continue }
        $lines.Add(''); $lines.Add($group[1])
        foreach ($issue in $selected) {
            $line = '  - ' + $issue.Code + ': ' + $issue.Message
            $where = @(@($issue.Role, $issue.Path, $issue.Detail) | Where-Object { $_ })
            if ($where.Count -gt 0) { $line += ' (' + ($where -join ' | ') + ')' }
            $lines.Add($line)
        }
    }
    $lines.Add(''); $lines.Add('Evidencias:')
    foreach ($property in $Plan.Evidence.PSObject.Properties) { $lines.Add('  ' + $property.Name + ': ' + $property.Value) }
    if (@($Plan.Pending).Count -gt 0) {
        $lines.Add(''); $lines.Add('Verificacoes pendentes:')
        foreach ($item in $Plan.Pending) { $lines.Add('  - ' + $item) }
    }
    $lines.Add(''); $lines.Add('Nenhuma modificacao foi realizada.')
    return , $lines.ToArray()
}

function Get-MaExitCode {
    param([string]$Status)
    switch ($Status) { 'Sucesso' { return 0 } 'Incompleto' { return 2 } 'Bloqueado' { return 3 } default { return 4 } }
}

# --- Abertura vinculada a handles (sistema de arquivos) ----------------------------
# Verificar um caminho e depois abri-lo pelo nome deixa uma janela em que outro
# processo troca um componente por link ou junction. As operacoes mutaveis nao
# resolvem caminhos depois da validacao:
#   - NtCreateFile abre um unico componente por vez, relativo ao handle do
#     diretorio pai (OBJECT_ATTRIBUTES.RootDirectory), com FILE_OPEN_REPARSE_POINT:
#     um ponto de reparse e aberto como ele proprio, nunca seguido, e recusado
#     pelos atributos lidos do proprio handle (FileAttributeTagInfo).
#   - Cada diretorio aberto permanece aberto, com acesso de leitura e
#     compartilhamento de leitura e escrita, sem FILE_SHARE_DELETE: enquanto o
#     handle existir, nenhum processo obtem acesso DELETE ao diretorio, logo nao o
#     renomeia, exclui nem o substitui. A cadeia vai da raiz da unidade ao destino.
#   - Diretorios e arquivos ausentes sao criados com FILE_CREATE relativo ao pai
#     fixado: a criacao falha se qualquer entrada surgir com o nome, sem sobrescrever.
#   - Bytes gravados sao conferidos pelo mesmo handle.
# Para operacoes Git, que resolvem caminhos por conta propria, a garantia e a
# possivel sem substituir o Git: a cadeia ate o destino e o proprio destino ficam
# fixados durante a operacao e o primeiro nivel do destino e conferido depois.
# Limitacoes: o que o Git grava dentro do destino segue a resolucao do proprio Git;
# um link criado ali por outro processo durante a operacao e detectado depois, nao
# impedido. A letra da unidade e resolvida uma vez, na abertura da raiz
# (DefineDosDevice/subst nao sao tratados como redirecionamento). NtCreateFile e
# documentado em winternl.h e pode mudar em versoes futuras do Windows.

$script:MaFileConstants = @{
    # FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE
    AccessDirectory     = [uint32]0x001000A1
    # FILE_GENERIC_READ | FILE_GENERIC_WRITE
    AccessFile          = [uint32]0x0012019F
    # DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE
    AccessDelete        = [uint32]0x00110080
    ShareNone           = [uint32]0
    ShareReadWrite      = [uint32]3
    DispositionOpen     = [uint32]1
    DispositionCreate   = [uint32]2
    OptionDirectory     = 0x00000001
    OptionSynchronous   = 0x00000020
    OptionNonDirectory  = 0x00000040
    OptionOpenReparse   = 0x00200000
    ObjCaseInsensitive  = 0x00000040
    AttributeDirectory  = 0x00000010
    AttributeNormal     = [uint32]0x00000080
    AttributeReparse    = 0x00000400
    InfoDisposition     = 4
    InfoAttributeTag    = 9
    InfoFullDirectory   = 14
    InfoFullDirectoryRestart = 15
    InfoId              = 18
    ErrorFileNotFound   = 2
    ErrorNoMoreFiles    = 18
    StatusAccessDenied  = [int]0xC0000022
    StatusNameNotFound  = [int]0xC0000034
    StatusNameCollision = [int]0xC0000035
    StatusPathNotFound  = [int]0xC000003A
    StatusSharing       = [int]0xC0000043
    StatusNotDirectory  = [int]0xC0000103
    StatusIsDirectory   = [int]0xC00000BA
}

function Get-MaFileApi {
    if ($script:MaFileApi -is [bool]) { throw 'MA_PATH_HANDLE_UNAVAILABLE' }
    if ($null -ne $script:MaFileApi) { return $script:MaFileApi }
    $p = [IntPtr]; $u = [uint32]
    $definitions = @(
        @('NtCreateFile', [int], @($p, $u, $p, $p, $p, $u, $u, $u, $u, $p, $u), 'ntdll.dll'),
        @('GetFileInformationByHandleEx', [bool], @($p, [int], $p, $u)),
        @('SetFileInformationByHandle', [bool], @($p, [int], $p, $u)),
        @('CloseHandle', [bool], @($p))
    )
    try { $script:MaFileApi = New-MaEmittedApi 'MaNativeFile' 'MaNativeFile.Api' $definitions }
    catch { $script:MaFileApi = $false; throw 'MA_PATH_HANDLE_UNAVAILABLE' }
    return $script:MaFileApi
}

# Codigo como mensagem e NTSTATUS no detalhe (Data['Stage']).
function New-MaFileError {
    param([string]$Code, [int]$Status = 0)
    $exception = New-Object System.Exception $Code
    if ($Status -ne 0) { $exception.Data['Stage'] = 'NTSTATUS 0x' + $Status.ToString('X8') }
    return $exception
}

# Como Close-MaNativeHandle: fecha uma unica vez, nunca lanca e devolve $null ou
# o descritor da falha.
function Close-MaFileHandle {
    param([IntPtr]$Handle, [string]$Name)
    if ($Handle -eq [IntPtr]::Zero) { return $null }
    try {
        $api = Get-MaFileApi
        if ([bool]$api::CloseHandle($Handle)) { return $null }
        return ($Name + ':MA_NATIVE_CLOSE_FAILED:' + $api::LastError)
    } catch { return ($Name + ':' + $_.Exception.Message + ':0') }
}

# NtCreateFile de um unico componente relativo ao handle Parent ou, com Parent
# zero, da raiz de unidade em forma NT (\??\X:\). Devolve Status (NTSTATUS) e
# Handle (zero se Status nao for STATUS_SUCCESS).
function Invoke-MaFileCreate {
    param([IntPtr]$Parent, [Parameter(Mandatory = $true)][string]$Name, [uint32]$Access, [uint32]$Share, [uint32]$Disposition, [uint32]$Options, [uint32]$Attributes = 0)
    if ($Parent -eq [IntPtr]::Zero) { if ($Name -cnotmatch '\A\\\?\?\\[A-Za-z]:\\\z') { throw 'MA_PATH_LOCAL_ABSOLUTE_REQUIRED' } }
    elseif (-not (Test-MaWindowsComponent $Name)) { throw 'MA_PATH_COMPONENT_UNSAFE' }
    $api = Get-MaFileApi
    $marshal = [System.Runtime.InteropServices.Marshal]
    $pointer = [IntPtr]::Size
    $memory = New-Object System.Collections.Generic.List[IntPtr]
    try {
        $buffer = $marshal::StringToHGlobalUni($Name); $memory.Add($buffer)
        # UNICODE_STRING: Length, MaximumLength (bytes) e Buffer no deslocamento de um ponteiro.
        $unicode = New-MaNativeZeroMemory (2 * $pointer); $memory.Add($unicode)
        $marshal::WriteInt16($unicode, 0, [int16](2 * $Name.Length))
        $marshal::WriteInt16($unicode, 2, [int16](2 * $Name.Length + 2))
        $marshal::WriteIntPtr($unicode, $pointer, $buffer)
        # OBJECT_ATTRIBUTES: Length, RootDirectory, ObjectName, Attributes, SD e SQOS,
        # um campo por ponteiro (x64: 48 bytes; x86: 24).
        $objectAttributes = New-MaNativeZeroMemory (6 * $pointer); $memory.Add($objectAttributes)
        $marshal::WriteInt32($objectAttributes, 0, 6 * $pointer)
        $marshal::WriteIntPtr($objectAttributes, $pointer, $Parent)
        $marshal::WriteIntPtr($objectAttributes, 2 * $pointer, $unicode)
        $marshal::WriteInt32($objectAttributes, 3 * $pointer, $script:MaFileConstants.ObjCaseInsensitive)
        $ioStatus = New-MaNativeZeroMemory (2 * $pointer); $memory.Add($ioStatus)
        $cell = New-MaNativeZeroMemory $pointer; $memory.Add($cell)
        $status = [int]$api::NtCreateFile($cell, $Access, $objectAttributes, $ioStatus, [IntPtr]::Zero, $Attributes, $Share, $Disposition, $Options, [IntPtr]::Zero, [uint32]0)
        $handle = $marshal::ReadIntPtr($cell, 0)
        if ($status -ne 0 -and $handle -ne [IntPtr]::Zero) {
            $closeFailure = Close-MaFileHandle $handle 'Create'
            $handle = [IntPtr]::Zero
            if ($null -ne $closeFailure) { throw (New-MaFileError 'MA_NATIVE_CLEANUP_FAILED' $status) }
        }
        return [pscustomobject]@{ Status = $status; Handle = $handle }
    } finally { foreach ($block in $memory) { $marshal::FreeHGlobal($block) } }
}

# FileAttributes lidos do proprio handle (FILE_ATTRIBUTE_TAG_INFO).
function Get-MaFileAttributes {
    param([IntPtr]$Handle)
    $api = Get-MaFileApi
    $info = New-MaNativeZeroMemory 8
    try {
        if (-not $api::GetFileInformationByHandleEx($Handle, $script:MaFileConstants.InfoAttributeTag, $info, [uint32]8)) { throw 'MA_PATH_INSPECTION_FAILED' }
        return [System.Runtime.InteropServices.Marshal]::ReadInt32($info, 0)
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info) }
}

# Identidade do objeto aberto: numero de serie do volume e FileId de 128 bits
# (FILE_ID_INFO), em hexadecimal. Nao depende da grafia do caminho.
function Get-MaFileIdentity {
    param([IntPtr]$Handle)
    $api = Get-MaFileApi
    $info = New-MaNativeZeroMemory 24
    try {
        if (-not $api::GetFileInformationByHandleEx($Handle, $script:MaFileConstants.InfoId, $info, [uint32]24)) { throw 'MA_PATH_INSPECTION_FAILED' }
        $bytes = New-Object byte[] 24
        [System.Runtime.InteropServices.Marshal]::Copy($info, $bytes, 0, 24)
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info) }
}

# Entradas (Name, Attributes) de um diretorio aberto, sem . e .., lidas pelo
# handle (FILE_FULL_DIR_INFO), sem resolver caminhos.
function Get-MaDirectoryEntries {
    param([IntPtr]$Handle)
    $api = Get-MaFileApi
    $c = $script:MaFileConstants
    $marshal = [System.Runtime.InteropServices.Marshal]
    $size = 65536
    $entries = New-Object System.Collections.Generic.List[object]
    $buffer = $marshal::AllocHGlobal($size)
    try {
        $class = $c.InfoFullDirectoryRestart
        while ($true) {
            if (-not $api::GetFileInformationByHandleEx($Handle, $class, $buffer, [uint32]$size)) {
                if ($api::LastError -in @($c.ErrorNoMoreFiles, $c.ErrorFileNotFound)) { break }
                throw 'MA_PATH_INSPECTION_FAILED'
            }
            $class = $c.InfoFullDirectory
            $offset = 0
            while ($true) {
                $next = $marshal::ReadInt32($buffer, $offset)
                $attributes = $marshal::ReadInt32($buffer, $offset + 56)
                $length = $marshal::ReadInt32($buffer, $offset + 60)
                $name = $marshal::PtrToStringUni([IntPtr]::Add($buffer, $offset + 68), [int]($length / 2))
                if ($name -cne '.' -and $name -cne '..') { $entries.Add([pscustomobject]@{ Name = $name; Attributes = $attributes }) }
                if ($next -eq 0) { break }
                $offset += $next
            }
        }
    } finally { $marshal::FreeHGlobal($buffer) }
    return , $entries.ToArray()
}

# Nomes das entradas de primeiro nivel que sao pontos de reparse.
function Get-MaReparseEntries {
    param([IntPtr]$Handle)
    $reparse = $script:MaFileConstants.AttributeReparse
    $names = New-Object System.Collections.Generic.List[string]
    $entries = Get-MaDirectoryEntries $Handle
    foreach ($entry in $entries) { if (($entry.Attributes -band $reparse) -ne 0) { $names.Add($entry.Name) } }
    return , $names.ToArray()
}

# Abre um diretorio pelo nome de um unico componente relativo ao handle Parent
# (ou a raiz da unidade), sem seguir ponto de reparse, com compartilhamento de
# leitura e escrita e sem FILE_SHARE_DELETE (ver o inicio desta secao). Com
# CreateMissing, cria o diretorio ausente com FILE_CREATE. Devolve Handle e
# Created; lanca MA_PATH_NOT_FOUND, MA_PATH_DIRECTORY_REQUIRED (entrada nao
# diretorio), MA_PATH_REPARSE_POINT, MA_PATH_PIN_FAILED (em uso com acesso de
# exclusao ou acesso negado), MA_PREPARE_TARGET_CHANGED (nome surgido durante a
# criacao) ou MA_PATH_INSPECTION_FAILED, com o NTSTATUS no detalhe.
function Open-MaPinnedDirectory {
    param([IntPtr]$Parent, [Parameter(Mandatory = $true)][string]$Name, [switch]$CreateMissing)
    $c = $script:MaFileConstants
    $options = [uint32]($c.OptionDirectory -bor $c.OptionSynchronous -bor $c.OptionOpenReparse)
    $created = $false
    $result = Invoke-MaFileCreate $Parent $Name $c.AccessDirectory $c.ShareReadWrite $c.DispositionOpen $options
    if ($CreateMissing -and $result.Status -eq $c.StatusNameNotFound) {
        $result = Invoke-MaFileCreate $Parent $Name $c.AccessDirectory $c.ShareReadWrite $c.DispositionCreate $options
        if ($result.Status -eq $c.StatusNameCollision) { throw (New-MaFileError 'MA_PREPARE_TARGET_CHANGED' $result.Status) }
        $created = ($result.Status -eq 0)
    }
    if ($result.Status -ne 0) {
        $code = 'MA_PATH_INSPECTION_FAILED'
        if ($result.Status -in @($c.StatusNameNotFound, $c.StatusPathNotFound)) { $code = 'MA_PATH_NOT_FOUND' }
        elseif ($result.Status -eq $c.StatusNotDirectory) { $code = 'MA_PATH_DIRECTORY_REQUIRED' }
        elseif ($result.Status -in @($c.StatusSharing, $c.StatusAccessDenied)) { $code = 'MA_PATH_PIN_FAILED' }
        throw (New-MaFileError $code $result.Status)
    }
    $attributes = $null
    try { $attributes = Get-MaFileAttributes $result.Handle } catch { $attributes = $null }
    if ($null -eq $attributes -or ($attributes -band $c.AttributeReparse) -ne 0 -or ($attributes -band $c.AttributeDirectory) -eq 0) {
        $closeFailure = Close-MaFileHandle $result.Handle 'Directory'
        $code = 'MA_PATH_REPARSE_POINT'; if ($null -eq $attributes) { $code = 'MA_PATH_INSPECTION_FAILED' }
        $failure = New-MaFileError $code
        Add-MaNativeCleanupFailure $failure @($closeFailure)
        throw $failure
    }
    return [pscustomobject]@{ Handle = $result.Handle; Created = $created }
}

# Cadeia de diretorios fixados: Handles abertos por esta cadeia e Leaf, o handle
# do ultimo componente (ou o pai informado, se nenhum foi aberto ainda).
function New-MaPinnedChain {
    param([string]$Path, [IntPtr]$Parent = [IntPtr]::Zero)
    return [pscustomobject]@{ Path = $Path; Handles = (New-Object System.Collections.Generic.List[IntPtr]); Leaf = $Parent }
}

function Add-MaPinnedComponent {
    param([Parameter(Mandatory = $true)]$Chain, [Parameter(Mandatory = $true)][string]$Name, [switch]$CreateMissing)
    $next = Open-MaPinnedDirectory $Chain.Leaf $Name -CreateMissing:$CreateMissing
    $Chain.Handles.Add($next.Handle)
    $Chain.Leaf = $next.Handle
    return $next.Created
}

# Fecha os handles da cadeia, do ultimo ao primeiro, cada um uma unica vez; nunca
# lanca e devolve os descritores das falhas.
function Close-MaPinnedChain {
    param($Chain)
    $failures = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Chain) { return , $failures.ToArray() }
    for ($index = $Chain.Handles.Count - 1; $index -ge 0; $index--) {
        $handle = $Chain.Handles[$index]; $Chain.Handles[$index] = [IntPtr]::Zero
        $closeFailure = Close-MaFileHandle $handle 'Directory'
        if ($null -ne $closeFailure) { $failures.Add($closeFailure) }
    }
    $Chain.Leaf = [IntPtr]::Zero
    return , $failures.ToArray()
}

# Fixa um diretorio existente pelo caminho absoluto inteiro, da raiz da unidade
# ao ultimo componente, cada um aberto relativo ao anterior: nenhum componente era
# ponto de reparse no instante da abertura e nenhum pode ser renomeado ou trocado
# enquanto a cadeia estiver aberta. A validacao textual previa (Assert-MaSafePath)
# so antecipa diagnosticos; a garantia vem da abertura por handles.
function Open-MaDirectoryChain {
    param([Parameter(Mandatory = $true)][string]$Path)
    $canonical = Assert-MaSafePath $Path 'Directory'
    $chain = New-MaPinnedChain $canonical
    try {
        $root = Open-MaPinnedDirectory ([IntPtr]::Zero) ('\??\' + $canonical.Substring(0, 3))
        $chain.Handles.Add($root.Handle); $chain.Leaf = $root.Handle
        foreach ($component in @($canonical.Substring(3).Split([char[]]@('\'), [StringSplitOptions]::RemoveEmptyEntries))) {
            [void](Test-MaNativeFault 'ChainComponent' ([pscustomobject]@{ Path = $canonical; Component = $component }))
            [void](Add-MaPinnedComponent $chain $component)
        }
    } catch {
        $failure = $_.Exception
        Add-MaNativeCleanupFailure $failure (Close-MaPinnedChain $chain)
        throw $failure
    }
    return $chain
}

# Nome do destino Path como filho direto do diretorio fixado pela cadeia.
function Get-MaChildName {
    param([Parameter(Mandatory = $true)]$Chain, [Parameter(Mandatory = $true)][string]$Path)
    $trimmed = $Path.TrimEnd('\')
    $parent = [IO.Path]::GetDirectoryName($trimmed)
    # GetFullPath normaliza como Assert-MaSafePath (inclusive nomes curtos 8.3).
    if ($parent) { $parent = [IO.Path]::GetFullPath($parent) }
    if (-not $parent -or -not $parent.TrimEnd('\').Equals($Chain.Path.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'MA_PATH_CONTAINMENT_FAILED' }
    $name = [IO.Path]::GetFileName($trimmed)
    if (-not (Test-MaWindowsComponent $name)) { throw 'MA_PATH_COMPONENT_UNSAFE' }
    return $name
}

# Destino de clone ou worktree, filho direto do diretorio de trabalho fixado:
# aberto sem seguir ponto de reparse ou, se ausente, criado com FILE_CREATE, e
# mantido aberto sem FILE_SHARE_DELETE durante a operacao Git (o nome nao pode
# ser trocado por link nem o diretorio renomeado). Entries: conteudo lido pelo
# handle. Identity: FileId, para a remocao segura de Close-MaOperationTarget.
function Open-MaOperationTarget {
    param([Parameter(Mandatory = $true)]$Workspace, [Parameter(Mandatory = $true)][string]$Path)
    $name = Get-MaChildName $Workspace $Path
    $opened = Open-MaPinnedDirectory $Workspace.Leaf $name -CreateMissing
    try {
        $identity = Get-MaFileIdentity $opened.Handle
        $entries = Get-MaDirectoryEntries $opened.Handle
    } catch {
        $failure = $_.Exception
        Add-MaNativeCleanupFailure $failure @(Close-MaFileHandle $opened.Handle 'Target')
        throw $failure
    }
    return [pscustomobject]@{ Path = $Path; Name = $name; Handle = $opened.Handle; Created = $opened.Created; Identity = $identity; Entries = $entries }
}

# Fecha o destino. Com RemoveIfCreatedEmpty, um destino criado nesta execucao e
# removido pelo handle se o nome ainda designar o mesmo objeto (FileId) e ele
# estiver vazio: o sistema de arquivos recusa excluir diretorio com conteudo, entao
# nada alem do proprio diretorio vazio pode ser removido. Devolve Removed e Failures.
function Close-MaOperationTarget {
    param($Workspace, $Target, [switch]$RemoveIfCreatedEmpty)
    $failures = New-Object System.Collections.Generic.List[string]
    $removed = $false
    if ($null -eq $Target) { return [pscustomobject]@{ Removed = $false; Failures = $failures.ToArray() } }
    $handle = $Target.Handle; $Target.Handle = [IntPtr]::Zero
    $closeFailure = Close-MaFileHandle $handle 'Target'
    if ($null -ne $closeFailure) { $failures.Add($closeFailure) }
    if ($RemoveIfCreatedEmpty -and $Target.Created -and $null -ne $Workspace -and $Workspace.Leaf -ne [IntPtr]::Zero) {
        $c = $script:MaFileConstants
        $options = [uint32]($c.OptionDirectory -bor $c.OptionSynchronous -bor $c.OptionOpenReparse)
        $opened = Invoke-MaFileCreate $Workspace.Leaf $Target.Name $c.AccessDelete $c.ShareReadWrite $c.DispositionOpen $options
        if ($opened.Status -eq 0) {
            $marshal = [System.Runtime.InteropServices.Marshal]
            $info = New-MaNativeZeroMemory 4
            try {
                if ((Get-MaFileIdentity $opened.Handle) -ceq $Target.Identity) {
                    $marshal::WriteByte($info, 0, 1)
                    $removed = [bool](Get-MaFileApi)::SetFileInformationByHandle($opened.Handle, $c.InfoDisposition, $info, [uint32]1)
                }
            } catch { $removed = $false }
            finally {
                $marshal::FreeHGlobal($info)
                $closeFailure = Close-MaFileHandle $opened.Handle 'Removal'
                if ($null -ne $closeFailure) { $failures.Add($closeFailure) }
            }
        }
    }
    return [pscustomobject]@{ Removed = $removed; Failures = $failures.ToArray() }
}

# --- PrepareMaintenance ------------------------------------------------------------
# Contrato (especificacao 5): autorizacao delimitada, BaseCommit completo e
# repositorio inicializado; clona a coordenacao quando necessario, cria a
# manutencao ausente na base autorizada e gera nela somente os destinos ausentes.
# Nunca cria Codex/Claude, ativa hooks, prepara o indice, faz commit, push ou PR.
# Cada operacao mutavel e precedida de revalidacao; falhas apos uma operacao sao
# relatadas como execucao parcial, sem reversao destrutiva.
# Clone e worktree add rodam sem checkout (--no-checkout), em destino fixado por
# handles; o checkout (read-tree) so ocorre depois de comprovado que nao
# executaria filtro, hook ou submodulo (Get-MaCheckoutSafety). Um checkout
# recusado deixa o clone ou worktree preservado e retomavel (CheckoutPendente).

# Referencia registrada como evidencia, nunca interpretada como aprovacao.
function Get-MaAuthorizationReferenceIssue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'MA_AUTHORIZATION_REFERENCE_REQUIRED' }
    if ($Value -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]' -or (Get-MaCodePointLength $Value) -gt $script:MaAuthorizationReferenceMaxLength) { return 'MA_AUTHORIZATION_REFERENCE_INVALID' }
    return $null
}

# Exclusao mutua entre fases mutaveis do mesmo repositorio: mutex nomeado do
# sistema derivado da identidade do destino, nao da grafia do caminho. A
# identidade combina o FileId do diretorio de trabalho, lido pelo handle da cadeia
# fixada, e o nome da coordenacao; caixa, nome curto 8.3 e barra final nao a
# alteram. A cadeia permanece fixada durante toda a fase: o diretorio protegido
# pelo mutex e o mesmo objeto em que as operacoes ocorrem. Nao grava arquivos e e
# liberado pelo sistema se o processo terminar; o abandono por execucao
# interrompida e informado e o estado e revalidado em seguida.
function Get-MaRepositoryLockName {
    param([Parameter(Mandatory = $true)][string]$Identity)
    return ('Global\MultiAgente-' + (Get-MaSha256 ([Text.Encoding]::UTF8.GetBytes($Identity.ToUpperInvariant()))))
}

function Get-MaWorkspaceLockIdentity {
    param([Parameter(Mandatory = $true)]$Workspace, [Parameter(Mandatory = $true)][string]$CoordinationPath)
    return ((Get-MaFileIdentity $Workspace.Leaf) + '\' + (Get-MaChildName $Workspace $CoordinationPath))
}

# Campos da configuracao que definem destinos e operacoes. A fase compara a
# configuracao de cada releitura com a usada para escolher o mutex.
function Get-MaConfigurationFingerprint {
    param($Configuration)
    if ($null -eq $Configuration) { return $null }
    $parts = @($Configuration.Name, $Configuration.Slug, $Configuration.RepositoryUrl, $Configuration.ParentDirectory)
    foreach ($role in $script:MaRoles) { $parts += [string]$Configuration.Branches[$role]; $parts += [string]$Configuration.Worktrees[$role] }
    return ($parts -join [string][char]0)
}

function Enter-MaRepositoryLock {
    param([Parameter(Mandatory = $true)][string]$Name)
    try { $mutex = New-Object System.Threading.Mutex($false, $Name) }
    catch { throw 'MA_PREPARE_LOCK_UNAVAILABLE' }
    $acquired = $false; $abandoned = $false
    try { $acquired = $mutex.WaitOne(0) }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception -and $exception -isnot [System.Threading.AbandonedMutexException]) { $exception = $exception.InnerException }
        if ($null -eq $exception) { $mutex.Dispose(); throw 'MA_PREPARE_LOCK_UNAVAILABLE' }
        $acquired = $true; $abandoned = $true
    }
    if (-not $acquired) { $mutex.Dispose(); throw 'MA_PREPARE_LOCKED' }
    return [pscustomobject]@{ Mutex = $mutex; Abandoned = $abandoned }
}

function Exit-MaRepositoryLock {
    param($Lock)
    if ($null -eq $Lock) { return }
    try { $Lock.Mutex.ReleaseMutex() } finally { $Lock.Mutex.Dispose() }
}

# Cria um destino governado ausente dentro da manutencao com os bytes renderizados,
# por abertura vinculada a handles (secao anterior): a raiz e fixada da unidade ate
# ela; cada diretorio intermediario e aberto ou criado (FILE_CREATE) pelo nome de
# um unico componente relativo ao pai fixado, sem seguir ponto de reparse, e
# permanece aberto sem FILE_SHARE_DELETE; o arquivo e criado com FILE_CREATE
# relativo ao ultimo diretorio, sem compartilhamento, e os bytes sao conferidos
# pelo mesmo handle. Nenhum caminho e resolvido de novo depois da validacao: uma
# troca concorrente por link ou junction e recusada (MA_FILE_UNSAFE) ou impedida
# pelo compartilhamento, e uma entrada surgida com o nome interrompe sem
# sobrescrever (MA_PREPARE_TARGET_CHANGED). Devolve os diretorios criados.
function New-MaGovernedFile {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$RelativePath, [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    if ((Get-MaGovernedPaths) -cnotcontains $RelativePath) { throw 'MA_PREPARE_TARGET_NOT_GOVERNED' }
    $c = $script:MaFileConstants
    $chain = Open-MaDirectoryChain $Root
    $created = New-Object System.Collections.Generic.List[string]
    $failure = $null
    try {
        [void](Test-MaNativeFault 'GovernedFileChain' ([pscustomobject]@{ Root = $chain.Path; RelativePath = $RelativePath }))
        $components = $RelativePath.Split('/')
        $relative = ''
        for ($index = 0; $index -lt $components.Length - 1; $index++) {
            if ($relative) { $relative += '/' }
            $relative += $components[$index]
            try { $isNew = Add-MaPinnedComponent $chain $components[$index] -CreateMissing }
            catch {
                $code = Get-MaErrorCode $_ 'MA_PREPARE_WRITE_FAILED'
                if ($code -in @('MA_PATH_REPARSE_POINT', 'MA_PATH_DIRECTORY_REQUIRED')) { $code = 'MA_FILE_UNSAFE' }
                elseif ($code -cne 'MA_PREPARE_TARGET_CHANGED') { $code = 'MA_PREPARE_WRITE_FAILED' }
                throw $code
            }
            if ($isNew) { $created.Add($relative) }
        }
        [void](Test-MaNativeFault 'GovernedFileCreate' ([pscustomobject]@{ Root = $chain.Path; RelativePath = $RelativePath }))
        $options = [uint32]($c.OptionNonDirectory -bor $c.OptionSynchronous -bor $c.OptionOpenReparse)
        $file = Invoke-MaFileCreate $chain.Leaf $components[$components.Length - 1] $c.AccessFile $c.ShareNone $c.DispositionCreate $options $c.AttributeNormal
        if ($file.Status -in @($c.StatusNameCollision, $c.StatusIsDirectory)) { throw 'MA_PREPARE_TARGET_CHANGED' }
        if ($file.Status -ne 0) { throw 'MA_PREPARE_WRITE_FAILED' }
        $handle = New-Object Microsoft.Win32.SafeHandles.SafeFileHandle($file.Handle, $true)
        $stream = $null
        try {
            try { $stream = New-Object IO.FileStream($handle, [IO.FileAccess]::ReadWrite, 4096, $false) } catch { throw 'MA_PREPARE_WRITE_FAILED' }
            try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush() } catch { throw 'MA_PREPARE_WRITE_FAILED' }
            # Conferencia pelo mesmo handle: tamanho exato e bytes iguais.
            $read = New-Object byte[] $Bytes.Length
            $total = 0
            try {
                [void]$stream.Seek(0, [IO.SeekOrigin]::Begin)
                while ($total -lt $read.Length) { $count = $stream.Read($read, $total, $read.Length - $total); if ($count -le 0) { break }; $total += $count }
                $extra = $stream.Read((New-Object byte[] 1), 0, 1)
            } catch { throw 'MA_PREPARE_WRITE_VERIFY_FAILED' }
            if ($total -ne $Bytes.Length -or $extra -ne 0 -or -not (Test-MaBytesEqual $read $Bytes)) { throw 'MA_PREPARE_WRITE_VERIFY_FAILED' }
        } finally {
            if ($null -ne $stream) { $stream.Dispose() } else { $handle.Dispose() }
        }
    } catch { $failure = $_.Exception }
    finally { $cleanup = Close-MaPinnedChain $chain }
    if ($null -ne $failure) { Add-MaNativeCleanupFailure $failure $cleanup; throw $failure }
    if (@($cleanup).Count -gt 0) { throw (New-MaNativeCleanupError $cleanup) }
    return , $created.ToArray()
}

# Branches locais (nome exato -> objeto), lidas sem alterar referencias.
function Get-MaBranchRefs {
    param([Parameter(Mandatory = $true)][string]$Root)
    $result = Invoke-MaGit $Root @('for-each-ref', '--format=%(refname)%00%(objectname)', 'refs/heads/')
    if ($result.ExitCode -ne 0) { throw 'MA_ENV_GIT_UNREADABLE' }
    $refs = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($line in (Split-MaLines $result.StdOut)) {
        $parts = $line.Split([char]0)
        if ($parts.Length -ne 2 -or -not $parts[0].StartsWith('refs/heads/') -or $parts[1] -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') { throw 'MA_ENV_GIT_UNREADABLE' }
        $refs[$parts[0].Substring(11)] = $parts[1]
    }
    return , $refs
}

# Situacao da branch configurada para a manutencao: ponta exata ou ausencia, e
# colisoes que o Git ou o sistema de arquivos tornariam ambiguas.
function Get-MaBranchCreationState {
    param($Refs, [string]$Branch, [string]$Role = 'maintenance')
    $tip = $null
    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($name in $Refs.Keys) {
        if ($name -ceq $Branch) { $tip = $Refs[$name]; continue }
        if ($name.Equals($Branch, [StringComparison]::OrdinalIgnoreCase)) { $issues.Add((New-MaIssue 'MA_PREPARE_BRANCH_CASE_CONFLICT' -Role $Role -Detail $name)) }
        elseif ($Branch.StartsWith($name + '/', [StringComparison]::OrdinalIgnoreCase) -or $name.StartsWith($Branch + '/', [StringComparison]::OrdinalIgnoreCase)) { $issues.Add((New-MaIssue 'MA_BRANCH_HIERARCHY_CONFLICT' -Role $Role -Detail $name)) }
    }
    return [pscustomobject]@{ Tip = $tip; Issues = $issues.ToArray() }
}

# O clone executa reference-transaction (e post-checkout, se fizesse checkout).
# Sem repositorio, valem core.hooksPath de sistema ou global e os modelos de
# inicializacao, que copiariam hooks ativos para o clone: GIT_TEMPLATE_DIR,
# init.templateDir e o diretorio padrao do Git (<prefixo>/share/git-core/templates,
# derivado de --exec-path). Nada e alterado: com qualquer hook possivel, ou se o
# diretorio padrao nao puder ser determinado, a operacao e recusada.
function Get-MaCloneHookIssues {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory)
    $issues = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('GIT_TEMPLATE_DIR'))) { $issues.Add((New-MaIssue 'MA_PREPARE_HOOKS_WOULD_RUN' -Role 'coordination' -Detail 'GIT_TEMPLATE_DIR')) }
    foreach ($key in @('core.hooksPath', 'init.templateDir')) {
        $result = Invoke-MaGit $WorkingDirectory @('config', '-z', '--show-scope', '--get-all', $key)
        if ($result.ExitCode -eq 0) {
            $fields = Split-MaNullFields $result.StdOut
            $scopes = @(for ($index = 0; $index + 1 -lt $fields.Count; $index += 2) { $fields[$index] })
            $issues.Add((New-MaIssue 'MA_PREPARE_HOOKS_WOULD_RUN' -Role 'coordination' -Detail ($key + ' (' + ($scopes -join ', ') + ')')))
        } elseif ($result.ExitCode -ne 1) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role 'coordination' -Path $WorkingDirectory -Detail $key)) }
    }
    $exec = Invoke-MaGit $WorkingDirectory @('--exec-path')
    $execPath = $null
    if ($exec.ExitCode -eq 0) { $lines = Split-MaLines $exec.StdOut; if ($lines.Count -eq 1) { $execPath = ConvertTo-MaWindowsPath $lines[0] } }
    if ($null -eq $execPath) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role 'coordination' -Path $WorkingDirectory -Detail '--exec-path')) }
    elseif ($execPath -inotmatch '\A[A-Za-z]:\\.*\\libexec\\git-core\z') { $issues.Add((New-MaIssue 'MA_PREPARE_HOOKS_WOULD_RUN' -Role 'coordination' -Detail ('diretorio padrao de modelos nao determinado a partir de ' + $execPath))) }
    else {
        $templates = [IO.Path]::Combine($execPath.Substring(0, $execPath.Length - '\libexec\git-core'.Length), 'share', 'git-core', 'templates', 'hooks')
        if ([IO.Directory]::Exists($templates)) {
            $inventory = Get-MaHookInventory $templates
            if ($inventory.Active.Count -gt 0) { $issues.Add((New-MaIssue 'MA_PREPARE_HOOKS_WOULD_RUN' -Role 'coordination' -Path $templates -Detail ('modelos padrao: ' + ($inventory.Active -join ', ')))) }
        }
    }
    return , $issues.ToArray()
}

# Rotulo do transporte de uma URL para relatorio, sem reproduzir usuario, host,
# caminho ou credenciais.
function Get-MaTransportLabel {
    param([string]$Url)
    if ($Url -cmatch '\A([A-Za-z][A-Za-z0-9+.-]+)::') { return ('helper ' + $Matches[1].ToLowerInvariant()) }
    if ($Url -cmatch '\A([A-Za-z][A-Za-z0-9+.-]+)://') { return $Matches[1].ToLowerInvariant() }
    if ($Url -cmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*:') { return 'ssh (forma scp)' }
    return 'caminho local ou forma desconhecida'
}

# Transporte efetivo do clone, determinado sem conectar ao remoto e com a mesma
# configuracao do clone (inclusive os argumentos de teste). O proprio Git expande
# url.<base>.insteadOf de todos os escopos (ls-remote --get-url, que tambem segue
# remote.<url>.url); o resultado precisa cumprir o contrato da URL configurada:
# https:// ou SSH (ssh:// ou forma scp), sem credenciais, consulta ou fragmento.
# Recusa file, ext, git, http, caminhos locais e remote helpers (<nome>::), alem
# de remote.origin.vcs, que trocaria o transporte do clone por um helper sem
# mudar a URL, e de remote.origin.url de qualquer camada: o clone le a
# configuracao do remoto origin e usaria a primeira URL (sistema ou global)
# antes da informada, inclusive <helper>::. Recusa tambem alias.remote-ssh, que
# executaria um comando (inclusive por caminho absoluto) no lugar do helper ssh
# ausente da instalacao. Com transporte SSH, recusa comandos SSH personalizados
# (core.sshCommand de qualquer camada, GIT_SSH e GIT_SSH_COMMAND) e exige o
# cliente SSH da instalacao (Get-MaGitTransport). Nada e alterado; leitura
# inconclusiva bloqueia. Esta verificacao produz o erro estruturado antes do
# clone; a recusa efetiva fica no proprio comando (GIT_ALLOW_PROTOCOL,
# GIT_EXEC_PATH e Invoke-MaGit -Transport; remote.origin.vcs fixado no clone
# HTTPS e alias.remote-ssh vazio em todo clone), inclusive se a configuracao
# mudar entre a verificacao e o clone. Devolve o transporte ('https' ou 'ssh';
# $null se recusado) e as ocorrencias.
function Get-MaCloneTransport {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory, [Parameter(Mandatory = $true)][string]$Url, [AllowEmptyCollection()][string[]]$GitArguments = @())
    $issues = New-Object System.Collections.Generic.List[object]
    # Chave presente em qualquer camada (escopos relatados, sem o valor) recusa.
    $refuseConfigured = {
        param([string]$Key, [string]$Code)
        $result = Invoke-MaGit $WorkingDirectory (@($GitArguments) + @('config', '-z', '--show-scope', '--get-all', $Key))
        if ($result.ExitCode -eq 0) {
            $fields = Split-MaNullFields $result.StdOut
            $scopes = @(for ($index = 0; $index + 1 -lt $fields.Count; $index += 2) { $fields[$index] })
            $issues.Add((New-MaIssue $Code -Role 'coordination' -Detail ($Key + ' (' + ($scopes -join ', ') + ')')))
        } elseif ($result.ExitCode -ne 1) { $issues.Add((New-MaIssue 'MA_REPOSITORY_TRANSPORT_UNVERIFIED' -Role 'coordination' -Path $WorkingDirectory -Detail $Key)) }
    }
    foreach ($key in @('remote.origin.vcs', 'remote.origin.url', 'alias.remote-ssh')) { & $refuseConfigured $key 'MA_REPOSITORY_TRANSPORT_UNSAFE' }
    if ($null -eq $script:MaGitTransport) { $issues.Add((New-MaIssue 'MA_GIT_TRANSPORT_UNTRUSTED' -Role 'coordination')) }
    $expanded = Invoke-MaGit $WorkingDirectory (@($GitArguments) + @('ls-remote', '--get-url', '--', $Url))
    $lines = Split-MaLines ([string]$expanded.StdOut)
    $transport = $null
    if ($expanded.ExitCode -ne 0 -or $lines.Count -ne 1) { $issues.Add((New-MaIssue 'MA_REPOSITORY_TRANSPORT_UNVERIFIED' -Role 'coordination' -Path $WorkingDirectory -Detail ('git ls-remote --get-url ' + $expanded.ExitCode))) }
    else {
        $effective = $lines[0]
        $valid = $true
        try { Assert-MaRepositoryUrl $effective } catch { $valid = $false }
        if (-not $valid) { $issues.Add((New-MaIssue 'MA_REPOSITORY_TRANSPORT_UNSAFE' -Role 'coordination' -Detail ('URL efetiva fora do contrato; transporte ' + (Get-MaTransportLabel $effective)))) }
        else {
            $transport = 'ssh'; if ($effective -cmatch '\Ahttps://') { $transport = 'https' }
            if ($effective -cne $Url) { $issues.Add((New-MaIssue 'MA_REPOSITORY_TRANSPORT_REWRITTEN' -Severity 'Aviso' -Role 'coordination' -Detail ((Get-MaTransportLabel $Url) + ' -> ' + (Get-MaTransportLabel $effective)))) }
        }
    }
    if ($transport -ceq 'ssh') {
        foreach ($name in @('GIT_SSH', 'GIT_SSH_COMMAND')) {
            if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) { $issues.Add((New-MaIssue 'MA_REPOSITORY_SSH_COMMAND_UNSUPPORTED' -Role 'coordination' -Detail $name)) }
        }
        & $refuseConfigured 'core.sshCommand' 'MA_REPOSITORY_SSH_COMMAND_UNSUPPORTED'
        if ($null -ne $script:MaGitTransport -and -not $script:MaGitTransport.Ssh) { $issues.Add((New-MaIssue 'MA_GIT_SSH_CLIENT_UNTRUSTED' -Role 'coordination')) }
    }
    if (@($issues | Where-Object { $_.Severity -ne 'Aviso' }).Count -gt 0) { $transport = $null }
    return [pscustomobject]@{ Transport = $transport; Issues = $issues.ToArray() }
}

# worktree add executa post-checkout, reference-transaction e post-index-change;
# o checkout por read-tree grava o indice (post-index-change). Qualquer
# core.hooksPath aplicavel ou hook ativo no diretorio padrao recusa a operacao; a
# configuracao do consumidor nao e substituida nem neutralizada.
function Get-MaWorktreeHookIssues {
    param($Coordination, [string]$Role = 'maintenance')
    $issues = New-Object System.Collections.Generic.List[object]
    $hooksPath = @($Coordination.HooksPath)
    if ($hooksPath.Count -gt 0) { $issues.Add((New-MaIssue 'MA_PREPARE_HOOKS_WOULD_RUN' -Role $Role -Detail ('core.hooksPath (' + ((@($hooksPath | ForEach-Object { $_.Scope })) -join ', ') + ')'))) }
    $active = @($Coordination.DefaultHooks)
    if ($active.Count -gt 0) { $issues.Add((New-MaIssue 'MA_PREPARE_HOOKS_WOULD_RUN' -Role $Role -Path ([IO.Path]::Combine($Coordination.CommonDir, 'hooks')) -Detail ($active -join ', '))) }
    return , $issues.ToArray()
}

# Caminhos com atributo filter definido (valor diferente de unspecified e unset),
# agrupados por valor: driver -> caminhos. $null se a consulta falhar. Com Source,
# os .gitattributes versionados vem desse commit, sem checkout; os demais arquivos
# de atributos ($GIT_DIR/info/attributes, core.attributesFile e o de sistema) sao
# lidos pelo proprio Git, como no checkout.
function Get-MaFilteredPaths {
    param([Parameter(Mandatory = $true)][string]$Root, [AllowEmptyCollection()][string[]]$Paths, [string]$Source = '')
    $filtered = [ordered]@{}
    if (@($Paths).Count -eq 0) { return $filtered }
    $arguments = @('check-attr', '-z', '--stdin')
    if ($Source) { $arguments += ('--source=' + $Source) }
    $arguments += 'filter'
    $result = Invoke-MaGit $Root $arguments -InputText (($Paths -join [string][char]0) + [char]0)
    $fields = Split-MaNullFields $result.StdOut
    if ($result.ExitCode -ne 0 -or $fields.Count -ne 3 * @($Paths).Count) { return $null }
    for ($index = 0; $index + 2 -lt $fields.Count; $index += 3) {
        $value = $fields[$index + 2]
        if ($value -cin @('unspecified', 'unset')) { continue }
        if (-not $filtered.Contains($value)) { $filtered[$value] = New-Object System.Collections.Generic.List[string] }
        $filtered[$value].Add($fields[$index])
    }
    return $filtered
}

# Verificacao previa ao checkout de Commit em Root, somente leitura. Recusa, sem
# alterar nada, se o checkout pudesse executar comando externo ou divergir do
# conferido: atributo filter em qualquer caminho do commit (exista ou nao driver
# configurado: a configuracao pode mudar ate o checkout e o instalador nao a
# sobrepoe), origem alternativa de atributos (attr.tree em qualquer camada ou
# GIT_ATTR_SOURCE), submodulos (gitlink ou .gitmodules) e hooks aplicaveis. Avisa
# quando core.fsmonitor esta configurado (o instalador o desliga por -c, sem
# alterar a configuracao). Devolve Issues e Paths (caminhos do commit).
function Get-MaCheckoutSafety {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Commit, [Parameter(Mandatory = $true)][string]$Role, $Environment)
    $issues = New-Object System.Collections.Generic.List[object]
    $paths = @()
    $result = { [pscustomobject]@{ Issues = $issues.ToArray(); Paths = $paths } }
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('GIT_ATTR_SOURCE'))) { $issues.Add((New-MaIssue 'MA_PREPARE_CHECKOUT_UNSUPPORTED' -Role $Role -Detail 'GIT_ATTR_SOURCE')) }
    $attrTree = Invoke-MaGit $Root @('config', '-z', '--show-scope', '--get-all', 'attr.tree')
    if ($attrTree.ExitCode -eq 0) {
        $fields = Split-MaNullFields $attrTree.StdOut
        $scopes = @(for ($index = 0; $index + 1 -lt $fields.Count; $index += 2) { $fields[$index] })
        $issues.Add((New-MaIssue 'MA_PREPARE_CHECKOUT_UNSUPPORTED' -Role $Role -Detail ('attr.tree (' + ($scopes -join ', ') + ')')))
    } elseif ($attrTree.ExitCode -ne 1) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $Root -Detail 'attr.tree')) }
    $fsmonitor = Invoke-MaGit $Root @('config', '-z', '--show-scope', '--get-all', 'core.fsmonitor')
    if ($fsmonitor.ExitCode -eq 0) {
        $fields = Split-MaNullFields $fsmonitor.StdOut
        $active = @(for ($index = 0; $index + 1 -lt $fields.Count; $index += 2) { if ($fields[$index + 1] -inotin @('false', 'no', 'off', '0', '')) { $fields[$index] } })
        if ($active.Count -gt 0) { $issues.Add((New-MaIssue 'MA_PREPARE_FSMONITOR_DISABLED' -Severity 'Aviso' -Role $Role -Detail ('core.fsmonitor (' + ($active -join ', ') + ')'))) }
    } elseif ($fsmonitor.ExitCode -ne 1) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $Root -Detail 'core.fsmonitor')) }
    if ($null -ne $Environment) { foreach ($issue in (Get-MaWorktreeHookIssues $Environment $Role)) { $issues.Add($issue) } }
    $tree = Invoke-MaGit $Root @('ls-tree', '-r', '-z', '--full-tree', $Commit)
    if ($tree.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $Root -Detail 'ls-tree')); return (& $result) }
    try { $entries = Get-MaGitEntries $tree.StdOut 'Tree' }
    catch { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $Root -Detail 'ls-tree')); return (& $result) }
    $paths = @($entries.Keys | Sort-Object)
    $gitlinks = @($paths | Where-Object { $_ -ieq '.gitmodules' -or @($entries[$_] | Where-Object { $_.Mode -ceq '160000' -or $_.Type -ceq 'commit' }).Count -gt 0 })
    if ($gitlinks.Count -gt 0) { $issues.Add((New-MaIssue 'MA_ENV_SUBMODULES_UNSUPPORTED' -Role $Role -Path $Root -Detail (Format-MaPathList $gitlinks))) }
    $filtered = Get-MaFilteredPaths $Root $paths $Commit
    if ($null -eq $filtered) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $Root -Detail 'check-attr')) }
    else {
        foreach ($driver in $filtered.Keys) { $issues.Add((New-MaIssue 'MA_PREPARE_CHECKOUT_FILTER' -Role $Role -Path $Root -Detail ('filter=' + $driver + ': ' + (Format-MaPathList $filtered[$driver].ToArray())))) }
    }
    return (& $result)
}

# Conclui o checkout de um clone ou worktree criado sem checkout, depois de
# Get-MaCheckoutSafety. Revalida, pelo handle do destino fixado, que nele existe
# somente .git, e que HEAD e a branch continuam os conferidos; executa
# read-tree -m -u sobre o commit conferido, sem submodulos (o Git recusa
# sobrescrever arquivo nao rastreado); e confere depois que HEAD nao mudou, que os
# atributos, agora lidos do checkout, continuam sem filtro e que nenhum ponto de
# reparse surgiu no primeiro nivel. Devolve Issues (nenhuma significa checkout
# concluido) e Executed (read-tree chegou a executar). Uma mudanca durante a
# execucao e detectada depois, nao impedida: a configuracao do consumidor nao e
# sobreposta.
function Invoke-MaCheckout {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Commit, [Parameter(Mandatory = $true)][string]$Branch, [Parameter(Mandatory = $true)][string]$Role, [Parameter(Mandatory = $true)]$Target, [AllowEmptyCollection()][string[]]$Paths)
    $issues = New-Object System.Collections.Generic.List[object]
    $reparse = $script:MaFileConstants.AttributeReparse
    $entries = Get-MaDirectoryEntries $Target.Handle
    if ($entries.Count -ne 1 -or $entries[0].Name -cne '.git' -or ($entries[0].Attributes -band $reparse) -ne 0) {
        $issues.Add((New-MaIssue 'MA_PREPARE_CHECKOUT_PENDING' -Role $Role -Path $Root -Detail (Format-MaPathList @($entries | ForEach-Object { $_.Name }))))
        return [pscustomobject]@{ Issues = $issues.ToArray(); Executed = $false }
    }
    $before = Get-MaHeadState $Root
    if ($before.Commit -cne $Commit -or $before.Branch -cne $Branch) {
        $issues.Add((New-MaIssue 'MA_PREPARE_STATE_CHANGED' -Role $Role -Path $Root -Detail 'HEAD antes do checkout'))
        return [pscustomobject]@{ Issues = $issues.ToArray(); Executed = $false }
    }
    $checkout = Invoke-MaGit $Root @('read-tree', '-m', '-u', '--no-recurse-submodules', $Commit) -TimeoutMilliseconds $script:MaCloneTimeoutMilliseconds
    if ($checkout.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_PREPARE_CHECKOUT_FAILED' -Severity 'Falha' -Role $Role -Path $Root -Detail ('git read-tree ' + $checkout.ExitCode))) }
    $after = Get-MaHeadState $Root
    if ($after.Commit -cne $Commit -or $after.Branch -cne $Branch) { $issues.Add((New-MaIssue 'MA_PREPARE_STATE_CHANGED' -Role $Role -Path $Root -Detail 'HEAD depois do checkout')) }
    $filtered = Get-MaFilteredPaths $Root $Paths
    if ($null -eq $filtered) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $Root -Detail 'check-attr')) }
    elseif ($filtered.Count -gt 0) { $issues.Add((New-MaIssue 'MA_PREPARE_STATE_CHANGED' -Role $Role -Path $Root -Detail ('atributo filter surgiu durante o checkout: ' + (@($filtered.Keys) -join ', ')))) }
    $redirected = Get-MaReparseEntries $Target.Handle
    if ($redirected.Count -gt 0) { $issues.Add((New-MaIssue 'MA_PREPARE_TARGET_REDIRECTED' -Role $Role -Path $Root -Detail (Format-MaPathList $redirected))) }
    return [pscustomobject]@{ Issues = $issues.ToArray(); Executed = $true }
}

function Format-MaPathList {
    param([string[]]$Paths)
    $shown = @($Paths | Select-Object -First 10)
    $text = $shown -join ', '
    if ($Paths.Count -gt $shown.Count) { $text += ' (+' + ($Paths.Count - $shown.Count) + ')' }
    return $text
}

# Alteracoes da manutencao fora do conjunto governado. status com
# GIT_OPTIONAL_LOCKS=0 nao grava o indice; um caminho rastreado com atributo
# filter levaria o status a executar um driver externo ao conferir o conteudo,
# entao a verificacao e declarada inconclusiva sem executar o status. Entradas nos
# diretorios exclusivos ficam com a classificacao dos destinos.
function Get-MaForeignChangeIssues {
    param([Parameter(Mandatory = $true)]$Environment)
    $issues = New-Object System.Collections.Generic.List[object]
    $root = $Environment.Path
    $tracked = Invoke-MaGit $root @('ls-files', '-z')
    if ($tracked.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role 'maintenance' -Path $root -Detail 'ls-files')); return , $issues.ToArray() }
    $paths = Split-MaNullFields $tracked.StdOut
    if ($paths.Count -gt 0) {
        $attributes = Invoke-MaGit $root @('check-attr', '-z', '--stdin', 'filter') -InputText (($paths -join [string][char]0) + [char]0)
        $fields = Split-MaNullFields $attributes.StdOut
        if ($attributes.ExitCode -ne 0 -or $fields.Count % 3 -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role 'maintenance' -Path $root -Detail 'check-attr')); return , $issues.ToArray() }
        $filtered = @(for ($index = 0; $index + 2 -lt $fields.Count; $index += 3) { if ($fields[$index + 2] -cnotin @('unspecified', 'unset')) { $fields[$index] } })
        if ($filtered.Count -gt 0) { $issues.Add((New-MaIssue 'MA_PREPARE_FOREIGN_CHANGE_UNVERIFIED' -Role 'maintenance' -Path $root -Detail (Format-MaPathList $filtered))); return , $issues.ToArray() }
    }
    $status = Invoke-MaGit $root @('status', '--porcelain=v1', '-z', '--untracked-files=all', '--no-renames', '--ignore-submodules=all')
    if ($status.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role 'maintenance' -Path $root -Detail 'status')); return , $issues.ToArray() }
    $governed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in (Get-MaGovernedPaths)) { [void]$governed.Add($path) }
    $foreign = New-Object System.Collections.Generic.List[string]
    foreach ($record in (Split-MaNullFields $status.StdOut)) {
        if ($record.Length -lt 4 -or $record[2] -ne ' ') { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role 'maintenance' -Path $root -Detail 'status')); return , $issues.ToArray() }
        $path = $record.Substring(3)
        if ($governed.Contains($path)) { continue }
        $exclusive = $false
        foreach ($directory in $script:MaExclusiveDirectories) { if ($path.StartsWith($directory + '/', [StringComparison]::OrdinalIgnoreCase)) { $exclusive = $true } }
        if (-not $exclusive) { $foreign.Add($path) }
    }
    if ($foreign.Count -gt 0) { $issues.Add((New-MaIssue 'MA_PREPARE_FOREIGN_CHANGE' -Role 'maintenance' -Path $root -Detail (Format-MaPathList $foreign.ToArray()))) }
    return , $issues.ToArray()
}

# Destinos a criar que regras de exclusao ocultariam da preparacao do indice.
function Get-MaIgnoredPathIssues {
    param([Parameter(Mandatory = $true)]$Environment, [string[]]$Paths)
    $issues = New-Object System.Collections.Generic.List[object]
    if (@($Paths).Count -eq 0) { return , $issues.ToArray() }
    foreach ($path in $Paths) { if ((Get-MaGovernedPaths) -cnotcontains $path) { throw 'MA_PREPARE_TARGET_NOT_GOVERNED' } }
    $result = Invoke-MaGit $Environment.Path @('check-ignore', '-z', '--stdin') -InputText (($Paths -join [string][char]0) + [char]0) -NoLiteralPathspecs
    if ($result.ExitCode -eq 0) { foreach ($path in (Split-MaNullFields $result.StdOut)) { $issues.Add((New-MaIssue 'MA_PREPARE_PATH_IGNORED' -Role 'maintenance' -Path $path)) } }
    elseif ($result.ExitCode -ne 1) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role 'maintenance' -Path $Environment.Path -Detail 'check-ignore')) }
    return , $issues.ToArray()
}

# HEAD (commit) e branch atuais de um ambiente, para revalidacao imediata.
function Get-MaHeadState {
    param([Parameter(Mandatory = $true)][string]$Root)
    $symbolic = Invoke-MaGit $Root @('symbolic-ref', '--quiet', 'HEAD')
    $head = Invoke-MaGit $Root @('rev-parse', '--verify', '--quiet', 'HEAD^{commit}')
    $branch = $null; $commit = $null
    if ($symbolic.ExitCode -eq 0) { $reference = (Split-MaLines $symbolic.StdOut)[0]; if ($reference.StartsWith('refs/heads/')) { $branch = $reference.Substring(11) } }
    if ($head.ExitCode -eq 0) { $commit = (Split-MaLines $head.StdOut)[0] }
    return [pscustomobject]@{ Branch = $branch; Commit = $commit }
}

function Invoke-MaPrepareMaintenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$AuthorizationReference = '',
        [string]$BaseCommit = '',
        [string]$IntegratedCommit = '',
        [string]$IntegrationReference = '',
        [switch]$WhatIfRequested
    )
    $phaseIssues = New-Object System.Collections.Generic.List[object]
    $performed = New-Object System.Collections.Generic.List[object]
    $simulated = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[string]
    $inspection = New-MaInspectionState
    $lock = $null
    $whatIf = [bool]$WhatIfRequested
    $authorizationHash = $null
    if (-not [string]::IsNullOrEmpty($AuthorizationReference)) { $authorizationHash = Get-MaSha256 ([Text.Encoding]::UTF8.GetBytes($AuthorizationReference)) }
    # A referencia nao e reproduzida (pode conter dados pessoais); o hash permite
    # conferi-la com o registro humano.
    $evidence = [ordered]@{
        AuthorizationReference = $(if ($authorizationHash) { 'fornecida (SHA-256 ' + $authorizationHash + '); registrada sem verificacao: o instalador nao infere aprovacao' } else { 'nao fornecida' })
        BaseCommit             = $(if ($BaseCommit) { 'fornecido; pendente de conferencia' } else { 'nao fornecido' })
        IntegratedCommit       = $(if ($IntegratedCommit) { 'fornecido; nao utilizado em PrepareMaintenance' } else { 'nao fornecido' })
        IntegrationReference   = $(if ($IntegrationReference) { 'fornecida; nao utilizada em PrepareMaintenance' } else { 'nao fornecida' })
    }
    $record = {
        param($List, [string]$Role, [string]$Operation, [string]$Target, [string]$Detail)
        $List.Add([pscustomobject]@{ Order = $List.Count + 1; Role = $Role; Operation = $Operation; Target = $Target; Detail = $Detail })
    }
    # Cada inspecao substitui a anterior: o resultado reflete o estado mais recente.
    # O recipiente conserva a inspecao em curso mesmo se ela lancar excecao.
    $current = @{ Inspection = $inspection }
    # ToArray: no 5.1, @() de uma List devolve a propria List, sem operador +.
    $blocked = { @(@($current.Inspection.Issues.ToArray()) + @($phaseIssues.ToArray()) | Where-Object { $_.Severity -ne 'Aviso' }).Count -gt 0 }
    $inspect = {
        $current.Inspection = New-MaInspectionState
        Invoke-MaInspection -State $current.Inspection -ConfigPath $ConfigPath -PackageRoot $PackageRoot -BaseCommit $BaseCommit -IntegratedCommit $IntegratedCommit -FallbackCode 'MA_PREPARE_UNEXPECTED_FAILURE'
    }
    $byRole = { param($State) $map = @{}; foreach ($environment in $State.Environments) { $map[$environment.Role] = $environment }; return $map }
    # Recursos fixados por handles durante a fase (ver "Abertura vinculada a
    # handles"): diretorio de trabalho, destinos de clone e worktree e o
    # repositorio comum. Fechados no finally, antes de liberar o mutex.
    $workspace = $null
    $targets = New-Object System.Collections.Generic.List[object]
    $chains = New-Object System.Collections.Generic.List[object]
    # Configuracao usada para fixar o diretorio de trabalho e escolher o mutex.
    # Cada releitura posterior precisa coincidir com ela; senao, bloqueio.
    $lockedFingerprint = $null
    $configurationChanged = {
        if ((Get-MaConfigurationFingerprint $current.Inspection.Configuration) -ceq $lockedFingerprint) { return $false }
        $phaseIssues.Add((New-MaIssue 'MA_PREPARE_CONFIG_CHANGED' -Path $ConfigPath))
        return $true
    }
    # Conflitos de destinos governados bloqueiam a geracao, nao a conclusao do
    # checkout de um clone ja realizado (o clone e preservado, especificacao 5).
    $classificationCodes = @('MA_FILE_CONFLICT', 'MA_FILE_UNSAFE', 'MA_FILE_UNEXPECTED_ENTRY')
    $blockedForCheckout = { @(@($current.Inspection.Issues.ToArray()) + @($phaseIssues.ToArray()) | Where-Object { $_.Severity -ne 'Aviso' -and $_.Code -cnotin $classificationCodes }).Count -gt 0 }
    $targetFor = { param([string]$Path) foreach ($target in $targets) { if ($target.Path -ceq $Path) { return $target } }; return $null }
    # Checkout posterior a clone ou worktree criado sem checkout, somente depois da
    # verificacao previa. $true se concluido; ocorrencias ficam em $phaseIssues.
    $checkout = {
        param([string]$Role, [string]$Path, $Environment, [string]$Branch)
        $safety = Get-MaCheckoutSafety -Root $Path -Commit $Environment.Head -Role $Role -Environment $Environment
        foreach ($issue in $safety.Issues) { $phaseIssues.Add($issue) }
        if (& $blocked) { return $false }
        $detail = 'read-tree de ' + $Environment.Head + '; sem filtro, hook, submodulo ou origem alternativa de atributos'
        if ($whatIf) { & $record $simulated $Role 'Checkout' $Path $detail; return $false }
        $target = & $targetFor $Path
        if ($null -eq $target) {
            try { $target = Open-MaOperationTarget $workspace $Path; $targets.Add($target) }
            catch { $phaseIssues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PATH_INSPECTION_FAILED') -Role $Role -Path $Path -Detail (Get-MaErrorDetail $_))); return $false }
        }
        $result = Invoke-MaCheckout -Root $Path -Commit $Environment.Head -Branch $Branch -Role $Role -Target $target -Paths $safety.Paths
        foreach ($issue in $result.Issues) { $phaseIssues.Add($issue) }
        if (& $blocked) {
            if ($result.Executed) { & $record $performed $Role 'Checkout (parcial)' $Path 'preservado sem remocao automatica' }
            return $false
        }
        & $record $performed $Role 'Checkout' $Path $detail
        return $true
    }
    $cleanupIssue = {
        param([string[]]$Failures)
        if (@($Failures).Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PATH_HANDLE_CLOSE_FAILED' -Severity 'Falha' -Detail (@($Failures) -join ', '))) }
    }
    try {
        do {
            # 1. Evidencias exigidas antes de qualquer acesso ao repositorio.
            $authorizationCode = Get-MaAuthorizationReferenceIssue $AuthorizationReference
            if ($authorizationCode) { $phaseIssues.Add((New-MaIssue $authorizationCode)) }
            if (-not $BaseCommit) { $phaseIssues.Add((New-MaIssue 'MA_BASECOMMIT_REQUIRED')) }

            # 2. Inspecao inicial, somente leitura.
            & $inspect; $inspection = $current.Inspection
            if ($null -ne $inspection.Configuration -and $null -eq $inspection.Rendered -and -not (& $blocked)) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_RENDER_UNAVAILABLE')) }
            # Conflitos de destinos nao impedem a retomada de um checkout pendente (que
            # tem verificacao propria); o clone e as operacoes da manutencao so ocorrem
            # sem nenhum bloqueio (passos 4 e 5).
            if ((& $blockedForCheckout) -or $null -eq $inspection.Configuration) { break }
            $configuration = $inspection.Configuration
            $lockedFingerprint = Get-MaConfigurationFingerprint $configuration

            # 3. Diretorio de trabalho fixado por handles, mutex derivado da sua
            # identidade e revalidacao sob ele. Destinos e argumentos das operacoes
            # vem somente de $configuration.
            try {
                $workspace = Open-MaDirectoryChain $configuration.ParentDirectory
                $lockName = Get-MaRepositoryLockName (Get-MaWorkspaceLockIdentity $workspace $configuration.Worktrees.coordination)
            } catch { $phaseIssues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PATH_INSPECTION_FAILED') -Path $configuration.ParentDirectory -Detail (Get-MaErrorDetail $_))); break }
            try { $lock = Enter-MaRepositoryLock $lockName }
            catch { $phaseIssues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PREPARE_LOCK_UNAVAILABLE'))); break }
            if ($lock.Abandoned) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_LOCK_ABANDONED' -Severity 'Aviso')) }
            [void](Test-MaNativeFault 'PrepareLocked' $configuration)
            & $inspect; $inspection = $current.Inspection
            if (& $configurationChanged) { break }
            if ((& $blockedForCheckout) -or $null -eq $inspection.Rendered) { break }
            $coordinationPath = $configuration.Worktrees.coordination
            $maintenancePath = $configuration.Worktrees.maintenance
            $environments = & $byRole $inspection

            # 4. Coordenacao: clone sem checkout, somente quando ausente ou diretorio
            # vazio, no destino fixado; checkout depois da verificacao previa.
            if (-not $environments.coordination.Exists -or $environments.coordination.State -eq 'VazioSemRepositorio') {
                if (& $blocked) { break }
                foreach ($issue in (Get-MaCloneHookIssues $configuration.ParentDirectory)) { $phaseIssues.Add($issue) }
                # Transporte efetivo (reescritas e helpers) antes de qualquer conexao.
                $cloneTransport = Get-MaCloneTransport $configuration.ParentDirectory $configuration.RepositoryUrl $script:MaCloneTestArguments
                foreach ($issue in $cloneTransport.Issues) { $phaseIssues.Add($issue) }
                if (& $blocked) { break }
                $cloneTarget = 'origin -> ' + $coordinationPath + ' (branch ' + $configuration.Branches.coordination + ')'
                if ($whatIf) {
                    & $record $simulated 'coordination' 'Clonar' $cloneTarget 'sem checkout'
                    & $record $simulated 'coordination' 'Checkout' $coordinationPath 'somente se, apos o clone, nenhum filtro, hook, submodulo ou origem alternativa de atributos se aplicar'
                    & $record $simulated 'maintenance' 'Criar branch e worktree' $maintenancePath ('branch ' + $configuration.Branches.maintenance + ' em ' + $BaseCommit)
                    & $record $simulated 'maintenance' 'Gerar' 'onze destinos governados' 'somente se todos os destinos clonados forem ausentes ou identicos'
                    $pending.Add('Conteudo do remoto desconhecido sem clone: conflitos (inclusive README criado pelo servidor) e atributos filter so poderao ser classificados apos o clone.')
                    break
                }
                # Destino fixado: vazio conferido pelo handle ou criado agora.
                try { $target = Open-MaOperationTarget $workspace $coordinationPath; $targets.Add($target) }
                catch {
                    $code = Get-MaErrorCode $_ 'MA_PATH_INSPECTION_FAILED'
                    if ($code -ceq 'MA_PREPARE_TARGET_CHANGED') { $code = 'MA_PREPARE_STATE_CHANGED' }
                    $phaseIssues.Add((New-MaIssue $code -Role 'coordination' -Path $coordinationPath -Detail (Get-MaErrorDetail $_))); break
                }
                if (@($target.Entries).Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_STATE_CHANGED' -Role 'coordination' -Path $coordinationPath)); break }
                # --no-checkout: nenhum filtro de checkout, nem post-checkout, durante o clone.
                # HTTPS: remote.origin.vcs fixado na ultima camada (-c) prevalece sobre
                # valor surgido depois da verificacao e seleciona o helper https do
                # exec-path da instalacao. O Git prioriza o prefixo <helper>:: da URL
                # sobre remote.origin.vcs; SSH nativo nao admite helper fixado. Em
                # todo clone, alias.remote-ssh vazio na ultima camada: um helper ssh
                # selecionado depois da verificacao (vcs=ssh ou ssh::) nao existe no
                # exec-path nem no PATH restrito (-Transport) e o alias aborta sem
                # executar comando.
                $transportArguments = @('-c', 'alias.remote-ssh='); if ($cloneTransport.Transport -ceq 'https') { $transportArguments += @('-c', 'remote.origin.vcs=https') }
                $cloneArguments = @($script:MaCloneTestArguments) + $transportArguments + @('clone', '--no-checkout', '--origin', 'origin', '--branch', $configuration.Branches.coordination, '--no-recurse-submodules', '--', $configuration.RepositoryUrl, $coordinationPath)
                $clone = Invoke-MaGit $configuration.ParentDirectory $cloneArguments -TimeoutMilliseconds $script:MaCloneTimeoutMilliseconds -Transport
                $redirected = Get-MaReparseEntries $target.Handle
                if ($clone.ExitCode -ne 0) {
                    $code = 'MA_PREPARE_CLONE_FAILED'; $severity = 'Falha'; $cloneDetail = 'git clone ' + $clone.ExitCode
                    if ([string]$clone.StdErr -cmatch 'Remote branch \S+ not found in upstream origin') { $code = 'MA_REMOTE_BRANCH_NOT_FOUND'; $severity = 'Bloqueio' }
                    # Configuracao mudou depois da verificacao: o Git recusou o transporte (GIT_ALLOW_PROTOCOL).
                    elseif ([string]$clone.StdErr -cmatch "transport '([A-Za-z0-9+._-]{1,64})' not allowed") { $code = 'MA_REPOSITORY_TRANSPORT_UNSAFE'; $severity = 'Bloqueio'; $cloneDetail += '; transporte recusado pelo Git: ' + $Matches[1].ToLowerInvariant() }
                    # Helper selecionado depois da verificacao, ausente da instalacao: o alias fixado vazio aborta.
                    elseif ([string]$clone.StdErr -cmatch "expansion of alias 'remote-([A-Za-z0-9+._-]{1,64})' failed") { $code = 'MA_REPOSITORY_TRANSPORT_UNSAFE'; $severity = 'Bloqueio'; $cloneDetail += '; helper de transporte nao autorizado: ' + $Matches[1].ToLowerInvariant() }
                    # Com o helper https fixado, a URL desviada chega a ele, que a recusa (libcurl
                    # limitada a GIT_ALLOW_PROTOCOL): somente o esquema e relatado.
                    elseif ([string]$clone.StdErr -cmatch "unable to access '([A-Za-z][A-Za-z0-9+.-]{0,63}):" -and $Matches[1] -cne 'https') { $code = 'MA_REPOSITORY_TRANSPORT_UNSAFE'; $severity = 'Bloqueio'; $cloneDetail += '; transporte recusado pelo Git: ' + $Matches[1].ToLowerInvariant() }
                    $phaseIssues.Add((New-MaIssue $code -Severity $severity -Role 'coordination' -Path $coordinationPath -Detail $cloneDetail))
                    $remaining = Get-MaDirectoryEntries $target.Handle
                    if ($remaining.Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_CLONE_RESIDUE' -Role 'coordination' -Path $coordinationPath)) }
                    else {
                        # Destino criado nesta execucao e ainda vazio: removido pelo handle.
                        $closed = Close-MaOperationTarget $workspace $target -RemoveIfCreatedEmpty
                        [void]$targets.Remove($target)
                        & $cleanupIssue $closed.Failures
                    }
                    if ($redirected.Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_TARGET_REDIRECTED' -Role 'coordination' -Path $coordinationPath -Detail (Format-MaPathList $redirected))) }
                    break
                }
                & $record $performed 'coordination' 'Clonar' $cloneTarget 'sem checkout'
                if ($redirected.Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_TARGET_REDIRECTED' -Role 'coordination' -Path $coordinationPath -Detail (Format-MaPathList $redirected))); break }
                # Checkout somente com o clone integro (inspecao do proprio ambiente).
                $cloned = Get-MaEnvironmentInspection -Role 'coordination' -Configuration $configuration -GitAvailable $true
                if (@($cloned.Issues | Where-Object { $_.Severity -ne 'Aviso' }).Count -eq 0 -and $cloned.CheckoutPending) {
                    [void](& $checkout 'coordination' $coordinationPath $cloned $configuration.Branches.coordination)
                }
                & $inspect; $inspection = $current.Inspection
                if (& $configurationChanged) { break }
                if ((& $blocked) -or $null -eq $inspection.Rendered) { break }
                $environments = & $byRole $inspection
            } elseif ($environments.coordination.CheckoutPending) {
                # Retomada: clone sem checkout deixado por execucao anterior.
                if (-not (& $checkout 'coordination' $coordinationPath $environments.coordination $configuration.Branches.coordination)) {
                    if ($whatIf) { $pending.Add('Checkout da coordenacao simulado: destinos da coordenacao e da manutencao serao classificados apos o checkout.') }
                    break
                }
                & $inspect; $inspection = $current.Inspection
                if (& $configurationChanged) { break }
                if ($null -eq $inspection.Rendered) { break }
                $environments = & $byRole $inspection
            }
            if (& $blocked) { break }

            # 5. Base autorizada: commit local, formato e igualdade com a coordenacao.
            $coordination = $environments.coordination
            if (-not $coordination.Inspected -or -not $coordination.Head) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_COORDINATION_UNAVAILABLE' -Role 'coordination' -Path $coordinationPath)); break }
            $expectedLength = 40; if ($coordination.ObjectFormat -ceq 'sha256') { $expectedLength = 64 }
            if ($BaseCommit.Length -ne $expectedLength) { $phaseIssues.Add((New-MaIssue 'MA_BASECOMMIT_FORMAT_MISMATCH' -Role 'coordination' -Detail $coordination.ObjectFormat)); break }
            if ($inspection.BaseCommitLocal -ne $true) { $phaseIssues.Add((New-MaIssue 'MA_BASECOMMIT_NOT_LOCAL' -Role 'coordination')); break }
            $evidence.BaseCommit = $BaseCommit + ': presente localmente como commit; autorizacao nao verificada'
            $maintenance = $environments.maintenance
            $createMaintenance = (-not $maintenance.Exists -or $maintenance.State -eq 'VazioSemRepositorio')

            # 6. Manutencao ausente: branch e worktree sem checkout na base
            # autorizada, com destino e repositorio comum fixados; checkout depois.
            $createdThisRun = $false
            if ($createMaintenance) {
                if ($coordination.Head -cne $BaseCommit) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_BASE_DIVERGENT' -Role 'coordination' -Detail ('HEAD da coordenacao ' + $coordination.Head))); break }
                $refs = Get-MaBranchRefs $coordinationPath
                $branchState = Get-MaBranchCreationState $refs $configuration.Branches.maintenance
                foreach ($issue in $branchState.Issues) { $phaseIssues.Add($issue) }
                if ($null -ne $branchState.Tip -and $branchState.Tip -cne $BaseCommit) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_BASE_DIVERGENT' -Role 'maintenance' -Detail ('branch ' + $configuration.Branches.maintenance + ' existente em ' + $branchState.Tip))) }
                foreach ($issue in (Get-MaWorktreeHookIssues $coordination)) { $phaseIssues.Add($issue) }
                if (& $blocked) { break }
                # Verificacao previa do checkout na base: nada e criado se o checkout da
                # manutencao nao puder ser comprovadamente seguro.
                $preflight = Get-MaCheckoutSafety -Root $coordinationPath -Commit $BaseCommit -Role 'maintenance' -Environment $coordination
                foreach ($issue in $preflight.Issues) { $phaseIssues.Add($issue) }
                if (& $blocked) { break }
                $branchExists = ($null -ne $branchState.Tip)
                $worktreeDetail = $(if ($branchExists) { 'branch existente ' + $configuration.Branches.maintenance + ' em ' + $BaseCommit + ', sem reposicionamento' } else { 'nova branch ' + $configuration.Branches.maintenance + ' em ' + $BaseCommit }) + '; sem checkout'
                if ($whatIf) {
                    & $record $simulated 'maintenance' 'Criar worktree' $maintenancePath $worktreeDetail
                    & $record $simulated 'maintenance' 'Checkout' $maintenancePath ('read-tree de ' + $BaseCommit + '; sem filtro, hook, submodulo ou origem alternativa de atributos')
                    # Previsao pela coordenacao: a manutencao nasce do mesmo commit.
                    foreach ($file in @($inspection.Files | Where-Object { $_.Role -eq 'coordination' -and $_.Classification -eq 'Ausente' })) {
                        & $record $simulated 'maintenance' 'Gerar' $file.Path ($file.ExpectedMode + ' sha256 ' + $file.ExpectedSha256)
                    }
                    $pending.Add('Geracao prevista a partir da coordenacao; a manutencao sera classificada novamente apos sua criacao.')
                    break
                }
                # Coordenacao, .git, .git\worktrees (se existir) e destino fixados.
                $adminPinned = $false
                try {
                    $common = New-MaPinnedChain ([IO.Path]::Combine($coordinationPath, '.git')) $workspace.Leaf
                    $chains.Add($common)
                    [void](Add-MaPinnedComponent $common (Get-MaChildName $workspace $coordinationPath))
                    [void](Add-MaPinnedComponent $common '.git')
                    try { [void](Add-MaPinnedComponent $common 'worktrees'); $adminPinned = $true }
                    catch { if ((Get-MaErrorCode $_ '') -cne 'MA_PATH_NOT_FOUND') { throw } }
                    $target = Open-MaOperationTarget $workspace $maintenancePath
                    $targets.Add($target)
                } catch {
                    $code = Get-MaErrorCode $_ 'MA_PATH_INSPECTION_FAILED'
                    if ($code -ceq 'MA_PREPARE_TARGET_CHANGED') { $code = 'MA_PREPARE_STATE_CHANGED' }
                    $phaseIssues.Add((New-MaIssue $code -Role 'maintenance' -Path $maintenancePath -Detail (Get-MaErrorDetail $_))); break
                }
                # Revalidacao imediata: destino vazio pelo handle, HEAD da coordenacao e branches.
                $now = Get-MaHeadState $coordinationPath
                $refsNow = Get-MaBranchRefs $coordinationPath
                $sameRefs = ($refsNow.Count -eq $refs.Count)
                foreach ($name in $refs.Keys) { if (-not $refsNow.ContainsKey($name) -or $refsNow[$name] -cne $refs[$name]) { $sameRefs = $false } }
                if (@($target.Entries).Count -gt 0 -or $now.Commit -cne $BaseCommit -or $now.Branch -cne $configuration.Branches.coordination -or -not $sameRefs) {
                    $phaseIssues.Add((New-MaIssue 'MA_PREPARE_STATE_CHANGED' -Role 'maintenance' -Path $maintenancePath))
                    # Destino criado nesta execucao e ainda vazio: removido pelo handle.
                    $closed = Close-MaOperationTarget $workspace $target -RemoveIfCreatedEmpty
                    [void]$targets.Remove($target)
                    & $cleanupIssue $closed.Failures
                    break
                }
                if ($branchExists) { $worktreeArguments = @('worktree', 'add', '--quiet', '--no-checkout', '--', $maintenancePath, $configuration.Branches.maintenance) }
                else { $worktreeArguments = @('worktree', 'add', '--quiet', '--no-checkout', '-b', $configuration.Branches.maintenance, '--', $maintenancePath, $BaseCommit) }
                $worktree = Invoke-MaGit $coordinationPath $worktreeArguments
                # Pontos de reparse no destino e no diretorio administrativo de worktrees.
                $redirected = New-Object System.Collections.Generic.List[string]
                $redirected.AddRange((Get-MaReparseEntries $target.Handle))
                try {
                    if (-not $adminPinned) { [void](Add-MaPinnedComponent $common 'worktrees'); $adminPinned = $true }
                    foreach ($name in (Get-MaReparseEntries $common.Leaf)) { $redirected.Add('.git/worktrees/' + $name) }
                } catch {
                    $code = Get-MaErrorCode $_ ''
                    if ($code -ceq 'MA_PATH_REPARSE_POINT') { $redirected.Add('.git/worktrees') }
                    elseif ($code -cne 'MA_PATH_NOT_FOUND') { throw }
                }
                $redirected = $redirected.ToArray()
                if ($worktree.ExitCode -ne 0) {
                    $phaseIssues.Add((New-MaIssue 'MA_PREPARE_WORKTREE_FAILED' -Severity 'Falha' -Role 'maintenance' -Path $maintenancePath -Detail ('git worktree add ' + $worktree.ExitCode)))
                    $refsAfter = Get-MaBranchRefs $coordinationPath
                    if (-not $branchExists -and $refsAfter.ContainsKey($configuration.Branches.maintenance)) { & $record $performed 'maintenance' 'Criar branch' $configuration.Branches.maintenance ('em ' + $refsAfter[$configuration.Branches.maintenance] + '; preservada') }
                    $remaining = Get-MaDirectoryEntries $target.Handle
                    if ($remaining.Count -gt 0) { & $record $performed 'maintenance' 'Criar worktree (parcial)' $maintenancePath 'preservado sem remocao automatica' }
                    else {
                        $closed = Close-MaOperationTarget $workspace $target -RemoveIfCreatedEmpty
                        [void]$targets.Remove($target)
                        & $cleanupIssue $closed.Failures
                    }
                    if ($redirected.Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_TARGET_REDIRECTED' -Role 'maintenance' -Path $maintenancePath -Detail (Format-MaPathList $redirected))) }
                    break
                }
                & $record $performed 'maintenance' 'Criar worktree' $maintenancePath $worktreeDetail
                if ($redirected.Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_TARGET_REDIRECTED' -Role 'maintenance' -Path $maintenancePath -Detail (Format-MaPathList $redirected))); break }
                $createdThisRun = $true
                $created = Get-MaEnvironmentInspection -Role 'maintenance' -Configuration $configuration -GitAvailable $true
                if (@($created.Issues | Where-Object { $_.Severity -ne 'Aviso' }).Count -eq 0 -and $created.CheckoutPending) {
                    [void](& $checkout 'maintenance' $maintenancePath $created $configuration.Branches.maintenance)
                }
                & $inspect; $inspection = $current.Inspection
                if (& $configurationChanged) { break }
                if ((& $blocked) -or $null -eq $inspection.Rendered) { break }
                $environments = & $byRole $inspection
                $maintenance = $environments.maintenance
            } elseif ($maintenance.CheckoutPending) {
                # Retomada: worktree sem checkout deixado por execucao anterior, na base.
                if ($maintenance.Head -cne $BaseCommit) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_BASE_DIVERGENT' -Role 'maintenance' -Detail ('HEAD da manutencao ' + $maintenance.Head + ' com checkout pendente'))); break }
                if (-not (& $checkout 'maintenance' $maintenancePath $maintenance $configuration.Branches.maintenance)) { break }
                & $inspect; $inspection = $current.Inspection
                if (& $configurationChanged) { break }
                if ((& $blocked) -or $null -eq $inspection.Rendered) { break }
                $environments = & $byRole $inspection
                $maintenance = $environments.maintenance
            }

            # 7. Manutencao existente: base, alteracoes alheias e destinos.
            if (-not $maintenance.Inspected -or -not $maintenance.Head) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_MAINTENANCE_UNAVAILABLE' -Role 'maintenance' -Path $maintenancePath)); break }
            $missing = @($inspection.Files | Where-Object { $_.Role -eq 'maintenance' -and $_.Classification -eq 'Ausente' } | ForEach-Object { $_.Path })
            if ($maintenance.Head -cne $BaseCommit) {
                # Depois do commit da preparacao, a manutencao avanca a partir da base;
                # a repeticao so e aceita se nada mais precisar ser gerado.
                $ancestor = Invoke-MaGit $maintenancePath @('merge-base', '--is-ancestor', $BaseCommit, $maintenance.Head)
                if ($ancestor.ExitCode -eq 1) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_BASE_DIVERGENT' -Role 'maintenance' -Detail ('HEAD da manutencao ' + $maintenance.Head + ' nao deriva do BaseCommit'))) }
                elseif ($ancestor.ExitCode -ne 0) { $phaseIssues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role 'maintenance' -Path $maintenancePath -Detail 'merge-base')) }
                elseif ($missing.Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_BASE_DIVERGENT' -Role 'maintenance' -Detail ('HEAD da manutencao ' + $maintenance.Head + ' avancou alem do BaseCommit; geracao recusada'))) }
            }
            # Worktree recem-criado nao tem alteracoes alheias; o existente e conferido.
            if (-not $createdThisRun) { foreach ($issue in (Get-MaForeignChangeIssues $maintenance)) { $phaseIssues.Add($issue) } }
            foreach ($issue in (Get-MaIgnoredPathIssues $maintenance $missing)) { $phaseIssues.Add($issue) }
            if ((& $blocked) -or $missing.Count -eq 0) { break }
            $toGenerate = @($inspection.Rendered | Where-Object { $missing -ccontains $_.Path })
            if ($whatIf) {
                foreach ($file in $toGenerate) { & $record $simulated 'maintenance' 'Gerar' $file.Path ($file.GitMode + ' sha256 ' + $file.Sha256) }
                break
            }

            # 8. Geracao: somente destinos ausentes, cada um revalidado antes da gravacao.
            $expectedHead = $maintenance.Head
            $stopped = $false
            foreach ($file in $toGenerate) {
                $now = Get-MaHeadState $maintenancePath
                $indexed = Invoke-MaGit $maintenancePath @('ls-files', '-s', '-z', '--', $file.Path)
                if ($now.Commit -cne $expectedHead -or $now.Branch -cne $configuration.Branches.maintenance -or $indexed.ExitCode -ne 0 -or $indexed.StdOut) {
                    $phaseIssues.Add((New-MaIssue 'MA_PREPARE_STATE_CHANGED' -Role 'maintenance' -Path $file.Path)); $stopped = $true; break
                }
                try { $directories = New-MaGovernedFile $maintenancePath $file.Path $file.Bytes }
                catch {
                    $code = Get-MaErrorCode $_ 'MA_PREPARE_WRITE_FAILED'
                    $severity = 'Bloqueio'; if ($code -in @('MA_PREPARE_WRITE_FAILED', 'MA_PREPARE_WRITE_VERIFY_FAILED', 'MA_NATIVE_CLEANUP_FAILED', 'MA_PATH_HANDLE_UNAVAILABLE')) { $severity = 'Falha' }
                    $phaseIssues.Add((New-MaIssue $code -Severity $severity -Role 'maintenance' -Path $file.Path -Detail (Get-MaErrorDetail $_))); $stopped = $true; break
                }
                foreach ($directory in $directories) { & $record $performed 'maintenance' 'Criar diretorio' $directory '' }
                & $record $performed 'maintenance' 'Gerar' $file.Path ($file.GitMode + ' sha256 ' + $file.Sha256)
            }
            if ($stopped) { break }

            # 9. Verificacao final: os onze destinos da manutencao identicos ou preparados.
            & $inspect; $inspection = $current.Inspection
            if (& $configurationChanged) { break }
            if (& $blocked) { break }
            $prepared = @($inspection.Files | Where-Object { $_.Role -eq 'maintenance' -and $_.Classification -in @('Identico', 'PreparadoNaoCommitado') })
            if ($prepared.Count -ne @(Get-MaGovernedPaths).Count) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_VERIFY_FAILED' -Severity 'Falha' -Role 'maintenance' -Detail ([string]$prepared.Count + ' de ' + @(Get-MaGovernedPaths).Count))) }
        } while ($false)
    } catch {
        $phaseIssues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PREPARE_UNEXPECTED_FAILURE') -Severity 'Falha' -Detail (Get-MaErrorDetail $_)))
    } finally {
        $inspection = $current.Inspection
        # Handles fechados antes de liberar o mutex; nenhuma falha e descartada.
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($target in @($targets.ToArray())) { foreach ($failure in (Close-MaOperationTarget $workspace $target).Failures) { $failures.Add($failure) } }
        foreach ($chain in @($chains.ToArray())) { foreach ($failure in (Close-MaPinnedChain $chain)) { $failures.Add($failure) } }
        foreach ($failure in (Close-MaPinnedChain $workspace)) { $failures.Add($failure) }
        & $cleanupIssue $failures.ToArray()
        try { Exit-MaRepositoryLock $lock } catch { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_LOCK_RELEASE_FAILED' -Severity 'Aviso')) }
    }
    foreach ($item in $inspection.Pending) { $pending.Add($item) }
    $pending.Add('Preparacao do indice, commit, push, PR, revisao cruzada e merge humano ficam fora do instalador, sob autorizacao humana propria.')
    $pending.Add('Ao preparar o indice (fora do instalador), registrar o modo 100755 dos hooks: o Windows nao guarda o bit executavel no sistema de arquivos (git update-index --chmod=+x -- .githooks/pre-commit .githooks/pre-push).')
    $pending.Add('Codex, Claude e a ativacao de hooks pertencem a CompleteWorktrees, apos integracao comprovada.')
    $pending.Add('Autorizacao humana nao verificada pelo instalador; a referencia e registrada apenas como evidencia fornecida.')
    $pending.Add('Estado remoto, protecao de branches e PRs nao verificados.')
    $pending.Add('Origem confiavel do pacote nao comprovada pelo manifesto; modos Git do pacote nao conferidos no indice de origem.')
    $issueArray = @(@($inspection.Issues.ToArray()) + @($phaseIssues.ToArray()))
    $status = Get-MaPlanStatus $issueArray ($simulated.Count -gt 0)
    return [pscustomobject]@{
        Phase         = 'PrepareMaintenance'
        Status        = $status
        WhatIf        = $whatIf
        Modified      = ($performed.Count -gt 0)
        Partial       = ($performed.Count -gt 0 -and $status -cne 'Sucesso')
        Package       = $inspection.Package
        Configuration = (ConvertTo-MaConfigurationSummary $inspection.Configuration)
        Git           = $inspection.Git
        Environments  = @(ConvertTo-MaEnvironmentSummary $inspection.Environments)
        Files         = $inspection.Files.ToArray()
        Performed     = $performed.ToArray()
        Simulated     = $simulated.ToArray()
        Issues        = $issueArray
        Pending       = $pending.ToArray()
        Evidence      = [pscustomobject]$evidence
    }
}

function Format-MaPrepareReport {
    param([Parameter(Mandatory = $true)]$Result)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Fase: ' + $Result.Phase)
    $lines.Add('Resultado: ' + $Result.Status)
    if ($Result.Partial) { $lines.Add('Execucao parcial: operacoes realizadas foram preservadas, sem reversao automatica; a fase nao esta concluida.') }
    if ($Result.WhatIf) { $lines.Add('WhatIf: simulacao; nenhuma operacao mutavel foi executada.') }
    if ($null -ne $Result.Package) {
        $integrity = 'invalida'; if ($Result.Package.Valid) { $integrity = 'valida' }
        $lines.Add('Pacote: versao ' + [string]$Result.Package.DistributionVersion + '; integridade ' + $integrity + ' (nao comprova origem).')
    }
    if ($null -ne $Result.Configuration) {
        $lines.Add('Projeto: ' + $Result.Configuration.Slug + ' | repositorio: ' + $Result.Configuration.RepositoryUrl)
        $lines.Add('Diretorio pai: ' + $Result.Configuration.ParentDirectory)
    }
    if ($null -ne $Result.Git) { $lines.Add('Git: ' + [string]$Result.Git.Path + ' ' + [string]$Result.Git.Version) }
    if (@($Result.Environments).Count -gt 0) {
        $lines.Add(''); $lines.Add('Ambientes (apos a execucao):')
        foreach ($environment in $Result.Environments) { $lines.Add('  [' + $environment.Role + '] ' + $environment.Path + ' | branch ' + $environment.ExpectedBranch + ' | ' + $environment.State + $(if ($environment.Head) { ' | HEAD ' + $environment.Head } else { '' })) }
    }
    if (@($Result.Files).Count -gt 0) {
        $lines.Add(''); $lines.Add('Destinos governados:')
        foreach ($file in $Result.Files) {
            $line = '  [' + $file.Role + '] ' + $file.Path + ' | ' + $file.Classification + ' | ' + $file.ExpectedMode + ' ' + $file.ExpectedObjectId
            if ($file.Reason) { $line += ' | ' + $file.Reason }
            $lines.Add($line)
        }
    }
    foreach ($group in @(@($Result.Performed, 'Acoes realizadas:'), @($Result.Simulated, 'Acoes simuladas (WhatIf, nenhuma executada):'))) {
        if (@($group[0]).Count -eq 0) { continue }
        $lines.Add(''); $lines.Add($group[1])
        foreach ($action in $group[0]) {
            $line = '  ' + $action.Order + '. [' + $action.Role + '] ' + $action.Operation + ' ' + $action.Target
            if ($action.Detail) { $line += ' (' + $action.Detail + ')' }
            $lines.Add($line)
        }
    }
    foreach ($group in @(@('Falha', 'Falhas operacionais:'), @('Bloqueio', 'Impedimentos:'), @('Aviso', 'Avisos:'))) {
        $selected = @($Result.Issues | Where-Object { $_.Severity -eq $group[0] })
        if ($selected.Count -eq 0) { continue }
        $lines.Add(''); $lines.Add($group[1])
        foreach ($issue in $selected) {
            $line = '  - ' + $issue.Code + ': ' + $issue.Message
            $where = @(@($issue.Role, $issue.Path, $issue.Detail) | Where-Object { $_ })
            if ($where.Count -gt 0) { $line += ' (' + ($where -join ' | ') + ')' }
            $lines.Add($line)
        }
    }
    $lines.Add(''); $lines.Add('Evidencias:')
    foreach ($property in $Result.Evidence.PSObject.Properties) { $lines.Add('  ' + $property.Name + ': ' + $property.Value) }
    if (@($Result.Pending).Count -gt 0) {
        $lines.Add(''); $lines.Add('Verificacoes pendentes:')
        foreach ($item in $Result.Pending) { $lines.Add('  - ' + $item) }
    }
    $lines.Add('')
    if ($Result.Modified) { $lines.Add('Modificacoes realizadas: ' + @($Result.Performed).Count + ' operacao(oes); nenhum commit, indice, push ou PR.') }
    else { $lines.Add('Nenhuma modificacao foi realizada.') }
    return , $lines.ToArray()
}

# --- CompleteWorktrees -------------------------------------------------------------
# Contrato (especificacao 5, 6 e 7): integracao comprovada, coordenacao ja
# sincronizada pelo responsavel, conteudo governado verificado e autorizacao
# abrangente. Cria Codex e Claude ausentes na base integrada (I), sem reposicionar
# branches existentes; confere os quatro ambientes; e insere core.hooksPath=.githooks
# na configuracao local do repositorio comum somente se a politica de hooks da
# secao 7 permitir. Nunca faz fetch, sincroniza a coordenacao, reposiciona a
# manutencao, integra historicos, prepara o indice, faz commit, push, PR ou merge.
# Cada operacao mutavel e precedida de revalidacao; falhas apos uma operacao sao
# relatadas como execucao parcial, sem reversao destrutiva. Worktrees criados antes
# da descoberta de um conflito sao preservados e a ativacao fica bloqueada.
#
# Evidencia de integracao (IntegrationReference): caminho local de um registro
# JSON 1.0, fora dos quatro worktrees, conferido campo a campo contra a
# configuracao, os parametros e os objetos Git locais. O registro e evidencia
# fornecida pelo responsavel: o instalador nao consulta o servidor nem infere
# aprovacao da existencia do arquivo, de texto ou de booleano (nenhum e aceito).
# Todos os campos sao obrigatorios; textos tem uma linha, sem controles, ate 500
# caracteres, e nunca sao reproduzidos no relatorio (somente o SHA-256 do registro):
#   evidenceVersion          "1.0"
#   repository               URL configurada (igualdade exata)
#   pullRequest              referencia do PR
#   sourceBranch             branch de manutencao configurada
#   targetBranch             branch de coordenacao configurada
#   reviewedHead             M: SHA completo do HEAD revisado do PR
#   review                   { reviewer, author, reference, reviewedHead = M }; reviewer distinto de author
#   mergeAuthorization       { authorizedBy, reference, pullRequest = pullRequest, reviewedHead = M }
#   integration              { result = "merged", method (merge, squash ou rebase),
#                              resultingCommit = I = IntegratedCommit, executedBy, proofSource }
#   completionAuthorization  { authorizedBy, reference = AuthorizationReference, integratedCommit = I,
#                              environments (diretorios abrangidos), operations
#                              (create-worktrees e/ou configure-hooks) }
# create-worktrees cobre a criacao dos ambientes ausentes listados; configure-hooks
# exige os quatro diretorios, pois a configuracao local e compartilhada por todos.

$script:MaEvidenceMaxBytes = 65536
$script:MaCompleteOperations = @('create-worktrees', 'configure-hooks')
$script:MaIntegrationMethods = @('merge', 'squash', 'rebase')
$script:MaHooksPathValue = '.githooks'

# Objeto do registro: devolve $true se for objeto; chaves desconhecidas (citadas
# somente se forem identificadores simples) e ausentes sao relatadas.
function Test-MaEvidenceObject {
    param($Value, [string]$Name, [string[]]$Keys, $Issues)
    if ($Value -isnot [System.Collections.IDictionary]) { $Issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_INVALID' -Detail ($Name + ': objeto esperado'))); return $false }
    foreach ($key in @($Value.Keys)) {
        if ($Keys -cnotcontains [string]$key) {
            $label = 'propriedade desconhecida'; if ([string]$key -cmatch '\A[A-Za-z][A-Za-z0-9]{0,40}\z') { $label += ' ' + $key }
            $Issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_INVALID' -Detail ($Name + ': ' + $label)))
        }
    }
    foreach ($key in $Keys) { if (-not (Test-MaExactKey $Value $key)) { $Issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_INVALID' -Detail ($Name + '.' + $key + ': ausente'))) } }
    return $true
}

# Secao (objeto) presente com a grafia exata; $null se ausente ou invalida.
function Get-MaEvidenceSection {
    param($Object, [string]$Key, [string[]]$Keys, $Issues)
    if (-not (Test-MaExactKey $Object $Key)) { return $null }
    $value = $Object[$Key]
    if (-not (Test-MaEvidenceObject $value $Key $Keys $Issues)) { return $null }
    return $value
}

# Texto de uma linha, sem controles, com ate 500 caracteres; $null se ausente ou invalido.
function Get-MaEvidenceText {
    param($Object, [string]$Key, [string]$Name, $Issues)
    if ($Object -isnot [System.Collections.IDictionary] -or -not (Test-MaExactKey $Object $Key)) { return $null }
    $value = $Object[$Key]
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]' -or (Get-MaCodePointLength $value) -gt $script:MaAuthorizationReferenceMaxLength) {
        $Issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_INVALID' -Detail ($Name + '.' + $Key + ': texto de uma linha, sem controles, com ate 500 caracteres')))
        return $null
    }
    return $value
}

function Get-MaEvidenceCommit {
    param($Object, [string]$Key, [string]$Name, $Issues)
    $value = Get-MaEvidenceText $Object $Key $Name $Issues
    if ($null -ne $value -and -not (Test-MaFullCommit $value)) { $Issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_INVALID' -Detail ($Name + '.' + $Key + ': SHA completo esperado'))); return $null }
    return $value
}

# Lista nao vazia, sem repeticao, de valores permitidos; $null se ausente ou invalida.
function Get-MaEvidenceList {
    param($Object, [string]$Key, [string]$Name, [string[]]$Allowed, $Issues)
    if ($Object -isnot [System.Collections.IDictionary] -or -not (Test-MaExactKey $Object $Key)) { return $null }
    $value = $Object[$Key]
    $items = New-Object System.Collections.Generic.List[string]
    $valid = ($value -is [object[]] -and $value.Count -gt 0)
    if ($valid) { foreach ($item in $value) { if ($item -isnot [string] -or $Allowed -cnotcontains $item -or $items.Contains($item)) { $valid = $false } else { $items.Add($item) } } }
    if (-not $valid) { $Issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_INVALID' -Detail ($Name + '.' + $Key + ': lista nao vazia, sem repeticao, de: ' + ($Allowed -join ', ')))); return $null }
    return , $items.ToArray()
}

# Le e confere o registro de integracao (formato no inicio desta secao). Devolve
# Valid, Sha256 dos bytes lidos, ReviewedHead (M), IntegratedCommit (I), Method,
# Operations, Environments e Issues. Nenhum texto do registro entra nas ocorrencias.
# AuthorizationOptional (somente Validate, que nao executa operacao autorizada):
# sem AuthorizationReference, completionAuthorization.reference nao e comparada.
function Read-MaIntegrationEvidence {
    param([AllowEmptyString()][string]$LiteralPath, [Parameter(Mandatory = $true)]$Configuration, [AllowEmptyString()][string]$AuthorizationReference = '', [AllowEmptyString()][string]$IntegratedCommit = '', [switch]$AuthorizationOptional)
    $issues = New-Object System.Collections.Generic.List[object]
    $evidence = [ordered]@{ Valid = $false; Sha256 = $null; ReviewedHead = $null; IntegratedCommit = $null; Method = $null; Operations = @(); Environments = @(); Issues = @() }
    $finish = { $evidence.Valid = ($issues.Count -eq 0); $evidence.Issues = $issues.ToArray(); return [pscustomobject]$evidence }
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { $issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_REQUIRED')); return (& $finish) }
    $data = $null
    try {
        $path = Assert-MaSafePath $LiteralPath 'File'
        foreach ($role in $script:MaRoles) { if (Test-MaPathWithin $path $Configuration.Worktrees[$role]) { throw 'MA_INTEGRATION_REFERENCE_INSIDE_WORKTREE' } }
        if ((New-Object IO.FileInfo $path).Length -gt $script:MaEvidenceMaxBytes) { throw 'MA_INTEGRATION_REFERENCE_INVALID' }
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -gt $script:MaEvidenceMaxBytes) { throw 'MA_INTEGRATION_REFERENCE_INVALID' }
        $evidence.Sha256 = Get-MaSha256 $bytes
        $data = Read-MaJsonStrict (ConvertFrom-MaUtf8Bytes $bytes)
    } catch {
        $code = Get-MaErrorCode $_ 'MA_INTEGRATION_REFERENCE_INVALID'
        $detail = ''
        if ($code -cnotin @('MA_INTEGRATION_REFERENCE_INSIDE_WORKTREE', 'MA_INTEGRATION_REFERENCE_INVALID')) { $detail = $code; $code = 'MA_INTEGRATION_REFERENCE_INVALID' }
        $issues.Add((New-MaIssue $code -Path $LiteralPath -Detail $detail))
        return (& $finish)
    }
    $topKeys = @('evidenceVersion', 'repository', 'pullRequest', 'sourceBranch', 'targetBranch', 'reviewedHead', 'review', 'mergeAuthorization', 'integration', 'completionAuthorization')
    if (-not (Test-MaEvidenceObject $data 'registro' $topKeys $issues)) { return (& $finish) }
    $mismatch = { param([string]$Detail) $issues.Add((New-MaIssue 'MA_INTEGRATION_EVIDENCE_MISMATCH' -Detail $Detail)) }
    if ((Test-MaExactKey $data 'evidenceVersion') -and ($data['evidenceVersion'] -isnot [string] -or $data['evidenceVersion'] -cne '1.0')) { $issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_INVALID' -Detail 'registro.evidenceVersion: "1.0" esperado')) }
    $repository = Get-MaEvidenceText $data 'repository' 'registro' $issues
    if ($null -ne $repository -and $repository -cne $Configuration.RepositoryUrl) { & $mismatch 'repository: diferente da URL configurada' }
    $pullRequest = Get-MaEvidenceText $data 'pullRequest' 'registro' $issues
    $source = Get-MaEvidenceText $data 'sourceBranch' 'registro' $issues
    if ($null -ne $source -and $source -cne $Configuration.Branches.maintenance) { & $mismatch ('sourceBranch: diferente de ' + $Configuration.Branches.maintenance) }
    $target = Get-MaEvidenceText $data 'targetBranch' 'registro' $issues
    if ($null -ne $target -and $target -cne $Configuration.Branches.coordination) { & $mismatch ('targetBranch: diferente de ' + $Configuration.Branches.coordination) }
    $reviewed = Get-MaEvidenceCommit $data 'reviewedHead' 'registro' $issues
    $evidence.ReviewedHead = $reviewed

    # Revisao independente vinculada a M.
    $review = Get-MaEvidenceSection $data 'review' @('reviewer', 'author', 'reference', 'reviewedHead') $issues
    if ($null -ne $review) {
        $reviewer = Get-MaEvidenceText $review 'reviewer' 'review' $issues
        $author = Get-MaEvidenceText $review 'author' 'review' $issues
        [void](Get-MaEvidenceText $review 'reference' 'review' $issues)
        $head = Get-MaEvidenceCommit $review 'reviewedHead' 'review' $issues
        if ($null -ne $head -and $null -ne $reviewed -and $head -cne $reviewed) { & $mismatch 'review.reviewedHead: diferente de reviewedHead' }
        if ($null -ne $reviewer -and $null -ne $author -and $reviewer.Trim().Equals($author.Trim(), [StringComparison]::OrdinalIgnoreCase)) { $issues.Add((New-MaIssue 'MA_INTEGRATION_REVIEW_NOT_INDEPENDENT')) }
    }

    # Autorizacao humana do merge vinculada ao PR e a M.
    $merge = Get-MaEvidenceSection $data 'mergeAuthorization' @('authorizedBy', 'reference', 'pullRequest', 'reviewedHead') $issues
    if ($null -ne $merge) {
        [void](Get-MaEvidenceText $merge 'authorizedBy' 'mergeAuthorization' $issues)
        [void](Get-MaEvidenceText $merge 'reference' 'mergeAuthorization' $issues)
        $mergePullRequest = Get-MaEvidenceText $merge 'pullRequest' 'mergeAuthorization' $issues
        if ($null -ne $mergePullRequest -and $null -ne $pullRequest -and $mergePullRequest -cne $pullRequest) { & $mismatch 'mergeAuthorization.pullRequest: diferente de pullRequest' }
        $head = Get-MaEvidenceCommit $merge 'reviewedHead' 'mergeAuthorization' $issues
        if ($null -ne $head -and $null -ne $reviewed -and $head -cne $reviewed) { & $mismatch 'mergeAuthorization.reviewedHead: diferente de reviewedHead' }
    }

    # Resultado da integracao, commit resultante e origem da comprovacao do merge humano.
    $resulting = $null
    $integration = Get-MaEvidenceSection $data 'integration' @('result', 'method', 'resultingCommit', 'executedBy', 'proofSource') $issues
    if ($null -ne $integration) {
        $result = Get-MaEvidenceText $integration 'result' 'integration' $issues
        if ($null -ne $result -and $result -cne 'merged') { $issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_INVALID' -Detail 'integration.result: "merged" esperado')) }
        $method = Get-MaEvidenceText $integration 'method' 'integration' $issues
        if ($null -ne $method -and $script:MaIntegrationMethods -cnotcontains $method) { $issues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_INVALID' -Detail ('integration.method: ' + ($script:MaIntegrationMethods -join ', ')))) }
        else { $evidence.Method = $method }
        $resulting = Get-MaEvidenceCommit $integration 'resultingCommit' 'integration' $issues
        [void](Get-MaEvidenceText $integration 'executedBy' 'integration' $issues)
        [void](Get-MaEvidenceText $integration 'proofSource' 'integration' $issues)
        if ($null -ne $resulting -and $IntegratedCommit -and $resulting -cne $IntegratedCommit) { & $mismatch 'integration.resultingCommit: diferente de IntegratedCommit' }
    }
    $evidence.IntegratedCommit = $resulting

    # Autorizacao humana desta conclusao: referencia, commit integrado e alcance.
    $completion = Get-MaEvidenceSection $data 'completionAuthorization' @('authorizedBy', 'reference', 'integratedCommit', 'environments', 'operations') $issues
    if ($null -ne $completion) {
        [void](Get-MaEvidenceText $completion 'authorizedBy' 'completionAuthorization' $issues)
        $reference = Get-MaEvidenceText $completion 'reference' 'completionAuthorization' $issues
        $compareReference = -not ($AuthorizationOptional -and [string]::IsNullOrEmpty($AuthorizationReference))
        if ($null -ne $reference -and $compareReference -and $reference -cne $AuthorizationReference) { & $mismatch 'completionAuthorization.reference: diferente de AuthorizationReference' }
        $authorizedCommit = Get-MaEvidenceCommit $completion 'integratedCommit' 'completionAuthorization' $issues
        if ($null -ne $authorizedCommit -and $null -ne $resulting -and $authorizedCommit -cne $resulting) { & $mismatch 'completionAuthorization.integratedCommit: diferente de integration.resultingCommit' }
        $directories = @(foreach ($role in $script:MaRoles) { [string]$Configuration.Directories[$role] })
        $environments = Get-MaEvidenceList $completion 'environments' 'completionAuthorization' $directories $issues
        if ($null -ne $environments) { $evidence.Environments = $environments }
        $operations = Get-MaEvidenceList $completion 'operations' 'completionAuthorization' $script:MaCompleteOperations $issues
        if ($null -ne $operations) { $evidence.Operations = $operations }
    }
    return (& $finish)
}

# Entradas de ls-tree -r -z com grafia exata (dicionario ordinal): caminho -> Mode,
# Type e ObjectId. Lanca MA_ENV_GIT_UNREADABLE se a saida for malformada.
function Get-MaTreeListing {
    param([string]$Text)
    $entries = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($record in (Split-MaNullFields $Text)) {
        $tab = $record.IndexOf([char]9)
        if ($tab -lt 0) { throw 'MA_ENV_GIT_UNREADABLE' }
        $meta = $record.Substring(0, $tab).Split(' ')
        $path = $record.Substring($tab + 1)
        if ($meta.Length -ne 3 -or $entries.ContainsKey($path)) { throw 'MA_ENV_GIT_UNREADABLE' }
        $entries[$path] = [pscustomobject]@{ Mode = $meta[0]; Type = $meta[1]; ObjectId = $meta[2] }
    }
    return , $entries
}

# Conteudo governado de um commit (especificacao 7, passos 2 a 6): o conjunto
# obrigatorio vem do pacote confiavel (RenderedFiles), nao do manifesto do
# consumidor; a arvore real e enumerada inteira, sem checkout, filtros, textconv ou
# busca remota; cada caminho e comparado em existencia, tipo, modo e bytes lidos do
# banco de objetos, sem normalizacao. Links (120000) e gitlinks sao rejeitados.
# Entradas extras nos diretorios exclusivos, o arquivo no lugar de diretorio
# exclusivo e grafias que diferem somente por caixa (colidiriam no checkout do
# Windows) sao inesperadas. Devolve Entries (relatorio por caminho) e Issues.
function Get-MaGovernedCommitComparison {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Commit, [Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][object[]]$RenderedFiles, [string]$ObjectFormat = 'sha1', [string]$Role = 'coordination')
    $issues = New-Object System.Collections.Generic.List[object]
    $entries = New-Object System.Collections.Generic.List[object]
    $done = { [pscustomobject]@{ Entries = $entries.ToArray(); Issues = $issues.ToArray() } }
    $listing = Invoke-MaGit $Root @('ls-tree', '-r', '-z', '--full-tree', $Commit)
    $tree = $null
    if ($listing.ExitCode -eq 0) { try { $tree = Get-MaTreeListing ([string]$listing.StdOut) } catch { $tree = $null } }
    if ($null -eq $tree) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $Root -Detail ('ls-tree ' + $Label + ' ' + $Commit))); return (& $done) }
    $governed = @($RenderedFiles | ForEach-Object { $_.Path })
    $relevant = Get-MaGovernedPathPattern $governed
    $objectCodes = @{ Missing = 'MA_GIT_OBJECT_MISSING'; Unreadable = 'MA_GIT_OBJECT_UNREADABLE'; Corrupt = 'MA_GIT_OBJECT_CORRUPT'; TypeMismatch = 'MA_GIT_OBJECT_TYPE_MISMATCH'; Undetermined = 'MA_GIT_OBJECT_UNVERIFIED' }
    foreach ($file in $RenderedFiles) {
        $expectedId = Get-MaGitBlobId $file.Bytes $ObjectFormat
        $reasons = New-Object System.Collections.Generic.List[string]
        $entry = $null; if ($tree.ContainsKey($file.Path)) { $entry = $tree[$file.Path] }
        $sha = $null
        if ($null -eq $entry) { $reasons.Add('ausente') }
        else {
            if ($entry.Type -cne 'blob') { $reasons.Add('tipo ' + $entry.Type) }
            elseif ($entry.Mode -ceq '120000') { $reasons.Add('link simbolico') }
            elseif ($entry.Mode -cne $file.GitMode) { $reasons.Add('modo ' + $entry.Mode) }
            if ($entry.Type -ceq 'blob') {
                $read = Read-MaGitObject $Root $entry.ObjectId $ObjectFormat 'blob'
                if ($read.Status -cne 'Ok') {
                    $reasons.Add('objeto ' + $read.Status)
                    $code = 'MA_GIT_OBJECT_UNVERIFIED'; if ($objectCodes.ContainsKey([string]$read.Status)) { $code = $objectCodes[[string]$read.Status] }
                    $issues.Add((New-MaIssue $code -Role $Role -Path $file.Path -Detail ($Label + ' ' + $entry.ObjectId)))
                } else {
                    $sha = Get-MaSha256 $read.Bytes
                    if (-not (Test-MaBytesEqual $read.Bytes $file.Bytes)) { $reasons.Add('bytes divergentes') }
                }
            }
        }
        $result = 'Conforme'; if ($reasons.Count -gt 0) { $result = 'Divergente' }
        $entries.Add([pscustomobject]@{
            Source = $Label; Commit = $Commit; Path = $file.Path; Result = $result; Reason = ($reasons -join '; ')
            Mode = $(if ($null -ne $entry) { $entry.Mode } else { '' }); Type = $(if ($null -ne $entry) { $entry.Type } else { '' })
            ObjectId = $(if ($null -ne $entry) { $entry.ObjectId } else { '' }); Sha256 = $sha
            ExpectedMode = $file.GitMode; ExpectedObjectId = $expectedId; ExpectedSha256 = $file.Sha256
        })
        if ($result -ceq 'Divergente' -and @($reasons | Where-Object { $_ -like 'objeto *' }).Count -eq 0) { $issues.Add((New-MaIssue 'MA_COMPLETE_GOVERNED_DIVERGENT' -Role $Role -Path $file.Path -Detail ($Label + ': ' + ($reasons -join '; ')))) }
    }
    $unexpected = @($tree.Keys | Where-Object { $governed -cnotcontains $_ -and $relevant.IsMatch($_) } | Sort-Object)
    foreach ($path in $unexpected) {
        $entry = $tree[$path]
        $entries.Add([pscustomobject]@{
            Source = $Label; Commit = $Commit; Path = $path; Result = 'Inesperado'; Reason = 'entrada fora do conjunto governado'
            Mode = $entry.Mode; Type = $entry.Type; ObjectId = $entry.ObjectId; Sha256 = $null; ExpectedMode = ''; ExpectedObjectId = ''; ExpectedSha256 = ''
        })
        $issues.Add((New-MaIssue 'MA_FILE_UNEXPECTED_ENTRY' -Role $Role -Path $path -Detail $Label))
    }
    return (& $done)
}

# Origem do valor no arquivo de configuracao do repositorio comum (camada local).
function Test-MaLocalConfigOrigin {
    param($Environment, [string]$Origin)
    if ([string]::IsNullOrEmpty($Origin) -or -not $Origin.StartsWith('file:') -or -not $Environment.CommonDir) { return $false }
    $path = ConvertTo-MaWindowsPath $Origin.Substring(5)
    try {
        if (-not [IO.Path]::IsPathRooted($path)) { $path = [IO.Path]::Combine($Environment.Path, $path) }
        $path = [IO.Path]::GetFullPath($path)
    } catch { return $false }
    return $path.Equals([IO.Path]::Combine($Environment.CommonDir, 'config'), [StringComparison]::OrdinalIgnoreCase)
}

# Cadeia de core.hooksPath compativel com a ativacao: uma unica ocorrencia, na
# camada local, no arquivo de configuracao do repositorio comum, com o valor
# relativo .githooks (resolvido pelo Git na raiz de cada worktree).
function Test-MaHooksChainCompatible {
    param($Environment)
    $chain = @($Environment.HooksPath)
    if ($chain.Count -ne 1) { return $false }
    if ($chain[0].Scope -cne 'local' -or $chain[0].Value -cne $script:MaHooksPathValue) { return $false }
    return (Test-MaLocalConfigOrigin $Environment $chain[0].Origin)
}

# Hooks que worktree add (reference-transaction) e o checkout por read-tree
# (post-index-change) executariam no contexto do ambiente. Sem core.hooksPath,
# valem os hooks ativos do diretorio padrao (Get-MaWorktreeHookIssues). Com a
# cadeia compativel, o diretorio efetivo e a .githooks governada da raiz, conferida
# para conter somente pre-commit e pre-push, que essas operacoes nao executam.
# Qualquer outra configuracao recusa a operacao, sem altera-la.
function Get-MaCompleteHookIssues {
    param([Parameter(Mandatory = $true)]$Environment, [string]$Role)
    $issues = New-Object System.Collections.Generic.List[object]
    if (@($Environment.HooksPath).Count -gt 0 -and (Test-MaHooksChainCompatible $Environment)) {
        $other = @($Environment.EffectiveHooks | Where-Object { @('pre-commit', 'pre-push') -notcontains $_ })
        if ($other.Count -gt 0) { $issues.Add((New-MaIssue 'MA_PREPARE_HOOKS_WOULD_RUN' -Role $Role -Path ([string]$Environment.HooksDirectory) -Detail ($other -join ', '))) }
    } else { foreach ($issue in (Get-MaWorktreeHookIssues $Environment $Role)) { $issues.Add($issue) } }
    return , $issues.ToArray()
}

# Politica de ativacao compartilhada (especificacao 7) sobre uma inspecao dos
# quatro ambientes, cada um consultado no proprio worktree, com includes e todas as
# camadas (sistema, global, local, worktree, includes condicionais e processo):
#   1-2. registros de worktree: exatamente os quatro previstos, disponiveis;
#   3-6. cadeia de core.hooksPath com valor, origem e escopo, por worktree;
#   7.   diretorio efetivo resolvido pelo Git e hooks ativos no diretorio padrao;
#   8.   .githooks governada de cada raiz (bytes e modos ja classificados).
# Decision: 'Compativel' (configuracao persistente ja compativel nos quatro),
# 'Inserir' (entrada ausente nos quatro, sem conflitos: uma insercao local
# permitida) ou 'Bloqueado'. Fingerprint resume o estado para a revalidacao.
function Get-MaHooksActivationState {
    param([Parameter(Mandatory = $true)]$Inspection)
    $issues = New-Object System.Collections.Generic.List[object]
    $report = New-Object System.Collections.Generic.List[object]
    $configuration = $Inspection.Configuration
    $map = @{}; foreach ($environment in @($Inspection.Environments)) { $map[$environment.Role] = $environment }
    $coordination = $map['coordination']
    $records = @(); if ($null -ne $coordination -and $coordination.Inspected) { $records = @($coordination.Worktrees) }
    $expected = @{}; foreach ($role in $script:MaRoles) { $expected[$configuration.Worktrees[$role].ToUpperInvariant()] = $role }
    $registered = @{}
    foreach ($record in $records) {
        $key = $record.Path.ToUpperInvariant()
        if ($record.Prunable -or $record.Bare -or -not $expected.ContainsKey($key) -or $registered.ContainsKey($key)) { $issues.Add((New-MaIssue 'MA_HOOKS_SCOPE_INCOMPLETE' -Path $record.Path -Detail 'registro extra, indisponivel ou duplicado')); continue }
        $registered[$key] = $record
    }
    foreach ($role in $script:MaRoles) {
        $environment = $map[$role]
        if (-not $registered.ContainsKey($configuration.Worktrees[$role].ToUpperInvariant()) -or $null -eq $environment -or -not $environment.Inspected) { $issues.Add((New-MaIssue 'MA_HOOKS_SCOPE_INCOMPLETE' -Role $role -Path $configuration.Worktrees[$role] -Detail 'ambiente ausente, nao registrado ou nao inspecionado')) }
    }
    $states = [ordered]@{}
    foreach ($role in $script:MaRoles) {
        $environment = $map[$role]
        if ($null -eq $environment -or -not $environment.Inspected) { continue }
        $chain = @($environment.HooksPath)
        $governedDirectory = [IO.Path]::Combine($environment.Path, '.githooks')
        $defaultDirectory = [IO.Path]::Combine([string]$environment.CommonDir, 'hooks')
        $effective = [string]$environment.HooksDirectory
        $state = 'Conflito'
        if (@($chain | Where-Object { $_.Scope -ceq 'command' }).Count -gt 0) { $issues.Add((New-MaIssue 'MA_HOOKS_PROCESS_OVERRIDE' -Role $role -Path $environment.Path)) }
        elseif ($chain.Count -eq 0) {
            if ($effective.Equals($defaultDirectory, [StringComparison]::OrdinalIgnoreCase)) { $state = 'Ausente' }
            else { $issues.Add((New-MaIssue 'MA_HOOKS_PRECEDENCE_INCONCLUSIVE' -Role $role -Path $environment.Path -Detail ('efetivo ' + $effective + '; esperado ' + $defaultDirectory))) }
        } elseif (Test-MaHooksChainCompatible $environment) {
            if ($effective.Equals($governedDirectory, [StringComparison]::OrdinalIgnoreCase)) { $state = 'Compativel' }
            else { $issues.Add((New-MaIssue 'MA_HOOKS_PRECEDENCE_INCONCLUSIVE' -Role $role -Path $environment.Path -Detail ('efetivo ' + $effective + '; esperado ' + $governedDirectory))) }
        } else {
            $reason = 'origem diferente do repositorio comum'
            if ($chain.Count -gt 1) { $reason = [string]$chain.Count + ' ocorrencias' }
            elseif ($chain[0].Value -ceq '') { $reason = 'valor vazio' }
            elseif ($chain[0].Scope -cne 'local') { $reason = 'escopo ' + $chain[0].Scope }
            elseif ($chain[0].Value -cne $script:MaHooksPathValue) { $reason = 'caminho distinto' }
            $issues.Add((New-MaIssue 'MA_HOOKS_CONFIG_CONFLICT' -Role $role -Path $environment.Path -Detail $reason))
        }
        # 8. .githooks governada: os dois hooks identicos e nenhuma entrada extra.
        $hookFiles = @($Inspection.Files | Where-Object { $_.Role -eq $role -and $script:MaHookPaths -ccontains $_.Path })
        $extra = @($Inspection.Issues | Where-Object { $_.Role -eq $role -and $_.Code -ceq 'MA_FILE_UNEXPECTED_ENTRY' -and ($_.Path -ieq '.githooks' -or $_.Path.StartsWith('.githooks/', [StringComparison]::OrdinalIgnoreCase)) } | ForEach-Object { $_.Path })
        $filesText = ((@($hookFiles | ForEach-Object { $_.Path + ' ' + $_.Classification }) + @($extra | ForEach-Object { $_ + ' inesperado' })) -join ', ')
        if ($hookFiles.Count -ne 2 -or @($hookFiles | Where-Object { $_.Classification -cne 'Identico' }).Count -gt 0 -or $extra.Count -gt 0) {
            $issues.Add((New-MaIssue 'MA_HOOKS_GOVERNED_INVALID' -Role $role -Path $governedDirectory -Detail $filesText))
        }
        $states[$role] = $state
        $values = '(nenhum)'
        if ($chain.Count -gt 0) { $values = ((@($chain | ForEach-Object { $_.Scope + ' ' + $_.Origin + ' = ' + $_.Value })) -join '; ') }
        $effectiveValue = '(ausente: diretorio padrao)'; if ($chain.Count -gt 0) { $effectiveValue = $chain[$chain.Count - 1].Value }
        $report.Add([pscustomobject]@{
            Role = $role; Root = $environment.Path; Branch = $environment.Branch; ExpectedBranch = $environment.ExpectedBranch; CommonDir = $environment.CommonDir
            Values = $values; EffectiveValue = $effectiveValue; Destination = $effective; ExpectedDestination = $governedDirectory; Files = $filesText; State = $state
        })
    }
    $commons = @(@($Inspection.Environments | Where-Object { $_.Inspected -and $_.CommonDir }) | ForEach-Object { $_.CommonDir.ToUpperInvariant() } | Sort-Object -Unique)
    if ($commons.Count -gt 1) { $issues.Add((New-MaIssue 'MA_HOOKS_SCOPE_INCOMPLETE' -Detail 'repositorios comuns distintos')) }
    $decision = 'Bloqueado'
    $distinct = @($states.Values | Sort-Object -Unique)
    if ($issues.Count -eq 0 -and $states.Count -eq $script:MaRoles.Count) {
        if ($distinct.Count -eq 1 -and $distinct[0] -ceq 'Compativel') { $decision = 'Compativel' }
        elseif ($distinct.Count -eq 1 -and $distinct[0] -ceq 'Ausente') {
            # A ativacao ocultaria hooks ativos no diretorio padrao (comum aos quatro).
            $hidden = @($coordination.DefaultHooks)
            if ($hidden.Count -gt 0) { $issues.Add((New-MaIssue 'MA_HOOKS_DEFAULT_WOULD_BE_HIDDEN' -Path ([IO.Path]::Combine($coordination.CommonDir, 'hooks')) -Detail ($hidden -join ', '))) }
            else { $decision = 'Inserir' }
        } else { $issues.Add((New-MaIssue 'MA_HOOKS_CONFIG_CONFLICT' -Detail 'estado distinto entre os worktrees')) }
    }
    $fingerprint = ((@(@($registered.Keys | Sort-Object) + @($report | ForEach-Object { $_.Role + '|' + $_.Values + '|' + $_.Destination + '|' + $_.Files + '|' + $_.State }) + @(@($coordination.DefaultHooks) -join ','))) -join [string][char]0)
    return [pscustomobject]@{ Decision = $decision; Issues = $issues.ToArray(); Report = $report.ToArray(); Fingerprint = $fingerprint }
}

function Invoke-MaCompleteWorktrees {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$AuthorizationReference = '',
        [string]$BaseCommit = '',
        [string]$IntegratedCommit = '',
        [string]$IntegrationReference = '',
        [switch]$WhatIfRequested
    )
    $phaseIssues = New-Object System.Collections.Generic.List[object]
    $performed = New-Object System.Collections.Generic.List[object]
    $simulated = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[string]
    $comparison = New-Object System.Collections.Generic.List[object]
    $inspection = New-MaInspectionState
    $lock = $null
    $whatIf = [bool]$WhatIfRequested
    $incomplete = $false
    $authorizationHash = $null
    if (-not [string]::IsNullOrEmpty($AuthorizationReference)) { $authorizationHash = Get-MaSha256 ([Text.Encoding]::UTF8.GetBytes($AuthorizationReference)) }
    # Referencias e registro nao sao reproduzidos (podem conter dados pessoais); os
    # hashes permitem conferi-los com os registros humanos.
    $evidence = [ordered]@{
        AuthorizationReference = $(if ($authorizationHash) { 'fornecida (SHA-256 ' + $authorizationHash + '); registrada sem verificacao: o instalador nao infere aprovacao' } else { 'nao fornecida' })
        IntegrationReference   = $(if ($IntegrationReference) { 'fornecida; pendente de conferencia' } else { 'nao fornecida' })
        IntegratedCommit       = $(if ($IntegratedCommit) { 'fornecido; pendente de conferencia' } else { 'nao fornecido' })
        ReviewedHead           = 'nao determinado'
        CoordinationHead       = 'nao determinado'
        BaseCommit             = $(if ($BaseCommit) { 'fornecido; nao utilizado em CompleteWorktrees' } else { 'nao fornecido' })
    }
    $record = {
        param($List, [string]$Role, [string]$Operation, [string]$Target, [string]$Detail)
        $List.Add([pscustomobject]@{ Order = $List.Count + 1; Role = $Role; Operation = $Operation; Target = $Target; Detail = $Detail })
    }
    # Estado mais recente (inspecao, politica de hooks), conservado mesmo com excecao.
    $current = @{ Inspection = $inspection; Hooks = $null }
    $blocked = { @(@($current.Inspection.Issues.ToArray()) + @($phaseIssues.ToArray()) | Where-Object { $_.Severity -ne 'Aviso' }).Count -gt 0 }
    $inspect = {
        $current.Inspection = New-MaInspectionState
        Invoke-MaInspection -State $current.Inspection -ConfigPath $ConfigPath -PackageRoot $PackageRoot -BaseCommit $BaseCommit -IntegratedCommit $IntegratedCommit -FallbackCode 'MA_COMPLETE_UNEXPECTED_FAILURE'
    }
    $byRole = { param($State) $map = @{}; foreach ($environment in $State.Environments) { $map[$environment.Role] = $environment }; return $map }
    # Recursos fixados por handles durante a fase, como em PrepareMaintenance.
    $workspace = $null
    $targets = New-Object System.Collections.Generic.List[object]
    $chains = New-Object System.Collections.Generic.List[object]
    $lockedFingerprint = $null
    $configurationChanged = {
        if ((Get-MaConfigurationFingerprint $current.Inspection.Configuration) -ceq $lockedFingerprint) { return $false }
        $phaseIssues.Add((New-MaIssue 'MA_PREPARE_CONFIG_CHANGED' -Path $ConfigPath))
        return $true
    }
    $targetFor = { param([string]$Path) foreach ($target in $targets) { if ($target.Path -ceq $Path) { return $target } }; return $null }
    # Checkout de worktree criado sem checkout, depois da verificacao previa de
    # filtros, atributos e submodulos e dos hooks do proprio ambiente.
    $checkout = {
        param([string]$Role, [string]$Path, $Environment, [string]$Branch)
        [void](& $requireIntegration $Role $Path $Environment.Head $Branch)
        foreach ($issue in (Get-MaCompleteHookIssues $Environment $Role)) { $phaseIssues.Add($issue) }
        $safety = Get-MaCheckoutSafety -Root $Path -Commit $Environment.Head -Role $Role -Environment $null
        foreach ($issue in $safety.Issues) { $phaseIssues.Add($issue) }
        if (& $blocked) { return $false }
        $detail = 'read-tree de ' + $Environment.Head + '; sem filtro, hook, submodulo ou origem alternativa de atributos'
        if ($whatIf) { & $record $simulated $Role 'Checkout' $Path $detail; return $false }
        $target = & $targetFor $Path
        if ($null -eq $target) {
            try { $target = Open-MaOperationTarget $workspace $Path; $targets.Add($target) }
            catch { $phaseIssues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PATH_INSPECTION_FAILED') -Role $Role -Path $Path -Detail (Get-MaErrorDetail $_))); return $false }
        }
        $result = Invoke-MaCheckout -Root $Path -Commit $Environment.Head -Branch $Branch -Role $Role -Target $target -Paths $safety.Paths
        foreach ($issue in $result.Issues) { $phaseIssues.Add($issue) }
        if (& $blocked) {
            if ($result.Executed) { & $record $performed $Role 'Checkout (parcial)' $Path 'preservado sem remocao automatica' }
            return $false
        }
        & $record $performed $Role 'Checkout' $Path $detail
        return $true
    }
    $compare = {
        param([string]$Root, [string]$Commit, [string]$Label, [string]$Role, [string]$ObjectFormat)
        $result = Get-MaGovernedCommitComparison -Root $Root -Commit $Commit -Label $Label -RenderedFiles $current.Inspection.Rendered -ObjectFormat $ObjectFormat -Role $Role
        foreach ($entry in $result.Entries) { $comparison.Add($entry) }
        foreach ($issue in $result.Issues) { $phaseIssues.Add($issue) }
    }
    # merge-base --is-ancestor: $true, $false ou $null (leitura inconclusiva, relatada).
    $isAncestor = {
        param([string]$Root, [string]$Ancestor, [string]$Descendant, [string]$Role)
        $answer = Invoke-MaGit $Root @('merge-base', '--is-ancestor', $Ancestor, $Descendant)
        if ($answer.ExitCode -eq 0) { return $true }
        if ($answer.ExitCode -eq 1) { return $false }
        $phaseIssues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $Root -Detail 'merge-base'))
        return $null
    }
    # I ancestral do HEAD efetivo de uma branch de agente criada ou reutilizada
    # (especificacao 5): estar a frente de I e permitido; conteudo governado igual
    # nao substitui a ancestralidade. A branch nunca e reposicionada. $true somente
    # com a ancestralidade comprovada.
    $requireIntegration = {
        param([string]$Role, [string]$Root, [string]$Commit, [string]$Branch)
        if (-not $Commit) { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_PREREQUISITE_MISSING' -Role $Role -Path $configuration.Worktrees[$Role] -Detail 'HEAD indeterminado')); return $false }
        $contains = & $isAncestor $Root $integrated $Commit $Role
        if ($contains -eq $false) { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_BRANCH_NOT_FROM_INTEGRATION' -Role $Role -Path $configuration.Worktrees[$Role] -Detail ('branch ' + $Branch + '; HEAD ' + $Commit + '; I ' + $integrated + ' nao e ancestral'))) }
        return ($contains -eq $true)
    }
    $cleanupIssue = {
        param([string[]]$Failures)
        if (@($Failures).Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PATH_HANDLE_CLOSE_FAILED' -Severity 'Falha' -Detail (@($Failures) -join ', '))) }
    }
    $governedCount = @(Get-MaGovernedPaths).Count
    try {
        do {
            # 1. Evidencias exigidas antes de qualquer acesso ao repositorio.
            $authorizationCode = Get-MaAuthorizationReferenceIssue $AuthorizationReference
            if ($authorizationCode) { $phaseIssues.Add((New-MaIssue $authorizationCode)) }
            if (-not $IntegratedCommit) { $phaseIssues.Add((New-MaIssue 'MA_INTEGRATEDCOMMIT_REQUIRED')) }
            if (-not $IntegrationReference) { $phaseIssues.Add((New-MaIssue 'MA_INTEGRATION_REFERENCE_REQUIRED')) }

            # 2. Inspecao inicial, somente leitura.
            & $inspect; $inspection = $current.Inspection
            if ($null -ne $inspection.Configuration -and $null -eq $inspection.Rendered -and -not (& $blocked)) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_RENDER_UNAVAILABLE')) }
            if ((& $blocked) -or $null -eq $inspection.Configuration) { break }
            $configuration = $inspection.Configuration
            $lockedFingerprint = Get-MaConfigurationFingerprint $configuration

            # 3. Diretorio de trabalho fixado, mutex comum as fases mutaveis e
            # revalidacao sob ele.
            try {
                $workspace = Open-MaDirectoryChain $configuration.ParentDirectory
                $lockName = Get-MaRepositoryLockName (Get-MaWorkspaceLockIdentity $workspace $configuration.Worktrees.coordination)
            } catch { $phaseIssues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PATH_INSPECTION_FAILED') -Path $configuration.ParentDirectory -Detail (Get-MaErrorDetail $_))); break }
            try { $lock = Enter-MaRepositoryLock $lockName }
            catch { $phaseIssues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PREPARE_LOCK_UNAVAILABLE'))); break }
            if ($lock.Abandoned) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_LOCK_ABANDONED' -Severity 'Aviso')) }
            & $inspect; $inspection = $current.Inspection
            if (& $configurationChanged) { break }
            if ((& $blocked) -or $null -eq $inspection.Rendered) { break }

            # 4. Registro de integracao, lido uma unica vez sob a exclusao mutua.
            $integration = Read-MaIntegrationEvidence -LiteralPath $IntegrationReference -Configuration $configuration -AuthorizationReference $AuthorizationReference -IntegratedCommit $IntegratedCommit
            foreach ($issue in $integration.Issues) { $phaseIssues.Add($issue) }
            if ($integration.Sha256) {
                $evidence.IntegrationReference = 'registro SHA-256 ' + $integration.Sha256 + $(if ($integration.Valid) { '; campos completos e consistentes com a configuracao e os parametros' } else { '; invalido ou inconsistente' }) + '; fornecido pelo responsavel, sem verificacao no servidor'
            }
            if (& $blocked) { break }
            $reviewed = $integration.ReviewedHead
            $integrated = $integration.IntegratedCommit

            # 5. Pre-condicoes sobre M, I e C, somente leitura.
            $environments = & $byRole $inspection
            $coordination = $environments.coordination
            $maintenance = $environments.maintenance
            $coordinationPath = $configuration.Worktrees.coordination
            foreach ($environment in @($coordination, $maintenance)) {
                if (-not $environment.Inspected -or -not $environment.Head -or $environment.CheckoutPending) { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_PREREQUISITE_MISSING' -Role $environment.Role -Path $environment.Path -Detail $environment.State)) }
            }
            if (& $blocked) { break }
            $format = $coordination.ObjectFormat
            $expectedLength = 40; if ($format -ceq 'sha256') { $expectedLength = 64 }
            foreach ($pair in @(@('M', $reviewed), @('I', $integrated))) {
                if ($pair[1].Length -ne $expectedLength) { $phaseIssues.Add((New-MaIssue 'MA_INTEGRATION_EVIDENCE_MISMATCH' -Detail ($pair[0] + ': comprimento incompativel com o formato ' + $format))) }
            }
            if (& $blocked) { break }
            # Passo 1: M e I presentes localmente como commits, sem busca remota.
            foreach ($pair in @(@('M', $reviewed), @('I', $integrated))) {
                $object = Read-MaGitObject $coordinationPath $pair[1] $format 'commit'
                if ($object.Status -cne 'Ok') { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_COMMIT_UNAVAILABLE' -Role 'coordination' -Detail ($pair[0] + ' ' + $pair[1] + ': ' + $object.Status))) }
            }
            if (& $blocked) { break }
            # Vinculo de M com a fonte revisada: na conclusao inicial, HEAD da
            # manutencao igual a M. Depois dela (Codex e Claude existentes), a
            # manutencao conserva seu historico e pode ter avancado a partir de M.
            $agentsExist = @(@($environments.codex, $environments.claude) | Where-Object { $_.Exists -and $_.State -ne 'VazioSemRepositorio' }).Count -eq 2
            if ($maintenance.Head -cne $reviewed) {
                $advanced = $null
                if ($agentsExist) { $advanced = & $isAncestor $maintenance.Path $reviewed $maintenance.Head 'maintenance' }
                if ($advanced -eq $true) { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_MAINTENANCE_NOT_REVIEWED' -Severity 'Aviso' -Role 'maintenance' -Detail ('HEAD ' + $maintenance.Head + ' deriva de M apos a conclusao inicial'))) }
                elseif ($null -ne $advanced -or -not $agentsExist) { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_MAINTENANCE_NOT_REVIEWED' -Role 'maintenance' -Detail ('HEAD da manutencao ' + $maintenance.Head))) }
            }
            # Coordenacao ja sincronizada: C contem I.
            $synced = & $isAncestor $coordinationPath $integrated $coordination.Head 'coordination'
            if ($synced -eq $false) { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_COORDINATION_NOT_SYNCED' -Role 'coordination' -Detail ('HEAD da coordenacao ' + $coordination.Head))) }
            elseif ($synced -eq $true) { $evidence.CoordinationHead = $coordination.Head + ': contem o commit integrado' }
            # Referencia de acompanhamento remoto local (sem fetch): somente aviso.
            $tracking = Invoke-MaGit $coordinationPath @('rev-parse', '--verify', '--quiet', ('refs/remotes/origin/' + $configuration.Branches.coordination + '^{commit}'))
            $trackingCommit = $null; if ($tracking.ExitCode -eq 0) { $trackingCommit = (Split-MaLines $tracking.StdOut)[0] }
            $trackingContains = $false
            if ($trackingCommit) {
                $answer = Invoke-MaGit $coordinationPath @('merge-base', '--is-ancestor', $integrated, $trackingCommit)
                $trackingContains = ($answer.ExitCode -eq 0)
            }
            if (-not $trackingContains) { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_REMOTE_TRACKING_UNCONFIRMED' -Severity 'Aviso' -Role 'coordination' -Detail ('refs/remotes/origin/' + $configuration.Branches.coordination))) }
            # Passos 2 a 6 e 8: conteudo governado de M, I e C pelo banco de objetos.
            & $compare $coordinationPath $reviewed 'M' 'maintenance' $format
            & $compare $coordinationPath $integrated 'I' 'coordination' $format
            & $compare $coordinationPath $coordination.Head 'C' 'coordination' $format
            $evidence.ReviewedHead = $reviewed + ': commit local; vinculo com o PR registrado, sem verificacao no servidor'
            $evidence.IntegratedCommit = $integrated + ': commit local; metodo registrado ' + $integration.Method
            # Passos 7 e 8: indice e bytes do checkout da manutencao e da coordenacao.
            foreach ($role in @('coordination', 'maintenance')) {
                $identical = @($inspection.Files | Where-Object { $_.Role -eq $role -and $_.Classification -ceq 'Identico' }).Count
                if ($identical -ne $governedCount) { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_GOVERNED_DIVERGENT' -Role $role -Detail ('indice e checkout: ' + $identical + ' de ' + $governedCount + ' identicos'))) }
            }
            if (& $blocked) { break }

            # 6. Codex e Claude, em duas etapas: primeiro a verificacao previa dos dois
            # (autorizacao, branch, conteudo governado de partida, hooks e checkout),
            # sem nenhuma operacao; depois a criacao dos ausentes sem checkout na base
            # integrada (ou na branch existente, sem reposiciona-la), com destino e
            # repositorio comum fixados, e o checkout. Existentes sao conferidos pela
            # inspecao; um worktree sem checkout deixado por execucao anterior e retomado.
            $plans = New-Object System.Collections.Generic.List[object]
            $refs = Get-MaBranchRefs $coordinationPath
            foreach ($role in @('codex', 'claude')) {
                $environment = $environments[$role]
                $path = $configuration.Worktrees[$role]
                $branch = $configuration.Branches[$role]
                $missing = (-not $environment.Exists -or $environment.State -eq 'VazioSemRepositorio')
                # Worktree existente, concluido ou com checkout pendente: o HEAD da
                # branch precisa conter I, como uma branch criada ou reutilizada.
                if (-not $missing -and $environment.Head) { [void](& $requireIntegration $role $coordinationPath $environment.Head ([string]$environment.Branch)) }
                if (-not $missing -and -not $environment.CheckoutPending) { continue }
                if (-not ($integration.Operations -ccontains 'create-worktrees' -and $integration.Environments -ccontains [string]$configuration.Directories[$role])) {
                    $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_AUTHORIZATION_SCOPE' -Role $role -Detail ('create-worktrees ' + $configuration.Directories[$role])))
                    continue
                }
                if (-not $missing) {
                    & $compare $coordinationPath $environment.Head ($role + ' (HEAD)') $role $format
                    $plans.Add([pscustomobject]@{ Role = $role; Path = $path; Branch = $branch; Resume = $true; Environment = $environment })
                    continue
                }
                $branchState = Get-MaBranchCreationState $refs $branch $role
                foreach ($issue in $branchState.Issues) { $phaseIssues.Add($issue) }
                $branchExists = ($null -ne $branchState.Tip)
                $start = $integrated
                if ($branchExists) {
                    # Branch existente: nao reposicionada; precisa conter I e seu
                    # conteudo governado corresponder ao esperado antes de qualquer
                    # criacao. A revalidacao das branches antes do worktree add garante
                    # que o tip conferido e o usado.
                    $start = $branchState.Tip
                    & $compare $coordinationPath $start ($role + ' (branch existente)') $role $format
                    [void](& $requireIntegration $role $coordinationPath $start $branch)
                }
                foreach ($issue in (Get-MaCompleteHookIssues $coordination $role)) { $phaseIssues.Add($issue) }
                $preflight = Get-MaCheckoutSafety -Root $coordinationPath -Commit $start -Role $role -Environment $null
                foreach ($issue in $preflight.Issues) { $phaseIssues.Add($issue) }
                $worktreeDetail = $(if ($branchExists) { 'branch existente ' + $branch + ' em ' + $start + ', sem reposicionamento' } else { 'nova branch ' + $branch + ' no commit integrado ' + $integrated }) + '; sem checkout'
                $plans.Add([pscustomobject]@{ Role = $role; Path = $path; Branch = $branch; Resume = $false; BranchExists = $branchExists; Start = $start; Detail = $worktreeDetail })
            }
            if (& $blocked) { break }
            # Branches esperadas na revalidacao: as lidas agora e as criadas por esta fase.
            $expectedRefs = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
            foreach ($name in $refs.Keys) { $expectedRefs[$name] = $refs[$name] }
            $stop = $false
            foreach ($plan in $plans) {
                $role = $plan.Role; $path = $plan.Path; $branch = $plan.Branch
                if ($plan.Resume) {
                    if (-not (& $checkout $role $path $plan.Environment $branch)) { if (-not $whatIf) { $stop = $true; break }; continue }
                    & $inspect; $inspection = $current.Inspection
                    if (& $configurationChanged) { $stop = $true; break }
                    if ((& $blocked) -or $null -eq $inspection.Rendered) { $stop = $true; break }
                    $environments = & $byRole $inspection; $coordination = $environments.coordination
                    continue
                }
                $branchExists = $plan.BranchExists
                $worktreeDetail = $plan.Detail
                if ($whatIf) {
                    & $record $simulated $role 'Criar worktree' $path $worktreeDetail
                    & $record $simulated $role 'Checkout' $path ('read-tree de ' + $plan.Start + '; sem filtro, hook, submodulo ou origem alternativa de atributos')
                    continue
                }
                # Coordenacao, .git, .git\worktrees e destino fixados.
                $adminPinned = $false
                try {
                    $common = New-MaPinnedChain ([IO.Path]::Combine($coordinationPath, '.git')) $workspace.Leaf
                    $chains.Add($common)
                    [void](Add-MaPinnedComponent $common (Get-MaChildName $workspace $coordinationPath))
                    [void](Add-MaPinnedComponent $common '.git')
                    try { [void](Add-MaPinnedComponent $common 'worktrees'); $adminPinned = $true }
                    catch { if ((Get-MaErrorCode $_ '') -cne 'MA_PATH_NOT_FOUND') { throw } }
                    $target = Open-MaOperationTarget $workspace $path
                    $targets.Add($target)
                } catch {
                    $code = Get-MaErrorCode $_ 'MA_PATH_INSPECTION_FAILED'
                    if ($code -ceq 'MA_PREPARE_TARGET_CHANGED') { $code = 'MA_PREPARE_STATE_CHANGED' }
                    $phaseIssues.Add((New-MaIssue $code -Role $role -Path $path -Detail (Get-MaErrorDetail $_))); $stop = $true; break
                }
                [void](Test-MaNativeFault 'CompleteBeforeWorktree' ([pscustomobject]@{ Role = $role; Path = $path; Coordination = $coordinationPath }))
                # Revalidacao imediata: destino vazio lido agora pelo handle, HEAD da
                # coordenacao e branches.
                $entriesNow = Get-MaDirectoryEntries $target.Handle
                $now = Get-MaHeadState $coordinationPath
                $refsNow = Get-MaBranchRefs $coordinationPath
                $sameRefs = ($refsNow.Count -eq $expectedRefs.Count)
                foreach ($name in $expectedRefs.Keys) { if (-not $refsNow.ContainsKey($name) -or $refsNow[$name] -cne $expectedRefs[$name]) { $sameRefs = $false } }
                if (@($entriesNow).Count -gt 0 -or $now.Commit -cne $coordination.Head -or $now.Branch -cne $configuration.Branches.coordination -or -not $sameRefs) {
                    $phaseIssues.Add((New-MaIssue 'MA_PREPARE_STATE_CHANGED' -Role $role -Path $path))
                    $closed = Close-MaOperationTarget $workspace $target -RemoveIfCreatedEmpty
                    [void]$targets.Remove($target)
                    & $cleanupIssue $closed.Failures
                    $stop = $true; break
                }
                if ($branchExists) { $worktreeArguments = @('worktree', 'add', '--quiet', '--no-checkout', '--', $path, $branch) }
                else { $worktreeArguments = @('worktree', 'add', '--quiet', '--no-checkout', '-b', $branch, '--', $path, $integrated) }
                $worktree = Invoke-MaGit $coordinationPath $worktreeArguments
                $redirected = New-Object System.Collections.Generic.List[string]
                $redirected.AddRange((Get-MaReparseEntries $target.Handle))
                try {
                    if (-not $adminPinned) { [void](Add-MaPinnedComponent $common 'worktrees'); $adminPinned = $true }
                    foreach ($name in (Get-MaReparseEntries $common.Leaf)) { $redirected.Add('.git/worktrees/' + $name) }
                } catch {
                    $code = Get-MaErrorCode $_ ''
                    if ($code -ceq 'MA_PATH_REPARSE_POINT') { $redirected.Add('.git/worktrees') }
                    elseif ($code -cne 'MA_PATH_NOT_FOUND') { throw }
                }
                $redirected = $redirected.ToArray()
                if ($worktree.ExitCode -ne 0) {
                    $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_WORKTREE_FAILED' -Severity 'Falha' -Role $role -Path $path -Detail ('git worktree add ' + $worktree.ExitCode)))
                    $refsAfter = Get-MaBranchRefs $coordinationPath
                    if (-not $branchExists -and $refsAfter.ContainsKey($branch)) { & $record $performed $role 'Criar branch' $branch ('em ' + $refsAfter[$branch] + '; preservada') }
                    $remaining = Get-MaDirectoryEntries $target.Handle
                    if ($remaining.Count -gt 0) { & $record $performed $role 'Criar worktree (parcial)' $path 'preservado sem remocao automatica' }
                    else {
                        $closed = Close-MaOperationTarget $workspace $target -RemoveIfCreatedEmpty
                        [void]$targets.Remove($target)
                        & $cleanupIssue $closed.Failures
                    }
                    if ($redirected.Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_TARGET_REDIRECTED' -Role $role -Path $path -Detail (Format-MaPathList $redirected))) }
                    $stop = $true; break
                }
                & $record $performed $role 'Criar worktree' $path $worktreeDetail
                if (-not $branchExists) { $expectedRefs[$branch] = $integrated }
                if ($redirected.Count -gt 0) { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_TARGET_REDIRECTED' -Role $role -Path $path -Detail (Format-MaPathList $redirected))); $stop = $true; break }
                $created = Get-MaEnvironmentInspection -Role $role -Configuration $configuration -GitAvailable $true
                if (@($created.Issues | Where-Object { $_.Severity -ne 'Aviso' }).Count -eq 0 -and $created.CheckoutPending) {
                    [void](& $checkout $role $path $created $branch)
                }
                & $inspect; $inspection = $current.Inspection
                if (& $configurationChanged) { $stop = $true; break }
                if ((& $blocked) -or $null -eq $inspection.Rendered) { $stop = $true; break }
                $environments = & $byRole $inspection; $coordination = $environments.coordination
            }
            if ($stop) { break }
            if ($whatIf -and $simulated.Count -gt 0) {
                & $record $simulated '' 'Configurar hooks' 'core.hooksPath' ('.githooks na configuracao local, somente se a politica de hooks e a autorizacao permitirem apos a criacao dos ambientes')
                $pending.Add('Configuracao efetiva dos hooks avaliada somente depois da criacao ou do checkout dos ambientes ausentes.')
                break
            }

            # 7. Hooks: politica da especificacao 7 nos quatro contextos.
            $hooks = Get-MaHooksActivationState $inspection
            $current.Hooks = $hooks
            foreach ($issue in $hooks.Issues) { $phaseIssues.Add($issue) }
            if (& $blocked) { break }
            if ($hooks.Decision -ceq 'Inserir') {
                $directories = @(foreach ($role in $script:MaRoles) { [string]$configuration.Directories[$role] })
                $covered = ($integration.Operations -ccontains 'configure-hooks' -and @($directories | Where-Object { $integration.Environments -cnotcontains $_ }).Count -eq 0)
                if (-not $covered) {
                    $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_HOOKS_NOT_AUTHORIZED' -Severity 'Aviso'))
                    $pending.Add('Ativacao dos hooks pendente: exige autorizacao registrada com configure-hooks para os quatro ambientes.')
                    $incomplete = $true
                    break
                }
                $hooksDetail = '.githooks na configuracao local do repositorio comum (' + [IO.Path]::Combine($coordination.CommonDir, 'config') + '), sem --replace-all nem alteracao global'
                if ($whatIf) { & $record $simulated '' 'Configurar hooks' 'core.hooksPath' $hooksDetail; break }
                # 9. Revalidacao imediata do conjunto antes da escrita.
                [void](Test-MaNativeFault 'CompleteBeforeHooks' $configuration)
                & $inspect; $inspection = $current.Inspection
                if (& $configurationChanged) { break }
                if ((& $blocked) -or $null -eq $inspection.Rendered) { break }
                $again = Get-MaHooksActivationState $inspection
                $current.Hooks = $again
                if ($again.Decision -cne 'Inserir' -or $again.Fingerprint -cne $hooks.Fingerprint) {
                    foreach ($issue in $again.Issues) { $phaseIssues.Add($issue) }
                    $phaseIssues.Add((New-MaIssue 'MA_PREPARE_STATE_CHANGED' -Detail 'configuracao de hooks'))
                    break
                }
                # HEAD efetivo de Codex e Claude, relido agora, ainda contendo I.
                $environments = & $byRole $inspection
                foreach ($role in @('codex', 'claude')) { [void](& $requireIntegration $role $coordinationPath ([string]$environments[$role].Head) ([string]$environments[$role].Branch)) }
                if (& $blocked) { break }
                $write = Invoke-MaGit $coordinationPath @('config', '--local', '--add', 'core.hooksPath', $script:MaHooksPathValue)
                if ($write.ExitCode -ne 0) { $phaseIssues.Add((New-MaIssue 'MA_HOOKS_ACTIVATION_FAILED' -Severity 'Falha' -Role 'coordination' -Detail ('git config ' + $write.ExitCode))); break }
                & $record $performed '' 'Configurar hooks' 'core.hooksPath' $hooksDetail
                # 10. Consulta posterior dos quatro contextos.
                & $inspect; $inspection = $current.Inspection
                if (& $configurationChanged) { break }
                $after = $null
                if ($null -ne $inspection.Rendered) { $after = Get-MaHooksActivationState $inspection; $current.Hooks = $after }
                if ($null -eq $after -or $after.Decision -cne 'Compativel') {
                    if ($null -ne $after) { foreach ($issue in $after.Issues) { $phaseIssues.Add($issue) } }
                    $phaseIssues.Add((New-MaIssue 'MA_HOOKS_VERIFY_FAILED' -Severity 'Falha'))
                    break
                }
                if (& $blocked) { break }
            }

            # 8. Verificacao final: quatro ambientes com os onze destinos identicos.
            foreach ($role in $script:MaRoles) {
                $identical = @($inspection.Files | Where-Object { $_.Role -eq $role -and $_.Classification -ceq 'Identico' }).Count
                if ($identical -ne $governedCount) { $phaseIssues.Add((New-MaIssue 'MA_COMPLETE_VERIFY_FAILED' -Severity 'Falha' -Role $role -Detail ([string]$identical + ' de ' + $governedCount))) }
            }
        } while ($false)
    } catch {
        $phaseIssues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_COMPLETE_UNEXPECTED_FAILURE') -Severity 'Falha' -Detail (Get-MaErrorDetail $_)))
    } finally {
        $inspection = $current.Inspection
        # Handles fechados antes de liberar o mutex; nenhuma falha e descartada.
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($target in @($targets.ToArray())) { foreach ($failure in (Close-MaOperationTarget $workspace $target).Failures) { $failures.Add($failure) } }
        foreach ($chain in @($chains.ToArray())) { foreach ($failure in (Close-MaPinnedChain $chain)) { $failures.Add($failure) } }
        foreach ($failure in (Close-MaPinnedChain $workspace)) { $failures.Add($failure) }
        & $cleanupIssue $failures.ToArray()
        try { Exit-MaRepositoryLock $lock } catch { $phaseIssues.Add((New-MaIssue 'MA_PREPARE_LOCK_RELEASE_FAILED' -Severity 'Aviso')) }
    }
    foreach ($item in $inspection.Pending) { $pending.Add($item) }
    $pending.Add('PR, revisao independente, autorizacao humana e execucao humana do merge: registro fornecido conferido somente quanto a forma e a consistencia com o estado local; servidor nao consultado.')
    $pending.Add('Estado remoto, protecao de branches e PRs nao verificados; nenhum fetch realizado.')
    $pending.Add('Hooks locais bloqueiam commit na coordenacao e push para ela; nao validam identidade, revisao ou autorizacao e nao substituem a protecao do servidor.')
    $pending.Add('Preparacao do indice, commit, push, PR e merge ficam fora do instalador, sob autorizacao humana propria.')
    $pending.Add('Origem confiavel do pacote nao comprovada pelo manifesto.')
    $issueArray = @(@($inspection.Issues.ToArray()) + @($phaseIssues.ToArray()))
    $status = Get-MaPlanStatus $issueArray ($incomplete -or $simulated.Count -gt 0)
    $hooksResult = $null
    if ($null -ne $current.Hooks) { $hooksResult = [pscustomobject]@{ Decision = $current.Hooks.Decision; Worktrees = $current.Hooks.Report } }
    return [pscustomobject]@{
        Phase         = 'CompleteWorktrees'
        Status        = $status
        WhatIf        = $whatIf
        Modified      = ($performed.Count -gt 0)
        Partial       = ($performed.Count -gt 0 -and $status -cne 'Sucesso')
        Package       = $inspection.Package
        Configuration = (ConvertTo-MaConfigurationSummary $inspection.Configuration)
        Git           = $inspection.Git
        Environments  = @(ConvertTo-MaEnvironmentSummary $inspection.Environments)
        Files         = $inspection.Files.ToArray()
        Comparison    = $comparison.ToArray()
        Hooks         = $hooksResult
        Performed     = $performed.ToArray()
        Simulated     = $simulated.ToArray()
        Issues        = $issueArray
        Pending       = $pending.ToArray()
        Evidence      = [pscustomobject]$evidence
    }
}

function Format-MaCompleteReport {
    param([Parameter(Mandatory = $true)]$Result)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Fase: ' + $Result.Phase)
    $lines.Add('Resultado: ' + $Result.Status)
    if ($Result.Partial) { $lines.Add('Execucao parcial: operacoes realizadas foram preservadas, sem reversao automatica; a fase nao esta concluida.') }
    if ($Result.WhatIf) { $lines.Add('WhatIf: simulacao; nenhuma operacao mutavel foi executada.') }
    if ($null -ne $Result.Package) {
        $integrity = 'invalida'; if ($Result.Package.Valid) { $integrity = 'valida' }
        $lines.Add('Pacote: versao ' + [string]$Result.Package.DistributionVersion + '; integridade ' + $integrity + ' (nao comprova origem).')
    }
    if ($null -ne $Result.Configuration) {
        $lines.Add('Projeto: ' + $Result.Configuration.Slug + ' | repositorio: ' + $Result.Configuration.RepositoryUrl)
        $lines.Add('Diretorio pai: ' + $Result.Configuration.ParentDirectory)
    }
    if ($null -ne $Result.Git) { $lines.Add('Git: ' + [string]$Result.Git.Path + ' ' + [string]$Result.Git.Version) }
    if (@($Result.Environments).Count -gt 0) {
        $lines.Add(''); $lines.Add('Ambientes (apos a execucao):')
        foreach ($environment in $Result.Environments) { $lines.Add('  [' + $environment.Role + '] ' + $environment.Path + ' | branch ' + $environment.ExpectedBranch + ' | ' + $environment.State + $(if ($environment.Head) { ' | HEAD ' + $environment.Head } else { '' })) }
    }
    if (@($Result.Comparison).Count -gt 0) {
        $lines.Add(''); $lines.Add('Comparacao do conteudo governado pelo banco de objetos (M revisado, I integrado, C coordenacao):')
        foreach ($entry in $Result.Comparison) {
            $line = '  [' + $entry.Source + '] ' + $entry.Path + ' | ' + $entry.Result
            if ($entry.Mode) { $line += ' | ' + $entry.Mode + ' ' + $entry.Type + ' ' + $entry.ObjectId }
            if ($entry.Sha256) { $line += ' sha256 ' + $entry.Sha256 }
            if ($entry.ExpectedMode) { $line += ' | esperado ' + $entry.ExpectedMode + ' ' + $entry.ExpectedObjectId }
            if ($entry.Reason) { $line += ' | ' + $entry.Reason }
            $lines.Add($line)
        }
    }
    if (@($Result.Files).Count -gt 0) {
        $lines.Add(''); $lines.Add('Destinos governados (HEAD, indice e bytes do checkout):')
        foreach ($file in $Result.Files) {
            $line = '  [' + $file.Role + '] ' + $file.Path + ' | ' + $file.Classification + ' | ' + $file.ExpectedMode + ' ' + $file.ExpectedObjectId
            if ($file.Reason) { $line += ' | ' + $file.Reason }
            $lines.Add($line)
        }
    }
    if ($null -ne $Result.Hooks) {
        $lines.Add(''); $lines.Add('Hooks por worktree (decisao: ' + $Result.Hooks.Decision + '):')
        foreach ($row in $Result.Hooks.Worktrees) {
            $lines.Add('  [' + $row.Role + '] ' + $row.Root + ' | branch ' + [string]$row.Branch + ' (configurada ' + $row.ExpectedBranch + ') | repositorio comum ' + [string]$row.CommonDir)
            $lines.Add('      core.hooksPath: ' + $row.Values + ' | efetivo: ' + $row.EffectiveValue + ' | destino: ' + $row.Destination + ' (previsto ' + $row.ExpectedDestination + ') | ' + $row.Files + ' | ' + $row.State)
        }
    }
    foreach ($group in @(@($Result.Performed, 'Acoes realizadas:'), @($Result.Simulated, 'Acoes simuladas (WhatIf, nenhuma executada):'))) {
        if (@($group[0]).Count -eq 0) { continue }
        $lines.Add(''); $lines.Add($group[1])
        foreach ($action in $group[0]) {
            $line = '  ' + $action.Order + '.'
            if ($action.Role) { $line += ' [' + $action.Role + ']' }
            $line += ' ' + $action.Operation + ' ' + $action.Target
            if ($action.Detail) { $line += ' (' + $action.Detail + ')' }
            $lines.Add($line)
        }
    }
    foreach ($group in @(@('Falha', 'Falhas operacionais:'), @('Bloqueio', 'Impedimentos:'), @('Aviso', 'Avisos:'))) {
        $selected = @($Result.Issues | Where-Object { $_.Severity -eq $group[0] })
        if ($selected.Count -eq 0) { continue }
        $lines.Add(''); $lines.Add($group[1])
        foreach ($issue in $selected) {
            $line = '  - ' + $issue.Code + ': ' + $issue.Message
            $where = @(@($issue.Role, $issue.Path, $issue.Detail) | Where-Object { $_ })
            if ($where.Count -gt 0) { $line += ' (' + ($where -join ' | ') + ')' }
            $lines.Add($line)
        }
    }
    $lines.Add(''); $lines.Add('Evidencias:')
    foreach ($property in $Result.Evidence.PSObject.Properties) { $lines.Add('  ' + $property.Name + ': ' + $property.Value) }
    if (@($Result.Pending).Count -gt 0) {
        $lines.Add(''); $lines.Add('Verificacoes pendentes:')
        foreach ($item in $Result.Pending) { $lines.Add('  - ' + $item) }
    }
    $lines.Add('')
    if ($Result.Modified) { $lines.Add('Modificacoes realizadas: ' + @($Result.Performed).Count + ' operacao(oes); nenhum commit, indice, push, PR ou merge.') }
    else { $lines.Add('Nenhuma modificacao foi realizada.') }
    return , $lines.ToArray()
}

# --- Validate ----------------------------------------------------------------------
# Contrato (especificacao 4, 5 e 9): configuracao valida e leitura possivel.
# Reconstroi o estado por arquivos, objetos Git, indice e configuracao efetiva e
# relata conformidade, incompletude ou bloqueio, sem correcao, fetch, clone, troca
# de branch, execucao de hooks, gravacao, relatorio em disco ou temporario. As
# leituras Git passam por Invoke-MaGit (sem gravar o indice, sem lazy fetch, sem
# substituicao de objetos, com fsmonitor e rastreamento desligados). Nenhuma
# exclusao mutua e obtida: a existencia do mutex das fases mutaveis e so consultada.
#
# O relatorio separa (especificacao 5):
#   - conformidade local: quatro ambientes no lugar e na branch previstos, mesmo
#     repositorio comum, exatamente quatro registros de worktree, origin, onze
#     destinos governados por ambiente (HEAD, indice e bytes do checkout com nomes
#     exatos, tipos, modos e objetos lidos), diretorios exclusivos sem entradas
#     extras, branches sem colisao por caixa e configuracao efetiva dos hooks nos
#     quatro contextos (politica da especificacao 7);
#   - alteracoes de trabalho fora do conjunto governado: na coordenacao impedem a
#     conformidade (a coordenacao nao recebe edicoes); nos demais, informativas;
#   - evidencia fornecida (opcional): IntegratedCommit (I) e o registro
#     IntegrationReference (com M), conferidos contra os objetos locais. Nunca
#     equivalem a prova de revisao, aprovacao ou integracao humana; sem eles, a
#     relacao dos ambientes com a base integrada fica pendente;
#   - protecao remota: nunca verificada.
# Conformity: Conforme; Incompleta (instalacao em andamento, com o proximo passo);
# Divergente (divergencia demonstrada); Inconclusiva (pre-condicao ou leitura sem
# conclusao confiavel). Status usa os codigos comuns; Sucesso exige conformidade
# local confirmada e nenhuma evidencia fornecida inconsistente.

# Ocorrencias que indicam leitura ou pre-condicao sem conclusao confiavel (as
# demais ocorrencias bloqueantes sao divergencias demonstradas).
$script:MaInconclusiveCodes = @(
    'MA_ENV_GIT_UNREADABLE', 'MA_ENV_SHALLOW', 'MA_ENV_PARTIAL_CLONE', 'MA_PATH_INSPECTION_FAILED', 'MA_GIT_ENV_OVERRIDE',
    'MA_GIT_NOT_FOUND', 'MA_GIT_VERSION_UNSUPPORTED', 'MA_GIT_EXECUTION_FAILED', 'MA_GIT_EXEC_PATH_UNTRUSTED', 'MA_GIT_TRANSPORT_UNTRUSTED',
    'MA_GIT_OBJECT_MISSING', 'MA_GIT_OBJECT_UNREADABLE', 'MA_GIT_OBJECT_CORRUPT', 'MA_GIT_OBJECT_TYPE_MISMATCH', 'MA_GIT_OBJECT_UNVERIFIED',
    'MA_BRANCH_GIT_REJECTED', 'MA_HOOKS_PRECEDENCE_INCONCLUSIVE', 'MA_HOOKS_PROCESS_OVERRIDE', 'MA_COMPLETE_COMMIT_UNAVAILABLE',
    'MA_VALIDATE_CHANGES_UNVERIFIED', 'MA_VALIDATE_CONCURRENT_PHASE', 'MA_VALIDATE_STATE_CHANGED', 'MA_VALIDATE_NOT_CONFIRMED', 'MA_VALIDATE_UNEXPECTED_FAILURE'
)

# Categoria de uma ocorrencia para o relatorio: aviso, pre-condicao (configuracao
# nao carregada), leitura inconclusiva ou divergencia.
function Get-MaValidateCategory {
    param([Parameter(Mandatory = $true)]$Issue, [bool]$Precondition = $false)
    if ($Issue.Severity -eq 'Aviso') { return 'aviso' }
    if ($Precondition) { return 'pre-condicao' }
    if ($Issue.Severity -eq 'Falha' -or $script:MaInconclusiveCodes -ccontains $Issue.Code -or $Issue.Code -cmatch '\AMA_(?:PACKAGE|JSON|SCHEMA|CONFIG|UTF8|TEMPLATE|RENDER|NATIVE|PATH_HANDLE)_') { return 'leitura inconclusiva' }
    return 'divergencia'
}

# Conformidade local: divergencia demonstrada prevalece sobre leitura
# inconclusiva, que prevalece sobre incompletude.
function Get-MaValidateConformity {
    param([object[]]$Issues, [int]$IncompleteCount, [bool]$ConfigurationLoaded)
    if (-not $ConfigurationLoaded) { return 'Inconclusiva' }
    $blocking = @($Issues | Where-Object { $null -ne $_ -and $_.Severity -ne 'Aviso' })
    if (@($blocking | Where-Object { (Get-MaValidateCategory $_) -ceq 'divergencia' }).Count -gt 0) { return 'Divergente' }
    if ($blocking.Count -gt 0) { return 'Inconclusiva' }
    if ($IncompleteCount -gt 0) { return 'Incompleta' }
    return 'Conforme'
}

# Alteracoes de trabalho de um ambiente fora do conjunto governado e dos
# diretorios exclusivos (esses sao conferidos byte a byte pela classificacao).
# status com GIT_OPTIONAL_LOCKS=0 nao grava o indice; um caminho rastreado com
# atributo filter levaria o status a executar um driver externo, entao a leitura e
# declarada nao verificada sem executar o status. State: Limpo, Alterado ou
# NaoVerificado; Paths: alterados, preparados no indice ou nao rastreados (sem os
# ignorados). Na coordenacao, alteracao ou leitura nao verificada bloqueia; nos
# demais ambientes as ocorrencias sao avisos.
function Get-MaWorkingChanges {
    param([Parameter(Mandatory = $true)]$Environment)
    $role = $Environment.Role
    $root = $Environment.Path
    $issues = New-Object System.Collections.Generic.List[object]
    $severity = 'Aviso'; if ($role -eq 'coordination') { $severity = 'Bloqueio' }
    $done = { param([string]$State, [string[]]$Paths) [pscustomobject]@{ Role = $role; Path = $root; State = $State; Paths = @($Paths); Issues = $issues.ToArray() } }
    $tracked = Invoke-MaGit $root @('ls-files', '-z')
    if ($tracked.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $role -Path $root -Detail 'ls-files')); return (& $done 'NaoVerificado' @()) }
    $filtered = Get-MaFilteredPaths $root (Split-MaNullFields $tracked.StdOut)
    if ($null -eq $filtered) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $role -Path $root -Detail 'check-attr')); return (& $done 'NaoVerificado' @()) }
    if ($filtered.Count -gt 0) {
        $paths = @(foreach ($driver in $filtered.Keys) { $filtered[$driver].ToArray() })
        $issues.Add((New-MaIssue 'MA_VALIDATE_CHANGES_UNVERIFIED' -Severity $severity -Role $role -Path $root -Detail (Format-MaPathList $paths)))
        return (& $done 'NaoVerificado' @())
    }
    $status = Invoke-MaGit $root @('status', '--porcelain=v1', '-z', '--untracked-files=all', '--no-renames', '--ignore-submodules=all')
    if ($status.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $role -Path $root -Detail 'status')); return (& $done 'NaoVerificado' @()) }
    $governed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in (Get-MaGovernedPaths)) { [void]$governed.Add($path) }
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($record in (Split-MaNullFields $status.StdOut)) {
        if ($record.Length -lt 4 -or $record[2] -ne ' ') { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $role -Path $root -Detail 'status')); return (& $done 'NaoVerificado' @()) }
        $path = $record.Substring(3)
        if ($governed.Contains($path)) { continue }
        $exclusive = $false
        foreach ($directory in $script:MaExclusiveDirectories) { if ($path.StartsWith($directory + '/', [StringComparison]::OrdinalIgnoreCase)) { $exclusive = $true } }
        if (-not $exclusive) { $changed.Add($path) }
    }
    if ($changed.Count -eq 0) { return (& $done 'Limpo' @()) }
    $code = 'MA_VALIDATE_WORKING_CHANGES'; if ($role -eq 'coordination') { $code = 'MA_VALIDATE_COORDINATION_CHANGED' }
    $issues.Add((New-MaIssue $code -Severity $severity -Role $role -Path $root -Detail ([string]$changed.Count + ' caminho(s): ' + (Format-MaPathList $changed.ToArray()))))
    return (& $done 'Alterado' $changed.ToArray())
}

# Cadeia de core.hooksPath de um worktree (escopo, origem e valor), lida como na
# inspecao; vazia se ausente ou ilegivel (a inspecao ja relata a leitura).
function Get-MaHooksPathChain {
    param([Parameter(Mandatory = $true)][string]$Root)
    $hooks = Invoke-MaGit $Root @('config', '-z', '--show-scope', '--show-origin', '--get-all', 'core.hooksPath')
    $fields = @(); if ($hooks.ExitCode -eq 0) { $fields = Split-MaNullFields $hooks.StdOut }
    return , @(for ($index = 0; $index + 2 -lt $fields.Count; $index += 3) { [pscustomobject]@{ Scope = $fields[$index]; Origin = $fields[$index + 1]; Value = $fields[$index + 2] } })
}

# Resumo do estado conferido: HEAD, branch e cadeia de core.hooksPath de cada
# ambiente (Role, Head, Branch, HooksPath), registros de worktree e branches
# locais ($null: ilegiveis). Comparado no fim da fase com Read-MaValidateDigest.
function Get-MaValidateDigest {
    param([object[]]$States, [object[]]$Worktrees, $Refs)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($state in $States) { $parts.Add($state.Role + '|' + [string]$state.Head + '|' + [string]$state.Branch + '|' + ((@($state.HooksPath | ForEach-Object { $_.Scope + '=' + $_.Origin + '=' + $_.Value })) -join ';')) }
    foreach ($record in $Worktrees) { $parts.Add('worktree|' + $record.Path + '|' + [string]$record.Branch + '|' + $record.Detached + '|' + $record.Bare + '|' + $record.Prunable + '|' + $record.Locked) }
    if ($null -eq $Refs) { $parts.Add('refs|?') }
    else { foreach ($name in @($Refs.Keys | Sort-Object -CaseSensitive)) { $parts.Add('ref|' + $name + '|' + $Refs[$name]) } }
    return ($parts -join [string][char]0)
}

# Releitura, no fim da fase, do mesmo resumo para os ambientes inspecionados.
function Read-MaValidateDigest {
    param([object[]]$Environments, [Parameter(Mandatory = $true)][string]$CoordinationPath)
    $states = @(foreach ($environment in $Environments) {
        $now = Get-MaHeadState $environment.Path
        [pscustomobject]@{ Role = $environment.Role; Head = $now.Commit; Branch = $now.Branch; HooksPath = (Get-MaHooksPathChain $environment.Path) }
    })
    $list = Invoke-MaGit $CoordinationPath @('worktree', 'list', '--porcelain', '-z')
    $records = @(); if ($list.ExitCode -eq 0) { $records = Get-MaWorktreeRecords $list.StdOut }
    $refs = $null
    try { $refs = Get-MaBranchRefs $CoordinationPath } catch { $refs = $null }
    return (Get-MaValidateDigest $states $records $refs)
}

# Fase mutavel em execucao para o mesmo repositorio: consulta, sem obter, o mutex
# nomeado de Enter-MaRepositoryLock, derivado da mesma identidade do diretorio de
# trabalho; a cadeia de diretorios e aberta somente para ler essa identidade e
# fechada em seguida. $true se o mutex existe (inclusive sem permissao de
# acesso), $false se nao existe e $null se a consulta nao foi possivel.
function Test-MaMutablePhaseActive {
    param([Parameter(Mandatory = $true)]$Configuration)
    $chain = $null
    $name = $null
    try {
        $chain = Open-MaDirectoryChain $Configuration.ParentDirectory
        $name = Get-MaRepositoryLockName (Get-MaWorkspaceLockIdentity $chain $Configuration.Worktrees.coordination)
    } catch { $name = $null }
    $failures = Close-MaPinnedChain $chain
    if (@($failures).Count -gt 0) { $name = $null }
    if ($null -eq $name) { return $null }
    $mutex = $null
    try { return [bool][System.Threading.Mutex]::TryOpenExisting($name, [ref]$mutex) }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception -and $exception -isnot [System.UnauthorizedAccessException]) { $exception = $exception.InnerException }
        if ($null -ne $exception) { return $true }
        return $null
    } finally { if ($null -ne $mutex) { $mutex.Dispose() } }
}

# Relacao dos ambientes com a base integrada fornecida (I e, com o registro, M),
# somente leitura e sem busca remota (especificacao 7): I e M presentes localmente
# como commits; a coordenacao e as branches de agente inspecionadas contem I; a
# manutencao esta em M ou, depois da conclusao inicial (agentes existentes),
# deriva de M; o conteudo governado de M e I corresponde ao esperado, pelo banco
# de objetos. A referencia local de acompanhamento remoto sem I e somente aviso.
# Devolve Issues, Comparison e CoordinationContains ($true, $false ou $null).
function Get-MaIntegrationRelation {
    param([Parameter(Mandatory = $true)]$Environments, [Parameter(Mandatory = $true)]$Configuration, [Parameter(Mandatory = $true)][object[]]$RenderedFiles, [Parameter(Mandatory = $true)][string]$Integrated, [string]$Reviewed = '')
    $issues = New-Object System.Collections.Generic.List[object]
    $entries = New-Object System.Collections.Generic.List[object]
    $contains = $null
    $done = { [pscustomobject]@{ Issues = $issues.ToArray(); Comparison = $entries.ToArray(); CoordinationContains = $contains } }
    $coordination = $Environments['coordination']
    $root = $coordination.Path
    $format = $coordination.ObjectFormat
    $expectedLength = 40; if ($format -ceq 'sha256') { $expectedLength = 64 }
    $commits = @(, @('I', $Integrated))
    if ($Reviewed) { $commits += , @('M', $Reviewed) }
    foreach ($pair in $commits) {
        if ($pair[1].Length -ne $expectedLength) { $issues.Add((New-MaIssue 'MA_INTEGRATION_EVIDENCE_MISMATCH' -Detail ($pair[0] + ': comprimento incompativel com o formato ' + $format))); continue }
        $object = Read-MaGitObject $root $pair[1] $format 'commit'
        if ($object.Status -cne 'Ok') { $issues.Add((New-MaIssue 'MA_COMPLETE_COMMIT_UNAVAILABLE' -Role 'coordination' -Detail ($pair[0] + ' ' + $pair[1] + ': ' + $object.Status))) }
    }
    if ($issues.Count -gt 0) { return (& $done) }
    $isAncestor = {
        param([string]$Ancestor, [string]$Descendant, [string]$Role)
        $answer = Invoke-MaGit $root @('merge-base', '--is-ancestor', $Ancestor, $Descendant)
        if ($answer.ExitCode -eq 0) { return $true }
        if ($answer.ExitCode -eq 1) { return $false }
        $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'merge-base'))
        return $null
    }
    $contains = & $isAncestor $Integrated $coordination.Head 'coordination'
    if ($contains -eq $false) { $issues.Add((New-MaIssue 'MA_COMPLETE_COORDINATION_NOT_SYNCED' -Role 'coordination' -Detail ('HEAD da coordenacao ' + $coordination.Head))) }
    foreach ($role in @('codex', 'claude')) {
        $environment = $Environments[$role]
        if (-not $environment.Inspected -or -not $environment.Head) { continue }
        if ((& $isAncestor $Integrated $environment.Head $role) -eq $false) {
            $issues.Add((New-MaIssue 'MA_COMPLETE_BRANCH_NOT_FROM_INTEGRATION' -Role $role -Path $environment.Path -Detail ('branch ' + [string]$environment.Branch + '; HEAD ' + $environment.Head + '; I ' + $Integrated + ' nao e ancestral')))
        }
    }
    $maintenance = $Environments['maintenance']
    if ($Reviewed -and $maintenance.Inspected -and $maintenance.Head -and $maintenance.Head -cne $Reviewed) {
        $agentsExist = @(@($Environments['codex'], $Environments['claude']) | Where-Object { $_.Exists -and $_.State -ne 'VazioSemRepositorio' }).Count -eq 2
        $advanced = $null
        if ($agentsExist) { $advanced = & $isAncestor $Reviewed $maintenance.Head 'maintenance' }
        if ($advanced -eq $true) { $issues.Add((New-MaIssue 'MA_COMPLETE_MAINTENANCE_NOT_REVIEWED' -Severity 'Aviso' -Role 'maintenance' -Detail ('HEAD ' + $maintenance.Head + ' deriva de M apos a conclusao inicial'))) }
        elseif ($null -ne $advanced -or -not $agentsExist) { $issues.Add((New-MaIssue 'MA_COMPLETE_MAINTENANCE_NOT_REVIEWED' -Role 'maintenance' -Detail ('HEAD da manutencao ' + $maintenance.Head))) }
    }
    $tracking = Invoke-MaGit $root @('rev-parse', '--verify', '--quiet', ('refs/remotes/origin/' + $Configuration.Branches.coordination + '^{commit}'))
    $trackingContains = $false
    if ($tracking.ExitCode -eq 0) {
        $answer = Invoke-MaGit $root @('merge-base', '--is-ancestor', $Integrated, (Split-MaLines $tracking.StdOut)[0])
        $trackingContains = ($answer.ExitCode -eq 0)
    }
    if (-not $trackingContains) { $issues.Add((New-MaIssue 'MA_COMPLETE_REMOTE_TRACKING_UNCONFIRMED' -Severity 'Aviso' -Role 'coordination' -Detail ('refs/remotes/origin/' + $Configuration.Branches.coordination))) }
    foreach ($pair in $commits) {
        $role = 'coordination'; if ($pair[0] -ceq 'M') { $role = 'maintenance' }
        $compared = Get-MaGovernedCommitComparison -Root $root -Commit $pair[1] -Label $pair[0] -RenderedFiles $RenderedFiles -ObjectFormat $format -Role $role
        foreach ($entry in $compared.Entries) { $entries.Add($entry) }
        foreach ($issue in $compared.Issues) { $issues.Add($issue) }
    }
    return (& $done)
}

function Invoke-MaValidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [string]$AuthorizationReference = '',
        [string]$BaseCommit = '',
        [string]$IntegratedCommit = '',
        [string]$IntegrationReference = '',
        [switch]$WhatIfRequested
    )
    $inspection = New-MaInspectionState
    $localIssues = New-Object System.Collections.Generic.List[object]
    $evidenceIssues = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[string]
    $incomplete = New-Object System.Collections.Generic.List[object]
    $comparison = New-Object System.Collections.Generic.List[object]
    $working = New-Object System.Collections.Generic.List[object]
    $hooks = $null
    $complete = $false
    $evidenceProvided = (-not [string]::IsNullOrEmpty($IntegratedCommit) -or -not [string]::IsNullOrEmpty($IntegrationReference))
    $relationChecked = $false
    $authorizationHash = $null
    if (-not [string]::IsNullOrEmpty($AuthorizationReference)) { $authorizationHash = Get-MaSha256 ([Text.Encoding]::UTF8.GetBytes($AuthorizationReference)) }
    # Referencias e registro nao sao reproduzidos; os hashes permitem conferi-los.
    $evidence = [ordered]@{
        IntegratedCommit       = $(if ($IntegratedCommit) { 'fornecido; pendente de conferencia' } else { 'nao fornecido' })
        IntegrationReference   = $(if ($IntegrationReference) { 'fornecida; pendente de conferencia' } else { 'nao fornecida' })
        AuthorizationReference = $(if ($authorizationHash) { 'fornecida (SHA-256 ' + $authorizationHash + '); usada somente na conferencia do registro, sem inferir aprovacao' } else { 'nao fornecida' })
        ReviewedHead           = 'nao determinado'
        CoordinationHead       = 'nao determinado'
        BaseCommit             = $(if ($BaseCommit) { 'fornecido; nao utilizado em Validate' } else { 'nao fornecido' })
    }
    $governedCount = @(Get-MaGovernedPaths).Count
    $addIncomplete = { param([string]$Role, [string]$Item, [string]$Next) $incomplete.Add([pscustomobject]@{ Role = $Role; Item = $Item; Next = $Next }) }
    # Proximo passo de cada pendencia de instalacao, conforme o fluxo aprovado.
    $nextMissing = @{
        coordination = 'PrepareMaintenance (clone da coordenacao)'; maintenance = 'PrepareMaintenance'
        codex = 'CompleteWorktrees'; claude = 'CompleteWorktrees'
    }
    $nextAbsent = @{
        coordination = 'Fora do instalador: integracao do PR de manutencao pelo humano e sincronizacao da coordenacao'
        maintenance  = 'PrepareMaintenance (geracao dos destinos ausentes)'
        codex        = 'Fora do instalador: a branch do agente nao contem a governanca; CompleteWorktrees exige o commit integrado na ancestralidade'
        claude       = 'Fora do instalador: a branch do agente nao contem a governanca; CompleteWorktrees exige o commit integrado na ancestralidade'
    }
    try {
        do {
            # 1. Pacote, configuracao, Git, renderizacao, ambientes, alcance e
            # destinos governados (inspecao comum, somente leitura).
            Invoke-MaInspection -State $inspection -ConfigPath $ConfigPath -PackageRoot $PackageRoot -FallbackCode 'MA_VALIDATE_UNEXPECTED_FAILURE'
            $configuration = $inspection.Configuration
            if ($null -eq $configuration) { break }
            $byRole = @{}; foreach ($environment in @($inspection.Environments)) { $byRole[$environment.Role] = $environment }
            $coordination = $byRole['coordination']

            # 2. Fase mutavel concorrente: consulta do mutex, sem obte-lo.
            $active = Test-MaMutablePhaseActive $configuration
            if ($active -eq $true) { $localIssues.Add((New-MaIssue 'MA_VALIDATE_CONCURRENT_PHASE')) }
            elseif ($null -eq $active) { $localIssues.Add((New-MaIssue 'MA_VALIDATE_CONCURRENCY_UNVERIFIED' -Severity 'Aviso')) }

            # 3. Presenca, inspecao e checkout dos quatro ambientes.
            $complete = $true
            foreach ($role in $script:MaRoles) {
                $environment = $byRole[$role]
                if (-not $environment.Exists -or $environment.State -eq 'VazioSemRepositorio') { & $addIncomplete $role ('ambiente ausente: ' + $environment.Path) $nextMissing[$role]; $complete = $false }
                elseif ($environment.CheckoutPending) { & $addIncomplete $role ('checkout pendente: ' + $environment.Path) ($nextMissing[$role] + ' (retomada do checkout)'); $complete = $false }
                elseif (-not $environment.Inspected) { $complete = $false }
            }

            # 4. Onze destinos governados identicos em cada ambiente inspecionado.
            $governedComplete = ($null -ne $inspection.Rendered)
            foreach ($role in $script:MaRoles) {
                $environment = $byRole[$role]
                if ($null -eq $inspection.Rendered -or -not $environment.Inspected -or $environment.CheckoutPending) { continue }
                $files = @($inspection.Files | Where-Object { $_.Role -eq $role })
                $absent = @($files | Where-Object { $_.Classification -ceq 'Ausente' } | ForEach-Object { $_.Path })
                $prepared = @($files | Where-Object { $_.Classification -ceq 'PreparadoNaoCommitado' } | ForEach-Object { $_.Path })
                if ($absent.Count -gt 0) { & $addIncomplete $role ([string]$absent.Count + ' de ' + $governedCount + ' destinos governados ausentes: ' + (Format-MaPathList $absent)) $nextAbsent[$role]; $governedComplete = $false }
                if ($prepared.Count -gt 0) { & $addIncomplete $role ([string]$prepared.Count + ' destinos governados preparados e nao commitados') 'Fora do instalador: preparacao do indice, commit, PR, revisao, merge humano e sincronizacao'; $governedComplete = $false }
            }

            # 5. Configuracao efetiva dos hooks nos quatro contextos (especificacao 7).
            if ($complete -and $governedComplete) {
                $hooks = Get-MaHooksActivationState $inspection
                foreach ($issue in $hooks.Issues) { $localIssues.Add($issue) }
                if ($hooks.Decision -ceq 'Inserir') { & $addIncomplete '' 'core.hooksPath ausente nos quatro ambientes: hooks governados nao ativados' 'CompleteWorktrees (ativacao dos hooks, com autorizacao para os quatro ambientes)' }
            } else { $pending.Add('Configuracao efetiva dos hooks avaliada somente com os quatro ambientes presentes e o conjunto governado completo em cada um.') }

            # 6. Branches configuradas sem colisao por caixa ou hierarquia.
            $refs = $null
            if ($coordination.Inspected) {
                try { $refs = Get-MaBranchRefs $coordination.Path } catch { $localIssues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role 'coordination' -Path $coordination.Path -Detail 'for-each-ref')) }
                if ($null -ne $refs) { foreach ($role in $script:MaRoles) { foreach ($issue in (Get-MaBranchCreationState $refs $configuration.Branches[$role] $role).Issues) { $localIssues.Add($issue) } } }
            }
            # Resumo do estado lido pela inspecao, para a releitura no fim da fase.
            $inspected = @($inspection.Environments | Where-Object { $_.Inspected })
            $digest = $null
            if ($coordination.Inspected) { $digest = Get-MaValidateDigest $inspected @($coordination.Worktrees) $refs }

            # 7. Alteracoes de trabalho fora do conjunto governado.
            foreach ($role in $script:MaRoles) {
                $environment = $byRole[$role]
                if (-not $environment.Inspected -or $environment.CheckoutPending) { $working.Add([pscustomobject]@{ Role = $role; Path = $environment.Path; State = 'NaoInspecionado'; Paths = @(); Issues = @() }); continue }
                $changes = Get-MaWorkingChanges $environment
                $working.Add($changes)
                foreach ($issue in $changes.Issues) { $localIssues.Add($issue) }
            }

            # 8. Evidencia fornecida (opcional), conferida contra os objetos locais.
            if ($evidenceProvided) {
                $integrated = $null
                $reviewed = ''
                if (-not $IntegratedCommit) { $evidenceIssues.Add((New-MaIssue 'MA_INTEGRATEDCOMMIT_REQUIRED' -Detail 'IntegrationReference exige IntegratedCommit')) }
                elseif (-not (Test-MaFullCommit $IntegratedCommit)) { $evidenceIssues.Add((New-MaIssue 'MA_COMMIT_FORMAT_INVALID' -Detail 'IntegratedCommit')) }
                else { $integrated = $IntegratedCommit }
                if ($IntegrationReference) {
                    $record = Read-MaIntegrationEvidence -LiteralPath $IntegrationReference -Configuration $configuration -AuthorizationReference $AuthorizationReference -IntegratedCommit $IntegratedCommit -AuthorizationOptional
                    foreach ($issue in $record.Issues) { $evidenceIssues.Add($issue) }
                    if ($record.Sha256) { $evidence.IntegrationReference = 'registro SHA-256 ' + $record.Sha256 + $(if ($record.Valid) { '; campos completos e consistentes com a configuracao e os parametros' } else { '; invalido ou inconsistente' }) + '; evidencia declarada, sem verificacao no servidor e sem valor de aprovacao' }
                    if ($record.Valid) { $reviewed = [string]$record.ReviewedHead }
                    if (-not $AuthorizationReference) { $pending.Add('Vinculo do registro com a autorizacao de conclusao nao conferido: AuthorizationReference nao fornecida.') }
                } else { $pending.Add('Registro de integracao nao fornecido: PR, revisao independente, autorizacao humana e execucao humana do merge sem registro conferido.') }
                # Relacao com a base integrada somente com I valido e registro, se
                # fornecido, consistente.
                $usable = ($null -ne $integrated -and @($evidenceIssues | Where-Object { $_.Severity -ne 'Aviso' }).Count -eq 0)
                if ($usable -and (-not $coordination.Inspected -or -not $coordination.Head -or $null -eq $inspection.Rendered)) { $pending.Add('Evidencia fornecida nao conferida: coordenacao ou pacote sem inspecao conclusiva.') }
                elseif ($usable) {
                    $relation = Get-MaIntegrationRelation $byRole $configuration $inspection.Rendered $integrated $reviewed
                    $relationChecked = $true
                    foreach ($issue in $relation.Issues) { $evidenceIssues.Add($issue) }
                    foreach ($entry in $relation.Comparison) { $comparison.Add($entry) }
                    if (@($relation.Issues | Where-Object { $_.Code -ceq 'MA_COMPLETE_COMMIT_UNAVAILABLE' }).Count -eq 0) {
                        $evidence.IntegratedCommit = $integrated + ': commit local; sem verificacao no servidor'
                        if ($reviewed) { $evidence.ReviewedHead = $reviewed + ': commit local; vinculo com o PR registrado, sem verificacao no servidor' }
                    }
                    if ($relation.CoordinationContains -eq $true) { $evidence.CoordinationHead = $coordination.Head + ': contem o commit integrado' }
                }
            } else { $pending.Add('Relacao dos ambientes com a base integrada (M e I) nao verificada: IntegratedCommit e IntegrationReference nao fornecidos.') }

            # 9. Estabilidade: mutex e estado relidos no fim da fase.
            [void](Test-MaNativeFault 'ValidateBeforeRecheck' $configuration)
            if ($active -ne $true -and (Test-MaMutablePhaseActive $configuration) -eq $true) { $localIssues.Add((New-MaIssue 'MA_VALIDATE_CONCURRENT_PHASE' -Detail 'iniciada durante a validacao')) }
            if ($null -ne $digest -and (Read-MaValidateDigest $inspected $coordination.Path) -cne $digest) { $localIssues.Add((New-MaIssue 'MA_VALIDATE_STATE_CHANGED')) }
        } while ($false)
    } catch {
        $localIssues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_VALIDATE_UNEXPECTED_FAILURE') -Severity 'Falha' -Detail (Get-MaErrorDetail $_)))
    }
    # O relatorio de hooks substitui o aviso de core.hooksPath presente da inspecao.
    $inspectionIssues = @($inspection.Issues.ToArray())
    if ($null -ne $hooks) { $inspectionIssues = @($inspectionIssues | Where-Object { $_.Code -cne 'MA_HOOKS_PATH_PRESENT' }) }
    $loaded = ($null -ne $inspection.Configuration)
    $conformity = Get-MaValidateConformity (@($inspectionIssues) + @($localIssues.ToArray())) $incomplete.Count $loaded
    # Salvaguarda: Conforme somente com tudo efetivamente conferido.
    if ($conformity -ceq 'Conforme') {
        $identical = @($inspection.Files | Where-Object { $_.Classification -ceq 'Identico' }).Count
        $expected = $governedCount * $script:MaRoles.Count
        $coordinationClean = (@($working | Where-Object { $_.Role -eq 'coordination' -and $_.State -ceq 'Limpo' }).Count -eq 1)
        if (-not $complete -or $identical -ne $expected -or $null -eq $hooks -or $hooks.Decision -cne 'Compativel' -or -not $coordinationClean) {
            $localIssues.Add((New-MaIssue 'MA_VALIDATE_NOT_CONFIRMED' -Detail ('ambientes completos ' + $complete + '; destinos identicos ' + $identical + ' de ' + $expected + '; hooks ' + $(if ($null -ne $hooks) { $hooks.Decision } else { 'nao avaliados' }) + '; coordenacao limpa ' + $coordinationClean)))
            $conformity = 'Inconclusiva'
        }
    }
    $local = @(@($inspectionIssues) + @($localIssues.ToArray()))
    foreach ($issue in $local) { Add-Member -InputObject $issue -NotePropertyName Category -NotePropertyValue (Get-MaValidateCategory $issue (-not $loaded)) -Force }
    foreach ($issue in $evidenceIssues) { Add-Member -InputObject $issue -NotePropertyName Category -NotePropertyValue 'evidencia' -Force }
    $evidenceResult = 'NaoFornecida'
    if ($evidenceProvided) {
        $blockingEvidence = @($evidenceIssues | Where-Object { $_.Severity -ne 'Aviso' })
        if (@($blockingEvidence | Where-Object { (Get-MaValidateCategory $_) -ceq 'divergencia' }).Count -gt 0) { $evidenceResult = 'Inconsistente' }
        elseif ($blockingEvidence.Count -gt 0) { $evidenceResult = 'Inconclusiva' }
        elseif ($relationChecked) { $evidenceResult = 'Consistente' }
        else { $evidenceResult = 'NaoVerificada' }
    }
    foreach ($item in $inspection.Pending) { $pending.Add($item) }
    $pending.Add('Protecao remota (branches protegidas, PRs, revisoes e regras do servidor) nao verificada: Validate nao acessa o servidor nem faz fetch.')
    $pending.Add('Conformidade local nao comprova revisao independente, aprovacao, autorizacao humana ou integracao remota; registro e SHAs fornecidos sao evidencia declarada, conferida somente contra o estado local.')
    $pending.Add('Hooks locais nao sao executados pela validacao; bloqueiam commit na coordenacao e push para ela, sem validar identidade, revisao ou autorizacao, e nao substituem a protecao do servidor.')
    $pending.Add('Estabilidade da leitura conferida por HEAD, branches, worktrees, core.hooksPath e exclusao mutua; mudanca concorrente somente nos bytes do checkout durante a leitura nao e detectada por essa releitura.')
    $pending.Add('Origem confiavel do pacote nao comprovada pelo manifesto.')
    $issueArray = @($local + @($evidenceIssues.ToArray()))
    $status = Get-MaPlanStatus $issueArray ($incomplete.Count -gt 0)
    $hooksResult = $null
    if ($null -ne $hooks) { $hooksResult = [pscustomobject]@{ Decision = $hooks.Decision; Worktrees = $hooks.Report } }
    return [pscustomobject]@{
        Phase            = 'Validate'
        Status           = $status
        Conformity       = $conformity
        EvidenceResult   = $evidenceResult
        RemoteProtection = 'NaoVerificada'
        WhatIf           = [bool]$WhatIfRequested
        Modified         = $false
        Package          = $inspection.Package
        Configuration    = (ConvertTo-MaConfigurationSummary $inspection.Configuration)
        Git              = $inspection.Git
        Environments     = @(ConvertTo-MaEnvironmentSummary $inspection.Environments)
        Files            = $inspection.Files.ToArray()
        Hooks            = $hooksResult
        Incomplete       = $incomplete.ToArray()
        WorkingChanges   = $working.ToArray()
        Comparison       = $comparison.ToArray()
        Issues           = $issueArray
        Pending          = $pending.ToArray()
        Evidence         = [pscustomobject]$evidence
    }
}

function Format-MaValidateReport {
    param([Parameter(Mandatory = $true)]$Result)
    $legend = @{
        Conforme     = 'quatro ambientes, registros, destinos governados, alteracoes da coordenacao e hooks efetivos conferidos'
        Incompleta   = 'instalacao nao concluida; ver pendencias de instalacao'
        Divergente   = 'divergencia demonstrada; ver impedimentos'
        Inconclusiva = 'pre-condicao ou leitura sem conclusao confiavel; conformidade nao declarada'
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Fase: ' + $Result.Phase)
    $lines.Add('Resultado: ' + $Result.Status)
    $lines.Add('Conformidade local: ' + $Result.Conformity + ' (' + $legend[[string]$Result.Conformity] + ')')
    if ($Result.WhatIf) { $lines.Add('WhatIf: sem efeito adicional; Validate nao executa operacoes mutaveis.') }
    if ($null -ne $Result.Package) {
        $integrity = 'invalida'; if ($Result.Package.Valid) { $integrity = 'valida' }
        $lines.Add('Pacote: versao ' + [string]$Result.Package.DistributionVersion + '; integridade ' + $integrity + ' (nao comprova origem).')
    }
    if ($null -ne $Result.Configuration) {
        $lines.Add('Projeto: ' + $Result.Configuration.Slug + ' | repositorio: ' + $Result.Configuration.RepositoryUrl)
        $lines.Add('Diretorio pai: ' + $Result.Configuration.ParentDirectory)
    }
    if ($null -ne $Result.Git) { $lines.Add('Git: ' + [string]$Result.Git.Path + ' ' + [string]$Result.Git.Version + ' | sh: ' + [string]$Result.Git.Shell) }
    if (@($Result.Environments).Count -gt 0) {
        $lines.Add(''); $lines.Add('Ambientes:')
        foreach ($environment in $Result.Environments) { $lines.Add('  [' + $environment.Role + '] ' + $environment.Path + ' | branch ' + $environment.ExpectedBranch + ' | ' + $environment.State + $(if ($environment.Head) { ' | HEAD ' + $environment.Head } else { '' })) }
    }
    if (@($Result.Files).Count -gt 0) {
        $lines.Add(''); $lines.Add('Destinos governados (HEAD, indice e bytes do checkout):')
        foreach ($file in $Result.Files) {
            $line = '  [' + $file.Role + '] ' + $file.Path + ' | ' + $file.Classification + ' | ' + $file.ExpectedMode + ' ' + $file.ExpectedObjectId
            if ($file.Reason) { $line += ' | ' + $file.Reason }
            $lines.Add($line)
        }
    }
    if ($null -ne $Result.Hooks) {
        $lines.Add(''); $lines.Add('Hooks por worktree (decisao: ' + $Result.Hooks.Decision + '):')
        foreach ($row in $Result.Hooks.Worktrees) {
            $lines.Add('  [' + $row.Role + '] ' + $row.Root + ' | branch ' + [string]$row.Branch + ' (configurada ' + $row.ExpectedBranch + ') | repositorio comum ' + [string]$row.CommonDir)
            $lines.Add('      core.hooksPath: ' + $row.Values + ' | efetivo: ' + $row.EffectiveValue + ' | destino: ' + $row.Destination + ' (previsto ' + $row.ExpectedDestination + ') | ' + $row.Files + ' | ' + $row.State)
        }
    }
    if (@($Result.Incomplete).Count -gt 0) {
        $lines.Add(''); $lines.Add('Instalacao incompleta:')
        foreach ($item in $Result.Incomplete) {
            $line = '  -'
            if ($item.Role) { $line += ' [' + $item.Role + ']' }
            $lines.Add($line + ' ' + $item.Item + ' -> proximo passo: ' + $item.Next)
        }
    }
    if (@($Result.WorkingChanges).Count -gt 0) {
        $lines.Add(''); $lines.Add('Alteracoes de trabalho (fora do conjunto governado):')
        foreach ($change in $Result.WorkingChanges) {
            $line = '  [' + $change.Role + '] ' + $change.State
            if (@($change.Paths).Count -gt 0) { $line += ': ' + @($change.Paths).Count + ' caminho(s): ' + (Format-MaPathList @($change.Paths)) }
            $lines.Add($line)
        }
    }
    $lines.Add(''); $lines.Add('Evidencia fornecida: ' + $Result.EvidenceResult + ' (declarada; conferida somente contra os objetos locais; nao comprova revisao, aprovacao ou integracao humana)')
    foreach ($property in $Result.Evidence.PSObject.Properties) { $lines.Add('  ' + $property.Name + ': ' + $property.Value) }
    foreach ($entry in $Result.Comparison) {
        $line = '  [' + $entry.Source + '] ' + $entry.Path + ' | ' + $entry.Result
        if ($entry.Mode) { $line += ' | ' + $entry.Mode + ' ' + $entry.Type + ' ' + $entry.ObjectId }
        if ($entry.Sha256) { $line += ' sha256 ' + $entry.Sha256 }
        if ($entry.ExpectedMode) { $line += ' | esperado ' + $entry.ExpectedMode + ' ' + $entry.ExpectedObjectId }
        if ($entry.Reason) { $line += ' | ' + $entry.Reason }
        $lines.Add($line)
    }
    $lines.Add(''); $lines.Add('Protecao remota: nao verificada (Validate nao acessa o servidor nem faz fetch).')
    foreach ($group in @(@('Falha', 'Falhas operacionais:'), @('Bloqueio', 'Impedimentos:'), @('Aviso', 'Avisos:'))) {
        $selected = @($Result.Issues | Where-Object { $_.Severity -eq $group[0] })
        if ($selected.Count -eq 0) { continue }
        $lines.Add(''); $lines.Add($group[1])
        foreach ($issue in $selected) {
            $line = '  - '
            if ($issue.PSObject.Properties['Category'] -and $issue.Category -cne 'aviso') { $line += '[' + $issue.Category + '] ' }
            $line += $issue.Code + ': ' + $issue.Message
            $where = @(@($issue.Role, $issue.Path, $issue.Detail) | Where-Object { $_ })
            if ($where.Count -gt 0) { $line += ' (' + ($where -join ' | ') + ')' }
            $lines.Add($line)
        }
    }
    if (@($Result.Pending).Count -gt 0) {
        $lines.Add(''); $lines.Add('Verificacoes pendentes:')
        foreach ($item in $Result.Pending) { $lines.Add('  - ' + $item) }
    }
    $lines.Add(''); $lines.Add('Nenhuma modificacao foi realizada.')
    return , $lines.ToArray()
}

Export-ModuleMember -Function Invoke-MaPlan, Format-MaPlanReport, Invoke-MaPrepareMaintenance, Format-MaPrepareReport, Invoke-MaCompleteWorktrees, Format-MaCompleteReport, Invoke-MaValidate, Format-MaValidateReport, Get-MaExitCode, Read-MaConfiguration, Test-MaPackageIntegrity, Get-MaRenderedFiles
