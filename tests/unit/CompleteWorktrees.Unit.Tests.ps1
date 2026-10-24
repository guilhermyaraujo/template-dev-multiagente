#Requires -Version 5.1
<#
Testes unitarios da fase CompleteWorktrees. Autocontidos: nao dependem de Pester
(a versao 5 fixada ainda nao foi distribuida). Fixtures sao descartaveis, criadas
sob o TEMP do executor e nunca apontam para o projeto atual. Repositorios sao
simulados: nenhum repositorio Git e criado, alterado ou consultado; o Git e
substituido por um invocador simulado, e o Git real so e usado fora de
repositorios no caso do ponto de entrada. Nenhum caso usa WMI/CIM nem provoca
escape de processos da contencao do executor.

Uso: powershell -NoProfile -File tests/unit/CompleteWorktrees.Unit.Tests.ps1
Codigo de saida: 0 quando todos os casos passam; 1 se algum caso falha.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PackageSource = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
$Module = Import-Module -Name ([IO.Path]::Combine($PackageSource, 'scripts', 'MultiAgentTemplate.psm1')) -Force -PassThru -DisableNameChecking
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$M = 'a' * 40
$I = 'b' * 40
$Authorization = 'registro-humano-ficticio#unit-complete'
$PullRequest = 'https://example.invalid/org/demo/pull/7'
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]

# --- Mini-harness -----------------------------------------------------------------

function It {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Output ('  [ok]    ' + $Name) }
    catch { $script:Failed.Add($Name + ' :: ' + $_.Exception.Message); Write-Output ('  [FALHA] ' + $Name + ' :: ' + $_.Exception.Message) }
    finally { InModule { $script:MaGitInvoker = $null } }
}
function Assert-Equal { param($Expected, $Actual, [string]$Message = '') if (-not [object]::Equals($Expected, $Actual)) { throw ('esperado <' + $Expected + '> obtido <' + $Actual + '> ' + $Message) } }
function Assert-True { param([bool]$Condition, [string]$Message = 'condicao falsa') if (-not $Condition) { throw $Message } }
function Get-Codes { param($Result) return ((@($Result.Issues | ForEach-Object { $_.Code + '@' + $_.Role + ' ' + $_.Detail })) -join ', ') }
function Assert-HasIssue {
    param($Result, [string]$Code, [string]$Detail = '')
    if (@($Result.Issues | Where-Object { $_.Code -ceq $Code -and ($Detail -eq '' -or ([string]$_.Detail).Contains($Detail)) }).Count -eq 0) { throw ('ausente: ' + $Code + ' ' + $Detail + ' | presentes: ' + (Get-Codes $Result)) }
}
function InModule { param([scriptblock]$Body, [object[]]$Arguments = @()) return (& $Module $Body @Arguments) }

# --- Fixtures ---------------------------------------------------------------------

function New-FixtureRoot {
    $path = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ma-comp-tests-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    $script:FixtureRoots.Add($path)
    return $path
}

# Modelo efetivo minimo usado pelas funcoes da fase (sem ler arquivos).
function New-Model {
    param([string]$Parent = 'C:\ma-unit\ws')
    $branches = [ordered]@{ coordination = 'main'; codex = 'feature/codex'; claude = 'feature/claude'; maintenance = 'chore/manutencao' }
    $directories = [ordered]@{ coordination = 'demo'; codex = 'demo-codex'; claude = 'demo-claude'; maintenance = 'demo-manutencao' }
    $worktrees = [ordered]@{}
    foreach ($role in @($directories.Keys)) { $worktrees[$role] = [IO.Path]::Combine($Parent, $directories[$role]) }
    return [pscustomobject]@{ Name = 'Projeto Demo'; Slug = 'demo'; RepositoryUrl = 'ssh://git@example.invalid/org/demo.git'; ParentDirectory = $Parent; Branches = $branches; Directories = $directories; Worktrees = $worktrees }
}

function New-EvidenceData {
    return [ordered]@{
        evidenceVersion = '1.0'
        repository = 'ssh://git@example.invalid/org/demo.git'
        pullRequest = $PullRequest
        sourceBranch = 'chore/manutencao'
        targetBranch = 'main'
        reviewedHead = $M
        review = [ordered]@{ reviewer = 'Revisor Ficticio'; author = 'Autor Ficticio'; reference = 'revisao-ficticia#7'; reviewedHead = $M }
        mergeAuthorization = [ordered]@{ authorizedBy = 'Responsavel Ficticio'; reference = 'autorizacao-merge#7'; pullRequest = $PullRequest; reviewedHead = $M }
        integration = [ordered]@{ result = 'merged'; method = 'squash'; resultingCommit = $I; executedBy = 'Responsavel Ficticio'; proofSource = 'registro-servidor#7' }
        completionAuthorization = [ordered]@{ authorizedBy = 'Responsavel Ficticio'; reference = $Authorization; integratedCommit = $I; environments = @('demo', 'demo-codex', 'demo-claude', 'demo-manutencao'); operations = @('create-worktrees', 'configure-hooks') }
    }
}

function Write-EvidenceText {
    param([string]$Text, [string]$Root = '')
    if (-not $Root) { $Root = New-FixtureRoot }
    $path = [IO.Path]::Combine($Root, 'integracao.json')
    [IO.File]::WriteAllBytes($path, $Utf8.GetBytes($Text))
    return $path
}

function Read-Evidence {
    param($Data, [string]$IntegratedCommit = $I, [string]$AuthorizationReference = $Authorization, $Model = $null)
    if ($null -eq $Model) { $Model = New-Model }
    $path = Write-EvidenceText ($Data | ConvertTo-Json -Depth 6)
    return (InModule { param($p, $m, $a, $c) Read-MaIntegrationEvidence -LiteralPath $p -Configuration $m -AuthorizationReference $a -IntegratedCommit $c } @($path, $Model, $AuthorizationReference, $IntegratedCommit))
}

# Inspecao sintetica dos quatro ambientes para a politica de hooks.
function New-HooksInspection {
    param([string]$Parent = 'C:\ma-unit\ws')
    $model = New-Model $Parent
    $common = [IO.Path]::Combine($model.Worktrees.coordination, '.git')
    $environments = @(foreach ($role in @('coordination', 'codex', 'claude', 'maintenance')) {
        [pscustomobject]@{
            Role = $role; Path = $model.Worktrees[$role]; Inspected = $true; CommonDir = $common; Branch = $model.Branches[$role]; ExpectedBranch = $model.Branches[$role]
            HooksPath = @(); HooksDirectory = [IO.Path]::Combine($common, 'hooks'); DefaultHooks = @(); EffectiveHooks = @(); Worktrees = @()
        }
    })
    $environments[0].Worktrees = @(foreach ($role in @('coordination', 'codex', 'claude', 'maintenance')) {
        [pscustomobject]@{ Path = $model.Worktrees[$role]; Branch = $model.Branches[$role]; Detached = $false; Bare = $false; Prunable = $false; Locked = $false }
    })
    $files = @(foreach ($role in @('coordination', 'codex', 'claude', 'maintenance')) { foreach ($hook in @('.githooks/pre-commit', '.githooks/pre-push')) { [pscustomobject]@{ Role = $role; Path = $hook; Classification = 'Identico' } } })
    return [pscustomobject]@{ Configuration = $model; Environments = $environments; Files = $files; Issues = @() }
}

function Set-Compatible {
    param($Inspection, [string[]]$Roles = @('coordination', 'codex', 'claude', 'maintenance'))
    foreach ($environment in $Inspection.Environments) {
        if ($Roles -notcontains $environment.Role) { continue }
        $environment.HooksPath = @([pscustomobject]@{ Scope = 'local'; Origin = ('file:' + [IO.Path]::Combine($environment.CommonDir, 'config').Replace('\', '/')); Value = '.githooks' })
        $environment.HooksDirectory = [IO.Path]::Combine($environment.Path, '.githooks')
    }
}

function Get-HooksState { param($Inspection) return (InModule { param($i) Get-MaHooksActivationState $i } @(, $Inspection)) }

# Arquivos renderizados sinteticos: os onze caminhos governados com bytes simples.
function New-Rendered {
    $paths = InModule { Get-MaGovernedPaths }
    return @(foreach ($path in $paths) {
        $bytes = $Utf8.GetBytes('conteudo de ' + $path + "`n")
        $mode = '100644'; if ($path -like '.githooks/*') { $mode = '100755' }
        [pscustomobject]@{ Path = $path; Bytes = $bytes; Sha256 = (InModule { param($b) Get-MaSha256 $b } @(, $bytes)); GitMode = $mode }
    })
}

function Get-BlobId { param([byte[]]$Bytes) return (InModule { param($b) Get-MaGitBlobId $b 'sha1' } @(, $Bytes)) }

# Git simulado para a comparacao: ls-tree devolve $script:TreeText; cat-file le
# os objetos de $script:Objects (id -> @{ Type; Bytes }).
$script:TreeText = ''
$script:TreeExit = 0
$script:Objects = @{}
$GitMock = {
    param([string]$WorkingDirectory, [string[]]$Arguments, [bool]$Binary, [string]$InputText, [bool]$Transport)
    $offset = 0; while ($offset + 1 -lt $Arguments.Count -and $Arguments[$offset] -ceq '-c') { $offset += 2 }
    if ($offset -gt 0) { $Arguments = $Arguments[$offset..($Arguments.Count - 1)] }
    $ok = { param([string]$Out) [pscustomobject]@{ ExitCode = 0; StdOut = $Out; StdErr = '' } }
    if ($Arguments[0] -ceq 'ls-tree') { return [pscustomobject]@{ ExitCode = $script:TreeExit; StdOut = $script:TreeText; StdErr = '' } }
    if ($Arguments[0] -ceq 'cat-file' -and $Arguments[1] -ceq '--batch-check') {
        $id = ([string]$InputText).Trim()
        if (-not $script:Objects.ContainsKey($id)) { return (& $ok ($id + " missing`n")) }
        return (& $ok ($id + ' ' + $script:Objects[$id].Type + ' ' + $script:Objects[$id].Bytes.Length + "`n"))
    }
    if ($Arguments[0] -ceq 'cat-file' -and $Arguments[1] -ceq '-e') {
        if ($script:Objects.ContainsKey($Arguments[2])) { return (& $ok '') }
        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = '' }
    }
    if ($Arguments[0] -ceq 'cat-file') { return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdOutBytes = [byte[]]$script:Objects[$Arguments[2]].Bytes; StdErr = '' } }
    return [pscustomobject]@{ ExitCode = 129; StdOut = ''; StdErr = 'simulado' }
}
function Use-GitMock { InModule { param($m) $script:MaGitInvoker = $m } @(, $GitMock) }

# Arvore conforme com os renderizados; Changes: caminho -> registro ls-tree
# completo ('modo tipo id') ou $null (remover). Extra: registros adicionais.
function Set-Tree {
    param([object[]]$Rendered, [hashtable]$Changes = @{}, [string[]]$Extra = @())
    $script:Objects = @{}
    $records = New-Object System.Collections.Generic.List[string]
    foreach ($file in $Rendered) {
        $id = Get-BlobId $file.Bytes
        $script:Objects[$id] = @{ Type = 'blob'; Bytes = $file.Bytes }
        if ($Changes.ContainsKey($file.Path)) { if ($null -ne $Changes[$file.Path]) { $records.Add($Changes[$file.Path] + [char]9 + $file.Path) }; continue }
        $records.Add($file.GitMode + ' blob ' + $id + [char]9 + $file.Path)
    }
    $records.Add('100644 blob ' + ('d' * 40) + [char]9 + 'app.txt')
    foreach ($record in $Extra) { $records.Add($record) }
    $script:TreeText = (@($records | ForEach-Object { $_ + [char]0 }) -join '')
    $script:TreeExit = 0
}

function Compare-Tree {
    param([object[]]$Rendered)
    return (InModule { param($r) Get-MaGovernedCommitComparison -Root 'C:\ma-unit\ws\demo' -Commit ('e' * 40) -Label 'I' -RenderedFiles $r -ObjectFormat 'sha1' } @(, $Rendered))
}

function Get-Entry { param($Result, [string]$Path) return @($Result.Entries | Where-Object { $_.Path -ceq $Path })[0] }

# Ambiente sintetico para a classificacao dos destinos: checkout real numa fixture
# descartavel, HEAD e indice como mapas do modulo e objetos dados por conferidos.
# Rename: caminho governado -> grafia usada no checkout, no HEAD e no indice.
# Extra: caminhos adicionais somente no HEAD e no indice (blob de AGENTS.md).
function New-ClassificationEnvironment {
    param([object[]]$Rendered, [hashtable]$Rename = @{}, [string[]]$Extra = @())
    $root = New-FixtureRoot
    $tree = InModule { New-MaPathMap }
    $index = InModule { New-MaPathMap }
    $objects = @{}
    foreach ($file in $Rendered) {
        $path = $file.Path; if ($Rename.ContainsKey($path)) { $path = $Rename[$path] }
        $full = [IO.Path]::Combine($root, $path.Replace('/', '\'))
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
        [IO.File]::WriteAllBytes($full, $file.Bytes)
        $id = Get-BlobId $file.Bytes
        $objects[$id] = 'Ok'
        $tree[$path] = @([pscustomobject]@{ Mode = $file.GitMode; Type = 'blob'; ObjectId = $id; Stage = '0' })
        $index[$path] = @([pscustomobject]@{ Mode = $file.GitMode; Type = 'index'; ObjectId = $id; Stage = '0' })
    }
    $agents = Get-BlobId (@($Rendered | Where-Object { $_.Path -ceq 'AGENTS.md' })[0].Bytes)
    foreach ($path in $Extra) {
        $tree[$path] = @([pscustomobject]@{ Mode = '100644'; Type = 'blob'; ObjectId = $agents; Stage = '0' })
        $index[$path] = @([pscustomobject]@{ Mode = '100644'; Type = 'index'; ObjectId = $agents; Stage = '0' })
    }
    return [pscustomobject]@{ Role = 'codex'; Path = $root; CheckoutPending = $false; ObjectFormat = 'sha1'; IsRepository = $true; Inspected = $true; Tree = $tree; Index = $index; Objects = $objects }
}

function Get-Classification { param($Environment, [object[]]$Rendered) return (InModule { param($e, $r) Get-MaFileClassification $e $r } @($Environment, $Rendered)) }
function Get-UnexpectedPaths { param($Result) return ((@($Result.Issues | Where-Object { $_.Code -ceq 'MA_FILE_UNEXPECTED_ENTRY' } | ForEach-Object { $_.Path })) -join ',') }

# --- Casos ------------------------------------------------------------------------

Write-Output ('PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
InModule { $script:MaGitInvoker = $null }

try {
    Write-Output 'Registro de integracao (IntegrationReference)'
    It 'registro completo e consistente e aceito; o hash cobre os bytes lidos' {
        $data = New-EvidenceData
        $path = Write-EvidenceText ($data | ConvertTo-Json -Depth 6)
        $r = InModule { param($p, $m, $a, $c) Read-MaIntegrationEvidence -LiteralPath $p -Configuration $m -AuthorizationReference $a -IntegratedCommit $c } @($path, (New-Model), $Authorization, $I)
        Assert-Equal $true $r.Valid (Get-Codes $r)
        Assert-Equal $M $r.ReviewedHead
        Assert-Equal $I $r.IntegratedCommit
        Assert-Equal 'squash' $r.Method
        Assert-Equal 'create-worktrees,configure-hooks' ($r.Operations -join ',')
        Assert-Equal 'demo,demo-codex,demo-claude,demo-manutencao' ($r.Environments -join ',')
        $expected = InModule { param($p) Get-MaSha256 ([IO.File]::ReadAllBytes($p)) } @($path)
        Assert-Equal $expected $r.Sha256
    }
    It 'caminho vazio, relativo, inexistente, dentro de worktree ou acima do limite: recusado' {
        $model = New-Model
        $read = { param($p, $m) InModule { param($x, $y) Read-MaIntegrationEvidence -LiteralPath $x -Configuration $y -AuthorizationReference $Authorization -IntegratedCommit $I } @($p, $m) }
        Assert-HasIssue (& $read '' $model) 'MA_INTEGRATION_REFERENCE_REQUIRED'
        Assert-HasIssue (& $read 'integracao.json' $model) 'MA_INTEGRATION_REFERENCE_INVALID' 'MA_PATH_LOCAL_ABSOLUTE_REQUIRED'
        $root = New-FixtureRoot
        Assert-HasIssue (& $read ([IO.Path]::Combine($root, 'ausente.json')) $model) 'MA_INTEGRATION_REFERENCE_INVALID' 'MA_PATH_NOT_FOUND'
        $inside = New-Model $root
        [void][IO.Directory]::CreateDirectory($inside.Worktrees.claude)
        $path = [IO.Path]::Combine($inside.Worktrees.claude, 'integracao.json')
        [IO.File]::WriteAllBytes($path, $Utf8.GetBytes(((New-EvidenceData) | ConvertTo-Json -Depth 6)))
        Assert-HasIssue (& $read $path $inside) 'MA_INTEGRATION_REFERENCE_INSIDE_WORKTREE'
        $large = Write-EvidenceText ('{"evidenceVersion":"1.0","x":"' + ('a' * 70000) + '"}')
        $r = & $read $large $model
        Assert-HasIssue $r 'MA_INTEGRATION_REFERENCE_INVALID'
        Assert-Equal $null $r.Sha256 'registro acima do limite lido'
    }
    It 'JSON invalido, chave duplicada por caixa ou BOM invalido: recusado com o codigo do leitor' {
        $model = New-Model
        Assert-HasIssue (InModule { param($p, $m) Read-MaIntegrationEvidence -LiteralPath $p -Configuration $m } @((Write-EvidenceText '{"a":1,'), $model)) 'MA_INTEGRATION_REFERENCE_INVALID' 'MA_JSON'
        $duplicate = Write-EvidenceText '{"evidenceVersion":"1.0","EvidenceVersion":"1.0"}'
        Assert-HasIssue (InModule { param($p, $m) Read-MaIntegrationEvidence -LiteralPath $p -Configuration $m } @($duplicate, $model)) 'MA_INTEGRATION_REFERENCE_INVALID' 'MA_JSON_DUPLICATE_KEY'
    }
    It 'booleano de aprovacao, texto aprovado ou secao trocada por booleano: nunca aceitos' {
        $data = New-EvidenceData; $data['approved'] = $true
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'propriedade desconhecida approved'
        $data = New-EvidenceData; $data.review = $true
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'review: objeto esperado'
        $data = New-EvidenceData; $data.integration.result = 'aprovado'
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'integration.result'
        $data = New-EvidenceData; $data.integration.result = $true
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'integration.result'
        $data = New-EvidenceData; $data.completionAuthorization.operations = @('approve')
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'completionAuthorization.operations'
    }
    It 'cada campo obrigatorio ausente e relatado; grafia com outra caixa nao substitui' {
        foreach ($key in @('evidenceVersion', 'repository', 'pullRequest', 'sourceBranch', 'targetBranch', 'reviewedHead', 'review', 'mergeAuthorization', 'integration', 'completionAuthorization')) {
            $data = New-EvidenceData; $data.Remove($key)
            $r = Read-Evidence $data
            Assert-Equal $false $r.Valid $key
            Assert-HasIssue $r 'MA_INTEGRATION_REFERENCE_INVALID' ('registro.' + $key + ': ausente')
        }
        foreach ($pair in @(@('review', 'reviewer'), @('mergeAuthorization', 'pullRequest'), @('integration', 'proofSource'), @('completionAuthorization', 'environments'))) {
            $data = New-EvidenceData; $data[$pair[0]].Remove($pair[1])
            Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' ($pair[0] + '.' + $pair[1] + ': ausente')
        }
        $data = New-EvidenceData; $value = $data.repository; $data.Remove('repository'); $data['Repository'] = $value
        $r = Read-Evidence $data
        Assert-HasIssue $r 'MA_INTEGRATION_REFERENCE_INVALID' 'registro.repository: ausente'
        Assert-HasIssue $r 'MA_INTEGRATION_REFERENCE_INVALID' 'propriedade desconhecida Repository'
    }
    It 'versao, textos com quebra, controle ou acima de 500 caracteres e SHA abreviado: recusados' {
        $data = New-EvidenceData; $data.evidenceVersion = '2.0'
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'evidenceVersion'
        foreach ($text in @("linha`nquebrada", ('x' + [char]7), ('a' * 501), ' ', ('x' + [char]0x2028))) {
            $data = New-EvidenceData; $data.pullRequest = $text; $data.mergeAuthorization.pullRequest = $text
            Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'registro.pullRequest'
        }
        $data = New-EvidenceData; $data.reviewedHead = 'abc1234'
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'registro.reviewedHead: SHA completo'
        $data = New-EvidenceData; $data.integration.resultingCommit = $I.ToUpperInvariant()
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'integration.resultingCommit'
    }
    It 'repositorio, branches, vinculos a M, PR e I divergentes: inconsistencia relatada' {
        $cases = @(
            @({ param($d) $d.repository = 'https://example.invalid/org/outro.git' }, 'repository'),
            @({ param($d) $d.sourceBranch = 'feature/codex' }, 'sourceBranch'),
            @({ param($d) $d.targetBranch = 'chore/manutencao' }, 'targetBranch'),
            @({ param($d) $d.review.reviewedHead = $I }, 'review.reviewedHead'),
            @({ param($d) $d.mergeAuthorization.reviewedHead = $I }, 'mergeAuthorization.reviewedHead'),
            @({ param($d) $d.mergeAuthorization.pullRequest = 'https://example.invalid/org/demo/pull/8' }, 'mergeAuthorization.pullRequest'),
            @({ param($d) $d.completionAuthorization.integratedCommit = $M }, 'completionAuthorization.integratedCommit'),
            @({ param($d) $d.completionAuthorization.reference = 'outra' }, 'completionAuthorization.reference')
        )
        foreach ($case in $cases) {
            $data = New-EvidenceData; & $case[0] $data
            $r = Read-Evidence $data
            Assert-Equal $false $r.Valid $case[1]
            Assert-HasIssue $r 'MA_INTEGRATION_EVIDENCE_MISMATCH' $case[1]
        }
        Assert-HasIssue (Read-Evidence (New-EvidenceData) -IntegratedCommit $M) 'MA_INTEGRATION_EVIDENCE_MISMATCH' 'integration.resultingCommit'
        Assert-HasIssue (Read-Evidence (New-EvidenceData) -AuthorizationReference 'outra-referencia') 'MA_INTEGRATION_EVIDENCE_MISMATCH' 'completionAuthorization.reference'
    }
    It 'revisor igual ao autor, inclusive por caixa ou espacos: revisao independente nao comprovada' {
        $data = New-EvidenceData; $data.review.reviewer = '  autor ficticio '
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REVIEW_NOT_INDEPENDENT'
    }
    It 'metodo, ambientes e operacoes fora do vocabulario, vazios ou repetidos: recusados' {
        $data = New-EvidenceData; $data.integration.method = 'force-push'
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'integration.method'
        foreach ($list in @(@('demo', 'outro'), @('demo', 'demo'), @())) {
            $data = New-EvidenceData; $data.completionAuthorization.environments = $list
            Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'completionAuthorization.environments'
        }
        $data = New-EvidenceData; $data.completionAuthorization.operations = 'create-worktrees'
        Assert-HasIssue (Read-Evidence $data) 'MA_INTEGRATION_REFERENCE_INVALID' 'completionAuthorization.operations'
    }
    It 'nenhum texto do registro aparece nas ocorrencias (privacidade, AC19)' {
        $data = New-EvidenceData
        $data.review.reviewer = 'Autor Ficticio'; $data.repository = 'https://usuario-secreto@example.invalid/x.git'; $data.integration.method = 'metodo-secreto'
        $r = Read-Evidence $data -AuthorizationReference 'referencia-secreta'
        Assert-Equal $false $r.Valid
        $text = (@($r.Issues | ForEach-Object { $_.Message + ' ' + $_.Detail + ' ' + $_.Path }) -join ' ')
        foreach ($secret in @('Autor Ficticio', 'usuario-secreto', 'metodo-secreto', 'referencia-secreta', $Authorization, 'Responsavel Ficticio', $PullRequest)) { Assert-True (-not $text.Contains($secret)) ('reproduzido: ' + $secret) }
    }

    Write-Output 'Politica de ativacao dos hooks'
    It 'entrada ausente nos quatro, sem conflitos: uma insercao permitida' {
        $state = Get-HooksState (New-HooksInspection)
        Assert-Equal 'Inserir' $state.Decision (Get-Codes $state)
        Assert-Equal 4 @($state.Report).Count
        Assert-Equal 'Ausente,Ausente,Ausente,Ausente' ((@($state.Report | ForEach-Object { $_.State })) -join ',')
    }
    It 'configuracao local .githooks nos quatro, com origem absoluta ou relativa: compativel' {
        $inspection = New-HooksInspection; Set-Compatible $inspection
        Assert-Equal 'Compativel' (Get-HooksState $inspection).Decision
        # Origem relativa (worktree principal) e com segmentos '..' (worktree vinculado).
        $inspection.Environments[0].HooksPath[0].Origin = 'file:.git/config'
        $inspection.Environments[1].HooksPath[0].Origin = 'file:' + $inspection.Environments[1].CommonDir.Replace('\', '/') + '/worktrees/demo-codex/../../config'
        $state = Get-HooksState $inspection
        Assert-Equal 'Compativel' $state.Decision (Get-Codes $state)
    }
    It 'valor vazio, caminho distinto, escopo nao local, origem de include e multiplas ocorrencias: conflito' {
        $cases = @(
            @({ param($e) $e.HooksPath[0].Value = '' }, 'valor vazio'),
            @({ param($e) $e.HooksPath[0].Value = 'outro' }, 'caminho distinto'),
            @({ param($e) $e.HooksPath[0].Scope = 'global' }, 'escopo global'),
            @({ param($e) $e.HooksPath[0].Origin = 'file:C:/ma-unit/incluido.gitconfig' }, 'origem diferente'),
            @({ param($e) $e.HooksPath = @($e.HooksPath[0], $e.HooksPath[0]) }, '2 ocorrencias')
        )
        foreach ($case in $cases) {
            $inspection = New-HooksInspection; Set-Compatible $inspection
            & $case[0] $inspection.Environments[2]
            $state = Get-HooksState $inspection
            Assert-Equal 'Bloqueado' $state.Decision $case[1]
            Assert-HasIssue $state 'MA_HOOKS_CONFIG_CONFLICT' $case[1]
        }
    }
    It 'escopo command (override de processo) bloqueia sem remover' {
        $inspection = New-HooksInspection
        $inspection.Environments[3].HooksPath = @([pscustomobject]@{ Scope = 'command'; Origin = 'command line:'; Value = '.githooks' })
        $state = Get-HooksState $inspection
        Assert-Equal 'Bloqueado' $state.Decision
        Assert-HasIssue $state 'MA_HOOKS_PROCESS_OVERRIDE'
    }
    It 'destino efetivo diferente do previsto pela cadeia: precedencia inconclusiva' {
        $inspection = New-HooksInspection
        $inspection.Environments[1].HooksDirectory = 'C:\ma-unit\outros-hooks'
        Assert-HasIssue (Get-HooksState $inspection) 'MA_HOOKS_PRECEDENCE_INCONCLUSIVE'
        $inspection = New-HooksInspection; Set-Compatible $inspection
        $inspection.Environments[2].HooksDirectory = [IO.Path]::Combine($inspection.Environments[0].Path, '.githooks')
        Assert-HasIssue (Get-HooksState $inspection) 'MA_HOOKS_PRECEDENCE_INCONCLUSIVE'
    }
    It 'estado distinto entre worktrees (uma camada por worktree): conflito' {
        $inspection = New-HooksInspection; Set-Compatible $inspection @('coordination', 'codex', 'claude')
        $state = Get-HooksState $inspection
        Assert-Equal 'Bloqueado' $state.Decision
        Assert-HasIssue $state 'MA_HOOKS_CONFIG_CONFLICT' 'estado distinto'
    }
    It 'hook ativo no diretorio padrao seria ocultado: bloqueio; amostras nao contam' {
        $inspection = New-HooksInspection
        $inspection.Environments[0].DefaultHooks = @('pre-commit')
        $state = Get-HooksState $inspection
        Assert-Equal 'Bloqueado' $state.Decision
        Assert-HasIssue $state 'MA_HOOKS_DEFAULT_WOULD_BE_HIDDEN' 'pre-commit'
    }
    It 'quinto worktree, registro indisponivel, ambiente nao registrado ou repositorio comum distinto: alcance incompleto (AC17)' {
        $inspection = New-HooksInspection
        $inspection.Environments[0].Worktrees += [pscustomobject]@{ Path = 'C:\ma-unit\ws\quinto'; Branch = 'extra'; Detached = $false; Bare = $false; Prunable = $false; Locked = $false }
        Assert-HasIssue (Get-HooksState $inspection) 'MA_HOOKS_SCOPE_INCOMPLETE' 'registro extra'
        $inspection = New-HooksInspection; $inspection.Environments[0].Worktrees[2].Prunable = $true
        Assert-HasIssue (Get-HooksState $inspection) 'MA_HOOKS_SCOPE_INCOMPLETE'
        $inspection = New-HooksInspection; $inspection.Environments[0].Worktrees = @($inspection.Environments[0].Worktrees[0..2])
        Assert-HasIssue (Get-HooksState $inspection) 'MA_HOOKS_SCOPE_INCOMPLETE' 'nao registrado'
        $inspection = New-HooksInspection; $inspection.Environments[3].CommonDir = 'C:\ma-unit\outro\.git'
        Assert-HasIssue (Get-HooksState $inspection) 'MA_HOOKS_SCOPE_INCOMPLETE' 'repositorios comuns distintos'
        $inspection = New-HooksInspection; $inspection.Environments[1].Inspected = $false
        Assert-Equal 'Bloqueado' (Get-HooksState $inspection).Decision
    }
    It '.githooks de um ambiente alterada, ausente ou com arquivo extra: ativacao bloqueada' {
        $inspection = New-HooksInspection; $inspection.Files[3].Classification = 'Conflitante'
        Assert-HasIssue (Get-HooksState $inspection) 'MA_HOOKS_GOVERNED_INVALID'
        $inspection = New-HooksInspection; $inspection.Files = @($inspection.Files[1..7])
        Assert-HasIssue (Get-HooksState $inspection) 'MA_HOOKS_GOVERNED_INVALID'
        $inspection = New-HooksInspection; $inspection.Issues = @([pscustomobject]@{ Code = 'MA_FILE_UNEXPECTED_ENTRY'; Role = 'claude'; Path = '.githooks/post-merge'; Severity = 'Bloqueio' })
        Assert-HasIssue (Get-HooksState $inspection) 'MA_HOOKS_GOVERNED_INVALID' '.githooks/post-merge inesperado'
    }
    It 'impressao digital igual para o mesmo estado e diferente apos mudanca' {
        $first = Get-HooksState (New-HooksInspection)
        $second = Get-HooksState (New-HooksInspection)
        Assert-Equal $first.Fingerprint $second.Fingerprint
        $changed = New-HooksInspection; $changed.Environments[0].DefaultHooks = @('post-commit')
        Assert-True ($first.Fingerprint -cne (Get-HooksState $changed).Fingerprint) 'mudanca nao refletida'
    }

    Write-Output 'Hooks executados pela criacao de worktree e pelo checkout'
    It 'sem core.hooksPath valem os hooks ativos do diretorio padrao; cadeia compativel admite somente pre-commit e pre-push' {
        # Iterado como a fase o consome (foreach): uma lista vazia nao produz ocorrencia.
        $issuesOf = { param($e) $list = New-Object System.Collections.Generic.List[object]; foreach ($issue in (InModule { param($x) Get-MaCompleteHookIssues $x 'codex' } @(, $e))) { $list.Add($issue) }; return , $list.ToArray() }
        $inspection = New-HooksInspection
        $coordination = $inspection.Environments[0]
        Assert-Equal 0 (& $issuesOf $coordination).Count
        $coordination.DefaultHooks = @('post-checkout')
        Assert-Equal 'MA_PREPARE_HOOKS_WOULD_RUN' (& $issuesOf $coordination)[0].Code
        Set-Compatible $inspection
        $coordination.EffectiveHooks = @('pre-commit', 'pre-push')
        Assert-Equal 0 (& $issuesOf $coordination).Count
        $coordination.EffectiveHooks = @('pre-commit', 'reference-transaction')
        Assert-Equal 'reference-transaction' (& $issuesOf $coordination)[0].Detail
        $coordination.HooksPath[0].Value = 'outro'
        Assert-Equal 'MA_PREPARE_HOOKS_WOULD_RUN' (& $issuesOf $coordination)[0].Code
    }

    Write-Output 'Comparacao do conteudo governado pelo banco de objetos'
    It 'arvore conforme: onze caminhos conformes, bytes conferidos e app.txt ignorado' {
        Use-GitMock
        $rendered = New-Rendered; Set-Tree $rendered
        $r = Compare-Tree $rendered
        Assert-Equal 0 @($r.Issues).Count (Get-Codes $r)
        Assert-Equal 11 @($r.Entries | Where-Object { $_.Result -eq 'Conforme' -and $_.Sha256 }).Count
        Assert-Equal 11 @($r.Entries).Count
    }
    It 'modo, link, gitlink, bytes e ausencia divergentes sao relatados por caminho e propriedade' {
        Use-GitMock
        $rendered = New-Rendered
        $hook = @($rendered | Where-Object { $_.Path -ceq '.githooks/pre-push' })[0]
        $other = $Utf8.GetBytes("outro`n"); $otherId = Get-BlobId $other
        Set-Tree $rendered @{
            '.githooks/pre-push'         = ('100644 blob ' + (Get-BlobId $hook.Bytes))
            '.githooks/pre-commit'       = ('120000 blob ' + $otherId)
            'AGENTS.md'                  = ('100644 blob ' + $otherId)
            'docs/agentes/revisao.md'    = ('160000 commit ' + ('f' * 40))
            'docs/agentes/manutencao.md' = $null
        }
        $script:Objects[$otherId] = @{ Type = 'blob'; Bytes = $other }
        $r = Compare-Tree $rendered
        Assert-Equal 'modo 100644' (Get-Entry $r '.githooks/pre-push').Reason
        Assert-True ((Get-Entry $r '.githooks/pre-commit').Reason.StartsWith('link simbolico')) (Get-Entry $r '.githooks/pre-commit').Reason
        Assert-Equal 'bytes divergentes' (Get-Entry $r 'AGENTS.md').Reason
        Assert-Equal 'tipo commit' (Get-Entry $r 'docs/agentes/revisao.md').Reason
        Assert-Equal 'ausente' (Get-Entry $r 'docs/agentes/manutencao.md').Reason
        Assert-Equal 5 @($r.Issues | Where-Object { $_.Code -ceq 'MA_COMPLETE_GOVERNED_DIVERGENT' }).Count (Get-Codes $r)
        Assert-Equal 'Conforme' (Get-Entry $r 'CLAUDE.md').Result
    }
    It 'entradas extras, diretorio exclusivo como arquivo e grafias por caixa sao inesperadas' {
        Use-GitMock
        $rendered = New-Rendered
        $id = 'c' * 40
        Set-Tree $rendered @{} @(('100755 blob ' + $id + [char]9 + '.githooks/post-merge'), ('100644 blob ' + $id + [char]9 + 'Agents.md'), ('100644 blob ' + $id + [char]9 + 'Docs/Agentes/extra.md'), ('100644 blob ' + $id + [char]9 + '.multiagente/outro.json'), ('100644 blob ' + $id + [char]9 + 'docs/outro.md'))
        $r = Compare-Tree $rendered
        $unexpected = @($r.Entries | Where-Object { $_.Result -eq 'Inesperado' } | ForEach-Object { $_.Path } | Sort-Object)
        Assert-Equal '.githooks/post-merge,.multiagente/outro.json,Agents.md,Docs/Agentes/extra.md' ($unexpected -join ',')
        Assert-Equal 4 @($r.Issues | Where-Object { $_.Code -ceq 'MA_FILE_UNEXPECTED_ENTRY' }).Count
        Set-Tree $rendered @{ '.githooks/pre-commit' = $null; '.githooks/pre-push' = $null } @(('100644 blob ' + $id + [char]9 + '.githooks'))
        $r = Compare-Tree $rendered
        Assert-True (@($r.Entries | Where-Object { $_.Path -ceq '.githooks' -and $_.Result -eq 'Inesperado' }).Count -eq 1) 'arquivo .githooks'
    }
    It 'objeto ausente, corrompido ou de outro tipo: interrompe sem busca, com o codigo do objeto' {
        Use-GitMock
        $rendered = New-Rendered; Set-Tree $rendered
        $agents = Get-BlobId (@($rendered | Where-Object { $_.Path -ceq 'AGENTS.md' })[0].Bytes)
        $claude = Get-BlobId (@($rendered | Where-Object { $_.Path -ceq 'CLAUDE.md' })[0].Bytes)
        $readme = Get-BlobId (@($rendered | Where-Object { $_.Path -ceq 'README.md' })[0].Bytes)
        $script:Objects.Remove($agents)
        $script:Objects[$claude] = @{ Type = 'blob'; Bytes = $Utf8.GetBytes("corrompido`n") }
        $script:Objects[$readme] = @{ Type = 'tree'; Bytes = [byte[]]@() }
        $r = Compare-Tree $rendered
        Assert-Equal 'objeto Missing' (Get-Entry $r 'AGENTS.md').Reason
        Assert-True (@($r.Issues | Where-Object { $_.Code -ceq 'MA_GIT_OBJECT_MISSING' -and $_.Path -ceq 'AGENTS.md' }).Count -eq 1) (Get-Codes $r)
        Assert-True (@($r.Issues | Where-Object { $_.Code -ceq 'MA_GIT_OBJECT_CORRUPT' -and $_.Path -ceq 'CLAUDE.md' }).Count -eq 1) (Get-Codes $r)
        Assert-True (@($r.Issues | Where-Object { $_.Code -ceq 'MA_GIT_OBJECT_TYPE_MISMATCH' -and $_.Path -ceq 'README.md' }).Count -eq 1) (Get-Codes $r)
    }
    It 'listagem com falha, malformada ou com caminho repetido: leitura inconclusiva' {
        Use-GitMock
        $rendered = New-Rendered; Set-Tree $rendered
        $script:TreeExit = 128
        Assert-HasIssue (Compare-Tree $rendered) 'MA_ENV_GIT_UNREADABLE' 'ls-tree I'
        Set-Tree $rendered; $script:TreeText = 'sem-tab' + [char]0
        Assert-HasIssue (Compare-Tree $rendered) 'MA_ENV_GIT_UNREADABLE'
        Set-Tree $rendered; $script:TreeText = $script:TreeText + $script:TreeText
        Assert-HasIssue (Compare-Tree $rendered) 'MA_ENV_GIT_UNREADABLE'
    }
    It 'commit lido como commit e conferido pelo identificador; outro tipo recusado' {
        Use-GitMock
        $bytes = $Utf8.GetBytes("tree " + ('4b825dc642cb6eb9a060e54bf8d69288fbee4904') + "`nauthor x <x> 0 +0000`ncommitter x <x> 0 +0000`n`nm`n")
        $id = InModule { param($b) Get-MaGitObjectId $b 'sha1' 'commit' } @(, $bytes)
        $script:Objects = @{}; $script:Objects[$id] = @{ Type = 'commit'; Bytes = $bytes }
        Assert-Equal 'Ok' (InModule { param($i) (Read-MaGitObject 'C:\ma-unit' $i 'sha1' 'commit').Status } @($id))
        Assert-Equal 'TypeMismatch' (InModule { param($i) (Read-MaGitObject 'C:\ma-unit' $i 'sha1' 'blob').Status } @($id))
        Assert-Equal 'Missing' (InModule { (Read-MaGitObject 'C:\ma-unit' ('9' * 40) 'sha1' 'commit').Status })
        Assert-Equal 'Undetermined' (InModule { (Read-MaGitObject 'C:\ma-unit' 'HEAD' 'sha1' 'commit').Status })
    }

    Write-Output 'Identidade exata dos caminhos governados (comparacao ordinal)'
    It 'entradas do Git por caminho exato: grafias por caixa distintas e filtro dos caminhos relevantes' {
        $id = 'c' * 40
        $text = (@(('100755 blob ' + $id + [char]9 + '.githooks/pre-commit'), ('100755 blob ' + $id + [char]9 + '.githooks/Pre-Commit'), ('100644 blob ' + $id + [char]9 + 'AGENTS.MD'), ('100644 blob ' + $id + [char]9 + '.GitHooks/x'), ('100644 blob ' + $id + [char]9 + 'app.txt'), ('100644 blob ' + $id + [char]9 + 'docs/outro.md')) | ForEach-Object { $_ + [char]0 }) -join ''
        $entries = InModule { param($t) $f = Get-MaGovernedPathPattern (Get-MaTemplateMap); Get-MaGitEntries $t 'Tree' $f } @($text)
        Assert-Equal '.githooks/pre-commit,.githooks/Pre-Commit,.GitHooks/x,AGENTS.MD' ((@($entries.Keys) | Sort-Object -CaseSensitive) -join ',')
        Assert-True (-not $entries.ContainsKey('.githooks/PRE-COMMIT')) 'chave encontrada sem distinguir caixa'
        Assert-Equal 1 @($entries['.githooks/pre-commit']).Count 'entradas de grafias distintas agrupadas'
        $all = InModule { param($t) Get-MaGitEntries $t 'Tree' } @($text)
        Assert-Equal 6 $all.Count 'sem filtro'
    }
    It 'checkout com o nome exato e File; grafia por caixa e CaseMismatch com o nome gravado' {
        $root = New-FixtureRoot
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($root, '.githooks'))
        [IO.File]::WriteAllBytes([IO.Path]::Combine($root, '.githooks', 'Pre-Commit'), $Utf8.GetBytes("x`n"))
        [IO.File]::WriteAllBytes([IO.Path]::Combine($root, '.githooks', 'pre-push'), $Utf8.GetBytes("y`n"))
        $exact = InModule { param($r) Get-MaFilesystemEntry $r '.githooks/pre-push' } @($root)
        Assert-Equal 'File' $exact.Kind
        $variant = InModule { param($r) Get-MaFilesystemEntry $r '.githooks/pre-commit' } @($root)
        Assert-Equal 'CaseMismatch' $variant.Kind
        Assert-Equal '.githooks/Pre-Commit' $variant.Actual
        Assert-Equal $null $variant.Bytes 'conteudo lido apesar da grafia'
        $directory = InModule { param($r) Get-MaFilesystemEntry $r '.GITHOOKS/pre-push' } @($root)
        Assert-Equal 'CaseMismatch' $directory.Kind
        Assert-Equal '.githooks/pre-push' $directory.Actual
        Assert-Equal 'Missing' (InModule { param($r) (Get-MaFilesystemEntry $r '.githooks/post-merge').Kind } @($root))
    }
    It 'nomes governados exatos no checkout, no HEAD e no indice: onze identicos, nenhuma ocorrencia' {
        $rendered = New-Rendered
        $r = Get-Classification (New-ClassificationEnvironment $rendered) $rendered
        Assert-Equal 11 @($r.Files | Where-Object { $_.Classification -ceq 'Identico' }).Count ((@($r.Files | ForEach-Object { $_.Path + ' ' + $_.Classification + ' ' + $_.Reason })) -join '; ')
        Assert-Equal 0 @($r.Issues).Count (Get-Codes $r)
    }
    It 'nome que difere somente pela caixa, com bytes e modo corretos: recusado e relatado como inesperado' {
        $rendered = New-Rendered
        $r = Get-Classification (New-ClassificationEnvironment $rendered @{ '.githooks/pre-commit' = '.githooks/Pre-Commit' }) $rendered
        $file = @($r.Files | Where-Object { $_.Path -ceq '.githooks/pre-commit' })[0]
        Assert-Equal 'Conflitante' $file.Classification $file.Reason
        Assert-True ($file.Reason.Contains('grafia divergente por caixa (.githooks/Pre-Commit)')) $file.Reason
        Assert-HasIssue $r 'MA_FILE_CONFLICT'
        Assert-Equal '.githooks/Pre-Commit' (Get-UnexpectedPaths $r)
        Assert-Equal 10 @($r.Files | Where-Object { $_.Classification -ceq 'Identico' }).Count
        # Diretorio exclusivo com outra grafia: os quatro documentos e o diretorio.
        $renames = @{}
        foreach ($name in @('coordenacao', 'desenvolvimento', 'manutencao', 'revisao')) { $renames['docs/agentes/' + $name + '.md'] = 'docs/Agentes/' + $name + '.md' }
        $r = Get-Classification (New-ClassificationEnvironment $rendered $renames) $rendered
        Assert-Equal 4 @($r.Files | Where-Object { $_.Path -like 'docs/agentes/*' -and $_.Classification -ceq 'Conflitante' -and $_.Reason.Contains('(docs/Agentes/') }).Count
        Assert-Equal 'docs/Agentes,docs/Agentes/coordenacao.md,docs/Agentes/desenvolvimento.md,docs/Agentes/manutencao.md,docs/Agentes/revisao.md' (Get-UnexpectedPaths $r)
    }
    It 'entrada extra que difere somente pela caixa no HEAD e no indice: detectada uma vez' {
        $rendered = New-Rendered
        $r = Get-Classification (New-ClassificationEnvironment $rendered @{} @('.githooks/Pre-Push', 'Agents.md')) $rendered
        Assert-Equal 11 @($r.Files | Where-Object { $_.Classification -ceq 'Identico' }).Count
        Assert-Equal '.githooks/Pre-Push,Agents.md' (Get-UnexpectedPaths $r)
    }
    It 'entrada inesperada por caixa em .githooks impede a ativacao dos hooks' {
        $inspection = New-HooksInspection
        Assert-Equal 'Inserir' (Get-HooksState $inspection).Decision
        $inspection.Issues = @([pscustomobject]@{ Code = 'MA_FILE_UNEXPECTED_ENTRY'; Severity = 'Bloqueio'; Role = 'claude'; Path = '.githooks/Pre-Push'; Detail = '' })
        $state = Get-HooksState $inspection
        Assert-Equal 'Bloqueado' $state.Decision
        Assert-True (@($state.Issues | Where-Object { $_.Code -ceq 'MA_HOOKS_GOVERNED_INVALID' -and $_.Role -eq 'claude' -and $_.Detail.Contains('.githooks/Pre-Push inesperado') }).Count -eq 1) (Get-Codes $state)
    }

    Write-Output 'Fase, relatorio e ponto de entrada'
    It 'sem evidencias e com configuracao ilegivel: bloqueio sem nenhuma chamada ao Git' {
        $counter =$Module.NewBoundScriptBlock({ param($a, $b, $c, $d, $e) $script:UnitCalls++; [pscustomobject]@{ ExitCode = 129; StdOut = ''; StdErr = '' } })
        InModule { param($m) $script:UnitCalls = 0; $script:MaGitInvoker = $m } @(, $counter)
        $root = New-FixtureRoot
        $r = Invoke-MaCompleteWorktrees -ConfigPath ([IO.Path]::Combine($root, 'multiagente.config.json')) -PackageRoot ([IO.Path]::Combine($root, 'pacote'))
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        foreach ($code in @('MA_AUTHORIZATION_REFERENCE_REQUIRED', 'MA_INTEGRATEDCOMMIT_REQUIRED', 'MA_INTEGRATION_REFERENCE_REQUIRED')) { Assert-HasIssue $r $code }
        Assert-Equal $false $r.Modified
        Assert-Equal 0 (InModule { $script:UnitCalls }) 'Git chamado'
        $lines = Format-MaCompleteReport $r
        Assert-Equal 'Fase: CompleteWorktrees' $lines[0]
        Assert-Equal 'Nenhuma modificacao foi realizada.' $lines[$lines.Count - 1]
    }
    It 'relatorio: parcial, comparacao, hooks por worktree e acoes, sem dados do registro' {
        $result = [pscustomobject]@{
            Phase = 'CompleteWorktrees'; Status = 'Bloqueado'; WhatIf = $false; Modified = $true; Partial = $true; Package = $null; Configuration = $null; Git = $null; Environments = @(); Files = @()
            Comparison = @([pscustomobject]@{ Source = 'I'; Commit = $I; Path = 'AGENTS.md'; Result = 'Divergente'; Reason = 'bytes divergentes'; Mode = '100644'; Type = 'blob'; ObjectId = ('c' * 40); Sha256 = ('d' * 64); ExpectedMode = '100644'; ExpectedObjectId = ('e' * 40); ExpectedSha256 = ('f' * 64) })
            Hooks = [pscustomobject]@{ Decision = 'Bloqueado'; Worktrees = @([pscustomobject]@{ Role = 'codex'; Root = 'C:\ws\demo-codex'; Branch = 'feature/codex'; ExpectedBranch = 'feature/codex'; CommonDir = 'C:\ws\demo\.git'; Values = 'local file:x = outro'; EffectiveValue = 'outro'; Destination = 'C:\ws\demo-codex\outro'; ExpectedDestination = 'C:\ws\demo-codex\.githooks'; Files = '.githooks/pre-commit Identico'; State = 'Conflito' }) }
            Performed = @([pscustomobject]@{ Order = 1; Role = 'codex'; Operation = 'Criar worktree'; Target = 'C:\ws\demo-codex'; Detail = 'nova branch' })
            Simulated = @(); Issues = @([pscustomobject]@{ Code = 'MA_HOOKS_CONFIG_CONFLICT'; Severity = 'Bloqueio'; Role = 'codex'; Path = 'C:\ws\demo-codex'; Message = 'm'; Detail = 'caminho distinto' })
            Pending = @('p'); Evidence = [pscustomobject]@{ IntegrationReference = 'registro SHA-256 x' }
        }
        $text = (Format-MaCompleteReport $result) -join "`n"
        foreach ($expected in @('Execucao parcial', '[I] AGENTS.md | Divergente | 100644 blob', 'Hooks por worktree (decisao: Bloqueado):', 'core.hooksPath: local file:x = outro', '1. [codex] Criar worktree', 'Modificacoes realizadas: 1 operacao(oes); nenhum commit, indice, push, PR ou merge.')) {
            Assert-True ($text.Contains($expected)) ('ausente no relatorio: ' + $expected)
        }
    }
    It 'ponto de entrada: CompleteWorktrees sem registro e Validate com configuracao invalida bloqueadas (codigo 3), sem modificacao' {
        $root = New-FixtureRoot
        $config = [IO.Path]::Combine($root, 'multiagente.config.json')
        [IO.File]::WriteAllBytes($config, $Utf8.GetBytes('{"schemaVersion":"1.0"}'))
        $host5 = (Get-Process -Id $PID).Path
        $script = [IO.Path]::Combine($PackageSource, 'scripts', 'Install-MultiAgentProject.ps1')
        $ErrorActionPreference = 'Continue'
        $complete = & $host5 -NoProfile -NonInteractive -File $script -Config $config -Phase CompleteWorktrees 2>&1
        $completeCode = $LASTEXITCODE
        $validate = & $host5 -NoProfile -NonInteractive -File $script -Config $config -Phase Validate 2>&1
        $validateCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Assert-Equal 3 $completeCode ($complete | Out-String)
        Assert-True (($complete | Out-String).Contains('MA_INTEGRATION_REFERENCE_REQUIRED')) ($complete | Out-String)
        Assert-Equal 3 $validateCode ($validate | Out-String)
        Assert-True (($validate | Out-String).Contains('Conformidade local: Inconclusiva')) ($validate | Out-String)
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $root -Force -Recurse).Count 'fixture alterada'
    }
} finally {
    InModule { $script:MaGitInvoker = $null }
    foreach ($root in $script:FixtureRoots) { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) } }
}

Write-Output ''
Write-Output ('Resultado: ' + $script:Passed + ' aprovados, ' + $script:Failed.Count + ' falhas')
foreach ($failure in $script:Failed) { Write-Output ('  - ' + $failure) }
if ($script:Failed.Count -gt 0) { exit 1 }
exit 0
