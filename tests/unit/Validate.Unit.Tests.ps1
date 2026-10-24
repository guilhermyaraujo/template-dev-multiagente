#Requires -Version 5.1
<#
Testes unitarios da fase Validate. Autocontidos: nao dependem de Pester (a
versao 5 fixada ainda nao foi distribuida). Fixtures sao descartaveis, criadas sob
o TEMP do executor e nunca apontam para o projeto atual. Repositorios sao
simulados: nenhum repositorio Git e criado, alterado ou consultado; o Git e
substituido por um invocador simulado, e o Git real so e usado fora de
repositorios no caso do ponto de entrada. A consulta da exclusao mutua usa um
diretorio descartavel e um mutex de nome derivado dele. Nenhum caso usa WMI/CIM
nem provoca escape de processos da contencao do executor.

Uso: powershell -NoProfile -File tests/unit/Validate.Unit.Tests.ps1
Codigo de saida: 0 quando todos os casos passam; 1 se algum caso falha.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PackageSource = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
$Module = Import-Module -Name ([IO.Path]::Combine($PackageSource, 'scripts', 'MultiAgentTemplate.psm1')) -Force -PassThru -DisableNameChecking
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$M = 'a' * 40
$I = 'b' * 40
$Authorization = 'registro-humano-ficticio#unit-validate'
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
function Get-Codes { param($Result) return ((@($Result.Issues | ForEach-Object { $_.Severity + ':' + $_.Code + '@' + $_.Role + ' ' + $_.Detail })) -join ', ') }
function Assert-HasIssue {
    param($Result, [string]$Code, [string]$Detail = '')
    if (@($Result.Issues | Where-Object { $_.Code -ceq $Code -and ($Detail -eq '' -or ([string]$_.Detail).Contains($Detail)) }).Count -eq 0) { throw ('ausente: ' + $Code + ' ' + $Detail + ' | presentes: ' + (Get-Codes $Result)) }
}
function InModule { param([scriptblock]$Body, [object[]]$Arguments = @()) return (& $Module $Body @Arguments) }
function New-Issue { param([string]$Code, [string]$Severity = 'Bloqueio') return (InModule { param($c, $s) New-MaIssue $c -Severity $s } @($Code, $Severity)) }

# --- Fixtures ---------------------------------------------------------------------

function New-FixtureRoot {
    $path = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ma-val-tests-' + [Guid]::NewGuid().ToString('N'))
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
    param([string]$Text)
    $path = [IO.Path]::Combine((New-FixtureRoot), 'integracao.json')
    [IO.File]::WriteAllBytes($path, $Utf8.GetBytes($Text))
    return $path
}

# Git simulado. $script:Responses: comando (argumentos unidos por espaco) ->
# @{ ExitCode; StdOut }; ausente devolve 129. $script:Calls registra os comandos.
$script:Responses = @{}
$script:Calls = New-Object System.Collections.Generic.List[string]
$GitMock = {
    param([string]$WorkingDirectory, [string[]]$Arguments, [bool]$Binary, [string]$InputText, [bool]$Transport)
    $command = $Arguments -join ' '
    $script:Calls.Add($command)
    if ($script:Responses.ContainsKey($command)) { $response = $script:Responses[$command]; return [pscustomobject]@{ ExitCode = $response.ExitCode; StdOut = $response.StdOut; StdErr = '' } }
    return [pscustomobject]@{ ExitCode = 129; StdOut = ''; StdErr = 'simulado' }
}
function Use-GitMock { $script:Calls.Clear(); InModule { param($m) $script:MaGitInvoker = $m } @(, $GitMock) }
function Set-Response { param([string]$Command, [string]$StdOut = '', [int]$ExitCode = 0) $script:Responses[$Command] = @{ ExitCode = $ExitCode; StdOut = $StdOut } }
function Join-Nul { param([string[]]$Items) return ((@($Items | ForEach-Object { $_ + [char]0 })) -join '') }

# Ambiente simulado com arquivos rastreados, atributos filter e status.
function Set-WorkingState {
    param([string[]]$Tracked, [string[]]$Status = @(), [hashtable]$Filters = @{})
    $script:Responses = @{}
    Set-Response 'ls-files -z' (Join-Nul $Tracked)
    $attributes = foreach ($path in $Tracked) { $value = 'unspecified'; if ($Filters.ContainsKey($path)) { $value = $Filters[$path] }; $path; 'filter'; $value }
    Set-Response 'check-attr -z --stdin filter' (Join-Nul @($attributes))
    Set-Response 'status --porcelain=v1 -z --untracked-files=all --no-renames --ignore-submodules=all' (Join-Nul $Status)
}
function Get-WorkingChanges { param([string]$Role) return (InModule { param($r) Get-MaWorkingChanges ([pscustomobject]@{ Role = $r; Path = 'C:\ma-unit\ws\demo' }) } @($Role)) }

# --- Casos ------------------------------------------------------------------------

Write-Output ('PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
InModule { $script:MaGitInvoker = $null }

try {
    Write-Output 'Categorias e conformidade local'
    It 'categoria: aviso, pre-condicao, leitura inconclusiva e divergencia demonstrada' {
        $category = { param($i, $p) InModule { param($x, $y) Get-MaValidateCategory $x $y } @($i, $p) }
        Assert-Equal 'aviso' (& $category (New-Issue 'MA_FILE_CONFLICT' 'Aviso') $false)
        Assert-Equal 'pre-condicao' (& $category (New-Issue 'MA_FILE_CONFLICT') $true)
        foreach ($code in @('MA_ENV_GIT_UNREADABLE', 'MA_GIT_OBJECT_MISSING', 'MA_GIT_OBJECT_CORRUPT', 'MA_GIT_ENV_OVERRIDE', 'MA_HOOKS_PRECEDENCE_INCONCLUSIVE', 'MA_HOOKS_PROCESS_OVERRIDE', 'MA_PACKAGE_HASH_MISMATCH', 'MA_CONFIG_REQUIRED', 'MA_VALIDATE_STATE_CHANGED', 'MA_VALIDATE_CONCURRENT_PHASE', 'MA_VALIDATE_CHANGES_UNVERIFIED', 'MA_COMPLETE_COMMIT_UNAVAILABLE')) {
            Assert-Equal 'leitura inconclusiva' (& $category (New-Issue $code) $false) $code
        }
        Assert-Equal 'leitura inconclusiva' (& $category (New-Issue 'MA_FILE_CONFLICT' 'Falha') $false) 'falha operacional'
        foreach ($code in @('MA_FILE_CONFLICT', 'MA_FILE_UNEXPECTED_ENTRY', 'MA_ENV_BRANCH_MISMATCH', 'MA_WORKTREE_UNEXPECTED', 'MA_HOOKS_CONFIG_CONFLICT', 'MA_VALIDATE_COORDINATION_CHANGED', 'MA_PREPARE_BRANCH_CASE_CONFLICT')) {
            Assert-Equal 'divergencia' (& $category (New-Issue $code) $false) $code
        }
    }
    It 'conformidade: divergencia prevalece sobre leitura inconclusiva, que prevalece sobre incompletude; avisos nao contam' {
        $conformity = { param($issues, $incomplete, $loaded) InModule { param($a, $b, $c) Get-MaValidateConformity $a $b $c } @(, $issues + @($incomplete, $loaded)) }
        Assert-Equal 'Conforme' (& $conformity @() 0 $true)
        Assert-Equal 'Conforme' (& $conformity @((New-Issue 'MA_VALIDATE_WORKING_CHANGES' 'Aviso')) 0 $true)
        Assert-Equal 'Incompleta' (& $conformity @((New-Issue 'MA_HOOKS_DEFAULT_ACTIVE' 'Aviso')) 2 $true)
        Assert-Equal 'Inconclusiva' (& $conformity @((New-Issue 'MA_GIT_OBJECT_MISSING')) 2 $true)
        Assert-Equal 'Divergente' (& $conformity @((New-Issue 'MA_GIT_OBJECT_MISSING'), (New-Issue 'MA_FILE_CONFLICT')) 2 $true)
        Assert-Equal 'Inconclusiva' (& $conformity @() 0 $false) 'configuracao nao carregada'
    }

    Write-Output 'Alteracoes de trabalho'
    It 'ambiente limpo: Limpo, sem ocorrencias' {
        Use-GitMock
        Set-WorkingState @('AGENTS.md', 'app.txt')
        $r = Get-WorkingChanges 'codex'
        Assert-Equal 'Limpo' $r.State
        Assert-Equal 0 @($r.Issues).Count
    }
    It 'governados exatos e diretorios exclusivos ficam com a classificacao; demais caminhos sao alteracoes' {
        Use-GitMock
        Set-WorkingState @('AGENTS.md', 'app.txt') @(' M AGENTS.md', '?? .githooks/post-merge', '?? .GitHooks/Extra', '?? .multiagente/x.json', ' M app.txt', 'A  src/novo.txt', '?? Agents.md')
        $r = Get-WorkingChanges 'claude'
        Assert-Equal 'Alterado' $r.State
        Assert-Equal 'app.txt,src/novo.txt,Agents.md' (@($r.Paths) -join ',')
        Assert-Equal 1 @($r.Issues).Count
        Assert-Equal 'MA_VALIDATE_WORKING_CHANGES' $r.Issues[0].Code
        Assert-Equal 'Aviso' $r.Issues[0].Severity
        Assert-True ($r.Issues[0].Detail.StartsWith('3 caminho(s): ')) $r.Issues[0].Detail
    }
    It 'na coordenacao, alteracao bloqueia como divergencia' {
        Use-GitMock
        Set-WorkingState @('app.txt') @('?? notas.txt')
        $r = Get-WorkingChanges 'coordination'
        Assert-Equal 'Alterado' $r.State
        Assert-Equal 'MA_VALIDATE_COORDINATION_CHANGED' $r.Issues[0].Code
        Assert-Equal 'Bloqueio' $r.Issues[0].Severity
    }
    It 'atributo filter em caminho rastreado: nao verificado e status nao executado' {
        foreach ($role in @('coordination', 'codex')) {
            Use-GitMock
            Set-WorkingState @('AGENTS.md', 'dados.bin') @(' M dados.bin') @{ 'dados.bin' = 'lfs' }
            $r = Get-WorkingChanges $role
            Assert-Equal 'NaoVerificado' $r.State $role
            Assert-Equal 'MA_VALIDATE_CHANGES_UNVERIFIED' $r.Issues[0].Code
            Assert-Equal 'dados.bin' $r.Issues[0].Detail
            $expected = 'Aviso'; if ($role -eq 'coordination') { $expected = 'Bloqueio' }
            Assert-Equal $expected $r.Issues[0].Severity $role
            Assert-Equal 0 @($script:Calls | Where-Object { $_ -like 'status*' }).Count 'status executado'
        }
    }
    It 'listagem, atributos ou status ilegiveis ou malformados: leitura inconclusiva' {
        Use-GitMock
        Set-WorkingState @('app.txt'); Set-Response 'ls-files -z' '' 128
        Assert-Equal 'ls-files' (Get-WorkingChanges 'codex').Issues[0].Detail
        Set-WorkingState @('app.txt'); Set-Response 'check-attr -z --stdin filter' 'app.txt' 0
        Assert-Equal 'check-attr' (Get-WorkingChanges 'codex').Issues[0].Detail
        Set-WorkingState @('app.txt'); Set-Response 'status --porcelain=v1 -z --untracked-files=all --no-renames --ignore-submodules=all' '' 128
        Assert-Equal 'status' (Get-WorkingChanges 'codex').Issues[0].Detail
        Set-WorkingState @('app.txt') @('XYapp.txt')
        $r = Get-WorkingChanges 'codex'
        Assert-Equal 'NaoVerificado' $r.State
        Assert-Equal 'MA_ENV_GIT_UNREADABLE' $r.Issues[0].Code
    }

    Write-Output 'Estabilidade e concorrencia'
    It 'resumo do estado: deterministico e sensivel a HEAD, branch, hooks, worktrees e branches locais' {
        $state = { param([string]$Head, [string]$Value) [pscustomobject]@{ Role = 'codex'; Head = $Head; Branch = 'feature/codex'; HooksPath = @([pscustomobject]@{ Scope = 'local'; Origin = 'file:x'; Value = $Value }) } }
        $records = @([pscustomobject]@{ Path = 'C:\ws\demo'; Branch = 'main'; Detached = $false; Bare = $false; Prunable = $false; Locked = $false })
        $refs = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal); $refs['main'] = $I
        $digest = { param($s, $w, $r) InModule { param($a, $b, $c) Get-MaValidateDigest $a $b $c } @($s, $w, $r) }
        $base = & $digest @(& $state $M '.githooks') $records $refs
        Assert-Equal $base (& $digest @(& $state $M '.githooks') $records $refs)
        Assert-True ($base -cne (& $digest @(& $state $I '.githooks') $records $refs)) 'HEAD'
        Assert-True ($base -cne (& $digest @(& $state $M 'outro') $records $refs)) 'core.hooksPath'
        $prunable = @([pscustomobject]@{ Path = 'C:\ws\demo'; Branch = 'main'; Detached = $false; Bare = $false; Prunable = $true; Locked = $false })
        Assert-True ($base -cne (& $digest @(& $state $M '.githooks') $prunable $refs)) 'worktree'
        $more = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal); $more['main'] = $I; $more['terceiro'] = $I
        Assert-True ($base -cne (& $digest @(& $state $M '.githooks') $records $more)) 'branch nova'
        Assert-True ($base -cne (& $digest @(& $state $M '.githooks') $records $null)) 'branches ilegiveis'
    }
    It 'exclusao mutua: consultada sem ser obtida; existente, ausente ou nao consultavel' {
        $root = New-FixtureRoot
        $model = New-Model $root
        Assert-Equal $false (InModule { param($m) Test-MaMutablePhaseActive $m } @(, $model)) 'mutex inexistente'
        $name = InModule { param($w, $c) $chain = Open-MaDirectoryChain $w; try { Get-MaRepositoryLockName (Get-MaWorkspaceLockIdentity $chain $c) } finally { [void](Close-MaPinnedChain $chain) } } @($root, $model.Worktrees.coordination)
        $holder = New-Object System.Threading.Mutex($false, $name)
        try {
            Assert-Equal $true (InModule { param($m) Test-MaMutablePhaseActive $m } @(, $model)) 'mutex existente'
            # A consulta nao obtem o mutex: o detentor continua podendo obte-lo.
            Assert-True ($holder.WaitOne(0)) 'mutex obtido pela consulta'
            $holder.ReleaseMutex()
        } finally { $holder.Dispose() }
        Assert-Equal $false (InModule { param($m) Test-MaMutablePhaseActive $m } @(, $model)) 'mutex liberado'
        $missing = New-Model ([IO.Path]::Combine($root, 'inexistente'))
        Assert-Equal $null (InModule { param($m) Test-MaMutablePhaseActive $m } @(, $missing)) 'diretorio inexistente'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $root -Force).Count 'fixture alterada'
    }

    Write-Output 'Evidencia fornecida'
    It 'AuthorizationReference opcional somente com o switch; com valor, a divergencia continua relatada' {
        $path = Write-EvidenceText ((New-EvidenceData) | ConvertTo-Json -Depth 6)
        $read = { param($a, [bool]$o) InModule { param($p, $m, $x, $y) Read-MaIntegrationEvidence -LiteralPath $p -Configuration $m -AuthorizationReference $x -IntegratedCommit $I -AuthorizationOptional:$y } @($path, (New-Model), $a, $o) }
        $r = & $read '' $true
        Assert-Equal $true $r.Valid (Get-Codes $r)
        Assert-HasIssue (& $read 'outra' $true) 'MA_INTEGRATION_EVIDENCE_MISMATCH' 'completionAuthorization.reference'
        Assert-Equal $true (& $read $Authorization $true).Valid
        # Comportamento anterior (CompleteWorktrees) preservado sem o switch.
        Assert-HasIssue (& $read '' $false) 'MA_INTEGRATION_EVIDENCE_MISMATCH' 'completionAuthorization.reference'
    }
    It 'relacao com a base integrada: commit ausente interrompe sem ancestralidade nem comparacao; formato incompativel recusado' {
        Use-GitMock
        $script:Responses = @{}
        Set-Response 'cat-file --batch-check' ($I + " missing`n")
        Set-Response ('cat-file -e ' + $I) '' 1
        $environments = @{}
        foreach ($role in @('coordination', 'codex', 'claude', 'maintenance')) { $environments[$role] = [pscustomobject]@{ Role = $role; Path = 'C:\ma-unit\ws\' + $role; ObjectFormat = 'sha1'; Inspected = $true; Head = $I; Branch = 'x'; Exists = $true; State = 'Existente' } }
        $relation = { param($integrated) InModule { param($e, $m, $i) Get-MaIntegrationRelation $e $m @([pscustomobject]@{ Path = 'AGENTS.md'; Bytes = [byte[]]@(); Sha256 = ''; GitMode = '100644' }) $i } @($environments, (New-Model), $integrated) }
        $r = & $relation $I
        Assert-Equal 'MA_COMPLETE_COMMIT_UNAVAILABLE' ((@($r.Issues | ForEach-Object { $_.Code })) -join ',')
        Assert-True ($r.Issues[0].Detail.Contains('Missing')) $r.Issues[0].Detail
        Assert-Equal 0 @($script:Calls | Where-Object { $_ -like 'merge-base*' -or $_ -like 'ls-tree*' }).Count 'consultas apos a ausencia'
        Assert-Equal 0 @($r.Comparison).Count
        $environments.coordination.ObjectFormat = 'sha256'
        $r = & $relation $I
        Assert-HasIssue $r 'MA_INTEGRATION_EVIDENCE_MISMATCH' 'I: comprimento incompativel com o formato sha256'
    }

    Write-Output 'Fase, relatorio e ponto de entrada'
    It 'sem configuracao legivel: Bloqueado, Inconclusiva, nenhuma chamada ao Git e relatorio sem modificacao' {
        $counter = $Module.NewBoundScriptBlock({ param($a, $b, $c, $d, $e) $script:UnitCalls++; [pscustomobject]@{ ExitCode = 129; StdOut = ''; StdErr = '' } })
        InModule { param($m) $script:UnitCalls = 0; $script:MaGitInvoker = $m } @(, $counter)
        $root = New-FixtureRoot
        $r = Invoke-MaValidate -ConfigPath ([IO.Path]::Combine($root, 'multiagente.config.json')) -PackageRoot ([IO.Path]::Combine($root, 'pacote')) -IntegratedCommit $I -AuthorizationReference $Authorization
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'Inconclusiva' $r.Conformity
        Assert-Equal 'NaoVerificada' $r.EvidenceResult
        Assert-Equal 'NaoVerificada' $r.RemoteProtection
        Assert-Equal $false $r.Modified
        Assert-Equal 0 (InModule { $script:UnitCalls }) 'Git chamado'
        Assert-True (@($r.Issues | Where-Object { $_.Severity -ne 'Aviso' -and $_.Category -cne 'pre-condicao' }).Count -eq 0) (Get-Codes $r)
        $lines = Format-MaValidateReport $r
        Assert-Equal 'Fase: Validate' $lines[0]
        Assert-Equal 'Resultado: Bloqueado' $lines[1]
        Assert-True ($lines[2].StartsWith('Conformidade local: Inconclusiva (')) $lines[2]
        Assert-Equal 'Nenhuma modificacao foi realizada.' $lines[$lines.Count - 1]
        $text = $lines -join "`n"
        Assert-True (-not $text.Contains($Authorization)) 'referencia reproduzida'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $root -Force).Count 'fixture alterada'
    }
    It 'relatorio: quatro separacoes, categorias, incompletude, alteracoes e comparacao, sem dados do registro' {
        $result = [pscustomobject]@{
            Phase = 'Validate'; Status = 'Bloqueado'; Conformity = 'Divergente'; EvidenceResult = 'Inconsistente'; RemoteProtection = 'NaoVerificada'; WhatIf = $true; Modified = $false
            Package = $null; Configuration = $null; Git = $null; Environments = @(); Files = @()
            Hooks = [pscustomobject]@{ Decision = 'Compativel'; Worktrees = @([pscustomobject]@{ Role = 'codex'; Root = 'C:\ws\demo-codex'; Branch = 'feature/codex'; ExpectedBranch = 'feature/codex'; CommonDir = 'C:\ws\demo\.git'; Values = 'local file:x = .githooks'; EffectiveValue = '.githooks'; Destination = 'C:\ws\demo-codex\.githooks'; ExpectedDestination = 'C:\ws\demo-codex\.githooks'; Files = '.githooks/pre-commit Identico'; State = 'Compativel' }) }
            Incomplete = @([pscustomobject]@{ Role = 'claude'; Item = 'ambiente ausente: C:\ws\demo-claude'; Next = 'CompleteWorktrees' })
            WorkingChanges = @([pscustomobject]@{ Role = 'coordination'; State = 'Alterado'; Paths = @('notas.txt') }, [pscustomobject]@{ Role = 'codex'; State = 'Limpo'; Paths = @() })
            Comparison = @([pscustomobject]@{ Source = 'I'; Commit = $I; Path = 'AGENTS.md'; Result = 'Divergente'; Reason = 'bytes divergentes'; Mode = '100644'; Type = 'blob'; ObjectId = ('c' * 40); Sha256 = ('d' * 64); ExpectedMode = '100644'; ExpectedObjectId = ('e' * 40); ExpectedSha256 = ('f' * 64) })
            Issues = @(
                [pscustomobject]@{ Code = 'MA_VALIDATE_COORDINATION_CHANGED'; Severity = 'Bloqueio'; Role = 'coordination'; Path = 'C:\ws\demo'; Message = 'm1'; Detail = '1 caminho(s): notas.txt'; Category = 'divergencia' },
                [pscustomobject]@{ Code = 'MA_GIT_OBJECT_MISSING'; Severity = 'Bloqueio'; Role = 'codex'; Path = 'AGENTS.md'; Message = 'm2'; Detail = ''; Category = 'leitura inconclusiva' },
                [pscustomobject]@{ Code = 'MA_INTEGRATION_EVIDENCE_MISMATCH'; Severity = 'Bloqueio'; Role = ''; Path = ''; Message = 'm3'; Detail = 'repository'; Category = 'evidencia' },
                [pscustomobject]@{ Code = 'MA_VALIDATE_WORKING_CHANGES'; Severity = 'Aviso'; Role = 'codex'; Path = ''; Message = 'm4'; Detail = ''; Category = 'aviso' }
            )
            Pending = @('p'); Evidence = [pscustomobject]@{ IntegrationReference = 'registro SHA-256 x' }
        }
        $lines = Format-MaValidateReport $result
        $text = $lines -join "`n"
        $order = @('Conformidade local: Divergente', 'WhatIf: sem efeito adicional', 'Hooks por worktree (decisao: Compativel):', 'Instalacao incompleta:', '  - [claude] ambiente ausente: C:\ws\demo-claude -> proximo passo: CompleteWorktrees',
            'Alteracoes de trabalho (fora do conjunto governado):', '  [coordination] Alterado: 1 caminho(s): notas.txt', '  [codex] Limpo', 'Evidencia fornecida: Inconsistente', '  [I] AGENTS.md | Divergente | 100644 blob',
            'Protecao remota: nao verificada', 'Impedimentos:', '  - [divergencia] MA_VALIDATE_COORDINATION_CHANGED', '  - [leitura inconclusiva] MA_GIT_OBJECT_MISSING', '  - [evidencia] MA_INTEGRATION_EVIDENCE_MISMATCH', 'Avisos:', '  - MA_VALIDATE_WORKING_CHANGES', 'Verificacoes pendentes:', 'Nenhuma modificacao foi realizada.')
        $position = -1
        foreach ($expected in $order) {
            $found = $text.IndexOf($expected, [StringComparison]::Ordinal)
            Assert-True ($found -gt $position) ('ausente ou fora de ordem: ' + $expected)
            $position = $found
        }
    }
    It 'ponto de entrada: configuracao invalida, codigo 3 e Validate identificada, com e sem WhatIf, sem modificacao' {
        $root = New-FixtureRoot
        $config = [IO.Path]::Combine($root, 'multiagente.config.json')
        [IO.File]::WriteAllBytes($config, $Utf8.GetBytes('{"schemaVersion":"1.0"}'))
        $host5 = (Get-Process -Id $PID).Path
        $script = [IO.Path]::Combine($PackageSource, 'scripts', 'Install-MultiAgentProject.ps1')
        foreach ($extra in @(@(), @('-WhatIf'))) {
            $ErrorActionPreference = 'Continue'
            $output = & $host5 -NoProfile -NonInteractive -File $script -Config $config -Phase Validate @extra 2>&1
            $code = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            $text = $output | Out-String
            Assert-Equal 3 $code $text
            foreach ($expected in @('Fase: Validate', 'Conformidade local: Inconclusiva', 'Protecao remota: nao verificada', 'Nenhuma modificacao foi realizada.')) { Assert-True ($text.Contains($expected)) ('ausente: ' + $expected) }
            Assert-True ($text.Contains('WhatIf: sem efeito adicional') -eq ($extra.Count -gt 0)) 'WhatIf'
            Assert-True (-not $text.Contains('MA_PHASE_NOT_IMPLEMENTED')) 'fase recusada'
        }
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
