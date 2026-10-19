#Requires -Version 5.1
<#
Testes unitarios da fase Plan. Autocontidos: nao dependem de Pester (a versao 5
fixada ainda nao foi distribuida) e rodam igualmente no Windows PowerShell 5.1 e
no PowerShell 7. Fixtures sao descartaveis, criadas sob o TEMP do executor e
nunca apontam para o projeto atual. Repositorios sao simulados: nenhum
repositorio Git e criado, alterado ou consultado. O Git real e usado somente
fora de repositorios (--version, check-ref-format e rev-parse --sq-quote).

Uso: powershell -NoProfile -File tests/unit/Plan.Unit.Tests.ps1
Codigo de saida: 0 quando todos os casos passam; 1 caso contrario.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PackageSource = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
$ModulePath = [IO.Path]::Combine($PackageSource, 'scripts', 'MultiAgentTemplate.psm1')
$Module = Import-Module -Name $ModulePath -Force -PassThru -DisableNameChecking
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]
$script:GitCalls = New-Object System.Collections.Generic.List[string]
$script:Repos = @{}
$script:RejectedBranches = @()

# --- Mini-harness -----------------------------------------------------------------

function It {
    param([string]$Name, [scriptblock]$Body)
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
        Worktrees = @(); Tree = @(); Index = @(); HooksPath = @(); RevParseFails = $false
    }
}

function Add-GovernedEntries {
    param([hashtable]$Repo, [object[]]$Rendered, [switch]$Tree, [switch]$Index, [hashtable]$ModeOverride = @{})
    foreach ($file in $Rendered) {
        $mode = $file.GitMode; if ($ModeOverride.ContainsKey($file.Path)) { $mode = $ModeOverride[$file.Path] }
        $id = Get-BlobId $file.Bytes
        if ($Tree) { $Repo.Tree += ($mode + ' blob ' + $id + "`t" + $file.Path) }
        if ($Index) { $Repo.Index += ($mode + ' ' + $id + ' 0' + "`t" + $file.Path) }
    }
}

$GitMock = {
    param([string]$WorkingDirectory, [string[]]$Arguments)
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
    if ($Arguments[0] -ceq 'ls-tree') { return (& $ok ((@($repo.Tree | ForEach-Object { $_ + [char]0 })) -join '')) }
    if ($Arguments[0] -ceq 'ls-files') { return (& $ok ((@($repo.Index | ForEach-Object { $_ + [char]0 })) -join '')) }
    if ($Arguments[0] -ceq 'cat-file') { return (& $ok '') }
    return (& $fail 129)
}

function Use-GitMock { $script:GitCalls.Clear(); $script:Repos = @{}; $script:RejectedBranches = @(); InModule { param($m) $script:MaGitInvoker = $m } @(, $GitMock) }
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

# --- Casos ------------------------------------------------------------------------------

Write-Output ('PowerShell ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + ')')
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

    Write-Output 'Argumentos nativos'
    It 'converte argumentos pelas regras do Windows' {
        $cases = [ordered]@{ 'abc' = 'abc'; '' = '""'; 'a b' = '"a b"'; 'a"b' = '"a\"b"'; 'C:\x y\' = '"C:\x y\\"'; 'a\\"b' = '"a\\\\\"b"'; 'a\b' = 'a\b' }
        foreach ($key in $cases.Keys) { Assert-Equal $cases[$key] (InModule { param($v) ConvertTo-MaNativeArgument $v } @($key)) $key }
    }
    It 'Git real recebe argumentos adversariais literalmente (fora de repositorio)' {
        Use-RealGit
        InModule { $c = Get-Command git -CommandType Application | Select-Object -First 1; $script:MaGitPath = $c.Path }
        $values = @('a b', "it's", '$HOME', '&calc', 'x;y', '[z]', 'q"uote', 'trail\', '', '%PATH%', '`whoami`', '$(id)')
        $result = InModule { param($wd, $v) Invoke-MaGit $wd (@('rev-parse', '--sq-quote') + $v) } @($base.Root, $values)
        $expected = ' ' + ((@($values | ForEach-Object { "'" + $_.Replace("'", "'\''") + "'" })) -join ' ')
        Assert-Equal 0 $result.ExitCode
        Assert-Equal $expected ($result.StdOut.TrimEnd("`n"))
    }
    It 'Git real confirma branches por check-ref-format' {
        Use-RealGit
        $good = [ordered]@{ coordination = 'main'; codex = 'feature/codex'; claude = 'feature/claude'; maintenance = 'chore/manutencao' }
        Assert-Equal 0 (InModule { param($b, $wd) (Test-MaBranchesWithGit $b $wd).Count } @($good, $base.Root))
        $bad = [ordered]@{ coordination = 'main'; codex = 'a..b'; claude = 'x.lock'; maintenance = 'chore/manutencao' }
        Assert-Equal 2 (InModule { param($b, $wd) (Test-MaBranchesWithGit $b $wd).Count } @($bad, $base.Root))
    }

    Write-Output 'Processos nativos com saida grande e prazo'
    $hostExe = (Get-Process -Id $PID).Path
    It 'drena 4 MiB em stdout e 4 MiB em stderr intercalados, com codigo de saida e stderr capturados' {
        $command = '$o = [string]::new([char]111, 65536); $e = [string]::new([char]101, 65536); for ($i = 0; $i -lt 64; $i++) { [Console]::Out.Write($o); [Console]::Error.Write($e) }; exit 3'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = InModule { param($exe, $cmd, $wd) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', $cmd) -WorkingDirectory $wd -TimeoutMilliseconds 60000 } @($hostExe, $command, $base.Root)
        Assert-Equal 3 $result.ExitCode
        Assert-Equal (64 * 65536) $result.StdOut.Length 'stdout'
        Assert-Equal (64 * 65536) $result.StdErr.Length 'stderr'
        Assert-True ($result.StdOut.Trim([char]111).Length -eq 0 -and $result.StdErr.Trim([char]101).Length -eq 0) 'conteudo'
        Assert-True ($clock.ElapsedMilliseconds -lt 60000) 'prazo'
    }
    It 'processo que nao termina e encerrado no prazo' {
        $marker = 'ma-timeout-' + [Guid]::NewGuid().ToString('N')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { InModule { param($exe, $m, $wd) Invoke-MaNativeProcess -FilePath $exe -Arguments @('-NoProfile', '-NonInteractive', '-Command', ('Start-Sleep -Seconds 60 # ' + $m)) -WorkingDirectory $wd -TimeoutMilliseconds 1500 } @($hostExe, $marker, $base.Root) } 'MA_NATIVE_TIMEOUT'
        Assert-True ($clock.ElapsedMilliseconds -lt 15000) ('demorou ' + $clock.ElapsedMilliseconds + ' ms')
        Start-Sleep -Milliseconds 500
        $alive = @(Get-CimInstance Win32_Process -Filter "Name like 'powershell%' or Name like 'pwsh%'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($marker) })
        Assert-Equal 0 $alive.Count 'processo filho ainda ativo apos o timeout'
    }
    $shell = InModule { $c = Get-Command git -CommandType Application | Select-Object -First 1; Find-MaShell $c.Path }
    # Duracao unica por caso: identifica o sleep.exe descendente na linha de comando.
    function New-SleepMarker { return ('40.' + (Get-Random -Minimum 100000 -Maximum 999999)) }
    function Get-AliveByMarker {
        param([string]$Marker)
        Start-Sleep -Milliseconds 500
        return @(Get-CimInstance Win32_Process -Property ProcessId, CommandLine | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Marker) })
    }
    function Stop-ByMarker { param([string]$Marker) foreach ($p in (Get-AliveByMarker $Marker)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } }
    It 'API de Job Object disponivel sem Add-Type nem arquivos' {
        Assert-True ((InModule { Get-MaJobApi }) -ne $false) 'Job Object indisponivel'
    }
    It 'descendente orfao (exec do MSYS) com pipes abertos: retorno no prazo e nenhum descendente vivo' {
        Assert-True ([bool]$shell) 'sh do Git for Windows nao localizado'
        $marker = New-SleepMarker
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Assert-Throws { InModule { param($sh, $mk, $wd) Invoke-MaNativeProcess -FilePath $sh -Arguments @('-c', ('sleep ' + $mk + ' & echo pronto')) -WorkingDirectory $wd -TimeoutMilliseconds 2000 } @($shell, $marker, $base.Root) } 'MA_NATIVE_TIMEOUT'
            Assert-True ($clock.ElapsedMilliseconds -lt 6000) ('demorou ' + $clock.ElapsedMilliseconds + ' ms; esperou o descendente')
            Assert-Equal 0 @(Get-AliveByMarker $marker).Count 'descendente sobreviveu ao timeout'
        } finally { Stop-ByMarker $marker }
    }
    It 'descendentes em subshell com pai intermediario encerrado tambem sao encerrados' {
        $marker = New-SleepMarker
        try {
            Assert-Throws { InModule { param($sh, $mk, $wd) Invoke-MaNativeProcess -FilePath $sh -Arguments @('-c', ('(sleep ' + $mk + '; true) & (sh -c "sleep ' + $mk + '" &) ; echo pronto')) -WorkingDirectory $wd -TimeoutMilliseconds 2000 } @($shell, $marker, $base.Root) } 'MA_NATIVE_TIMEOUT'
            Assert-Equal 0 @(Get-AliveByMarker $marker).Count 'descendente sobreviveu ao timeout'
        } finally { Stop-ByMarker $marker }
    }
    It 'processo principal ainda ativo no timeout: arvore inteira encerrada' {
        $marker = New-SleepMarker
        try {
            Assert-Throws { InModule { param($sh, $mk, $wd) Invoke-MaNativeProcess -FilePath $sh -Arguments @('-c', ('sleep ' + $mk + ' & sleep ' + $mk)) -WorkingDirectory $wd -TimeoutMilliseconds 1500 } @($shell, $marker, $base.Root) } 'MA_NATIVE_TIMEOUT'
            Assert-Equal 0 @(Get-AliveByMarker $marker).Count 'processos sobreviveram ao timeout'
        } finally { Stop-ByMarker $marker }
    }
    It 'chamada concluida nao encerra descendente que liberou os pipes' {
        $marker = New-SleepMarker
        try {
            $result = InModule { param($sh, $mk, $wd) Invoke-MaNativeProcess -FilePath $sh -Arguments @('-c', ('sleep ' + $mk + ' </dev/null >/dev/null 2>&1 & echo pronto')) -WorkingDirectory $wd -TimeoutMilliseconds 10000 } @($shell, $marker, $base.Root)
            Assert-Equal 0 $result.ExitCode
            Assert-Equal "pronto`n" $result.StdOut
            Assert-Equal 1 @(Get-AliveByMarker $marker).Count 'fechar o job nao deve encerrar processos'
        } finally { Stop-ByMarker $marker }
    }
    It 'saida grande dentro do prazo segue funcionando apos processo curto com descendente encerrado' {
        $shell = InModule { $c = Get-Command git -CommandType Application | Select-Object -First 1; Find-MaShell $c.Path }
        $result = InModule { param($sh, $wd) Invoke-MaNativeProcess -FilePath $sh -Arguments @('-c', '(sleep 1; echo filho) & echo pai; wait; echo erro >&2; exit 5') -WorkingDirectory $wd -TimeoutMilliseconds 20000 } @($shell, $base.Root)
        Assert-Equal 5 $result.ExitCode
        Assert-Equal "pai`nfilho`n" $result.StdOut
        Assert-Equal "erro`n" $result.StdErr
    }
    It 'timeout do Git durante o Plan e falha operacional' {
        Use-GitMock
        $s = New-Scenario
        [void](New-Coordination $s -WithFiles)
        $previous = $GitMock
        InModule { param($m) $script:MaGitInvoker = { param($wd, $a) if ($a[0] -ceq 'worktree') { throw 'MA_NATIVE_TIMEOUT' }; & $m $wd $a }.GetNewClosure() } @(, $previous)
        $plan = Invoke-Plan $s
        Assert-Equal 'Falha' $plan.Status
        Assert-Equal 'MA_NATIVE_TIMEOUT' @($plan.Issues | Where-Object { $_.Severity -eq 'Falha' })[0].Code
        Assert-Equal 4 (Get-MaExitCode $plan.Status)
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
        $id = Get-BlobId $readme
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
        $allowed = '\A(?:--version|check-ref-format --branch \S+|rev-parse --path-format=absolute (?:--show-toplevel|--git-path hooks)\b.*|rev-parse --verify --quiet HEAD\^\{commit\}|config -z (?:--get-regexp|--get-all|--show-scope --show-origin --get-all) .*|symbolic-ref --quiet HEAD|worktree list --porcelain -z|ls-tree -r -z --full-tree HEAD -- .*|ls-files -s -z -- .*|cat-file -e [0-9a-f]{40}\^\{commit\})\z'
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
    It 'fases nao implementadas sao recusadas sem modificacao' {
        Use-RealGit
        $s = New-Scenario
        $before = Get-Snapshot $s.Root
        $host5 = (Get-Process -Id $PID).Path
        $script = [IO.Path]::Combine($PackageSource, 'scripts', 'Install-MultiAgentProject.ps1')
        foreach ($phase in @('PrepareMaintenance', 'CompleteWorktrees', 'Validate')) {
            # No 5.1, stderr nativo redirecionado vira ErrorRecord; sob Stop seria excecao.
            $ErrorActionPreference = 'Continue'
            $output = & $host5 -NoProfile -NonInteractive -File $script -Config $s.Config -Phase $phase 2>&1
            $code = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            Assert-Equal 4 $code $phase
            Assert-True ((($output | Out-String)).Contains('MA_PHASE_NOT_IMPLEMENTED')) $phase
        }
        Assert-SameSnapshot $before (Get-Snapshot $s.Root)
    }
    It 'Plan pelo ponto de entrada nao modifica a fixture e informa o resultado' {
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
    foreach ($root in $script:FixtureRoots) { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) } }
}

Write-Output ''
Write-Output ('Resultado: ' + $script:Passed + ' aprovados, ' + $script:Failed.Count + ' falhas')
foreach ($failure in $script:Failed) { Write-Output ('  - ' + $failure) }
if ($script:Failed.Count -gt 0) { exit 1 }
exit 0
