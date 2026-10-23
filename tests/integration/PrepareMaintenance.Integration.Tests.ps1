#Requires -Version 5.1
<#
Testes de integracao e ponta a ponta da fase PrepareMaintenance com Git real.
Cada caso cria um remoto de origem, workspace, pacote e configuracao
exclusivamente em um diretorio descartavel sob o TEMP do executor, fora dos
worktrees do projeto, e o remove ao final. Nenhum caso aponta para o projeto
atual nem para repositorios de coordenacao ou manutencao reais.

O remoto configurado e ficticio (ssh://git@example.invalid/...). O clone do
instalador usa o transporte SSH do proprio Git, permitido pela politica de
protocolos, com um ssh ficticio local no lugar do cliente SSH fixado da
instalacao: sem rede, ele atende somente o upload-pack do caminho ficticio, no
remoto de origem da fixture, e registra cada chamada. Esse comando chega pelo
ponto de teste do modulo ($script:MaSshTestCommand), nao pela configuracao do
consumidor (core.sshCommand e recusado); outras configuracoes do consumidor
chegam por $script:MaCloneTestArguments a verificacao do transporte e ao clone.
A politica de protocolos e o PATH restrito do clone nao sao alterados. A URL
registrada no origin continua a configurada. Nenhum caso conecta a servidores:
reescritas para transportes proibidos sao recusadas antes de qualquer conexao e,
nos casos sem a verificacao previa, pelo proprio Git.
Os casos de helpers de transporte e comandos SSH usam HTTPS ou SSH em porta
local fechada (127.0.0.1:9, o SSH pelo cliente real da instalacao) e sentinelas
da fixture (scripts que so gravam um marcador e falham), postas em
GIT_EXEC_PATH, no inicio do PATH, em GIT_SSH* somente deste processo (restaurados
ao final) ou na configuracao por -c; cada caso tem controle que comprova a
sentinela.
Commits existem somente nas fixtures, criados pelo executor de testes com
identidade ficticia por variavel de processo, -c core.hooksPath=<vazio> e
-c commit.gpgsign=false apenas no processo da fixture; nenhuma configuracao
global, de sistema ou do projeto e alterada. Nenhum caso usa WMI/CIM, breakaway
de processos ou push.

Uso: powershell -NoProfile -File tests/integration/PrepareMaintenance.Integration.Tests.ps1
Codigo de saida: 0 quando todos os casos passam; 1 se algum caso falha; 2 se a
suite nao pode ser executada por pre-requisito ausente (nunca contado como aprovado).

Pre-requisitos: Git for Windows >= 2.44 no PATH e Job Object do Windows
disponivel. Variaveis Git que redirecionam repositorio ou configuracao sao
removidas apenas deste processo de teste e restauradas ao final.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PackageSource = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
$Module = Import-Module -Name ([IO.Path]::Combine($PackageSource, 'scripts', 'MultiAgentTemplate.psm1')) -Force -PassThru -DisableNameChecking
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$GitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$GitExe = $null; if ($null -ne $GitCommand) { $GitExe = $GitCommand.Path }
$Url = 'ssh://git@example.invalid/org/demo.git'
$HttpsUrl = 'https://example.invalid/org/demo.git'
# HTTPS em porta local fechada: o helper conecta e falha, sem DNS nem servidor.
$LoopbackUrl = 'https://127.0.0.1:9/org/demo.git'
$Authorization = 'registro-humano-ficticio#prepare-1'
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]

# --- Harness ------------------------------------------------------------------------

function It {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Output ('  [ok]    ' + $Name) }
    catch { $script:Failed.Add($Name + ' :: ' + $_.Exception.Message); Write-Output ('  [FALHA] ' + $Name + ' :: ' + $_.Exception.Message) }
    finally { InModule { $script:MaCloneTestArguments = @(); $script:MaSshTestCommand = $null; $script:MaGitInvoker = $null } }
}
function Assert-Equal { param($Expected, $Actual, [string]$Message = '') if (-not [object]::Equals($Expected, $Actual)) { throw ('esperado <' + $Expected + '> obtido <' + $Actual + '> ' + $Message) } }
function Assert-True { param([bool]$Condition, [string]$Message = 'condicao falsa') if (-not $Condition) { throw $Message } }
function Get-Codes { param($Result) return ((@($Result.Issues | ForEach-Object { $_.Severity + ':' + $_.Code + '@' + $_.Role + ' ' + $_.Detail })) -join ', ') }
function Assert-HasIssue {
    param($Result, [string]$Code, [string]$Role = '')
    if (@($Result.Issues | Where-Object { $_.Code -ceq $Code -and ($Role -eq '' -or $_.Role -eq $Role) }).Count -eq 0) { throw ('ausente: ' + $Code + ' ' + $Role + ' | presentes: ' + (Get-Codes $Result)) }
}
function Get-File { param($Result, [string]$Role, [string]$Path) return @($Result.Files | Where-Object { $_.Role -eq $Role -and $_.Path -eq $Path })[0] }
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

# Git somente para preparar fixtures e conferir resultados.
function Invoke-FixtureGit {
    param([string]$Directory, [string[]]$Arguments, [switch]$AllowFailure)
    $environment = @{
        GIT_AUTHOR_NAME = 'Fixture'; GIT_AUTHOR_EMAIL = 'fixture@example.invalid'; GIT_AUTHOR_DATE = '2026-01-01T00:00:00Z'
        GIT_COMMITTER_NAME = 'Fixture'; GIT_COMMITTER_EMAIL = 'fixture@example.invalid'; GIT_COMMITTER_DATE = '2026-01-01T00:00:00Z'
        GIT_TERMINAL_PROMPT = '0'
    }
    $all = @('-c', ('core.hooksPath=' + $script:NoHooks), '-c', 'commit.gpgsign=false', '-c', 'gc.auto=0', '-c', 'maintenance.auto=false') + $Arguments
    $result = InModule { param($p, $a, $d, $e) Invoke-MaNativeProcess -FilePath $p -Arguments $a -WorkingDirectory $d -Environment $e } @($GitExe, $all, $Directory, $environment)
    if ($AllowFailure) { return $result }
    if ($result.ExitCode -ne 0) { throw ('git de fixture falhou (' + ($Arguments -join ' ') + '): ' + $result.StdErr) }
    return ([string]$result.StdOut).Trim()
}

function ConvertTo-FileUrl { param([string]$Path) return ('file:///' + $Path.Replace('\', '/')) }

# Literal entre aspas simples para sh, com barras normais.
function ConvertTo-ShQuoted { param([string]$Text) return ("'" + $Text.Replace('\', '/').Replace("'", "'\''") + "'") }

# ssh ficticio, fora da raiz da fixture (os instantaneos da raiz nao mudam com o
# registro): atende somente o upload-pack de org/demo.git no remoto de origem.
# Command e o valor do ponto de teste do cliente SSH (GIT_SSH_COMMAND do clone).
function New-FixtureSsh {
    param([string]$Directory, [string]$Origin)
    [void][IO.Directory]::CreateDirectory($Directory)
    $program = [IO.Path]::Combine($Directory, 'ssh-ficticio.sh')
    $log = [IO.Path]::Combine($Directory, 'ssh.log')
    $body = "#!/bin/sh`n# Argumentos: opcoes, host e comando remoto (variante OpenSSH fixada pelo clone).`nfor last; do :; done`n" +
        "printf '%s\n' `"`$*`" >> " + (ConvertTo-ShQuoted $log) + "`n" +
        "case `"`$last`" in`n  `"git-upload-pack '/org/demo.git'`"|`"git-upload-pack 'org/demo.git'`") exec " + (ConvertTo-ShQuoted $GitExe) + ' upload-pack ' + (ConvertTo-ShQuoted $Origin) + " ;;`nesac`n" +
        "echo `"ssh ficticio: comando recusado: `$last`" >&2`nexit 1`n"
    Write-FixtureFile $program ([Text.Encoding]::ASCII.GetBytes($body))
    $shell = InModule { param($g) Find-MaShell $g } @($GitExe)
    return [pscustomobject]@{ Log = $log; Command = ((ConvertTo-ShQuoted $shell) + ' ' + (ConvertTo-ShQuoted $program)) }
}
# Registro esperado de um upload-pack pelo ssh ficticio (variante OpenSSH, protocolo v2).
$SshCall = "-o SendEnv=GIT_PROTOCOL git@example.invalid git-upload-pack '/org/demo.git'"

function Get-SshCalls { param($Scenario) if (-not [IO.File]::Exists($Scenario.Ssh.Log)) { return @() } return @([IO.File]::ReadAllText($Scenario.Ssh.Log).Replace("`r", '').TrimEnd("`n").Split([char]10)) }

function New-PrepareScenario {
    param([string]$WorkspaceName = 'ws', [switch]$EmptyOrigin, [byte[]]$Readme = $null, [switch]$Governance, [string]$Gitignore = '', [hashtable]$SeedFiles = @{}, [string]$RepositoryUrl = $Url)
    $root = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ma-prep-int-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $script:FixtureRoots.Add($root)
    $script:FixtureRoots.Add($root + '-ssh')
    $script:NoHooks = [IO.Path]::Combine($root, 'sem-hooks')
    [void][IO.Directory]::CreateDirectory($script:NoHooks)
    $workspace = [IO.Path]::Combine($root, $WorkspaceName)
    [void][IO.Directory]::CreateDirectory($workspace)
    $package = New-FixturePackage $root
    $config = [IO.Path]::Combine($root, 'multiagente.config.json')
    Write-FixtureFile $config $Utf8.GetBytes('{"schemaVersion":"1.0","project":{"name":"Projeto Demo","slug":"demo"},"repository":{"url":"' + $RepositoryUrl + '"},"workspace":{"parentDirectory":' + ($workspace | ConvertTo-Json) + '}}')
    $model = Read-MaConfiguration -LiteralPath $config -SchemaPath ([IO.Path]::Combine($package, 'schema', 'project.schema.json'))
    $rendered = Get-MaRenderedFiles -PackageRoot $package -Configuration $model -DistributionVersion '0.0.0-integracao'
    # Remoto de origem: bare, copiado por clone de um repositorio semente com o
    # commit inicial preparado fora do instalador (ou vazio).
    $origin = [IO.Path]::Combine($root, 'origem.git')
    $base = $null
    if ($EmptyOrigin) { [void](Invoke-FixtureGit $root @('init', '-q', '--bare', '-b', 'main', $origin)) }
    else {
        $seed = [IO.Path]::Combine($root, 'semente')
        [void](Invoke-FixtureGit $root @('init', '-q', '-b', 'main', $seed))
        Write-FixtureFile ([IO.Path]::Combine($seed, 'app.txt')) $Utf8.GetBytes("aplicacao`n")
        if ($null -ne $Readme) { Write-FixtureFile ([IO.Path]::Combine($seed, 'README.md')) $Readme }
        if ($Gitignore) { Write-FixtureFile ([IO.Path]::Combine($seed, '.gitignore')) $Utf8.GetBytes($Gitignore) }
        if ($Governance) { foreach ($file in $rendered) { Write-FixtureFile ([IO.Path]::Combine($seed, $file.Path.Replace('/', '\'))) $file.Bytes } }
        foreach ($relative in $SeedFiles.Keys) { Write-FixtureFile ([IO.Path]::Combine($seed, $relative.Replace('/', '\'))) $Utf8.GetBytes([string]$SeedFiles[$relative]) }
        Save-Commit $seed 'inicial'
        [void](Invoke-FixtureGit $root @('clone', '-q', '--bare', (ConvertTo-FileUrl $seed), $origin))
        $base = Invoke-FixtureGit $origin @('rev-parse', 'refs/heads/main')
    }
    return [pscustomobject]@{
        Root = $root; Workspace = $workspace; Package = $package; Config = $config; Model = $model; Rendered = $rendered
        Origin = $origin; Base = $base; Coordination = $model.Worktrees.coordination; Maintenance = $model.Worktrees.maintenance
        Ssh = (New-FixtureSsh ($root + '-ssh') $origin)
    }
}

function Save-Commit {
    param([string]$Directory, [string]$Message)
    [void](Invoke-FixtureGit $Directory @('add', '-A'))
    foreach ($hook in @('.githooks/pre-commit', '.githooks/pre-push')) {
        if ([IO.File]::Exists([IO.Path]::Combine($Directory, $hook.Replace('/', '\')))) { [void](Invoke-FixtureGit $Directory @('update-index', '--chmod=+x', '--', $hook)) }
    }
    [void](Invoke-FixtureGit $Directory @('commit', '-q', '-m', $Message))
}

# Clone de fixture (fora do instalador), com o origin apontando para a URL configurada.
function New-FixtureClone {
    param($Scenario)
    [void](Invoke-FixtureGit $Scenario.Root @('clone', '-q', (ConvertTo-FileUrl $Scenario.Origin), $Scenario.Coordination))
    [void](Invoke-FixtureGit $Scenario.Coordination @('remote', 'set-url', 'origin', $Url))
}

# ssh ficticio da fixture no clone (ponto de teste do cliente SSH) e,
# opcionalmente, outros -c como configuracao do consumidor vista pela
# verificacao do transporte e pelo clone.
function Use-FixtureOrigin {
    param($Scenario, [string[]]$Extra = @())
    InModule { param($a, $c) $script:MaCloneTestArguments = @($a); $script:MaSshTestCommand = $c } @(@($Extra), $Scenario.Ssh.Command)
}

# Git real e ambiente de transporte do clone definidos pelo contexto, como na
# fase. Sem as camadas temporarias GIT_CONFIG_SYSTEM/GLOBAL dos casos de
# transporte: o Git for Windows le a configuracao ate em --version, e uma camada
# ilegivel impediria o contexto (recusa correta, mas alheia ao caso).
function Initialize-GitTransport {
    $levels = @{}
    foreach ($name in @('GIT_CONFIG_SYSTEM', 'GIT_CONFIG_GLOBAL')) { $levels[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $null) }
    try { InModule { param($w) $saved = $script:MaGitInvoker; $script:MaGitInvoker = $null; try { [void](Get-MaGitContext -WorkingDirectory $w) } finally { $script:MaGitInvoker = $saved } } @([IO.Path]::GetTempPath()) }
    finally { foreach ($name in $levels.Keys) { [Environment]::SetEnvironmentVariable($name, $levels[$name]) } }
}

function Invoke-Prepare {
    param($Scenario, [string]$BaseCommit = '', [string]$AuthorizationReference = $Authorization, [switch]$WhatIf)
    if (-not $PSBoundParameters.ContainsKey('BaseCommit')) { $BaseCommit = [string]$Scenario.Base }
    return (Invoke-MaPrepareMaintenance -ConfigPath $Scenario.Config -PackageRoot $Scenario.Package -AuthorizationReference $AuthorizationReference -BaseCommit $BaseCommit -WhatIfRequested:$WhatIf)
}

function Assert-MaintenanceGenerated {
    param($Scenario)
    foreach ($file in $Scenario.Rendered) {
        $path = [IO.Path]::Combine($Scenario.Maintenance, $file.Path.Replace('/', '\'))
        Assert-True ([IO.File]::Exists($path)) ('ausente: ' + $file.Path)
        Assert-Equal $file.Sha256 (Get-Sha256Hex ([IO.File]::ReadAllBytes($path))) $file.Path
    }
}

# Proibicoes do contrato: nenhum commit, indice, Codex/Claude, hooks ou push.
function Assert-ContractProhibitions {
    param($Scenario, [string]$OriginBefore)
    Assert-SameSnapshot $OriginBefore (Get-Snapshot $Scenario.Origin) 'remoto de origem'
    foreach ($role in @('codex', 'claude')) { Assert-True (-not [IO.Directory]::Exists($Scenario.Model.Worktrees[$role])) ($role + ' criado') }
    if (-not [IO.Directory]::Exists($Scenario.Coordination)) { return }
    $branches = Invoke-FixtureGit $Scenario.Coordination @('for-each-ref', '--format=%(refname)', 'refs/heads/')
    Assert-True ($branches -notmatch 'feature/') ('branches de agentes criadas: ' + $branches)
    # Consulta sem o -c da fixture: todas as camadas persistentes do repositorio.
    $hooks = InModule { param($g, $wd) $script:MaGitPath = $g; Invoke-MaGit $wd @('config', '--get-all', 'core.hooksPath') } @($GitExe, $Scenario.Coordination)
    Assert-Equal 1 $hooks.ExitCode 'core.hooksPath configurado'
    Assert-Equal $Scenario.Base (Invoke-FixtureGit $Scenario.Coordination @('rev-parse', 'refs/heads/main')) 'coordenacao avancou'
    if ([IO.Directory]::Exists($Scenario.Maintenance) -and [IO.File]::Exists([IO.Path]::Combine($Scenario.Maintenance, '.git'))) {
        Assert-Equal $Scenario.Base (Invoke-FixtureGit $Scenario.Maintenance @('rev-parse', 'HEAD')) 'commit na manutencao'
        $staged = Invoke-FixtureGit $Scenario.Maintenance @('diff-index', '--cached', '--name-only', 'HEAD')
        Assert-Equal '' $staged 'indice preparado'
    }
}

# Tudo na raiz da fixture fora do workspace (remoto, semente, pacote, configuracao
# e diretorios auxiliares): nenhuma operacao do instalador pode altera-lo.
function Get-OutsideSnapshot {
    param($Scenario, [string[]]$Skip = @())
    $parts = foreach ($entry in @(Get-ChildItem -LiteralPath $Scenario.Root -Force | Sort-Object Name)) {
        if ($entry.FullName -ieq $Scenario.Workspace -or $Skip -icontains $entry.FullName) { continue }
        if ($entry.PSIsContainer) { $entry.Name + "`n" + (Get-Snapshot $entry.FullName) } else { $entry.Name + '|' + (Get-Sha256Hex ([IO.File]::ReadAllBytes($entry.FullName))) }
    }
    return (@($parts) -join "`n")
}

# Nome do mutex pela cadeia fixada do diretorio de trabalho, como a fase o calcula.
function Get-LockName {
    param($Scenario)
    return (InModule { param($w, $c) $chain = Open-MaDirectoryChain $w; try { Get-MaRepositoryLockName (Get-MaWorkspaceLockIdentity $chain $c) } finally { [void](Close-MaPinnedChain $chain) } } @($Scenario.Workspace, $Scenario.Coordination))
}

# Tenta renomear e desfazer; devolve 'recusado' ou 'movido'.
function Test-Rename {
    param([string]$Path)
    try { [IO.Directory]::Move($Path, $Path + '-movido'); [IO.Directory]::Move($Path + '-movido', $Path); return 'movido' } catch { return 'recusado' }
}

# Comando de filtro que grava uma sentinela se for executado (sh do Git for Windows).
function Get-SentinelFilter {
    param([string]$Sentinel)
    return ('cat; echo executado >> ''' + $Sentinel.Replace('\', '/') + '''')
}

# Ponto de entrada em processo separado, como o usuario o executaria.
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
InModule { $script:MaGitInvoker = $null; $script:MaCloneTestArguments = @() }

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
    # Hooks globais ou de sistema bloqueariam o clone por desenho; a suite exige ausencia.
    $globalHooks = InModule { param($g, $wd) $script:MaGitPath = $g; Invoke-MaGit $wd @('config', '--get-all', 'core.hooksPath') } @($GitExe, [IO.Path]::GetTempPath())
    if ($globalHooks.ExitCode -eq 0) { $missing.Add('core.hooksPath global ou de sistema ausente (o clone seria recusado por desenho)') }
}
if ($missing.Count -gt 0) {
    foreach ($item in $missing) { Write-Output ('  [PRE-REQ] ausente: ' + $item) }
    Write-Output 'Resultado: 0 aprovados, 0 falhas; suite nao executada por pre-requisito ausente'
    foreach ($name in $SavedGitEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$SavedGitEnvironment[$name]) }
    exit 2
}

try {
    Write-Output 'Preparacao completa a partir de workspace vazio'
    It 'clone, manutencao na base autorizada e onze destinos gerados, sem commit nem indice' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        $originBefore = Get-Snapshot $s.Origin
        $outsideBefore = Get-OutsideSnapshot $s
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal $false $r.Partial
        Assert-Equal $true $r.Modified
        Assert-SameSnapshot $outsideBefore (Get-OutsideSnapshot $s) 'fixture fora do workspace'
        Assert-Equal 'sem checkout' (Get-Performed $r 'Clonar')[0].Detail
        Assert-Equal 'coordination,maintenance' ((@(Get-Performed $r 'Checkout' | ForEach-Object { $_.Role })) -join ',')
        Assert-Equal 1 @(Get-Performed $r 'Clonar').Count
        Assert-Equal 1 @(Get-Performed $r 'Criar worktree').Count
        Assert-Equal 11 @(Get-Performed $r 'Gerar').Count
        Assert-Equal '.githooks,docs,docs/agentes,.multiagente' ((@(Get-Performed $r 'Criar diretorio' | ForEach-Object { $_.Target })) -join ',')
        Assert-MaintenanceGenerated $s
        Assert-Equal $Url (Invoke-FixtureGit $s.Coordination @('config', '--get', 'remote.origin.url')) 'origin registrado'
        Assert-Equal $SshCall ((@(Get-SshCalls $s)) -join ' || ') 'transporte efetivo do clone'
        Assert-Equal 'chore/manutencao' (Invoke-FixtureGit $s.Maintenance @('symbolic-ref', '--short', 'HEAD'))
        Assert-Equal 11 @($r.Files | Where-Object { $_.Role -eq 'maintenance' -and $_.Classification -eq 'PreparadoNaoCommitado' }).Count
        Assert-ContractProhibitions $s $originBefore
        $governedIndex = Invoke-FixtureGit $s.Maintenance @('ls-files', '--', 'AGENTS.md', '.githooks', '.multiagente', 'docs/agentes')
        Assert-Equal '' $governedIndex 'arquivos gerados no indice'
        # Plan posterior reconhece a preparacao, sem modificar nada.
        $plan = Invoke-MaPlan -ConfigPath $s.Config -PackageRoot $s.Package -BaseCommit $s.Base
        Assert-Equal 'Sucesso' $plan.Status ((@($plan.Issues | ForEach-Object { $_.Code })) -join ',')
        Assert-Equal 0 @($plan.Actions | Where-Object { $_.Role -eq 'maintenance' }).Count
    }
    It 'caminho com espacos, acentos, apostrofo, $, &, colchetes e ponto e virgula chega literal (AC18)' {
        $name = 'ws a' + [char]0xE7 + 'a ''x'' $y & [z]; w'
        $s = New-PrepareScenario -WorkspaceName $name
        Use-FixtureOrigin $s
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-MaintenanceGenerated $s
        Assert-Equal $name ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($s.Coordination))) 'diretorio pai literal'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $s.Root -Force -Directory | Where-Object { $_.Name -like 'ws*' }).Count 'caminho expandido ou duplicado'
    }

    Write-Output 'Repeticao e retomada'
    It 'repeticao antes do commit reconhece a preparacao sem alteracao (AC10)' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        Assert-Equal 'Sucesso' (Invoke-Prepare $s).Status
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal $false $r.Modified
        Assert-Equal 0 @($r.Performed).Count
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
    }
    It 'retomada gera somente os destinos ausentes, sem duplicar nem sobrescrever' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        [void](Invoke-Prepare $s)
        foreach ($relative in @('docs\agentes\revisao.md', '.multiagente\manifest.json')) { [IO.File]::Delete([IO.Path]::Combine($s.Maintenance, $relative)) }
        $agents = [IO.Path]::Combine($s.Maintenance, 'AGENTS.md')
        $agentsTime = [IO.File]::GetLastWriteTimeUtc($agents)
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 'docs/agentes/revisao.md,.multiagente/manifest.json' ((@(Get-Performed $r 'Gerar' | ForEach-Object { $_.Target })) -join ',')
        Assert-Equal 0 @(Get-Performed $r 'Clonar').Count
        Assert-Equal 0 @(Get-Performed $r 'Criar worktree').Count
        Assert-Equal $agentsTime ([IO.File]::GetLastWriteTimeUtc($agents)) 'AGENTS.md regravado'
        Assert-MaintenanceGenerated $s
    }
    It 'coordenacao ja clonada: reutiliza sem novo clone e cria somente a manutencao' {
        $s = New-PrepareScenario; New-FixtureClone $s
        $originBefore = Get-Snapshot $s.Origin
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 0 @(Get-Performed $r 'Clonar').Count
        Assert-Equal 1 @(Get-Performed $r 'Criar worktree').Count
        Assert-ContractProhibitions $s $originBefore
    }
    It 'branch de manutencao existente na base e reutilizada sem reposicionamento' {
        $s = New-PrepareScenario; New-FixtureClone $s
        [void](Invoke-FixtureGit $s.Coordination @('branch', 'chore/manutencao', $s.Base))
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-True ((Get-Performed $r 'Criar worktree')[0].Detail -like 'branch existente*') 'reuso da branch'
        Assert-Equal $s.Base (Invoke-FixtureGit $s.Coordination @('rev-parse', 'refs/heads/chore/manutencao'))
    }
    It 'apos commit humano da preparacao a repeticao nao gera alteracao (AC11)' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        [void](Invoke-Prepare $s)
        Save-Commit $s.Maintenance 'governanca'
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 0 @($r.Performed).Count
        Assert-Equal 11 @($r.Files | Where-Object { $_.Role -eq 'maintenance' -and $_.Classification -eq 'Identico' }).Count
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
    }
    It 'manutencao avancada alem da base com destino ausente: base divergente, nada gerado' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        [void](Invoke-Prepare $s)
        Save-Commit $s.Maintenance 'governanca'
        [void](Invoke-FixtureGit $s.Maintenance @('rm', '-q', '--', 'docs/agentes/revisao.md'))
        [void](Invoke-FixtureGit $s.Maintenance @('commit', '-q', '-m', 'remove'))
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_PREPARE_BASE_DIVERGENT' 'maintenance'
        Assert-Equal 0 @($r.Performed).Count
        Assert-True (-not [IO.File]::Exists([IO.Path]::Combine($s.Maintenance, 'docs', 'agentes', 'revisao.md'))) 'regerado'
    }

    Write-Output 'Conflitos e estado parcial'
    It 'destino parcialmente divergente interrompe sem sobrescrever' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        [void](Invoke-Prepare $s)
        $agents = [IO.Path]::Combine($s.Maintenance, 'AGENTS.md')
        Write-FixtureFile $agents $Utf8.GetBytes("alterado`n")
        [IO.File]::Delete([IO.Path]::Combine($s.Maintenance, 'CLAUDE.md'))
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_FILE_CONFLICT' 'maintenance'
        Assert-Equal 0 @($r.Performed).Count
        Assert-Equal "alterado`n" ([IO.File]::ReadAllText($agents))
        Assert-True (-not [IO.File]::Exists([IO.Path]::Combine($s.Maintenance, 'CLAUDE.md'))) 'CLAUDE.md gerado apesar do conflito'
    }
    It 'README criado pelo servidor: clone preservado, geracao bloqueada, estado parcial (AC24)' {
        $s = New-PrepareScenario -Readme ($Utf8.GetBytes("# demo`n")); Use-FixtureOrigin $s
        $originBefore = Get-Snapshot $s.Origin
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal $true $r.Partial
        Assert-HasIssue $r 'MA_FILE_CONFLICT' 'coordination'
        Assert-Equal 'Clonar,Checkout' ((@($r.Performed | ForEach-Object { $_.Operation })) -join ',')
        Assert-True ([IO.Directory]::Exists([IO.Path]::Combine($s.Coordination, '.git'))) 'clone removido'
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada apesar do conflito'
        # Checkout do Git preservado (core.autocrlf=true do sistema pode gravar CRLF).
        Assert-Equal '# demo' ([IO.File]::ReadAllText([IO.Path]::Combine($s.Coordination, 'README.md')).TrimEnd())
        Assert-ContractProhibitions $s $originBefore
        $lines = (Format-MaPrepareReport $r) -join "`n"
        Assert-True ($lines.Contains('Execucao parcial')) 'relatorio sem execucao parcial'
        # Repeticao: reconhece o clone e continua bloqueada, sem novo clone.
        $again = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $again.Status
        Assert-Equal 0 @($again.Performed).Count
    }
    It 'conflito de .gitattributes ja na coordenacao bloqueia antes de qualquer criacao (AC09)' {
        $s = New-PrepareScenario; New-FixtureClone $s
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.gitattributes')) $Utf8.GetBytes("* text=auto`n")
        Save-Commit $s.Coordination 'atributos'
        $s.Base = Invoke-FixtureGit $s.Coordination @('rev-parse', 'HEAD')
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_FILE_CONFLICT' 'coordination'
        Assert-Equal 0 @($r.Performed).Count
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
    }
    It 'caminho governado ignorado: manutencao criada e geracao recusada, estado parcial' {
        $s = New-PrepareScenario -Gitignore ".multiagente/`n"; Use-FixtureOrigin $s
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_PREPARE_PATH_IGNORED' 'maintenance'
        Assert-Equal $true $r.Partial
        Assert-Equal 0 @(Get-Performed $r 'Gerar').Count
    }

    Write-Output 'Inicializacao'
    It 'remoto vazio: pre-requisito ausente, nada criado e nenhum commit inicial (AC23)' {
        $s = New-PrepareScenario -EmptyOrigin; Use-FixtureOrigin $s
        $originBefore = Get-Snapshot $s.Origin
        $r = Invoke-Prepare $s -BaseCommit ('0123456789' * 4)
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_REMOTE_BRANCH_NOT_FOUND' 'coordination'
        Assert-Equal $false $r.Modified
        Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'coordenacao criada'
        Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto'
    }
    It 'coordenacao existente sem commit: bloqueio sem criar commit inicial (AC23)' {
        $s = New-PrepareScenario
        [void][IO.Directory]::CreateDirectory($s.Coordination)
        [void](Invoke-FixtureGit $s.Coordination @('init', '-q', '-b', 'main'))
        [void](Invoke-FixtureGit $s.Coordination @('remote', 'add', 'origin', $Url))
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status
        Assert-HasIssue $r 'MA_REPOSITORY_NO_COMMIT' 'coordination'
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
    }
    It 'base divergente da coordenacao e base ausente localmente bloqueiam sem criacao' {
        $s = New-PrepareScenario; New-FixtureClone $s
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, 'app.txt')) $Utf8.GetBytes("v2`n")
        Save-Commit $s.Coordination 'segundo'
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_BASE_DIVERGENT' 'coordination'
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
        $r = Invoke-Prepare $s -BaseCommit ('0123456789' * 4)
        Assert-HasIssue $r 'MA_BASECOMMIT_NOT_LOCAL' 'coordination'
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
    }
    It 'branch de manutencao existente em outro commit: base divergente, sem reposicionar' {
        $s = New-PrepareScenario; New-FixtureClone $s
        # Branch ja existente em commit derivado da base, criado na fixture sem mover a main.
        $tree = Invoke-FixtureGit $s.Coordination @('rev-parse', ($s.Base + '^{tree}'))
        $other = Invoke-FixtureGit $s.Coordination @('commit-tree', $tree, '-p', $s.Base, '-m', 'outro')
        [void](Invoke-FixtureGit $s.Coordination @('branch', 'chore/manutencao', $other))
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_BASE_DIVERGENT' 'maintenance'
        Assert-Equal $other (Invoke-FixtureGit $s.Coordination @('rev-parse', 'refs/heads/chore/manutencao')) 'branch reposicionada'
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
    }
    It 'branch de manutencao ocupada por outro worktree bloqueia' {
        $s = New-PrepareScenario; New-FixtureClone $s
        $elsewhere = [IO.Path]::Combine($s.Root, 'outro-lugar')
        [void](Invoke-FixtureGit $s.Coordination @('worktree', 'add', '-q', '-b', 'chore/manutencao', $elsewhere, $s.Base))
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status
        Assert-HasIssue $r 'MA_BRANCH_OCCUPIED' 'maintenance'
        Assert-Equal 0 @($r.Performed).Count
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
    }
    It 'branch existente que difere so por caixa bloqueia' {
        $s = New-PrepareScenario; New-FixtureClone $s
        [void](Invoke-FixtureGit $s.Coordination @('branch', 'Chore/Manutencao', $s.Base))
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_BRANCH_CASE_CONFLICT' 'maintenance'
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
    }

    Write-Output 'Alteracoes alheias e hooks do consumidor'
    It 'arquivo alheio na manutencao interrompe a retomada' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        [void](Invoke-Prepare $s)
        Write-FixtureFile ([IO.Path]::Combine($s.Maintenance, 'notas.txt')) $Utf8.GetBytes("trabalho`n")
        Write-FixtureFile ([IO.Path]::Combine($s.Maintenance, 'app.txt')) $Utf8.GetBytes("editado`n")
        [IO.File]::Delete([IO.Path]::Combine($s.Maintenance, 'README.md'))
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status
        $foreign = @($r.Issues | Where-Object { $_.Code -eq 'MA_PREPARE_FOREIGN_CHANGE' })
        Assert-Equal 1 $foreign.Count (Get-Codes $r)
        Assert-Equal 'app.txt, notas.txt' $foreign[0].Detail
        Assert-True (-not [IO.File]::Exists([IO.Path]::Combine($s.Maintenance, 'README.md'))) 'README regerado'
    }
    It 'atributo filter em caminho rastreado torna a conferencia inconclusiva, sem executar driver' {
        $s = New-PrepareScenario; New-FixtureClone $s
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, 'src', '.gitattributes')) $Utf8.GetBytes("* filter=inexistente`n")
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, 'src', 'a.txt')) $Utf8.GetBytes("a`n")
        Save-Commit $s.Coordination 'filtro'
        $s.Base = Invoke-FixtureGit $s.Coordination @('rev-parse', 'HEAD')
        # O instalador recusa criar a manutencao com filtro na base; o worktree e criado
        # pela fixture (driver inexistente: nada a executar) para exercitar a conferencia.
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_CHECKOUT_FILTER' 'maintenance'
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada com filtro na base'
        [void](Invoke-FixtureGit $s.Coordination @('worktree', 'add', '-q', '-b', 'chore/manutencao', $s.Maintenance, $s.Base))
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_FOREIGN_CHANGE_UNVERIFIED' 'maintenance'
        Assert-Equal 0 @($r.Performed).Count
    }
    It 'hook ativo no diretorio padrao bloqueia a criacao da manutencao sem executa-lo' {
        $s = New-PrepareScenario; New-FixtureClone $s
        $sentinel = [IO.Path]::Combine($s.Root, 'sentinela-hook.txt')
        $hook = "#!/bin/sh`necho executado > '" + $sentinel.Replace('\', '/') + "'`n"
        Write-FixtureFile ([IO.Path]::Combine($s.Coordination, '.git', 'hooks', 'post-checkout')) $Utf8.GetBytes($hook)
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status
        Assert-HasIssue $r 'MA_PREPARE_HOOKS_WOULD_RUN' 'maintenance'
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
        Assert-True (-not [IO.File]::Exists($sentinel)) 'hook executado'
    }
    It 'core.hooksPath local bloqueia a criacao da manutencao sem alterar a configuracao' {
        $s = New-PrepareScenario; New-FixtureClone $s
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'core.hooksPath', 'hooks-proprios'))
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_HOOKS_WOULD_RUN' 'maintenance'
        Assert-Equal 'hooks-proprios' (Invoke-FixtureGit $s.Coordination @('config', '--local', '--get', 'core.hooksPath'))
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
    }

    Write-Output 'WhatIf, evidencias e exclusao mutua'
    It 'WhatIf em workspace vazio: Incompleto, acoes simuladas e nenhuma modificacao (AC07)' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s -WhatIf
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-Equal $false $r.Modified
        Assert-Equal 'Clonar' @($r.Simulated)[0].Operation
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'WhatIf com coordenacao existente preve worktree e onze geracoes sem executar' {
        $s = New-PrepareScenario; New-FixtureClone $s
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s -WhatIf
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-Equal 1 @($r.Simulated | Where-Object { $_.Operation -eq 'Criar worktree' }).Count
        Assert-Equal 11 @($r.Simulated | Where-Object { $_.Operation -eq 'Gerar' }).Count
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'WhatIf com manutencao parcial preve somente os ausentes' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        [void](Invoke-Prepare $s)
        [IO.File]::Delete([IO.Path]::Combine($s.Maintenance, 'CLAUDE.md'))
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s -WhatIf
        Assert-Equal 'CLAUDE.md' ((@($r.Simulated | ForEach-Object { $_.Target })) -join ',')
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'sem AuthorizationReference ou BaseCommit: bloqueio antes de qualquer operacao' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        $before = Get-Snapshot $s.Root
        Assert-HasIssue (Invoke-Prepare $s -AuthorizationReference '') 'MA_AUTHORIZATION_REFERENCE_REQUIRED'
        Assert-HasIssue (Invoke-Prepare $s -BaseCommit '') 'MA_BASECOMMIT_REQUIRED'
        Assert-HasIssue (Invoke-Prepare $s -BaseCommit 'abc123') 'MA_COMMIT_FORMAT_INVALID'
        Assert-HasIssue (Invoke-Prepare $s -AuthorizationReference "linha`nquebrada") 'MA_AUTHORIZATION_REFERENCE_INVALID'
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'outra fase mutavel com a exclusao mutua: bloqueio sem operacao' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        $name = Get-LockName $s
        $holder = [powershell]::Create()
        $ready = New-Object System.Threading.ManualResetEvent($false)
        $release = New-Object System.Threading.ManualResetEvent($false)
        [void]$holder.AddScript({ param($n, $r1, $r2) $m = New-Object System.Threading.Mutex($false, $n); [void]$m.WaitOne(); [void]$r1.Set(); [void]$r2.WaitOne(30000); $m.ReleaseMutex(); $m.Dispose() }).AddArgument($name).AddArgument($ready).AddArgument($release)
        $handle = $holder.BeginInvoke()
        try {
            Assert-True ($ready.WaitOne(10000)) 'mutex nao obtido pelo detentor'
            $before = Get-Snapshot $s.Root
            $r = Invoke-Prepare $s
            Assert-HasIssue $r 'MA_PREPARE_LOCKED'
            Assert-Equal $false $r.Modified
            Assert-SameSnapshot $before (Get-Snapshot $s.Root)
        } finally { [void]$release.Set(); [void]$holder.EndInvoke($handle); $holder.Dispose() }
        Assert-Equal 'Sucesso' (Invoke-Prepare $s).Status 'apos liberacao'
    }

    Write-Output 'Concorrencia entre inspecao e operacao'
    # Invocador que delega ao Git real e altera o estado no instante indicado.
    function Use-InterceptingGit {
        param([scriptblock]$Trigger)
        Initialize-GitTransport
        $wrapper = $Module.NewBoundScriptBlock({
            param($WorkingDirectory, $Arguments, $Binary, $InputText, $Transport)
            & $script:MaTestTrigger $WorkingDirectory $Arguments
            $saved = $script:MaGitInvoker; $script:MaGitInvoker = $null
            try { return (Invoke-MaGit -WorkingDirectory $WorkingDirectory -Arguments $Arguments -Binary:$Binary -InputText $InputText -TimeoutMilliseconds 600000 -NoLiteralPathspecs:($Arguments[0] -ceq 'check-ignore') -Transport:([bool]$Transport)) }
            finally { $script:MaGitInvoker = $saved }
        })
        InModule { param($w, $t) $script:MaTestTrigger = $t; $script:MaGitInvoker = $w } @($wrapper, $Trigger)
    }
    It 'destino criado por terceiro antes da gravacao: nada sobrescrito, execucao parcial' {
        $s = New-PrepareScenario; New-FixtureClone $s
        $script:Claude = [IO.Path]::Combine($s.Maintenance, 'CLAUDE.md')
        $claude = $script:Claude
        $script:Fired = $false
        # Gatilho criado neste escopo: executa na sessao do teste, chamado pelo modulo.
        Use-InterceptingGit {
            param($wd, $a)
            if (-not $script:Fired -and ($a -join ' ') -ceq 'ls-files -s -z -- CLAUDE.md') { [IO.File]::WriteAllBytes($script:Claude, [Text.Encoding]::ASCII.GetBytes("terceiro`n")); $script:Fired = $true }
        }
        $r = Invoke-Prepare $s
        Assert-True $script:Fired 'gatilho nao executado'
        Assert-HasIssue $r 'MA_PREPARE_TARGET_CHANGED' 'maintenance'
        Assert-Equal $true $r.Partial
        Assert-Equal "terceiro`n" ([IO.File]::ReadAllText($claude))
        Assert-Equal 'AGENTS.md' ((@(Get-Performed $r 'Gerar' | ForEach-Object { $_.Target })) -join ',')
    }
    It 'coordenacao avancada entre inspecao e criacao do worktree: operacao nao executada' {
        $s = New-PrepareScenario; New-FixtureClone $s
        $script:CoordinationPath = $s.Coordination
        $script:Count = 0
        Use-InterceptingGit {
            param($wd, $a)
            if (($a -join ' ') -like 'for-each-ref*') {
                $script:Count++
                # Segunda leitura das branches = revalidacao imediata anterior ao worktree add.
                if ($script:Count -eq 2) { [void](Invoke-FixtureGit $script:CoordinationPath @('commit', '-q', '--allow-empty', '-m', 'concorrente')) }
            }
        }
        $r = Invoke-Prepare $s
        Assert-Equal 2 $script:Count 'revalidacao nao observada'
        Assert-HasIssue $r 'MA_PREPARE_STATE_CHANGED' 'maintenance'
        Assert-Equal $false $r.Modified
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
    }

    Write-Output 'Caminhos fixados por handles durante operacoes Git'
    It 'junction plantada no destino fixado antes do clone: renomear recusado, nada gravado fora' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        $script:Scenario = $s
        $script:Outside = [IO.Path]::Combine($s.Root, 'fora'); [void][IO.Directory]::CreateDirectory($script:Outside)
        $script:Observed = New-Object System.Collections.Generic.List[string]
        $outsideBefore = Get-OutsideSnapshot $s
        Use-InterceptingGit {
            param($wd, $a)
            if ($script:Observed.Count -eq 0 -and $a -ccontains 'clone') {
                $script:Observed.Add('coordenacao:' + (Test-Rename $script:Scenario.Coordination))
                $script:Observed.Add('workspace:' + (Test-Rename $script:Scenario.Workspace))
                [void](New-Item -ItemType Junction -Path ([IO.Path]::Combine($script:Scenario.Coordination, '.git')) -Value $script:Outside)
            }
        }
        $r = Invoke-Prepare $s
        Assert-Equal 'coordenacao:recusado,workspace:recusado' ($script:Observed -join ',')
        Assert-HasIssue $r 'MA_PREPARE_CLONE_FAILED' 'coordination'
        Assert-HasIssue $r 'MA_PREPARE_CLONE_RESIDUE' 'coordination'
        Assert-HasIssue $r 'MA_PREPARE_TARGET_REDIRECTED' 'coordination'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:Outside -Force -Recurse).Count 'gravado atraves da junction'
        Assert-SameSnapshot $outsideBefore (Get-OutsideSnapshot $s) 'fixture fora do workspace'
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
        [IO.Directory]::Delete([IO.Path]::Combine($s.Coordination, '.git'))
    }
    It 'workspace, coordenacao e destino fixados durante worktree add e checkout: renomear recusado' {
        $s = New-PrepareScenario; New-FixtureClone $s
        $script:Scenario = $s
        $script:Observed = New-Object System.Collections.Generic.List[string]
        $outsideBefore = Get-OutsideSnapshot $s
        Use-InterceptingGit {
            param($wd, $a)
            if ($a[0] -cin @('worktree', 'read-tree') -and ($a -join ' ') -cne 'worktree list --porcelain -z') {
                foreach ($path in @($script:Scenario.Workspace, $script:Scenario.Maintenance, [IO.Path]::Combine($script:Scenario.Coordination, '.git'))) { $script:Observed.Add($a[0] + ':' + (Test-Rename $path)) }
            }
        }
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 'worktree:recusado,worktree:recusado,worktree:recusado,read-tree:recusado,read-tree:recusado,read-tree:recusado' ($script:Observed -join ',')
        Assert-MaintenanceGenerated $s
        Assert-SameSnapshot $outsideBefore (Get-OutsideSnapshot $s) 'fixture fora do workspace'
    }

    Write-Output 'Configuracao alterada durante a fase'
    It 'configuracao trocada para outro workspace depois do clone: nenhuma operacao no destino relido' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        $script:Scenario = $s
        $script:OtherWorkspace = [IO.Path]::Combine($s.Root, 'ws-b'); [void][IO.Directory]::CreateDirectory($script:OtherWorkspace)
        $script:Changed = $false
        Use-InterceptingGit {
            param($wd, $a)
            if (-not $script:Changed -and $a -ccontains 'clone') {
                $json = '{"schemaVersion":"1.0","project":{"name":"Projeto Demo","slug":"demo"},"repository":{"url":"' + $Url + '"},"workspace":{"parentDirectory":' + ($script:OtherWorkspace | ConvertTo-Json) + '}}'
                [IO.File]::WriteAllBytes($script:Scenario.Config, $Utf8.GetBytes($json)); $script:Changed = $true
            }
        }
        $r = Invoke-Prepare $s
        Assert-True $script:Changed 'gatilho nao executado'
        Assert-HasIssue $r 'MA_PREPARE_CONFIG_CHANGED'
        Assert-Equal 'Clonar,Checkout' ((@($r.Performed | ForEach-Object { $_.Operation })) -join ',') 'somente o destino do mutex'
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:OtherWorkspace -Force).Count 'gravado no workspace relido'
    }

    Write-Output 'Transporte efetivo do clone (Git real, sem conexao a servidores)'
    # Camadas de sistema e global em arquivos temporarios, so neste processo e so
    # nas chamadas diretas (a fase recusaria GIT_CONFIG_*); isolam tambem a
    # configuracao real do executor. Restauradas por Clear-ConfigLevels.
    $OriginalAllowProtocol = [Environment]::GetEnvironmentVariable('GIT_ALLOW_PROTOCOL')
    function Use-ConfigLevels {
        param([string]$Directory, [string]$System = '', [string]$Global = '')
        foreach ($level in @(@('GIT_CONFIG_SYSTEM', $System, 'sistema.cfg'), @('GIT_CONFIG_GLOBAL', $Global, 'global.cfg'))) {
            $path = [IO.Path]::Combine($Directory, $level[2])
            Write-FixtureFile $path $Utf8.GetBytes($level[1])
            [Environment]::SetEnvironmentVariable($level[0], $path)
        }
    }
    function Clear-ConfigLevels {
        foreach ($name in @('GIT_CONFIG_SYSTEM', 'GIT_CONFIG_GLOBAL')) { [Environment]::SetEnvironmentVariable($name, $null) }
        [Environment]::SetEnvironmentVariable('GIT_ALLOW_PROTOCOL', $OriginalAllowProtocol)
    }
    # Git real e ambiente de transporte definidos pelo contexto, como na fase.
    function Get-CloneTransport { param([string]$Directory, [string]$RepositoryUrl, [string[]]$Extra = @()) Initialize-GitTransport; return (InModule { param($w, $u, $a) Get-MaCloneTransport $w $u $a } @($Directory, $RepositoryUrl, $Extra)) }
    function Get-Blocking { param($Result) return ((@($Result.Issues | Where-Object { $_.Severity -ne 'Aviso' } | ForEach-Object { $_.Code + ':' + $_.Detail })) -join ' | ') }
    # Secao de configuracao [url "<base>"] com insteadOf.
    function Get-RewriteSection { param([string]$Base, [string]$Prefix) return ('[url "' + $Base + '"]' + "`n`tinsteadOf = " + $Prefix + "`n") }
    # URL ext:: cujo comando (sh do Git for Windows) grava a sentinela se executado.
    function Get-ExtSentinelUrl {
        param([string]$Sentinel)
        $shell = InModule { param($g) Find-MaShell $g } @($GitExe)
        return ('ext::' + $shell.Replace('\', '/').Replace(' ', '% ') + ' -c echo% executado% >>% ' + (ConvertTo-ShQuoted $Sentinel).Replace(' ', '% '))
    }
    # Invocador que delega ao Git real registrando as chamadas e, opcionalmente,
    # acrescentando -c ao clone (configuracao alterada depois da verificacao).
    function Use-RecordingGit {
        param([string[]]$CloneExtra = @())
        $script:Calls = New-Object System.Collections.Generic.List[string]
        Initialize-GitTransport
        $wrapper = $Module.NewBoundScriptBlock({
            param($WorkingDirectory, $Arguments, $Binary, $InputText, $Transport)
            if ($Arguments -ccontains 'clone') { $Arguments = @($script:MaTestCloneExtra) + @($Arguments) }
            & $script:MaTestRecord ($Arguments -join ' ')
            $saved = $script:MaGitInvoker; $script:MaGitInvoker = $null
            try { return (Invoke-MaGit -WorkingDirectory $WorkingDirectory -Arguments $Arguments -Binary:$Binary -InputText $InputText -TimeoutMilliseconds 600000 -NoLiteralPathspecs:($Arguments[0] -ceq 'check-ignore') -Transport:([bool]$Transport)) }
            finally { $script:MaGitInvoker = $saved }
        })
        InModule { param($w, $e, $r) $script:MaTestCloneExtra = $e; $script:MaTestRecord = $r; $script:MaGitInvoker = $w } @($wrapper, $CloneExtra, { param($c) $script:Calls.Add($c) })
    }
    function Get-CloneCalls { return @($script:Calls | Where-Object { $_ -cmatch '(?:\A| )clone --no-checkout ' }) }

    It 'HTTPS e SSH sem reescrita: transporte classificado como permitido pelo proprio Git' {
        $s = New-PrepareScenario
        Use-ConfigLevels ($s.Root + '-ssh')
        try {
            foreach ($case in @(@($HttpsUrl, 'https'), @('https://example.invalid:8443/org/demo.git', 'https'), @($Url, 'ssh'), @('git@example.invalid:org/demo.git', 'ssh'))) {
                $r = Get-CloneTransport $s.Workspace $case[0]
                Assert-Equal $case[1] $r.Transport $case[0]
                Assert-Equal 0 @($r.Issues).Count (Get-Codes $r)
            }
        } finally { Clear-ConfigLevels }
    }
    It 'HTTPS configurado e reescrito para SSH: clone pelo transporte efetivo, aviso e origin configurado' {
        $s = New-PrepareScenario -RepositoryUrl $HttpsUrl
        Use-FixtureOrigin $s @('-c', ('url.' + $Url + '.insteadOf=' + $HttpsUrl))
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 'https -> ssh' @($r.Issues | Where-Object { $_.Code -ceq 'MA_REPOSITORY_TRANSPORT_REWRITTEN' })[0].Detail (Get-Codes $r)
        Assert-Equal $SshCall ((@(Get-SshCalls $s)) -join ' || ') 'transporte efetivo do clone'
        Assert-Equal $HttpsUrl (Invoke-FixtureGit $s.Coordination @('config', '--get', 'remote.origin.url')) 'origin registrado'
        Assert-MaintenanceGenerated $s
    }
    It 'HTTPS reescrito para file://, mesmo com protocol.file.allow=always: bloqueado sem executar o clone' {
        $s = New-PrepareScenario -RepositoryUrl $HttpsUrl
        Use-FixtureOrigin $s @('-c', 'protocol.allow=always', '-c', 'protocol.file.allow=always', '-c', ('url.' + (ConvertTo-FileUrl $s.Origin) + '.insteadOf=' + $HttpsUrl))
        Use-RecordingGit
        $originBefore = Get-Snapshot $s.Origin
        $outsideBefore = Get-OutsideSnapshot $s
        $workspaceBefore = Get-Snapshot $s.Workspace
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:URL efetiva fora do contrato; transporte file' (Get-Blocking $r)
        Assert-Equal $false $r.Modified
        Assert-True (@($script:Calls | Where-Object { $_.EndsWith('ls-remote --get-url -- ' + $HttpsUrl) }).Count -eq 1) 'URL efetiva nao consultada'
        Assert-Equal 0 @(Get-CloneCalls).Count 'clone executado'
        Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'coordenacao criada'
        Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto de origem'
        Assert-SameSnapshot $outsideBefore (Get-OutsideSnapshot $s) 'fixture fora do workspace'
        Assert-SameSnapshot $workspaceBefore (Get-Snapshot $s.Workspace) 'workspace'
        # WhatIf tambem recusa, sem simular o clone.
        $simulated = Invoke-Prepare $s -WhatIf
        Assert-HasIssue $simulated 'MA_REPOSITORY_TRANSPORT_UNSAFE' 'coordination'
        Assert-Equal 0 @($simulated.Simulated).Count
        Assert-Equal 0 @(Get-CloneCalls).Count 'clone executado no WhatIf'
    }
    It 'HTTPS reescrito para ext:: ou remote helper: bloqueado e comando nao executado (controle sem a politica executa)' {
        $s = New-PrepareScenario -RepositoryUrl $HttpsUrl
        $sentinel = [IO.Path]::Combine($s.Root + '-ssh', 'sentinela-ext.txt')
        $ext = Get-ExtSentinelUrl $sentinel
        # Controle: o Git da fixture, sem a politica do instalador, executa o comando do ext::.
        [void](Invoke-FixtureGit ($s.Root + '-ssh') @('-c', 'protocol.ext.allow=always', 'clone', '-q', '--no-checkout', $ext, 'controle') -AllowFailure)
        Assert-True ([IO.File]::Exists($sentinel)) 'controle: ext:: nao executou'
        [IO.File]::Delete($sentinel)
        $originBefore = Get-Snapshot $s.Origin
        foreach ($case in @(@($ext, 'helper ext'), @('sentinela::https://example.invalid/org/demo.git', 'helper sentinela'))) {
            Use-FixtureOrigin $s @('-c', 'protocol.allow=always', '-c', 'protocol.ext.allow=always', '-c', 'protocol.sentinela.allow=always', '-c', ('url.' + $case[0] + '.insteadOf=' + $HttpsUrl))
            Use-RecordingGit
            $r = Invoke-Prepare $s
            Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
            Assert-Equal ('MA_REPOSITORY_TRANSPORT_UNSAFE:URL efetiva fora do contrato; transporte ' + $case[1]) (Get-Blocking $r)
            Assert-Equal 0 @(Get-CloneCalls).Count ('clone executado: ' + $case[1])
            Assert-True (-not [IO.File]::Exists($sentinel)) ('comando executado: ' + $case[1])
            Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'coordenacao criada'
        }
        Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto de origem'
    }
    It 'HTTPS reescrito para HTTP sem TLS ou git://: bloqueado sem conexao' {
        $s = New-PrepareScenario -RepositoryUrl $HttpsUrl
        foreach ($case in @(@('http://127.0.0.1:9/org/demo.git', 'http'), @('git://127.0.0.1:9/org/demo.git', 'git'))) {
            Use-FixtureOrigin $s @('-c', 'protocol.allow=always', '-c', ('url.' + $case[0] + '.insteadOf=' + $HttpsUrl))
            Use-RecordingGit
            $r = Invoke-Prepare $s
            Assert-Equal ('MA_REPOSITORY_TRANSPORT_UNSAFE:URL efetiva fora do contrato; transporte ' + $case[1]) (Get-Blocking $r)
            Assert-Equal 0 @(Get-CloneCalls).Count ('clone executado: ' + $case[1])
        }
    }
    It 'configuracoes conflitantes em sistema, global e linha de comando: reescrita escolhida pelo Git e recusada' {
        $s = New-PrepareScenario -RepositoryUrl $HttpsUrl
        $levels = $s.Root + '-ssh'
        $file = ConvertTo-FileUrl $s.Origin
        try {
            # Prefixo mais longo vence, qualquer que seja o nivel: global (HTTPS) sobre sistema (file).
            Use-ConfigLevels $levels -System (Get-RewriteSection $file 'https://example.invalid/') -Global (Get-RewriteSection 'https://espelho.invalid/org/' 'https://example.invalid/org/')
            $r = Get-CloneTransport $s.Workspace $HttpsUrl
            Assert-Equal 'https' $r.Transport (Get-Codes $r)
            Assert-Equal 'Aviso:MA_REPOSITORY_TRANSPORT_REWRITTEN@coordination https -> https' (Get-Codes $r)
            # Linha de comando (file) sobre sistema (HTTPS), com protocol.*.allow=always global.
            Use-ConfigLevels $levels -System (Get-RewriteSection 'https://espelho.invalid/' 'https://example.invalid/') -Global "[protocol]`n`tallow = always`n[protocol `"file`"]`n`tallow = always`n"
            $r = Get-CloneTransport $s.Workspace $HttpsUrl @('-c', ('url.' + $file + '.insteadOf=' + $HttpsUrl))
            Assert-Equal $null $r.Transport
            Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:URL efetiva fora do contrato; transporte file' (Get-Blocking $r)
            # remote.origin.vcs global troca o transporte sem mudar a URL.
            Use-ConfigLevels $levels -Global "[remote `"origin`"]`n`tvcs = sentinela`n"
            Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:remote.origin.vcs (global)' (Get-Blocking (Get-CloneTransport $s.Workspace $HttpsUrl))
            # Falha de inspecao real: configuracao global ilegivel.
            Use-ConfigLevels $levels -Global "[url `"x`n"
            $r = Get-CloneTransport $s.Workspace $HttpsUrl
            Assert-Equal $null $r.Transport
            Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNVERIFIED:remote.origin.vcs | MA_REPOSITORY_TRANSPORT_UNVERIFIED:remote.origin.url | MA_REPOSITORY_TRANSPORT_UNVERIFIED:alias.remote-ssh | MA_REPOSITORY_TRANSPORT_UNVERIFIED:git ls-remote --get-url 128' (Get-Blocking $r)
        } finally { Clear-ConfigLevels }
    }
    It 'politica aplicada no proprio comando: clone recusa file, ext e helper apesar de protocol.*.allow e GIT_ALLOW_PROTOCOL do consumidor' {
        $s = New-PrepareScenario -RepositoryUrl $HttpsUrl
        $levels = $s.Root + '-ssh'
        $sentinel = [IO.Path]::Combine($levels, 'sentinela-ext.txt')
        $ext = Get-ExtSentinelUrl $sentinel
        $target = [IO.Path]::Combine($s.Workspace, 'direto')
        $originBefore = Get-Snapshot $s.Origin
        $clone = { param([string[]]$Arguments) InModule { param($g, $w, $a) $script:MaGitPath = $g; Invoke-MaGit $w $a } @($GitExe, $s.Workspace, $Arguments) }
        try {
            Use-ConfigLevels $levels -Global ("[protocol]`n`tallow = always`n[protocol `"file`"]`n`tallow = always`n[protocol `"ext`"]`n`tallow = always`n" + (Get-RewriteSection (ConvertTo-FileUrl $s.Origin) $HttpsUrl))
            [Environment]::SetEnvironmentVariable('GIT_ALLOW_PROTOCOL', 'file:ext:sentinela:http:git')
            $cases = @(
                @(@('-c', 'protocol.file.allow=always', 'clone', '--no-checkout', '--', $HttpsUrl, $target), 'file'),
                @(@('-c', 'protocol.ext.allow=always', 'clone', '--no-checkout', '--', $ext, $target), 'ext'),
                @(@('-c', 'remote.origin.vcs=sentinela', '-c', 'protocol.sentinela.allow=always', 'clone', '--no-checkout', '--', $HttpsUrl, $target), 'sentinela'))
            foreach ($case in $cases) {
                $result = & $clone $case[0]
                Assert-Equal 128 $result.ExitCode ($case[1] + ': ' + $result.StdErr)
                Assert-True ([string]$result.StdErr -cmatch ("transport '" + $case[1] + "' not allowed")) ($case[1] + ': ' + $result.StdErr)
                Assert-True (-not [IO.Directory]::Exists($target)) ('destino criado: ' + $case[1])
            }
        } finally { Clear-ConfigLevels }
        Assert-True (-not [IO.File]::Exists($sentinel)) 'comando do ext:: executado'
        Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto de origem'
    }
    It 'configuracao alterada entre a verificacao e o clone: o Git recusa o transporte, erro estruturado e sem residuo' {
        $s = New-PrepareScenario -RepositoryUrl $HttpsUrl
        Use-RecordingGit @('-c', 'protocol.file.allow=always', '-c', ('url.' + (ConvertTo-FileUrl $s.Origin) + '.insteadOf=' + $HttpsUrl))
        $originBefore = Get-Snapshot $s.Origin
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:git clone 128; transporte recusado pelo Git: file' (Get-Blocking $r)
        Assert-Equal 1 @(Get-CloneCalls).Count 'clone nao chamado'
        Assert-Equal $false $r.Partial
        Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'destino do clone deixado'
        Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto de origem'
        Assert-Equal 0 @(Get-SshCalls $s).Count 'ssh executado'
    }

    # Helper de transporte sentinela (script sh, resolvido pelo Git como
    # git-remote-<nome>): grava a sentinela e falha, sem acessar a rede.
    function New-HelperSentinel {
        param([string]$Directory, [string]$Name)
        $folder = [IO.Path]::Combine($Directory, 'helper-' + $Name)
        $sentinel = [IO.Path]::Combine($Directory, 'sentinela-helper-' + $Name + '.txt')
        Write-FixtureFile ([IO.Path]::Combine($folder, 'git-remote-' + $Name)) ([Text.Encoding]::ASCII.GetBytes("#!/bin/sh`necho executado >> " + (ConvertTo-ShQuoted $sentinel) + "`nexit 1`n"))
        return [pscustomobject]@{ Directory = $folder; Sentinel = $sentinel }
    }
    # Ambiente deste processo com o helper sentinela em GIT_EXEC_PATH ou no inicio
    # do PATH, seguido do sh do Git for Windows (interpretador do script).
    function Use-SentinelEnvironment {
        param([string]$ExecPath = '', [string]$PathDirectory = '')
        $saved = @{ PATH = [Environment]::GetEnvironmentVariable('PATH'); GIT_EXEC_PATH = [Environment]::GetEnvironmentVariable('GIT_EXEC_PATH') }
        $shell = [IO.Path]::GetDirectoryName((InModule { param($g) Find-MaShell $g } @($GitExe)))
        [Environment]::SetEnvironmentVariable('PATH', ((@(@($PathDirectory, $shell) | Where-Object { $_ }) + @($saved.PATH)) -join ';'))
        if ($ExecPath) { [Environment]::SetEnvironmentVariable('GIT_EXEC_PATH', $ExecPath) }
        return $saved
    }
    function Restore-SentinelEnvironment { param($Saved) foreach ($name in @('PATH', 'GIT_EXEC_PATH')) { [Environment]::SetEnvironmentVariable($name, $Saved[$name]) } }

    It 'GIT_EXEC_PATH com helper sentinela: ignorado pelo Git do instalador, HTTPS pelo helper da instalacao e sem residuo' {
        $s = New-PrepareScenario
        $helper = New-HelperSentinel ($s.Root + '-ssh') 'https'
        $target = [IO.Path]::Combine($s.Workspace, 'direto')
        $saved = Use-SentinelEnvironment -ExecPath $helper.Directory
        try {
            # Controle: o Git da fixture, no mesmo ambiente, executa a sentinela.
            [void](Invoke-FixtureGit ($s.Root + '-ssh') @('clone', '-q', '--no-checkout', '--', $LoopbackUrl, 'controle') -AllowFailure)
            Assert-True ([IO.File]::Exists($helper.Sentinel)) 'controle: sentinela nao executada'
            [IO.File]::Delete($helper.Sentinel)
            # HTTPS legitimo: o helper da instalacao conecta e falha na porta fechada.
            $result = InModule { param($g, $w, $a) $script:MaGitPath = $g; Invoke-MaGit $w $a } @($GitExe, $s.Workspace, @('clone', '--no-checkout', '--', $LoopbackUrl, $target))
            Assert-Equal 128 $result.ExitCode $result.StdErr
            Assert-True ([string]$result.StdErr -cmatch "unable to access 'https://127\.0\.0\.1:9/") ('helper da instalacao nao executado: ' + $result.StdErr)
            Assert-True (-not [IO.File]::Exists($helper.Sentinel)) 'sentinela executada pelo Git do instalador'
            Assert-True (-not [IO.Directory]::Exists($target)) 'destino deixado'
            # Fase completa no mesmo ambiente (SSH da fixture): aviso, conclusao e sentinela intacta.
            Use-FixtureOrigin $s
            $r = Invoke-Prepare $s
            Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
            Assert-HasIssue $r 'MA_GIT_EXEC_PATH_IGNORED'
            Assert-True (-not [IO.File]::Exists($helper.Sentinel)) 'sentinela executada na fase'
            Assert-MaintenanceGenerated $s
        } finally { Restore-SentinelEnvironment $saved }
        Assert-True (@(Get-ChildItem -LiteralPath $s.Workspace -Force | Where-Object { $_.Name -ceq 'direto' }).Count -eq 0) 'residuo do clone direto'
    }
    It 'remote.origin.vcs=ssh surgido depois da verificacao (HTTPS): git-remote-ssh do PATH nao executado e sem residuo' {
        $s = New-PrepareScenario -RepositoryUrl $HttpsUrl
        $helper = New-HelperSentinel ($s.Root + '-ssh') 'ssh'
        $saved = Use-SentinelEnvironment -PathDirectory $helper.Directory
        try {
            # Controle: o Git da fixture com remote.origin.vcs=ssh executa o helper do PATH.
            [void](Invoke-FixtureGit ($s.Root + '-ssh') @('-c', 'remote.origin.vcs=ssh', 'clone', '-q', '--no-checkout', '--', $LoopbackUrl, 'controle') -AllowFailure)
            Assert-True ([IO.File]::Exists($helper.Sentinel)) 'controle: sentinela nao executada'
            [IO.File]::Delete($helper.Sentinel)
            # Depois da verificacao: vcs=ssh e URL desviada para a porta local fechada.
            Use-RecordingGit @('-c', 'remote.origin.vcs=ssh', '-c', ('url.' + $LoopbackUrl + '.insteadOf=' + $HttpsUrl))
            $originBefore = Get-Snapshot $s.Origin
            $outsideBefore = Get-OutsideSnapshot $s
            $workspaceBefore = Get-Snapshot $s.Workspace
            $r = Invoke-Prepare $s
            Assert-Equal 'Falha' $r.Status (Get-Codes $r)
            Assert-Equal 'MA_PREPARE_CLONE_FAILED:git clone 128' (Get-Blocking $r)
            $clones = @(Get-CloneCalls)
            Assert-Equal 1 $clones.Count 'clone nao chamado'
            Assert-True ($clones[0].Contains(' -c remote.origin.vcs=https clone --no-checkout ')) ('helper https nao fixado na ultima camada: ' + $clones[0])
            Assert-True (-not [IO.File]::Exists($helper.Sentinel)) 'git-remote-ssh do PATH executado'
            Assert-Equal $false $r.Partial
            Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'destino do clone deixado'
            Assert-SameSnapshot $workspaceBefore (Get-Snapshot $s.Workspace) 'workspace'
            Assert-SameSnapshot $outsideBefore (Get-OutsideSnapshot $s) 'fixture fora do workspace'
            Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto de origem'
        } finally { Restore-SentinelEnvironment $saved }
    }
    It 'remote.origin.url de outra camada com <helper>::: recusado antes do clone e helper nao executado' {
        $s = New-PrepareScenario -RepositoryUrl $HttpsUrl
        $helper = New-HelperSentinel ($s.Root + '-ssh') 'ssh'
        $saved = Use-SentinelEnvironment -PathDirectory $helper.Directory
        try {
            # Controle: o clone usa a primeira URL do origin (global, lida antes da local), nao a informada.
            Use-ConfigLevels ($s.Root + '-ssh') -Global "[remote `"origin`"]`n`turl = ssh::sequestrado`n"
            try {
                [void](Invoke-FixtureGit ($s.Root + '-ssh') @('clone', '-q', '--no-checkout', '--', $LoopbackUrl, 'controle') -AllowFailure)
                Assert-True ([IO.File]::Exists($helper.Sentinel)) 'controle: sentinela nao executada'
                [IO.File]::Delete($helper.Sentinel)
                Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:remote.origin.url (global)' (Get-Blocking (Get-CloneTransport $s.Workspace $HttpsUrl))
            } finally { Clear-ConfigLevels }
            # Na fase (a camada global por variavel seria recusada como redirecionamento): linha de comando.
            Use-FixtureOrigin $s @('-c', 'remote.origin.url=ssh::sequestrado')
            Use-RecordingGit
            $workspaceBefore = Get-Snapshot $s.Workspace
            $r = Invoke-Prepare $s
            Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
            Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:remote.origin.url (command)' (Get-Blocking $r)
            Assert-Equal 0 @(Get-CloneCalls).Count 'clone executado'
            Assert-True (-not [IO.File]::Exists($helper.Sentinel)) 'helper executado'
            Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'coordenacao criada'
            Assert-SameSnapshot $workspaceBefore (Get-Snapshot $s.Workspace) 'workspace'
        } finally { Restore-SentinelEnvironment $saved }
    }
    It 'SSH legitimo com git-remote-ssh sentinela no PATH: transporte nativo, conclusao e sentinela intacta' {
        $s = New-PrepareScenario
        $helper = New-HelperSentinel ($s.Root + '-ssh') 'ssh'
        $saved = Use-SentinelEnvironment -PathDirectory $helper.Directory
        try {
            Use-FixtureOrigin $s
            $r = Invoke-Prepare $s
            Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
            Assert-Equal $SshCall ((@(Get-SshCalls $s)) -join ' || ') 'transporte SSH nativo'
            Assert-True (-not [IO.File]::Exists($helper.Sentinel)) 'git-remote-ssh executado'
            Assert-MaintenanceGenerated $s
        } finally { Restore-SentinelEnvironment $saved }
    }

    Write-Output 'PATH restrito e cliente SSH fixado no clone (alternativa B)'
    $ShellPath = InModule { param($g) Find-MaShell $g } @($GitExe)
    # Programa sentinela de nome arbitrario (script sh): grava o marcador e falha.
    function New-ProgramSentinel {
        param([string]$Directory, [string]$Name)
        $folder = [IO.Path]::Combine($Directory, 'programa-' + $Name)
        $sentinel = [IO.Path]::Combine($Directory, 'sentinela-programa-' + $Name + '.txt')
        $program = [IO.Path]::Combine($folder, $Name)
        Write-FixtureFile $program ([Text.Encoding]::ASCII.GetBytes("#!/bin/sh`necho executado >> " + (ConvertTo-ShQuoted $sentinel) + "`nexit 1`n"))
        return [pscustomobject]@{ Directory = $folder; Program = $program; Sentinel = $sentinel; Command = ((ConvertTo-ShQuoted $ShellPath) + ' ' + (ConvertTo-ShQuoted $program)) }
    }

    It 'HTTPS legitimo pelo ambiente de transporte: helper da instalacao com PATH restrito, sentinela do PATH intacta' {
        $s = New-PrepareScenario -RepositoryUrl $LoopbackUrl
        $helper = New-HelperSentinel ($s.Root + '-ssh') 'https'
        $saved = Use-SentinelEnvironment -PathDirectory $helper.Directory
        try {
            Initialize-GitTransport
            $target = [IO.Path]::Combine($s.Workspace, 'direto')
            $result = InModule { param($w, $a) Invoke-MaGit $w $a -Transport } @($s.Workspace, @('clone', '--no-checkout', '--', $LoopbackUrl, $target))
            Assert-Equal 128 $result.ExitCode $result.StdErr
            Assert-True ([string]$result.StdErr -cmatch "unable to access 'https://127\.0\.0\.1:9/") ('helper da instalacao nao executado: ' + $result.StdErr)
            Assert-True (-not [IO.Directory]::Exists($target)) 'destino deixado'
            # Fase: falha operacional na porta fechada, sem residuo.
            $workspaceBefore = Get-Snapshot $s.Workspace
            $r = Invoke-Prepare $s
            Assert-Equal 'Falha' $r.Status (Get-Codes $r)
            Assert-Equal 'MA_PREPARE_CLONE_FAILED:git clone 128' (Get-Blocking $r)
            Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'destino do clone deixado'
            Assert-SameSnapshot $workspaceBefore (Get-Snapshot $s.Workspace) 'workspace'
            Assert-True (-not [IO.File]::Exists($helper.Sentinel)) 'git-remote-https do PATH executado'
        } finally { Restore-SentinelEnvironment $saved }
    }
    It 'helper ssh selecionado depois da verificacao (vcs=ssh no SSH, ssh:: no HTTPS): fora do PATH restrito, alias vazio aborta e sem residuo' {
        foreach ($case in @(
                @{ Url = $Url; Extra = @('-c', 'remote.origin.vcs=ssh'); Name = 'vcs=ssh' },
                @{ Url = $HttpsUrl; Extra = @('-c', ('url.ssh::sequestrado.insteadOf=' + $HttpsUrl)); Name = 'insteadOf ssh::' })) {
            $s = New-PrepareScenario -RepositoryUrl $case.Url
            $helper = New-HelperSentinel ($s.Root + '-ssh') 'ssh'
            $saved = Use-SentinelEnvironment -PathDirectory $helper.Directory
            try {
                # Controle: o Git da fixture, com o PATH deste processo, executa o helper.
                [void](Invoke-FixtureGit ($s.Root + '-ssh') (@($case.Extra) + @('clone', '-q', '--no-checkout', '--', $case.Url, 'controle')) -AllowFailure)
                Assert-True ([IO.File]::Exists($helper.Sentinel)) ('controle: sentinela nao executada: ' + $case.Name)
                [IO.File]::Delete($helper.Sentinel)
                Use-FixtureOrigin $s
                Use-RecordingGit $case.Extra
                $workspaceBefore = Get-Snapshot $s.Workspace
                $originBefore = Get-Snapshot $s.Origin
                $r = Invoke-Prepare $s
                Assert-Equal 'Bloqueado' $r.Status ($case.Name + ': ' + (Get-Codes $r))
                Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:git clone 128; helper de transporte nao autorizado: ssh' (Get-Blocking $r) $case.Name
                Assert-Equal 1 @(Get-CloneCalls).Count ('clone nao chamado: ' + $case.Name)
                Assert-True (-not [IO.File]::Exists($helper.Sentinel)) ('git-remote-ssh do PATH executado: ' + $case.Name)
                Assert-Equal 0 @(Get-SshCalls $s).Count ('ssh executado: ' + $case.Name)
                Assert-Equal $false $r.Partial
                Assert-True (-not [IO.Directory]::Exists($s.Coordination)) ('destino do clone deixado: ' + $case.Name)
                Assert-SameSnapshot $workspaceBefore (Get-Snapshot $s.Workspace) 'workspace'
                Assert-SameSnapshot $originBefore (Get-Snapshot $s.Origin) 'remoto de origem'
            } finally { Restore-SentinelEnvironment $saved }
        }
    }
    It 'alias.remote-ssh com comando: recusado na verificacao e, surgido depois dela, nao executado' {
        $s = New-PrepareScenario
        $program = New-ProgramSentinel ($s.Root + '-ssh') 'alias-remote-ssh'
        $alias = 'alias.remote-ssh=!' + $program.Command
        # Controle: com vcs=ssh e sem helper no PATH, o Git da fixture executa o alias.
        [void](Invoke-FixtureGit ($s.Root + '-ssh') @('-c', 'remote.origin.vcs=ssh', '-c', $alias, 'clone', '-q', '--no-checkout', '--', $Url, 'controle') -AllowFailure)
        Assert-True ([IO.File]::Exists($program.Sentinel)) 'controle: alias nao executado'
        [IO.File]::Delete($program.Sentinel)
        # Na configuracao (linha de comando): recusado antes do clone.
        Use-FixtureOrigin $s @('-c', $alias)
        Use-RecordingGit
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:alias.remote-ssh (command)' (Get-Blocking $r)
        Assert-Equal 0 @(Get-CloneCalls).Count 'clone executado'
        # Surgido depois da verificacao, com vcs=ssh: o alias vazio fixado prevalece.
        Use-FixtureOrigin $s
        Use-RecordingGit @('-c', 'remote.origin.vcs=ssh', '-c', $alias)
        $r = Invoke-Prepare $s
        Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:git clone 128; helper de transporte nao autorizado: ssh' (Get-Blocking $r)
        Assert-Equal 1 @(Get-CloneCalls).Count 'clone nao chamado'
        Assert-True (-not [IO.File]::Exists($program.Sentinel)) 'alias executado'
        Assert-Equal 0 @(Get-SshCalls $s).Count 'ssh executado'
        Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'destino do clone deixado'
    }
    It 'comando SSH personalizado (core.sshCommand, GIT_SSH, GIT_SSH_COMMAND): recusado antes do clone; HTTPS nao afetado' {
        $s = New-PrepareScenario
        $program = New-ProgramSentinel ($s.Root + '-ssh') 'ssh-personalizado'
        # Controle: o Git da fixture executa o comando configurado.
        [void](Invoke-FixtureGit ($s.Root + '-ssh') @('-c', ('core.sshCommand=' + $program.Command), 'clone', '-q', '--no-checkout', '--', $Url, 'controle') -AllowFailure)
        Assert-True ([IO.File]::Exists($program.Sentinel)) 'controle: comando nao executado'
        [IO.File]::Delete($program.Sentinel)
        $workspaceBefore = Get-Snapshot $s.Workspace
        Use-FixtureOrigin $s @('-c', ('core.sshCommand=' + $program.Command))
        Use-RecordingGit
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'MA_REPOSITORY_SSH_COMMAND_UNSUPPORTED:core.sshCommand (command)' (Get-Blocking $r)
        Assert-Equal 0 @(Get-CloneCalls).Count 'clone executado'
        foreach ($case in @(@('GIT_SSH', $program.Program), @('GIT_SSH_COMMAND', $program.Command))) {
            [Environment]::SetEnvironmentVariable($case[0], $case[1])
            try {
                Use-FixtureOrigin $s
                Use-RecordingGit
                $r = Invoke-Prepare $s
                Assert-Equal ('MA_REPOSITORY_SSH_COMMAND_UNSUPPORTED:' + $case[0]) (Get-Blocking $r) $case[0]
                Assert-Equal 0 @(Get-CloneCalls).Count ('clone executado: ' + $case[0])
            } finally { [Environment]::SetEnvironmentVariable($case[0], $null) }
        }
        Assert-True (-not [IO.File]::Exists($program.Sentinel)) 'comando SSH personalizado executado'
        Assert-Equal 0 @(Get-SshCalls $s).Count 'ssh executado'
        Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'coordenacao criada'
        Assert-SameSnapshot $workspaceBefore (Get-Snapshot $s.Workspace) 'workspace'
        # HTTPS: o comando SSH do consumidor nao e recusado (o clone fixa o cliente da instalacao).
        Use-ConfigLevels ($s.Root + '-ssh')
        try {
            $https = Get-CloneTransport $s.Workspace $HttpsUrl @('-c', ('core.sshCommand=' + $program.Command))
            Assert-Equal 'https' $https.Transport (Get-Codes $https)
            Assert-Equal 0 @($https.Issues).Count (Get-Codes $https)
        } finally { Clear-ConfigLevels }
    }
    It 'core.sshCommand surgido depois da verificacao e ssh no PATH: clone pelo cliente SSH da instalacao, sentinelas intactas' {
        $loopbackSsh = 'ssh://git@127.0.0.1:9/org/demo.git'
        $s = New-PrepareScenario -RepositoryUrl $loopbackSsh
        $late = New-ProgramSentinel ($s.Root + '-ssh') 'ssh-tardio'
        $pathSsh = New-ProgramSentinel ($s.Root + '-ssh') 'ssh'
        $saved = Use-SentinelEnvironment -PathDirectory $pathSsh.Directory
        try {
            # Controles: o Git da fixture executa o ssh do PATH e o core.sshCommand.
            [void](Invoke-FixtureGit ($s.Root + '-ssh') @('clone', '-q', '--no-checkout', '--', $loopbackSsh, 'controle-path') -AllowFailure)
            Assert-True ([IO.File]::Exists($pathSsh.Sentinel)) 'controle: ssh do PATH nao executado'
            [void](Invoke-FixtureGit ($s.Root + '-ssh') @('-c', ('core.sshCommand=' + $late.Command), 'clone', '-q', '--no-checkout', '--', $loopbackSsh, 'controle-config') -AllowFailure)
            Assert-True ([IO.File]::Exists($late.Sentinel)) 'controle: core.sshCommand nao executado'
            foreach ($file in @($pathSsh.Sentinel, $late.Sentinel)) { [IO.File]::Delete($file) }
            # Sem o ponto de teste: o cliente SSH real da instalacao e recusado na porta fechada.
            Use-RecordingGit @('-c', ('core.sshCommand=' + $late.Command))
            $workspaceBefore = Get-Snapshot $s.Workspace
            $r = Invoke-Prepare $s
            Assert-Equal 'Falha' $r.Status (Get-Codes $r)
            Assert-Equal 'MA_PREPARE_CLONE_FAILED:git clone 128' (Get-Blocking $r)
            Assert-Equal 1 @(Get-CloneCalls).Count 'clone nao chamado'
            Assert-True (-not [IO.Directory]::Exists($s.Coordination)) 'destino do clone deixado'
            Assert-SameSnapshot $workspaceBefore (Get-Snapshot $s.Workspace) 'workspace'
            # Evidencia do cliente usado: mensagem do OpenSSH da instalacao no clone com -Transport.
            $target = [IO.Path]::Combine($s.Workspace, 'direto')
            $result = InModule { param($w, $a) Invoke-MaGit $w $a -Transport } @($s.Workspace, @('-c', ('core.sshCommand=' + $late.Command), '-c', 'alias.remote-ssh=', 'clone', '--no-checkout', '--', $loopbackSsh, $target))
            Assert-Equal 128 $result.ExitCode $result.StdErr
            Assert-True ([string]$result.StdErr -cmatch 'ssh: connect to host 127\.0\.0\.1 port 9: ') ('cliente SSH da instalacao nao executado: ' + $result.StdErr)
            Assert-True (-not [IO.Directory]::Exists($target)) 'destino deixado'
            Assert-True (-not [IO.File]::Exists($pathSsh.Sentinel)) 'ssh do PATH executado'
            Assert-True (-not [IO.File]::Exists($late.Sentinel)) 'core.sshCommand executado'
        } finally { Restore-SentinelEnvironment $saved }
    }

    Write-Output 'Filtros, atributos e condicoes nao suportadas no checkout'
    It 'filtro executavel na base clonada: clone preservado sem checkout e driver nao executado' {
        $s = New-PrepareScenario -SeedFiles @{ 'dados/.gitattributes' = "*.dat filter=sentinela`n"; 'dados/x.dat' = "conteudo`n" }
        $sentinel = [IO.Path]::Combine($s.Root, 'sentinela-filtro.txt')
        $filter = 'filter.sentinela.smudge=' + (Get-SentinelFilter $sentinel)
        # Controle: com checkout, o mesmo -c executaria o driver.
        $control = [IO.Path]::Combine($s.Root, 'controle')
        [void](Invoke-FixtureGit $s.Root @('-c', $filter, 'clone', '-q', (ConvertTo-FileUrl $s.Origin), $control))
        Assert-True ([IO.File]::Exists($sentinel)) 'controle: filtro nao executou'
        [IO.File]::Delete($sentinel)
        # O -c do teste chega somente ao clone do instalador, como uma configuracao do consumidor.
        Use-FixtureOrigin $s @('-c', $filter)
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_PREPARE_CHECKOUT_FILTER' 'coordination'
        Assert-Equal 'Clonar' ((@($r.Performed | ForEach-Object { $_.Operation })) -join ',')
        Assert-Equal $true $r.Partial
        Assert-True (-not [IO.File]::Exists($sentinel)) 'filtro executado'
        Assert-Equal '.git' ((@(Get-ChildItem -LiteralPath $s.Coordination -Force | ForEach-Object { $_.Name })) -join ',') 'checkout realizado'
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
        $plan = Invoke-MaPlan -ConfigPath $s.Config -PackageRoot $s.Package -BaseCommit $s.Base
        Assert-Equal 'CheckoutPendente' @($plan.Environments | Where-Object { $_.Role -eq 'coordination' })[0].State
        $before = Get-Snapshot $s.Workspace
        $again = Invoke-Prepare $s
        Assert-HasIssue $again 'MA_PREPARE_CHECKOUT_FILTER' 'coordination'
        Assert-Equal 0 @($again.Performed).Count
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
        Assert-True (-not [IO.File]::Exists($sentinel)) 'filtro executado na repeticao'
    }
    It 'checkout pendente com conflito governado: retomada verifica o filtro e recusa sem executar' {
        # .gitattributes da raiz divergente (conflito) e filtro aplicavel: a retomada
        # nao para no conflito antes de verificar o checkout.
        $s = New-PrepareScenario -SeedFiles @{ '.gitattributes' = "*.dat filter=sentinela`n"; 'dados.dat' = "conteudo`n" }
        $sentinel = [IO.Path]::Combine($s.Root, 'sentinela-filtro.txt')
        [void](Invoke-FixtureGit $s.Root @('clone', '-q', '--no-checkout', (ConvertTo-FileUrl $s.Origin), $s.Coordination))
        [void](Invoke-FixtureGit $s.Coordination @('remote', 'set-url', 'origin', $Url))
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'filter.sentinela.smudge', (Get-SentinelFilter $sentinel)))
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_CHECKOUT_FILTER' 'coordination'
        Assert-HasIssue $r 'MA_FILE_CONFLICT' 'coordination'
        Assert-Equal 0 @($r.Performed).Count
        Assert-True (-not [IO.File]::Exists($sentinel)) 'filtro executado'
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
    }
    It 'filtro configurado na coordenacao existente: nenhuma manutencao criada e configuracao intacta' {
        $s = New-PrepareScenario -SeedFiles @{ 'dados/.gitattributes' = "*.dat filter=sentinela`n"; 'dados/x.dat' = "conteudo`n" }
        New-FixtureClone $s
        $sentinel = [IO.Path]::Combine($s.Root, 'sentinela-filtro.txt')
        $command = Get-SentinelFilter $sentinel
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'filter.sentinela.smudge', $command))
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_PREPARE_CHECKOUT_FILTER' 'maintenance'
        Assert-Equal 0 @($r.Performed).Count
        Assert-True (-not [IO.File]::Exists($sentinel)) 'filtro executado'
        Assert-True (-not [IO.Directory]::Exists($s.Maintenance)) 'manutencao criada'
        Assert-Equal $command (Invoke-FixtureGit $s.Coordination @('config', '--local', '--get', 'filter.sentinela.smudge')) 'configuracao do consumidor alterada'
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
    }
    It 'attr.tree local e GIT_ATTR_SOURCE recusam o checkout sem criar nada' {
        $s = New-PrepareScenario; New-FixtureClone $s
        [void](Invoke-FixtureGit $s.Coordination @('config', '--local', 'attr.tree', 'HEAD'))
        $before = Get-Snapshot $s.Workspace
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_CHECKOUT_UNSUPPORTED' 'maintenance'
        Assert-Equal 0 @($r.Performed).Count
        Assert-SameSnapshot $before (Get-Snapshot $s.Workspace) 'workspace'
        Assert-Equal 'HEAD' (Invoke-FixtureGit $s.Coordination @('config', '--local', '--get', 'attr.tree'))
        $s2 = New-PrepareScenario; New-FixtureClone $s2
        [Environment]::SetEnvironmentVariable('GIT_ATTR_SOURCE', 'HEAD')
        try { $r = Invoke-Prepare $s2 } finally { [Environment]::SetEnvironmentVariable('GIT_ATTR_SOURCE', $null) }
        Assert-HasIssue $r 'MA_PREPARE_CHECKOUT_UNSUPPORTED' 'maintenance'
        Assert-True (-not [IO.Directory]::Exists($s2.Maintenance)) 'manutencao criada'
    }

    Write-Output 'Retomada, idempotencia e WhatIf com checkout pendente'
    It 'clone sem checkout deixado por execucao interrompida: WhatIf simula, retomada conclui e repeticao nao altera' {
        $s = New-PrepareScenario
        [void](Invoke-FixtureGit $s.Root @('clone', '-q', '--no-checkout', (ConvertTo-FileUrl $s.Origin), $s.Coordination))
        [void](Invoke-FixtureGit $s.Coordination @('remote', 'set-url', 'origin', $Url))
        $plan = Invoke-MaPlan -ConfigPath $s.Config -PackageRoot $s.Package -BaseCommit $s.Base
        Assert-Equal 'Incompleto' $plan.Status ((@($plan.Issues | ForEach-Object { $_.Code })) -join ',')
        Assert-HasIssue $plan 'MA_ENV_CHECKOUT_PENDING' 'coordination'
        $before = Get-Snapshot $s.Root
        $simulated = Invoke-Prepare $s -WhatIf
        Assert-Equal 'Incompleto' $simulated.Status (Get-Codes $simulated)
        Assert-Equal 'Checkout' ((@($simulated.Simulated | ForEach-Object { $_.Operation })) -join ',')
        Assert-SameSnapshot $before (Get-Snapshot $s.Root) 'WhatIf'
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 'coordination:Checkout,maintenance:Criar worktree,maintenance:Checkout' ((@($r.Performed | Where-Object { $_.Operation -cnotin @('Gerar', 'Criar diretorio') } | ForEach-Object { $_.Role + ':' + $_.Operation })) -join ',')
        Assert-Equal 11 @(Get-Performed $r 'Gerar').Count
        Assert-Equal "aplicacao`n" ([IO.File]::ReadAllText([IO.Path]::Combine($s.Coordination, 'app.txt')).Replace("`r", ''))
        Assert-Equal '' (Invoke-FixtureGit $s.Coordination @('status', '--porcelain')) 'coordenacao divergente apos o checkout'
        Assert-MaintenanceGenerated $s
        $after = Get-Snapshot $s.Workspace
        $again = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $again.Status (Get-Codes $again)
        Assert-Equal 0 @($again.Performed).Count
        Assert-SameSnapshot $after (Get-Snapshot $s.Workspace) 'workspace'
    }
    It 'worktree de manutencao sem checkout deixado por execucao interrompida: retomada conclui a preparacao' {
        $s = New-PrepareScenario; New-FixtureClone $s
        [void](Invoke-FixtureGit $s.Coordination @('worktree', 'add', '-q', '--no-checkout', '-b', 'chore/manutencao', $s.Maintenance, $s.Base))
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 'maintenance' ((@(Get-Performed $r 'Checkout' | ForEach-Object { $_.Role })) -join ',')
        Assert-Equal 0 @(Get-Performed $r 'Criar worktree').Count
        Assert-Equal 11 @(Get-Performed $r 'Gerar').Count
        Assert-MaintenanceGenerated $s
        Assert-Equal 'Sucesso' (Invoke-Prepare $s).Status 'repeticao'
    }

    Write-Output 'Ponta a ponta pelo ponto de entrada'
    It 'PrepareMaintenance pelo ponto de entrada: codigo 0, depois Plan codigo 0' {
        $s = New-PrepareScenario; New-FixtureClone $s
        $run = Invoke-EntryPoint $s @('-Phase', 'PrepareMaintenance', '-AuthorizationReference', $Authorization, '-BaseCommit', $s.Base)
        Assert-Equal 0 $run.Code $run.Text
        Assert-True ($run.Text.Contains('Fase: PrepareMaintenance')) $run.Text
        Assert-True ($run.Text.Contains('Resultado: Sucesso')) $run.Text
        Assert-True ($run.Text.Contains('Modificacoes realizadas: 17 operacao(oes)')) $run.Text
        Assert-True (-not $run.Text.Contains($Authorization)) 'referencia de autorizacao reproduzida no relatorio'
        Assert-MaintenanceGenerated $s
        $plan = Invoke-EntryPoint $s @('-BaseCommit', $s.Base)
        Assert-Equal 0 $plan.Code $plan.Text
        Assert-True ($plan.Text.Contains('PreparadoNaoCommitado')) $plan.Text
    }
    It 'ponto de entrada com -WhatIf: codigo 2 e nenhuma modificacao' {
        $s = New-PrepareScenario; New-FixtureClone $s
        $before = Get-Snapshot $s.Root
        $run = Invoke-EntryPoint $s @('-Phase', 'PrepareMaintenance', '-AuthorizationReference', $Authorization, '-BaseCommit', $s.Base, '-WhatIf')
        Assert-Equal 2 $run.Code $run.Text
        Assert-True ($run.Text.Contains('Nenhuma modificacao foi realizada.')) $run.Text
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'ponto de entrada com conflito: codigo 3 e nenhuma modificacao' {
        $s = New-PrepareScenario -Readme ($Utf8.GetBytes("# demo`n")); New-FixtureClone $s
        $before = Get-Snapshot $s.Root
        $run = Invoke-EntryPoint $s @('-Phase', 'PrepareMaintenance', '-AuthorizationReference', $Authorization, '-BaseCommit', $s.Base)
        Assert-Equal 3 $run.Code $run.Text
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'fluxo completo: preparar, commit humano na manutencao e Plan conforme' {
        $s = New-PrepareScenario; Use-FixtureOrigin $s
        Assert-Equal 'Sucesso' (Invoke-Prepare $s).Status
        # Etapas humanas fora do instalador: indice com modos e commit na manutencao.
        Save-Commit $s.Maintenance 'governanca'
        $tree = Invoke-FixtureGit $s.Maintenance @('ls-tree', '-r', 'HEAD', '--', '.githooks')
        Assert-True ($tree -match '100755 blob [0-9a-f]+\s+\.githooks/pre-commit') $tree
        $plan = Invoke-MaPlan -ConfigPath $s.Config -PackageRoot $s.Package -BaseCommit $s.Base
        Assert-Equal 'Sucesso' $plan.Status ((@($plan.Issues | ForEach-Object { $_.Code })) -join ',')
        Assert-Equal 11 @($plan.Files | Where-Object { $_.Role -eq 'maintenance' -and $_.Classification -eq 'Identico' }).Count
    }
} finally {
    InModule { $script:MaGitInvoker = $null; $script:MaCloneTestArguments = @(); $script:MaSshTestCommand = $null }
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
