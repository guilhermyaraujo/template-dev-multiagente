#Requires -Version 5.1
<#
Testes de integracao e ponta a ponta da fase CompleteWorktrees com Git real.
Cada caso cria remoto de origem, workspace, pacote, configuracao e registro de
integracao exclusivamente em um diretorio descartavel sob o TEMP do executor,
fora dos worktrees do projeto, e o remove ao final. Nenhum caso aponta para o
projeto atual nem para repositorios reais.

O estado anterior a conclusao e preparado pelo executor de testes, fora do
instalador: clone da coordenacao, manutencao com a governanca gerada e commitada
(M), integracao simulada por commit-tree na coordenacao (I: squash sem
ancestralidade com M, merge comum ou fast-forward), sincronizacao fast-forward da
coordenacao e atualizacao local de refs/remotes/origin/<coordenacao>, como faria o
responsavel depois de um fetch. Nenhum caso faz fetch, push ou acesso a rede; o
remoto configurado e ficticio (ssh://git@example.invalid/...). O fluxo de ponta a
ponta usa a propria PrepareMaintenance pelo ponto de entrada.
Commits existem somente nas fixtures, criados pelo executor de testes com
identidade ficticia por variavel de processo, -c core.hooksPath=<vazio> e
-c commit.gpgsign=false apenas no processo da fixture; nenhuma configuracao
global, de sistema ou do projeto e alterada. Os hooks ativados sao exercitados com
entradas simuladas (commit recusado na coordenacao da fixture e pre-push com stdin
simulado), sem push. Nenhum caso usa WMI/CIM ou breakaway de processos.

Uso: powershell -NoProfile -File tests/integration/CompleteWorktrees.Integration.Tests.ps1
Codigo de saida: 0 quando todos os casos passam; 1 se algum caso falha; 2 se a
suite nao pode ser executada por pre-requisito ausente (nunca contado como aprovado).

Pre-requisitos: Git for Windows >= 2.44 no PATH, sh da instalacao Git, Job Object
do Windows disponivel e nenhum core.hooksPath global ou de sistema. Variaveis Git
que redirecionam repositorio ou configuracao sao removidas apenas deste processo
de teste e restauradas ao final.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PackageSource = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
$Module = Import-Module -Name ([IO.Path]::Combine($PackageSource, 'scripts', 'MultiAgentTemplate.psm1')) -Force -PassThru -DisableNameChecking
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$GitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$GitExe = $null; if ($null -ne $GitCommand) { $GitExe = $GitCommand.Path }
$Url = 'ssh://git@example.invalid/org/demo.git'
$Authorization = 'registro-humano-ficticio#complete-1'
$PrepareAuthorization = 'registro-humano-ficticio#prepare-1'
$PullRequest = 'https://example.invalid/org/demo/pull/7'
$Directories = @('demo', 'demo-codex', 'demo-claude', 'demo-manutencao')
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]

# --- Harness ------------------------------------------------------------------------

function It {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Output ('  [ok]    ' + $Name) }
    catch { $script:Failed.Add($Name + ' :: ' + $_.Exception.Message); Write-Output ('  [FALHA] ' + $Name + ' :: ' + $_.Exception.Message) }
    finally { InModule { $script:MaGitInvoker = $null; $script:MaNativeFaults = @{} } }
}
function Assert-Equal { param($Expected, $Actual, [string]$Message = '') if (-not [object]::Equals($Expected, $Actual)) { throw ('esperado <' + $Expected + '> obtido <' + $Actual + '> ' + $Message) } }
function Assert-True { param([bool]$Condition, [string]$Message = 'condicao falsa') if (-not $Condition) { throw $Message } }
function Get-Codes { param($Result) return ((@($Result.Issues | ForEach-Object { $_.Severity + ':' + $_.Code + '@' + $_.Role + ' ' + $_.Path + ' ' + $_.Detail })) -join ', ') }
function Assert-HasIssue {
    param($Result, [string]$Code, [string]$Role = '')
    if (@($Result.Issues | Where-Object { $_.Code -ceq $Code -and ($Role -eq '' -or $_.Role -eq $Role) }).Count -eq 0) { throw ('ausente: ' + $Code + ' ' + $Role + ' | presentes: ' + (Get-Codes $Result)) }
}
function Get-Performed { param($Result, [string]$Operation) return @($Result.Performed | Where-Object { $_.Operation -eq $Operation }) }
function InModule { param([scriptblock]$Body, [object[]]$Arguments = @()) return (& $Module $Body @Arguments) }

# --- Fixtures -------------------------------------------------------------------------

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $algorithm.Dispose() }
}

function Write-FixtureFile {
    param([string]$Path, [AllowEmptyCollection()][byte[]]$Bytes)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function New-FixturePackage {
    param([string]$Root)
    $package = [IO.Path]::Combine($Root, 'pacote')
    $copy = @('schema/project.schema.json', 'scripts/MultiAgentTemplate.psm1', 'scripts/Install-MultiAgentProject.ps1')
    foreach ($relative in @('AGENTS.md', 'CLAUDE.md', 'README.md', '.gitattributes', '.githooks/pre-commit', '.githooks/pre-push',
            'docs/agentes/coordenacao.md', 'docs/agentes/desenvolvimento.md', 'docs/agentes/manutencao.md', 'docs/agentes/revisao.md')) { $copy += 'templates/' + $relative + '.tmpl' }
    $placeholders = @('AGENTS.md', 'CLAUDE.md', '.gitattributes', '.githooks/pre-commit', '.githooks/pre-push', 'docs/especificacao-v1.md',
        'docs/errata-especificacao-v1.1.md', 'docs/agentes/coordenacao.md', 'docs/agentes/desenvolvimento.md', 'docs/agentes/manutencao.md', 'docs/agentes/revisao.md')
    $all = @()
    foreach ($relative in $copy) { $all += , @($relative, [IO.File]::ReadAllBytes([IO.Path]::Combine($PackageSource, $relative.Replace('/', '\')))) }
    foreach ($relative in $placeholders) { $all += , @($relative, $Utf8.GetBytes("ficticio`n")) }
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($item in ($all | Sort-Object { $_[0] })) {
        Write-FixtureFile ([IO.Path]::Combine($package, $item[0].Replace('/', '\'))) $item[1]
        $mode = '100644'; if ($item[0] -like '.githooks/*') { $mode = '100755' }
        $entries.Add('    { "path": "' + $item[0] + '", "sha256": "' + (Get-Sha256Hex $item[1]) + '", "gitMode": "' + $mode + '" }')
    }
    $manifest = "{`n  `"distributionVersion`": `"0.0.0-integracao`",`n  `"specificationVersion`": `"1.1`",`n  `"compatibleSchemaVersions`": [`"1.0`"],`n  `"integrityAlgorithm`": `"SHA-256`",`n  `"files`": [`n" + ($entries -join ",`n") + "`n  ]`n}`n"
    Write-FixtureFile ([IO.Path]::Combine($package, 'package.manifest.json')) $Utf8.GetBytes($manifest)
    return $package
}

# Estado completo de um diretorio, incluindo .git: entradas, atributos e, para
# arquivos, tamanho, mtime e SHA-256 (mtime de diretorios fora: NTFS tardio).
function Get-Snapshot {
    param([string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return '(ausente)' }
    return ((@(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { $_.FullName + '|dir|' + [int]$_.Attributes }
        else { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks + '|' + [int]$_.Attributes + '|' + (Get-Sha256Hex ([IO.File]::ReadAllBytes($_.FullName))) }
    })) -join "`n")
}

function Assert-SameSnapshot {
    param([string]$Before, [string]$After, [string]$What = 'fixture')
    if ($Before -ceq $After) { return }
    $old = $Before.Split([char]10); $new = $After.Split([char]10)
    $diff = @(@($old | Where-Object { $new -cnotcontains $_ } | ForEach-Object { '- ' + $_ }) + @($new | Where-Object { $old -cnotcontains $_ } | ForEach-Object { '+ ' + $_ }))
    throw ($What + ' alterada: ' + ($diff -join ' || '))
}

# Git somente para preparar fixtures e conferir resultados. Environment acrescenta
# variaveis ao processo da fixture (por exemplo GIT_INDEX_FILE temporario).
function Invoke-FixtureGit {
    param([string]$Directory, [string[]]$Arguments, [switch]$AllowFailure, [hashtable]$Environment = @{}, [AllowNull()][string]$InputText = $null)
    $variables = @{
        GIT_AUTHOR_NAME = 'Fixture'; GIT_AUTHOR_EMAIL = 'fixture@example.invalid'; GIT_AUTHOR_DATE = '2026-01-01T00:00:00Z'
        GIT_COMMITTER_NAME = 'Fixture'; GIT_COMMITTER_EMAIL = 'fixture@example.invalid'; GIT_COMMITTER_DATE = '2026-01-01T00:00:00Z'
        GIT_TERMINAL_PROMPT = '0'
    }
    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    $all = @('-c', ('core.hooksPath=' + $script:NoHooks), '-c', 'commit.gpgsign=false', '-c', 'gc.auto=0', '-c', 'maintenance.auto=false') + $Arguments
    $result = InModule { param($p, $a, $d, $e, $i) Invoke-MaNativeProcess -FilePath $p -Arguments $a -WorkingDirectory $d -Environment $e -InputText $i } @($GitExe, $all, $Directory, $variables, $InputText)
    if ($AllowFailure) { return $result }
    if ($result.ExitCode -ne 0) { throw ('git de fixture falhou (' + ($Arguments -join ' ') + '): ' + $result.StdErr) }
    return ([string]$result.StdOut).Trim()
}

# Git sem o -c da fixture: todas as camadas persistentes, como o usuario as ve.
function Invoke-PlainGit {
    param([string]$Directory, [string[]]$Arguments)
    return (InModule { param($g, $wd, $a) $script:MaGitPath = $g; Invoke-MaGit $wd $a } @($GitExe, $Directory, $Arguments))
}

function ConvertTo-FileUrl { param([string]$Path) return ('file:///' + $Path.Replace('\', '/')) }

function Save-Commit {
    param([string]$Directory, [string]$Message)
    [void](Invoke-FixtureGit $Directory @('add', '-A'))
    foreach ($hook in @('.githooks/pre-commit', '.githooks/pre-push')) {
        if ([IO.File]::Exists([IO.Path]::Combine($Directory, $hook.Replace('/', '\')))) { [void](Invoke-FixtureGit $Directory @('update-index', '--chmod=+x', '--', $hook)) }
    }
    [void](Invoke-FixtureGit $Directory @('commit', '-q', '-m', $Message))
}

# Commit cuja arvore e a de Source com caminhos alterados, sem checkout: indice
# temporario da fixture. Changes: caminho -> @{ Mode; Text } ou $null (remover).
function New-AlteredCommit {
    param($Scenario, [string]$Source, [hashtable]$Changes, [string[]]$Parents)
    $index = [IO.Path]::Combine($Scenario.Root, 'indice-' + [Guid]::NewGuid().ToString('N'))
    $environment = @{ GIT_INDEX_FILE = $index }
    try {
        [void](Invoke-FixtureGit $Scenario.Coordination @('read-tree', $Source) -Environment $environment)
        foreach ($path in $Changes.Keys) {
            $change = $Changes[$path]
            if ($null -eq $change) { [void](Invoke-FixtureGit $Scenario.Coordination @('update-index', '--force-remove', '--', $path) -Environment $environment); continue }
            $blob = Invoke-FixtureGit $Scenario.Coordination @('hash-object', '-w', '--no-filters', '--stdin') -InputText $change.Text
            [void](Invoke-FixtureGit $Scenario.Coordination @('update-index', '--add', '--cacheinfo', ($change.Mode + ',' + $blob + ',' + $path)) -Environment $environment)
        }
        $tree = Invoke-FixtureGit $Scenario.Coordination @('write-tree') -Environment $environment
    } finally { if ([IO.File]::Exists($index)) { [IO.File]::Delete($index) } }
    $arguments = @('commit-tree', $tree)
    foreach ($parent in $Parents) { $arguments += @('-p', $parent) }
    return (Invoke-FixtureGit $Scenario.Coordination ($arguments + @('-m', 'integracao alterada')))
}

function Get-RenderedText { param($Scenario, [string]$Path) return $Utf8.GetString(@($Scenario.Rendered | Where-Object { $_.Path -ceq $Path })[0].Bytes) }

# Estado anterior a conclusao, preparado fora do instalador. Method: squash
# (I com a arvore de M e pai na base, sem ancestralidade com M), merge (I com pais
# base e M) ou ff (I = M). NoSync deixa a coordenacao na base. OnlyCoordination
# para logo apos o clone da coordenacao (manutencao, M e I a cargo do caso).
function New-CompleteScenario {
    param([string]$WorkspaceName = 'ws', [ValidateSet('squash', 'merge', 'ff')][string]$Method = 'squash', [switch]$NoSync, [switch]$OnlyCoordination)
    $root = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ma-comp-int-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $script:FixtureRoots.Add($root)
    $script:NoHooks = [IO.Path]::Combine($root, 'sem-hooks')
    [void][IO.Directory]::CreateDirectory($script:NoHooks)
    $workspace = [IO.Path]::Combine($root, $WorkspaceName)
    [void][IO.Directory]::CreateDirectory($workspace)
    $package = New-FixturePackage $root
    $config = [IO.Path]::Combine($root, 'multiagente.config.json')
    Write-FixtureFile $config $Utf8.GetBytes('{"schemaVersion":"1.0","project":{"name":"Projeto Demo","slug":"demo"},"repository":{"url":"' + $Url + '"},"workspace":{"parentDirectory":' + ($workspace | ConvertTo-Json) + '}}')
    $model = Read-MaConfiguration -LiteralPath $config -SchemaPath ([IO.Path]::Combine($package, 'schema', 'project.schema.json'))
    $rendered = Get-MaRenderedFiles -PackageRoot $package -Configuration $model -DistributionVersion '0.0.0-integracao'
    $seed = [IO.Path]::Combine($root, 'semente')
    [void](Invoke-FixtureGit $root @('init', '-q', '-b', 'main', $seed))
    Write-FixtureFile ([IO.Path]::Combine($seed, 'app.txt')) $Utf8.GetBytes("aplicacao`n")
    Save-Commit $seed 'inicial'
    $origin = [IO.Path]::Combine($root, 'origem.git')
    [void](Invoke-FixtureGit $root @('clone', '-q', '--bare', (ConvertTo-FileUrl $seed), $origin))
    $base = Invoke-FixtureGit $origin @('rev-parse', 'refs/heads/main')
    $coordination = $model.Worktrees.coordination
    $maintenance = $model.Worktrees.maintenance
    [void](Invoke-FixtureGit $root @('clone', '-q', (ConvertTo-FileUrl $origin), $coordination))
    [void](Invoke-FixtureGit $coordination @('remote', 'set-url', 'origin', $Url))
    if ($OnlyCoordination) {
        return [pscustomobject]@{
            Root = $root; Workspace = $workspace; Package = $package; Config = $config; Model = $model; Rendered = $rendered
            Origin = $origin; Base = $base; M = $null; I = $null; Method = $Method
            Coordination = $coordination; Maintenance = $maintenance; Codex = $model.Worktrees.codex; Claude = $model.Worktrees.claude
            Evidence = [IO.Path]::Combine($root, 'integracao.json')
        }
    }
    # Manutencao preparada e commit humano da governanca (M).
    [void](Invoke-FixtureGit $coordination @('worktree', 'add', '-q', '-b', 'chore/manutencao', $maintenance, $base))
    foreach ($file in $rendered) { Write-FixtureFile ([IO.Path]::Combine($maintenance, $file.Path.Replace('/', '\'))) $file.Bytes }
    Save-Commit $maintenance 'governanca'
    $reviewed = Invoke-FixtureGit $maintenance @('rev-parse', 'HEAD')
    $treeOfM = $reviewed + '^{tree}'
    switch ($Method) {
        'squash' { $integrated = Invoke-FixtureGit $coordination @('commit-tree', $treeOfM, '-p', $base, '-m', 'squash do PR 7') }
        'merge' { $integrated = Invoke-FixtureGit $coordination @('commit-tree', $treeOfM, '-p', $base, '-p', $reviewed, '-m', 'merge do PR 7') }
        default { $integrated = $reviewed }
    }
    $scenario = [pscustomobject]@{
        Root = $root; Workspace = $workspace; Package = $package; Config = $config; Model = $model; Rendered = $rendered
        Origin = $origin; Base = $base; M = $reviewed; I = $integrated; Method = $Method
        Coordination = $coordination; Maintenance = $maintenance; Codex = $model.Worktrees.codex; Claude = $model.Worktrees.claude
        Evidence = [IO.Path]::Combine($root, 'integracao.json')
    }
    if (-not $NoSync) { Sync-Coordination $scenario $integrated }
    Write-Evidence $scenario (New-EvidenceData $scenario)
    return $scenario
}

# Sincronizacao humana simulada: fast-forward da coordenacao e referencia de
# acompanhamento remoto local (sem fetch).
function Sync-Coordination {
    param($Scenario, [string]$Commit)
    [void](Invoke-FixtureGit $Scenario.Coordination @('merge', '-q', '--ff-only', $Commit))
    [void](Invoke-FixtureGit $Scenario.Coordination @('update-ref', 'refs/remotes/origin/main', $Commit))
}

function New-EvidenceData {
    param($Scenario)
    $method = $Scenario.Method; if ($method -ceq 'ff') { $method = 'rebase' }
    return [ordered]@{
        evidenceVersion = '1.0'
        repository = $Url
        pullRequest = $PullRequest
        sourceBranch = 'chore/manutencao'
        targetBranch = 'main'
        reviewedHead = $Scenario.M
        review = [ordered]@{ reviewer = 'Revisor Codex Ficticio'; author = 'Autor Claude Ficticio'; reference = 'revisao-ficticia#7'; reviewedHead = $Scenario.M }
        mergeAuthorization = [ordered]@{ authorizedBy = 'Responsavel Humano Ficticio'; reference = 'autorizacao-merge-ficticia#7'; pullRequest = $PullRequest; reviewedHead = $Scenario.M }
        integration = [ordered]@{ result = 'merged'; method = $method; resultingCommit = $Scenario.I; executedBy = 'Responsavel Humano Ficticio'; proofSource = 'registro-servidor-ficticio#7' }
        completionAuthorization = [ordered]@{ authorizedBy = 'Responsavel Humano Ficticio'; reference = $Authorization; integratedCommit = $Scenario.I; environments = $Directories; operations = @('create-worktrees', 'configure-hooks') }
    }
}

function Write-Evidence {
    param($Scenario, $Data, [string]$Path = '')
    if (-not $Path) { $Path = $Scenario.Evidence }
    Write-FixtureFile $Path $Utf8.GetBytes(($Data | ConvertTo-Json -Depth 6))
}

function Invoke-Complete {
    param($Scenario, [string]$AuthorizationReference = $Authorization, [string]$IntegratedCommit = '', [string]$IntegrationReference = '', [switch]$WhatIf)
    if (-not $PSBoundParameters.ContainsKey('IntegratedCommit')) { $IntegratedCommit = $Scenario.I }
    if (-not $PSBoundParameters.ContainsKey('IntegrationReference')) { $IntegrationReference = $Scenario.Evidence }
    return (Invoke-MaCompleteWorktrees -ConfigPath $Scenario.Config -PackageRoot $Scenario.Package -AuthorizationReference $AuthorizationReference -IntegratedCommit $IntegratedCommit -IntegrationReference $IntegrationReference -WhatIfRequested:$WhatIf)
}

# Worktree de agente criado pela fixture (fora do instalador), com checkout.
function New-FixtureAgent {
    param($Scenario, [string]$Role, [string]$Commit = '')
    if (-not $Commit) { $Commit = $Scenario.I }
    $path = $Scenario.Model.Worktrees[$Role]
    [void](Invoke-FixtureGit $Scenario.Coordination @('worktree', 'add', '-q', '-b', $Scenario.Model.Branches[$Role], $path, $Commit))
}

function Get-HooksPathValues {
    param([string]$Directory)
    $result = Invoke-PlainGit $Directory @('config', '-z', '--show-scope', '--get-all', 'core.hooksPath')
    if ($result.ExitCode -eq 1) { return '' }
    return ([string]$result.StdOut).Replace([string][char]0, '|')
}

# Conclusao conforme: Codex e Claude nas branches, onze destinos identicos em cada
# um e core.hooksPath=.githooks local unico, visto igual nos quatro contextos.
function Assert-Completed {
    param($Scenario, [string]$CodexCommit = '', [string]$ClaudeCommit = '')
    foreach ($pair in @(@('codex', $CodexCommit), @('claude', $ClaudeCommit))) {
        $path = $Scenario.Model.Worktrees[$pair[0]]
        Assert-Equal $Scenario.Model.Branches[$pair[0]] (Invoke-FixtureGit $path @('symbolic-ref', '--short', 'HEAD')) ($pair[0] + ' branch')
        $expected = $pair[1]; if (-not $expected) { $expected = $Scenario.I }
        Assert-Equal $expected (Invoke-FixtureGit $path @('rev-parse', 'HEAD')) ($pair[0] + ' HEAD')
        foreach ($file in $Scenario.Rendered) {
            $full = [IO.Path]::Combine($path, $file.Path.Replace('/', '\'))
            Assert-True ([IO.File]::Exists($full)) ($pair[0] + ' ausente: ' + $file.Path)
            Assert-Equal $file.Sha256 (Get-Sha256Hex ([IO.File]::ReadAllBytes($full))) ($pair[0] + ' ' + $file.Path)
        }
    }
    foreach ($role in @('coordination', 'codex', 'claude', 'maintenance')) {
        Assert-Equal 'local|.githooks|' (Get-HooksPathValues $Scenario.Model.Worktrees[$role]) ('core.hooksPath em ' + $role)
    }
}

# Proibicoes: nenhum push, fetch, sincronizacao, reposicionamento, commit ou indice.
function Assert-NoPublication {
    param($Scenario, [string]$OriginBefore, [string]$CoordinationHead = '')
    if (-not $CoordinationHead) { $CoordinationHead = $Scenario.I }
    Assert-SameSnapshot $OriginBefore (Get-Snapshot $Scenario.Origin) 'remoto de origem'
    Assert-Equal $CoordinationHead (Invoke-FixtureGit $Scenario.Coordination @('rev-parse', 'refs/heads/main')) 'coordenacao movida'
    Assert-Equal $Scenario.M (Invoke-FixtureGit $Scenario.Coordination @('rev-parse', 'refs/heads/chore/manutencao')) 'manutencao reposicionada'
    foreach ($path in @($Scenario.Coordination, $Scenario.Maintenance, $Scenario.Codex, $Scenario.Claude)) {
        if (-not [IO.File]::Exists([IO.Path]::Combine($path, '.git')) -and -not [IO.Directory]::Exists([IO.Path]::Combine($path, '.git'))) { continue }
        Assert-Equal '' (Invoke-FixtureGit $path @('diff-index', '--cached', '--name-only', 'HEAD')) ('indice preparado em ' + $path)
    }
}

function Get-OutsideSnapshot {
    param($Scenario)
    $parts = foreach ($entry in @(Get-ChildItem -LiteralPath $Scenario.Root -Force | Sort-Object Name)) {
        if ($entry.FullName -ieq $Scenario.Workspace) { continue }
        if ($entry.PSIsContainer) { $entry.Name + "`n" + (Get-Snapshot $entry.FullName) } else { $entry.Name + '|' + (Get-Sha256Hex ([IO.File]::ReadAllBytes($entry.FullName))) }
    }
    return (@($parts) -join "`n")
}

function Get-LockName {
    param($Scenario)
    return (InModule { param($w, $c) $chain = Open-MaDirectoryChain $w; try { Get-MaRepositoryLockName (Get-MaWorkspaceLockIdentity $chain $c) } finally { [void](Close-MaPinnedChain $chain) } } @($Scenario.Workspace, $Scenario.Coordination))
}

# Falha simulada num ponto nomeado do modulo (ver $script:MaNativeFaults).
function Set-Fault { param([string]$Point, [scriptblock]$Action) InModule { param($p, $a) $script:MaNativeFaults[$p] = $a } @($Point, $Action) }

function Invoke-EntryPoint {
    param($Scenario, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File ([IO.Path]::Combine($Scenario.Package, 'scripts', 'Install-MultiAgentProject.ps1')) -Config $Scenario.Config @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    return [pscustomobject]@{ Code = $code; Text = ($output | Out-String) }
}

# --- Casos ------------------------------------------------------------------------------

Write-Output ('PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
InModule { $script:MaGitInvoker = $null; $script:MaNativeFaults = @{} }

$overrideNames = InModule { $script:MaGitOverrideVariables }
$SavedGitEnvironment = [ordered]@{}
foreach ($variable in @(Get-ChildItem Env:)) {
    if ($variable.Name -in $overrideNames -or $variable.Name -match '\AGIT_CONFIG_(?:KEY|VALUE)_[0-9]+\z' -or $variable.Name -in @('GIT_TEMPLATE_DIR', 'GIT_SSH', 'GIT_SSH_COMMAND')) {
        $SavedGitEnvironment[$variable.Name] = $variable.Value
        [Environment]::SetEnvironmentVariable($variable.Name, $null)
    }
}
if ($SavedGitEnvironment.Count -gt 0) { Write-Output ('Ambiente: removidas deste processo de teste: ' + (@($SavedGitEnvironment.Keys) -join ', ')) }

$missing = New-Object System.Collections.Generic.List[string]
$Shell = $null
if (-not $GitExe) { $missing.Add('Git nao localizado no PATH') }
else {
    $versionText = [string](& $GitExe --version 2>$null)
    Write-Output ('Pre-requisito Git: ' + $GitExe + ' ' + $versionText)
    $versionMatch = [regex]::Match($versionText, '([0-9]+)\.([0-9]+)\.([0-9]+)')
    if (-not $versionMatch.Success -or (New-Object Version ([int]$versionMatch.Groups[1].Value), ([int]$versionMatch.Groups[2].Value), ([int]$versionMatch.Groups[3].Value)) -lt (New-Object Version 2, 44, 0)) { $missing.Add('Git >= 2.44') }
    $Shell = InModule { param($g) Find-MaShell $g } @($GitExe)
    if (-not $Shell) { $missing.Add('sh da instalacao Git') }
    try {
        [void](InModule { param($p) Invoke-MaNativeProcess -FilePath $p -Arguments @('--version') -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMilliseconds 30000 } @($GitExe))
        Write-Output 'Pre-requisito Job: contencao em Job Object disponivel'
    } catch { $missing.Add('Job Object (' + $_.Exception.Message + ')') }
    $globalHooks = Invoke-PlainGit ([IO.Path]::GetTempPath()) @('config', '--get-all', 'core.hooksPath')
    if ($globalHooks.ExitCode -eq 0) { $missing.Add('core.hooksPath global ou de sistema ausente (a ativacao seria bloqueada por desenho)') }
}
if ($missing.Count -gt 0) {
    foreach ($item in $missing) { Write-Output ('  [PRE-REQ] ausente: ' + $item) }
    Write-Output 'Resultado: 0 aprovados, 0 falhas; suite nao executada por pre-requisito ausente'
    foreach ($name in $SavedGitEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$SavedGitEnvironment[$name]) }
    exit 2
}

try {
    Write-Output 'Conclusao apos integracao comprovada'
    It 'squash: M e I distintos sem ancestralidade, Codex e Claude criados em I e hooks ativados (AC13, AC25, AC27)' {
        $s = New-CompleteScenario
        Assert-True ($s.M -cne $s.I) 'M igual a I'
        Assert-Equal 1 (Invoke-FixtureGit $s.Coordination @('merge-base', '--is-ancestor', $s.M, $s.I) -AllowFailure).ExitCode 'M ancestral de I'
        Assert-Equal 1 (Invoke-FixtureGit $s.Coordination @('merge-base', '--is-ancestor', $s.I, $s.M) -AllowFailure).ExitCode 'I ancestral de M'
        $originBefore = Get-Snapshot $s.Origin
        $outsideBefore = Get-OutsideSnapshot $s
        $r = Invoke-Complete $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal $false $r.Partial
        Assert-Equal 'Criar worktree,Checkout,Criar worktree,Checkout,Configurar hooks' ((@($r.Performed | ForEach-Object { $_.Operation })) -join ',')
        Assert-Equal 'codex,codex,claude,claude,' ((@($r.Performed | ForEach-Object { $_.Role })) -join ',')
        Assert-Equal 33 @($r.Comparison | Where-Object { $_.Result -eq 'Conforme' }).Count 'comparacao M, I e C'
        Assert-Equal 0 @($r.Comparison | Where-Object { $_.Result -ne 'Conforme' }).Count 'divergencias'
        Assert-Equal 'M,I,C' ((@($r.Comparison | ForEach-Object { $_.Source } | Select-Object -Unique)) -join ',')
        Assert-Equal 44 @($r.Files | Where-Object { $_.Classification -eq 'Identico' }).Count 'quatro ambientes identicos'
        Assert-Equal 'Compativel' $r.Hooks.Decision
        Assert-Equal 4 @($r.Hooks.Worktrees).Count
        foreach ($row in $r.Hooks.Worktrees) { Assert-True ($row.Destination -ieq [IO.Path]::Combine($row.Root, '.githooks')) ('destino ' + $row.Role + ': ' + $row.Destination) }
        Assert-Completed $s
        Assert-NoPublication $s $originBefore
        Assert-SameSnapshot $outsideBefore (Get-OutsideSnapshot $s) 'fixture fora do workspace'
        # Relatorio: comparacao por caminho e hooks por worktree, sem dados do registro.
        $text = (Format-MaCompleteReport $r) -join "`n"
        Assert-True ($text.Contains('Hooks por worktree (decisao: Compativel)')) 'relatorio de hooks'
        Assert-True ($text.Contains('[I] .githooks/pre-push | Conforme | 100755 blob')) 'relatorio de comparacao'
        foreach ($secret in @($Authorization, 'Revisor Codex Ficticio', 'Responsavel Humano Ficticio', $PullRequest, 'registro-servidor-ficticio')) { Assert-True (-not $text.Contains($secret)) ('relatorio reproduz ' + $secret) }
        # Repeticao apos a conclusao: nenhuma alteracao (AC11).
        $before = Get-Snapshot $s.Workspace
        $again = Invoke-Complete $s
        Assert-Equal 'Sucesso' $again.Status (Get-Codes $again)
        Assert-Equal 0 @($again.Performed).Count
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace na repeticao'
        $plan = Invoke-MaPlan -ConfigPath $s.Config -PackageRoot $s.Package
        Assert-Equal 'Sucesso' $plan.Status ((@($plan.Issues | ForEach-Object { $_.Code })) -join ',')
    }
    It 'merge comum (I com M como pai) e fast-forward (I = M) sao aceitos' {
        foreach ($method in @('merge', 'ff')) {
            $s = New-CompleteScenario -Method $method
            $r = Invoke-Complete $s
            Assert-Equal 'Sucesso' $r.Status ($method + ': ' + (Get-Codes $r))
            Assert-Completed $s
        }
    }
    It 'caminho com espacos, acentos, apostrofo, $, &, colchetes e ponto e virgula chega literal (AC18)' {
        $name = 'ws a' + [char]0xE7 + 'a ''x'' $y & [z]; w'
        $s = New-CompleteScenario -WorkspaceName $name
        $r = Invoke-Complete $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Completed $s
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $s.Root -Force -Directory | Where-Object { $_.Name -like 'ws*' }).Count 'caminho expandido ou duplicado'
    }
    It 'WhatIf: Incompleto, criacoes e ativacao simuladas, nenhuma modificacao (AC07)' {
        $s = New-CompleteScenario
        $before = Get-Snapshot $s.Root
        $r = Invoke-Complete $s -WhatIf
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-Equal $false $r.Modified
        Assert-Equal 'Criar worktree,Checkout,Criar worktree,Checkout,Configurar hooks' ((@($r.Simulated | ForEach-Object { $_.Operation })) -join ',')
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }

    Write-Output 'Evidencia de integracao e autorizacao'
    It 'sem IntegrationReference, IntegratedCommit ou AuthorizationReference: bloqueio sem operacao' {
        $s = New-CompleteScenario
        $before = Get-Snapshot $s.Root
        Assert-HasIssue (Invoke-Complete $s -IntegrationReference '') 'MA_INTEGRATION_REFERENCE_REQUIRED'
        Assert-HasIssue (Invoke-Complete $s -IntegratedCommit '') 'MA_INTEGRATEDCOMMIT_REQUIRED'
        Assert-HasIssue (Invoke-Complete $s -IntegratedCommit 'abc123') 'MA_COMMIT_FORMAT_INVALID'
        Assert-HasIssue (Invoke-Complete $s -AuthorizationReference '') 'MA_AUTHORIZATION_REFERENCE_REQUIRED'
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'registro com booleano de aprovacao, revisor igual ao autor ou vinculos divergentes: bloqueio sem operacao' {
        $s = New-CompleteScenario
        $before = Get-Snapshot $s.Workspace
        $cases = @(
            @('MA_INTEGRATION_REFERENCE_INVALID', { param($d) $d['approved'] = $true }),
            @('MA_INTEGRATION_REVIEW_NOT_INDEPENDENT', { param($d) $d.review.reviewer = 'autor claude ficticio' }),
            @('MA_INTEGRATION_EVIDENCE_MISMATCH', { param($d) $d.integration.resultingCommit = $d.reviewedHead }),
            @('MA_INTEGRATION_EVIDENCE_MISMATCH', { param($d) $d.completionAuthorization.reference = 'outra-autorizacao' }),
            @('MA_INTEGRATION_EVIDENCE_MISMATCH', { param($d) $d.mergeAuthorization.reviewedHead = $d.integration.resultingCommit })
        )
        foreach ($case in $cases) {
            $data = New-EvidenceData $s
            & $case[1] $data
            Write-Evidence $s $data
            $r = Invoke-Complete $s
            Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
            Assert-HasIssue $r $case[0]
            Assert-Equal $false $r.Modified
        }
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
    }
    It 'registro dentro de um dos worktrees e recusado' {
        $s = New-CompleteScenario
        $inside = [IO.Path]::Combine($s.Coordination, 'integracao.json')
        Write-Evidence $s (New-EvidenceData $s) $inside
        $r = Invoke-Complete $s -IntegrationReference $inside
        Assert-HasIssue $r 'MA_INTEGRATION_REFERENCE_INSIDE_WORKTREE'
        Assert-Equal $false $r.Modified
        Assert-True (-not [IO.Directory]::Exists($s.Codex)) 'codex criado'
    }
    It 'autorizacao sem configure-hooks: worktrees criados, ativacao pendente e resultado Incompleto' {
        $s = New-CompleteScenario
        $data = New-EvidenceData $s; $data.completionAuthorization.operations = @('create-worktrees')
        Write-Evidence $s $data
        $r = Invoke-Complete $s
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_COMPLETE_HOOKS_NOT_AUTHORIZED'
        Assert-Equal 2 @(Get-Performed $r 'Criar worktree').Count
        Assert-Equal 0 @(Get-Performed $r 'Configurar hooks').Count
        Assert-Equal '' (Get-HooksPathValues $s.Coordination) 'hooks ativados sem autorizacao'
        # Autorizacao de configure-hooks sem os quatro ambientes tambem nao basta.
        $data.completionAuthorization.operations = @('configure-hooks'); $data.completionAuthorization.environments = @('demo-codex', 'demo-claude')
        Write-Evidence $s $data
        $again = Invoke-Complete $s
        Assert-Equal 'Incompleto' $again.Status (Get-Codes $again)
        Assert-Equal 0 @($again.Performed).Count
    }
    It 'autorizacao sem o ambiente Claude: nada e criado, nem Codex' {
        $s = New-CompleteScenario
        $data = New-EvidenceData $s; $data.completionAuthorization.environments = @('demo', 'demo-codex', 'demo-manutencao')
        Write-Evidence $s $data
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_COMPLETE_AUTHORIZATION_SCOPE' 'claude'
        Assert-Equal $false $r.Modified
        Assert-True (-not [IO.Directory]::Exists($s.Codex)) 'codex criado'
    }

    Write-Output 'Pre-condicoes: coordenacao, manutencao e commits'
    It 'coordenacao nao sincronizada: bloqueio, sem sincronizar nem criar (AC13)' {
        $s = New-CompleteScenario -NoSync
        $originBefore = Get-Snapshot $s.Origin
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_COMPLETE_COORDINATION_NOT_SYNCED' 'coordination'
        Assert-Equal $false $r.Modified
        Assert-NoPublication $s $originBefore $s.Base
        Assert-True (-not [IO.Directory]::Exists($s.Codex)) 'codex criado'
    }
    It 'manutencao com HEAD diferente do revisado: bloqueio sem reposicionar' {
        $s = New-CompleteScenario
        Write-FixtureFile ([IO.Path]::Combine($s.Maintenance, 'notas.txt')) $Utf8.GetBytes("nota`n")
        Save-Commit $s.Maintenance 'posterior'
        $head = Invoke-FixtureGit $s.Maintenance @('rev-parse', 'HEAD')
        $r = Invoke-Complete $s
        Assert-HasIssue $r 'MA_COMPLETE_MAINTENANCE_NOT_REVIEWED' 'maintenance'
        Assert-Equal $false $r.Modified
        Assert-Equal $head (Invoke-FixtureGit $s.Maintenance @('rev-parse', 'HEAD')) 'manutencao reposicionada'
    }
    It 'commit integrado ausente localmente: bloqueio sem busca remota' {
        $s = New-CompleteScenario
        $absent = 'abcdef0123' * 4
        $data = New-EvidenceData $s; $data.integration.resultingCommit = $absent; $data.completionAuthorization.integratedCommit = $absent
        Write-Evidence $s $data
        $originBefore = Get-Snapshot $s.Origin
        $r = Invoke-Complete $s -IntegratedCommit $absent
        Assert-HasIssue $r 'MA_COMPLETE_COMMIT_UNAVAILABLE' 'coordination'
        Assert-Equal $false $r.Modified
        Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto'
        Assert-Equal 1 (Invoke-FixtureGit $s.Coordination @('cat-file', '-e', $absent) -AllowFailure).ExitCode 'objeto obtido'
    }

    Write-Output 'Comparacao apos squash: conteudo falso (AC28)'
    It 'I com documento alterado, hook 100644, hook como link, arquivo extra ou omitido: rejeitados' {
        $s = New-CompleteScenario
        $revisao = (Get-RenderedText $s 'docs/agentes/revisao.md') + "alterado`n"
        $preCommit = Get-RenderedText $s '.githooks/pre-commit'
        $cases = @(
            @('docs/agentes/revisao.md', 'bytes divergentes', @{ 'docs/agentes/revisao.md' = @{ Mode = '100644'; Text = $revisao } }),
            @('.githooks/pre-commit', 'modo 100644', @{ '.githooks/pre-commit' = @{ Mode = '100644'; Text = $preCommit } }),
            @('.githooks/pre-push', 'link simbolico', @{ '.githooks/pre-push' = @{ Mode = '120000'; Text = 'pre-commit' } }),
            @('.githooks/post-merge', 'entrada fora do conjunto governado', @{ '.githooks/post-merge' = @{ Mode = '100755'; Text = "#!/bin/sh`nexit 0`n" } }),
            @('docs/agentes/manutencao.md', 'ausente', @{ 'docs/agentes/manutencao.md' = $null })
        )
        foreach ($case in $cases) {
            $altered = New-AlteredCommit $s $s.I $case[2] @($s.Base)
            $data = New-EvidenceData $s; $data.integration.resultingCommit = $altered; $data.completionAuthorization.integratedCommit = $altered
            Write-Evidence $s $data
            $r = Invoke-Complete $s -IntegratedCommit $altered
            Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
            $entry = @($r.Comparison | Where-Object { $_.Source -ceq 'I' -and $_.Path -ceq $case[0] })
            Assert-Equal 1 $entry.Count ('entrada de ' + $case[0])
            Assert-True ($entry[0].Result -ne 'Conforme' -and $entry[0].Reason.Contains($case[1])) ($case[0] + ': ' + $entry[0].Result + ' ' + $entry[0].Reason)
            # O manifesto do consumidor e o mesmo de M: nao basta (AC28).
            Assert-Equal 'Conforme' @($r.Comparison | Where-Object { $_.Source -ceq 'I' -and $_.Path -ceq '.multiagente/manifest.json' })[0].Result
            Assert-Equal $false $r.Modified
        }
        Assert-True (-not [IO.Directory]::Exists($s.Codex)) 'codex criado'
    }
    It 'checkout da manutencao divergente apesar de assume-unchanged e status limpo (AC29)' {
        $s = New-CompleteScenario
        [void](Invoke-FixtureGit $s.Maintenance @('update-index', '--assume-unchanged', '--', 'AGENTS.md'))
        Write-FixtureFile ([IO.Path]::Combine($s.Maintenance, 'AGENTS.md')) $Utf8.GetBytes("alterado`n")
        Assert-Equal '' (Invoke-FixtureGit $s.Maintenance @('status', '--porcelain')) 'status deveria parecer limpo'
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_FILE_CONFLICT' 'maintenance'
        Assert-Equal $false $r.Modified
    }

    Write-Output 'Branches e worktrees existentes, retomada e falhas parciais'
    It 'branches de agentes existentes sao reutilizadas sem reposicionamento' {
        $s = New-CompleteScenario
        [void](Invoke-FixtureGit $s.Coordination @('branch', 'feature/codex', $s.I))
        $ahead = Invoke-FixtureGit $s.Coordination @('commit-tree', ($s.I + '^{tree}'), '-p', $s.I, '-m', 'trabalho do claude')
        [void](Invoke-FixtureGit $s.Coordination @('branch', 'feature/claude', $ahead))
        $r = Invoke-Complete $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 2 @(Get-Performed $r 'Criar worktree' | Where-Object { $_.Detail -like 'branch existente*' }).Count
        Assert-Completed $s '' $ahead
    }
    It 'branch existente com conteudo governado divergente: nada criado, nem o outro agente' {
        $s = New-CompleteScenario
        [void](Invoke-FixtureGit $s.Coordination @('branch', 'feature/claude', $s.Base))
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_COMPLETE_GOVERNED_DIVERGENT' 'claude'
        Assert-Equal $false $r.Modified
        Assert-True (-not [IO.Directory]::Exists($s.Codex)) 'codex criado'
        Assert-Equal $s.Base (Invoke-FixtureGit $s.Coordination @('rev-parse', 'refs/heads/feature/claude')) 'branch reposicionada'
    }
    It 'Codex ja existente: somente Claude criado' {
        $s = New-CompleteScenario
        New-FixtureAgent $s 'codex'
        $r = Invoke-Complete $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 'claude' ((@(Get-Performed $r 'Criar worktree' | ForEach-Object { $_.Role })) -join ',')
        Assert-Completed $s
    }
    It 'Codex sem checkout deixado por execucao interrompida: retomada conclui' {
        $s = New-CompleteScenario
        [void](Invoke-FixtureGit $s.Coordination @('worktree', 'add', '-q', '--no-checkout', '-b', 'feature/codex', $s.Codex, $s.I))
        $r = Invoke-Complete $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 'codex,claude' ((@(Get-Performed $r 'Checkout' | ForEach-Object { $_.Role })) -join ',')
        Assert-Equal 'claude' ((@(Get-Performed $r 'Criar worktree' | ForEach-Object { $_.Role })) -join ',')
        Assert-Completed $s
    }
    It 'falha depois de criar o Codex: preservado, parcial, hooks nao ativados e retomada conclui (AC12)' {
        $s = New-CompleteScenario
        Set-Fault 'CompleteBeforeWorktree' { param($c) if ($c.Role -ceq 'claude') { throw 'falha simulada' } }
        $r = Invoke-Complete $s
        Assert-Equal 'Falha' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_COMPLETE_UNEXPECTED_FAILURE'
        Assert-Equal $true $r.Partial
        Assert-Equal 'codex' ((@(Get-Performed $r 'Criar worktree' | ForEach-Object { $_.Role })) -join ',')
        Assert-Equal '' (Get-HooksPathValues $s.Coordination) 'hooks ativados na falha'
        Assert-True ([IO.File]::Exists([IO.Path]::Combine($s.Codex, 'AGENTS.md'))) 'codex removido'
        InModule { $script:MaNativeFaults = @{} }
        $again = Invoke-Complete $s
        Assert-Equal 'Sucesso' $again.Status (Get-Codes $again)
        Assert-Equal 'claude' ((@(Get-Performed $again 'Criar worktree' | ForEach-Object { $_.Role })) -join ',')
        Assert-Completed $s
    }
    It 'branch criada por terceiro entre a inspecao e o worktree add: operacao nao executada' {
        $s = New-CompleteScenario
        $script:Scenario = $s
        Set-Fault 'CompleteBeforeWorktree' { param($c) [void](Invoke-FixtureGit $script:Scenario.Coordination @('branch', 'terceiro', $script:Scenario.I)) }
        $r = Invoke-Complete $s
        Assert-HasIssue $r 'MA_PREPARE_STATE_CHANGED' 'codex'
        Assert-Equal $false $r.Modified
        Assert-True (-not [IO.Directory]::Exists($s.Codex)) 'destino criado e nao removido'
    }

    Write-Output 'Ancestralidade da base integrada nas branches de agente'
    It 'branch e worktree existentes a frente de I: reutilizados sem reposicionamento' {
        $s = New-CompleteScenario
        $codexAhead = New-AlteredCommit $s $s.I @{ 'src/codex.txt' = @{ Mode = '100644'; Text = "trabalho do codex`n" } } @($s.I)
        $claudeAhead = New-AlteredCommit $s $s.I @{ 'src/claude.txt' = @{ Mode = '100644'; Text = "trabalho do claude`n" } } @($s.I)
        New-FixtureAgent $s 'codex' $codexAhead
        [void](Invoke-FixtureGit $s.Coordination @('branch', 'feature/claude', $claudeAhead))
        $r = Invoke-Complete $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 0 @($r.Issues | Where-Object { $_.Code -ceq 'MA_COMPLETE_BRANCH_NOT_FROM_INTEGRATION' }).Count (Get-Codes $r)
        Assert-Equal 'claude' ((@(Get-Performed $r 'Criar worktree' | ForEach-Object { $_.Role })) -join ',')
        Assert-Completed $s $codexAhead $claudeAhead
    }
    It 'branch sem I na ancestralidade e conteudo governado igual: bloqueada sem alterar branches, worktrees ou arquivos' {
        $s = New-CompleteScenario
        # Mesma arvore de I: copia com o mesmo pai e commit orfao, nenhum contendo I.
        $copy = Invoke-FixtureGit $s.Coordination @('commit-tree', ($s.I + '^{tree}'), '-p', $s.Base, '-m', 'copia sem I')
        $orphan = Invoke-FixtureGit $s.Coordination @('commit-tree', ($s.I + '^{tree}'), '-m', 'orfao sem I')
        foreach ($start in @($copy, $orphan)) {
            [void](Invoke-FixtureGit $s.Coordination @('branch', '-f', 'feature/claude', $start))
            $originBefore = Get-Snapshot $s.Origin
            $before = Get-Snapshot $s.Workspace
            $r = Invoke-Complete $s
            Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
            $issue = @($r.Issues | Where-Object { $_.Code -ceq 'MA_COMPLETE_BRANCH_NOT_FROM_INTEGRATION' })
            Assert-Equal 1 $issue.Count (Get-Codes $r)
            Assert-Equal 'Bloqueio' $issue[0].Severity
            Assert-Equal 'claude' $issue[0].Role
            Assert-Equal $s.Claude $issue[0].Path
            Assert-True ($issue[0].Detail.Contains('branch feature/claude; HEAD ' + $start + '; I ' + $s.I)) $issue[0].Detail
            # O conteudo governado e igual e nao substitui a ancestralidade.
            Assert-Equal 11 @($r.Comparison | Where-Object { $_.Source -ceq 'claude (branch existente)' -and $_.Result -eq 'Conforme' }).Count
            Assert-Equal 0 @($r.Issues | Where-Object { $_.Code -ceq 'MA_COMPLETE_GOVERNED_DIVERGENT' }).Count (Get-Codes $r)
            Assert-Equal $false $r.Modified
            Assert-True (-not [IO.Directory]::Exists($s.Codex)) 'codex criado'
            Assert-True (-not [IO.Directory]::Exists($s.Claude)) 'claude criado'
            Assert-Equal $start (Invoke-FixtureGit $s.Coordination @('rev-parse', 'refs/heads/feature/claude')) 'branch reposicionada'
            Assert-Equal '' (Get-HooksPathValues $s.Coordination) 'hooks ativados'
            Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
            Assert-NoPublication $s $originBefore
        }
    }
    It 'worktree existente com branch sem I, com ou sem checkout: bloqueado sem alteracao' {
        $s = New-CompleteScenario
        $copy = Invoke-FixtureGit $s.Coordination @('commit-tree', ($s.I + '^{tree}'), '-p', $s.Base, '-m', 'copia sem I')
        New-FixtureAgent $s 'codex' $copy
        [void](Invoke-FixtureGit $s.Coordination @('worktree', 'add', '-q', '--no-checkout', '-b', 'feature/claude', $s.Claude, $copy))
        $originBefore = Get-Snapshot $s.Origin
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'claude,codex' ((@($r.Issues | Where-Object { $_.Code -ceq 'MA_COMPLETE_BRANCH_NOT_FROM_INTEGRATION' } | ForEach-Object { $_.Role } | Sort-Object)) -join ',') (Get-Codes $r)
        Assert-Equal $false $r.Modified
        Assert-Equal 0 @(Get-Performed $r 'Checkout').Count 'checkout da retomada executado'
        Assert-Equal '.git' ((@(Get-ChildItem -LiteralPath $s.Claude -Force | ForEach-Object { $_.Name })) -join ',') 'claude com checkout'
        Assert-Equal '' (Get-HooksPathValues $s.Coordination) 'hooks ativados'
        # O snapshot inclui refs, indices e registros de worktree; o Claude sem
        # checkout nao tem indice, entao o remoto e conferido a parte.
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
        Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto de origem'
    }
    It 'retomada depois de criacao parcial em branch a frente de I: checkout concluido' {
        $s = New-CompleteScenario
        $ahead = New-AlteredCommit $s $s.I @{ 'src/codex.txt' = @{ Mode = '100644'; Text = "trabalho do codex`n" } } @($s.I)
        [void](Invoke-FixtureGit $s.Coordination @('worktree', 'add', '-q', '--no-checkout', '-b', 'feature/codex', $s.Codex, $ahead))
        $r = Invoke-Complete $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 'codex,claude' ((@(Get-Performed $r 'Checkout' | ForEach-Object { $_.Role })) -join ',')
        Assert-Equal 'claude' ((@(Get-Performed $r 'Criar worktree' | ForEach-Object { $_.Role })) -join ',')
        Assert-Completed $s $ahead
        Assert-True ([IO.File]::Exists([IO.Path]::Combine($s.Codex, 'src', 'codex.txt'))) 'trabalho do codex ausente'
    }
    It 'branch de agente reposicionada por terceiro antes da ativacao: hooks nao ativados, worktrees preservados' {
        $s = New-CompleteScenario
        $script:Scenario = $s
        $script:Copy = Invoke-FixtureGit $s.Coordination @('commit-tree', ($s.I + '^{tree}'), '-p', $s.Base, '-m', 'copia sem I')
        Set-Fault 'CompleteBeforeHooks' { param($c) [void](Invoke-FixtureGit $script:Scenario.Coordination @('update-ref', 'refs/heads/feature/claude', $script:Copy)) }
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_COMPLETE_BRANCH_NOT_FROM_INTEGRATION' 'claude'
        Assert-Equal $true $r.Partial
        Assert-Equal 2 @(Get-Performed $r 'Criar worktree').Count
        Assert-Equal 0 @(Get-Performed $r 'Configurar hooks').Count
        Assert-Equal '' (Get-HooksPathValues $s.Coordination) 'hooks ativados'
        Assert-Equal $script:Copy (Invoke-FixtureGit $s.Coordination @('rev-parse', 'refs/heads/feature/claude')) 'branch reposicionada pelo instalador'
    }

    Write-Output 'Nomes exatos dos arquivos governados'
    It 'worktree de agente existente com hook em outra caixa: bloqueado, hooks nao ativados e nada alterado' {
        $s = New-CompleteScenario
        $preCommit = Get-RenderedText $s '.githooks/pre-commit'
        # Literais de hashtable nao distinguem caixa: mapa ordinal para as duas grafias.
        $changes = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
        $changes['.githooks/pre-commit'] = $null
        $changes['.githooks/Pre-Commit'] = @{ Mode = '100755'; Text = $preCommit }
        $wrong = New-AlteredCommit $s $s.I $changes @($s.I)
        New-FixtureAgent $s 'codex' $wrong
        Assert-Equal 'Pre-Commit' ((@(Get-ChildItem -LiteralPath ([IO.Path]::Combine($s.Codex, '.githooks')) -Force | Where-Object { $_.Name -ieq 'pre-commit' } | ForEach-Object { $_.Name })) -join ',') 'fixture'
        $originBefore = Get-Snapshot $s.Origin
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        $file = @($r.Files | Where-Object { $_.Role -eq 'codex' -and $_.Path -ceq '.githooks/pre-commit' })[0]
        Assert-Equal 'Conflitante' $file.Classification $file.Reason
        Assert-True ($file.Reason.Contains('grafia divergente por caixa (.githooks/Pre-Commit)')) $file.Reason
        Assert-True (@($r.Issues | Where-Object { $_.Code -ceq 'MA_FILE_UNEXPECTED_ENTRY' -and $_.Role -eq 'codex' -and $_.Path -ceq '.githooks/Pre-Commit' }).Count -eq 1) (Get-Codes $r)
        Assert-Equal $false $r.Modified
        Assert-True (-not [IO.Directory]::Exists($s.Claude)) 'claude criado'
        Assert-Equal '' (Get-HooksPathValues $s.Coordination) 'hooks ativados'
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
        Assert-NoPublication $s $originBefore
    }
    It 'entrada extra so por caixa no indice de um agente: detectada e hooks nao ativados' {
        $s = New-CompleteScenario
        $data = New-EvidenceData $s; $data.completionAuthorization.operations = @('create-worktrees')
        Write-Evidence $s $data
        $first = Invoke-Complete $s
        Assert-Equal 'Incompleto' $first.Status (Get-Codes $first)
        $blob = Invoke-FixtureGit $s.Claude @('rev-parse', ($s.I + ':.githooks/pre-push'))
        [void](Invoke-FixtureGit $s.Claude @('update-index', '--add', '--cacheinfo', ('100755,' + $blob + ',.githooks/Pre-Push')))
        Assert-True ((Invoke-FixtureGit $s.Claude @('ls-files', '-s', '--', '.githooks')).Contains('.githooks/Pre-Push')) 'fixture'
        Write-Evidence $s (New-EvidenceData $s)
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-True (@($r.Issues | Where-Object { $_.Code -ceq 'MA_FILE_UNEXPECTED_ENTRY' -and $_.Role -eq 'claude' -and $_.Path -ceq '.githooks/Pre-Push' }).Count -eq 1) (Get-Codes $r)
        Assert-Equal 44 @($r.Files | Where-Object { $_.Classification -eq 'Identico' }).Count 'nomes exatos aceitos'
        Assert-Equal $false $r.Modified
        Assert-Equal '' (Get-HooksPathValues $s.Coordination) 'hooks ativados'
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
    }
    It 'outra fase mutavel com a exclusao mutua: bloqueio sem operacao' {
        $s = New-CompleteScenario
        $name = Get-LockName $s
        $holder = [powershell]::Create()
        $ready = New-Object System.Threading.ManualResetEvent($false)
        $release = New-Object System.Threading.ManualResetEvent($false)
        [void]$holder.AddScript({ param($n, $r1, $r2) $m = New-Object System.Threading.Mutex($false, $n); [void]$m.WaitOne(); [void]$r1.Set(); [void]$r2.WaitOne(30000); $m.ReleaseMutex(); $m.Dispose() }).AddArgument($name).AddArgument($ready).AddArgument($release)
        $handle = $holder.BeginInvoke()
        try {
            Assert-True ($ready.WaitOne(10000)) 'mutex nao obtido pelo detentor'
            $before = Get-Snapshot $s.Root
            $r = Invoke-Complete $s
            Assert-HasIssue $r 'MA_PREPARE_LOCKED'
            Assert-Equal $false $r.Modified
            Assert-SameSnapshot $before (Get-Snapshot $s.Root)
        } finally { [void]$release.Set(); [void]$holder.EndInvoke($handle); $holder.Dispose() }
    }

    Write-Output 'Hooks efetivos e alcance (AC16, AC17, AC25, AC26)'
    It 'quinto worktree registrado ou registro indisponivel: nada criado nem configurado' {
        $s = New-CompleteScenario
        $fifth = [IO.Path]::Combine($s.Root, 'quinto')
        [void](Invoke-FixtureGit $s.Coordination @('worktree', 'add', '-q', '-b', 'extra', $fifth, $s.I))
        $r = Invoke-Complete $s
        Assert-HasIssue $r 'MA_WORKTREE_UNEXPECTED'
        Assert-Equal $false $r.Modified
        # Diretorio removido fora do Git: registro indisponivel (prunable).
        [IO.Directory]::Delete($fifth, $true)
        $again = Invoke-Complete $s
        Assert-HasIssue $again 'MA_WORKTREE_PRUNABLE'
        Assert-Equal $false $again.Modified
        Assert-True (-not [IO.Directory]::Exists($s.Codex)) 'codex criado'
        Assert-Equal '' (Get-HooksPathValues $s.Coordination)
    }
    It 'hook ativo no diretorio padrao: criacao recusada sem executa-lo' {
        $s = New-CompleteScenario
        $sentinel = [IO.Path]::Combine($s.Root, 'sentinela-hook.txt')
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.git', 'hooks', 'reference-transaction')) $Utf8.GetBytes("#!/bin/sh`necho executado > '" + $sentinel.Replace('\', '/') + "'`n")
        $r = Invoke-Complete $s
        Assert-HasIssue $r 'MA_PREPARE_HOOKS_WOULD_RUN' 'codex'
        Assert-Equal $false $r.Modified
        Assert-True (-not [IO.File]::Exists($sentinel)) 'hook executado'
    }
    It 'hook ativo no diretorio padrao seria ocultado: ativacao bloqueada sem alteracao' {
        $s = New-CompleteScenario
        New-FixtureAgent $s 'codex'; New-FixtureAgent $s 'claude'
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.git', 'hooks', 'pre-commit')) $Utf8.GetBytes("#!/bin/sh`nexit 0`n")
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_HOOKS_DEFAULT_WOULD_BE_HIDDEN'
        Assert-Equal $false $r.Modified
        Assert-Equal '' (Get-HooksPathValues $s.Coordination)
    }
    It 'arquivos de amostra no diretorio padrao nao impedem a ativacao' {
        $s = New-CompleteScenario
        $samples = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($s.Coordination, '.git', 'hooks')) -Filter '*.sample')
        if ($samples.Count -eq 0) { Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.git', 'hooks', 'pre-commit.sample')) $Utf8.GetBytes("#!/bin/sh`nexit 1`n") }
        $r = Invoke-Complete $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Completed $s
    }
    It 'valor vazio, caminho distinto ou ocorrencias multiplas: conflito sem substituicao (AC16)' {
        $s = New-CompleteScenario
        New-FixtureAgent $s 'codex'; New-FixtureAgent $s 'claude'
        # Com valor vazio o proprio Git nao resolve o diretorio de hooks (git-path
        # hooks falha): a inspecao ja interrompe como leitura inconclusiva.
        $cases = @(@(@(''), 'MA_ENV_GIT_UNREADABLE'), @(@('outro'), 'MA_HOOKS_CONFIG_CONFLICT'), @(@('.githooks', '.githooks'), 'MA_HOOKS_CONFIG_CONFLICT'))
        foreach ($case in $cases) {
            $values = $case[0]
            [void](Invoke-FixtureGit $s.Coordination @('config', '--local', '--unset-all', 'core.hooksPath') -AllowFailure)
            foreach ($value in $values) { [void](Invoke-FixtureGit $s.Coordination @('config', '--local', '--add', 'core.hooksPath', $value)) }
            $expected = (@($values | ForEach-Object { 'local|' + $_ + '|' }) -join '')
            $r = Invoke-Complete $s
            Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
            Assert-HasIssue $r $case[1]
            Assert-Equal $false $r.Modified
            Assert-Equal $expected (Get-HooksPathValues $s.Coordination) 'configuracao alterada'
        }
    }
    It 'configuracao ja compativel: worktrees criados e nenhuma substituicao' {
        $s = New-CompleteScenario
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'core.hooksPath', '.githooks'))
        $r = Invoke-Complete $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 2 @(Get-Performed $r 'Criar worktree').Count
        Assert-Equal 0 @(Get-Performed $r 'Configurar hooks').Count
        Assert-Completed $s
    }
    It 'include condicional por branch descoberto depois da criacao: worktrees preservados e ativacao bloqueada (AC12, AC26)' {
        $s = New-CompleteScenario
        $include = [IO.Path]::Combine($s.Root, 'incluido.gitconfig')
        Write-FixtureFile $include $Utf8.GetBytes("[core]`n`thooksPath = outro`n")
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'includeIf.onbranch:feature/claude.path', $include.Replace('\', '/')))
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal $true $r.Partial
        Assert-Equal 'codex,claude' ((@(Get-Performed $r 'Criar worktree' | ForEach-Object { $_.Role })) -join ',')
        Assert-True ([IO.Directory]::Exists($s.Claude)) 'claude removido'
        Assert-Equal 0 @(Get-Performed $r 'Configurar hooks').Count
        Assert-Equal '' (Get-HooksPathValues $s.Coordination) 'hooks ativados'
        Assert-True ((Get-HooksPathValues $s.Claude).Contains('|outro|')) 'include nao visto no claude'
    }
    It '.githooks com arquivo extra num agente: ativacao bloqueada' {
        $s = New-CompleteScenario
        New-FixtureAgent $s 'codex'; New-FixtureAgent $s 'claude'
        Write-FixtureFile ([IO.Path]::Combine($s.Codex, '.githooks', 'post-merge')) $Utf8.GetBytes("#!/bin/sh`nexit 0`n")
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_FILE_UNEXPECTED_ENTRY' 'codex'
        Assert-Equal '' (Get-HooksPathValues $s.Coordination)
    }
    It 'override de processo (GIT_CONFIG_PARAMETERS) bloqueia sem remove-lo' {
        $s = New-CompleteScenario
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_PARAMETERS', "'core.hookspath'='temporario'")
        try {
            $r = Invoke-Complete $s
            Assert-HasIssue $r 'MA_GIT_ENV_OVERRIDE'
            Assert-Equal $false $r.Modified
            Assert-Equal "'core.hookspath'='temporario'" ([Environment]::GetEnvironmentVariable('GIT_CONFIG_PARAMETERS')) 'override removido'
        } finally { [Environment]::SetEnvironmentVariable('GIT_CONFIG_PARAMETERS', $null) }
    }
    It 'core.hooksPath definido por terceiro antes da escrita: nada substituido, worktrees preservados' {
        $s = New-CompleteScenario
        $script:Scenario = $s
        Set-Fault 'CompleteBeforeHooks' { param($c) [void](Invoke-FixtureGit $script:Scenario.Coordination @('config', '--local', 'core.hooksPath', 'terceiro')) }
        $r = Invoke-Complete $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal $true $r.Partial
        Assert-Equal 0 @(Get-Performed $r 'Configurar hooks').Count
        Assert-Equal 'local|terceiro|' (Get-HooksPathValues $s.Coordination) 'valor do terceiro substituido'
    }
    It 'hooks ativados bloqueiam commit na coordenacao e push para ela (entradas simuladas, AC14)' {
        $s = New-CompleteScenario
        Assert-Equal 'Sucesso' (Invoke-Complete $s).Status
        $identity = @{ GIT_AUTHOR_NAME = 'Fixture'; GIT_AUTHOR_EMAIL = 'fixture@example.invalid'; GIT_COMMITTER_NAME = 'Fixture'; GIT_COMMITTER_EMAIL = 'fixture@example.invalid' }
        $commit = InModule { param($p, $d, $e) Invoke-MaNativeProcess -FilePath $p -Arguments @('-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-q', '-m', 'direto') -WorkingDirectory $d -Environment $e } @($GitExe, $s.Coordination, $identity)
        Assert-True ($commit.ExitCode -ne 0) 'commit na coordenacao aceito'
        Assert-True (([string]$commit.StdOut + [string]$commit.StdErr).Contains('BLOQUEADO')) 'mensagem do hook'
        Assert-Equal $s.I (Invoke-FixtureGit $s.Coordination @('rev-parse', 'HEAD')) 'commit criado'
        $prePush = [IO.Path]::Combine($s.Codex, '.githooks', 'pre-push').Replace('\', '/')
        $zero = '0' * 40
        foreach ($case in @(@('refs/heads/main', 1), @('refs/heads/feature/codex', 0))) {
            $push = InModule { param($sh, $hook, $d, $i) Invoke-MaNativeProcess -FilePath $sh -Arguments @($hook, 'origin', 'ssh://example.invalid/demo.git') -WorkingDirectory $d -InputText $i } @($Shell, $prePush, $s.Codex, ('refs/heads/feature/codex ' + $s.I + ' ' + $case[0] + ' ' + $zero + "`n"))
            Assert-Equal $case[1] $push.ExitCode ('pre-push para ' + $case[0])
        }
    }

    Write-Output 'Ponta a ponta pelo ponto de entrada'
    It 'fluxo completo: PrepareMaintenance, commit humano, squash, sincronizacao, CompleteWorktrees e Plan' {
        # A propria PrepareMaintenance prepara a manutencao a partir da base.
        $s = New-CompleteScenario -OnlyCoordination
        $prepare = Invoke-EntryPoint $s @('-Phase', 'PrepareMaintenance', '-AuthorizationReference', $PrepareAuthorization, '-BaseCommit', $s.Base)
        Assert-Equal 0 $prepare.Code $prepare.Text
        Save-Commit $s.Maintenance 'governanca'
        $s.M = Invoke-FixtureGit $s.Maintenance @('rev-parse', 'HEAD')
        $s.I = Invoke-FixtureGit $s.Coordination @('commit-tree', ($s.M + '^{tree}'), '-p', $s.Base, '-m', 'squash do PR 7')
        Sync-Coordination $s $s.I
        Write-Evidence $s (New-EvidenceData $s)
        # Registro informado por caminho relativo ao diretorio atual (o processo filho
        # herda o local do PowerShell).
        Push-Location -LiteralPath $s.Root
        try { $run = Invoke-EntryPoint $s @('-Phase', 'CompleteWorktrees', '-AuthorizationReference', $Authorization, '-IntegratedCommit', $s.I, '-IntegrationReference', 'integracao.json') }
        finally { Pop-Location }
        Assert-Equal 0 $run.Code $run.Text
        Assert-True ($run.Text.Contains('Resultado: Sucesso')) $run.Text
        Assert-True ($run.Text.Contains('Modificacoes realizadas: 5 operacao(oes)')) $run.Text
        foreach ($secret in @($Authorization, 'Responsavel Humano Ficticio')) { Assert-True (-not $run.Text.Contains($secret)) ('relatorio reproduz ' + $secret) }
        Assert-Completed $s
        $plan = Invoke-EntryPoint $s @()
        Assert-Equal 0 $plan.Code $plan.Text
        $before = Get-Snapshot $s.Workspace
        $again = Invoke-EntryPoint $s @('-Phase', 'CompleteWorktrees', '-AuthorizationReference', $Authorization, '-IntegratedCommit', $s.I, '-IntegrationReference', $s.Evidence)
        Assert-Equal 0 $again.Code $again.Text
        Assert-True ($again.Text.Contains('Nenhuma modificacao foi realizada.')) $again.Text
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace na repeticao'
    }
    It 'ponto de entrada: -WhatIf codigo 2 e registro ausente codigo 3, sem modificacao' {
        $s = New-CompleteScenario
        $before = Get-Snapshot $s.Root
        $whatIf = Invoke-EntryPoint $s @('-Phase', 'CompleteWorktrees', '-AuthorizationReference', $Authorization, '-IntegratedCommit', $s.I, '-IntegrationReference', $s.Evidence, '-WhatIf')
        Assert-Equal 2 $whatIf.Code $whatIf.Text
        Assert-True ($whatIf.Text.Contains('Nenhuma modificacao foi realizada.')) $whatIf.Text
        $blocked = Invoke-EntryPoint $s @('-Phase', 'CompleteWorktrees', '-AuthorizationReference', $Authorization, '-IntegratedCommit', $s.I)
        Assert-Equal 3 $blocked.Code $blocked.Text
        Assert-True ($blocked.Text.Contains('MA_INTEGRATION_REFERENCE_REQUIRED')) $blocked.Text
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
} finally {
    InModule { $script:MaGitInvoker = $null; $script:MaNativeFaults = @{} }
    foreach ($name in $SavedGitEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$SavedGitEnvironment[$name]) }
    foreach ($root in $script:FixtureRoots) {
        if ([IO.Directory]::Exists($root)) {
            Get-ChildItem -LiteralPath $root -Recurse -Force -File | ForEach-Object { $_.Attributes = 'Normal' }
            [IO.Directory]::Delete($root, $true)
        }
    }
}

Write-Output ''
Write-Output ('Resultado: ' + $script:Passed + ' aprovados, ' + $script:Failed.Count + ' falhas')
foreach ($failure in $script:Failed) { Write-Output ('  - ' + $failure) }
if ($script:Failed.Count -gt 0) { exit 1 }
exit 0
