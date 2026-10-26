#Requires -Version 5.1
<#
Testes unitarios da fase PrepareMaintenance. Autocontidos: nao dependem de
Pester (a versao 5 fixada ainda nao foi distribuida). Fixtures sao descartaveis,
criadas sob o TEMP do executor e nunca apontam para o projeto atual.
Repositorios sao simulados: nenhum repositorio Git e criado, alterado ou
consultado; o Git real e usado somente fora de repositorios (--version e
check-ref-format) no caso do ponto de entrada. Nenhum caso usa WMI/CIM nem
provoca escape de processos da contencao do executor.

Uso: powershell -NoProfile -File tests/unit/PrepareMaintenance.Unit.Tests.ps1
Codigo de saida: 0 quando todos os casos passam; 1 se algum caso falha; 2 se
nenhum falha, mas algum caso nao pode ser executado por pre-requisito ausente
(nunca contado como aprovado).

Pre-requisitos exigidos por caso:
  Git  Git for Windows >= 2.44 localizado no PATH.
  Job  Executor seguro disponivel (job com KILL_ON_JOB_CLOSE).
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PackageSource = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
$Module = Import-Module -Name ([IO.Path]::Combine($PackageSource, 'scripts', 'MultiAgentTemplate.psm1')) -Force -PassThru -DisableNameChecking
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Base = 'a' * 40
$Authorization = 'registro-humano-ficticio#unit'
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:Blocked = New-Object System.Collections.Generic.List[string]
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]
$script:GitCalls = New-Object System.Collections.Generic.List[string]
$script:Repos = @{}
$script:Objects = @{}
$script:Prereq = @{}
$script:IndexStub = $null
$script:ExecPath = $null
$script:OriginVcs = $null
$script:OriginUrlConfig = $null
$script:GetUrl = $null
$script:CloneStdErr = $null
$script:AliasRemoteSsh = $null
$script:SshCommandConfig = $null
$script:TransportCalls = New-Object System.Collections.Generic.List[string]

# --- Mini-harness -----------------------------------------------------------------

function It {
    param([string]$Name, [scriptblock]$Body, [string[]]$Requires = @())
    $missing = @($Requires | Where-Object { -not $script:Prereq[$_] })
    if ($missing.Count -gt 0) {
        $script:Blocked.Add($Name + ' :: ausente: ' + ($missing -join ', '))
        Write-Output ('  [PRE-REQ] ' + $Name + ' :: ausente: ' + ($missing -join ', '))
        return
    }
    try { & $Body; $script:Passed++; Write-Output ('  [ok]    ' + $Name) }
    catch { $script:Failed.Add($Name + ' :: ' + $_.Exception.Message); Write-Output ('  [FALHA] ' + $Name + ' :: ' + $_.Exception.Message) }
    finally { InModule { $script:MaGitInvoker = $null } }
}
function Assert-Equal { param($Expected, $Actual, [string]$Message = '') if (-not [object]::Equals($Expected, $Actual)) { throw ('esperado <' + $Expected + '> obtido <' + $Actual + '> ' + $Message) } }
function Assert-True { param([bool]$Condition, [string]$Message = 'condicao falsa') if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Body, [string]$Code)
    $thrown = $null
    try { & $Body } catch { $thrown = $_.Exception.Message }
    if ($null -eq $thrown) { throw ('nenhuma excecao; esperado ' + $Code) }
    if ($thrown -cne $Code) { throw ('esperado ' + $Code + ' obtido ' + $thrown) }
}
function Get-Codes { param($Result) return ((@($Result.Issues | ForEach-Object { $_.Code + '@' + $_.Role })) -join ', ') }
function Assert-HasIssue {
    param($Result, [string]$Code, [string]$Role = '')
    if (@($Result.Issues | Where-Object { $_.Code -ceq $Code -and ($Role -eq '' -or $_.Role -eq $Role) }).Count -eq 0) { throw ('impedimento ausente: ' + $Code + ' | presentes: ' + (Get-Codes $Result)) }
}
function InModule { param([scriptblock]$Body, [object[]]$Arguments = @()) return (& $Module $Body @Arguments) }

# --- Fixtures ---------------------------------------------------------------------

function New-FixtureRoot {
    $path = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ma-prep-tests-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    $script:FixtureRoots.Add($path)
    return $path
}

function Write-FixtureFile {
    param([string]$Path, [AllowEmptyCollection()][byte[]]$Bytes)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $algorithm.Dispose() }
}

function New-FixturePackage {
    param([string]$Root)
    $package = [IO.Path]::Combine($Root, 'pacote')
    $copy = @('schema/project.schema.json', 'scripts/MultiAgentTemplate.psm1', 'scripts/Install-MultiAgentProject.ps1')
    foreach ($relative in @('AGENTS.md', 'CLAUDE.md', 'README.md', '.gitattributes', '.githooks/pre-commit', '.githooks/pre-push',
            'docs/agentes/coordenacao.md', 'docs/agentes/desenvolvimento.md', 'docs/agentes/manutencao.md', 'docs/agentes/revisao.md')) { $copy += 'templates/' + $relative + '.tmpl' }
    $placeholders = @('AGENTS.md', 'CLAUDE.md', '.gitattributes', '.githooks/pre-commit', '.githooks/pre-push', 'docs/especificacao-v1.md',
        'docs/errata-especificacao-v1.1.md', 'docs/agentes/coordenacao.md', 'docs/agentes/desenvolvimento.md', 'docs/agentes/manutencao.md', 'docs/agentes/revisao.md')
    $entries = New-Object System.Collections.Generic.List[string]
    $all = @()
    foreach ($relative in $copy) { $all += , @($relative, [IO.File]::ReadAllBytes([IO.Path]::Combine($PackageSource, $relative.Replace('/', '\')))) }
    foreach ($relative in $placeholders) { $all += , @($relative, $Utf8.GetBytes("ficticio`n")) }
    foreach ($item in ($all | Sort-Object { $_[0] })) {
        Write-FixtureFile ([IO.Path]::Combine($package, $item[0].Replace('/', '\'))) $item[1]
        $mode = '100644'; if ($item[0] -like '.githooks/*') { $mode = '100755' }
        $entries.Add('    { "path": "' + $item[0] + '", "sha256": "' + (Get-Sha256Hex $item[1]) + '", "gitMode": "' + $mode + '" }')
    }
    $manifest = "{`n  `"distributionVersion`": `"0.0.0-teste`",`n  `"specificationVersion`": `"1.1`",`n  `"compatibleSchemaVersions`": [`"1.0`"],`n  `"integrityAlgorithm`": `"SHA-256`",`n  `"files`": [`n" + ($entries -join ",`n") + "`n  ]`n}`n"
    Write-FixtureFile ([IO.Path]::Combine($package, 'package.manifest.json')) $Utf8.GetBytes($manifest)
    return $package
}

function New-Scenario {
    $root = New-FixtureRoot
    $workspace = [IO.Path]::Combine($root, 'ws')
    [void][IO.Directory]::CreateDirectory($workspace)
    $package = New-FixturePackage $root
    $config = [IO.Path]::Combine($root, 'multiagente.config.json')
    Write-FixtureFile $config $Utf8.GetBytes('{"schemaVersion":"1.0","project":{"name":"Projeto Demo","slug":"demo"},"repository":{"url":"https://example.invalid/org/demo.git"},"workspace":{"parentDirectory":' + ($workspace | ConvertTo-Json) + '}}')
    $model = Read-MaConfiguration -LiteralPath $config -SchemaPath ([IO.Path]::Combine($package, 'schema', 'project.schema.json'))
    $rendered = Get-MaRenderedFiles -PackageRoot $package -Configuration $model -DistributionVersion '0.0.0-teste'
    return [pscustomobject]@{ Root = $root; Workspace = $workspace; Package = $package; Config = $config; Model = $model; Rendered = $rendered }
}

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
    throw ('estado alterado: ' + ($diff -join ' || '))
}

# --- Git simulado --------------------------------------------------------------------
# Leituras da inspecao como na suite do Plan, mais as leituras de PrepareMaintenance.
# Comandos mutaveis do instalador (clone e worktree add) sao registrados e falham:
# nenhum caso unitario depende de sua execucao.

function New-RepoState {
    param([string]$Path, [string]$Branch = 'main', [string]$CommonDir = $null)
    if (-not $CommonDir) { $CommonDir = [IO.Path]::Combine($Path, '.git') }
    return @{
        TopLevel = $Path.Replace('\', '/'); CommonDir = $CommonDir.Replace('\', '/'); Symbolic = ('refs/heads/' + $Branch); Head = $Base
        Origin = @('https://example.invalid/org/demo.git'); Worktrees = @(); HooksPath = @(); Refs = @(('refs/heads/' + $Branch + [char]0 + $Base))
        Tracked = @(); Attributes = @{}; Status = @(); Ignored = @(); GlobalHooks = @()
        # Verificacao previa do checkout: arvore do commit, attr.tree e core.fsmonitor.
        CommitTree = @(); AttrTree = @(); Fsmonitor = @(); IndexFileMissing = $false
    }
}

$GitMock = {
    param([string]$WorkingDirectory, [string[]]$Arguments, [bool]$Binary, [string]$InputText, [bool]$Transport)
    $script:GitCalls.Add(($Arguments -join ' '))
    # Chamadas com o ambiente de transporte (Invoke-MaGit -Transport).
    if ($Transport) { $script:TransportCalls.Add(($Arguments -join ' ')) }
    # -c do instalador antes do subcomando (remote.origin.vcs fixado no clone HTTPS).
    $offset = 0; while ($offset + 1 -lt $Arguments.Count -and $Arguments[$offset] -ceq '-c') { $offset += 2 }
    if ($offset -gt 0) { $Arguments = $Arguments[$offset..($Arguments.Count - 1)] }
    $ok ={ param([string]$Out) [pscustomobject]@{ ExitCode = 0; StdOut = $Out; StdErr = '' } }
    $fail = { param([int]$Code) [pscustomobject]@{ ExitCode = $Code; StdOut = ''; StdErr = 'simulado' } }
    $nul = [string][char]0
    $command = $Arguments -join ' '
    if ($command -ceq '--version') { return (& $ok "git version 2.52.0.windows.1`n") }
    if ($command -ceq '--exec-path') { return (& $ok ($script:ExecPath + "`n")) }
    if ($Arguments[0] -ceq 'check-ref-format') { return (& $ok ($Arguments[2] + "`n")) }
    if ($command -ceq 'config -z --show-scope --get-all core.hooksPath' -and -not $script:Repos.ContainsKey($WorkingDirectory)) {
        if ($script:GlobalHooks.Count -eq 0) { return (& $fail 1) }
        return (& $ok ((@($script:GlobalHooks | ForEach-Object { 'global' + $nul + $_ + $nul })) -join ''))
    }
    if ($command -ceq 'config -z --show-scope --get-all init.templateDir') { return (& $fail 1) }
    # Transporte do clone: remote.origin.vcs (ausente, valor ou codigo de falha) e
    # expansao da URL (por padrao, sem reescrita).
    if ($command -ceq 'config -z --show-scope --get-all remote.origin.vcs') {
        if ($null -eq $script:OriginVcs) { return (& $fail 1) }
        if ($script:OriginVcs -is [int]) { return (& $fail $script:OriginVcs) }
        return (& $ok ('global' + $nul + $script:OriginVcs + $nul))
    }
    if ($command -ceq 'config -z --show-scope --get-all remote.origin.url') {
        if ($null -eq $script:OriginUrlConfig) { return (& $fail 1) }
        if ($script:OriginUrlConfig -is [int]) { return (& $fail $script:OriginUrlConfig) }
        return (& $ok ('global' + $nul + $script:OriginUrlConfig + $nul))
    }
    # alias.remote-ssh e core.sshCommand: ausente, valor (escopo global) ou codigo de falha.
    foreach ($entry in @(@('alias.remote-ssh', $script:AliasRemoteSsh), @('core.sshCommand', $script:SshCommandConfig))) {
        if ($command -ceq ('config -z --show-scope --get-all ' + $entry[0])) {
            if ($null -eq $entry[1]) { return (& $fail 1) }
            if ($entry[1] -is [int]) { return (& $fail $entry[1]) }
            return (& $ok ('global' + $nul + $entry[1] + $nul))
        }
    }
    if ($Arguments[0] -ceq 'ls-remote' -and $Arguments[1] -ceq '--get-url' -and $Arguments[2] -ceq '--') {
        if ($null -ne $script:GetUrl) { return (& $script:GetUrl $Arguments[3]) }
        return (& $ok ($Arguments[3] + "`n"))
    }
    if ($Arguments[0] -ceq 'clone' -and $null -ne $script:CloneStdErr) { return [pscustomobject]@{ ExitCode = 128; StdOut = ''; StdErr = $script:CloneStdErr } }
    if ($Arguments[0] -cin @('clone', 'worktree', 'read-tree') -and $command -cne 'worktree list --porcelain -z') { return (& $fail 128) }
    $repo = $null
    foreach ($key in $script:Repos.Keys) { if ($key.Equals($WorkingDirectory, [StringComparison]::OrdinalIgnoreCase)) { $repo = $script:Repos[$key] } }
    if ($null -eq $repo) { return (& $fail 128) }
    if ($command.StartsWith('rev-parse --path-format=absolute --show-toplevel')) { return (& $ok (($repo.TopLevel, $repo.CommonDir, 'false', 'false', 'sha1') -join "`n")) }
    if ($command.StartsWith('config -z --get-regexp')) { return (& $fail 1) }
    if ($command -ceq 'symbolic-ref --quiet HEAD') { return (& $ok ($repo.Symbolic + "`n")) }
    if ($command -ceq 'rev-parse --verify --quiet HEAD^{commit}') { if ($repo.Head) { return (& $ok ($repo.Head + "`n")) } else { return (& $fail 1) } }
    if ($command -ceq 'config -z --get-all remote.origin.url') { return (& $ok ((@($repo.Origin | ForEach-Object { $_ + $nul })) -join '')) }
    if ($command -ceq 'worktree list --porcelain -z') { return (& $ok ((@($repo.Worktrees | ForEach-Object { $_ + $nul + $nul })) -join '')) }
    if ($command.StartsWith('config -z --show-scope --show-origin --get-all core.hooksPath')) {
        if ($repo.HooksPath.Count -eq 0) { return (& $fail 1) }
        return (& $ok ((@($repo.HooksPath | ForEach-Object { $_ + $nul })) -join ''))
    }
    if ($command -ceq 'rev-parse --path-format=absolute --git-path hooks') { return (& $ok ($repo.CommonDir + "/hooks`n")) }
    if ($command -ceq 'rev-parse --path-format=absolute --git-path index') {
        if ($repo.IndexFileMissing) { return (& $ok ($repo.CommonDir + "/index-ausente`n")) }
        return (& $ok ($script:IndexStub.Replace('\', '/') + "`n"))
    }
    if ($command -ceq 'rev-parse --verify --quiet HEAD^{tree}') { return (& $ok (('c' * 40) + "`n")) }
    foreach ($key in @('attr.tree', 'core.fsmonitor')) {
        if ($command -ceq ('config -z --show-scope --get-all ' + $key)) {
            $values = @($repo.AttrTree); if ($key -ceq 'core.fsmonitor') { $values = @($repo.Fsmonitor) }
            if ($values.Count -eq 0) { return (& $fail 1) }
            return (& $ok ((@($values | ForEach-Object { $_ + $nul })) -join ''))
        }
    }
    # Arvore completa do commit (verificacao previa do checkout) e arvore do HEAD (inspecao).
    if ($Arguments[0] -ceq 'ls-tree' -and $Arguments[$Arguments.Count - 1] -cne 'HEAD') { return (& $ok ((@($repo.CommitTree | ForEach-Object { $_ + $nul })) -join '')) }
    if ($Arguments[0] -ceq 'ls-tree') { return (& $ok '') }
    if ($command -ceq 'ls-files -z') { return (& $ok ((@($repo.Tracked | ForEach-Object { $_ + $nul })) -join '')) }
    if ($Arguments[0] -ceq 'ls-files') { return (& $ok '') }
    if ($Arguments[0] -ceq 'cat-file' -and $Arguments[1] -ceq '-e' -and $Arguments[2].EndsWith('^{commit}')) { return (& $ok '') }
    if ($Arguments[0] -ceq 'for-each-ref') { return (& $ok ((@($repo.Refs | ForEach-Object { $_ + "`n" })) -join '')) }
    if ($Arguments[0] -ceq 'check-attr') {
        $out = ''
        foreach ($path in @(([string]$InputText).Split([char]0) | Where-Object { $_ })) {
            $value = 'unspecified'; if ($repo.Attributes.ContainsKey($path)) { $value = $repo.Attributes[$path] }
            $out += $path + $nul + 'filter' + $nul + $value + $nul
        }
        return (& $ok $out)
    }
    if ($Arguments[0] -ceq 'status') { return (& $ok ((@($repo.Status | ForEach-Object { $_ + $nul })) -join '')) }
    if ($Arguments[0] -ceq 'check-ignore') {
        $hits = @(([string]$InputText).Split([char]0) | Where-Object { $_ -and $repo.Ignored -ccontains $_ })
        if ($hits.Count -eq 0) { return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = '' } }
        return (& $ok ((@($hits | ForEach-Object { $_ + $nul })) -join ''))
    }
    return (& $fail 129)
}

function Use-GitMock {
    if (-not $script:IndexStub) { $script:IndexStub = [IO.Path]::Combine((New-FixtureRoot), 'index'); [IO.File]::WriteAllBytes($script:IndexStub, [byte[]]@()) }
    # Diretorio de execucao ficticio: modelos padrao inexistentes, sem hooks.
    $script:ExecPath = 'C:/ma-inexistente-' + [Guid]::NewGuid().ToString('N') + '/mingw64/libexec/git-core'
    $script:OriginVcs = $null; $script:OriginUrlConfig = $null; $script:GetUrl = $null; $script:CloneStdErr = $null
    $script:AliasRemoteSsh = $null; $script:SshCommandConfig = $null; $script:TransportCalls.Clear()
    $script:GitCalls.Clear(); $script:Repos = @{}; $script:GlobalHooks = @(); InModule { param($m) $script:MaGitInvoker = $m } @(, $GitMock)
    Use-SimulatedTransport
}

# Ambiente de transporte simulado (o Git real o definiria em Get-MaGitContext).
function Use-SimulatedTransport {
    param([switch]$WithoutSsh, [switch]$Unavailable)
    $transport = [pscustomobject]@{ GitPath = 'C:\ma-simulado\mingw64\bin\git.exe'; Path = 'C:\ma-simulado\mingw64\bin'; Ssh = 'C:\ma-simulado\usr\bin\ssh.exe'; SshCommand = "'C:/ma-simulado/usr/bin/ssh.exe'" }
    if ($WithoutSsh) { $transport.Ssh = $null }
    if ($Unavailable) { $transport = $null }
    InModule { param($t) $script:MaGitTransport = $t } @(, $transport)
}

function New-Coordination {
    param($Scenario)
    $path = $Scenario.Model.Worktrees.coordination
    [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($path, '.git'))
    Write-FixtureFile ([IO.Path]::Combine($path, 'app.txt')) $Utf8.GetBytes("aplicacao`n")
    $repo = New-RepoState $path
    $repo.Worktrees = @('worktree ' + $path.Replace('\', '/') + [char]0 + 'HEAD ' + $Base + [char]0 + 'branch refs/heads/main')
    $script:Repos[$path] = $repo
    return $repo
}

function New-LinkedWorktree {
    param($Scenario, [string]$Role, [hashtable]$Coordination)
    $path = $Scenario.Model.Worktrees[$Role]
    Write-FixtureFile ([IO.Path]::Combine($path, '.git')) $Utf8.GetBytes("gitdir: x`n")
    $repo = New-RepoState $path $Scenario.Model.Branches[$Role] $Coordination.CommonDir.Replace('/', '\')
    $Coordination.Worktrees += ('worktree ' + $path.Replace('\', '/') + [char]0 + 'HEAD ' + $Base + [char]0 + 'branch refs/heads/' + $Scenario.Model.Branches[$Role])
    $Coordination.Refs += ('refs/heads/' + $Scenario.Model.Branches[$Role] + [char]0 + $Base)
    $script:Repos[$path] = $repo
    return $repo
}

function Invoke-Prepare {
    param($Scenario, [string]$BaseCommit = $Base, [string]$AuthorizationReference = $Authorization, [switch]$WhatIf)
    return (Invoke-MaPrepareMaintenance -ConfigPath $Scenario.Config -PackageRoot $Scenario.Package -AuthorizationReference $AuthorizationReference -BaseCommit $BaseCommit -WhatIfRequested:$WhatIf)
}

# Somente leituras e as duas operacoes autorizadas; nunca indice, commit, push ou configuracao
# (inclusive precedidos de -c do instalador).
$ForbiddenGit = '\A(?:-c \S+ )*(?:add|commit|update-index|push|fetch|pull|merge(?! --is-ancestor)|rebase|reset|checkout|switch|restore|branch|tag|stash|clean|rm|mv|gc|config (?!-z ))\b'
function Assert-NoForbiddenGit { foreach ($call in $script:GitCalls) { Assert-True ($call -cnotmatch $ForbiddenGit) ('comando Git proibido: ' + $call) } }
function Assert-NoMutatingGit { foreach ($call in $script:GitCalls) { Assert-True ($call -cnotmatch '\A(?:-c \S+ )*(?:clone|worktree add|read-tree)\b') ('operacao mutavel executada: ' + $call) } }

# Nome do mutex de um diretorio de trabalho e de uma coordenacao, pela cadeia fixada.
function Get-LockName {
    param([string]$Workspace, [string]$Coordination)
    return (InModule { param($w, $c) $chain = Open-MaDirectoryChain $w; try { Get-MaRepositoryLockName (Get-MaWorkspaceLockIdentity $chain $c) } finally { [void](Close-MaPinnedChain $chain) } } @($Workspace, $Coordination))
}
function Use-Faults { param([hashtable]$Faults) InModule { param($f) $script:MaNativeFaults = $f } @(, $Faults) }
function Clear-Faults { InModule { $script:MaNativeFaults = @{}; $script:MaFileApi = $null } }

# Detentor do mutex em outra thread (o mutex e reentrante na mesma thread).
function Start-LockHolder {
    param([string]$Name, [switch]$Abandon)
    $holder = [powershell]::Create()
    $holder.Runspace = [runspacefactory]::CreateRunspace()
    $holder.Runspace.ThreadOptions = 'UseNewThread'
    $holder.Runspace.Open()
    $ready = New-Object System.Threading.ManualResetEvent($false)
    $release = New-Object System.Threading.ManualResetEvent($false)
    [void]$holder.AddScript({
        param($n, $r1, $r2, $abandon)
        $m = New-Object System.Threading.Mutex($false, $n); [void]$m.WaitOne(); [void]$r1.Set()
        if (-not $abandon) { [void]$r2.WaitOne(30000); $m.ReleaseMutex() }
    }).AddArgument($Name).AddArgument($ready).AddArgument($release).AddArgument([bool]$Abandon)
    $handle = $holder.BeginInvoke()
    if (-not $ready.WaitOne(10000)) { throw 'detentor do mutex nao iniciou' }
    return [pscustomobject]@{ PowerShell = $holder; Handle = $handle; Release = $release }
}
function Stop-LockHolder {
    param($Holder)
    [void]$Holder.Release.Set(); [void]$Holder.PowerShell.EndInvoke($Holder.Handle)
    $Holder.PowerShell.Runspace.Dispose(); $Holder.PowerShell.Dispose()
}

# --- Ambiente e pre-requisitos ------------------------------------------------------------

Write-Output ('PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
$overrideNames = InModule { $script:MaGitOverrideVariables }
$SavedGitEnvironment = [ordered]@{}
foreach ($variable in @(Get-ChildItem Env:)) {
    if ($variable.Name -in $overrideNames -or $variable.Name -match '\AGIT_CONFIG_(?:KEY|VALUE)_[0-9]+\z' -or $variable.Name -in @('GIT_TEMPLATE_DIR', 'GIT_SSH', 'GIT_SSH_COMMAND')) {
        $SavedGitEnvironment[$variable.Name] = $variable.Value
        [Environment]::SetEnvironmentVariable($variable.Name, [NullString]::Value)
    }
}
$gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$script:Prereq.Git = ($null -ne $gitCommand)
$script:Prereq.Job = $false
if ($script:Prereq.Git) {
    Write-Output ('Pre-requisito Git: ' + $gitCommand.Path)
    try { [void](InModule { param($p) Invoke-MaNativeProcess -FilePath $p -Arguments @('--version') -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMilliseconds 30000 } @($gitCommand.Path)); $script:Prereq.Job = $true; Write-Output 'Pre-requisito Job: executor seguro disponivel' }
    catch { Write-Output ('Pre-requisito Job: indisponivel (' + $_.Exception.Message + ')') }
}

try {
    Write-Output 'Evidencias de autorizacao'
    It 'AuthorizationReference: obrigatoria, uma linha, sem controles e com limite' {
        $check = { param($v) InModule { param($x) Get-MaAuthorizationReferenceIssue $x } @(, $v) }
        Assert-Equal 'MA_AUTHORIZATION_REFERENCE_REQUIRED' (& $check '')
        Assert-Equal 'MA_AUTHORIZATION_REFERENCE_REQUIRED' (& $check '   ')
        Assert-Equal 'MA_AUTHORIZATION_REFERENCE_INVALID' (& $check "a`nb")
        Assert-Equal 'MA_AUTHORIZATION_REFERENCE_INVALID' (& $check ('a' + [char]0x202E + 'b'))
        Assert-Equal 'MA_AUTHORIZATION_REFERENCE_INVALID' (& $check ('a' + [char]0x2028))
        Assert-Equal 'MA_AUTHORIZATION_REFERENCE_INVALID' (& $check ('x' * 501))
        Assert-Equal $null (& $check ('x' * 500))
        Assert-Equal $null (& $check 'https://example.invalid/org/demo/pull/7#aprovacao-humana')
    }

    Write-Output 'Exclusao mutua'
    It 'nome do mutex deriva da identidade do diretorio fixado, nao da grafia do caminho' {
        $parent = New-FixtureRoot
        $workspace = [IO.Path]::Combine($parent, 'Area de Trabalho Longa')
        [void][IO.Directory]::CreateDirectory($workspace)
        $name = Get-LockName $workspace ([IO.Path]::Combine($workspace, 'demo'))
        Assert-True ($name -cmatch '\AGlobal\\MultiAgente-[0-9a-f]{64}\z') $name
        Assert-Equal $name (Get-LockName ($workspace.ToUpperInvariant() + '\') ([IO.Path]::Combine($workspace.ToLowerInvariant(), 'DEMO'))) 'caixa e barra final'
        # Nome curto 8.3 do mesmo diretorio, quando o volume o mantem.
        $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($workspace).ShortPath
        if ($short -cne $workspace -and $short.IndexOf('~') -ge 0) { Assert-Equal $name (Get-LockName $short ([IO.Path]::Combine($short, 'demo'))) ('nome curto ' + $short) }
        else { Write-Output '          (volume sem nomes 8.3: comparacao por nome curto nao aplicavel)' }
        Assert-True ($name -cne (Get-LockName $workspace ([IO.Path]::Combine($workspace, 'demo2')))) 'coordenacao distinta'
        $other = [IO.Path]::Combine($parent, 'outra'); [void][IO.Directory]::CreateDirectory($other)
        Assert-True ($name -cne (Get-LockName $other ([IO.Path]::Combine($other, 'demo')))) 'diretorio distinto'
        # Mesmo caminho, outro objeto: o nome acompanha o diretorio, nao o texto.
        [IO.Directory]::Move($workspace, $workspace + '-antigo'); [void][IO.Directory]::CreateDirectory($workspace)
        Assert-True ($name -cne (Get-LockName $workspace ([IO.Path]::Combine($workspace, 'demo')))) 'diretorio substituido no mesmo caminho'
    }
    It 'mutex ocupado por outra thread recusa; liberado, e obtido' {
        $name = InModule { param($x) Get-MaRepositoryLockName $x } @('teste-' + [Guid]::NewGuid().ToString('N'))
        $holder = Start-LockHolder $name
        try { Assert-Throws { InModule { param($x) Enter-MaRepositoryLock $x } @($name) } 'MA_PREPARE_LOCKED' }
        finally { Stop-LockHolder $holder }
        $lock = InModule { param($x) Enter-MaRepositoryLock $x } @($name)
        Assert-Equal $false $lock.Abandoned
        InModule { param($l) Exit-MaRepositoryLock $l } @($lock)
    }
    It 'mutex abandonado por execucao interrompida e obtido e informado' {
        $name = InModule { param($x) Get-MaRepositoryLockName $x } @('teste-' + [Guid]::NewGuid().ToString('N'))
        Stop-LockHolder (Start-LockHolder $name -Abandon)
        $lock = InModule { param($x) Enter-MaRepositoryLock $x } @($name)
        try { Assert-Equal $true $lock.Abandoned } finally { InModule { param($l) Exit-MaRepositoryLock $l } @($lock) }
    }
    It 'configuracao alterada depois do mutex: bloqueio sem operacao em nenhum dos destinos' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        [void](New-LinkedWorktree $s 'maintenance' $coordination)
        $script:OtherWorkspace = [IO.Path]::Combine($s.Root, 'ws-b')
        [void][IO.Directory]::CreateDirectory($script:OtherWorkspace)
        $script:ConfigPath = $s.Config
        $beforeA = Get-Snapshot $s.Workspace
        Use-Faults @{ PrepareLocked = {
            param($c)
            $json = '{"schemaVersion":"1.0","project":{"name":"Projeto Demo","slug":"demo"},"repository":{"url":"https://example.invalid/org/demo.git"},"workspace":{"parentDirectory":' + ($script:OtherWorkspace | ConvertTo-Json) + '}}'
            [IO.File]::WriteAllBytes($script:ConfigPath, (New-Object System.Text.UTF8Encoding($false)).GetBytes($json))
            $false
        } }
        try { $r = Invoke-Prepare $s } finally { Clear-Faults }
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_PREPARE_CONFIG_CHANGED'
        Assert-Equal 0 @($r.Performed).Count
        Assert-NoMutatingGit
        Assert-SameSnapshot $beforeA (Get-Snapshot $s.Workspace)
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:OtherWorkspace -Force).Count 'gravado no destino relido'
    }

    Write-Output 'Gravacao de destinos governados'
    $writeFile = { param($r, $p, $b) InModule { param($a, $c, $d) New-MaGovernedFile $a $c $d } @($r, $p, $b) }
    It 'cria diretorios ausentes, grava os bytes exatos e informa os diretorios criados' {
        $root = New-FixtureRoot
        $bytes = $Utf8.GetBytes("conteudo`n")
        $created = & $writeFile $root 'docs/agentes/revisao.md' $bytes
        Assert-Equal 'docs,docs/agentes' ((@($created)) -join ',')
        Assert-Equal (Get-Sha256Hex $bytes) (Get-Sha256Hex ([IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'docs', 'agentes', 'revisao.md'))))
        Assert-Equal 0 @(& $writeFile $root 'docs/agentes/coordenacao.md' $bytes).Count 'diretorios reutilizados'
    }
    It 'destino existente nao e sobrescrito, nem arquivo nem diretorio' {
        $root = New-FixtureRoot
        Write-FixtureFile ([IO.Path]::Combine($root, 'AGENTS.md')) $Utf8.GetBytes("original`n")
        Assert-Throws { & $writeFile $root 'AGENTS.md' ($Utf8.GetBytes("novo`n")) } 'MA_PREPARE_TARGET_CHANGED'
        Assert-Equal "original`n" ([IO.File]::ReadAllText([IO.Path]::Combine($root, 'AGENTS.md')))
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($root, 'CLAUDE.md'))
        Assert-Throws { & $writeFile $root 'CLAUDE.md' ($Utf8.GetBytes("novo`n")) } 'MA_PREPARE_TARGET_CHANGED'
    }
    It 'caminho fora do conjunto governado e recusado' {
        $root = New-FixtureRoot
        foreach ($path in @('outro.txt', '../AGENTS.md', 'docs/agentes/../../AGENTS.md', 'agents.md', '.githooks/post-merge', 'docs\agentes\revisao.md')) {
            Assert-Throws { & $writeFile $root $path ($Utf8.GetBytes("x`n")) } 'MA_PREPARE_TARGET_NOT_GOVERNED'
        }
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $root -Force).Count 'algo foi gravado'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($root)) -Force -Filter 'AGENTS.md').Count 'gravado fora da raiz'
    }
    It 'junction no caminho ou na raiz e componente arquivo sao recusados sem gravar no destino' {
        $root = New-FixtureRoot
        $elsewhere = New-FixtureRoot
        [void](New-Item -ItemType Junction -Path ([IO.Path]::Combine($root, 'docs')) -Value $elsewhere)
        Assert-Throws { & $writeFile $root 'docs/agentes/revisao.md' ($Utf8.GetBytes("x`n")) } 'MA_FILE_UNSAFE'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $elsewhere -Force -Recurse).Count 'gravado atraves da junction'
        $linked = [IO.Path]::Combine((New-FixtureRoot), 'raiz-link')
        [void](New-Item -ItemType Junction -Path $linked -Value $elsewhere)
        Assert-Throws { & $writeFile $linked 'AGENTS.md' ($Utf8.GetBytes("x`n")) } 'MA_PATH_REPARSE_POINT'
        $other = New-FixtureRoot
        Write-FixtureFile ([IO.Path]::Combine($other, '.githooks')) $Utf8.GetBytes("arquivo`n")
        Assert-Throws { & $writeFile $other '.githooks/pre-commit' ($Utf8.GetBytes("x`n")) } 'MA_FILE_UNSAFE'
        [IO.Directory]::Delete([IO.Path]::Combine($root, 'docs')); [IO.Directory]::Delete($linked)
    }
    It 'troca concorrente por junction depois da validacao: recusada pelo handle, nada gravado fora' {
        $root = New-FixtureRoot
        $script:SwapRoot = $root; $script:SwapOutside = New-FixtureRoot
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($root, 'docs', 'agentes'))
        # Depois de fixar a raiz e antes de abrir docs: docs trocado por junction.
        Use-Faults @{ GovernedFileChain = {
            param($c)
            $docs = [IO.Path]::Combine($script:SwapRoot, 'docs')
            [IO.Directory]::Move($docs, $docs + '-original')
            [void](New-Item -ItemType Junction -Path $docs -Value $script:SwapOutside)
            $false
        } }
        try { Assert-Throws { & $writeFile $root 'docs/agentes/revisao.md' ($Utf8.GetBytes("x`n")) } 'MA_FILE_UNSAFE' } finally { Clear-Faults }
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:SwapOutside -Force -Recurse).Count 'gravado atraves da junction'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($root, 'docs-original', 'agentes')) -Force).Count 'gravado no original'
        [IO.Directory]::Delete([IO.Path]::Combine($root, 'docs'))
    }
    It 'raiz trocada por junction depois da validacao textual: recusada pela cadeia de handles' {
        $parent = New-FixtureRoot
        $root = [IO.Path]::Combine($parent, 'manutencao'); [void][IO.Directory]::CreateDirectory($root)
        $script:SwapRoot = $root; $script:SwapOutside = New-FixtureRoot
        Use-Faults @{ ChainComponent = {
            param($c)
            if ($c.Component -ceq 'manutencao' -and -not [IO.Directory]::Exists($script:SwapRoot + '-original')) {
                [IO.Directory]::Move($script:SwapRoot, $script:SwapRoot + '-original')
                [void](New-Item -ItemType Junction -Path $script:SwapRoot -Value $script:SwapOutside)
            }
            $false
        } }
        try { Assert-Throws { & $writeFile $root 'AGENTS.md' ($Utf8.GetBytes("x`n")) } 'MA_PATH_REPARSE_POINT' } finally { Clear-Faults }
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:SwapOutside -Force).Count 'gravado atraves da junction'
        [IO.Directory]::Delete($root)
    }
    It 'diretorios fixados nao podem ser renomeados durante a gravacao; o arquivo fica no destino real' {
        $root = New-FixtureRoot
        $script:SwapRoot = $root
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($root, 'docs', 'agentes'))
        $script:SwapResult = New-Object System.Collections.Generic.List[string]
        # Antes de criar o arquivo: tentativa de mover docs, agentes e a propria raiz.
        Use-Faults @{ GovernedFileCreate = {
            param($c)
            foreach ($relative in @('docs\agentes', 'docs', '')) {
                $path = [IO.Path]::Combine($script:SwapRoot, $relative).TrimEnd('\')
                try { [IO.Directory]::Move($path, $path + '-movido'); $script:SwapResult.Add('movido:' + $relative) } catch { $script:SwapResult.Add('recusado') }
            }
            $false
        } }
        $bytes = $Utf8.GetBytes("conteudo`n")
        try { [void](& $writeFile $root 'docs/agentes/revisao.md' $bytes) } finally { Clear-Faults }
        Assert-Equal 'recusado,recusado,recusado' ($script:SwapResult -join ',')
        Assert-Equal (Get-Sha256Hex $bytes) (Get-Sha256Hex ([IO.File]::ReadAllBytes([IO.Path]::Combine($root, 'docs', 'agentes', 'revisao.md'))))
        # Liberados ao final: a raiz volta a poder ser renomeada.
        [IO.Directory]::Move($root, $root + '-x'); [IO.Directory]::Move($root + '-x', $root)
    }
    It 'abertura vinculada a handles indisponivel: gravacao recusada sem escrita' {
        $root = New-FixtureRoot
        InModule { $script:MaFileApi = $false }
        try { Assert-Throws { & $writeFile $root 'AGENTS.md' ($Utf8.GetBytes("x`n")) } 'MA_PATH_HANDLE_UNAVAILABLE' } finally { Clear-Faults }
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $root -Force).Count 'algo foi gravado'
    }
    It 'destino de clone ou worktree: criado de forma atomica, fixado e removido somente se criado e vazio' {
        $parent = New-FixtureRoot
        $result = InModule {
            param($p)
            $chain = Open-MaDirectoryChain $p
            $out = [ordered]@{}
            try {
                $target = Open-MaOperationTarget $chain ([IO.Path]::Combine($p, 'demo'))
                $out.Created = $target.Created
                try { [IO.Directory]::Delete([IO.Path]::Combine($p, 'demo')); $out.Delete = 'permitido' } catch { $out.Delete = 'recusado' }
                try { [IO.Directory]::Move([IO.Path]::Combine($p, 'demo'), [IO.Path]::Combine($p, 'outro')); $out.Move = 'permitido' } catch { $out.Move = 'recusado' }
                [IO.File]::WriteAllText([IO.Path]::Combine($p, 'demo', 'dado.txt'), 'x')
                $out.WithContent = (Close-MaOperationTarget $chain $target -RemoveIfCreatedEmpty).Removed
                $again = Open-MaOperationTarget $chain ([IO.Path]::Combine($p, 'demo'))
                $out.ReopenedCreated = $again.Created
                $out.Entries = (@($again.Entries | ForEach-Object { $_.Name }) -join ',')
                [IO.File]::Delete([IO.Path]::Combine($p, 'demo', 'dado.txt'))
                # Preexistente (nao criado nesta abertura): nunca removido.
                $out.Preexisting = (Close-MaOperationTarget $chain $again -RemoveIfCreatedEmpty).Removed
                $fresh = Open-MaOperationTarget $chain ([IO.Path]::Combine($p, 'novo'))
                $out.Fresh = (Close-MaOperationTarget $chain $fresh -RemoveIfCreatedEmpty).Removed
            } finally { [void](Close-MaPinnedChain $chain) }
            [pscustomobject]$out
        } @($parent)
        Assert-Equal $true $result.Created
        Assert-Equal 'recusado' $result.Delete
        Assert-Equal 'recusado' $result.Move
        Assert-Equal $false $result.WithContent 'removido com conteudo'
        Assert-Equal $false $result.ReopenedCreated
        Assert-Equal 'dado.txt' $result.Entries
        Assert-Equal $false $result.Preexisting 'preexistente removido'
        Assert-Equal $true $result.Fresh
        Assert-True ([IO.Directory]::Exists([IO.Path]::Combine($parent, 'demo'))) 'preexistente ausente'
        Assert-True (-not [IO.Directory]::Exists([IO.Path]::Combine($parent, 'novo'))) 'criado vazio nao removido'
    }

    Write-Output 'Branches, hooks e alteracoes alheias'
    It 'branch: ponta exata, conflito de caixa e hierarquia nos dois sentidos' {
        $state = InModule {
            $refs = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
            $refs['main'] = 'a' * 40; $refs['chore/manutencao'] = 'b' * 40; $refs['Chore/Manutencao'] = 'c' * 40; $refs['chore/manutencao/x'] = 'd' * 40
            Get-MaBranchCreationState $refs 'chore/manutencao'
        }
        Assert-Equal ('b' * 40) $state.Tip
        Assert-Equal 'MA_PREPARE_BRANCH_CASE_CONFLICT,MA_BRANCH_HIERARCHY_CONFLICT' ((@($state.Issues | ForEach-Object { $_.Code })) -join ',')
        $prefix = InModule {
            $refs = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
            $refs['chore'] = 'a' * 40
            Get-MaBranchCreationState $refs 'chore/manutencao'
        }
        Assert-Equal $null $prefix.Tip
        Assert-Equal 'MA_BRANCH_HIERARCHY_CONFLICT' ((@($prefix.Issues | ForEach-Object { $_.Code })) -join ',')
    }
    It 'clone recusado com core.hooksPath global ou GIT_TEMPLATE_DIR' {
        Use-GitMock
        $script:GlobalHooks = @('C:/hooks')
        $issues = InModule { Get-MaCloneHookIssues 'C:\inexistente' }
        Assert-Equal 'core.hooksPath (global)' @($issues)[0].Detail
        $script:GlobalHooks = @()
        [Environment]::SetEnvironmentVariable('GIT_TEMPLATE_DIR', 'C:\modelos')
        try { $issues = InModule { Get-MaCloneHookIssues 'C:\inexistente' } } finally { [Environment]::SetEnvironmentVariable('GIT_TEMPLATE_DIR', [NullString]::Value) }
        Assert-Equal 'GIT_TEMPLATE_DIR' ((@($issues | ForEach-Object { $_.Detail })) -join ',')
    }
    It 'alteracoes alheias: fora do conjunto acusadas; governadas e diretorios exclusivos nao' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        $maintenance = New-LinkedWorktree $s 'maintenance' $coordination
        $maintenance.Tracked = @('app.txt')
        $maintenance.Status = @(' M app.txt', '?? AGENTS.md', '?? .githooks/post-merge', '?? docs/agentes/extra.md', '?? notas com espaco.txt', 'A  src/novo.txt')
        $environment = [pscustomobject]@{ Path = $s.Model.Worktrees.maintenance }
        $issues = InModule { param($e) Get-MaForeignChangeIssues $e } @($environment)
        Assert-Equal 1 @($issues).Count
        Assert-Equal 'MA_PREPARE_FOREIGN_CHANGE' @($issues)[0].Code
        Assert-Equal 'app.txt, notas com espaco.txt, src/novo.txt' @($issues)[0].Detail
    }
    It 'atributo filter em caminho rastreado: inconclusivo e status nao executado' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        $maintenance = New-LinkedWorktree $s 'maintenance' $coordination
        $maintenance.Tracked = @('app.txt', 'dados.bin')
        $maintenance.Attributes = @{ 'dados.bin' = 'lfs' }
        $environment = [pscustomobject]@{ Path = $s.Model.Worktrees.maintenance }
        $issues = InModule { param($e) Get-MaForeignChangeIssues $e } @($environment)
        Assert-Equal 'MA_PREPARE_FOREIGN_CHANGE_UNVERIFIED' @($issues)[0].Code
        Assert-Equal 'dados.bin' @($issues)[0].Detail
        Assert-Equal 0 @($script:GitCalls | Where-Object { $_ -like 'status*' }).Count 'status executado com filtro'
    }

    Write-Output 'Checkout: verificacao previa e condicoes nao suportadas'
    $safety = { param($repoPath, $environment) InModule { param($p, $e, $b) Get-MaCheckoutSafety -Root $p -Commit $b -Role 'maintenance' -Environment $e } @($repoPath, $environment, $Base) }
    $noHooks = [pscustomobject]@{ HooksPath = @(); DefaultHooks = @(); CommonDir = 'C:\inexistente\.git' }
    It 'atributo filter versionado no commit recusa o checkout, exista ou nao driver, sem executar nada' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        $coordination.CommitTree = @(('100644 blob ' + ('1' * 40) + "`tapp.txt"), ('100644 blob ' + ('2' * 40) + "`tdados.bin"), ('100644 blob ' + ('3' * 40) + "`tsrc/x.txt"))
        $coordination.Attributes = @{ 'dados.bin' = 'lfs'; 'src/x.txt' = 'set' }
        $result = & $safety $s.Model.Worktrees.coordination $noHooks
        $codes = (@($result.Issues | ForEach-Object { $_.Code + ':' + $_.Detail })) -join ' | '
        Assert-Equal 'MA_PREPARE_CHECKOUT_FILTER:filter=lfs: dados.bin | MA_PREPARE_CHECKOUT_FILTER:filter=set: src/x.txt' $codes
        Assert-Equal 'app.txt,dados.bin,src/x.txt' (@($result.Paths) -join ',')
        Assert-True (@($script:GitCalls | Where-Object { $_ -ceq ('check-attr -z --stdin --source=' + $Base + ' filter') }).Count -eq 1) 'atributos lidos do commit'
        Assert-NoMutatingGit
    }
    It 'attr.tree, GIT_ATTR_SOURCE, submodulo e hook aplicavel recusam; core.fsmonitor gera aviso' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        $coordination.CommitTree = @(('100644 blob ' + ('1' * 40) + "`t.gitmodules"), ('160000 commit ' + ('4' * 40) + "`tvendor/lib"))
        $coordination.AttrTree = @('local' + [char]0 + 'refs/heads/atributos')
        $coordination.Fsmonitor = @('global' + [char]0 + 'true')
        $hooks = [pscustomobject]@{ HooksPath = @(); DefaultHooks = @('post-index-change'); CommonDir = 'C:\inexistente\.git' }
        [Environment]::SetEnvironmentVariable('GIT_ATTR_SOURCE', 'HEAD')
        try { $result = & $safety $s.Model.Worktrees.coordination $hooks } finally { [Environment]::SetEnvironmentVariable('GIT_ATTR_SOURCE', [NullString]::Value) }
        $codes = (@($result.Issues | ForEach-Object { $_.Severity + ':' + $_.Code + ':' + $_.Detail })) -join ' | '
        foreach ($expected in @('Bloqueio:MA_PREPARE_CHECKOUT_UNSUPPORTED:GIT_ATTR_SOURCE', 'Bloqueio:MA_PREPARE_CHECKOUT_UNSUPPORTED:attr.tree (local)',
                'Aviso:MA_PREPARE_FSMONITOR_DISABLED:core.fsmonitor (global)', 'Bloqueio:MA_PREPARE_HOOKS_WOULD_RUN:post-index-change',
                'Bloqueio:MA_ENV_SUBMODULES_UNSUPPORTED:.gitmodules, vendor/lib')) { Assert-True ($codes.Contains($expected)) ('ausente: ' + $expected + ' | ' + $codes) }
        Assert-NoMutatingGit
    }
    It 'manutencao ausente com filtro na base: nenhuma branch, worktree ou checkout criados' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        $coordination.CommitTree = @(('100644 blob ' + ('1' * 40) + "`tdados.bin"))
        $coordination.Attributes = @{ 'dados.bin' = 'lfs' }
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_PREPARE_CHECKOUT_FILTER' 'maintenance'
        Assert-Equal 0 @($r.Performed).Count
        Assert-NoMutatingGit
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'hook ativo nos modelos padrao do Git recusa o clone; diretorio padrao indeterminado tambem' {
        Use-GitMock
        $git = [IO.Path]::Combine((New-FixtureRoot), 'Git', 'mingw64')
        Write-FixtureFile ([IO.Path]::Combine($git, 'share', 'git-core', 'templates', 'hooks', 'reference-transaction')) $Utf8.GetBytes("#!/bin/sh`n")
        Write-FixtureFile ([IO.Path]::Combine($git, 'share', 'git-core', 'templates', 'hooks', 'pre-commit.sample')) $Utf8.GetBytes("#!/bin/sh`n")
        $script:ExecPath = [IO.Path]::Combine($git, 'libexec', 'git-core').Replace('\', '/')
        $issues = InModule { Get-MaCloneHookIssues 'C:\inexistente' }
        Assert-Equal 'modelos padrao: reference-transaction' ((@($issues | ForEach-Object { $_.Detail })) -join ',')
        $script:ExecPath = 'C:/Git/outro-layout'
        $issues = InModule { Get-MaCloneHookIssues 'C:\inexistente' }
        Assert-True (((@($issues | ForEach-Object { $_.Detail })) -join ',').StartsWith('diretorio padrao de modelos nao determinado')) 'layout desconhecido aceito'
    }
    It 'WhatIf com checkout pendente da coordenacao: checkout simulado, nada executado' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        $coordination.IndexFileMissing = $true
        [IO.File]::Delete([IO.Path]::Combine($s.Model.Worktrees.coordination, 'app.txt'))
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s -WhatIf
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-Equal 'Checkout' ((@($r.Simulated | ForEach-Object { $_.Operation })) -join ',')
        Assert-NoMutatingGit
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'checkout pendente com conteudo alem de .git: retomada recusada sem alterar o conteudo' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        $coordination.IndexFileMissing = $true
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_PREPARE_CHECKOUT_PENDING' 'coordination'
        Assert-NoMutatingGit
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }

    Write-Output 'PrepareMaintenance com repositorios simulados'
    It 'sem autorizacao ou base: bloqueio, nenhuma operacao mutavel nem modificacao' {
        Use-GitMock
        $s = New-Scenario
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s -AuthorizationReference '' -BaseCommit ''
        Assert-Equal 'Bloqueado' $r.Status
        Assert-HasIssue $r 'MA_AUTHORIZATION_REFERENCE_REQUIRED'
        Assert-HasIssue $r 'MA_BASECOMMIT_REQUIRED'
        Assert-Equal $false $r.Modified
        Assert-NoMutatingGit
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'WhatIf em workspace vazio: Incompleto, clone simulado e nao executado' {
        Use-GitMock
        $s = New-Scenario
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s -WhatIf
        Assert-Equal 'Incompleto' $r.Status (Get-Codes $r)
        Assert-Equal 'Clonar,Checkout,Criar branch e worktree,Gerar' ((@($r.Simulated | ForEach-Object { $_.Operation })) -join ',')
        Assert-True (@($r.Simulated)[0].Detail -ceq 'sem checkout') 'clone sem checkout'
        Assert-NoMutatingGit
        Assert-NoForbiddenGit
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
        Assert-Equal 2 (Get-MaExitCode $r.Status)
    }
    It 'manutencao existente na base: gera os onze destinos e confere a preparacao' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        [void](New-LinkedWorktree $s 'maintenance' $coordination)
        $r = Invoke-Prepare $s
        Assert-Equal 'Sucesso' $r.Status (Get-Codes $r)
        Assert-Equal 11 @($r.Performed | Where-Object { $_.Operation -eq 'Gerar' }).Count
        Assert-Equal 11 @($r.Files | Where-Object { $_.Role -eq 'maintenance' -and $_.Classification -eq 'PreparadoNaoCommitado' }).Count
        foreach ($file in $s.Rendered) { Assert-Equal $file.Sha256 (Get-Sha256Hex ([IO.File]::ReadAllBytes([IO.Path]::Combine($s.Model.Worktrees.maintenance, $file.Path.Replace('/', '\'))))) $file.Path }
        Assert-NoForbiddenGit
        Assert-NoMutatingGit
        Assert-True (-not [IO.File]::Exists([IO.Path]::Combine($s.Model.Worktrees.coordination, 'AGENTS.md'))) 'gerado na coordenacao'
        foreach ($role in @('codex', 'claude')) { Assert-True (-not [IO.Directory]::Exists($s.Model.Worktrees[$role])) ($role + ' criado') }
    }
    It 'base divergente da coordenacao: nenhuma criacao de worktree' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s)
        $r = Invoke-Prepare $s -BaseCommit ('b' * 40)
        Assert-HasIssue $r 'MA_PREPARE_BASE_DIVERGENT' 'coordination'
        Assert-NoMutatingGit
    }
    It 'BaseCommit de 64 hexadecimais em repositorio SHA-1 e recusado' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s)
        $r = Invoke-Prepare $s -BaseCommit ('a' * 64)
        Assert-HasIssue $r 'MA_BASECOMMIT_FORMAT_MISMATCH' 'coordination'
    }
    It 'core.hooksPath na coordenacao: worktree add nao e executado' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        $coordination.HooksPath = @('local' + [char]0 + 'file:.git/config' + [char]0 + 'hooks-proprios')
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_HOOKS_WOULD_RUN' 'maintenance'
        Assert-NoMutatingGit
    }
    It 'caminho ignorado na manutencao: geracao recusada' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        $maintenance = New-LinkedWorktree $s 'maintenance' $coordination
        $maintenance.Ignored = @('.multiagente/manifest.json')
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_PATH_IGNORED' 'maintenance'
        Assert-Equal 0 @($r.Performed).Count
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'exclusao mutua ocupada: bloqueio antes de qualquer operacao' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        [void](New-LinkedWorktree $s 'maintenance' $coordination)
        $holder = Start-LockHolder (Get-LockName $s.Workspace $s.Model.Worktrees.coordination)
        try {
            $before = Get-Snapshot $s.Root
            $r = Invoke-Prepare $s
            Assert-HasIssue $r 'MA_PREPARE_LOCKED'
            Assert-SameSnapshot $before (Get-Snapshot $s.Root)
        } finally { Stop-LockHolder $holder }
    }
    It 'falha do clone simulado: falha operacional sem residuo' {
        Use-GitMock
        $s = New-Scenario
        $r = Invoke-Prepare $s
        Assert-Equal 'Falha' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_PREPARE_CLONE_FAILED' 'coordination'
        Assert-Equal $false $r.Partial
        Assert-Equal 4 (Get-MaExitCode $r.Status)
        Assert-True (@($script:GitCalls | Where-Object { $_ -clike '-c alias.remote-ssh= -c remote.origin.vcs=https clone --no-checkout *' }).Count -eq 1) 'clone sem --no-checkout ou sem o helper https fixado'
        # Destino criado pelo instalador e ainda vazio: removido pelo handle.
        Assert-True (-not [IO.Directory]::Exists($s.Model.Worktrees.coordination)) 'destino vazio criado deixado'
        # Destino vazio preexistente: preservado.
        [void][IO.Directory]::CreateDirectory($s.Model.Worktrees.coordination)
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_CLONE_FAILED' 'coordination'
        Assert-True ([IO.Directory]::Exists($s.Model.Worktrees.coordination)) 'destino preexistente removido'
    }

    Write-Output 'Transporte efetivo do clone'
    $transport = { param([string]$Url) InModule { param($u) Get-MaCloneTransport 'C:\inexistente' $u } @($Url) }
    # Reescrita simulada: ls-remote --get-url devolve a URL indicada.
    $rewrite = { param([string]$To) $script:RewriteTo = $To; $script:GetUrl = { param($u) [pscustomobject]@{ ExitCode = 0; StdOut = ($script:RewriteTo + "`n"); StdErr = '' } } }
    $describe = { param($Result) (@($Result.Issues | ForEach-Object { $_.Severity + ':' + $_.Code + ':' + $_.Detail })) -join ' | ' }
    It 'HTTPS e SSH sem reescrita: transporte classificado como permitido, URL expandida pelo Git' {
        Use-GitMock
        foreach ($case in @(@('https://example.invalid/org/demo.git', 'https'), @('https://example.invalid:8443/org/demo.git', 'https'),
                @('ssh://git@example.invalid/org/demo.git', 'ssh'), @('ssh://example.invalid:2222/org/demo.git', 'ssh'), @('git@example.invalid:org/demo.git', 'ssh'))) {
            $r = & $transport $case[0]
            Assert-Equal $case[1] $r.Transport $case[0]
            Assert-Equal '' (& $describe $r) $case[0]
            Assert-True (@($script:GitCalls | Where-Object { $_ -ceq ('ls-remote --get-url -- ' + $case[0]) }).Count -eq 1) ('URL nao expandida pelo Git: ' + $case[0])
        }
        Assert-NoMutatingGit
    }
    It 'reescrita para file, ext, helper, http, git, caminho local ou URL com credencial: recusada sem reproduzir a URL' {
        Use-GitMock
        foreach ($case in @(@('file:///C:/origem.git', 'file'), @('ext::sh -c touch% sentinela', 'helper ext'), @('sentinela::https://example.invalid/org/demo.git', 'helper sentinela'),
                @('http://example.invalid/org/demo.git', 'http'), @('git://example.invalid/org/demo.git', 'git'), @('C:/repos/origem.git', 'caminho local ou forma desconhecida'),
                @('\\servidor\repos\origem.git', 'caminho local ou forma desconhecida'), @('https://usuario:segredo@example.invalid/org/demo.git', 'https'))) {
            & $rewrite $case[0]
            $r = & $transport 'https://example.invalid/org/demo.git'
            Assert-Equal $null $r.Transport $case[0]
            Assert-Equal ('Bloqueio:MA_REPOSITORY_TRANSPORT_UNSAFE:URL efetiva fora do contrato; transporte ' + $case[1]) (& $describe $r) $case[0]
            Assert-True (-not (& $describe $r).Contains('segredo') -and -not (& $describe $r).Contains('example.invalid')) 'URL reproduzida'
        }
        Assert-NoMutatingGit
    }
    It 'reescrita para outro HTTPS ou de HTTPS para SSH: permitida com aviso, configuracao preservada' {
        Use-GitMock
        & $rewrite 'https://espelho.invalid/org/demo.git'
        $r = & $transport 'https://example.invalid/org/demo.git'
        Assert-Equal 'https' $r.Transport
        Assert-Equal 'Aviso:MA_REPOSITORY_TRANSPORT_REWRITTEN:https -> https' (& $describe $r)
        & $rewrite 'git@example.invalid:org/demo.git'
        $r = & $transport 'https://example.invalid/org/demo.git'
        Assert-Equal 'ssh' $r.Transport
        Assert-Equal 'Aviso:MA_REPOSITORY_TRANSPORT_REWRITTEN:https -> ssh (forma scp)' (& $describe $r)
        Assert-NoForbiddenGit
    }
    It 'remote.origin.vcs recusa; leitura inconclusiva do vcs ou da URL efetiva bloqueia' {
        Use-GitMock
        $script:OriginVcs = 'sentinela'
        $r = & $transport 'https://example.invalid/org/demo.git'
        Assert-Equal $null $r.Transport
        Assert-Equal 'Bloqueio:MA_REPOSITORY_TRANSPORT_UNSAFE:remote.origin.vcs (global)' (& $describe $r)
        $script:OriginVcs = 128
        Assert-Equal 'Bloqueio:MA_REPOSITORY_TRANSPORT_UNVERIFIED:remote.origin.vcs' (& $describe (& $transport 'https://example.invalid/org/demo.git'))
        $script:OriginVcs = $null
        $outputs = @(
            @{ ExitCode = 128; StdOut = ''; Expected = 'git ls-remote --get-url 128' },
            @{ ExitCode = 0; StdOut = ''; Expected = 'git ls-remote --get-url 0' },
            @{ ExitCode = 0; StdOut = "https://example.invalid/org/demo.git`nfile:///C:/x`n"; Expected = 'git ls-remote --get-url 0' })
        foreach ($output in $outputs) {
            $script:Output = $output
            $script:GetUrl = { param($u) [pscustomobject]@{ ExitCode = $script:Output.ExitCode; StdOut = $script:Output.StdOut; StdErr = 'simulado' } }
            $r = & $transport 'https://example.invalid/org/demo.git'
            Assert-Equal $null $r.Transport
            Assert-Equal ('Bloqueio:MA_REPOSITORY_TRANSPORT_UNVERIFIED:' + $output.Expected) (& $describe $r)
        }
    }
    It 'remote.origin.url de outra camada (inclusive <helper>::) recusa; leitura inconclusiva bloqueia' {
        Use-GitMock
        foreach ($value in @('ssh::sequestrado', 'https://espelho.invalid/org/demo.git')) {
            $script:OriginUrlConfig = $value
            $r = & $transport 'https://example.invalid/org/demo.git'
            Assert-Equal $null $r.Transport $value
            Assert-Equal 'Bloqueio:MA_REPOSITORY_TRANSPORT_UNSAFE:remote.origin.url (global)' (& $describe $r) $value
            Assert-True (-not (& $describe $r).Contains('sequestrado') -and -not (& $describe $r).Contains('espelho')) 'URL reproduzida'
        }
        $script:OriginUrlConfig = 128
        Assert-Equal 'Bloqueio:MA_REPOSITORY_TRANSPORT_UNVERIFIED:remote.origin.url' (& $describe (& $transport 'https://example.invalid/org/demo.git'))
        Assert-NoMutatingGit
    }
    It 'clone HTTPS fixa remote.origin.vcs=https; todo clone fixa alias.remote-ssh vazio e usa o ambiente de transporte' {
        Use-GitMock
        $s = New-Scenario
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_CLONE_FAILED' 'coordination'
        $clones = @($script:GitCalls | Where-Object { $_ -cmatch '(?:\A| )clone --no-checkout ' })
        Assert-Equal 1 $clones.Count
        Assert-True ($clones[0].StartsWith('-c alias.remote-ssh= -c remote.origin.vcs=https clone --no-checkout --origin origin ')) $clones[0]
        # Somente o clone recebe o PATH restrito e o cliente SSH fixado.
        Assert-Equal $clones[0] (@($script:TransportCalls) -join ' || ')
        Use-GitMock
        & $rewrite 'git@example.invalid:org/demo.git'
        $r = Invoke-Prepare $s
        Assert-HasIssue $r 'MA_PREPARE_CLONE_FAILED' 'coordination'
        $clones = @($script:GitCalls | Where-Object { $_ -cmatch '(?:\A| )clone --no-checkout ' })
        Assert-Equal 1 $clones.Count
        Assert-True ($clones[0].StartsWith('-c alias.remote-ssh= clone --no-checkout --origin origin ')) $clones[0]
        Assert-Equal $clones[0] (@($script:TransportCalls) -join ' || ')
    }
    It 'alias.remote-ssh de qualquer camada recusa com HTTPS ou SSH; leitura inconclusiva bloqueia' {
        Use-GitMock
        $script:AliasRemoteSsh = '!/c/externo/helper.exe'
        foreach ($url in @('https://example.invalid/org/demo.git', 'ssh://git@example.invalid/org/demo.git')) {
            $r = & $transport $url
            Assert-Equal $null $r.Transport $url
            Assert-Equal 'Bloqueio:MA_REPOSITORY_TRANSPORT_UNSAFE:alias.remote-ssh (global)' (& $describe $r) $url
            Assert-True (-not (& $describe $r).Contains('externo')) 'valor reproduzido'
        }
        $script:AliasRemoteSsh = 128
        Assert-Equal 'Bloqueio:MA_REPOSITORY_TRANSPORT_UNVERIFIED:alias.remote-ssh' (& $describe (& $transport 'https://example.invalid/org/demo.git'))
        Assert-NoMutatingGit
    }
    It 'transporte SSH recusa core.sshCommand, GIT_SSH e GIT_SSH_COMMAND; HTTPS nao os consulta' {
        Use-GitMock
        $script:SshCommandConfig = '/c/externo/plink.exe -batch'
        $r = & $transport 'ssh://git@example.invalid/org/demo.git'
        Assert-Equal $null $r.Transport
        Assert-Equal 'Bloqueio:MA_REPOSITORY_SSH_COMMAND_UNSUPPORTED:core.sshCommand (global)' (& $describe $r)
        Assert-True (-not (& $describe $r).Contains('plink')) 'comando reproduzido'
        # Reescrita de HTTPS para SSH tambem recusa: o transporte efetivo decide.
        & $rewrite 'git@example.invalid:org/demo.git'
        Assert-Equal 'Aviso:MA_REPOSITORY_TRANSPORT_REWRITTEN:https -> ssh (forma scp) | Bloqueio:MA_REPOSITORY_SSH_COMMAND_UNSUPPORTED:core.sshCommand (global)' (& $describe (& $transport 'https://example.invalid/org/demo.git'))
        $script:GetUrl = $null
        $script:SshCommandConfig = 128
        Assert-Equal 'Bloqueio:MA_REPOSITORY_TRANSPORT_UNVERIFIED:core.sshCommand' (& $describe (& $transport 'ssh://git@example.invalid/org/demo.git'))
        # HTTPS: o comando SSH do consumidor nao e lido nem recusado (o clone fixa o cliente).
        $script:SshCommandConfig = '/c/externo/plink.exe'
        $script:GitCalls.Clear()
        $r = & $transport 'https://example.invalid/org/demo.git'
        Assert-Equal 'https' $r.Transport
        Assert-Equal '' (& $describe $r)
        Assert-Equal 0 @($script:GitCalls | Where-Object { $_.Contains('core.sshCommand') }).Count 'core.sshCommand consultado no HTTPS'
        $script:SshCommandConfig = $null
        foreach ($name in @('GIT_SSH', 'GIT_SSH_COMMAND')) {
            $saved = [Environment]::GetEnvironmentVariable($name)
            try {
                [Environment]::SetEnvironmentVariable($name, 'C:\externo\ssh.exe')
                Assert-Equal ('Bloqueio:MA_REPOSITORY_SSH_COMMAND_UNSUPPORTED:' + $name) (& $describe (& $transport 'ssh://git@example.invalid/org/demo.git')) $name
                Assert-Equal 'https' (& $transport 'https://example.invalid/org/demo.git').Transport $name
            } finally { [Environment]::SetEnvironmentVariable($name, $(if ($null -eq $saved) { [NullString]::Value } else { $saved })) }
        }
        Assert-NoMutatingGit
    }
    It 'sem cliente SSH da instalacao o SSH e recusado; sem ambiente de transporte nenhum clone' {
        Use-GitMock
        Use-SimulatedTransport -WithoutSsh
        Assert-Equal 'Bloqueio:MA_GIT_SSH_CLIENT_UNTRUSTED:' (& $describe (& $transport 'ssh://git@example.invalid/org/demo.git'))
        Assert-Equal 'https' (& $transport 'https://example.invalid/org/demo.git').Transport 'HTTPS recusado sem cliente SSH'
        Use-SimulatedTransport -Unavailable
        foreach ($url in @('https://example.invalid/org/demo.git', 'ssh://git@example.invalid/org/demo.git')) {
            $r = & $transport $url
            Assert-Equal $null $r.Transport $url
            Assert-Equal 'Bloqueio:MA_GIT_TRANSPORT_UNTRUSTED:' (& $describe $r) $url
        }
        # Na fase: recusa antes do clone, nada criado.
        $s = New-Scenario
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_GIT_TRANSPORT_UNTRUSTED' 'coordination'
        Assert-NoMutatingGit
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
        # Chamada direta com -Transport sem ambiente comprovado: recusada sem processo.
        $savedPath = InModule { $script:MaGitPath }
        try {
            InModule { $script:MaGitInvoker = $null; $script:MaGitPath = 'C:\ma-inexistente\git.exe' }
            Assert-Throws { InModule { Invoke-MaGit 'C:\ma-inexistente' @('clone') -Transport } } 'MA_GIT_TRANSPORT_UNTRUSTED'
        } finally { InModule { param($p) $script:MaGitPath = $p } @($savedPath) }
    }
    It 'PrepareMaintenance: reescrita incompativel bloqueia antes do clone, inclusive no WhatIf' {
        Use-GitMock
        $s = New-Scenario
        & $rewrite 'ext::sh -c touch% sentinela'
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_REPOSITORY_TRANSPORT_UNSAFE' 'coordination'
        Assert-Equal $false $r.Modified
        Assert-Equal 3 (Get-MaExitCode $r.Status)
        Assert-NoMutatingGit
        Assert-True (-not [IO.Directory]::Exists($s.Model.Worktrees.coordination)) 'destino do clone criado'
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
        $simulated = Invoke-Prepare $s -WhatIf
        Assert-Equal 'Bloqueado' $simulated.Status (Get-Codes $simulated)
        Assert-HasIssue $simulated 'MA_REPOSITORY_TRANSPORT_UNSAFE' 'coordination'
        Assert-Equal 0 @($simulated.Simulated).Count
        Assert-NoMutatingGit
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'PrepareMaintenance: falha de inspecao do transporte bloqueia sem clone' {
        Use-GitMock
        $s = New-Scenario
        $script:GetUrl = { param($u) [pscustomobject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal: bad config line 1' } }
        $before = Get-Snapshot $s.Root
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-HasIssue $r 'MA_REPOSITORY_TRANSPORT_UNVERIFIED' 'coordination'
        Assert-NoMutatingGit
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'transporte recusado pelo proprio Git no clone: erro estruturado e destino criado removido' {
        Use-GitMock
        $s = New-Scenario
        # Recusa pelo Git ou, com o helper https fixado, pela libcurl (URL desviada, sem reproduzi-la).
        foreach ($case in @(@("fatal: transport 'file' not allowed`n", 'file'), @("fatal: unable to access 'file:///C:/x/': Protocol `"file`" disabled`n", 'file'),
                @("fatal: unable to access 'file:///C:/a b/x/': URL rejected: Malformed input to a URL function`n", 'file'),
                @("fatal: unable to access 'ssh://h/x/': Protocol `"SSH`" not supported or disabled in libcurl`n", 'ssh'))) {
            Use-GitMock
            $script:CloneStdErr = $case[0]
            $r = Invoke-Prepare $s
            Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
            Assert-Equal ('MA_REPOSITORY_TRANSPORT_UNSAFE:git clone 128; transporte recusado pelo Git: ' + $case[1]) ((@($r.Issues | Where-Object { $_.Severity -ne 'Aviso' } | ForEach-Object { $_.Code + ':' + $_.Detail })) -join ' | ')
            Assert-Equal $false $r.Partial
            Assert-True (-not [IO.Directory]::Exists($s.Model.Worktrees.coordination)) 'destino vazio criado deixado'
        }
        # Helper ssh selecionado depois da verificacao: o alias fixado vazio aborta.
        Use-GitMock
        $script:CloneStdErr = "expansion of alias 'remote-ssh' failed; '' is not a git command`nfatal: remote helper 'ssh' aborted session`n"
        $r = Invoke-Prepare $s
        Assert-Equal 'Bloqueado' $r.Status (Get-Codes $r)
        Assert-Equal 'MA_REPOSITORY_TRANSPORT_UNSAFE:git clone 128; helper de transporte nao autorizado: ssh' ((@($r.Issues | Where-Object { $_.Severity -ne 'Aviso' } | ForEach-Object { $_.Code + ':' + $_.Detail })) -join ' | ')
        Assert-True (-not [IO.Directory]::Exists($s.Model.Worktrees.coordination)) 'destino vazio criado deixado'
    }

    Write-Output 'Relatorio'
    It 'relatorio distingue execucao parcial, nao reproduz a referencia e indica modificacoes' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s
        [void](New-LinkedWorktree $s 'maintenance' $coordination)
        $secret = 'referencia-pessoal-123'
        $done = Invoke-Prepare $s -AuthorizationReference $secret
        $text = (Format-MaPrepareReport $done) -join "`n"
        Assert-True (-not $text.Contains($secret)) 'referencia reproduzida'
        Assert-True ($text.Contains('SHA-256 ' + (Get-Sha256Hex ($Utf8.GetBytes($secret))))) 'hash da referencia'
        Assert-True ($text.EndsWith('Modificacoes realizadas: 15 operacao(oes); nenhum commit, indice, push ou PR.')) $text
        Assert-True ($text.Contains('git update-index --chmod=+x')) 'pendencia do modo dos hooks'
        $partial = $done.PSObject.Copy(); $partial.Status = 'Bloqueado'; $partial.Partial = $true
        Assert-True (((Format-MaPrepareReport $partial) -join "`n").Contains('Execucao parcial')) 'execucao parcial'
        $nothing = Invoke-Prepare $s -WhatIf
        $lines = Format-MaPrepareReport $nothing
        Assert-Equal 'Nenhuma modificacao foi realizada.' $lines[$lines.Count - 1]
        Assert-Equal 'Fase: PrepareMaintenance' $lines[0]
    }

    Write-Output 'Ponto de entrada'
    It 'PrepareMaintenance sem autorizacao: codigo 3 e nenhuma modificacao' -Requires Git, Job {
        $s = New-Scenario
        $before = Get-Snapshot $s.Root
        $ErrorActionPreference = 'Continue'
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File ([IO.Path]::Combine($s.Package, 'scripts', 'Install-MultiAgentProject.ps1')) -Config $s.Config -Phase PrepareMaintenance -BaseCommit $Base 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $text = $output | Out-String
        Assert-Equal 3 $code $text
        Assert-True ($text.Contains('MA_AUTHORIZATION_REFERENCE_REQUIRED')) $text
        Assert-True ($text.Contains('Nenhuma modificacao foi realizada.')) $text
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
} finally {
    InModule { $script:MaGitInvoker = $null }
    foreach ($name in $SavedGitEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$SavedGitEnvironment[$name]) }
    foreach ($root in $script:FixtureRoots) {
        if (-not [IO.Directory]::Exists($root)) { continue }
        # Junctions removidas antes, sem seguir o destino.
        foreach ($entry in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })) { [IO.Directory]::Delete($entry.FullName) }
        [IO.Directory]::Delete($root, $true)
    }
}

Write-Output ''
Write-Output ('Resultado: ' + $script:Passed + ' aprovados, ' + $script:Failed.Count + ' falhas, ' + $script:Blocked.Count + ' nao executados por pre-requisito')
foreach ($failure in $script:Failed) { Write-Output ('  - ' + $failure) }
foreach ($blocked in $script:Blocked) { Write-Output ('  - [PRE-REQ] ' + $blocked) }
if ($script:Failed.Count -gt 0) { exit 1 }
if ($script:Blocked.Count -gt 0) { exit 2 }
exit 0
