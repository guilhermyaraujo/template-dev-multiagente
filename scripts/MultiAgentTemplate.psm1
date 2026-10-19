#Requires -Version 5.1
# Modulo do instalador multiagente. Esta entrega implementa somente a fase Plan:
# leitura, validacao, renderizacao em memoria e inspecao, sem modificacoes.
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
    MA_NATIVE_TIMEOUT                    = 'Processo nativo excedeu o tempo limite.'
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
    MA_PHASE_NOT_IMPLEMENTED             = 'Fase nao implementada nesta entrega; somente Plan.'
    MA_PLAN_UNEXPECTED_FAILURE           = 'Falha operacional inesperada durante o planejamento.'
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
    $header = [Text.Encoding]::ASCII.GetBytes('blob ' + $Bytes.Length + [char]0)
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

function Read-MaConfiguration {
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [Parameter(Mandatory = $true)][string]$SchemaPath)
    $configurationPath = Assert-MaSafePath $LiteralPath 'File'
    $checkedSchemaPath = Assert-MaSafePath $SchemaPath 'File'
    $schema = Read-MaJsonStrict (Read-MaUtf8 $checkedSchemaPath)
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

function Get-MaRenderedFiles {
    param([Parameter(Mandatory = $true)][string]$PackageRoot, [Parameter(Mandatory = $true)]$Configuration, [Parameter(Mandatory = $true)][string]$DistributionVersion)
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($relative in (Get-MaTemplateMap)) {
        $source = Assert-MaSafePath ([IO.Path]::Combine($PackageRoot, 'templates', ($relative + '.tmpl').Replace('/', '\'))) 'File'
        $bytes = [IO.File]::ReadAllBytes($source)
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

function Invoke-MaNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$TimeoutMilliseconds = $script:MaGitTimeoutMilliseconds
    )
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-MaNativeArgument $_ }) -join ' ')
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    foreach ($name in $Environment.Keys) { $info.EnvironmentVariables[$name] = [string]$Environment[$name] }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $job = [IntPtr]::Zero
    try {
        try { [void]$process.Start() } catch { throw 'MA_GIT_EXECUTION_FAILED' }
        $job = New-MaProcessJob $process
        $process.StandardInput.Close()
        # Drenagem simultanea dos dois fluxos: pipe cheio nao bloqueia o filho.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            Stop-MaProcessTree $process $job
            throw 'MA_NATIVE_TIMEOUT'
        }
        # O fim dos fluxos tambem tem prazo: um descendente que herdou os pipes
        # pode mante-los abertos depois da saida do processo. Nao se usa
        # WaitForExit() sem argumento, que esperaria esse descendente sem limite.
        $remaining = [int][Math]::Max(0, $TimeoutMilliseconds - $clock.ElapsedMilliseconds)
        $drained = $false
        try { $drained = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdout, $stderr), $remaining) }
        catch { throw 'MA_GIT_EXECUTION_FAILED' }
        if (-not $drained) {
            # O processo principal ja saiu; o job alcanca descendentes cujo pai
            # intermediario terminou (ex.: exec do MSYS), que a arvore nao mostra.
            Stop-MaProcessTree $process $job
            throw 'MA_NATIVE_TIMEOUT'
        }
        # Stderr e mantido somente em memoria; relatorios nao o reproduzem.
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout.Result; StdErr = $stderr.Result }
    } finally {
        # Fechar o job nao encerra processos (sem KILL_ON_JOB_CLOSE): so o timeout encerra.
        if ($job -ne [IntPtr]::Zero) { [void](Get-MaJobApi)::CloseHandle($job) }
        $process.Dispose()
    }
}

# Job Object do Windows declarado por System.Reflection.Emit, somente em memoria:
# sem Add-Type (que no 5.1 chama csc.exe e grava temporarios), sem comandos
# externos e sem arquivos. Disponivel no .NET Framework (5.1) e no .NET (7).
$script:MaJobApi = $null
function Get-MaJobApi {
    if ($null -ne $script:MaJobApi) { return $script:MaJobApi }
    try {
        $assembly = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly((New-Object System.Reflection.AssemblyName 'MaNativeJob'), [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
        $type = $assembly.DefineDynamicModule('MaNativeJob').DefineType('MaNativeJob.Kernel32', [System.Reflection.TypeAttributes]'Public, Abstract, Sealed')
        $definitions = @(
            @('CreateJobObjectW', [IntPtr], [Type[]]@([IntPtr], [IntPtr])),
            @('AssignProcessToJobObject', [bool], [Type[]]@([IntPtr], [IntPtr])),
            @('TerminateJobObject', [bool], [Type[]]@([IntPtr], [uint32])),
            @('CloseHandle', [bool], [Type[]]@([IntPtr]))
        )
        foreach ($definition in $definitions) {
            $method = $type.DefinePInvokeMethod($definition[0], 'kernel32.dll', [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
                [System.Reflection.CallingConventions]::Standard, $definition[1], $definition[2],
                [System.Runtime.InteropServices.CallingConvention]::Winapi, [System.Runtime.InteropServices.CharSet]::Unicode)
            $method.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
        }
        $script:MaJobApi = $type.CreateType()
    } catch { $script:MaJobApi = $false }
    return $script:MaJobApi
}

# Associa o processo recem-iniciado a um job sem nome. Descendentes criados a
# partir dai herdam o job, mesmo que o pai intermediario termine. Limite: o que
# o processo criar entre Start() e a associacao (janela de microssegundos) fica
# fora do job. Se a API nao estiver disponivel, retorna Zero e o encerramento
# volta ao processo direto (ou a arvore, no .NET do PowerShell 7).
function New-MaProcessJob {
    param([System.Diagnostics.Process]$Process)
    $api = Get-MaJobApi
    if ($api -eq $false) { return [IntPtr]::Zero }
    try {
        $job = $api::CreateJobObjectW([IntPtr]::Zero, [IntPtr]::Zero)
        if ($job -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        if (-not $api::AssignProcessToJobObject($job, $Process.Handle)) { [void]$api::CloseHandle($job); return [IntPtr]::Zero }
        return $job
    } catch { return [IntPtr]::Zero }
}

function Stop-MaProcessTree {
    param([System.Diagnostics.Process]$Process, [IntPtr]$Job = [IntPtr]::Zero)
    if ($Job -ne [IntPtr]::Zero) { try { [void](Get-MaJobApi)::TerminateJobObject($Job, [uint32]1) } catch { } }
    try {
        if ($Process.HasExited) { return }
        $treeKill = $Process.GetType().GetMethod('Kill', [Type[]]@([bool]))
        if ($null -ne $treeKill) { [void]$treeKill.Invoke($Process, @($true)) } else { $Process.Kill() }
    } catch { }
}

# Leituras Git sem lock opcional (sem refresh do indice), sem lazy fetch, sem
# objetos de substituicao, sem fsmonitor, sem prompt e sem subir alem do destino.
function Invoke-MaGit {
    param([Parameter(Mandatory = $true)][string]$WorkingDirectory, [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Arguments)
    if ($null -ne $script:MaGitInvoker) { return (& $script:MaGitInvoker $WorkingDirectory $Arguments) }
    if (-not $script:MaGitPath) { throw 'MA_GIT_NOT_FOUND' }
    $ceiling = [IO.Path]::GetDirectoryName($WorkingDirectory.TrimEnd('\'))
    if (-not $ceiling) { $ceiling = $WorkingDirectory }
    $environment = @{
        GIT_OPTIONAL_LOCKS      = '0'
        GIT_NO_LAZY_FETCH       = '1'
        GIT_NO_REPLACE_OBJECTS  = '1'
        GIT_TERMINAL_PROMPT     = '0'
        GIT_LITERAL_PATHSPECS   = '1'
        GIT_CEILING_DIRECTORIES = $ceiling
        GCM_INTERACTIVE         = 'never'
        GIT_PAGER               = 'cat'
        LC_ALL                  = 'C'
    }
    $all = @('-c', 'core.fsmonitor=false') + $Arguments
    return (Invoke-MaNativeProcess -FilePath $script:MaGitPath -Arguments $all -WorkingDirectory $WorkingDirectory -Environment $environment)
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

function Get-MaGitContext {
    param([string]$WorkingDirectory)
    $issues = New-Object System.Collections.Generic.List[object]
    $context = [ordered]@{ Available = $false; Path = $null; Version = $null; Shell = $null }
    if ($null -eq $script:MaGitInvoker) {
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
    } catch { $issues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_GIT_EXECUTION_FAILED') -Severity 'Falha')) }
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

function Get-MaGitEntries {
    param([string]$Text, [ValidateSet('Tree', 'Index')][string]$Kind)
    $entries = @{}
    foreach ($record in (Split-MaNullFields $Text)) {
        $tab = $record.IndexOf([char]9)
        if ($tab -lt 0) { throw 'MA_ENV_GIT_UNREADABLE' }
        $meta = $record.Substring(0, $tab).Split(' ')
        $path = $record.Substring($tab + 1)
        if ($meta.Length -ne 3) { throw 'MA_ENV_GIT_UNREADABLE' }
        if ($Kind -eq 'Tree') { $entry = [pscustomobject]@{ Mode = $meta[0]; Type = $meta[1]; ObjectId = $meta[2]; Stage = '0' } }
        else { $entry = [pscustomobject]@{ Mode = $meta[0]; Type = 'index'; ObjectId = $meta[1]; Stage = $meta[2] } }
        if ($entries.ContainsKey($path)) { $entries[$path] = @($entries[$path]) + $entry } else { $entries[$path] = @($entry) }
    }
    return $entries
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
        ObjectFormat = 'sha1'; HooksPath = @(); DefaultHooks = @(); AuxiliaryHookFiles = @(); Worktrees = @(); Tree = @{}; Index = @{}
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
        if ($hookDirectories[$directory] -eq 'MA_HOOKS_EFFECTIVE_ACTIVE' -and $directory.Equals($governedHooks, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($inventory.Active.Count -gt 0) { $issues.Add((New-MaIssue $hookDirectories[$directory] -Severity 'Aviso' -Role $Role -Path $directory -Detail ($inventory.Active -join ', '))) }
    }

    # Entradas governadas no HEAD e no indice, lidas sem checkout nem filtros.
    $pathspecs = @($script:MaExclusiveDirectories) + @((Get-MaTemplateMap) | Where-Object { $_.IndexOf('/') -lt 0 })
    if ($state.Head) {
        $tree = Invoke-MaGit $root (@('ls-tree', '-r', '-z', '--full-tree', 'HEAD', '--') + $pathspecs)
        if ($tree.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'ls-tree')) }
        else { $state.Tree = Get-MaGitEntries $tree.StdOut 'Tree' }
    }
    $index = Invoke-MaGit $root (@('ls-files', '-s', '-z', '--') + $pathspecs)
    if ($index.ExitCode -ne 0) { $issues.Add((New-MaIssue 'MA_ENV_GIT_UNREADABLE' -Role $Role -Path $root -Detail 'ls-files')) }
    else { $state.Index = Get-MaGitEntries $index.StdOut 'Index' }
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

function Get-MaFilesystemEntry {
    param([string]$Root, [string]$RelativePath)
    $current = $Root
    $components = $RelativePath.Split('/')
    for ($index = 0; $index -lt $components.Length; $index++) {
        $current = [IO.Path]::Combine($current, $components[$index])
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) { return [pscustomobject]@{ Kind = 'Unsafe'; Bytes = $null } }
            return [pscustomobject]@{ Kind = 'Missing'; Bytes = $null }
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return [pscustomobject]@{ Kind = 'Unsafe'; Bytes = $null } }
        if ($index -lt $components.Length - 1 -and -not $item.PSIsContainer) { return [pscustomobject]@{ Kind = 'TypeConflict'; Bytes = $null } }
    }
    if ($item.PSIsContainer) { return [pscustomobject]@{ Kind = 'Directory'; Bytes = $null } }
    return [pscustomobject]@{ Kind = 'File'; Bytes = [IO.File]::ReadAllBytes($current) }
}

function Get-MaUnexpectedEntries {
    param([string]$Root, [string[]]$Expected)
    $found = New-Object System.Collections.Generic.List[string]
    $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Expected) { [void]$expectedSet.Add($path) }
    foreach ($directory in $script:MaExclusiveDirectories) {
        $entry = Get-MaFilesystemEntry $Root $directory
        if ($entry.Kind -eq 'Missing') { continue }
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
    foreach ($file in $RenderedFiles) {
        $expectedId = Get-MaGitBlobId $file.Bytes $Environment.ObjectFormat
        $fs = Get-MaFilesystemEntry $Environment.Path $file.Path
        $treeEntries = @(); if ($Environment.Tree.ContainsKey($file.Path)) { $treeEntries = @($Environment.Tree[$file.Path]) }
        $indexEntries = @(); if ($Environment.Index.ContainsKey($file.Path)) { $indexEntries = @($Environment.Index[$file.Path]) }
        $reasons = New-Object System.Collections.Generic.List[string]
        $classification = $null
        if ($fs.Kind -in @('Unsafe', 'TypeConflict')) { $classification = 'Inseguro'; $reasons.Add('link, junction ou componente intermediario nao diretorio') }
        else {
            if ($fs.Kind -eq 'Directory') { $reasons.Add('checkout: diretorio no lugar de arquivo') }
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
            elseif ($fs.Kind -eq 'Missing' -and $treeEntries.Count -eq 0 -and $indexEntries.Count -eq 0) { $classification = 'Ausente' }
            elseif ($fs.Kind -eq 'Missing') { $classification = 'Conflitante'; $reasons.Add('removido do checkout') }
            elseif (-not $Environment.IsRepository -or -not $Environment.Inspected) { $classification = 'Identico' }
            elseif ($treeEntries.Count -eq 1 -and $indexEntries.Count -eq 1) { $classification = 'Identico' }
            elseif ($treeEntries.Count -eq 1) { $classification = 'Conflitante'; $reasons.Add('removido do indice') }
            elseif ($role -eq 'maintenance') { $classification = 'PreparadoNaoCommitado' }
            else { $classification = 'Conflitante'; $reasons.Add('arquivo governado nao commitado fora da manutencao') }
        }
        $results.Add([pscustomobject]@{ Role = $role; Path = $file.Path; Classification = $classification; Reason = ($reasons -join '; '); ExpectedSha256 = $file.Sha256; ExpectedMode = $file.GitMode; ExpectedObjectId = $expectedId })
        if ($classification -eq 'Inseguro') { $issues.Add((New-MaIssue 'MA_FILE_UNSAFE' -Role $role -Path $file.Path)) }
        elseif ($classification -eq 'Conflitante') { $issues.Add((New-MaIssue 'MA_FILE_CONFLICT' -Role $role -Path $file.Path -Detail ($reasons -join '; '))) }
    }
    $expectedPaths = @($RenderedFiles | ForEach-Object { $_.Path })
    $fsUnexpected = Get-MaUnexpectedEntries $Environment.Path $expectedPaths
    $gitUnexpected = @(@($Environment.Tree.Keys) + @($Environment.Index.Keys) | Where-Object { $expectedPaths -notcontains $_ } | Sort-Object -Unique)
    foreach ($path in (@($fsUnexpected) + @($gitUnexpected) | Sort-Object -Unique)) { $issues.Add((New-MaIssue 'MA_FILE_UNEXPECTED_ENTRY' -Role $role -Path $path)) }
    return [pscustomobject]@{ Files = $results.ToArray(); Issues = $issues.ToArray() }
}

# --- Plan --------------------------------------------------------------------------

function Test-MaFullCommit {
    param([string]$Value)
    return ($Value -cmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z')
}

function Get-MaPlanStatus {
    param([object[]]$Issues, [bool]$Incomplete)
    if (@($Issues | Where-Object { $_.Severity -eq 'Falha' }).Count -gt 0) { return 'Falha' }
    if (@($Issues | Where-Object { $_.Severity -eq 'Bloqueio' }).Count -gt 0) { return 'Bloqueado' }
    if ($Incomplete) { return 'Incompleto' }
    return 'Sucesso'
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
    $issues = New-Object System.Collections.Generic.List[object]
    $actions = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[string]
    $files = New-Object System.Collections.Generic.List[object]
    $environments = @()
    $configuration = $null
    $gitContext = $null
    $package = $null
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
        # 1. Pacote confiavel.
        $package = Test-MaPackageIntegrity $PackageRoot
        foreach ($issue in $package.Issues) { $issues.Add($issue) }

        # 2. Configuracao e padroes.
        try {
            $schemaPath = [IO.Path]::Combine($PackageRoot, 'schema', 'project.schema.json')
            $configuration = Read-MaConfiguration -LiteralPath $ConfigPath -SchemaPath $schemaPath
            if (-not [IO.Path]::GetFileName($configuration.ConfigPath).Equals($script:MaExpectedConfigName, [StringComparison]::OrdinalIgnoreCase)) {
                $issues.Add((New-MaIssue 'MA_CONFIG_NAME_UNEXPECTED' -Severity 'Aviso' -Path $configuration.ConfigPath))
            }
            $packagePath = [IO.Path]::GetFullPath($PackageRoot)
            foreach ($role in $script:MaRoles) {
                $destination = $configuration.Worktrees[$role]
                if ((Test-MaPathWithin $packagePath $destination) -or (Test-MaPathWithin $destination $packagePath)) { $issues.Add((New-MaIssue 'MA_PACKAGE_INSIDE_WORKTREE' -Role $role -Path $destination)) }
            }
        } catch {
            $issues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PLAN_UNEXPECTED_FAILURE') -Path $ConfigPath))
            $configuration = $null
        }

        foreach ($pair in @(@('BaseCommit', $BaseCommit), @('IntegratedCommit', $IntegratedCommit))) {
            if ($pair[1] -and -not (Test-MaFullCommit $pair[1])) { $issues.Add((New-MaIssue 'MA_COMMIT_FORMAT_INVALID' -Detail $pair[0])) }
        }

        if ($null -ne $configuration) {
            # 3. Git, ambiente de processo e validacao das branches pelo proprio Git.
            foreach ($issue in (Get-MaGitOverrideIssues)) { $issues.Add($issue) }
            $git = Get-MaGitContext -WorkingDirectory $configuration.ParentDirectory
            $gitContext = $git.Context
            foreach ($issue in $git.Issues) { $issues.Add($issue) }
            if ($gitContext.Available) { foreach ($issue in (Test-MaBranchesWithGit $configuration.Branches $configuration.ParentDirectory)) { $issues.Add($issue) } }

            # 4. Renderizacao em memoria, somente a partir de pacote integro.
            $rendered = $null
            if ($package.Valid) {
                try {
                    $rendered = Get-MaRenderedFiles -PackageRoot $PackageRoot -Configuration $configuration -DistributionVersion $package.DistributionVersion
                } catch { $issues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PLAN_UNEXPECTED_FAILURE'))) }
            } else { $pending.Add('Renderizacao e classificacao dos destinos nao executadas: pacote sem integridade comprovada.') }

            # 5. Ambientes, alcance e destinos.
            $environments = @(foreach ($role in $script:MaRoles) { Get-MaEnvironmentInspection -Role $role -Configuration $configuration -GitAvailable ([bool]$gitContext.Available) })
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
                if ($base.ExitCode -eq 0) { $evidence.BaseCommit = 'presente localmente como commit; autorizacao nao verificada' }
                else { $issues.Add((New-MaIssue 'MA_BASECOMMIT_NOT_LOCAL' -Severity 'Aviso' -Role 'coordination')) }
            }

            # 6. Acoes previstas (nenhuma executada nesta fase).
            $byRole = @{}; foreach ($environment in $environments) { $byRole[$environment.Role] = $environment }
            if (-not $byRole.coordination.Exists -or $byRole.coordination.State -eq 'VazioSemRepositorio') {
                & $addAction 'PrepareMaintenance' 'coordination' ('Clonar origin em ' + $configuration.Worktrees.coordination + ' (branch ' + $configuration.Branches.coordination + ').')
                $incomplete = $true
                $pending.Add('Conteudo do repositorio remoto desconhecido sem clone: conflitos (inclusive README criado pelo servidor) so poderao ser classificados apos o clone.')
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
    } catch {
        $issues.Add((New-MaIssue (Get-MaErrorCode $_ 'MA_PLAN_UNEXPECTED_FAILURE') -Severity 'Falha'))
    }
    $issueArray = $issues.ToArray()
    $status = Get-MaPlanStatus $issueArray $incomplete
    $configurationSummary = $null
    if ($null -ne $configuration) {
        $configurationSummary = [pscustomobject]@{ Name = $configuration.Name; Slug = $configuration.Slug; RepositoryUrl = $configuration.RepositoryUrl; ParentDirectory = $configuration.ParentDirectory; Branches = $configuration.Branches; Worktrees = $configuration.Worktrees }
    }
    return [pscustomobject]@{
        Phase         = 'Plan'
        Status        = $status
        WhatIf        = [bool]$WhatIfRequested
        Modified      = $false
        Package       = $package
        Configuration = $configurationSummary
        Git           = $gitContext
        Environments  = @($environments | ForEach-Object { [pscustomobject]@{ Role = $_.Role; Path = $_.Path; ExpectedBranch = $_.ExpectedBranch; State = $_.State; Branch = $_.Branch; Head = $_.Head; HooksPath = $_.HooksPath; DefaultHooks = $_.DefaultHooks; AuxiliaryHookFiles = $_.AuxiliaryHookFiles } })
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

Export-ModuleMember -Function Invoke-MaPlan, Format-MaPlanReport, Get-MaExitCode, Read-MaConfiguration, Test-MaPackageIntegrity, Get-MaRenderedFiles
