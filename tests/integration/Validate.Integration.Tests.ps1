#Requires -Version 5.1
<#
Testes de integracao e ponta a ponta da fase Validate com Git real. Cada caso
cria remoto de origem, workspace, pacote, configuracao e registro de integracao
exclusivamente em um diretorio descartavel sob o TEMP do executor, fora dos
worktrees do projeto, e o remove ao final. Nenhum caso aponta para o projeto atual
nem para repositorios reais.

Os estados inspecionados sao preparados pelo executor de testes, fora do
instalador: clone da coordenacao, manutencao com a governanca gerada (preparada
ou commitada como M), integracao simulada por commit-tree (I: squash sem
ancestralidade com M), sincronizacao fast-forward da coordenacao e da referencia
local refs/remotes/origin/<coordenacao>, worktrees de agentes e core.hooksPath
local. Um caso conclui pela propria CompleteWorktrees antes de validar. As
divergencias sao introduzidas pelo executor nas fixtures; Validate so le. Nenhum
caso faz fetch, push ou acesso a rede; o remoto configurado e ficticio
(ssh://git@example.invalid/...). Commits existem somente nas fixtures, criados com
identidade ficticia por variavel de processo, -c core.hooksPath=<vazio> e
-c commit.gpgsign=false apenas no processo da fixture; nenhuma configuracao global,
de sistema ou do projeto e alterada. Hooks, filtros e fsmonitor configurados nas
fixtures sao sentinelas: provam que Validate nao os executa. Nenhum caso usa
WMI/CIM ou breakaway de processos.

Uso: powershell -NoProfile -File tests/integration/Validate.Integration.Tests.ps1
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
$PullRequest = 'https://example.invalid/org/demo/pull/7'
$Directories = @('demo', 'demo-codex', 'demo-claude', 'demo-manutencao')
$Roles = @('coordination', 'codex', 'claude', 'maintenance')
$HookNames = @('pre-commit', 'pre-push', 'post-checkout', 'post-merge', 'post-commit', 'reference-transaction', 'post-index-change', 'pre-auto-gc', 'post-rewrite', 'commit-msg', 'prepare-commit-msg')
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]

# --- Harness ------------------------------------------------------------------------

function It {
    param([string]$Name, [scriptblock]$Body)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { & $Body; $script:Passed++; Write-Output ('  [ok]    ' + $Name + ' (' + [int]$watch.Elapsed.TotalSeconds + ' s)') }
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
function Assert-NoIssue {
    param($Result, [string]$Code)
    if (@($Result.Issues | Where-Object { $_.Code -ceq $Code }).Count -gt 0) { throw ('presente: ' + $Code + ' | ' + (Get-Codes $Result)) }
}
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

# Git somente para preparar fixtures e conferir resultados.
function Invoke-FixtureGit {
    param([string]$Directory, [string[]]$Arguments, [switch]$AllowFailure, [hashtable]$Environment = @{}, [AllowNull()][string]$InputText = $null)
    $variables = @{
        GIT_AUTHOR_NAME = 'Fixture'; GIT_AUTHOR_EMAIL = 'fixture@example.invalid'; GIT_AUTHOR_DATE = '2026-01-01T00:00:00Z'
        GIT_COMMITTER_NAME = 'Fixture'; GIT_COMMITTER_EMAIL = 'fixture@example.invalid'; GIT_COMMITTER_DATE = '2026-01-01T00:00:00Z'
        GIT_TERMINAL_PROMPT = '0'
    }
    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    $all = @('-c', ('core.hooksPath=' + $script:NoHooks), '-c', 'commit.gpgsign=false', '-c', 'gc.auto=0', '-c', 'maintenance.auto=false', '-c', 'core.fsmonitor=false') + $Arguments
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

function New-EvidenceData {
    param($Scenario)
    return [ordered]@{
        evidenceVersion = '1.0'
        repository = $Url
        pullRequest = $PullRequest
        sourceBranch = 'chore/manutencao'
        targetBranch = 'main'
        reviewedHead = $Scenario.M
        review = [ordered]@{ reviewer = 'Revisor Codex Ficticio'; author = 'Autor Claude Ficticio'; reference = 'revisao-ficticia#7'; reviewedHead = $Scenario.M }
        mergeAuthorization = [ordered]@{ authorizedBy = 'Responsavel Humano Ficticio'; reference = 'autorizacao-merge-ficticia#7'; pullRequest = $PullRequest; reviewedHead = $Scenario.M }
        integration = [ordered]@{ result = 'merged'; method = 'squash'; resultingCommit = $Scenario.I; executedBy = 'Responsavel Humano Ficticio'; proofSource = 'registro-servidor-ficticio#7' }
        completionAuthorization = [ordered]@{ authorizedBy = 'Responsavel Humano Ficticio'; reference = $Authorization; integratedCommit = $Scenario.I; environments = $Directories; operations = @('create-worktrees', 'configure-hooks') }
    }
}

function Write-Evidence {
    param($Scenario, $Data, [string]$Path = '')
    if (-not $Path) { $Path = $Scenario.Evidence }
    Write-FixtureFile $Path $Utf8.GetBytes(($Data | ConvertTo-Json -Depth 6))
}

# Etapas do estado preparado fora do instalador, na ordem do fluxo aprovado.
function Add-PreparedMaintenance {
    param($Scenario)
    [void](Invoke-FixtureGit $Scenario.Coordination @('worktree', 'add', '-q', '-b', 'chore/manutencao', $Scenario.Maintenance, $Scenario.Base))
    foreach ($file in $Scenario.Rendered) { Write-FixtureFile ([IO.Path]::Combine($Scenario.Maintenance, $file.Path.Replace('/', '\'))) $file.Bytes }
}

# Commit humano da governanca (M), squash (I sem ancestralidade com M),
# sincronizacao da coordenacao (salvo NoSync) e registro de integracao.
function Add-Integration {
    param($Scenario, [switch]$NoSync)
    Save-Commit $Scenario.Maintenance 'governanca'
    $Scenario.M = Invoke-FixtureGit $Scenario.Maintenance @('rev-parse', 'HEAD')
    $Scenario.I = Invoke-FixtureGit $Scenario.Coordination @('commit-tree', ($Scenario.M + '^{tree}'), '-p', $Scenario.Base, '-m', 'squash do PR 7')
    if (-not $NoSync) {
        [void](Invoke-FixtureGit $Scenario.Coordination @('merge', '-q', '--ff-only', $Scenario.I))
        [void](Invoke-FixtureGit $Scenario.Coordination @('update-ref', 'refs/remotes/origin/main', $Scenario.I))
    }
    Write-Evidence $Scenario (New-EvidenceData $Scenario)
}

function Add-FixtureAgent {
    param($Scenario, [string]$Role, [string]$Commit = '')
    if (-not $Commit) { $Commit = $Scenario.I }
    [void](Invoke-FixtureGit $Scenario.Coordination @('worktree', 'add', '-q', '-b', $Scenario.Model.Branches[$Role], $Scenario.Model.Worktrees[$Role], $Commit))
}

function Enable-Hooks { param($Scenario) [void](Invoke-FixtureGit $Scenario.Coordination @('config', '--local', 'core.hooksPath', '.githooks')) }

# Stage: Vazio (workspace sem ambientes), Coordenacao, Preparado, Integrado,
# SemHooks (agentes criados) ou Completo (core.hooksPath local ativo).
function New-ValidateScenario {
    param([string]$WorkspaceName = 'ws', [ValidateSet('Vazio', 'Coordenacao', 'Preparado', 'Integrado', 'SemHooks', 'Completo')][string]$Stage = 'Completo', [switch]$NoSync)
    $root = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ma-val-int-' + [Guid]::NewGuid().ToString('N'))
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
    $scenario = [pscustomobject]@{
        Root = $root; Workspace = $workspace; Package = $package; Config = $config; Model = $model; Rendered = $rendered
        Origin = $null; Base = $null; M = $null; I = $null
        Coordination = $model.Worktrees.coordination; Maintenance = $model.Worktrees.maintenance; Codex = $model.Worktrees.codex; Claude = $model.Worktrees.claude
        Evidence = [IO.Path]::Combine($root, 'integracao.json')
    }
    if ($Stage -ceq 'Vazio') { return $scenario }
    $seed = [IO.Path]::Combine($root, 'semente')
    [void](Invoke-FixtureGit $root @('init', '-q', '-b', 'main', $seed))
    Write-FixtureFile ([IO.Path]::Combine($seed, 'app.txt')) $Utf8.GetBytes("aplicacao`n")
    Save-Commit $seed 'inicial'
    $scenario.Origin = [IO.Path]::Combine($root, 'origem.git')
    [void](Invoke-FixtureGit $root @('clone', '-q', '--bare', (ConvertTo-FileUrl $seed), $scenario.Origin))
    $scenario.Base = Invoke-FixtureGit $scenario.Origin @('rev-parse', 'refs/heads/main')
    [void](Invoke-FixtureGit $root @('clone', '-q', (ConvertTo-FileUrl $scenario.Origin), $scenario.Coordination))
    [void](Invoke-FixtureGit $scenario.Coordination @('remote', 'set-url', 'origin', $Url))
    if ($Stage -ceq 'Coordenacao') { return $scenario }
    Add-PreparedMaintenance $scenario
    if ($Stage -ceq 'Preparado') { return $scenario }
    Add-Integration $scenario -NoSync:$NoSync
    if ($Stage -ceq 'Integrado') { return $scenario }
    Add-FixtureAgent $scenario 'codex'; Add-FixtureAgent $scenario 'claude'
    if ($Stage -ceq 'SemHooks') { return $scenario }
    Enable-Hooks $scenario
    return $scenario
}

function Invoke-Validate {
    param($Scenario, [switch]$WithEvidence, [string]$AuthorizationReference = '', [string]$IntegratedCommit = '', [string]$IntegrationReference = '')
    if ($WithEvidence) {
        if (-not $PSBoundParameters.ContainsKey('IntegratedCommit')) { $IntegratedCommit = $Scenario.I }
        if (-not $PSBoundParameters.ContainsKey('IntegrationReference')) { $IntegrationReference = $Scenario.Evidence }
    }
    return (Invoke-MaValidate -ConfigPath $Scenario.Config -PackageRoot $Scenario.Package -AuthorizationReference $AuthorizationReference -IntegratedCommit $IntegratedCommit -IntegrationReference $IntegrationReference)
}

# Validacao conferida contra o estado anterior: nada no root da fixture muda.
function Invoke-ReadOnlyValidate {
    param($Scenario, [hashtable]$Options = @{})
    $before = Get-Snapshot $Scenario.Root
    $result = Invoke-Validate $Scenario @Options
    Assert-SameSnapshot $before (Get-Snapshot $Scenario.Root) 'fixture apos Validate'
    return $result
}

function Get-HooksPathValues {
    param([string]$Directory)
    $result = Invoke-PlainGit $Directory @('config', '-z', '--show-scope', '--get-all', 'core.hooksPath')
    if ($result.ExitCode -eq 1) { return '' }
    return ([string]$result.StdOut).Replace([string][char]0, '|')
}

function Get-Incomplete { param($Result) return ((@($Result.Incomplete | ForEach-Object { $_.Role + ': ' + $_.Item + ' -> ' + $_.Next })) -join ' || ') }

function Get-LockName {
    param($Scenario)
    return (InModule { param($w, $c) $chain = Open-MaDirectoryChain $w; try { Get-MaRepositoryLockName (Get-MaWorkspaceLockIdentity $chain $c) } finally { [void](Close-MaPinnedChain $chain) } } @($Scenario.Workspace, $Scenario.Coordination))
}

function Set-Fault { param([string]$Point, [scriptblock]$Action) InModule { param($p, $a) $script:MaNativeFaults[$p] = $a } @($Point, $Action) }

function Invoke-EntryPoint {
    param($Scenario, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File ([IO.Path]::Combine($Scenario.Package, 'scripts', 'Install-MultiAgentProject.ps1')) -Config $Scenario.Config -Phase Validate @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    return [pscustomobject]@{ Code = $code; Text = ($output | Out-String) }
}

# Sentinela de execucao: script sh que grava um arquivo; nunca deve existir.
function New-Sentinel {
    param($Scenario, [string]$Name)
    $sentinel = [IO.Path]::Combine($Scenario.Root, 'sentinela-' + $Name + '.txt')
    return [pscustomobject]@{ Path = $sentinel; Script = ("#!/bin/sh`necho executado >> '" + $sentinel.Replace('\', '/') + "'`n") }
}

# Conformidade completa com o resultado de Validate.
function Assert-Conforme {
    param($Result, [string]$Message = '')
    Assert-Equal 'Sucesso' $Result.Status ($Message + ' ' + (Get-Codes $Result) + ' | ' + (Get-Incomplete $Result))
    Assert-Equal 'Conforme' $Result.Conformity $Message
    Assert-Equal 44 @($Result.Files | Where-Object { $_.Classification -ceq 'Identico' }).Count ($Message + ' destinos identicos')
    Assert-Equal 'Compativel' $Result.Hooks.Decision $Message
    Assert-Equal 0 @($Result.Incomplete).Count $Message
    Assert-Equal $false $Result.Modified
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
    if ($globalHooks.ExitCode -eq 0) { $missing.Add('core.hooksPath global ou de sistema ausente (a conformidade seria bloqueada por desenho)') }
}
if ($missing.Count -gt 0) {
    foreach ($item in $missing) { Write-Output ('  [PRE-REQ] ausente: ' + $item) }
    Write-Output 'Resultado: 0 aprovados, 0 falhas; suite nao executada por pre-requisito ausente'
    foreach ($name in $SavedGitEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$SavedGitEnvironment[$name]) }
    exit 2
}

try {
    Write-Output 'Conformidade apos a conclusao'
    It 'concluida pela CompleteWorktrees: Sucesso e Conforme, quatro separacoes, nada alterado e resultado estavel (AC07, AC11, AC25)' {
        $s = New-ValidateScenario -Stage Integrado
        $complete = Invoke-MaCompleteWorktrees -ConfigPath $s.Config -PackageRoot $s.Package -AuthorizationReference $Authorization -IntegratedCommit $s.I -IntegrationReference $s.Evidence
        Assert-Equal 'Sucesso' $complete.Status (Get-Codes $complete)
        $r = Invoke-ReadOnlyValidate $s
        Assert-Conforme $r
        Assert-Equal 'NaoFornecida' $r.EvidenceResult
        Assert-Equal 'NaoVerificada' $r.RemoteProtection
        Assert-Equal 'Limpo,Limpo,Limpo,Limpo' ((@($r.WorkingChanges | ForEach-Object { $_.State })) -join ',')
        Assert-Equal 4 @($r.Hooks.Worktrees).Count
        foreach ($row in $r.Hooks.Worktrees) { Assert-True ($row.Destination -ieq [IO.Path]::Combine($row.Root, '.githooks')) ('destino ' + $row.Role + ': ' + $row.Destination) }
        Assert-NoIssue $r 'MA_HOOKS_PATH_PRESENT'
        Assert-Equal 0 @($r.Issues | Where-Object { $_.Severity -ne 'Aviso' }).Count (Get-Codes $r)
        Assert-True (@($r.Pending | Where-Object { $_.StartsWith('Relacao dos ambientes com a base integrada') }).Count -eq 1) 'pendencia da base integrada'
        $text = (Format-MaValidateReport $r) -join "`n"
        foreach ($expected in @('Conformidade local: Conforme', 'Hooks por worktree (decisao: Compativel)', 'Alteracoes de trabalho (fora do conjunto governado):', 'Evidencia fornecida: NaoFornecida', 'Protecao remota: nao verificada', 'Nenhuma modificacao foi realizada.')) {
            Assert-True ($text.Contains($expected)) ('relatorio sem: ' + $expected)
        }
        # Estabilidade e idempotencia: segunda leitura com relatorio identico.
        $again = Invoke-ReadOnlyValidate $s
        Assert-Equal $text ((Format-MaValidateReport $again) -join "`n") 'relatorio da repeticao'
    }
    It 'evidencia: I e registro conferidos contra os objetos locais; sem AuthorizationReference o vinculo fica pendente (AC20, AC27)' {
        $s = New-ValidateScenario
        $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; AuthorizationReference = $Authorization }
        Assert-Conforme $r
        Assert-Equal 'Consistente' $r.EvidenceResult
        Assert-True ($s.M -cne $s.I) 'M igual a I'
        Assert-Equal 22 @($r.Comparison | Where-Object { $_.Result -eq 'Conforme' }).Count 'comparacao de M e I'
        Assert-Equal 'I,M' ((@($r.Comparison | ForEach-Object { $_.Source } | Select-Object -Unique)) -join ',')
        Assert-True ($r.Evidence.CoordinationHead.Contains('contem o commit integrado')) $r.Evidence.CoordinationHead
        Assert-True ($r.Evidence.IntegrationReference.StartsWith('registro SHA-256 ')) $r.Evidence.IntegrationReference
        $text = (Format-MaValidateReport $r) -join "`n"
        Assert-True ($text.Contains('Evidencia fornecida: Consistente')) 'secao de evidencia'
        Assert-True ($text.Contains('[I] .githooks/pre-push | Conforme | 100755 blob')) 'comparacao por caminho'
        foreach ($secret in @($Authorization, 'Revisor Codex Ficticio', 'Responsavel Humano Ficticio', $PullRequest, 'registro-servidor-ficticio')) { Assert-True (-not $text.Contains($secret)) ('relatorio reproduz ' + $secret) }
        $without = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true }
        Assert-Equal 'Sucesso' $without.Status (Get-Codes $without)
        Assert-Equal 'Consistente' $without.EvidenceResult
        Assert-True (@($without.Pending | Where-Object { $_.Contains('AuthorizationReference nao fornecida') }).Count -eq 1) 'pendencia da autorizacao'
        $other = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; AuthorizationReference = 'outra-autorizacao' }
        Assert-Equal 'Bloqueado' $other.Status
        Assert-Equal 'Conforme' $other.Conformity 'conformidade local afetada pela evidencia'
        Assert-Equal 'Inconsistente' $other.EvidenceResult
        Assert-HasIssue $other 'MA_INTEGRATION_EVIDENCE_MISMATCH'
        $onlyCommit = Invoke-ReadOnlyValidate $s @{ IntegratedCommit = $s.I }
        Assert-Equal 'Consistente' $onlyCommit.EvidenceResult (Get-Codes $onlyCommit)
        Assert-Equal 11 @($onlyCommit.Comparison).Count 'somente I comparado'
        Assert-True (@($onlyCommit.Pending | Where-Object { $_.StartsWith('Registro de integracao nao fornecido') }).Count -eq 1) 'pendencia do registro'
        $onlyRecord = Invoke-ReadOnlyValidate $s @{ IntegrationReference = $s.Evidence }
        Assert-HasIssue $onlyRecord 'MA_INTEGRATEDCOMMIT_REQUIRED'
        Assert-Equal 'Inconsistente' $onlyRecord.EvidenceResult
    }
    It 'registro com aprovacao booleana, revisor igual ao autor ou dentro de um worktree: evidencia inconsistente, nada alterado' {
        $s = New-ValidateScenario
        $cases = @(
            @('MA_INTEGRATION_REFERENCE_INVALID', { param($d) $d['approved'] = $true }),
            @('MA_INTEGRATION_REVIEW_NOT_INDEPENDENT', { param($d) $d.review.reviewer = 'autor claude ficticio' })
        )
        foreach ($case in $cases) {
            $data = New-EvidenceData $s; & $case[1] $data
            Write-Evidence $s $data
            $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; AuthorizationReference = $Authorization }
            Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
            Assert-HasIssue $r $case[0]
            Assert-Equal 'Inconsistente' $r.EvidenceResult
            Assert-Equal 'Conforme' $r.Conformity
            Assert-Equal 0 @($r.Comparison).Count 'relacao conferida com registro invalido'
        }
        $inside = [IO.Path]::Combine($s.Codex, 'integracao.json')
        Write-Evidence $s (New-EvidenceData $s) $inside
        $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; IntegrationReference = $inside }
        Assert-HasIssue $r 'MA_INTEGRATION_REFERENCE_INSIDE_WORKTREE'
    }
    It 'caminho com espacos, acentos, apostrofo, $, &, colchetes e ponto e virgula chega literal (AC18)' {
        $name = 'ws a' + [char]0xE7 + 'a ''x'' $y & [z]; w'
        $s = New-ValidateScenario -WorkspaceName $name
        $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; AuthorizationReference = $Authorization }
        Assert-Conforme $r
        Assert-Equal 'Consistente' $r.EvidenceResult
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $s.Root -Force -Directory | Where-Object { $_.Name -like 'ws*' }).Count 'caminho expandido ou duplicado'
    }

    Write-Output 'Estados parcialmente configurados (incompletude)'
    It 'progressao: vazio, coordenacao, manutencao preparada, integrada sem agentes, agentes sem hooks e concluida' {
        $s = New-ValidateScenario -Stage Vazio
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-Equal 'Incompleta' $r.Conformity
        Assert-Equal 'coordination,codex,claude,maintenance' ((@($r.Incomplete | ForEach-Object { $_.Role })) -join ',') (Get-Incomplete $r)
        Assert-True ($r.Incomplete[0].Next.StartsWith('PrepareMaintenance')) (Get-Incomplete $r)
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $s.Workspace -Force).Count 'ambiente criado'
        # Coordenacao clonada, sem governanca.
        $s = New-ValidateScenario -Stage Coordenacao
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        $coordination = @($r.Incomplete | Where-Object { $_.Role -eq 'coordination' })
        Assert-True ($coordination.Count -eq 1 -and $coordination[0].Item.StartsWith('11 de 11 destinos governados ausentes')) (Get-Incomplete $r)
        Assert-True ($coordination[0].Next.Contains('integracao do PR')) $coordination[0].Next
        Assert-Equal 'Limpo' @($r.WorkingChanges | Where-Object { $_.Role -eq 'coordination' })[0].State
        # Manutencao preparada e nao commitada.
        Add-PreparedMaintenance $s
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-True (@($r.Incomplete | Where-Object { $_.Role -eq 'maintenance' -and $_.Item -ceq '11 destinos governados preparados e nao commitados' }).Count -eq 1) (Get-Incomplete $r)
        Assert-Equal 'Limpo' @($r.WorkingChanges | Where-Object { $_.Role -eq 'maintenance' })[0].State 'governados nao sao alteracoes de trabalho'
        Assert-Equal $null $r.Hooks
        # Integrada e sincronizada, sem agentes.
        Add-Integration $s
        $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; AuthorizationReference = $Authorization }
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-Equal 'codex,claude' ((@($r.Incomplete | ForEach-Object { $_.Role })) -join ',') (Get-Incomplete $r)
        Assert-Equal 'CompleteWorktrees' $r.Incomplete[0].Next
        Assert-Equal 'Consistente' $r.EvidenceResult
        Assert-True (@($r.Pending | Where-Object { $_.StartsWith('Configuracao efetiva dos hooks avaliada somente') }).Count -eq 1) 'pendencia dos hooks'
        # Agentes sem hooks ativados.
        Add-FixtureAgent $s 'codex'; Add-FixtureAgent $s 'claude'
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-Equal 'Inserir' $r.Hooks.Decision
        Assert-True ($r.Incomplete[0].Item.StartsWith('core.hooksPath ausente nos quatro ambientes')) (Get-Incomplete $r)
        Assert-Equal 44 @($r.Files | Where-Object { $_.Classification -ceq 'Identico' }).Count
        # Concluida.
        Enable-Hooks $s
        Assert-Conforme (Invoke-ReadOnlyValidate $s)
    }
    It 'worktree de agente sem checkout: Incompleta com retomada pela CompleteWorktrees' {
        $s = New-ValidateScenario -Stage Integrado
        [void](Invoke-FixtureGit $s.Coordination @('worktree', 'add', '-q', '--no-checkout', '-b', 'feature/codex', $s.Codex, $s.I))
        Add-FixtureAgent $s 'claude'
        Enable-Hooks $s
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        $codex = @($r.Incomplete | Where-Object { $_.Role -eq 'codex' })
        Assert-True ($codex.Count -eq 1 -and $codex[0].Item.StartsWith('checkout pendente') -and $codex[0].Next -ceq 'CompleteWorktrees (retomada do checkout)') (Get-Incomplete $r)
        Assert-Equal 'NaoInspecionado' @($r.WorkingChanges | Where-Object { $_.Role -eq 'codex' })[0].State
    }

    Write-Output 'Divergencias demonstradas (AC15, AC28, AC29)'
    It 'documento alterado no checkout de um agente: Divergente por caminho, nada alterado' {
        $s = New-ValidateScenario
        Write-FixtureFile ([IO.Path]::Combine($s.Codex, 'docs', 'agentes', 'revisao.md')) $Utf8.GetBytes("alterado`n")
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'Divergente' $r.Conformity
        Assert-HasIssue $r 'MA_FILE_CONFLICT' 'codex'
        $file = @($r.Files | Where-Object { $_.Role -eq 'codex' -and $_.Path -ceq 'docs/agentes/revisao.md' })[0]
        Assert-Equal 'Conflitante' $file.Classification
        Assert-True ($file.Reason.Contains('checkout: bytes divergentes')) $file.Reason
        $text = (Format-MaValidateReport $r) -join "`n"
        Assert-True ($text.Contains('[divergencia] MA_FILE_CONFLICT')) 'categoria no relatorio'
    }
    It 'checkout divergente apesar de assume-unchanged e status limpo (AC29)' {
        $s = New-ValidateScenario
        [void](Invoke-FixtureGit $s.Claude @('update-index', '--assume-unchanged', '--', 'AGENTS.md'))
        Write-FixtureFile ([IO.Path]::Combine($s.Claude, 'AGENTS.md')) $Utf8.GetBytes("alterado`n")
        Assert-Equal '' (Invoke-FixtureGit $s.Claude @('status', '--porcelain')) 'status deveria parecer limpo'
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Divergente' $r.Conformity (Get-Codes $r)
        Assert-HasIssue $r 'MA_FILE_CONFLICT' 'claude'
        Assert-Equal 'Limpo' @($r.WorkingChanges | Where-Object { $_.Role -eq 'claude' })[0].State
    }
    It 'hook com modo 100644 no indice: Divergente' {
        $s = New-ValidateScenario
        [void](Invoke-FixtureGit $s.Maintenance @('update-index', '--chmod=-x', '--', '.githooks/pre-push'))
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Divergente' $r.Conformity (Get-Codes $r)
        $file = @($r.Files | Where-Object { $_.Role -eq 'maintenance' -and $_.Path -ceq '.githooks/pre-push' })[0]
        Assert-True ($file.Reason.Contains('indice: modo 100644')) $file.Reason
        Assert-HasIssue $r 'MA_HOOKS_GOVERNED_INVALID' 'maintenance'
    }
    It 'hook com nome que difere somente pela caixa no checkout: Divergente e entrada inesperada (protecao do Marco 3)' {
        $s = New-ValidateScenario
        $hooks = [IO.Path]::Combine($s.Codex, '.githooks')
        [IO.File]::Move([IO.Path]::Combine($hooks, 'pre-push'), [IO.Path]::Combine($hooks, 'tmp-nome'))
        [IO.File]::Move([IO.Path]::Combine($hooks, 'tmp-nome'), [IO.Path]::Combine($hooks, 'Pre-Push'))
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Divergente' $r.Conformity (Get-Codes $r)
        $file = @($r.Files | Where-Object { $_.Role -eq 'codex' -and $_.Path -ceq '.githooks/pre-push' })[0]
        Assert-True ($file.Reason.Contains('grafia divergente por caixa (.githooks/Pre-Push)')) $file.Reason
        Assert-True (@($r.Issues | Where-Object { $_.Code -ceq 'MA_FILE_UNEXPECTED_ENTRY' -and $_.Role -eq 'codex' -and $_.Path -ceq '.githooks/Pre-Push' }).Count -eq 1) (Get-Codes $r)
    }
    It 'arquivo extra em .githooks: Divergente e hooks invalidos, sem execucao' {
        $s = New-ValidateScenario
        $sentinel = New-Sentinel $s 'extra'
        Write-FixtureFile ([IO.Path]::Combine($s.Maintenance, '.githooks', 'post-merge')) $Utf8.GetBytes($sentinel.Script)
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Divergente' $r.Conformity (Get-Codes $r)
        Assert-HasIssue $r 'MA_FILE_UNEXPECTED_ENTRY' 'maintenance'
        Assert-HasIssue $r 'MA_HOOKS_GOVERNED_INVALID' 'maintenance'
        Assert-True (-not [IO.File]::Exists($sentinel.Path)) 'hook executado'
    }

    Write-Output 'Hooks efetivos e alcance (AC16, AC17, AC25, AC26)'
    It 'core.hooksPath distinto, multiplo, por worktree ou por include condicional: Divergente, configuracao preservada' {
        $s = New-ValidateScenario
        $include = [IO.Path]::Combine($s.Root, 'incluido.gitconfig')
        Write-FixtureFile $include $Utf8.GetBytes("[core]`n`thooksPath = outro`n")
        $cases = @(
            @('distinto', { [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'core.hooksPath', 'outro')) }, { Enable-Hooks $s }),
            @('multiplo', { [void](Invoke-FixtureGit $s.Coordination @('config', '--local', '--add', 'core.hooksPath', '.githooks')) }, { [void](Invoke-FixtureGit $s.Coordination @('config', '--local', '--unset-all', 'core.hooksPath')); Enable-Hooks $s }),
            @('worktree', { [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'core.repositoryFormatVersion', '1')); [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'extensions.worktreeConfig', 'true')); [void](Invoke-FixtureGit $s.Claude @('config', '--worktree', 'core.hooksPath', '.githooks')) },
                { [void](Invoke-FixtureGit $s.Claude @('config', '--worktree', '--unset', 'core.hooksPath')); [void](Invoke-FixtureGit $s.Coordination @('config', '--local', '--unset', 'extensions.worktreeConfig')) }),
            @('include', { [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'includeIf.onbranch:feature/claude.path', $include.Replace('\', '/'))) },
                { [void](Invoke-FixtureGit $s.Coordination @('config', '--local', '--unset', 'includeIf.onbranch:feature/claude.path')) })
        )
        foreach ($case in $cases) {
            & $case[1]
            $values = @(foreach ($role in $Roles) { Get-HooksPathValues $s.Model.Worktrees[$role] })
            $r = Invoke-ReadOnlyValidate $s
            Assert-Equal 'Bloqueado' $r.Status ($case[0] + ': ' + (Get-Codes $r))
            Assert-Equal 'Divergente' $r.Conformity $case[0]
            Assert-HasIssue $r 'MA_HOOKS_CONFIG_CONFLICT'
            Assert-Equal ($values -join '#') ((@(foreach ($role in $Roles) { Get-HooksPathValues $s.Model.Worktrees[$role] })) -join '#') ('configuracao alterada: ' + $case[0])
            & $case[2]
            Assert-Conforme (Invoke-Validate $s) ('restaurado apos ' + $case[0])
        }
    }
    It 'hooks no diretorio padrao: ocultados com a cadeia compativel, bloqueiam sem ela; nenhum executado' {
        $s = New-ValidateScenario
        $sentinel = New-Sentinel $s 'padrao'
        foreach ($name in $HookNames) { Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.git', 'hooks', $name)) $Utf8.GetBytes($sentinel.Script) }
        $r = Invoke-ReadOnlyValidate $s
        Assert-Conforme $r 'hooks padrao ocultados'
        Assert-HasIssue $r 'MA_HOOKS_DEFAULT_ACTIVE'
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', '--unset-all', 'core.hooksPath'))
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_HOOKS_DEFAULT_WOULD_BE_HIDDEN'
        Assert-True (-not [IO.File]::Exists($sentinel.Path)) 'hook executado'
    }
    It 'quinto worktree registrado e registro indisponivel: Divergente' {
        $s = New-ValidateScenario
        $fifth = [IO.Path]::Combine($s.Root, 'quinto')
        [void](Invoke-FixtureGit $s.Coordination @('worktree', 'add', '-q', '-b', 'extra', $fifth, $s.I))
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Divergente' $r.Conformity (Get-Codes $r)
        Assert-HasIssue $r 'MA_WORKTREE_UNEXPECTED'
        Assert-HasIssue $r 'MA_HOOKS_SCOPE_INCOMPLETE'
        [IO.Directory]::Delete($fifth, $true)
        $r = Invoke-ReadOnlyValidate $s
        Assert-HasIssue $r 'MA_WORKTREE_PRUNABLE'
        Assert-Equal 'Divergente' $r.Conformity
    }
    It 'override de processo (GIT_CONFIG_PARAMETERS): Inconclusiva, sem remove-lo' {
        $s = New-ValidateScenario
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_PARAMETERS', "'core.hookspath'='temporario'")
        try {
            $r = Invoke-ReadOnlyValidate $s
            Assert-HasIssue $r 'MA_GIT_ENV_OVERRIDE'
            Assert-Equal 'Inconclusiva' $r.Conformity (Get-Codes $r)
            Assert-Equal "'core.hookspath'='temporario'" ([Environment]::GetEnvironmentVariable('GIT_CONFIG_PARAMETERS')) 'override removido'
        } finally { [Environment]::SetEnvironmentVariable('GIT_CONFIG_PARAMETERS', $null) }
    }

    Write-Output 'Alteracoes de trabalho'
    It 'alteracao nos agentes e informativa; na coordenacao impede a conformidade' {
        $s = New-ValidateScenario
        Write-FixtureFile ([IO.Path]::Combine($s.Codex, 'notas.txt')) $Utf8.GetBytes("nota`n")
        Write-FixtureFile ([IO.Path]::Combine($s.Claude, 'app.txt')) $Utf8.GetBytes("alterado`n")
        [void](Invoke-FixtureGit $s.Claude @('add', '--', 'app.txt'))
        $r = Invoke-ReadOnlyValidate $s
        Assert-Conforme $r 'alteracoes nos agentes'
        Assert-Equal 'notas.txt' (@(@($r.WorkingChanges | Where-Object { $_.Role -eq 'codex' })[0].Paths) -join ',')
        Assert-Equal 'app.txt' (@(@($r.WorkingChanges | Where-Object { $_.Role -eq 'claude' })[0].Paths) -join ',')
        Assert-Equal 2 @($r.Issues | Where-Object { $_.Code -ceq 'MA_VALIDATE_WORKING_CHANGES' -and $_.Severity -eq 'Aviso' }).Count (Get-Codes $r)
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, 'rascunho.txt')) $Utf8.GetBytes("edicao`n")
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'Divergente' $r.Conformity
        Assert-HasIssue $r 'MA_VALIDATE_COORDINATION_CHANGED' 'coordination'
        Assert-Equal 'rascunho.txt' (@(@($r.WorkingChanges | Where-Object { $_.Role -eq 'coordination' })[0].Paths) -join ',')
    }
    It 'fsmonitor e filtro configurados: nenhum executado; com filter rastreado o status nao e lido (Inconclusiva)' {
        $s = New-ValidateScenario
        $monitor = New-Sentinel $s 'fsmonitor'
        $monitorScript = [IO.Path]::Combine($s.Root, 'fsmonitor.sh')
        Write-FixtureFile $monitorScript $Utf8.GetBytes($monitor.Script)
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'core.fsmonitor', $monitorScript.Replace('\', '/')))
        $r = Invoke-ReadOnlyValidate $s
        Assert-Conforme $r 'fsmonitor configurado'
        Assert-True (-not [IO.File]::Exists($monitor.Path)) 'fsmonitor executado'
        $filter = New-Sentinel $s 'filtro'
        $filterScript = [IO.Path]::Combine($s.Root, 'filtro.sh')
        Write-FixtureFile $filterScript $Utf8.GetBytes($filter.Script + "cat`n")
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'filter.sentinela.clean', ("sh '" + $filterScript.Replace('\', '/') + "'")))
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'filter.sentinela.smudge', ("sh '" + $filterScript.Replace('\', '/') + "'")))
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.git', 'info', 'attributes')) $Utf8.GetBytes("app.txt filter=sentinela`n")
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Inconclusiva' $r.Conformity (Get-Codes $r)
        Assert-Equal 'NaoVerificado,NaoVerificado,NaoVerificado,NaoVerificado' ((@($r.WorkingChanges | ForEach-Object { $_.State })) -join ',')
        Assert-True (@($r.Issues | Where-Object { $_.Code -ceq 'MA_VALIDATE_CHANGES_UNVERIFIED' -and $_.Role -eq 'coordination' -and $_.Severity -eq 'Bloqueio' }).Count -eq 1) (Get-Codes $r)
        Assert-Equal 3 @($r.Issues | Where-Object { $_.Code -ceq 'MA_VALIDATE_CHANGES_UNVERIFIED' -and $_.Severity -eq 'Aviso' }).Count (Get-Codes $r)
        Assert-True (-not [IO.File]::Exists($filter.Path)) 'filtro executado'
        Assert-True (-not [IO.File]::Exists($monitor.Path)) 'fsmonitor executado'
    }

    Write-Output 'Relacao com a base integrada'
    It 'branch de agente sem I e conteudo igual: sem evidencia, pendente; com evidencia, inconsistente' {
        $s = New-ValidateScenario -Stage Integrado
        $copy = Invoke-FixtureGit $s.Coordination @('commit-tree', ($s.I + '^{tree}'), '-p', $s.Base, '-m', 'copia sem I')
        Add-FixtureAgent $s 'codex' $copy
        Add-FixtureAgent $s 'claude'
        Enable-Hooks $s
        $local = Invoke-ReadOnlyValidate $s
        Assert-Conforme $local 'conteudo governado igual'
        Assert-True (@($local.Pending | Where-Object { $_.StartsWith('Relacao dos ambientes com a base integrada') }).Count -eq 1) 'limitacao nao explicitada'
        $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; AuthorizationReference = $Authorization }
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'Conforme' $r.Conformity
        Assert-Equal 'Inconsistente' $r.EvidenceResult
        Assert-HasIssue $r 'MA_COMPLETE_BRANCH_NOT_FROM_INTEGRATION' 'codex'
        Assert-NoIssue $r 'MA_COMPLETE_COORDINATION_NOT_SYNCED'
    }
    It 'coordenacao sem I: com evidencia, nao sincronizada; localmente incompleta' {
        $s = New-ValidateScenario -Stage Integrado -NoSync
        $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; AuthorizationReference = $Authorization }
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'Incompleta' $r.Conformity
        Assert-HasIssue $r 'MA_COMPLETE_COORDINATION_NOT_SYNCED' 'coordination'
        Assert-HasIssue $r 'MA_COMPLETE_REMOTE_TRACKING_UNCONFIRMED' 'coordination'
        Assert-Equal 'Inconsistente' $r.EvidenceResult
    }
    It 'commit integrado ausente localmente: evidencia inconclusiva, sem busca remota' {
        $s = New-ValidateScenario
        $absent = 'abcdef0123' * 4
        $data = New-EvidenceData $s; $data.integration.resultingCommit = $absent; $data.completionAuthorization.integratedCommit = $absent
        Write-Evidence $s $data
        $originBefore = Get-Snapshot $s.Origin
        $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; IntegratedCommit = $absent; AuthorizationReference = $Authorization }
        Assert-HasIssue $r 'MA_COMPLETE_COMMIT_UNAVAILABLE' 'coordination'
        Assert-Equal 'Inconclusiva' $r.EvidenceResult
        Assert-Equal 'Conforme' $r.Conformity
        Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto'
        Assert-Equal 1 (Invoke-FixtureGit $s.Coordination @('cat-file', '-e', $absent) -AllowFailure).ExitCode 'objeto obtido'
    }
    It 'I com documento alterado e manifesto igual: comparacao rejeita por caminho (AC28)' {
        $s = New-ValidateScenario
        $revisao = (Get-RenderedText $s 'docs/agentes/revisao.md') + "alterado`n"
        $altered = New-AlteredCommit $s $s.I @{ 'docs/agentes/revisao.md' = @{ Mode = '100644'; Text = $revisao } } @($s.Base)
        $data = New-EvidenceData $s; $data.integration.resultingCommit = $altered; $data.completionAuthorization.integratedCommit = $altered
        Write-Evidence $s $data
        $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; IntegratedCommit = $altered; AuthorizationReference = $Authorization }
        Assert-Equal 'Inconsistente' $r.EvidenceResult (Get-Codes $r)
        $entry = @($r.Comparison | Where-Object { $_.Source -ceq 'I' -and $_.Path -ceq 'docs/agentes/revisao.md' })
        Assert-True ($entry.Count -eq 1 -and $entry[0].Result -eq 'Divergente' -and $entry[0].Reason -ceq 'bytes divergentes') 'comparacao do documento'
        Assert-Equal 'Conforme' @($r.Comparison | Where-Object { $_.Source -ceq 'I' -and $_.Path -ceq '.multiagente/manifest.json' })[0].Result
        Assert-HasIssue $r 'MA_COMPLETE_GOVERNED_DIVERGENT'
        Assert-HasIssue $r 'MA_COMPLETE_COORDINATION_NOT_SYNCED'
    }
    It 'manutencao avancada depois da conclusao: aviso e evidencia consistente' {
        $s = New-ValidateScenario
        Write-FixtureFile ([IO.Path]::Combine($s.Maintenance, 'notas.txt')) $Utf8.GetBytes("nota`n")
        Save-Commit $s.Maintenance 'posterior'
        $r = Invoke-ReadOnlyValidate $s @{ WithEvidence = $true; AuthorizationReference = $Authorization }
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 'Consistente' $r.EvidenceResult
        Assert-True (@($r.Issues | Where-Object { $_.Code -ceq 'MA_COMPLETE_MAINTENANCE_NOT_REVIEWED' -and $_.Severity -eq 'Aviso' }).Count -eq 1) (Get-Codes $r)
    }

    Write-Output 'Somente leitura, concorrencia e leitura inconclusiva'
    It 'objeto de blob governado ausente: Inconclusiva, sem busca remota' {
        $s = New-ValidateScenario
        $blob = Invoke-FixtureGit $s.Coordination @('rev-parse', 'HEAD:docs/agentes/revisao.md')
        $object = [IO.Path]::Combine($s.Coordination, '.git', 'objects', $blob.Substring(0, 2), $blob.Substring(2))
        Assert-True ([IO.File]::Exists($object)) 'objeto solto esperado na fixture'
        [IO.File]::SetAttributes($object, 'Normal'); [IO.File]::Delete($object)
        $originBefore = Get-Snapshot $s.Origin
        $r = Invoke-ReadOnlyValidate $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'Inconclusiva' $r.Conformity
        Assert-HasIssue $r 'MA_GIT_OBJECT_MISSING'
        Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto'
        Assert-Equal 1 (Invoke-FixtureGit $s.Coordination @('cat-file', '-e', $blob) -AllowFailure).ExitCode 'objeto obtido'
        $text = (Format-MaValidateReport $r) -join "`n"
        Assert-True ($text.Contains('[leitura inconclusiva] MA_GIT_OBJECT_MISSING')) 'categoria no relatorio'
    }
    It 'fase mutavel em execucao (mutex): Inconclusiva, sem obter a exclusao mutua' {
        $s = New-ValidateScenario
        $name = Get-LockName $s
        $holder = [powershell]::Create()
        $ready = New-Object System.Threading.ManualResetEvent($false)
        $release = New-Object System.Threading.ManualResetEvent($false)
        [void]$holder.AddScript({ param($n, $r1, $r2) $m = New-Object System.Threading.Mutex($false, $n); [void]$m.WaitOne(); [void]$r1.Set(); [void]$r2.WaitOne(60000); $m.ReleaseMutex(); $m.Dispose() }).AddArgument($name).AddArgument($ready).AddArgument($release)
        $handle = $holder.BeginInvoke()
        try {
            Assert-True ($ready.WaitOne(10000)) 'mutex nao obtido pelo detentor'
            $r = Invoke-ReadOnlyValidate $s
            Assert-HasIssue $r 'MA_VALIDATE_CONCURRENT_PHASE'
            Assert-Equal 'Inconclusiva' $r.Conformity (Get-Codes $r)
            Assert-Equal 'Bloqueado' $r.Status
        } finally { [void]$release.Set(); [void]$holder.EndInvoke($handle); $holder.Dispose() }
        Assert-Conforme (Invoke-Validate $s) 'apos liberar a exclusao mutua'
    }
    It 'estado alterado durante a validacao (branch nova, HEAD ou core.hooksPath de um agente): Inconclusiva' {
        $s = New-ValidateScenario
        $script:Scenario = $s
        $changes = @(
            { [void](Invoke-FixtureGit $script:Scenario.Coordination @('branch', 'terceiro', $script:Scenario.I)) },
            { Write-FixtureFile ([IO.Path]::Combine($script:Scenario.Codex, 'novo.txt')) $Utf8.GetBytes("x`n"); Save-Commit $script:Scenario.Codex 'commit concorrente' },
            { [void](Invoke-FixtureGit $script:Scenario.Coordination @('config', '--local', '--add', 'core.hooksPath', '.githooks')) }
        )
        foreach ($change in $changes) {
            Set-Fault 'ValidateBeforeRecheck' $change
            $r = Invoke-Validate $s
            InModule { $script:MaNativeFaults = @{} }
            Assert-HasIssue $r 'MA_VALIDATE_STATE_CHANGED'
            Assert-Equal 'Inconclusiva' $r.Conformity (Get-Codes $r)
            Assert-Equal 'Bloqueado' $r.Status
        }
    }
    It 'nenhum temporario ou rastreamento gravado: TEMP e TMP vazios e GIT_TRACE no repositorio sem efeito' {
        $s = New-ValidateScenario
        $temporary = [IO.Path]::Combine($s.Root, 'tmp-validate')
        [void][IO.Directory]::CreateDirectory($temporary)
        $trace = [IO.Path]::Combine($s.Coordination, 'trace.txt')
        $saved = @{}
        foreach ($name in @('TEMP', 'TMP', 'GIT_TRACE', 'GIT_TRACE2_EVENT')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            [Environment]::SetEnvironmentVariable('TEMP', $temporary); [Environment]::SetEnvironmentVariable('TMP', $temporary)
            [Environment]::SetEnvironmentVariable('GIT_TRACE', $trace); [Environment]::SetEnvironmentVariable('GIT_TRACE2_EVENT', $trace)
            $before = Get-Snapshot $s.Root
            $r = Invoke-Validate $s
            Assert-SameSnapshot $before (Get-Snapshot $s.Root) 'fixture'
        } finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
        Assert-Conforme $r
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $temporary -Force).Count 'temporario criado'
        Assert-True (-not [IO.File]::Exists($trace)) 'rastreamento gravado'
    }

    Write-Output 'Ponto de entrada'
    It 'conforme 0, WhatIf sem efeito, registro relativo, divergente 3 e incompleta 2, sem modificacao' {
        $s = New-ValidateScenario
        $before = Get-Snapshot $s.Root
        $run = Invoke-EntryPoint $s @()
        Assert-Equal 0 $run.Code $run.Text
        Assert-True ($run.Text.Contains('Resultado: Sucesso') -and $run.Text.Contains('Conformidade local: Conforme')) $run.Text
        $whatIf = Invoke-EntryPoint $s @('-WhatIf')
        Assert-Equal 0 $whatIf.Code $whatIf.Text
        Assert-True ($whatIf.Text.Contains('WhatIf: sem efeito adicional')) $whatIf.Text
        Push-Location -LiteralPath $s.Root
        try { $evidence = Invoke-EntryPoint $s @('-IntegratedCommit', $s.I, '-IntegrationReference', 'integracao.json', '-AuthorizationReference', $Authorization) }
        finally { Pop-Location }
        Assert-Equal 0 $evidence.Code $evidence.Text
        Assert-True ($evidence.Text.Contains('Evidencia fornecida: Consistente')) $evidence.Text
        foreach ($secret in @($Authorization, 'Responsavel Humano Ficticio')) { Assert-True (-not $evidence.Text.Contains($secret)) ('relatorio reproduz ' + $secret) }
        Assert-SameSnapshot $before (Get-Snapshot $s.Root) 'fixture'
        Write-FixtureFile ([IO.Path]::Combine($s.Claude, 'CLAUDE.md')) $Utf8.GetBytes("alterado`n")
        $before = Get-Snapshot $s.Root
        $divergent = Invoke-EntryPoint $s @()
        Assert-Equal 3 $divergent.Code $divergent.Text
        Assert-True ($divergent.Text.Contains('Conformidade local: Divergente')) $divergent.Text
        Assert-SameSnapshot $before (Get-Snapshot $s.Root) 'fixture'
        $partial = New-ValidateScenario -Stage Preparado
        $before = Get-Snapshot $partial.Root
        $incomplete = Invoke-EntryPoint $partial @()
        Assert-Equal 2 $incomplete.Code $incomplete.Text
        Assert-True ($incomplete.Text.Contains('Instalacao incompleta:')) $incomplete.Text
        Assert-SameSnapshot $before (Get-Snapshot $partial.Root) 'fixture'
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
