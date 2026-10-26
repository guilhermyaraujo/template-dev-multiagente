#Requires -Version 5.1
<#
Testes de integracao da fase Plan com Git real. Cada caso cria repositorios,
commits e worktrees exclusivamente em um diretorio descartavel sob o TEMP do
executor, fora dos worktrees do projeto, e o remove ao final. Commits existem
somente nessas fixtures, com identidade ficticia por variavel de processo.
Preparacao usa -c core.hooksPath=<vazio> e -c commit.gpgsign=false apenas no
processo da fixture: nenhuma configuracao global, de sistema ou do projeto e
alterada. O Plan roda sem simulacao, sobre o Git real, e cada execucao confere
que nenhum byte, indice, referencia ou configuracao da fixture mudou.

Uso: powershell -NoProfile -File tests/integration/Plan.Integration.Tests.ps1
Codigo de saida: 0 quando todos os casos passam; 1 se algum caso falha; 2 se a
suite nao pode ser executada por pre-requisito ausente (nunca contado como aprovado).

Pre-requisitos: Git for Windows >= 2.44 no PATH e Job Object do Windows
disponivel (o Plan recusa executar processos sem contencao). Variaveis Git que
redirecionam repositorio ou configuracao (GIT_DIR, GIT_CONFIG_*, ...) sao
removidas apenas deste processo de teste e restauradas ao final.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PackageSource = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
$Module = Import-Module -Name ([IO.Path]::Combine($PackageSource, 'scripts', 'MultiAgentTemplate.psm1')) -Force -PassThru -DisableNameChecking
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$GitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$GitExe = $null; if ($null -ne $GitCommand) { $GitExe = $GitCommand.Path }
$Url = 'https://example.invalid/org/demo.git'
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]

# --- Harness ------------------------------------------------------------------------

function It {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Output ('  [ok]    ' + $Name) }
    catch { $script:Failed.Add($Name + ' :: ' + $_.Exception.Message); Write-Output ('  [FALHA] ' + $Name + ' :: ' + $_.Exception.Message) }
}
function Assert-Equal { param($Expected, $Actual, [string]$Message = '') if (-not [object]::Equals($Expected, $Actual)) { throw ('esperado <' + $Expected + '> obtido <' + $Actual + '> ' + $Message) } }
function Assert-True { param([bool]$Condition, [string]$Message = 'condicao falsa') if (-not $Condition) { throw $Message } }
function Get-Codes { param($Plan) return ((@($Plan.Issues | ForEach-Object { $_.Severity + ':' + $_.Code + '@' + $_.Role })) -join ', ') }
function Assert-HasIssue {
    param($Plan, [string]$Code, [string]$Role = '')
    if (@($Plan.Issues | Where-Object { $_.Code -ceq $Code -and ($Role -eq '' -or $_.Role -eq $Role) }).Count -eq 0) { throw ('ausente: ' + $Code + ' ' + $Role + ' | presentes: ' + (Get-Codes $Plan)) }
}
function Get-File { param($Plan, [string]$Role, [string]$Path) return @($Plan.Files | Where-Object { $_.Role -eq $Role -and $_.Path -eq $Path })[0] }
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

# Estado completo da fixture, incluindo .git (indice, refs, config, logs, objetos):
# entradas, atributos e, para arquivos, tamanho, mtime e SHA-256. O mtime de
# diretorios fica fora (atualizacao tardia do NTFS); criacoes e remocoes de
# entradas continuam detectadas.
function Get-Snapshot {
    param([string]$Path)
    return ((@(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { $_.FullName + '|dir|' + [int]$_.Attributes }
        else { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks + '|' + [int]$_.Attributes + '|' + (Get-Sha256Hex ([IO.File]::ReadAllBytes($_.FullName))) }
    })) -join "`n")
}

function Assert-SameSnapshot {
    param([string]$Before, [string]$After)
    if ($Before -ceq $After) { return }
    $old = $Before.Split([char]10); $new = $After.Split([char]10)
    $diff = @(@($old | Where-Object { $new -cnotcontains $_ } | ForEach-Object { '- ' + $_ }) + @($new | Where-Object { $old -cnotcontains $_ } | ForEach-Object { '+ ' + $_ }))
    throw ('fixture alterada pelo Plan: ' + ($diff -join ' || '))
}

# Git somente para preparar fixtures. Identidade ficticia e hooks desativados
# apenas neste processo; nada e gravado em configuracao global ou de sistema.
function Invoke-FixtureGit {
    param([string]$Directory, [string[]]$Arguments)
    $environment = @{
        GIT_AUTHOR_NAME = 'Fixture'; GIT_AUTHOR_EMAIL = 'fixture@example.invalid'; GIT_AUTHOR_DATE = '2026-01-01T00:00:00Z'
        GIT_COMMITTER_NAME = 'Fixture'; GIT_COMMITTER_EMAIL = 'fixture@example.invalid'; GIT_COMMITTER_DATE = '2026-01-01T00:00:00Z'
        GIT_TERMINAL_PROMPT = '0'
    }
    # gc.auto e maintenance.auto desligados: a preparacao nao deixa processos em
    # segundo plano (o executor recusa descendentes que persistem apos a chamada).
    $all = @('-c', ('core.hooksPath=' + $script:NoHooks), '-c', 'commit.gpgsign=false', '-c', 'gc.auto=0', '-c', 'maintenance.auto=false') + $Arguments
    $result = InModule { param($p, $a, $d, $e) Invoke-MaNativeProcess -FilePath $p -Arguments $a -WorkingDirectory $d -Environment $e } @($GitExe, $all, $Directory, $environment)
    if ($result.ExitCode -ne 0) { throw ('git de fixture falhou (' + ($Arguments -join ' ') + '): ' + $result.StdErr) }
    return ([string]$result.StdOut).Trim()
}

function New-GitScenario {
    param([switch]$Bare)
    $root = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ma-plan-int-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $script:FixtureRoots.Add($root)
    $script:NoHooks = [IO.Path]::Combine($root, 'sem-hooks')
    [void][IO.Directory]::CreateDirectory($script:NoHooks)
    $workspace = [IO.Path]::Combine($root, 'ws')
    [void][IO.Directory]::CreateDirectory($workspace)
    $package = New-FixturePackage $root
    $config = [IO.Path]::Combine($root, 'multiagente.config.json')
    Write-FixtureFile $config $Utf8.GetBytes('{"schemaVersion":"1.0","project":{"name":"Projeto Demo","slug":"demo"},"repository":{"url":"' + $Url + '"},"workspace":{"parentDirectory":' + ($workspace | ConvertTo-Json) + '}}')
    $model = Read-MaConfiguration -LiteralPath $config -SchemaPath ([IO.Path]::Combine($package, 'schema', 'project.schema.json'))
    $rendered = Get-MaRenderedFiles -PackageRoot $package -Configuration $model -DistributionVersion '0.0.0-integracao'
    return [pscustomobject]@{ Root = $root; Workspace = $workspace; Package = $package; Config = $config; Model = $model; Rendered = $rendered; Coordination = $model.Worktrees.coordination }
}

function Initialize-Coordination {
    param($Scenario, [switch]$NoCommit, [switch]$Governance, [byte[]]$Readme = $null)
    $path = $Scenario.Coordination
    [void][IO.Directory]::CreateDirectory($path)
    [void](Invoke-FixtureGit $path @('init', '-q', '-b', 'main'))
    [void](Invoke-FixtureGit $path @('remote', 'add', 'origin', $Url))
    if ($NoCommit) { return }
    Write-FixtureFile ([IO.Path]::Combine($path, 'app.txt')) $Utf8.GetBytes("aplicacao`n")
    if ($Governance) { Write-Governed $path $Scenario.Rendered }
    if ($null -ne $Readme) { Write-FixtureFile ([IO.Path]::Combine($path, 'README.md')) $Readme }
    Save-Commit $path 'inicial'
}

function Write-Governed {
    param([string]$Directory, [object[]]$Rendered)
    foreach ($file in $Rendered) { Write-FixtureFile ([IO.Path]::Combine($Directory, $file.Path.Replace('/', '\'))) $file.Bytes }
}

# Grava modos explicitamente: o Windows nao tem bit executavel no sistema de arquivos.
function Save-Commit {
    param([string]$Directory, [string]$Message, [switch]$HookMode644)
    [void](Invoke-FixtureGit $Directory @('add', '-A'))
    foreach ($hook in @('.githooks/pre-commit', '.githooks/pre-push')) {
        if ([IO.File]::Exists([IO.Path]::Combine($Directory, $hook.Replace('/', '\')))) {
            $flag = '--chmod=+x'; if ($HookMode644) { $flag = '--chmod=-x' }
            [void](Invoke-FixtureGit $Directory @('update-index', $flag, '--', $hook))
        }
    }
    [void](Invoke-FixtureGit $Directory @('commit', '-q', '-m', $Message))
}

function Add-Worktree {
    param($Scenario, [string]$Role, [string]$Branch = '', [string]$Path = '')
    if (-not $Branch) { $Branch = $Scenario.Model.Branches[$Role] }
    if (-not $Path) { $Path = $Scenario.Model.Worktrees[$Role] }
    [void](Invoke-FixtureGit $Scenario.Coordination @('worktree', 'add', '-q', '-b', $Branch, $Path, 'HEAD'))
    return $Path
}

function Add-AllWorktrees { param($Scenario) foreach ($role in @('maintenance', 'codex', 'claude')) { [void](Add-Worktree $Scenario $role) } }

# Executa o Plan real e exige que a fixture inteira permaneca identica.
function Invoke-ReadOnlyPlan {
    param($Scenario, [string]$BaseCommit = '')
    $before = Get-Snapshot $Scenario.Root
    $plan = Invoke-MaPlan -ConfigPath $Scenario.Config -PackageRoot $Scenario.Package -BaseCommit $BaseCommit
    Assert-SameSnapshot $before (Get-Snapshot $Scenario.Root)
    Assert-Equal $false $plan.Modified
    return $plan
}

# --- Casos ------------------------------------------------------------------------------

Write-Output ('PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
InModule { $script:MaGitInvoker = $null }

# Remove deste processo de teste (e de seus filhos) as variaveis que o Plan trata
# como redirecionamento; o bloqueio correspondente e coberto pela suite unitaria.
$overrideNames = InModule { $script:MaGitOverrideVariables }
$SavedGitEnvironment = [ordered]@{}
foreach ($variable in @(Get-ChildItem Env:)) {
    if ($variable.Name -in $overrideNames -or $variable.Name -match '\AGIT_CONFIG_(?:KEY|VALUE)_[0-9]+\z') {
        $SavedGitEnvironment[$variable.Name] = $variable.Value
        [Environment]::SetEnvironmentVariable($variable.Name, [NullString]::Value)
    }
}
if ($SavedGitEnvironment.Count -gt 0) { Write-Output ('Ambiente: removidas deste processo de teste: ' + (@($SavedGitEnvironment.Keys) -join ', ')) }

# Pre-requisitos: sem Git suportado ou sem Job Object, nenhum caso e executado
# e a suite termina com codigo 2 (nao aprovada).
$missing = New-Object System.Collections.Generic.List[string]
if (-not $GitExe) { $missing.Add('Git nao localizado no PATH') }
else {
    $versionText = [string](& $GitExe --version 2>$null)
    Write-Output ('Pre-requisito Git: ' + $GitExe + ' ' + $versionText)
    $versionMatch = [regex]::Match($versionText, '([0-9]+)\.([0-9]+)\.([0-9]+)')
    if (-not $versionMatch.Success -or (New-Object Version ([int]$versionMatch.Groups[1].Value), ([int]$versionMatch.Groups[2].Value), ([int]$versionMatch.Groups[3].Value)) -lt (New-Object Version 2, 44, 0)) { $missing.Add('Git >= 2.44') }
    try {
        [void](InModule { param($p) Invoke-MaNativeProcess -FilePath $p -Arguments @('--version') -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMilliseconds 30000 } @($GitExe))
        Write-Output 'Pre-requisito Job: contencao em Job Object disponivel'
    } catch { $missing.Add('Job Object (' + $_.Exception.Message + ')') }
}
if ($missing.Count -gt 0) {
    foreach ($item in $missing) { Write-Output ('  [PRE-REQ] ausente: ' + $item) }
    Write-Output 'Resultado: 0 aprovados, 0 falhas; suite nao executada por pre-requisito ausente'
    foreach ($name in $SavedGitEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$SavedGitEnvironment[$name]) }
    exit 2
}
try {
    Write-Output 'Pacote'
    It 'pacote de fixture integro e renderizacao com templates reais' {
        $s = New-GitScenario
        $r = Test-MaPackageIntegrity $s.Package
        Assert-True $r.Valid ((@($r.Issues | ForEach-Object { $_.Code + ' ' + $_.Path })) -join '; ')
        Assert-Equal 11 $s.Rendered.Count
    }

    Write-Output 'Repositorio normal'
    It 'repositorio com commit inicial sem governanca: destinos ausentes, Sucesso' {
        $s = New-GitScenario; Initialize-Coordination $s
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
        Assert-Equal 11 @($plan.Files | Where-Object { $_.Role -eq 'coordination' -and $_.Classification -eq 'Ausente' }).Count
        Assert-True (@($plan.Actions | Where-Object { $_.Role -eq 'maintenance' -and $_.Description -like 'Criar worktree*' }).Count -eq 1) 'manutencao prevista'
        Assert-Equal 'Existente' (@($plan.Environments | Where-Object { $_.Role -eq 'coordination' })[0].State)
    }
    It 'repositorio com governanca integrada: onze destinos identicos' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
        Assert-Equal 11 @($plan.Files | Where-Object { $_.Classification -eq 'Identico' }).Count
    }
    It 'BaseCommit presente e ausente localmente' {
        $s = New-GitScenario; Initialize-Coordination $s
        $head = Invoke-FixtureGit $s.Coordination @('rev-parse', 'HEAD')
        $plan = Invoke-ReadOnlyPlan $s $head
        Assert-Equal 'presente localmente como commit; autorizacao nao verificada' $plan.Evidence.BaseCommit
        $plan = Invoke-ReadOnlyPlan $s ('0123456789' * 4)
        Assert-HasIssue $plan 'MA_BASECOMMIT_NOT_LOCAL'
    }
    It 'repositorio sem commit bloqueia (AC23)' {
        $s = New-GitScenario; Initialize-Coordination $s -NoCommit
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-HasIssue $plan 'MA_REPOSITORY_NO_COMMIT' 'coordination'
    }
    It 'HEAD destacado bloqueia' {
        $s = New-GitScenario; Initialize-Coordination $s
        [void](Invoke-FixtureGit $s.Coordination @('checkout', '-q', '--detach'))
        Assert-HasIssue (Invoke-ReadOnlyPlan $s) 'MA_ENV_DETACHED_HEAD' 'coordination'
    }
    It 'origin divergente e origin ausente bloqueiam' {
        $s = New-GitScenario; Initialize-Coordination $s
        [void](Invoke-FixtureGit $s.Coordination @('remote', 'set-url', 'origin', 'https://example.invalid/org/outro.git'))
        Assert-HasIssue (Invoke-ReadOnlyPlan $s) 'MA_REMOTE_ORIGIN_MISMATCH'
        [void](Invoke-FixtureGit $s.Coordination @('remote', 'remove', 'origin'))
        Assert-HasIssue (Invoke-ReadOnlyPlan $s) 'MA_REMOTE_ORIGIN_MISSING'
    }
    It 'clone raso bloqueia' {
        $s = New-GitScenario
        $source = [IO.Path]::Combine($s.Root, 'origem')
        [void][IO.Directory]::CreateDirectory($source)
        [void](Invoke-FixtureGit $source @('init', '-q', '-b', 'main'))
        foreach ($n in 1..2) { Write-FixtureFile ([IO.Path]::Combine($source, 'f.txt')) $Utf8.GetBytes("v$n`n"); Save-Commit $source "c$n" }
        [void](Invoke-FixtureGit $s.Workspace @('clone', '-q', '--depth', '1', ('file:///' + $source.Replace('\', '/')), $s.Coordination))
        [void](Invoke-FixtureGit $s.Coordination @('remote', 'set-url', 'origin', $Url))
        Assert-HasIssue (Invoke-ReadOnlyPlan $s) 'MA_ENV_SHALLOW' 'coordination'
    }

    Write-Output 'Worktrees vinculados'
    It 'quatro ambientes completos e identicos, com core.autocrlf=true do sistema' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance; Add-AllWorktrees $s
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
        Assert-Equal 44 @($plan.Files | Where-Object { $_.Classification -eq 'Identico' }).Count
        Assert-Equal 0 @($plan.Actions | Where-Object { $_.Description -like 'Criar worktree*' -or $_.Description -like 'Clonar*' }).Count
        foreach ($e in $plan.Environments) { Assert-Equal 'Existente' $e.State $e.Role; Assert-Equal $e.ExpectedBranch $e.Branch $e.Role }
    }
    It 'manutencao preparada e nao commitada e reconhecida (AC10)' {
        $s = New-GitScenario; Initialize-Coordination $s
        $maintenance = Add-Worktree $s 'maintenance'
        Write-Governed $maintenance $s.Rendered
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
        Assert-Equal 11 @($plan.Files | Where-Object { $_.Role -eq 'maintenance' -and $_.Classification -eq 'PreparadoNaoCommitado' }).Count
        Assert-Equal 0 @($plan.Actions | Where-Object { $_.Role -eq 'maintenance' }).Count
    }
    It 'manutencao parcialmente preparada preve somente os ausentes' {
        $s = New-GitScenario; Initialize-Coordination $s
        $maintenance = Add-Worktree $s 'maintenance'
        Write-Governed $maintenance @($s.Rendered | Where-Object { $_.Path -like 'docs/*' })
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
        Assert-Equal 7 @($plan.Actions | Where-Object { $_.Role -eq 'maintenance' -and $_.Description -like 'Gerar *' }).Count
    }
    It 'worktree vinculado em branch diferente da configurada bloqueia' {
        $s = New-GitScenario; Initialize-Coordination $s
        [void](Add-Worktree $s 'codex' 'outra/branch')
        Assert-HasIssue (Invoke-ReadOnlyPlan $s) 'MA_ENV_BRANCH_MISMATCH' 'codex'
    }
    It 'clone independente no lugar de worktree vinculado bloqueia' {
        $s = New-GitScenario; Initialize-Coordination $s
        $claude = $s.Model.Worktrees.claude
        [void][IO.Directory]::CreateDirectory($claude)
        [void](Invoke-FixtureGit $claude @('init', '-q', '-b', 'feature/claude'))
        Assert-HasIssue (Invoke-ReadOnlyPlan $s) 'MA_ENV_NOT_LINKED_WORKTREE' 'claude'
    }

    Write-Output 'Alcance'
    It 'branch configurada ocupada por worktree fora do previsto bloqueia' {
        $s = New-GitScenario; Initialize-Coordination $s
        [void](Add-Worktree $s 'codex' '' ([IO.Path]::Combine($s.Root, 'outro-lugar')))
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-HasIssue $plan 'MA_BRANCH_OCCUPIED' 'codex'
        Assert-HasIssue $plan 'MA_WORKTREE_UNEXPECTED'
    }
    It 'branch de um papel ocupada no diretorio de outro papel bloqueia' {
        $s = New-GitScenario; Initialize-Coordination $s
        [void](Add-Worktree $s 'codex' 'feature/claude')
        $plan = Invoke-ReadOnlyPlan $s
        Assert-HasIssue $plan 'MA_BRANCH_OCCUPIED' 'claude'
        Assert-HasIssue $plan 'MA_ENV_BRANCH_MISMATCH' 'codex'
    }
    It 'quinto worktree bloqueia (AC17)' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance; Add-AllWorktrees $s
        [void](Add-Worktree $s 'codex' 'quinto' ([IO.Path]::Combine($s.Workspace, 'demo-quinto')))
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-HasIssue $plan 'MA_WORKTREE_UNEXPECTED'
    }
    It 'registro de worktree indisponivel bloqueia' {
        $s = New-GitScenario; Initialize-Coordination $s
        $codex = Add-Worktree $s 'codex'
        [IO.Directory]::Delete($codex, $true)
        $plan = Invoke-ReadOnlyPlan $s
        Assert-HasIssue $plan 'MA_WORKTREE_PRUNABLE'
        Assert-Equal 'Ausente' (@($plan.Environments | Where-Object { $_.Role -eq 'codex' })[0].State)
    }

    Write-Output 'Divergencias de conteudo'
    It 'checkout divergente com HEAD e indice corretos (AC29)' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, 'CLAUDE.md')) $Utf8.GetBytes("alterado`n")
        $plan = Invoke-ReadOnlyPlan $s
        $file = Get-File $plan 'coordination' 'CLAUDE.md'
        Assert-Equal 'Conflitante' $file.Classification
        Assert-Equal 'checkout: bytes divergentes' $file.Reason
        Assert-Equal 'Bloqueado' $plan.Status
    }
    It 'checkout com CRLF e mesmo texto e divergencia exata, sem normalizacao' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        $agents = @($s.Rendered | Where-Object { $_.Path -eq 'AGENTS.md' })[0]
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, 'AGENTS.md')) $Utf8.GetBytes($Utf8.GetString($agents.Bytes).Replace("`n", "`r`n"))
        Assert-Equal 'checkout: bytes divergentes' (Get-File (Invoke-ReadOnlyPlan $s) 'coordination' 'AGENTS.md').Reason
    }
    It 'indice divergente com checkout e HEAD corretos' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        $path = [IO.Path]::Combine($s.Coordination, 'docs', 'agentes', 'revisao.md')
        $original = [IO.File]::ReadAllBytes($path)
        Write-FixtureFile $path $Utf8.GetBytes("preparado no indice`n")
        [void](Invoke-FixtureGit $s.Coordination @('add', '--', 'docs/agentes/revisao.md'))
        Write-FixtureFile $path $original
        $file = Get-File (Invoke-ReadOnlyPlan $s) 'coordination' 'docs/agentes/revisao.md'
        Assert-Equal 'Conflitante' $file.Classification
        Assert-Equal 'indice: blob divergente' $file.Reason
    }
    It 'modo do hook alterado somente no indice' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        [void](Invoke-FixtureGit $s.Coordination @('update-index', '--chmod=-x', '--', '.githooks/pre-push'))
        Assert-Equal 'indice: modo 100644' (Get-File (Invoke-ReadOnlyPlan $s) 'coordination' '.githooks/pre-push').Reason
    }
    It 'hook commitado com 100644 e rejeitado mesmo com bytes corretos' {
        $s = New-GitScenario
        $path = $s.Coordination
        [void][IO.Directory]::CreateDirectory($path)
        [void](Invoke-FixtureGit $path @('init', '-q', '-b', 'main')); [void](Invoke-FixtureGit $path @('remote', 'add', 'origin', $Url))
        Write-Governed $path $s.Rendered
        Save-Commit $path 'modo errado' -HookMode644
        $reason = (Get-File (Invoke-ReadOnlyPlan $s) 'coordination' '.githooks/pre-commit').Reason
        Assert-True ($reason -like '*HEAD: tipo ou modo 100644 blob*' -and $reason -like '*indice: modo 100644*') $reason
    }
    It 'link simbolico commitado em caminho governado e rejeitado' {
        $s = New-GitScenario; Initialize-Coordination $s
        $blob = Invoke-FixtureGit $s.Coordination @('hash-object', '-w', '--', 'app.txt')
        [void](Invoke-FixtureGit $s.Coordination @('update-index', '--add', '--cacheinfo', ('120000,' + $blob + ',CLAUDE.md')))
        [void](Invoke-FixtureGit $s.Coordination @('commit', '-q', '-m', 'link'))
        $reason = (Get-File (Invoke-ReadOnlyPlan $s) 'coordination' 'CLAUDE.md').Reason
        Assert-True ($reason -like '*HEAD: tipo ou modo 120000*') $reason
    }
    It 'README criado pelo servidor e diferente e conflito (AC09, AC24)' {
        $s = New-GitScenario; Initialize-Coordination $s -Readme ($Utf8.GetBytes("# demo`n"))
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-HasIssue $plan 'MA_FILE_CONFLICT' 'coordination'
        Assert-Equal 'Conflitante' (Get-File $plan 'coordination' 'README.md').Classification
        Assert-Equal 'Ausente' (Get-File $plan 'coordination' 'AGENTS.md').Classification
    }
    It 'conflito na manutencao herdado da base bloqueia a geracao' {
        $s = New-GitScenario; Initialize-Coordination $s -Readme ($Utf8.GetBytes("# demo`n"))
        [void](Add-Worktree $s 'maintenance')
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Conflitante' (Get-File $plan 'maintenance' 'README.md').Classification
    }
    It 'entrada inesperada commitada e no checkout de .githooks e detectada' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.multiagente', 'extra.json')) $Utf8.GetBytes("{}`n")
        Save-Commit $s.Coordination 'extra'
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.githooks', 'post-merge')) $Utf8.GetBytes("#!/bin/sh`n")
        $paths = @((Invoke-ReadOnlyPlan $s).Issues | Where-Object { $_.Code -eq 'MA_FILE_UNEXPECTED_ENTRY' } | ForEach-Object { $_.Path })
        Assert-True ($paths -contains '.multiagente/extra.json') ('HEAD ' + ($paths -join ','))
        Assert-True ($paths -contains '.githooks/post-merge') ('checkout ' + ($paths -join ','))
    }
    It 'arquivo removido do checkout mas presente no HEAD e conflito' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        [IO.File]::Delete([IO.Path]::Combine($s.Coordination, 'docs', 'agentes', 'manutencao.md'))
        Assert-Equal 'removido do checkout' (Get-File (Invoke-ReadOnlyPlan $s) 'coordination' 'docs/agentes/manutencao.md').Reason
    }
    It 'governanca nao commitada na coordenacao e conflito' {
        $s = New-GitScenario; Initialize-Coordination $s
        Write-Governed $s.Coordination @($s.Rendered | Where-Object { $_.Path -eq 'CLAUDE.md' })
        Assert-Equal 'arquivo governado nao commitado fora da manutencao' (Get-File (Invoke-ReadOnlyPlan $s) 'coordination' 'CLAUDE.md').Reason
    }

    Write-Output 'Objetos Git ausentes, ilegiveis ou corrompidos'
    # Objetos soltos ficam somente leitura no Windows; libera antes de alterar.
    function Get-LooseObjectPath {
        param($Scenario, [string]$Spec)
        $id = Invoke-FixtureGit $Scenario.Coordination @('rev-parse', $Spec)
        $path = [IO.Path]::Combine($Scenario.Coordination, '.git', 'objects', $id.Substring(0, 2), $id.Substring(2))
        Assert-True ([IO.File]::Exists($path)) ('objeto solto inexistente: ' + $id)
        [IO.File]::SetAttributes($path, [IO.FileAttributes]::Normal)
        return $path
    }
    It 'objeto do blob removido do banco local: bloqueio sem busca remota' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        [IO.File]::Delete((Get-LooseObjectPath $s 'HEAD:AGENTS.md'))
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-Equal 2 @($plan.Issues | Where-Object { $_.Code -eq 'MA_GIT_OBJECT_MISSING' -and $_.Path -eq 'AGENTS.md' }).Count (Get-Codes $plan)
        Assert-Equal 'Inconclusivo' (Get-File $plan 'coordination' 'AGENTS.md').Classification
    }
    It 'objeto com bytes invalidos (zlib quebrado): ilegivel' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        [IO.File]::WriteAllBytes((Get-LooseObjectPath $s 'HEAD:README.md'), $Utf8.GetBytes('lixo'))
        $plan = Invoke-ReadOnlyPlan $s
        Assert-HasIssue $plan 'MA_GIT_OBJECT_UNREADABLE' 'coordination'
        Assert-Equal 'Inconclusivo' (Get-File $plan 'coordination' 'README.md').Classification
    }
    It 'objeto substituido pelo conteudo de outro objeto valido: rejeitado' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        $target = Get-LooseObjectPath $s 'HEAD:CLAUDE.md'
        [IO.File]::Copy((Get-LooseObjectPath $s 'HEAD:app.txt'), $target, $true)
        $plan = Invoke-ReadOnlyPlan $s
        $codes = @($plan.Issues | Where-Object { $_.Path -eq 'CLAUDE.md' -and $_.Code -like 'MA_GIT_OBJECT_*' } | ForEach-Object { $_.Code } | Sort-Object -Unique)
        # O Git 2.52 entrega os bytes trocados sem erro; so o recalculo do id detecta.
        Assert-Equal 'MA_GIT_OBJECT_CORRUPT' ($codes -join ',')
        Assert-Equal 'Inconclusivo' (Get-File $plan 'coordination' 'CLAUDE.md').Classification
        Assert-Equal 'Bloqueado' $plan.Status
    }
    It 'ausencia comprovada e ilegibilidade sao distinguidas no mesmo repositorio' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        [IO.File]::Delete((Get-LooseObjectPath $s 'HEAD:AGENTS.md'))
        [IO.File]::WriteAllBytes((Get-LooseObjectPath $s 'HEAD:README.md'), $Utf8.GetBytes('lixo'))
        $plan = Invoke-ReadOnlyPlan $s
        $byPath = @{}
        foreach ($issue in @($plan.Issues | Where-Object { $_.Code -like 'MA_GIT_OBJECT_*' })) { $byPath[$issue.Path] = $issue.Code }
        Assert-Equal 'MA_GIT_OBJECT_MISSING' $byPath['AGENTS.md'] (Get-Codes $plan)
        Assert-Equal 'MA_GIT_OBJECT_UNREADABLE' $byPath['README.md'] (Get-Codes $plan)
        Assert-Equal 0 @($plan.Issues | Where-Object { $_.Code -eq 'MA_GIT_OBJECT_UNVERIFIED' }).Count (Get-Codes $plan)
    }
    It 'entrada do indice apontando para objeto que nao e blob: tipo divergente' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        $commit = Invoke-FixtureGit $s.Coordination @('rev-parse', 'HEAD')
        [void](Invoke-FixtureGit $s.Coordination @('update-index', '--cacheinfo', ('100644,' + $commit + ',AGENTS.md')))
        $plan = Invoke-ReadOnlyPlan $s
        Assert-HasIssue $plan 'MA_GIT_OBJECT_TYPE_MISMATCH' 'coordination'
        Assert-Equal 'Bloqueado' $plan.Status
    }
    It 'objetos integros nos quatro ambientes mantem Sucesso' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance; Add-AllWorktrees $s
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 0 @($plan.Issues | Where-Object { $_.Code -like 'MA_GIT_OBJECT_*' }).Count (Get-Codes $plan)
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
    }

    Write-Output 'Hooks e configuracao'
    It 'core.hooksPath local e hook ativo no diretorio padrao sao relatados sem alteracao' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'core.hooksPath', 'outro-dir'))
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.git', 'hooks', 'pre-commit')) $Utf8.GetBytes("#!/bin/sh`nexit 0`n")
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, 'outro-dir', 'pre-push')) $Utf8.GetBytes("#!/bin/sh`nexit 0`n")
        $plan = Invoke-ReadOnlyPlan $s
        $hooks = @($plan.Issues | Where-Object { $_.Code -eq 'MA_HOOKS_PATH_PRESENT' })[0]
        Assert-True ($hooks.Detail -like '*local=outro-dir*') $hooks.Detail
        Assert-HasIssue $plan 'MA_HOOKS_DEFAULT_ACTIVE' 'coordination'
        $effective = @($plan.Issues | Where-Object { $_.Code -eq 'MA_HOOKS_EFFECTIVE_ACTIVE' })
        Assert-Equal 1 $effective.Count (Get-Codes $plan)
        Assert-Equal 'pre-push' $effective[0].Detail
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
        Assert-Equal 'outro-dir' (Invoke-FixtureGit $s.Coordination @('config', '--local', '--get', 'core.hooksPath'))
    }

    It 'amostras e auxiliares nao sao hooks; nomes reconhecidos, .exe e caixa diferente sao' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        $hooks = [IO.Path]::Combine($s.Coordination, '.git', 'hooks')
        foreach ($name in @('README.txt', 'helper.sh', 'pre-commit.bak')) { Write-FixtureFile ([IO.Path]::Combine($hooks, $name)) $Utf8.GetBytes("x`n") }
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 0 @($plan.Issues | Where-Object { $_.Code -like 'MA_HOOKS_*_ACTIVE' }).Count (Get-Codes $plan)
        $auxiliary = @(@($plan.Environments | Where-Object { $_.Role -eq 'coordination' })[0].AuxiliaryHookFiles)
        Assert-True ($auxiliary -contains 'pre-commit.sample' -and $auxiliary -contains 'helper.sh' -and $auxiliary -contains 'pre-commit.bak') ($auxiliary -join ',')
        Write-FixtureFile ([IO.Path]::Combine($hooks, 'commit-msg.exe')) $Utf8.GetBytes("x`n")
        Write-FixtureFile ([IO.Path]::Combine($hooks, 'Pre-Push')) $Utf8.GetBytes("#!/bin/sh`n")
        $active = @((Invoke-ReadOnlyPlan $s).Issues | Where-Object { $_.Code -eq 'MA_HOOKS_DEFAULT_ACTIVE' })
        Assert-Equal 1 $active.Count
        Assert-Equal 'commit-msg.exe, Pre-Push' $active[0].Detail
    }
    It 'core.hooksPath=.githooks nos quatro ambientes: hooks governados nao contam como preexistentes' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance; Add-AllWorktrees $s
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'core.hooksPath', '.githooks'))
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 0 @($plan.Issues | Where-Object { $_.Code -like 'MA_HOOKS_*_ACTIVE' }).Count (Get-Codes $plan)
        Assert-Equal 4 @($plan.Issues | Where-Object { $_.Code -eq 'MA_HOOKS_PATH_PRESENT' }).Count
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
        Assert-Equal 44 @($plan.Files | Where-Object { $_.Classification -eq 'Identico' }).Count
    }
    It 'diretorio efetivo fora da .githooks continua inspecionado' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance
        $external = [IO.Path]::Combine($s.Root, 'hooks externos')
        Write-FixtureFile ([IO.Path]::Combine($external, 'pre-commit')) $Utf8.GetBytes("#!/bin/sh`n")
        Write-FixtureFile ([IO.Path]::Combine($external, 'notas.md')) $Utf8.GetBytes("x`n")
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'core.hooksPath', $external.Replace('\', '/')))
        $effective = @((Invoke-ReadOnlyPlan $s).Issues | Where-Object { $_.Code -eq 'MA_HOOKS_EFFECTIVE_ACTIVE' })
        Assert-Equal 1 $effective.Count
        Assert-Equal 'pre-commit' $effective[0].Detail
        Assert-True ($effective[0].Path.Equals($external, [StringComparison]::OrdinalIgnoreCase)) $effective[0].Path
    }

    Write-Output 'Somente leitura e ponto de entrada'
    It 'indice, refs e config dos quatro ambientes inalterados apos Plan com checkout sujo' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance; Add-AllWorktrees $s
        # Arquivo com mtime alterado e conteudo igual: um refresh do indice regravaria .git/index.
        $agents = [IO.Path]::Combine($s.Coordination, 'AGENTS.md')
        [IO.File]::SetLastWriteTimeUtc($agents, [DateTime]::UtcNow.AddMinutes(5))
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.codex, 'trabalho.txt')) $Utf8.GetBytes("nao rastreado`n")
        $indexes = @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($s.Coordination, '.git')) -Recurse -Force -File | Where-Object { $_.Name -eq 'index' })
        Assert-Equal 4 $indexes.Count 'quatro indices'
        $plan = Invoke-ReadOnlyPlan $s
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
    }
    It 'GIT_TRACE* e trace2 apontando para o repositorio nao geram gravacao durante o Plan' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance; Add-AllWorktrees $s
        $names = @('GIT_TRACE', 'GIT_TRACE_SETUP', 'GIT_TRACE_PERFORMANCE', 'GIT_TRACE_PACK_ACCESS', 'GIT_TRACE2', 'GIT_TRACE2_EVENT', 'GIT_TRACE2_PERF')
        $saved = @{}; foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            # Controle: a variavel faz o Git gravar quando nao e neutralizada.
            $control = [IO.Path]::Combine($s.Root, 'controle-trace.log')
            [Environment]::SetEnvironmentVariable('GIT_TRACE', $control)
            [void](InModule { param($g, $wd) Invoke-MaNativeProcess -FilePath $g -Arguments @('--version') -WorkingDirectory $wd } @($GitExe, $s.Root))
            Assert-True ([IO.File]::Exists($control)) 'controle: GIT_TRACE nao gravou'
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, [IO.Path]::Combine($s.Coordination, ($name.ToLowerInvariant() + '.log'))) }
            $plan = Invoke-ReadOnlyPlan $s
        } finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $saved[$name]) { [NullString]::Value } else { $saved[$name] })) } }
        Assert-Equal 'Sucesso' $plan.Status (Get-Codes $plan)
    }
    It 'ponto de entrada do pacote integro: codigo 0 sem modificacao' {
        $s = New-GitScenario; Initialize-Coordination $s -Governance; Add-AllWorktrees $s
        $before = Get-Snapshot $s.Root
        $ErrorActionPreference = 'Continue'
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File ([IO.Path]::Combine($s.Package, 'scripts', 'Install-MultiAgentProject.ps1')) -Config $s.Config 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $text = $output | Out-String
        Assert-Equal 0 $code $text
        Assert-True ($text.Contains('Resultado: Sucesso')) $text
        Assert-True ($text.Contains('Nenhuma modificacao foi realizada.')) 'rodape'
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'ponto de entrada com conflito: codigo 3 sem modificacao' {
        $s = New-GitScenario; Initialize-Coordination $s -Readme ($Utf8.GetBytes("# demo`n"))
        $before = Get-Snapshot $s.Root
        $ErrorActionPreference = 'Continue'
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File ([IO.Path]::Combine($s.Package, 'scripts', 'Install-MultiAgentProject.ps1')) -Config $s.Config 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        Assert-Equal 3 $code ($output | Out-String)
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
} finally {
    foreach ($name in $SavedGitEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$SavedGitEnvironment[$name]) }
    foreach ($root in $script:FixtureRoots) {
        if ([IO.Directory]::Exists($root)) {
            # Objetos Git sao somente leitura no Windows; liberar antes de remover a fixture.
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
