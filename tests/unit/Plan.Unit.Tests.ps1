#Requires -Version 5.1
<#
Testes unitarios da fase Plan. Autocontidos: nao dependem de Pester (a versao 5
fixada ainda nao foi distribuida). Executados no Windows PowerShell 5.1 x64 e
x86; o PowerShell 7 nao foi testado. Fixtures sao descartaveis, criadas sob o TEMP do executor e
nunca apontam para o projeto atual. Repositorios sao simulados: nenhum
repositorio Git e criado, alterado ou consultado. O Git real e usado somente
fora de repositorios (--version, check-ref-format e rev-parse --sq-quote).

Uso: powershell -NoProfile -File tests/unit/Plan.Unit.Tests.ps1
Codigo de saida: 0 quando todos os casos passam; 1 se algum caso falha; 2 se
nenhum falha, mas algum caso nao pode ser executado por pre-requisito ausente
(nunca contado como aprovado).

Pre-requisitos verificados no inicio e exigidos por caso:
  Git  Git for Windows >= 2.44 localizado no PATH.
  Sh   sh.exe e sleep.exe do Git for Windows (usr\bin), usados por caminho
       absoluto (/usr/bin/sleep), sem depender do PATH.
  Job  Executor seguro disponivel: job com KILL_ON_JOB_CLOSE e criacao suspensa
       dentro do job (Windows 10 / Server 2016 ou superior).
  GitLauncher  Lancador cmd\git.exe do Git for Windows (caso do git real iniciado
       pelo lancador dentro do job).
Nenhum caso usa WMI/CIM nem provoca, por desenho, escape de processos da
contencao do executor (o ponto de entrada e invocado diretamente, como pelo
usuario). A observacao de processos usa mutex nomeado mantido pelo filho ou
Get-Process (sleep.exe novos); execute uma instancia da suite por vez.
Variaveis Git que redirecionam repositorio ou configuracao (GIT_DIR, GIT_CONFIG_*,
...) sao removidas apenas deste processo de teste e restauradas ao final; o
bloqueio do Plan para elas continua coberto por casos que as definem.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PackageSource = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
$ModulePath = [IO.Path]::Combine($PackageSource, 'scripts', 'MultiAgentTemplate.psm1')
$Module = Import-Module -Name $ModulePath -Force -PassThru -DisableNameChecking
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:Blocked = New-Object System.Collections.Generic.List[string]
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]
$script:GitCalls = New-Object System.Collections.Generic.List[string]
$script:Repos = @{}
$script:RejectedBranches = @()
$script:Objects = @{}
$script:UnreadableObjects = @()
$script:ObjectTypes = @{}
$script:BatchCheckFails = @()
$script:ExistenceCheckFails = @()
$script:IndexStub = $null

# --- Mini-harness -----------------------------------------------------------------

$script:Prereq = @{}
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
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if (-not [object]::Equals($Expected, $Actual)) { throw ('esperado <' + $Expected + '> obtido <' + $Actual + '> ' + $Message) }
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'condicao falsa')
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Code)
    $thrown = $null
    try { & $Body } catch { $thrown = $_.Exception.Message }
    if ($null -eq $thrown) { throw ('nenhuma excecao; esperado ' + $Code) }
    if ($thrown -cne $Code) { throw ('esperado ' + $Code + ' obtido ' + $thrown) }
}

function Assert-HasIssue {
    param($Plan, [string]$Code, [string]$Role = '')
    $found = @($Plan.Issues | Where-Object { $_.Code -ceq $Code -and ($Role -eq '' -or $_.Role -eq $Role) })
    if ($found.Count -eq 0) { throw ('impedimento ausente: ' + $Code + ' | presentes: ' + ((@($Plan.Issues | ForEach-Object { $_.Code })) -join ',')) }
}

function Assert-NoIssue {
    param($Plan, [string]$Code)
    if (@($Plan.Issues | Where-Object { $_.Code -ceq $Code }).Count -gt 0) { throw ('impedimento inesperado: ' + $Code) }
}

# Executa no escopo do modulo para alcancar funcoes internas.
function InModule {
    param([scriptblock]$Body, [object[]]$Arguments = @())
    return (& $Module $Body @Arguments)
}

# --- Fixtures ---------------------------------------------------------------------

function New-FixtureRoot {
    $path = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ma-plan-tests-' + [Guid]::NewGuid().ToString('N'))
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

# Pacote descartavel: templates e esquema copiados do pacote (somente leitura) e
# demais obrigatorios como conteudo ficticio; manifesto calculado pelo teste.
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

function ConvertTo-JsonLiteral {
    param([string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function New-FixtureConfig {
    param([string]$Root, [string]$Workspace, [string]$Name = 'Projeto Demo', [string]$Slug = 'demo', [string]$Url = 'https://example.invalid/org/demo.git', [string]$Extra = '', [string]$FileName = 'multiagente.config.json', [switch]$RawJson)
    # -RawJson insere nome e slug ja escritos como fonte JSON (escapes \uXXXX preservados).
    $nameJson = ConvertTo-JsonLiteral $Name; $slugJson = ConvertTo-JsonLiteral $Slug
    if ($RawJson) { $nameJson = '"' + $Name + '"'; $slugJson = '"' + $Slug + '"' }
    $json = '{"schemaVersion":"1.0","project":{"name":' + $nameJson + ',"slug":' + $slugJson + '},"repository":{"url":' + (ConvertTo-JsonLiteral $Url) + '},"workspace":{"parentDirectory":' + (ConvertTo-JsonLiteral $Workspace) + '}' + $Extra + '}'
    $path = [IO.Path]::Combine($Root, $FileName)
    Write-FixtureFile $path $Utf8.GetBytes($json)
    return $path
}

function Write-RawConfig {
    param([string]$Root, [string]$Json)
    $path = [IO.Path]::Combine($Root, 'multiagente.config.json')
    Write-FixtureFile $path $Utf8.GetBytes($Json)
    return $path
}

function New-Scenario {
    $root = New-FixtureRoot
    $workspace = [IO.Path]::Combine($root, 'ws')
    [void][IO.Directory]::CreateDirectory($workspace)
    $package = New-FixturePackage $root
    $config = New-FixtureConfig $root $workspace
    $model = Read-MaConfiguration -LiteralPath $config -SchemaPath ([IO.Path]::Combine($package, 'schema', 'project.schema.json'))
    $rendered = Get-MaRenderedFiles -PackageRoot $package -Configuration $model -DistributionVersion '0.0.0-teste'
    return [pscustomobject]@{ Root = $root; Workspace = $workspace; Package = $package; Config = $config; Model = $model; Rendered = $rendered }
}

# Estado observavel: entradas, tipos, atributos e, para arquivos, tamanho, mtime
# e SHA-256 dos bytes. O mtime de diretorios fica fora: o NTFS o atualiza de
# forma tardia apos a criacao da fixture, mesmo sem nenhuma escrita do Plan;
# criacoes e remocoes continuam detectadas pela lista de entradas.
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

function Get-BlobId {
    param([byte[]]$Bytes)
    return (InModule { param($b) Get-MaGitBlobId $b 'sha1' } @(, $Bytes))
}

# --- Git simulado --------------------------------------------------------------------

function New-RepoState {
    param([string]$Path, [string]$Branch = 'main', [string]$CommonDir = $null)
    if (-not $CommonDir) { $CommonDir = [IO.Path]::Combine($Path, '.git') }
    return @{
        TopLevel = $Path.Replace('\', '/'); CommonDir = $CommonDir.Replace('\', '/'); Bare = 'false'; Shallow = 'false'; Format = 'sha1'
        Symbolic = ('refs/heads/' + $Branch); Head = ('a' * 40); Origin = @('https://example.invalid/org/demo.git'); Partial = $false
        Worktrees = @(); Tree = @(); Index = @(); HooksPath = @(); RevParseFails = $false; IndexFileMissing = $false
    }
}

# Banco de objetos simulado: identificador -> bytes. Objetos marcados como
# ilegiveis existem (cat-file -e) mas falham na leitura (cat-file blob).
function Register-Object {
    param([byte[]]$Bytes)
    $id = Get-BlobId $Bytes
    $script:Objects[$id] = $Bytes
    return $id
}

function Add-GovernedEntries {
    param([hashtable]$Repo, [object[]]$Rendered, [switch]$Tree, [switch]$Index, [hashtable]$ModeOverride = @{})
    foreach ($file in $Rendered) {
        $mode = $file.GitMode; if ($ModeOverride.ContainsKey($file.Path)) { $mode = $ModeOverride[$file.Path] }
        $id = Register-Object $file.Bytes
        if ($Tree) { $Repo.Tree += ($mode + ' blob ' + $id + "`t" + $file.Path) }
        if ($Index) { $Repo.Index += ($mode + ' ' + $id + ' 0' + "`t" + $file.Path) }
    }
}

# Simula o Git observado na integracao: objeto solto corrompido aparece como
# "missing" no batch-check, com erro no stderr, enquanto cat-file -e retorna 0;
# objeto ausente aparece como "missing" sem stderr e cat-file -e retorna 1.
$GitMock = {
    param([string]$WorkingDirectory, [string[]]$Arguments, [bool]$Binary, [string]$InputText)
    $script:GitCalls.Add(($Arguments -join ' '))
    $ok = { param([string]$Out) [pscustomobject]@{ ExitCode = 0; StdOut = $Out; StdErr = '' } }
    $fail = { param([int]$Code) [pscustomobject]@{ ExitCode = $Code; StdOut = ''; StdErr = 'simulado' } }
    $command = $Arguments -join ' '
    if ($command -ceq '--version') { return (& $ok "git version 2.52.0.windows.1`n") }
    if ($Arguments[0] -ceq 'check-ref-format') {
        if ($script:RejectedBranches -ccontains $Arguments[2]) { return (& $fail 1) }
        return (& $ok ($Arguments[2] + "`n"))
    }
    $repo = $null
    foreach ($key in $script:Repos.Keys) { if ($key.Equals($WorkingDirectory, [StringComparison]::OrdinalIgnoreCase)) { $repo = $script:Repos[$key] } }
    if ($null -eq $repo) { return (& $fail 128) }
    if ($command.StartsWith('rev-parse --path-format=absolute --show-toplevel')) {
        if ($repo.RevParseFails) { return (& $fail 128) }
        return (& $ok (($repo.TopLevel, $repo.CommonDir, $repo.Bare, $repo.Shallow, $repo.Format) -join "`n"))
    }
    if ($command.StartsWith('config -z --get-regexp')) { if ($repo.Partial) { return (& $ok "remote.origin.promisor`ntrue`0") } else { return (& $fail 1) } }
    if ($command -ceq 'symbolic-ref --quiet HEAD') { if ($repo.Symbolic) { return (& $ok ($repo.Symbolic + "`n")) } else { return (& $fail 1) } }
    if ($command -ceq 'rev-parse --verify --quiet HEAD^{commit}') { if ($repo.Head) { return (& $ok ($repo.Head + "`n")) } else { return (& $fail 1) } }
    if ($command -ceq 'config -z --get-all remote.origin.url') { if ($repo.Origin.Count -gt 0) { return (& $ok ((@($repo.Origin | ForEach-Object { $_ + [char]0 })) -join '')) } else { return (& $fail 1) } }
    if ($command -ceq 'worktree list --porcelain -z') { return (& $ok ((@($repo.Worktrees | ForEach-Object { $_ + [char]0 + [char]0 })) -join '')) }
    if ($command.StartsWith('config -z --show-scope --show-origin --get-all core.hooksPath')) {
        if ($repo.HooksPath.Count -eq 0) { return (& $fail 1) }
        return (& $ok ((@($repo.HooksPath | ForEach-Object { $_ + [char]0 })) -join ''))
    }
    if ($command -ceq 'rev-parse --path-format=absolute --git-path hooks') { return (& $ok ($repo.CommonDir + "/hooks`n")) }
    # Arquivo de indice: existente por padrao; ausente simula clone sem checkout.
    if ($command -ceq 'rev-parse --path-format=absolute --git-path index') {
        if ($repo.IndexFileMissing) { return (& $ok ($repo.CommonDir + "/index-ausente`n")) }
        return (& $ok ($script:IndexStub.Replace('\', '/') + "`n"))
    }
    if ($command -ceq 'rev-parse --verify --quiet HEAD^{tree}') { return (& $ok (('c' * 40) + "`n")) }
    if ($Arguments[0] -ceq 'ls-tree') { return (& $ok ((@($repo.Tree | ForEach-Object { $_ + [char]0 })) -join '')) }
    if ($Arguments[0] -ceq 'ls-files') { return (& $ok ((@($repo.Index | ForEach-Object { $_ + [char]0 })) -join '')) }
    if ($Arguments[0] -ceq 'cat-file' -and $Arguments[1] -ceq '--batch-check') {
        $oid = ([string]$InputText).Trim()
        if ($script:BatchCheckFails -ccontains $oid) { return (& $fail 128) }
        if ($script:UnreadableObjects -ccontains $oid) { return [pscustomobject]@{ ExitCode = 0; StdOut = ($oid + " missing`n"); StdErr = "error: inflate: data stream error`n" } }
        if ($script:Objects.ContainsKey($oid)) {
            $type = 'blob'; if ($script:ObjectTypes.ContainsKey($oid)) { $type = $script:ObjectTypes[$oid] }
            return (& $ok ($oid + ' ' + $type + ' ' + ([byte[]]$script:Objects[$oid]).Length + "`n"))
        }
        return (& $ok ($oid + " missing`n"))
    }
    if ($Arguments[0] -ceq 'cat-file' -and $Arguments[1] -ceq '-e') {
        if ($Arguments[2].EndsWith('^{commit}')) { return (& $ok '') }
        if ($script:ExistenceCheckFails -ccontains $Arguments[2]) { return (& $fail 128) }
        if ($script:Objects.ContainsKey($Arguments[2]) -or $script:UnreadableObjects -ccontains $Arguments[2]) { return (& $ok '') }
        return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = '' }
    }
    if ($Arguments[0] -ceq 'cat-file' -and $Arguments[1] -ceq 'blob') {
        if ($script:UnreadableObjects -ccontains $Arguments[2] -or -not $script:Objects.ContainsKey($Arguments[2])) { return (& $fail 128) }
        return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdOutBytes = [byte[]]$script:Objects[$Arguments[2]]; StdErr = '' }
    }
    return (& $fail 129)
}

function Use-GitMock {
    if (-not $script:IndexStub) { $script:IndexStub = [IO.Path]::Combine((New-FixtureRoot), 'index'); [IO.File]::WriteAllBytes($script:IndexStub, [byte[]]@()) }
    $script:GitCalls.Clear(); $script:Repos = @{};$script:RejectedBranches = @(); $script:Objects = @{}; $script:UnreadableObjects = @(); $script:ObjectTypes = @{}; $script:BatchCheckFails = @(); $script:ExistenceCheckFails = @(); InModule { param($m) $script:MaGitInvoker = $m } @(, $GitMock)
}
function Use-RealGit { InModule { $script:MaGitInvoker = $null } }

function Invoke-Plan {
    param($Scenario, [string]$BaseCommit = '')
    return (Invoke-MaPlan -ConfigPath $Scenario.Config -PackageRoot $Scenario.Package -BaseCommit $BaseCommit)
}

function New-Coordination {
    param($Scenario, [switch]$WithFiles)
    $path = $Scenario.Model.Worktrees.coordination
    [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($path, '.git'))
    $repo = New-RepoState $path
    $repo.Worktrees = @('worktree ' + $path.Replace('\', '/') + [char]0 + 'HEAD ' + ('a' * 40) + [char]0 + 'branch refs/heads/main')
    if ($WithFiles) {
        foreach ($file in $Scenario.Rendered) { Write-FixtureFile ([IO.Path]::Combine($path, $file.Path.Replace('/', '\'))) $file.Bytes }
        Add-GovernedEntries $repo $Scenario.Rendered -Tree -Index
    }
    $script:Repos[$path] = $repo
    return $repo
}

function New-LinkedWorktree {
    param($Scenario, [string]$Role, [hashtable]$Coordination)
    $path = $Scenario.Model.Worktrees[$Role]
    Write-FixtureFile ([IO.Path]::Combine($path, '.git')) $Utf8.GetBytes("gitdir: x`n")
    $common = $Coordination.CommonDir.Replace('/', '\')
    $repo = New-RepoState $path $Scenario.Model.Branches[$Role] $common
    $Coordination.Worktrees += ('worktree ' + $path.Replace('\', '/') + [char]0 + 'HEAD ' + ('a' * 40) + [char]0 + 'branch refs/heads/' + $Scenario.Model.Branches[$Role])
    $script:Repos[$path] = $repo
    return $repo
}

# --- Ambiente e pre-requisitos ------------------------------------------------------------

# Remove do processo de teste (e de seus filhos) as variaveis que o Plan trata como
# redirecionamento; o proprio bloqueio e testado em casos que as definem.
function Clear-GitOverrideEnvironment {
    $names = InModule { $script:MaGitOverrideVariables }
    $saved = [ordered]@{}
    foreach ($variable in @(Get-ChildItem Env:)) {
        if ($variable.Name -in $names -or $variable.Name -match '\AGIT_CONFIG_(?:KEY|VALUE)_[0-9]+\z') {
            $saved[$variable.Name] = $variable.Value
            [Environment]::SetEnvironmentVariable($variable.Name, $null)
        }
    }
    return $saved
}

function Restore-GitOverrideEnvironment {
    param([System.Collections.IDictionary]$Saved)
    foreach ($name in $Saved.Keys) { [Environment]::SetEnvironmentVariable($name, [string]$Saved[$name]) }
}

function Get-TestPrerequisites {
    $result = @{ Git = $false; Sh = $false; Job = $false; GitLauncher = $false; GitPath = $null; ShPath = $null; LauncherPath = $null; Notes = New-Object System.Collections.Generic.List[string] }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { $result.Notes.Add('Git: nao localizado no PATH') }
    else {
        $result.GitPath = $git.Path
        try {
            $version = & $git.Path --version 2>$null
            $match = [regex]::Match([string]$version, '([0-9]+)\.([0-9]+)\.([0-9]+)')
            $result.Git = $match.Success -and ((New-Object Version ([int]$match.Groups[1].Value), ([int]$match.Groups[2].Value), ([int]$match.Groups[3].Value)) -ge (New-Object Version 2, 44, 0))
            $result.Notes.Add('Git: ' + $git.Path + ' ' + [string]$version)
        } catch { $result.Notes.Add('Git: falha ao executar') }
        $shell = InModule { param($p) Find-MaShell $p } @($git.Path)
        if ($shell -and [IO.File]::Exists([IO.Path]::Combine([IO.Path]::GetDirectoryName($shell), 'sleep.exe'))) { $result.Sh = $true; $result.ShPath = $shell; $result.Notes.Add('Sh: ' + $shell + ' (com sleep.exe)') }
        else { $result.Notes.Add('Sh: sh.exe/sleep.exe do Git for Windows nao localizados (MinGit?)') }
        # Lancador cmd\git.exe: raiz do Git for Windows a partir de cmd\, bin\ ou mingw64\bin\.
        $directory = [IO.Path]::GetDirectoryName($git.Path)
        for ($level = 0; $level -lt 3 -and $directory; $level++) {
            $candidate = [IO.Path]::Combine($directory, 'cmd', 'git.exe')
            if ([IO.File]::Exists($candidate)) { $result.GitLauncher = $true; $result.LauncherPath = $candidate; break }
            $directory = [IO.Path]::GetDirectoryName($directory)
        }
        if ($result.GitLauncher) { $result.Notes.Add('GitLauncher: ' + $result.LauncherPath) } else { $result.Notes.Add('GitLauncher: cmd\git.exe nao localizado') }
        try {
            $probe = InModule { param($p) Invoke-MaNativeProcess -FilePath $p -Arguments @('--version') -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutMilliseconds 30000 } @($git.Path)
            $result.Job = ($probe.ExitCode -eq 0)
            $result.Notes.Add('Job: executor seguro disponivel (criacao suspensa dentro do job)')
        } catch { $result.Notes.Add('Job: indisponivel (' + $_.Exception.Message + ')') }
    }
    return $result
}

# --- Casos ------------------------------------------------------------------------------

Write-Output ('PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
$SavedGitEnvironment = Clear-GitOverrideEnvironment
if ($SavedGitEnvironment.Count -gt 0) { Write-Output ('Ambiente: removidas deste processo de teste: ' + (@($SavedGitEnvironment.Keys) -join ', ')) }
$detected = Get-TestPrerequisites
foreach ($key in @('Git', 'Sh', 'Job', 'GitLauncher')) { $script:Prereq[$key] = [bool]$detected[$key] }
foreach ($note in $detected.Notes) { Write-Output ('Pre-requisito ' + $note) }
try {
    $base = New-Scenario
    $schema = [IO.Path]::Combine($base.Package, 'schema', 'project.schema.json')
    $ws = $base.Workspace

    Write-Output 'Esquema e configuracao'
    It 'configuracao minima aplica padroes e deriva quatro ambientes' {
        $m = $base.Model
        Assert-Equal 'main' $m.Branches.coordination; Assert-Equal 'feature/codex' $m.Branches.codex
        Assert-Equal 'feature/claude' $m.Branches.claude; Assert-Equal 'chore/manutencao' $m.Branches.maintenance
        Assert-Equal 4 $m.Worktrees.Count
        Assert-Equal ([IO.Path]::Combine($ws, 'demo-manutencao')) $m.Worktrees.maintenance
        Assert-Equal 'coordination,codex,claude,maintenance' ((@($m.Branches.Keys)) -join ',')
    }
    It 'rejeita propriedade desconhecida' { Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Extra ',"extra":1') $schema } 'MA_CONFIG_UNKNOWN_PROPERTY' }
    It 'rejeita propriedade conhecida com caixa diferente' { Assert-Throws { Read-MaConfiguration (Write-RawConfig $base.Root ('{"SchemaVersion":"1.0","project":{"name":"a","slug":"a"},"repository":{"url":"git@h:o/r.git"},"workspace":{"parentDirectory":' + (ConvertTo-JsonLiteral $ws) + '}}')) $schema } 'MA_CONFIG_REQUIRED' }
    It 'rejeita chave duplicada por caixa' { Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Extra ',"Branches":{},"branches":{}') $schema } 'MA_JSON_DUPLICATE_KEY' }
    It 'rejeita ausencia de obrigatorio' { Assert-Throws { Read-MaConfiguration (Write-RawConfig $base.Root '{"schemaVersion":"1.0"}') $schema } 'MA_CONFIG_REQUIRED' }
    It 'rejeita tipo incorreto' { Assert-Throws { Read-MaConfiguration (Write-RawConfig $base.Root ('{"schemaVersion":"1.0","project":{"name":5,"slug":"a"},"repository":{"url":"git@h:o/r.git"},"workspace":{"parentDirectory":' + (ConvertTo-JsonLiteral $ws) + '}}')) $schema } 'MA_CONFIG_TYPE' }
    It 'rejeita schemaVersion diferente' { Assert-Throws { Read-MaConfiguration (Write-RawConfig $base.Root ('{"schemaVersion":"1.1","project":{"name":"a","slug":"a"},"repository":{"url":"git@h:o/r.git"},"workspace":{"parentDirectory":' + (ConvertTo-JsonLiteral $ws) + '}}')) $schema } 'MA_CONFIG_CONST' }
    It 'rejeita virgula final e conteudo apos o JSON' {
        Assert-Throws { InModule { Read-MaJsonStrict '{"a":"b",}' } } 'MA_JSON_STRING_EXPECTED'
        Assert-Throws { InModule { Read-MaJsonStrict '{} {}' } } 'MA_JSON_TRAILING_CONTENT'
    }
    It 'rejeita slug com quebra final codificada (pattern ECMA, regressao do Codex)' { Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Slug 'demo\n' -RawJson) $schema } 'MA_CONFIG_PATTERN' }
    It 'rejeita nome com controle, separador de linha ou controle de direcao' {
        foreach ($escape in @('\u0007', '\n', '\u2028', '\u202e', '\u200f')) { Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Name ('a' + $escape + 'b') -RawJson) $schema } 'MA_PROJECT_NAME_INVALID' }
    }
    It 'conta comprimento por ponto de codigo' {
        $emoji = [string][char]0xD83D + [char]0xDE00
        Assert-Equal 120 (InModule { param($v) Get-MaCodePointLength $v } @(($emoji * 120)))
        $model = Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Name ($emoji * 70)) $schema
        Assert-Equal 140 $model.Name.Length
    }
    It 'rejeita branches invalidas, ambiguas, reservadas e hierarquicas' {
        $cases = @{
            'a..b' = 'MA_CONFIG_PATTERN|MA_BRANCH_INVALID'; 'x.lock' = 'MA_BRANCH_INVALID'; 'HEAD' = 'MA_BRANCH_AMBIGUOUS'; 'refs/heads/x' = 'MA_BRANCH_AMBIGUOUS'
            'feature/con' = 'MA_BRANCH_INVALID'; 'a b' = 'MA_CONFIG_PATTERN'; 'a/.b' = 'MA_BRANCH_INVALID'; 'a//b' = 'MA_BRANCH_INVALID'; 'a/' = 'MA_BRANCH_INVALID'
            "a'b" = 'MA_CONFIG_PATTERN'; 'a$(x)' = 'MA_CONFIG_PATTERN'; 'a;b' = 'MA_CONFIG_PATTERN'; 'a`b' = 'MA_CONFIG_PATTERN'
        }
        foreach ($branch in $cases.Keys) {
            $code = $null
            try { [void](Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Extra (',"branches":{"codex":' + (ConvertTo-JsonLiteral $branch) + '}')) $schema) } catch { $code = $_.Exception.Message }
            Assert-True ($null -ne $code -and ($cases[$branch].Split('|') -ccontains $code)) ('branch ' + $branch + ' -> ' + $code)
        }
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Extra ',"branches":{"codex":"Main"}') $schema } 'MA_BRANCH_DUPLICATE'
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Extra ',"branches":{"codex":"feature","claude":"feature/claude"}') $schema } 'MA_BRANCH_HIERARCHY_CONFLICT'
    }
    It 'aceita branches alternativas validas' {
        $model = Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Extra ',"branches":{"coordination":"trunk","codex":"dev/codex-1.0","claude":"dev/claude_2","maintenance":"ops/manut"}') $schema
        Assert-Equal 'trunk' $model.Branches.coordination; Assert-Equal 'ops/manut' $model.Branches.maintenance
    }
    It 'aceita URLs HTTPS e SSH permitidas' {
        foreach ($url in @('https://example.invalid/org/r.git', 'https://example.invalid:8443/org/r.git', 'ssh://git@example.invalid/org/r.git', 'ssh://example.invalid:2222/org/r.git', 'git@example.invalid:org/r.git')) {
            InModule { param($u) Assert-MaRepositoryUrl $u } @($url)
        }
    }
    It 'rejeita URLs com credencial, consulta, fragmento ou protocolo de execucao' {
        foreach ($url in @('https://user:token@example.invalid/r.git', 'https://token@example.invalid/r.git', 'https://example.invalid/r.git?x=1', 'https://example.invalid/r.git#f',
                'http://example.invalid/r.git', 'ext::sh -c touch% /tmp/x', 'file:///C:/r.git', 'git@example.invalid:../r.git', 'ssh://-oProxyCommand=calc/r.git',
                'ssh://git:senha@example.invalid/r.git', 'https://example.invalid/', 'C:\repo', '-u@h:r', 'https://example.invalid/a%0ab')) {
            Assert-Throws { InModule { param($u) Assert-MaRepositoryUrl $u } @($url) } 'MA_REPOSITORY_URL_INVALID'
        }
    }
    It 'rejeita diretorio pai relativo, UNC, reservado, inexistente ou com ADS' {
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root 'relativo\pasta') $schema } 'MA_PATH_LOCAL_ABSOLUTE_REQUIRED'
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root '\\servidor\share') $schema } 'MA_PATH_LOCAL_ABSOLUTE_REQUIRED'
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root ($ws + '\CON')) $schema } 'MA_PATH_COMPONENT_UNSAFE'
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root ($ws + '\conout$')) $schema } 'MA_PATH_COMPONENT_UNSAFE'
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root ($ws + '\..\x')) $schema } 'MA_PATH_COMPONENT_UNSAFE'
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root ($ws + '\nao-existe')) $schema } 'MA_PATH_NOT_FOUND'
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $base.Root ($ws + ':fluxo')) $schema } 'MA_PATH_LOCAL_ABSOLUTE_REQUIRED'
    }
    It 'nao expande variaveis e aceita metacaracteres literais no caminho' {
        $odd = [IO.Path]::Combine($base.Root, "dir com espaco '`$HOME & [x] ;")
        [void][IO.Directory]::CreateDirectory($odd)
        $model = Read-MaConfiguration (New-FixtureConfig $base.Root $odd) $schema
        Assert-Equal $odd $model.ParentDirectory
        Assert-Equal ([IO.Path]::Combine($odd, 'demo-codex')) $model.Worktrees.codex
    }
    It 'detecta componente intermediario que e arquivo' {
        Write-FixtureFile ([IO.Path]::Combine($base.Root, 'arquivo.txt')) $Utf8.GetBytes('x')
        Assert-Throws { InModule { param($p) Assert-MaSafePath $p 'Directory' -AllowMissing } @(([IO.Path]::Combine($base.Root, 'arquivo.txt', 'filho'))) } 'MA_PATH_PARENT_NOT_DIRECTORY'
    }
    It 'rejeita configuracao dentro de um worktree' {
        $inside = [IO.Path]::Combine($ws, 'demo-codex')
        [void][IO.Directory]::CreateDirectory($inside)
        Assert-Throws { Read-MaConfiguration (New-FixtureConfig $inside $ws) $schema } 'MA_CONFIG_INSIDE_WORKTREE'
        [IO.Directory]::Delete($inside, $true)
    }

    Write-Output 'Escape e renderizacao'
    It 'escapa prosa Markdown sem duplicar (regressao do Codex)' {
        Assert-Equal 'A \& B \<x\>' (InModule { ConvertTo-MaMarkdownProse 'A & B <x>' })
        Assert-Equal '\[a\]\(b\) \| \*c\* \# \{\{BRANCH\}\}' (InModule { ConvertTo-MaMarkdownProse '[a](b) | *c* # {{BRANCH}}' })
        Assert-Equal '&#32;&#32;a b&#32;' (InModule { ConvertTo-MaMarkdownProse '  a b ' })
        Assert-Equal 'C\:\\x' (InModule { ConvertTo-MaMarkdownProse 'C:\x' })
    }
    It 'nome adversarial permanece dado literal na renderizacao' {
        $name = '{{BRANCH_COORDINATION}} | <script>x</script> [l](http://e) `c` # ' + [char]0x00C7
        $model = Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Name $name) $schema
        $files = Get-MaRenderedFiles -PackageRoot $base.Package -Configuration $model -DistributionVersion 't'
        $readme = $Utf8.GetString(($files | Where-Object { $_.Path -eq 'README.md' }).Bytes)
        $first = $readme.Split([char]10)[0]
        Assert-Equal ('# ' + (InModule { param($n) ConvertTo-MaMarkdownProse $n } @($name))) $first
        Assert-True (-not $readme.Contains('<script>')) 'HTML ativo'
        Assert-True ($first.Contains('\{\{BRANCH\_COORDINATION\}\}')) 'token do nome reinterpretado'
        foreach ($file in $files) { Assert-True (-not $Utf8.GetString($file.Bytes).Contains('{{WORKTREE_')) ('token remanescente em ' + $file.Path) }
    }
    It 'insere branch validada como literal sh nos hooks' {
        $model = Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Extra ',"branches":{"coordination":"trunk"}') $schema
        $files = Get-MaRenderedFiles -PackageRoot $base.Package -Configuration $model -DistributionVersion 't'
        $commit = $Utf8.GetString(($files | Where-Object { $_.Path -eq '.githooks/pre-commit' }).Bytes)
        $push = $Utf8.GetString(($files | Where-Object { $_.Path -eq '.githooks/pre-push' }).Bytes)
        Assert-True ($commit.Contains("[ `"`$branch`" = 'trunk' ]")) 'pre-commit'
        Assert-True ($push.Contains("'refs/heads/trunk'")) 'pre-push'
        Assert-Equal '100755' (($files | Where-Object { $_.Path -eq '.githooks/pre-push' }).GitMode)
    }
    It 'recusa tokens fora do contexto permitido' {
        $m = $base.Model
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "echo {{PROJECT_NAME_MD}}`n" '.githooks/pre-commit' $c } @($m) } 'MA_TEMPLATE_CONTEXT_INVALID'
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "x = {{BRANCH_CODEX}}`n" '.githooks/pre-commit' $c } @($m) } 'MA_TEMPLATE_CONTEXT_INVALID'
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "x = {{BRANCH_COORDINATION}}`n" '.githooks/pre-commit' $c } @($m) } 'MA_TEMPLATE_CONTEXT_INVALID'
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "Texto {{PROJECT_NAME_MD}} solto`n" 'README.md' $c } @($m) } 'MA_TEMPLATE_CONTEXT_INVALID'
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "| {{PROJECT_NAME_MD}} |`n" 'README.md' $c } @($m) } 'MA_TEMPLATE_CONTEXT_INVALID'
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "{{BRANCH_CODEX}}`n" '.gitattributes' $c } @($m) } 'MA_TEMPLATE_CONTEXT_INVALID'
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "{{OUTRO}}`n" 'README.md' $c } @($m) } 'MA_TEMPLATE_TOKEN_UNKNOWN'
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "a }} b`n" 'README.md' $c } @($m) } 'MA_TEMPLATE_TOKEN_MALFORMED'
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "a {{BRANCH_CODEX b`n" 'README.md' $c } @($m) } 'MA_TEMPLATE_TOKEN_MALFORMED'
        Assert-Throws { InModule { param($c) ConvertTo-MaRenderedText "ver template-dev-multiagente`n" 'README.md' $c } @($m) } 'MA_TEMPLATE_ORIGIN_IDENTIFIER'
    }
    It 'escapa branch em prosa e preserva em codigo, inclusive codigo multilinha' {
        $model = Read-MaConfiguration (New-FixtureConfig $base.Root $ws -Extra ',"branches":{"codex":"feat/_x_"}') $schema
        $text = "na {{BRANCH_CODEX}}.`n`n``{{BRANCH_CODEX}}```n`n``inicio`nfim {{BRANCH_CODEX}}.```n`n| ``{{BRANCH_CODEX}}`` | {{BRANCH_CODEX}} |`n"
        $out = InModule { param($t, $c) ConvertTo-MaRenderedText $t 'README.md' $c } @($text, $model)
        Assert-Equal "na feat\/\_x\_.`n`n``feat/_x_```n`n``inicio`nfim feat/_x_.```n`n| ``feat/_x_`` | feat\/\_x\_ |`n" $out
    }
    It 'renderizacao e deterministica e o manifesto nao contem caminhos locais' {
        $again = Get-MaRenderedFiles -PackageRoot $base.Package -Configuration $base.Model -DistributionVersion '0.0.0-teste'
        for ($i = 0; $i -lt $again.Count; $i++) { Assert-Equal $base.Rendered[$i].Sha256 $again[$i].Sha256 $again[$i].Path }
        $manifest = $Utf8.GetString(($again | Where-Object { $_.Path -eq '.multiagente/manifest.json' }).Bytes)
        Assert-True (-not $manifest.Contains($ws)) 'caminho absoluto'
        Assert-True (-not $manifest.Contains('ma-plan-tests')) 'caminho de fixture'
        Assert-True ($manifest.StartsWith("{`n  `"distributionVersion`": `"0.0.0-teste`",`n  `"configuration`": {`n")) 'formato'
        Assert-True ($manifest.EndsWith("]`n}`n")) 'final LF'
        Assert-True (-not $manifest.Contains("`r")) 'CR'
        Assert-Equal 11 $again.Count
        foreach ($file in $again) { Assert-True (-not ($file.Bytes.Length -ge 3 -and $file.Bytes[0] -eq 239)) ('BOM em ' + $file.Path); Assert-True ([Array]::IndexOf($file.Bytes, [byte]13) -lt 0) ('CR em ' + $file.Path) }
    }
    It 'serializa JSON com escapes estaveis' {
        $value = [ordered]@{ a = "x`"\`n" + [char]1 + [char]0x2028; b = @(); c = @{}; d = $true; e = $null; f = @('1') }
        Assert-Equal ("{`n  `"a`": `"x\`"\\\n\u0001\u2028`",`n  `"b`": [],`n  `"c`": {},`n  `"d`": true,`n  `"e`": null,`n  `"f`": [`n    `"1`"`n  ]`n}") (InModule { param($v) ConvertTo-MaJsonText $v } @(, $value))
    }
    It 'calcula identificador de blob Git sem executar o Git' {
        Assert-Equal 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391' (Get-BlobId ([byte[]]@()))
        Assert-Equal 'ce013625030ba8dba906f756967f9e9ca394464a' (Get-BlobId ($Utf8.GetBytes("hello`n")))
    }

    Write-Output 'Integridade do pacote'
    It 'pacote de fixture integro' { $r = Test-MaPackageIntegrity $base.Package; Assert-True $r.Valid ((@($r.Issues | ForEach-Object { $_.Code + ' ' + $_.Path })) -join '; ') }
    It 'detecta hash divergente, arquivo nao inventariado e CR' {
        $root = New-FixtureRoot; $package = New-FixturePackage $root
        Write-FixtureFile ([IO.Path]::Combine($package, 'AGENTS.md')) $Utf8.GetBytes("alterado`n")
        Write-FixtureFile ([IO.Path]::Combine($package, 'extra.txt')) $Utf8.GetBytes("x`n")
        Write-FixtureFile ([IO.Path]::Combine($package, 'CLAUDE.md')) $Utf8.GetBytes("ficticio`r`n")
        $r = Test-MaPackageIntegrity $package
        Assert-True (-not $r.Valid) 'valido'
        $codes = @($r.Issues | ForEach-Object { $_.Code + ':' + $_.Path })
        Assert-True ($codes -ccontains 'MA_PACKAGE_HASH_MISMATCH:AGENTS.md') 'hash'
        Assert-True ($codes -ccontains 'MA_PACKAGE_FILE_NOT_INVENTORIED:extra.txt') 'inventario'
        Assert-True ($codes -ccontains 'MA_PACKAGE_ENCODING_INVALID:CLAUDE.md') 'CR'
    }
    It 'template trocado depois da verificacao de integridade: renderizacao recusada' {
        $root = New-FixtureRoot; $package = New-FixturePackage $root
        $r = Test-MaPackageIntegrity $package
        Assert-True $r.Valid 'pacote'
        $verified = @{}; foreach ($file in $r.Files) { $verified[$file.Path] = $file.ActualHash }
        $template = [IO.Path]::Combine($package, 'templates', 'AGENTS.md.tmpl')
        Write-FixtureFile $template ([IO.File]::ReadAllBytes($template) + $Utf8.GetBytes("trocado depois`n"))
        Assert-Throws { Get-MaRenderedFiles -PackageRoot $package -Configuration $base.Model -DistributionVersion '0.0.0-teste' -VerifiedHashes $verified } 'MA_PACKAGE_HASH_MISMATCH'
        # Sem hashes conferidos (uso direto da funcao), o comportamento anterior e mantido.
        $unverified = Get-MaRenderedFiles -PackageRoot $package -Configuration $base.Model -DistributionVersion '0.0.0-teste'
        Assert-Equal 11 $unverified.Count
    }
    It 'esquema trocado depois da verificacao de integridade: configuracao recusada' {
        $expected = Get-Sha256Hex ([IO.File]::ReadAllBytes($schema))
        Assert-Equal 'demo' (Read-MaConfiguration -LiteralPath $base.Config -SchemaPath $schema -SchemaSha256 $expected).Slug
        Assert-Throws { Read-MaConfiguration -LiteralPath $base.Config -SchemaPath $schema -SchemaSha256 ('0' * 64) } 'MA_PACKAGE_HASH_MISMATCH'
    }
    It 'Plan recusa pacote com template trocado depois da verificacao' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $template = [IO.Path]::Combine($s.Package, 'templates', 'CLAUDE.md.tmpl')
        $original = [IO.File]::ReadAllBytes($template)
        # A troca ocorre entre a verificacao e a renderizacao: no primeiro comando Git do Plan.
        $swap = @{ Done = $false; Path = $template; Bytes = ($original + $Utf8.GetBytes("x`n")) }
        $previous = $GitMock
        InModule { param($m, $sw) $script:MaGitInvoker = { param($wd, $a, $bin, $i) if (-not $sw.Done) { [IO.File]::WriteAllBytes($sw.Path, [byte[]]$sw.Bytes); $sw.Done = $true }; & $m $wd $a $bin $i }.GetNewClosure() } @($previous, $swap)
        $plan = Invoke-Plan $s
        Assert-True $swap.Done 'a troca nao ocorreu durante o Plan'
        Assert-HasIssue $plan 'MA_PACKAGE_HASH_MISMATCH'
        Assert-True ($plan.Status -ne 'Sucesso') $plan.Status
        Assert-Equal 0 @($plan.Files).Count 'nenhum destino classificado com template nao conferido'
    }

    Write-Output 'Argumentos nativos'
    It 'converte argumentos pelas regras do Windows' {
        $cases = [ordered]@{ 'abc' = 'abc'; '' = '""'; 'a b' = '"a b"'; 'a"b' = '"a\"b"'; 'C:\x y\' = '"C:\x y\\"'; 'a\\"b' = '"a\\\\\"b"'; 'a\b' = 'a\b' }
        foreach ($key in $cases.Keys) { Assert-Equal $cases[$key] (InModule { param($v) ConvertTo-MaNativeArgument $v } @($key)) $key }
    }
    It 'Git real recebe argumentos adversariais literalmente (fora de repositorio)' -Requires Git, Job {
        Use-RealGit
        InModule { $c = Get-Command git -CommandType Application | Select-Object -First 1; $script:MaGitPath = $c.Path }
        $values = @('a b', "it's", '$HOME', '&calc', 'x;y', '[z]', 'q"uote', 'trail\', '', '%PATH%', '`whoami`', '$(id)')
        $result = InModule { param($wd, $v) Invoke-MaGit $wd (@('rev-parse', '--sq-quote') + $v) } @($base.Root, $values)
        $expected = ' ' + ((@($values | ForEach-Object { "'" + $_.Replace("'", "'\''") + "'" })) -join ' ')
        Assert-Equal 0 $result.ExitCode
        Assert-Equal $expected ($result.StdOut.TrimEnd("`n"))
    }
    It 'Git real confirma branches por check-ref-format' -Requires Git, Job {
        Use-RealGit
        $good = [ordered]@{ coordination = 'main'; codex = 'feature/codex'; claude = 'feature/claude'; maintenance = 'chore/manutencao' }
        Assert-Equal 0 (InModule { param($b, $wd) (Test-MaBranchesWithGit $b $wd).Count } @($good, $base.Root))
        $bad = [ordered]@{ coordination = 'main'; codex = 'a..b'; claude = 'x.lock'; maintenance = 'chore/manutencao' }
        Assert-Equal 2 (InModule { param($b, $wd) (Test-MaBranchesWithGit $b $wd).Count } @($bad, $base.Root))
    }

    Write-Output 'Origem dos helpers de transporte'
    It 'exec-path aceito somente no layout da instalacao do git.exe e com git-remote-https.exe' {
        $root = [IO.Path]::Combine((New-FixtureRoot), 'Git')
        $exec = [IO.Path]::Combine($root, 'mingw64', 'libexec', 'git-core')
        $flat = [IO.Path]::Combine($root, 'libexec', 'git-core')
        foreach ($directory in @($exec, $flat)) { Write-FixtureFile ([IO.Path]::Combine($directory, 'git-remote-https.exe')) ([byte[]]@()) }
        $other = [IO.Path]::Combine((New-FixtureRoot), 'mingw64', 'libexec', 'git-core')
        Write-FixtureFile ([IO.Path]::Combine($other, 'git-remote-https.exe')) ([byte[]]@())
        $empty = [IO.Path]::Combine($root, 'clangarm64', 'libexec', 'git-core')
        [void][IO.Directory]::CreateDirectory($empty)
        $trusted = { param([string]$Git, [string]$Exec) InModule { param($g, $e) Get-MaTrustedExecPath $g $e } @($Git, $Exec) }
        Assert-Equal $exec (& $trusted ([IO.Path]::Combine($root, 'cmd', 'git.exe')) $exec) 'cmd\git.exe'
        Assert-Equal $exec (& $trusted ([IO.Path]::Combine($root, 'mingw64', 'bin', 'git.exe')) $exec) 'mingw64\bin\git.exe'
        Assert-Equal $flat (& $trusted ([IO.Path]::Combine($root, 'bin', 'git.exe')) $flat) 'bin\git.exe'
        foreach ($case in @(
                @([IO.Path]::Combine($root, 'cmd', 'git.exe'), $other, 'fora da instalacao'),
                @([IO.Path]::Combine($root, 'cmd', 'git.exe'), $empty, 'sem git-remote-https.exe'),
                @([IO.Path]::Combine($root, 'cmd', 'git.exe'), ($root + '\mingw64\..\mingw64\libexec\git-core'), 'segmento relativo'),
                @([IO.Path]::Combine($root, 'cmd', 'git.exe'), [IO.Path]::Combine($root, 'mingw64', 'bin'), 'fora de libexec\git-core'),
                @([IO.Path]::Combine($root, 'mingw64', 'bin', 'git.exe'), $flat, 'prefixo acima da instalacao'),
                @([IO.Path]::Combine($root, 'cmd', 'git.exe'), '', 'vazio'))) {
            Assert-Equal $null (& $trusted $case[0] $case[1]) $case[2]
        }
    }
    It 'ambiente de transporte: git.exe real, PATH restrito a instalacao e Windows, cliente SSH da instalacao' {
        $build = { param([string]$Exec) InModule { param($e) Get-MaGitTransport $e } @($Exec) }
        $windows = @([Environment]::GetFolderPath('System'), [Environment]::GetFolderPath('Windows'))
        # Git for Windows: prefixo mingw64 abaixo da instalacao, usr\bin na instalacao.
        $root = [IO.Path]::Combine((New-FixtureRoot), "Git d'Teste")
        $exec = [IO.Path]::Combine($root, 'mingw64', 'libexec', 'git-core')
        Write-FixtureFile ([IO.Path]::Combine($exec, 'git-remote-https.exe')) ([byte[]]@())
        Write-FixtureFile ([IO.Path]::Combine($root, 'mingw64', 'bin', 'git.exe')) ([byte[]]@())
        $ssh = [IO.Path]::Combine($root, 'usr', 'bin', 'ssh.exe')
        Write-FixtureFile $ssh ([byte[]]@())
        $built = & $build $exec
        Assert-Equal '' $built.Detail
        Assert-Equal ([IO.Path]::Combine($root, 'mingw64', 'bin', 'git.exe')) $built.Transport.GitPath 'git.exe real, sem o wrapper cmd'
        Assert-Equal ((@([IO.Path]::Combine($root, 'mingw64', 'bin'), [IO.Path]::Combine($root, 'usr', 'bin')) + $windows) -join ';') $built.Transport.Path
        Assert-Equal $ssh $built.Transport.Ssh
        Assert-Equal ("'" + $ssh.Replace('\', '/').Replace("'", "'\''") + "'") $built.Transport.SshCommand 'literal sh com apostrofo escapado'
        # Sem o cliente SSH: transporte HTTPS disponivel, SSH recusado; o comando continua fixado na instalacao.
        [IO.File]::Delete($ssh)
        $built = & $build $exec
        Assert-Equal $null $built.Transport.Ssh
        Assert-True ($built.Transport.SshCommand.Contains('/usr/bin/ssh.exe')) $built.Transport.SshCommand
        # Layout sem prefixo MinGW: usr\bin sob o proprio prefixo; diretorio ausente fora do PATH.
        $flat = [IO.Path]::Combine((New-FixtureRoot), 'git')
        Write-FixtureFile ([IO.Path]::Combine($flat, 'libexec', 'git-core', 'git-remote-https.exe')) ([byte[]]@())
        Write-FixtureFile ([IO.Path]::Combine($flat, 'bin', 'git.exe')) ([byte[]]@())
        $built = & $build ([IO.Path]::Combine($flat, 'libexec', 'git-core'))
        Assert-Equal ((@([IO.Path]::Combine($flat, 'bin')) + $windows) -join ';') $built.Transport.Path
        Assert-Equal $null $built.Transport.Ssh
        # git.exe real ausente: recusado.
        $missing = [IO.Path]::Combine((New-FixtureRoot), 'Git', 'mingw64', 'libexec', 'git-core')
        Write-FixtureFile ([IO.Path]::Combine($missing, 'git-remote-https.exe')) ([byte[]]@())
        $built = & $build $missing
        Assert-Equal $null $built.Transport
        Assert-True ($built.Detail.EndsWith('\mingw64\bin\git.exe')) $built.Detail
        # git-remote-ssh (script ou .exe) no exec-path ou num diretorio do PATH restrito: recusado.
        Write-FixtureFile $ssh ([byte[]]@())
        foreach ($helper in @([IO.Path]::Combine($exec, 'git-remote-ssh'), [IO.Path]::Combine($root, 'usr', 'bin', 'git-remote-ssh.exe'), [IO.Path]::Combine($root, 'mingw64', 'bin', 'git-remote-ssh'))) {
            Write-FixtureFile $helper ([byte[]]@())
            $built = & $build $exec
            Assert-Equal $null $built.Transport $helper
            Assert-Equal $helper $built.Detail
            [IO.File]::Delete($helper)
        }
        Assert-True ($null -ne (& $build $exec).Transport) 'layout limpo recusado'
    }
    It 'Git real: contexto define o transporte da instalacao localizada, sem diretorios do usuario' -Requires Git, Job {
        Use-RealGit
        $context = InModule { param($wd) Get-MaGitContext -WorkingDirectory $wd } @($base.Root)
        Assert-Equal '' ((@($context.Issues | Where-Object { $_.Code -ceq 'MA_GIT_TRANSPORT_UNTRUSTED' } | ForEach-Object { $_.Detail })) -join ' | ')
        $transport = InModule { $script:MaGitTransport }
        $install = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($context.Context.ExecPath.Substring(0, $context.Context.ExecPath.Length - '\git-core'.Length)))
        Assert-True ([IO.File]::Exists($transport.GitPath) -and $transport.GitPath.EndsWith('\bin\git.exe')) $transport.GitPath
        $windows = @([Environment]::GetFolderPath('System'), [Environment]::GetFolderPath('Windows'))
        foreach ($directory in $transport.Path.Split(';')) {
            Assert-True ($directory.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase) -or $windows -icontains $directory) ('diretorio fora da instalacao e do Windows: ' + $directory)
        }
        Assert-True ($null -ne $transport.Ssh -and [IO.File]::Exists($transport.Ssh)) 'cliente SSH da instalacao nao localizado'
    }
    It 'GIT_EXEC_PATH do ambiente nao chega ao Git do instalador; aviso no contexto' -Requires Git, Job {
        Use-RealGit
        $saved = [Environment]::GetEnvironmentVariable('GIT_EXEC_PATH')
        $hostile = [IO.Path]::Combine((New-FixtureRoot), 'libexec', 'git-core')
        [void][IO.Directory]::CreateDirectory($hostile)
        $execIssues = { param($Context) (@($Context.Issues | Where-Object { $_.Code -like 'MA_GIT_EXEC_PATH_*' } | ForEach-Object { $_.Severity + ':' + $_.Code + ':' + $_.Detail })) -join ' | ' }
        try {
            [Environment]::SetEnvironmentVariable('GIT_EXEC_PATH', $null)
            $clean = InModule { param($wd) Get-MaGitContext -WorkingDirectory $wd } @($base.Root)
            Assert-True ([bool]$clean.Context.ExecPath) ('exec-path nao confirmado: ' + (& $execIssues $clean))
            Assert-Equal '' (& $execIssues $clean)
            [Environment]::SetEnvironmentVariable('GIT_EXEC_PATH', $hostile)
            $seen = InModule { param($wd) Invoke-MaGit $wd @('--exec-path') } @($base.Root)
            Assert-Equal $clean.Context.ExecPath (InModule { param($p) ConvertTo-MaWindowsPath $p } @(([string]$seen.StdOut).Trim())) 'exec-path do processo filho'
            $context = InModule { param($wd) Get-MaGitContext -WorkingDirectory $wd } @($base.Root)
            Assert-Equal $clean.Context.ExecPath $context.Context.ExecPath
            Assert-Equal 'Aviso:MA_GIT_EXEC_PATH_IGNORED:GIT_EXEC_PATH' (& $execIssues $context)
            # O mesmo exec-path informado no ambiente nao gera aviso.
            [Environment]::SetEnvironmentVariable('GIT_EXEC_PATH', $clean.Context.ExecPath)
            Assert-Equal '' (& $execIssues (InModule { param($wd) Get-MaGitContext -WorkingDirectory $wd } @($base.Root)))
        } finally { [Environment]::SetEnvironmentVariable('GIT_EXEC_PATH', $saved) }
    }

    Write-Output 'Processos nativos com saida grande e prazo'
    $hostExe = (Get-Process -Id $PID).Path
    $shell = $detected.ShPath
    # Caminhos MSYS absolutos: o sh resolve /usr/bin a partir da raiz do Git for
    # Windows, sem depender do PATH do processo (no Codex, sleep nao estava no PATH).
    $sleepCmd = '/usr/bin/sleep'
    $shCmd = '/usr/bin/sh'
    # Oraculo sem WMI: os sleep.exe existentes quando o marcador e criado sao
    # registrados; depois, somente sleep.exe novos e ainda vivos contam. A duracao
    # unica continua identificando o caso na linha de comando. Duas execucoes
    # simultaneas da suite interfeririam neste oraculo: execute uma por vez.
    $script:SleepBaseline = @{}
    function New-SleepMarker {
        $marker = '40.' + (Get-Random -Minimum 100000 -Maximum 999999)
        $script:SleepBaseline[$marker] = @(Get-Process -Name sleep -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        return $marker
    }
    function Get-AliveByMarker {
        param([string]$Marker)
        if (-not $script:SleepBaseline.ContainsKey($Marker)) { throw ('marcador nao registrado: ' + $Marker) }
        Start-Sleep -Milliseconds 500
        $before = @($script:SleepBaseline[$Marker])
        return @(Get-Process -Name sleep -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })
    }
    function Stop-ByMarker {
        param([string]$Marker)
        if (-not $script:SleepBaseline.ContainsKey($Marker)) { return }
        foreach ($p in (Get-AliveByMarker $Marker)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    function Invoke-Sh {
        param([string]$Script, [int]$Timeout)
        return (InModule { param($sh, $s, $wd, $t) Invoke-MaNativeProcess -FilePath $sh -Arguments @('-c', $s) -WorkingDirectory $wd -TimeoutMilliseconds $t } @($shell, $Script, $base.Root, $Timeout))
    }
    # Oraculo sem acesso a outros processos: o filho mantem um mutex nomeado; quando
    # nenhum portador esta vivo, o objeto deixa de existir e OpenExisting falha.
    # Portadores terminam sozinhos ao fim de $Seconds (no maximo 60 s).
    function New-HolderName { return ('Local\ma-holder-' + [Guid]::NewGuid().ToString('N')) }
    function Get-HolderCommand {
        param([string]$Name, [int]$Seconds)
        return ('$m = New-Object System.Threading.Mutex($true, ''' + $Name + '''); Start-Sleep -Seconds ' + $Seconds)
    }
    function Test-HolderAlive {
        param([string]$Name)
        $existing = $null
        if ([System.Threading.Mutex]::TryOpenExisting($Name, [ref]$existing)) { $existing.Dispose(); return $true }
        return $false
    }
    function Wait-HolderAlive {
        param([string]$Name, [int]$TimeoutMilliseconds = 20000)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) { if (Test-HolderAlive $Name) { return $true }; Start-Sleep -Milliseconds 100 }
        return $false
    }
    # Sem confirmacao do executor (KILL_ON_JOB_CLOSE no finally), o encerramento e
    # assincrono: o portador desaparece alguns milissegundos depois do retorno.
    function Wait-HolderGone {
        param([string]$Name, [int]$TimeoutMilliseconds = 3000)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) { if (-not (Test-HolderAlive $Name)) { return $true }; Start-Sleep -Milliseconds 20 }
        return $false
    }
    # Ausencia sustentada: o portador nao existe e nao aparece durante a janela.
    function Assert-HolderAbsent {
        param([string]$Name, [int]$WindowMilliseconds = 3000, [string]$Message = 'portador vivo')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ($clock.ElapsedMilliseconds -lt $WindowMilliseconds) { if (Test-HolderAlive $Name) { throw $Message }; Start-Sleep -Milliseconds 100 }
    }
    function Invoke-HolderChild {
        param([string]$Name, [int]$Timeout, [int]$Seconds = 60)
        InModule { param($exe, $cmd, $wd, $t) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $wd -TimeoutMilliseconds $t } @($hostExe, (Get-HolderCommand $Name $Seconds), $base.Root, $Timeout)
    }
    # Pontos de injecao do executor. As acoes sao scriptblocks deste script (sem
    # GetNewClosure), para enxergar as funcoes acima; parametros vao por $script:.
    function Set-NativeFault { param([string]$Point, [scriptblock]$Action) InModule { param($p, $a) $script:MaNativeFaults[$p] = $a } @($Point, $Action) }
    function Set-AssociationProbe { param([scriptblock]$Probe) InModule { param($p) $script:MaNativeAssociationProbe = $p } @(, $Probe) }
    function Set-NativeApi { param($Api) InModule { param($a) $script:MaNativeApi = $a } @(, $Api) }
    function Clear-NativeTestSeams { InModule { $script:MaNativeFaults = @{}; $script:MaNativeAssociationProbe = $null; $script:MaTerminationConfirmMilliseconds = 5000 } }
    # Depois da retomada, espera o portador existir: o processo executou antes da falha.
    $script:FaultHolder = $null
    $script:HolderSeen = $false
    function Set-AfterResumeWait { param([string]$Name) $script:FaultHolder = $Name; $script:HolderSeen = $false; Set-NativeFault 'AfterResume' { $script:HolderSeen = Wait-HolderAlive $script:FaultHolder 20000; $false } }
    # Sem isto, a ausencia posterior do portador passaria mesmo se ele nunca tivesse existido.
    function Assert-HolderWasAlive { if (-not $script:HolderSeen) { throw 'o processo nao chegou a ser observado vivo antes da falha' } }
    # Excecao completa (codigo e Data) de uma chamada que deve falhar.
    function Get-NativeFailure { param([scriptblock]$Body) try { [void](& $Body) } catch { return $_.Exception }; throw 'nenhuma excecao' }
    $UnconfirmedProbe = { param($e) [pscustomobject]@{ Confirmed = $false; InJob = $e.InJob; JobProcessIds = $e.JobProcessIds } }

    It 'drena 4 MiB em stdout e 4 MiB em stderr intercalados, com codigo de saida e stderr capturados' -Requires Job {
        $command = '$o = [string]::new([char]111, 65536); $e = [string]::new([char]101, 65536); for ($i = 0; $i -lt 64; $i++) { [Console]::Out.Write($o); [Console]::Error.Write($e) }; exit 3'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = InModule { param($exe, $cmd, $wd) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $wd -TimeoutMilliseconds 60000 } @($hostExe, $command, $base.Root)
        Assert-Equal 3 $result.ExitCode
        Assert-Equal (64 * 65536) $result.StdOut.Length 'stdout'
        Assert-Equal (64 * 65536) $result.StdErr.Length 'stderr'
        Assert-True ($result.StdOut.Trim([char]111).Length -eq 0 -and $result.StdErr.Trim([char]101).Length -eq 0) 'conteudo'
        Assert-True ($clock.ElapsedMilliseconds -lt 60000) 'prazo'
    }
    It 'stdin com prazo: texto entregue ao processo e lido de volta' -Requires Job {
        $result = InModule { param($exe, $wd) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', '[Console]::In.ReadToEnd().ToUpperInvariant()') -WorkingDirectory $wd -TimeoutMilliseconds 30000 -InputText "abc`ndef`n" } @($hostExe, $base.Root)
        Assert-Equal 0 $result.ExitCode
        Assert-Equal "ABC`nDEF" ($result.StdOut.Replace("`r", '').TrimEnd("`n"))
    }
    It 'ambiente: substituicoes com espaco, aspas e simbolos chegam literais; ambiente atual herdado' -Requires Job {
        $value = "a b & `$x 'c' %PATH%"
        $result = InModule { param($exe, $wd, $v) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write($env:MA_TESTE_VALOR + ''|'' + [string]::IsNullOrEmpty($env:SystemRoot))') -WorkingDirectory $wd -Environment @{ MA_TESTE_VALOR = $v } -TimeoutMilliseconds 30000 } @($hostExe, $base.Root, $value)
        Assert-Equal ($value + '|False') $result.StdOut
    }
    It 'processo que nao termina e encerrado no prazo, com encerramento do job conferido' -Requires Job {
        $holder = New-HolderName
        try {
            Set-AfterResumeWait $holder
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 3000 }
            Assert-Equal 'MA_NATIVE_TIMEOUT' $failure.Message
            Assert-True ($clock.ElapsedMilliseconds -lt 30000) ('demorou ' + $clock.ElapsedMilliseconds + ' ms')
            Assert-HolderWasAlive
            Assert-HolderAbsent $holder 1500 'processo filho ainda ativo apos o timeout'
        } finally { Clear-NativeTestSeams }
    }
    It 'API do executor emitida em memoria, sem Add-Type nem arquivos' -Requires Job {
        Assert-True ($null -ne (InModule { Get-MaNativeApi })) 'API indisponivel'
    }
    It 'descendente orfao (exec do MSYS) com pipes abertos: retorno no prazo e nenhum descendente vivo' -Requires Job, Sh {
        $marker = New-SleepMarker
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Assert-Throws { Invoke-Sh ($sleepCmd + ' ' + $marker + ' & echo pronto') 2000 } 'MA_NATIVE_TIMEOUT'
            Assert-True ($clock.ElapsedMilliseconds -lt 8000) ('demorou ' + $clock.ElapsedMilliseconds + ' ms; esperou o descendente')
            Assert-Equal 0 @(Get-AliveByMarker $marker).Count 'descendente sobreviveu ao timeout'
        } finally { Stop-ByMarker $marker }
    }
    It 'descendentes em subshell com pai intermediario encerrado tambem sao encerrados' -Requires Job, Sh {
        $marker = New-SleepMarker
        try {
            Assert-Throws { Invoke-Sh ('(' + $sleepCmd + ' ' + $marker + '; true) & (' + $shCmd + ' -c "' + $sleepCmd + ' ' + $marker + '" &) ; echo pronto') 2000 } 'MA_NATIVE_TIMEOUT'
            Assert-Equal 0 @(Get-AliveByMarker $marker).Count 'descendente sobreviveu ao timeout'
        } finally { Stop-ByMarker $marker }
    }
    It 'processo principal ainda ativo no timeout: arvore inteira encerrada' -Requires Job, Sh {
        $marker = New-SleepMarker
        try {
            Assert-Throws { Invoke-Sh ($sleepCmd + ' ' + $marker + ' & ' + $sleepCmd + ' ' + $marker) 1500 } 'MA_NATIVE_TIMEOUT'
            Assert-Equal 0 @(Get-AliveByMarker $marker).Count 'processos sobreviveram ao timeout'
        } finally { Stop-ByMarker $marker }
    }
    It 'descendente que libera os pipes e permanece ativo: encerrado pelo job e chamada recusada' -Requires Job, Sh {
        $marker = New-SleepMarker
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Assert-Throws { Invoke-Sh ($sleepCmd + ' ' + $marker + ' </dev/null >/dev/null 2>&1 & echo pronto') 10000 } 'MA_NATIVE_DESCENDANT_PERSISTED'
            Assert-True ($clock.ElapsedMilliseconds -lt 10000) ('demorou ' + $clock.ElapsedMilliseconds + ' ms')
            Assert-Equal 0 @(Get-AliveByMarker $marker).Count 'descendente persistente nao foi encerrado'
        } finally { Stop-ByMarker $marker }
    }
    It 'descendente que termina antes do fim da chamada nao gera falha' -Requires Job, Sh {
        $result = Invoke-Sh ('(' + $sleepCmd + ' 1; echo filho) & echo pai; wait; echo erro >&2; exit 5') 20000
        Assert-Equal 5 $result.ExitCode
        Assert-Equal "pai`nfilho`n" $result.StdOut
        Assert-Equal "erro`n" $result.StdErr
    }
    It 'timeout do Git durante o Plan e falha operacional' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $previous = $GitMock
        InModule { param($m) $script:MaGitInvoker = { param($wd, $a, $b, $i) if ($a[0] -ceq 'worktree') { throw 'MA_NATIVE_TIMEOUT' }; & $m $wd $a $b $i }.GetNewClosure() } @(, $previous)
        $plan = Invoke-Plan $s
        Assert-Equal 'Falha' $plan.Status
        Assert-Equal 'MA_NATIVE_TIMEOUT' @($plan.Issues | Where-Object { $_.Severity -eq 'Falha' })[0].Code
        Assert-Equal 4 (Get-MaExitCode $plan.Status)
    }

    Write-Output 'Executor seguro: contencao antes da execucao'
    It 'API indisponivel: recusa antes de iniciar processo, sem afirmar encerramento' {
        $holder = New-HolderName
        try {
            Set-NativeApi $false
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 30000 }
            Assert-Equal 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' $failure.Message
            Assert-True (-not (InModule { Get-MaMessage 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' }).Contains('encerrado')) 'mensagem afirma encerramento sem processo'
            Assert-HolderAbsent $holder 3000 'um processo foi iniciado sem job'
        } finally { Set-NativeApi $null; Clear-NativeTestSeams }
    }
    foreach ($point in @('JobLimitSet', 'JobLimitQuery')) {
        It ('limite do job nao confirmado (' + $point + ' simulado): nenhum processo criado') -Requires Job {
            $holder = New-HolderName
            try {
                Set-NativeFault $point { $true }
                $failure = Get-NativeFailure { Invoke-HolderChild $holder 30000 }
                Assert-Equal 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' $failure.Message
                Assert-Equal 'JobLimit' $failure.Data['Stage']
                Assert-HolderAbsent $holder 3000 'um processo foi iniciado sem o limite confirmado'
            } finally { Clear-NativeTestSeams }
        }
    }
    It 'job: KILL_ON_JOB_CLOSE como unico limite, sem breakaway, e handle nao herdavel' -Requires Job {
        $info = InModule {
            $job = New-MaNativeJob
            try {
                $cell = New-MaNativeZeroMemory 4
                try { [void](Get-MaNativeApi)::GetHandleInformation($job, $cell); $handleFlags = [System.Runtime.InteropServices.Marshal]::ReadInt32($cell, 0) }
                finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($cell) }
                [pscustomobject]@{ Limit = (Get-MaNativeJobLimitFlags $job); HandleFlags = $handleFlags }
            } finally { [void](Close-MaNativeHandle $job 'Job') }
        }
        Assert-Equal 0x2000 $info.Limit 'LimitFlags'
        Assert-Equal 0 ($info.HandleFlags -band 1) 'handle do job herdavel'
    }
    It 'processo nasce no job, conferido antes da retomada; suspenso nao executa' -Requires Job {
        $holder = New-HolderName
        $script:FaultHolder = $holder; $script:HolderBeforeResume = $null; $script:HolderSeen = $false; $script:Evidence = $null
        try {
            Set-AssociationProbe { param($e) $script:Evidence = $e; $e }
            Set-NativeFault 'BeforeResume' { Start-Sleep -Milliseconds 2000; $script:HolderBeforeResume = Test-HolderAlive $script:FaultHolder; $false }
            Set-NativeFault 'AfterResume' { $script:HolderSeen = Wait-HolderAlive $script:FaultHolder 20000; $false }
            $result = Invoke-HolderChild $holder 60000 3
            Assert-Equal 0 $result.ExitCode
            Assert-Equal $false $script:HolderBeforeResume 'o processo executou antes da retomada'
            Assert-True $script:HolderSeen 'o processo nao executou depois da retomada'
            Assert-True $script:Evidence.Confirmed 'associacao nao confirmada'
            Assert-Equal $true $script:Evidence.InJob 'IsProcessInJob'
            Assert-Equal 1 @($script:Evidence.JobProcessIds).Count 'lista de PIDs do job'
        } finally { Clear-NativeTestSeams }
    }
    It 'associacao nao confirmada: suspenso encerrado sem executar e chamada recusada' -Requires Job {
        $holder = New-HolderName
        try {
            Set-AssociationProbe $UnconfirmedProbe
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 30000 }
            Assert-Equal 'MA_NATIVE_CONTAINMENT_FAILED' $failure.Message
            Assert-Equal 'Association' $failure.Data['Stage']
            Assert-HolderAbsent $holder 3000 'o processo executou sem associacao confirmada'
        } finally { Clear-NativeTestSeams }
    }
    It 'associacao nao confirmada e TerminateProcess recusado (simulado): codigo proprio, o processo nao executa' -Requires Job {
        $holder = New-HolderName
        try {
            Set-AssociationProbe $UnconfirmedProbe
            Set-NativeFault 'TerminateProcess' { $true }
            InModule { $script:MaTerminationConfirmMilliseconds = 1000 }
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 30000 }
            Assert-Equal 'MA_NATIVE_CONTAINMENT_FAILED_UNTERMINATED' $failure.Message
            Assert-Equal 'TerminateProcess' $failure.Data['Stage']
            Assert-Equal 'MA_NATIVE_CONTAINMENT_FAILED' $failure.Data['Cause']
            Assert-HolderAbsent $holder 3000 'o processo suspenso chegou a executar'
        } finally { Clear-NativeTestSeams }
    }
    It 'falha simulada na construcao do stream: suspenso encerrado sem executar, erro original preservado' -Requires Job {
        $holder = New-HolderName
        try {
            Set-NativeFault 'StreamCreate' { param($c) if ($c.Name -ceq 'StdOutRead') { throw 'MA_TESTE_FALHA_INJETADA' }; $false }
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 30000 }
            Assert-Equal 'MA_TESTE_FALHA_INJETADA' $failure.Message
            Assert-HolderAbsent $holder 3000 'o processo executou'
        } finally { Clear-NativeTestSeams }
    }
    It 'neto criado logo apos a retomada permanece no job e e encerrado (inversao da limitacao do executor interino)' -Requires Job {
        $holder = New-HolderName
        try {
            # O filho inicia um neto que segura o mutex e herda o pipe de saida; o
            # filho sai em 8 s e o neto viveria 30 s mantendo o pipe aberto.
            $grandchild = Get-HolderCommand $holder 30
            $child = '$i = New-Object System.Diagnostics.ProcessStartInfo(''' + $hostExe + ''', ''-NoProfile -NonInteractive -Command "' + $grandchild.Replace('''', '''''') + '"''); $i.UseShellExecute = $false; $i.CreateNoWindow = $true; [void][System.Diagnostics.Process]::Start($i); Start-Sleep -Seconds 8; ''pronto'''
            Set-AfterResumeWait $holder
            Assert-Throws { InModule { param($exe, $cmd, $wd) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $wd -TimeoutMilliseconds 15000 } @($hostExe, $child, $base.Root) } 'MA_NATIVE_TIMEOUT'
            Assert-HolderWasAlive
            Assert-HolderAbsent $holder 1500 'o neto escapou do job'
        } finally { Clear-NativeTestSeams }
    }
    It 'lancador cmd\git.exe: o git real nasce dentro do job' -Requires Job, GitLauncher {
        $launcher = $detected.LauncherPath
        $realGit = [IO.Path]::Combine([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($launcher)), 'mingw64', 'bin', 'git.exe')
        Assert-True ([IO.File]::Exists($realGit)) ('git real nao localizado: ' + $realGit)
        $measure = {
            param($exe, $wd)
            $job = New-MaNativeJob
            $state = $null
            try {
                $state = Start-MaNativeSuspendedProcess -Job $job -FilePath $exe -Arguments @('--version') -WorkingDirectory $wd -Environment @{}
                Resume-MaNativeProcess $state
                $exited = ((Get-MaNativeApi)::WaitForSingleObject($state.ProcessHandle, [uint32]30000) -eq 0)
                $settled = Wait-MaNativeJobEmpty $job 5000
                [pscustomobject]@{ Exited = $exited; Settled = $settled.Status; Total = (Get-MaNativeJobAccounting $job).Total; Confirmed = $state.Evidence.Confirmed }
            } finally { try { Close-MaNativeProcess $state } catch { }; [void](Close-MaNativeHandle $job 'Job') }
        }
        $direct = InModule $measure @($realGit, $base.Root)
        $viaLauncher = InModule $measure @($launcher, $base.Root)
        foreach ($m in @($direct, $viaLauncher)) { Assert-True ($m.Exited -and $m.Confirmed -and $m.Settled -eq 'Empty') 'execucao contida' }
        # O lancador acrescenta pelo menos o git real a contabilidade do job.
        Assert-True ($viaLauncher.Total -ge $direct.Total + 1) ('processos no job: direto ' + $direct.Total + ', lancador ' + $viaLauncher.Total)
    }

    Write-Output 'Executor seguro: encerramento e limpeza'
    It 'timeout com TerminateJobObject recusado (simulado): nao confirmado; o fechamento do job encerra o processo' -Requires Job {
        $holder = New-HolderName
        try {
            Set-AfterResumeWait $holder
            Set-NativeFault 'TerminateJobObject' { $true }
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 3000 }
            Assert-Equal 'MA_NATIVE_TERMINATION_UNCONFIRMED' $failure.Message
            Assert-Equal 'TerminateJobObject' $failure.Data['Stage']
            Assert-Equal 'MA_NATIVE_TIMEOUT' $failure.Data['Cause']
            Assert-HolderWasAlive
            Assert-True (Wait-HolderGone $holder 3000) 'KILL_ON_JOB_CLOSE nao encerrou o processo'
            Assert-HolderAbsent $holder 1500 'processo reapareceu apos o fechamento do job'
        } finally { Clear-NativeTestSeams }
    }
    It 'timeout com consulta do job recusada no encerramento (simulada): nao confirmado' -Requires Job {
        $holder = New-HolderName
        try {
            Set-AfterResumeWait $holder
            Set-NativeFault 'JobAccounting' { $true }
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 3000 }
            Assert-Equal 'MA_NATIVE_TERMINATION_UNCONFIRMED' $failure.Message
            Assert-Equal 'JobQuery' $failure.Data['Stage']
            Assert-Equal 'MA_NATIVE_TIMEOUT' $failure.Data['Cause']
            Assert-HolderWasAlive
            Assert-True (Wait-HolderGone $holder 3000) 'processo ativo apos o encerramento'
            Assert-HolderAbsent $holder 1500 'processo reapareceu apos o encerramento'
        } finally { Clear-NativeTestSeams }
    }
    It 'sucesso com consulta final do job recusada (simulada): sem resultado de sucesso' -Requires Job {
        try {
            Set-NativeFault 'JobAccounting' { $true }
            $failure = Get-NativeFailure { InModule { param($exe, $wd) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') -WorkingDirectory $wd -TimeoutMilliseconds 30000 } @($hostExe, $base.Root) }
            Assert-Equal 'MA_NATIVE_TERMINATION_UNCONFIRMED' $failure.Message
        } finally { Clear-NativeTestSeams }
    }
    It 'falha depois da retomada: descendentes encerrados antes do retorno e erro original preservado' -Requires Job {
        $holder = New-HolderName
        $script:FaultHolder = $holder; $script:HolderSeen = $false
        try {
            Set-NativeFault 'AfterResume' { $script:HolderSeen = Wait-HolderAlive $script:FaultHolder 20000; throw 'MA_TESTE_FALHA_INJETADA' }
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 30000 }
            Assert-Equal 'MA_TESTE_FALHA_INJETADA' $failure.Message
            Assert-HolderWasAlive
            Start-Sleep -Milliseconds 100
            Assert-HolderAbsent $holder 1000 'processo ativo quando o executor retornou'
        } finally { Clear-NativeTestSeams }
    }
    It 'enumeracao dos membros falha no encerramento: erro original preservado, falha registrada e processo encerrado' -Requires Job {
        $holder = New-HolderName
        $script:FaultHolder = $holder; $script:HolderSeen = $false
        try {
            Set-NativeFault 'JobMembers' { $true }
            Set-NativeFault 'AfterResume' { $script:HolderSeen = Wait-HolderAlive $script:FaultHolder 20000; throw 'MA_TESTE_FALHA_INJETADA' }
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 30000 }
            Assert-Equal 'MA_TESTE_FALHA_INJETADA' $failure.Message
            $cleanup = (@($failure.Data['CleanupFailures']) -join ',')
            Assert-True ($cleanup.Contains('MemberEnumeration:MA_NATIVE_JOB_QUERY_FAILED')) $cleanup
            Assert-HolderWasAlive
            Assert-HolderAbsent $holder 1500 'processo ativo apos o encerramento'
        } finally { Clear-NativeTestSeams }
    }
    It 'CloseHandle do job recusado apos sucesso: MA_NATIVE_CLEANUP_FAILED, sem resultado, uma unica tentativa' -Requires Job {
        $script:KeptJob = [IntPtr]::Zero; $script:JobCloses = 0
        try {
            Set-NativeFault 'CloseHandle' { param($c) if ($c.Name -ceq 'Job') { $script:JobCloses++; $script:KeptJob = $c.Handle; return $true }; $false }
            $failure = Get-NativeFailure { InModule { param($exe, $wd) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') -WorkingDirectory $wd -TimeoutMilliseconds 30000 } @($hostExe, $base.Root) }
            Assert-Equal 'MA_NATIVE_CLEANUP_FAILED' $failure.Message
            $cleanup = (@($failure.Data['CleanupFailures']) -join ',')
            Assert-True ($cleanup.Contains('Job:MA_NATIVE_CLOSE_FAILED')) $cleanup
            Assert-Equal 1 $script:JobCloses 'tentativas de fechar o job'
        } finally {
            Clear-NativeTestSeams
            if ($script:KeptJob -ne [IntPtr]::Zero) { [void](InModule { param($h) (Get-MaNativeApi)::CloseHandle($h) } @($script:KeptJob)) }
        }
    }
    It 'CloseHandle do job recusado apos falha principal: erro original prevalece e a falha de limpeza e registrada' -Requires Job {
        $holder = New-HolderName
        $script:FaultHolder = $holder; $script:HolderSeen = $false; $script:KeptJob = [IntPtr]::Zero
        try {
            Set-NativeFault 'CloseHandle' { param($c) if ($c.Name -ceq 'Job') { $script:KeptJob = $c.Handle; return $true }; $false }
            Set-NativeFault 'AfterResume' { $script:HolderSeen = Wait-HolderAlive $script:FaultHolder 20000; throw 'MA_TESTE_FALHA_INJETADA' }
            $failure = Get-NativeFailure { Invoke-HolderChild $holder 30000 }
            Assert-Equal 'MA_TESTE_FALHA_INJETADA' $failure.Message
            $cleanup = (@($failure.Data['CleanupFailures']) -join ',')
            Assert-True ($cleanup.Contains('Job:MA_NATIVE_CLOSE_FAILED')) $cleanup
            # O encerramento foi confirmado antes do fechamento recusado.
            Assert-HolderAbsent $holder 1500 'processo ativo apos o encerramento'
        } finally {
            Clear-NativeTestSeams
            if ($script:KeptJob -ne [IntPtr]::Zero) { [void](InModule { param($h) (Get-MaNativeApi)::CloseHandle($h) } @($script:KeptJob)) }
        }
    }
    It 'Job Object real: processo instantaneo com API recem-criada nao gera falsa falha por corrida (50 repeticoes)' -Requires Git, Job {
        $git = $detected.GitPath
        for ($i = 0; $i -lt 50; $i++) {
            Set-NativeApi $null
            $result = InModule { param($g, $wd) Invoke-MaNativeProcess -FilePath $g -Arguments @('--version') -WorkingDirectory $wd -TimeoutMilliseconds 30000 } @($git, $base.Root)
            Assert-Equal 0 $result.ExitCode ('repeticao ' + $i)
        }
    }
    It 'executor real volta a funcionar apos restaurar a API' -Requires Job {
        $result = InModule { param($exe, $wd) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'exit 7') -WorkingDirectory $wd -TimeoutMilliseconds 30000 } @($hostExe, $base.Root)
        Assert-Equal 7 $result.ExitCode
    }
    It 'Plan com executor indisponivel e falha operacional, nunca sucesso' -Requires Git {
        Use-RealGit
        $s = New-Scenario
        try {
            Set-NativeApi $false
            $plan = Invoke-Plan $s
        } finally { Set-NativeApi $null }
        Assert-Equal 'Falha' $plan.Status
        Assert-HasIssue $plan 'MA_NATIVE_CONTAINMENT_UNAVAILABLE'
        $issue = @($plan.Issues | Where-Object { $_.Code -ceq 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' })[0]
        Assert-True ($issue.Detail.Contains('Stage=Api')) ('detalhe: ' + $issue.Detail)
    }

    Write-Output 'Leitura binaria e objetos Git'
    It 'saida binaria preserva BOM, CR, NUL e bytes nao UTF-8' -Requires Job {
        $command = '$o = [Console]::OpenStandardOutput(); $b = [byte[]](239,187,191,97,13,10,0,255,128); $o.Write($b, 0, $b.Length); $o.Flush()'
        $result = InModule { param($exe, $cmd, $wd) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $wd -BinaryOutput } @($hostExe, $command, $base.Root)
        Assert-Equal '239,187,191,97,13,10,0,255,128' (($result.StdOutBytes | ForEach-Object { [string]$_ }) -join ',')
    }
    It 'diagnostico de objeto: cada resultado e distinguido' {
        Use-GitMock
        $script:Repos[$base.Root] = New-RepoState $base.Root
        $okId = Register-Object ([byte[]](239, 187, 191) + $Utf8.GetBytes("x`n"))
        $corruptId = Register-Object ($Utf8.GetBytes("original`n")); $script:Objects[$corruptId] = $Utf8.GetBytes("trocado`n")
        $treeId = Register-Object ($Utf8.GetBytes("arvore`n")); $script:ObjectTypes[$treeId] = 'tree'
        $unreadableId = 'c' * 40; $script:UnreadableObjects = @($unreadableId)
        $missingId = 'd' * 40
        $batchFailId = 'e' * 40; $script:BatchCheckFails = @($batchFailId)
        $existFailId = 'f' * 40; $script:ExistenceCheckFails = @($existFailId)
        $expected = [ordered]@{ $okId = 'Ok'; $corruptId = 'Corrupt'; $treeId = 'TypeMismatch'; $unreadableId = 'Unreadable'; $missingId = 'Missing'; $batchFailId = 'Undetermined'; $existFailId = 'Undetermined'; 'nao-hex' = 'Undetermined' }
        foreach ($oid in $expected.Keys) { Assert-Equal $expected[$oid] (InModule { param($r, $o) Test-MaGitBlobObject $r $o 'sha1' } @($base.Root, $oid)) $oid }
    }
    It 'ausencia so e comprovada com batch-check e cat-file -e concordantes e sem erro' {
        Use-GitMock
        $script:Repos[$base.Root] = New-RepoState $base.Root
        $missingId = 'a1' * 20
        Assert-Equal 'Missing' (InModule { param($r, $o) Test-MaGitBlobObject $r $o 'sha1' } @($base.Root, $missingId))
        Assert-True ($script:GitCalls -ccontains 'cat-file --batch-check') 'batch-check nao consultado'
        Assert-True ($script:GitCalls -ccontains ('cat-file -e ' + $missingId)) 'cat-file -e nao consultado'
        # "missing" com erro no stderr (objeto corrompido) nao prova ausencia.
        $script:UnreadableObjects = @($missingId)
        Assert-Equal 'Unreadable' (InModule { param($r, $o) Test-MaGitBlobObject $r $o 'sha1' } @($base.Root, $missingId))
    }
    It 'objeto ausente bloqueia e torna o destino inconclusivo' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $agents = @($s.Rendered | Where-Object { $_.Path -eq 'AGENTS.md' })[0]
        $script:Objects.Remove((Get-BlobId $agents.Bytes))
        $plan = Invoke-Plan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-Equal 2 @($plan.Issues | Where-Object { $_.Code -eq 'MA_GIT_OBJECT_MISSING' -and $_.Path -eq 'AGENTS.md' }).Count 'HEAD e indice'
        $file = @($plan.Files | Where-Object { $_.Role -eq 'coordination' -and $_.Path -eq 'AGENTS.md' })[0]
        Assert-Equal 'Inconclusivo' $file.Classification
        Assert-True ($file.Reason -like '*HEAD: objeto Missing*') $file.Reason
    }
    It 'objeto presente mas ilegivel bloqueia' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $readme = Get-BlobId (@($s.Rendered | Where-Object { $_.Path -eq 'README.md' })[0].Bytes)
        $script:Objects.Remove($readme); $script:UnreadableObjects = @($readme)
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_GIT_OBJECT_UNREADABLE' 'coordination'
        Assert-Equal 'Inconclusivo' (@($plan.Files | Where-Object { $_.Path -eq 'README.md' })[0].Classification)
    }
    It 'objeto com causa nao determinada bloqueia com codigo proprio' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $claude = Get-BlobId (@($s.Rendered | Where-Object { $_.Path -eq 'CLAUDE.md' })[0].Bytes)
        $script:Objects.Remove($claude); $script:BatchCheckFails = @($claude)
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_GIT_OBJECT_UNVERIFIED' 'coordination'
        Assert-NoIssue $plan 'MA_GIT_OBJECT_MISSING'
        Assert-Equal 'Bloqueado' $plan.Status
    }
    It 'objeto com tipo diferente de blob bloqueia' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $script:ObjectTypes[(Get-BlobId (@($s.Rendered | Where-Object { $_.Path -eq 'AGENTS.md' })[0].Bytes))] = 'tree'
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_GIT_OBJECT_TYPE_MISMATCH' 'coordination'
        Assert-Equal 'Bloqueado' $plan.Status
    }
    It 'objeto corrompido (conteudo nao corresponde ao id) bloqueia apesar de id e checkout corretos' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $claude = @($s.Rendered | Where-Object { $_.Path -eq 'CLAUDE.md' })[0]
        $script:Objects[(Get-BlobId $claude.Bytes)] = $Utf8.GetBytes("conteudo trocado`n")
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_GIT_OBJECT_CORRUPT' 'coordination'
        $file = @($plan.Files | Where-Object { $_.Path -eq 'CLAUDE.md' })[0]
        Assert-Equal 'Inconclusivo' $file.Classification
        Assert-True ($file.Reason -like '*objeto Corrupt*') $file.Reason
        Assert-Equal 'Bloqueado' $plan.Status
    }
    It 'cada objeto e lido uma unica vez por ambiente e todos os objetos ok mantem Sucesso' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $plan = Invoke-Plan $s ('b' * 40)
        Assert-Equal 'Sucesso' $plan.Status ((@($plan.Issues | ForEach-Object { $_.Code })) -join ',')
        $reads = @($script:GitCalls | Where-Object { $_ -like 'cat-file blob *' })
        Assert-Equal @($reads | Sort-Object -Unique).Count $reads.Count 'leitura repetida'
        Assert-Equal 11 $reads.Count
        Assert-Equal 11 @($script:GitCalls | Where-Object { $_ -ceq 'cat-file --batch-check' }).Count 'consulta de presenca por objeto'
    }

    Write-Output 'Identificacao de hooks'
    It 'distingue hooks reconhecidos pelo Git de arquivos auxiliares' {
        $dir = [IO.Path]::Combine($base.Root, 'hooks-inventario')
        foreach ($name in @('pre-commit', 'Post-Merge', 'commit-msg.exe', 'pre-push.sample', 'README.md', 'helper.sh', 'pre-commit.bak', 'pre-commit.ps1', 'reference-transaction')) {
            Write-FixtureFile ([IO.Path]::Combine($dir, $name)) $Utf8.GetBytes("#!/bin/sh`n")
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($dir, 'update'))
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($dir, 'lib'))
        $inventory = InModule { param($d) Get-MaHookInventory $d } @($dir)
        Assert-Equal 'commit-msg.exe,Post-Merge,pre-commit,reference-transaction,update/' (($inventory.Active | Sort-Object) -join ',')
        Assert-Equal 'helper.sh,lib,pre-commit.bak,pre-commit.ps1,pre-push.sample,README.md' (($inventory.Auxiliary | Sort-Object) -join ',')
    }
    It 'somente arquivos auxiliares no diretorio padrao nao geram aviso' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        foreach ($name in @('pre-commit.sample', 'README.txt', 'helper.sh')) { Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, '.git', 'hooks', $name)) $Utf8.GetBytes("x`n") }
        $plan = Invoke-Plan $s
        Assert-Equal 0 @($plan.Issues | Where-Object { $_.Code -like 'MA_HOOKS_*_ACTIVE' }).Count
        Assert-Equal 'helper.sh,pre-commit.sample,README.txt' ((@($plan.Environments | Where-Object { $_.Role -eq 'coordination' })[0].AuxiliaryHookFiles | Sort-Object) -join ',')
        Assert-Equal 'Sucesso' $plan.Status
    }

    Write-Output 'Plan com repositorios simulados'
    It 'workspace vazio: Incompleto, acoes previstas e nenhuma modificacao' {
        Use-GitMock
        $s = New-Scenario
        $before = Get-Snapshot $s.Root
        $plan = Invoke-Plan $s
        Assert-Equal 'Incompleto' $plan.Status
        Assert-Equal $false $plan.Modified
        Assert-True (@($plan.Actions | Where-Object { $_.Description -like 'Clonar origin*' }).Count -eq 1) 'clone previsto'
        Assert-True (@($plan.Actions | Where-Object { $_.Phase -eq 'CompleteWorktrees' -and $_.Role -eq 'codex' }).Count -eq 1) 'codex previsto'
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
        Assert-Equal 2 (Get-MaExitCode $plan.Status)
    }
    It 'pacote invalido bloqueia e nao renderiza' {
        Use-GitMock
        $s = New-Scenario
        Write-FixtureFile ([IO.Path]::Combine($s.Package, 'templates', 'README.md.tmpl')) $Utf8.GetBytes("# {{PROJECT_NAME_MD}}`nalterado`n")
        $plan = Invoke-Plan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-HasIssue $plan 'MA_PACKAGE_HASH_MISMATCH'
        Assert-Equal 0 @($plan.Files).Count
    }
    It 'configuracao invalida bloqueia' {
        Use-GitMock
        $s = New-Scenario
        $s.Config = New-FixtureConfig $s.Root $s.Workspace -Url 'https://u:p@example.invalid/r.git'
        $plan = Invoke-Plan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-HasIssue $plan 'MA_REPOSITORY_URL_INVALID'
    }
    It 'coordenacao com arquivos identicos: Sucesso e manutencao prevista' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $before = Get-Snapshot $s.Root
        $plan = Invoke-Plan $s ('b' * 40)
        Assert-Equal 'Sucesso' $plan.Status ((@($plan.Issues | ForEach-Object { $_.Code + ' ' + $_.Path })) -join '; ')
        Assert-Equal 11 @($plan.Files | Where-Object { $_.Role -eq 'coordination' -and $_.Classification -eq 'Identico' }).Count
        Assert-True (@($plan.Actions | Where-Object { $_.Role -eq 'maintenance' -and $_.Description -like 'Criar worktree*' }).Count -eq 1) 'manutencao'
        Assert-Equal 'presente localmente como commit; autorizacao nao verificada' $plan.Evidence.BaseCommit
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'clone sem checkout (indice ausente): aviso, acao de retomada e classificacao pelo HEAD' {
        Use-GitMock
        $s = New-Scenario
        $repo = New-Coordination $s
        Add-GovernedEntries $repo $s.Rendered -Tree
        $repo.IndexFileMissing = $true
        $before = Get-Snapshot $s.Root
        $plan = Invoke-Plan $s ('b' * 40)
        Assert-Equal 'Incompleto' $plan.Status ((@($plan.Issues | ForEach-Object { $_.Code + ' ' + $_.Path })) -join '; ')
        Assert-HasIssue $plan 'MA_ENV_CHECKOUT_PENDING' 'coordination'
        Assert-Equal 'CheckoutPendente' @($plan.Environments | Where-Object { $_.Role -eq 'coordination' })[0].State
        Assert-Equal 11 @($plan.Files | Where-Object { $_.Role -eq 'coordination' -and $_.Classification -eq 'Identico' -and $_.Reason -like 'checkout pendente*' }).Count
        Assert-True (@($plan.Actions | Where-Object { $_.Role -eq 'coordination' -and $_.Description -like 'Concluir o checkout pendente*' }).Count -eq 1) 'retomada prevista'
        # Arquivo no checkout antes da conclusao: divergente, nunca identico.
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, 'AGENTS.md')) $s.Rendered[0].Bytes
        $plan = Invoke-Plan $s ('b' * 40)
        Assert-HasIssue $plan 'MA_FILE_CONFLICT' 'coordination'
        [IO.File]::Delete([IO.Path]::Combine($s.Model.Worktrees.coordination, 'AGENTS.md'))
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'repositorio sem commit bloqueia (AC23)' {
        Use-GitMock
        $s = New-Scenario
        $repo = New-Coordination $s
        $repo.Head = $null
        $plan = Invoke-Plan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-HasIssue $plan 'MA_REPOSITORY_NO_COMMIT' 'coordination'
    }
    It 'README criado pelo servidor e diferente gera conflito (AC09, AC24)' {
        Use-GitMock
        $s = New-Scenario
        $repo = New-Coordination $s
        $readme = $Utf8.GetBytes("# demo`n")
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, 'README.md')) $readme
        $id = Register-Object $readme
        $repo.Tree = @('100644 blob ' + $id + "`tREADME.md"); $repo.Index = @('100644 ' + $id + " 0`tREADME.md")
        $plan = Invoke-Plan $s
        Assert-Equal 'Bloqueado' $plan.Status
        Assert-HasIssue $plan 'MA_FILE_CONFLICT' 'coordination'
        Assert-Equal 'Conflitante' (@($plan.Files | Where-Object { $_.Role -eq 'coordination' -and $_.Path -eq 'README.md' })[0].Classification)
        Assert-Equal 'Ausente' (@($plan.Files | Where-Object { $_.Role -eq 'coordination' -and $_.Path -eq 'AGENTS.md' })[0].Classification)
    }
    It '.gitattributes diferente tambem e conflito, sem excecao' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s)
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, '.gitattributes')) $Utf8.GetBytes("* text=auto`n")
        $plan = Invoke-Plan $s
        Assert-Equal 'Conflitante' (@($plan.Files | Where-Object { $_.Path -eq '.gitattributes' })[0].Classification)
    }
    It 'hook com modo 100644 no HEAD e rejeitado mesmo com bytes corretos' {
        Use-GitMock
        $s = New-Scenario
        $path = $s.Model.Worktrees.coordination
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($path, '.git'))
        $repo = New-RepoState $path
        $repo.Worktrees = @('worktree ' + $path.Replace('\', '/') + [char]0 + 'branch refs/heads/main')
        foreach ($file in $s.Rendered) { Write-FixtureFile ([IO.Path]::Combine($path, $file.Path.Replace('/', '\'))) $file.Bytes }
        Add-GovernedEntries $repo $s.Rendered -Tree -Index -ModeOverride @{ '.githooks/pre-push' = '100644' }
        $script:Repos[$path] = $repo
        $plan = Invoke-Plan $s
        $entry = @($plan.Files | Where-Object { $_.Path -eq '.githooks/pre-push' })[0]
        Assert-Equal 'Conflitante' $entry.Classification
        Assert-True ($entry.Reason -like '*100644*') $entry.Reason
    }
    It 'blob alterado no HEAD com checkout correto e detectado (conteudo falso)' {
        Use-GitMock
        $s = New-Scenario
        $repo = New-Coordination $s -WithFiles
        $repo.Tree = @($repo.Tree | ForEach-Object { if ($_ -like "*`tAGENTS.md") { '100644 blob ' + ('c' * 40) + "`tAGENTS.md" } else { $_ } })
        $plan = Invoke-Plan $s
        Assert-True ((@($plan.Files | Where-Object { $_.Path -eq 'AGENTS.md' })[0].Reason) -like '*HEAD: blob divergente*') 'HEAD'
    }
    It 'checkout divergente apesar de indice e HEAD corretos (AC29)' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, 'CLAUDE.md')) $Utf8.GetBytes("alterado`n")
        $plan = Invoke-Plan $s
        Assert-True ((@($plan.Files | Where-Object { $_.Path -eq 'CLAUDE.md' })[0].Reason) -like '*checkout: bytes divergentes*') 'checkout'
    }
    It 'entrada inesperada em .githooks e no HEAD e detectada' {
        Use-GitMock
        $s = New-Scenario
        $repo = New-Coordination $s -WithFiles
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, '.githooks', 'post-merge')) $Utf8.GetBytes("#!/bin/sh`n")
        $repo.Tree += ('100644 blob ' + ('d' * 40) + "`tdocs/agentes/extra.md")
        $plan = Invoke-Plan $s
        $paths = @($plan.Issues | Where-Object { $_.Code -eq 'MA_FILE_UNEXPECTED_ENTRY' } | ForEach-Object { $_.Path })
        Assert-True ($paths -contains '.githooks/post-merge') 'filesystem'
        Assert-True ($paths -contains 'docs/agentes/extra.md') 'HEAD'
    }
    It 'manutencao com arquivos gerados nao commitados e reconhecida (AC10)' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s -WithFiles
        [void](New-LinkedWorktree $s 'maintenance' $coordination)
        foreach ($file in $s.Rendered) { Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.maintenance, $file.Path.Replace('/', '\'))) $file.Bytes }
        $script:Repos[$s.Model.Worktrees.maintenance].Tree = @()
        $script:Repos[$s.Model.Worktrees.maintenance].Index = @()
        $plan = Invoke-Plan $s
        Assert-Equal 11 @($plan.Files | Where-Object { $_.Role -eq 'maintenance' -and $_.Classification -eq 'PreparadoNaoCommitado' }).Count
        Assert-Equal 0 @($plan.Actions | Where-Object { $_.Role -eq 'maintenance' }).Count
        Assert-NoIssue $plan 'MA_FILE_CONFLICT'
    }
    It 'arquivo governado nao commitado na coordenacao e conflito' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s)
        $agents = $s.Rendered | Where-Object { $_.Path -eq 'AGENTS.md' }
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, 'AGENTS.md')) $agents.Bytes
        $plan = Invoke-Plan $s
        Assert-Equal 'Conflitante' (@($plan.Files | Where-Object { $_.Path -eq 'AGENTS.md' })[0].Classification)
    }
    It 'quinto worktree e registro removivel bloqueiam (AC17)' {
        Use-GitMock
        $s = New-Scenario
        $repo = New-Coordination $s -WithFiles
        $repo.Worktrees += ('worktree C:/outro/lugar' + [char]0 + 'branch refs/heads/x')
        $repo.Worktrees += ('worktree ' + $s.Model.Worktrees.codex.Replace('\', '/') + [char]0 + 'branch refs/heads/feature/codex' + [char]0 + 'prunable gitdir file points to non-existent location')
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_WORKTREE_UNEXPECTED'
        Assert-HasIssue $plan 'MA_WORKTREE_PRUNABLE'
    }
    It 'branch configurada ocupada por outro worktree bloqueia' {
        Use-GitMock
        $s = New-Scenario
        $repo = New-Coordination $s -WithFiles
        $repo.Worktrees += ('worktree ' + $s.Model.Worktrees.codex.Replace('\', '/') + [char]0 + 'branch refs/heads/chore/manutencao')
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_BRANCH_OCCUPIED' 'maintenance'
    }
    It 'HEAD destacado, branch errada, origin divergente, raso e partial clone bloqueiam' {
        foreach ($case in @('detached', 'branch', 'origin', 'shallow', 'partial', 'unreadable')) {
            Use-GitMock
            $s = New-Scenario
            $repo = New-Coordination $s -WithFiles
            switch ($case) {
                'detached' { $repo.Symbolic = $null; $code = 'MA_ENV_DETACHED_HEAD' }
                'branch' { $repo.Symbolic = 'refs/heads/develop'; $code = 'MA_ENV_BRANCH_MISMATCH' }
                'origin' { $repo.Origin = @('https://example.invalid/outro.git'); $code = 'MA_REMOTE_ORIGIN_MISMATCH' }
                'shallow' { $repo.Shallow = 'true'; $code = 'MA_ENV_SHALLOW' }
                'partial' { $repo.Partial = $true; $code = 'MA_ENV_PARTIAL_CLONE' }
                'unreadable' { $repo.RevParseFails = $true; $code = 'MA_ENV_GIT_UNREADABLE' }
            }
            $plan = Invoke-Plan $s
            Assert-Equal 'Bloqueado' $plan.Status $case
            Assert-HasIssue $plan $code 'coordination'
        }
    }
    It 'worktree vinculado de outro repositorio comum bloqueia' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s -WithFiles
        $codex = New-LinkedWorktree $s 'codex' $coordination
        $codex.CommonDir = 'C:/outro/.git'
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_ENV_COMMON_DIR_MISMATCH' 'codex'
    }
    It 'diretorio existente nao vazio e sem repositorio bloqueia; vazio e aceito' {
        Use-GitMock
        $s = New-Scenario
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, 'notas.txt')) $Utf8.GetBytes('x')
        [void][IO.Directory]::CreateDirectory($s.Model.Worktrees.codex)
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_ENV_NOT_REPOSITORY' 'coordination'
        Assert-Equal 'VazioSemRepositorio' (@($plan.Environments | Where-Object { $_.Role -eq 'codex' })[0].State)
    }
    It 'destino de ambiente que e arquivo bloqueia' {
        Use-GitMock
        $s = New-Scenario
        Write-FixtureFile $s.Model.Worktrees.claude $Utf8.GetBytes('x')
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_ENV_NOT_DIRECTORY' 'claude'
    }
    It 'core.hooksPath e hooks ativos no diretorio padrao sao relatados como avisos' {
        Use-GitMock
        $s = New-Scenario
        $repo = New-Coordination $s -WithFiles
        $repo.HooksPath = @('global', 'file:C:/u/.gitconfig', 'C:/hooks')
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, '.git', 'hooks', 'pre-commit')) $Utf8.GetBytes("#!/bin/sh`n")
        Write-FixtureFile ([IO.Path]::Combine($s.Model.Worktrees.coordination, '.git', 'hooks', 'pre-push.sample')) $Utf8.GetBytes("#!/bin/sh`n")
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_HOOKS_PATH_PRESENT'
        $default = @($plan.Issues | Where-Object { $_.Code -eq 'MA_HOOKS_DEFAULT_ACTIVE' })
        Assert-Equal 1 $default.Count
        Assert-Equal 'pre-commit' $default[0].Detail
        Assert-Equal 'Sucesso' $plan.Status
    }
    It 'variavel de ambiente Git de redirecionamento torna a inspecao inconclusiva' {
        Use-GitMock
        $s = New-Scenario
        $previous = [Environment]::GetEnvironmentVariable('GIT_DIR')
        try {
            [Environment]::SetEnvironmentVariable('GIT_DIR', 'C:\falso')
            $plan = Invoke-Plan $s
        } finally { [Environment]::SetEnvironmentVariable('GIT_DIR', $previous) }
        Assert-HasIssue $plan 'MA_GIT_ENV_OVERRIDE'
        Assert-Equal 'Bloqueado' $plan.Status
    }
    It 'GIT_CONFIG_COUNT/KEY/VALUE (configuracao injetada por processo) bloqueiam o Plan' {
        Use-GitMock
        $s = New-Scenario
        $names = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')
        $previous = @{}; foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', '1')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_KEY_0', 'safe.directory')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_VALUE_0', '*')
            $plan = Invoke-Plan $s
        } finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) } }
        Assert-Equal 'Bloqueado' $plan.Status
        $details = @($plan.Issues | Where-Object { $_.Code -eq 'MA_GIT_ENV_OVERRIDE' } | ForEach-Object { $_.Detail } | Sort-Object)
        Assert-Equal 'GIT_CONFIG_COUNT,GIT_CONFIG_KEY_0,GIT_CONFIG_VALUE_0' ($details -join ',')
    }
    It 'branch rejeitada pelo Git bloqueia' {
        Use-GitMock
        $s = New-Scenario
        $script:RejectedBranches = @('feature/claude')
        $plan = Invoke-Plan $s
        Assert-HasIssue $plan 'MA_BRANCH_GIT_REJECTED' 'claude'
    }
    It 'BaseCommit abreviado e rejeitado' {
        Use-GitMock
        $s = New-Scenario
        $plan = Invoke-Plan $s 'abc123'
        Assert-HasIssue $plan 'MA_COMMIT_FORMAT_INVALID'
    }
    It 'Plan usa somente comandos Git de leitura' {
        Use-GitMock
        $s = New-Scenario
        $coordination = New-Coordination $s -WithFiles
        [void](New-LinkedWorktree $s 'maintenance' $coordination)
        [void](Invoke-Plan $s ('b' * 40))
        $allowed = '\A(?:--version|check-ref-format --branch \S+|rev-parse --path-format=absolute (?:--show-toplevel|--git-path hooks|--git-path index)\b.*|rev-parse --verify --quiet HEAD\^\{(?:commit|tree)\}|config -z (?:--get-regexp|--get-all|--show-scope --show-origin --get-all) .*|symbolic-ref --quiet HEAD|worktree list --porcelain -z|ls-tree -r -z --full-tree HEAD|ls-files -s -z|cat-file -e [0-9a-f]{40}\^\{commit\}|cat-file (?:blob|-e) [0-9a-f]{40}|cat-file --batch-check)\z'
        Assert-True ($script:GitCalls.Count -gt 10) 'chamadas registradas'
        foreach ($call in $script:GitCalls) { Assert-True ($call -cmatch $allowed) ('comando nao permitido: ' + $call) }
    }
    It 'relatorio identifica fase, resultado e ausencia de modificacao' {
        Use-GitMock
        $s = New-Scenario
        $lines = Format-MaPlanReport (Invoke-Plan $s)
        Assert-Equal 'Fase: Plan' $lines[0]
        Assert-Equal 'Resultado: Incompleto' $lines[1]
        Assert-Equal 'Nenhuma modificacao foi realizada.' $lines[$lines.Count - 1]
        Assert-True (-not (($lines -join "`n").Contains('senha'))) 'privacidade'
    }

    Write-Output 'Ponto de entrada'
    It 'Validate sem ambientes nao e conforme e CompleteWorktrees sem evidencias e bloqueada, ambas sem modificacao' {
        Use-RealGit
        $s = New-Scenario
        $before = Get-Snapshot $s.Root
        $host5 = (Get-Process -Id $PID).Path
        $script = [IO.Path]::Combine($PackageSource, 'scripts', 'Install-MultiAgentProject.ps1')
        # PrepareMaintenance, CompleteWorktrees e Validate tem suites proprias. O
        # ponto de entrada usa o pacote em execucao: Validate fica Incompleta (2)
        # com pacote integro ou Inconclusiva (3) sem integridade comprovada.
        foreach ($case in @(@('Validate', @(2, 3), 'Fase: Validate'), @('CompleteWorktrees', @(3), 'MA_INTEGRATION_REFERENCE_REQUIRED'))) {
            # No 5.1, stderr nativo redirecionado vira ErrorRecord; sob Stop seria excecao.
            $ErrorActionPreference = 'Continue'
            $output = & $host5 -NoProfile -NonInteractive -File $script -Config $s.Config -Phase $case[0] 2>&1
            $code = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            $text = $output | Out-String
            Assert-True ($code -in $case[1]) ($case[0] + ': saida ' + $code)
            Assert-True ($text.Contains($case[2])) $case[0]
            if ($case[0] -eq 'Validate') {
                $expected = 'Conformidade local: Incompleta'; if ($code -eq 3) { $expected = 'Conformidade local: Inconclusiva' }
                Assert-True ($text.Contains($expected)) ('Validate: ' + $expected)
            }
        }
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'Plan pelo ponto de entrada nao modifica a fixture e informa o resultado' -Requires Git, Job {
        Use-RealGit
        $s = New-Scenario
        $before = Get-Snapshot $s.Root
        $host5 = (Get-Process -Id $PID).Path
        $script = [IO.Path]::Combine($PackageSource, 'scripts', 'Install-MultiAgentProject.ps1')
        $output = & $host5 -NoProfile -NonInteractive -File $script -Config $s.Config -WhatIf 2>&1
        $code = $LASTEXITCODE
        $text = $output | Out-String
        Assert-True ($text.Contains('Fase: Plan')) $text
        Assert-True ($code -in @(2, 3)) ('saida ' + $code)
        Assert-True ($text.Contains('WhatIf: sem efeito adicional')) 'WhatIf'
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
} finally {
    Use-RealGit
    InModule { $script:MaNativeApi = $null; $script:MaNativeFaults = @{}; $script:MaNativeAssociationProbe = $null; $script:MaTerminationConfirmMilliseconds = 5000 }
    Restore-GitOverrideEnvironment $SavedGitEnvironment
    foreach ($root in $script:FixtureRoots) { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) } }
}

Write-Output ''
Write-Output ('Resultado: ' + $script:Passed + ' aprovados, ' + $script:Failed.Count + ' falhas, ' + $script:Blocked.Count + ' nao executados por pre-requisito')
foreach ($failure in $script:Failed) { Write-Output ('  - ' + $failure) }
foreach ($blocked in $script:Blocked) { Write-Output ('  - [PRE-REQ] ' + $blocked) }
if ($script:Failed.Count -gt 0) { exit 1 }
if ($script:Blocked.Count -gt 0) { exit 2 }
exit 0
