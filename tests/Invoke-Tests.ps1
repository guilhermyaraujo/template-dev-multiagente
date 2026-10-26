#Requires -Version 5.1
<#
.SYNOPSIS
Executor central das suites do instalador multiagente.

.DESCRIPTION
Executa as suites de tests/unit e tests/integration em serie, cada uma em um
processo PowerShell proprio, contido em Job Object e com prazo.

Completude: antes de executar, os casos esperados de cada suite sao obtidos da
AST do arquivo (Get-SuiteCatalog), sem executa-lo. Cada linha de caso emitida
([ok], [FALHA], [PRE-REQ]) e identificada pelo nome contra esse catalogo. A suite
so e aprovada se cada caso esperado for contabilizado exatamente uma vez, sem
caso desconhecido, e se resumo, linhas [PRE-REQ] e codigo de saida concordarem.
Execucao truncada, caso ausente, repetido ou nao catalogado deixa a suite
Inconclusiva, mesmo com codigo de saida zero e resumo coerente.

Processos: cada processo filho nasce suspenso dentro de um job proprio, sem nome,
com handle nao herdavel, KILL_ON_JOB_CLOSE e sem breakaway, pelo executor nativo
do modulo do pacote (scripts/MultiAgentTemplate.psm1; sem WMI, Add-Type ou cmd).
Os descendentes herdam o job. O job inteiro e encerrado (TerminateJobObject) e o
termino conferido pela contagem do job e pelo sinal de cada membro, antes de
devolver, em quatro situacoes distintas no registro (StopReason): prazo;
descendente ativo depois do fim da suite; interrupcao controlada (excecao no
executor); e parada do pipeline (Ctrl+C), atendida entre as fatias de 250 ms da
espera da suite (ate cerca de 30 s se ocorrer na drenagem da saida). Na parada do
pipeline o executor nao emite resultado geral: informa no erro padrao os
encerramentos confirmados e nao confirmados. Termino abrupto do proprio executor
(processo encerrado, console fechado, desligamento) nao executa nenhum finally: o
fechamento do ultimo handle do job aciona KILL_ON_JOB_CLOSE, que encerra os
membros, mas o executor nao confirma nem relata esse encerramento. Em todos os
casos de encerramento forcado, o finally das suites nao executa e fixtures podem
restar sob o TEMP. Somente membros do job sao encerrados: processos preexistentes
ou de outra origem nunca entram nele. Encerramento nao conferido e falha e nunca
e relatado como limpeza concluida. Limite: processos criados fora da arvore (WMI,
Agendador, servicos, COM fora do processo) nao herdam o job e nao sao observados
nem encerrados.

Motores (-Engine): Harness (auxiliar, somente quando pedido) executa cada suite
pelo mini-harness autocontido dela e nao demonstra a secao 8 da especificacao.
Pester (padrao) executa cada suite nativamente pelo Pester 5, com a versao exata fixada em
tests/PesterRequirement.psd1: o adaptador tests/pester/NativeSuite.Tests.ps1
monta, pelo plano obtido da AST da suite (Get-SuitePlan, sem alterar o arquivo),
um It do Pester por caso do catalogo, que executa o bloco do proprio caso; o
Pester executa e avalia cada caso no processo Pester, contido em Job Object. Sem
versao fixada ou sem essa versao instalada no PowerShell, o motor Pester fica
pendente; nada e instalado ou importado de outra versao.

Por padrao as suites rodam no Windows PowerShell 5.1 (System32) e no
PowerShell 7 (pwsh no PATH). Um PowerShell ausente fica pendente e nunca e
contado como aprovado. -PowerShellPath substitui a lista.

Concorrencia: uma instancia do executor por sessao (mutex). Plan.Unit observa
processos sleep.exe novos, sem WMI; nao execute outros sleep.exe (por exemplo,
lacos de espera no Git Bash) nem outras suites durante a execucao, ou os casos
de encerramento de arvore podem falhar por interferencia externa.

Isolamento: cada suite cria e remove as proprias fixtures sob o TEMP e nunca
aponta para o projeto atual. O executor usa como diretorio de trabalho um
diretorio descartavel proprio, conferido vazio depois de cada suite, e compara
o conteudo da raiz executada (exceto .git) antes e depois de tudo. Uma
alteracao inesperada e falha.

-Package monta uma copia isolada do pacote somente com os arquivos do
package.manifest.json antes de iniciar qualquer processo, confere sua integridade
com o proprio modulo da copia (em processo separado), exercita o ponto de entrada
em modos sem modificacao (Plan, Validate e PrepareMaintenance -WhatIf) sobre um
workspace descartavel e executa as suites a partir da copia, sem depender do
worktree de desenvolvimento; a contencao dos processos tambem usa o modulo da copia.

Nenhum commit, push, fetch ou acesso a repositorios reais e feito pelo executor.
Nenhum relatorio e gravado em disco; redirecione a saida se precisar guarda-la.
Nao altera a politica de execucao.

.EXAMPLE
powershell -NoProfile -File tests/Invoke-Tests.ps1

.EXAMPLE
powershell -NoProfile -File tests/Invoke-Tests.ps1 -Package -Group Unit

.EXAMPLE
powershell -NoProfile -File tests/Invoke-Tests.ps1 -Engine Harness

Codigos de saida: 0 todas as suites aprovadas em todos os PowerShells;
1 alguma falha (caso, suite inconclusiva, prazo, processos, pacote ou isolamento);
2 nenhuma falha, mas algo pendente (PowerShell, Pester 5 ou pre-requisito de suite);
3 execucao recusada (outra instancia em andamento ou parametro invalido).
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Unit', 'Integration')][string]$Group = 'All',
    [string[]]$Suite = @(),
    [string[]]$PowerShellPath = @(),
    [ValidateSet('Harness', 'Pester')][string]$Engine = 'Pester',
    [switch]$Package,
    [switch]$KeepPackage,
    [ValidateRange(1, 1440)][int]$TimeoutMinutes = 60
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$SourceRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$SuiteNames = @(
    'InvokeTests.Unit', 'Plan.Unit', 'PrepareMaintenance.Unit', 'CompleteWorktrees.Unit', 'Validate.Unit',
    'Plan.Integration', 'PrepareMaintenance.Integration', 'CompleteWorktrees.Integration', 'Validate.Integration'
)
$script:Pending = New-Object System.Collections.Generic.List[string]
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:OwnedRoots = New-Object System.Collections.Generic.List[string]
# Registro de cada processo iniciado pelo executor, atualizado mesmo se a chamada lancar.
$script:ProcessJournal = New-Object System.Collections.Generic.List[object]
$script:ContainmentModule = $null
$script:ContainmentRoot = $SourceRoot

# Criterios de aceitacao (secao 9 da especificacao) e as suites cujos casos os
# exercitam, pelos nomes dos casos. Hosts: os dois PowerShells sao exigidos.
# Externo: depende de revisao ou decisao fora do executor.
$Criteria = @(
    @{ Id = 'AC01'; Hosts = $true; Suites = $SuiteNames; Text = 'Mesma suite aprovada nos dois PowerShells' }
    @{ Id = 'AC02'; Suites = @('Plan.Unit', 'CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'Configuracao minima produz quatro ambientes' }
    @{ Id = 'AC03'; Suites = @('Plan.Unit', 'Plan.Integration', 'CompleteWorktrees.Integration'); Text = 'Mesmo repositorio comum nos quatro ambientes' }
    @{ Id = 'AC04'; Suites = @('Plan.Unit', 'Plan.Integration'); Text = 'Diretorios e branches consistentes nos documentos' }
    @{ Id = 'AC05'; Suites = @('Plan.Unit'); Text = 'Sem identificador de origem; dados como tokens nao reinterpretados' }
    @{ Id = 'AC06'; Suites = @('Plan.Unit'); Text = 'Branches alternativas validadas, sem caracteres proibidos de shell' }
    @{ Id = 'AC07'; Suites = @('Plan.Integration', 'PrepareMaintenance.Integration', 'CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'Plan, Validate e WhatIf preservam o estado' }
    @{ Id = 'AC08'; Suites = @('Plan.Unit', 'PrepareMaintenance.Integration', 'CompleteWorktrees.Integration'); Text = 'Nenhum commit, push, PR, merge, rebase ou deploy pelo instalador' }
    @{ Id = 'AC09'; Suites = @('Plan.Integration', 'PrepareMaintenance.Integration'); Text = 'Destino diferente nunca substituido, anexado ou mesclado' }
    @{ Id = 'AC10'; Suites = @('Plan.Integration', 'PrepareMaintenance.Integration'); Text = 'Preparacao repetida reconhece arquivos nao commitados' }
    @{ Id = 'AC11'; Suites = @('PrepareMaintenance.Integration', 'Validate.Integration'); Text = 'Instalacao concluida repetida sem alteracao' }
    @{ Id = 'AC12'; Suites = @('CompleteWorktrees.Integration'); Text = 'Falha parcial preserva trabalho e separa ambientes de hooks' }
    @{ Id = 'AC13'; Suites = @('CompleteWorktrees.Integration'); Text = 'Conclusao sem sincronizar nem reposicionar; squash por conteudo' }
    @{ Id = 'AC14'; Suites = @('CompleteWorktrees.Integration'); Text = 'Hooks bloqueiam pelo destino, exclusao e lote misto (entradas simuladas)' }
    @{ Id = 'AC15'; Suites = @('Plan.Integration', 'CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'Bytes, tipos e modos nos objetos e checkouts' }
    @{ Id = 'AC16'; Suites = @('CompleteWorktrees.Unit', 'CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'Configuracao efetiva conflitante detectada sem substituicao' }
    @{ Id = 'AC17'; Suites = @('Plan.Integration', 'CompleteWorktrees.Unit', 'CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'Nenhum alcance adicional aceito' }
    @{ Id = 'AC18'; Suites = @('Plan.Unit', 'PrepareMaintenance.Integration', 'CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'Caminhos com metacaracteres chegam literais' }
    @{ Id = 'AC19'; Suites = @('Plan.Unit', 'PrepareMaintenance.Unit', 'CompleteWorktrees.Unit'); Text = 'Sem exposicao de segredos, execucao ou expansao' }
    @{ Id = 'AC20'; Suites = @('CompleteWorktrees.Unit', 'Validate.Integration'); Text = 'Evidencias identificadas; comparacao por caminho' }
    @{ Id = 'AC21'; External = $true; Text = 'Revisao independente registra o SHA completo avaliado' }
    @{ Id = 'AC22'; External = $true; Text = 'Ausencia de defeitos criticos ou altos para publicacao' }
    @{ Id = 'AC23'; Suites = @('Plan.Unit', 'Plan.Integration', 'PrepareMaintenance.Integration'); Text = 'Repositorio sem commit bloqueia sem commit inicial' }
    @{ Id = 'AC24'; Suites = @('Plan.Integration', 'PrepareMaintenance.Integration'); Text = 'Conflito bloqueia a geracao; sem resolucao automatica' }
    @{ Id = 'AC25'; Suites = @('CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'core.hooksPath conferido nos quatro worktrees' }
    @{ Id = 'AC26'; Suites = @('CompleteWorktrees.Unit', 'CompleteWorktrees.Integration'); Text = 'Hook padrao, override, include ou quinto worktree bloqueiam' }
    @{ Id = 'AC27'; Suites = @('CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'M e I sem ancestralidade aceitos por conteudo' }
    @{ Id = 'AC28'; Suites = @('Plan.Integration', 'CompleteWorktrees.Unit', 'CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'Manifesto isolado nunca basta' }
    @{ Id = 'AC29'; Suites = @('Plan.Integration', 'CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'Indice e checkout conferidos alem de status e flags' }
    @{ Id = 'AC30'; Suites = @('Plan.Unit'); Text = 'Nome com Markdown, HTML e tokens permanece literal' }
    @{ Id = 'AC31'; Suites = @('Plan.Unit'); Text = 'Hooks somente com literais permitidos' }
    @{ Id = 'AC32'; Hosts = $true; Suites = @('Plan.Unit', 'Plan.Integration', 'PrepareMaintenance.Integration', 'CompleteWorktrees.Integration', 'Validate.Integration'); Text = 'Corpus adversarial nos dois PowerShells' }
)

# --- Processos ---------------------------------------------------------------------

# Modulo do pacote que fornece o executor nativo contido em Job Object. Carregado
# uma unica vez, da raiz deste executor ou, com -Package, da copia isolada.
function Get-ContainmentModule {
    if ($null -eq $script:ContainmentModule) {
        $script:ContainmentModule = Import-Module -Name ([IO.Path]::Combine($script:ContainmentRoot, 'scripts', 'MultiAgentTemplate.psm1')) -Force -PassThru -DisableNameChecking
    }
    return $script:ContainmentModule
}

# Executado no escopo do modulo. $Entry (no registro de processos) e atualizado
# a cada etapa, de modo que o estado do encerramento fica disponivel mesmo se a
# chamada lancar. Termination: NaoIniciado (nenhum processo executou),
# JobVazio (fim normal, job conferido vazio), Confirmado (job encerrado e termino
# conferido) ou NaoConfirmado (o termino nao pode ser afirmado).
$script:ContainedRun = {
    param($Entry, [string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [hashtable]$Environment, [int]$TimeoutMilliseconds,
        [int]$DrainMilliseconds, [int]$SettleMilliseconds, [int]$ConfirmMilliseconds, $Interrupt)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $encoding = [Console]::OutputEncoding
    $job = [IntPtr]::Zero
    $state = $null
    $streams = New-Object System.Collections.Generic.List[System.IDisposable]
    $tasks = $null
    $stopReason = $null
    $settled = $false
    try {
        # Contencao indisponivel (API ou limite do job): nenhum processo e criado.
        try { $job = New-MaNativeJob; $api = Get-MaNativeApi }
        catch { $Entry.StartError = $_.Exception.Message; $settled = $true; return }
        try {
            $state = Start-MaNativeSuspendedProcess -Job $job -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -Environment $Environment
        } catch {
            # O modulo encerra e confere o processo ainda suspenso; sem confirmacao, lanca codigo proprio.
            $Entry.StartError = $_.Exception.Message
            if ($_.Exception.Message -cmatch '\AMA_NATIVE_(?:TERMINATION_UNCONFIRMED|CONTAINMENT_FAILED_UNTERMINATED)\z') { $Entry.Termination = 'NaoConfirmado'; $Entry.TerminationDetail = $_.Exception.Message }
            $settled = $true
            return
        }
        $Entry.ProcessId = $state.ProcessId
        $Entry.Contained = $true
        $stdin = ConvertTo-MaNativeStream $state 'StdInWrite' ([IO.FileAccess]::Write) 1; $streams.Add($stdin)
        $stdout = ConvertTo-MaNativeStream $state 'StdOutRead' ([IO.FileAccess]::Read); $streams.Add($stdout)
        $stderr = ConvertTo-MaNativeStream $state 'StdErrRead' ([IO.FileAccess]::Read); $streams.Add($stderr)
        $tasks = @((New-Object IO.StreamReader($stdout, $encoding, $true, 4096)).ReadToEndAsync(), (New-Object IO.StreamReader($stderr, $encoding, $true, 4096)).ReadToEndAsync())
        Resume-MaNativeProcess $state
        $stdin.Dispose()
        if ($null -ne $Interrupt) { & $Interrupt $Entry }
        # Espera em fatias: entre elas o PowerShell atende a parada do pipeline
        # (Ctrl+C), que uma unica espera nativa adiaria ate o fim da suite ou o prazo.
        $wait = $script:MaNativeConstants.WaitTimeout
        while ($wait -eq $script:MaNativeConstants.WaitTimeout -and $clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            $wait = $api::WaitForSingleObject($state.ProcessHandle, [uint32][Math]::Min(250, [Math]::Max(0, $TimeoutMilliseconds - $clock.ElapsedMilliseconds)))
        }
        if ($wait -eq $script:MaNativeConstants.WaitTimeout) { $Entry.TimedOut = $true; $stopReason = 'prazo' }
        elseif ($wait -ne $script:MaNativeConstants.WaitObject0) { $stopReason = 'espera do processo recusada' }
        else {
            $exitCell = New-MaNativeZeroMemory 4
            try { if ($api::GetExitCodeProcess($state.ProcessHandle, $exitCell)) { $Entry.ExitCode = [Runtime.InteropServices.Marshal]::ReadInt32($exitCell, 0) } }
            finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($exitCell) }
            # Descendente que herdou os pipes os mantem abertos depois da saida do processo.
            $drain = [int][Math]::Max(0, [Math]::Min($DrainMilliseconds, $TimeoutMilliseconds - $clock.ElapsedMilliseconds))
            if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks, $drain)) { $Entry.Persisted = $true; $stopReason = 'saida retida por descendente' }
            else {
                $wait = Wait-MaNativeJobEmpty $job $SettleMilliseconds
                if ($wait.Status -eq 'Empty') { $Entry.Termination = 'JobVazio'; $settled = $true }
                elseif ($wait.Status -eq 'Active') { $Entry.Persisted = $true; $stopReason = 'descendente ativo' }
                else { $stopReason = 'consulta do job recusada' }
            }
        }
    } catch {
        # Excecao no executor, inclusive o ponto de interrupcao controlada dos testes.
        # A parada do pipeline (Ctrl+C) nao passa por catch: somente pelo finally.
        $Entry.Interrupted = $true
        $Entry.InterruptDetail = $_.Exception.Message
        if (-not $stopReason) { $stopReason = 'interrupcao controlada' }
        throw
    } finally {
        # Prazo, descendente ativo, interrupcao controlada, parada do pipeline ou
        # falha: encerra o job inteiro e confere o termino antes de devolver.
        if (-not $settled -and $job -ne [IntPtr]::Zero) {
            if (-not $stopReason) { $stopReason = 'parada do pipeline (Ctrl+C)'; $Entry.PipelineStopped = $true }
            $Entry.StopReason = $stopReason
            try { Stop-MaNativeJob $job $ConfirmMilliseconds $null; $Entry.Termination = 'Confirmado' }
            catch {
                # Termino confirmado com falha de limpeza de handles: confirmado, com o detalhe.
                if ($_.Exception.Message -ceq 'MA_NATIVE_CLEANUP_FAILED') { $Entry.Termination = 'Confirmado'; $Entry.TerminationDetail = 'MA_NATIVE_CLEANUP_FAILED' }
                else {
                    $Entry.Termination = 'NaoConfirmado'
                    $stage = ''; if ($_.Exception.Data.Contains('Stage')) { $stage = [string]$_.Exception.Data['Stage'] }
                    $Entry.TerminationDetail = ($_.Exception.Message + ' ' + $stage).Trim()
                }
            }
        }
        if ($job -ne [IntPtr]::Zero) {
            $accounting = Get-MaNativeJobAccounting $job
            if ($null -ne $accounting) { $Entry.ProcessesInJob = $accounting.Total; $Entry.ActiveAtEnd = $accounting.Active }
        }
        # Com os membros encerrados, os pipes fecham e a saida parcial fica disponivel.
        if ($null -ne $tasks) {
            $Entry.StreamsComplete = $false
            try { $Entry.StreamsComplete = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks, 30000) } catch { }
            if ($tasks[0].Status -eq 'RanToCompletion') { $Entry.StdOut = $tasks[0].Result }
            if ($tasks[1].Status -eq 'RanToCompletion') { $Entry.StdErr = $tasks[1].Result }
        }
        foreach ($stream in $streams) { try { $stream.Dispose() } catch { $Entry.CleanupFailures += 'Stream' } }
        try { Close-MaNativeProcess $state } catch { $Entry.CleanupFailures += 'Process' }
        # Garantia final: KILL_ON_JOB_CLOSE encerra qualquer membro restante; sem confirmacao.
        $jobHandle = $job; $job = [IntPtr]::Zero
        if ($null -ne (Close-MaNativeHandle $jobHandle 'Job')) { $Entry.CleanupFailures += 'Job' }
        $Entry.Elapsed = $clock.Elapsed
    }
}

# Processo filho contido em Job Object; devolve o registro da execucao. Nao lanca
# por falha do processo: StartError, TimedOut, Persisted e Termination descrevem o
# ocorrido. Lanca somente se a contencao estiver indisponivel ou se $Interrupt
# (ponto de interrupcao controlada, usado pelos testes) lancar.
function Invoke-ChildProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutMilliseconds, [hashtable]$Environment = @{},
        [int]$DrainMilliseconds = 30000, [int]$SettleMilliseconds = 5000, [int]$ConfirmMilliseconds = 30000, [scriptblock]$Interrupt = $null)
    $entry = [pscustomobject]@{
        FilePath = $FilePath; ProcessId = 0; Contained = $false; StartError = ''; ExitCode = $null; StdOut = ''; StdErr = ''
        TimedOut = $false; Persisted = $false; Interrupted = $false; InterruptDetail = ''; PipelineStopped = $false; StopReason = ''; StreamsComplete = $false
        Termination = 'NaoIniciado'; TerminationDetail = ''; ProcessesInJob = $null; ActiveAtEnd = $null; CleanupFailures = @(); Elapsed = [TimeSpan]::Zero
    }
    $script:ProcessJournal.Add($entry)
    $module = Get-ContainmentModule
    if (-not [IO.File]::Exists($FilePath)) { $entry.StartError = 'executavel ausente'; return $entry }
    & $module $script:ContainedRun $entry $FilePath $Arguments $WorkingDirectory $Environment $TimeoutMilliseconds $DrainMilliseconds $SettleMilliseconds $ConfirmMilliseconds $Interrupt
    return $entry
}

# Resumo dos processos iniciados: execucoes, processos na arvore e encerramentos.
function Get-ProcessJournalSummary {
    param($Journal)
    # Enumeracao explicita: @() sobre List[object] lanca ArgumentException no 5.1.
    $items = @(foreach ($item in $Journal) { $item })
    $stopped = @($items | Where-Object { $_.StopReason })
    $unconfirmed = @($items | Where-Object { $_.Termination -eq 'NaoConfirmado' })
    $processes = [int](($items | Where-Object { $null -ne $_.ProcessesInJob } | ForEach-Object { $_.ProcessesInJob } | Measure-Object -Sum).Sum)
    $reasons = @($stopped | Group-Object -Property StopReason | Sort-Object Name | ForEach-Object { $_.Name + ' ' + $_.Count }) -join ', '
    return [pscustomobject]@{ Runs = $items.Count; Processes = $processes; Stopped = $stopped.Count; Reasons = $reasons; Unconfirmed = $unconfirmed }
}

# --- Ambiente ----------------------------------------------------------------------

function Get-HostCandidates {
    if ($PowerShellPath.Count -gt 0) { return @($PowerShellPath | ForEach-Object { [pscustomobject]@{ Label = $_; Path = $_ } }) }
    $desktop = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    $core = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $corePath = $null; if ($null -ne $core) { $corePath = $core.Path }
    return @(
        [pscustomobject]@{ Label = 'Windows PowerShell 5.1'; Path = $desktop }
        [pscustomobject]@{ Label = 'PowerShell 7'; Path = $corePath }
    )
}

function Get-HostIdentity {
    param([string]$Path, [string]$WorkingDirectory)
    $probe = @'
$v = $PSVersionTable
$edition = 'Desktop'; if ($v.ContainsKey('PSEdition')) { $edition = [string]$v.PSEdition }
$pester = @(Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | ForEach-Object { $_.Version.ToString() } | Select-Object -Unique) -join ','
[Console]::Out.WriteLine('EDITION=' + $edition)
[Console]::Out.WriteLine('VERSION=' + $v.PSVersion.ToString())
[Console]::Out.WriteLine('ARCH=' + $(if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }))
[Console]::Out.WriteLine('POLICY=' + (Get-ExecutionPolicy).ToString())
[Console]::Out.WriteLine('PESTER=' + $pester)
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    $result = Invoke-ChildProcess -FilePath $Path -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WorkingDirectory $WorkingDirectory -TimeoutMilliseconds 120000
    if ($result.ExitCode -ne 0 -or $result.TimedOut -or $result.Termination -eq 'NaoConfirmado') { throw ('identificacao do PowerShell falhou: ' + $Path) }
    $values = @{}
    foreach ($line in ($result.StdOut -split "`r?`n")) { if ($line -match '\A([A-Z]+)=(.*)\z') { $values[$Matches[1]] = $Matches[2] } }
    foreach ($key in @('EDITION', 'VERSION', 'ARCH', 'POLICY', 'PESTER')) { if (-not $values.ContainsKey($key)) { throw ('identificacao do PowerShell incompleta: ' + $Path) } }
    $versions = @($values['PESTER'] -split ',' | Where-Object { $_ })
    return [pscustomobject]@{ Edition = $values['EDITION']; Version = $values['VERSION']; Architecture = $values['ARCH']; Policy = $values['POLICY']; PesterVersions = $versions }
}

function Get-GitIdentity {
    param([string]$WorkingDirectory)
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { return 'ausente no PATH' }
    $result = Invoke-ChildProcess -FilePath $git.Path -Arguments @('--version') -WorkingDirectory $WorkingDirectory -TimeoutMilliseconds 30000
    return ($result.StdOut.Trim() + ' (' + $git.Path + ')')
}

# --- Pester 5 ----------------------------------------------------------------------

# Requisito fixado na distribuicao de testes (tests/PesterRequirement.psd1), lido
# como dados (Import-PowerShellDataFile nao executa codigo).
function Read-PesterRequirement {
    param([string]$Root)
    return (Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($Root, 'tests', 'PesterRequirement.psd1')))
}

# Situacao do requisito num PowerShell: Disponivel somente com a versao exata
# fixada, de Pester 5, entre as instaladas. Nenhuma outra versao e aceita.
function Test-PesterRequirement {
    param([System.Collections.IDictionary]$Requirement, [string[]]$Available = @())
    $state = { param([string]$Name, [string]$Text) [pscustomobject]@{ State = $Name; Text = $Text } }
    $found = 'nenhum'; if (@($Available).Count -gt 0) { $found = (@($Available) -join ', ') }
    if ([string]$Requirement['ModuleName'] -cne 'Pester' -or [string]$Requirement['MajorVersion'] -ne '5') { return (& $state 'ForaDoContrato' 'requisito diferente de Pester 5 (especificacao secao 8)') }
    $required = [string]$Requirement['RequiredVersion']
    if (-not $required) { return (& $state 'NaoFixada' 'versao exata de Pester 5 nao fixada em tests/PesterRequirement.psd1 (decisao humana)') }
    if ($required -cnotmatch '\A5\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z') { return (& $state 'ForaDoContrato' ('versao fixada ' + $required + ' nao e uma versao exata de Pester 5')) }
    if (@($Available) -contains $required) { return (& $state 'Disponivel' ('Pester ' + $required + ' fixado e instalado')) }
    return (& $state 'Ausente' ('Pester ' + $required + ' fixado e ausente neste PowerShell (instalados: ' + $found + ')'))
}

# Processo Pester: importa somente a versao fixada, confere a versao carregada e
# executa a suite pelo adaptador nativo, no proprio processo (contido no Job Object
# pelo executor). Emite uma linha JSON por teste, as falhas de bloco e de conteiner
# e o resumo. TestDrive e TestRegistry desligados: nenhum efeito fora das fixtures.
# Codigo de saida pelo resultado global: 0 Passed, 1 Failed, 4 outro resultado ou
# erro do processo, 3 versao carregada diferente da fixada.
$PesterProbe = @'
$ErrorActionPreference = 'Stop'
# Nomes com prefixo: os casos executam neste processo e nao devem achar variaveis dele.
try {
    $MaPesterRequired = [version]$env:MA_PESTER_VERSION
    Import-Module -Name Pester -RequiredVersion $MaPesterRequired -Force
    $MaPesterLoaded = @(Get-Module -Name Pester)
    if ($MaPesterLoaded.Count -ne 1 -or $MaPesterLoaded[0].Version -ne $MaPesterRequired) { [Console]::Out.WriteLine('PESTER-ERRO=versao carregada diferente da fixada'); exit 3 }
    [Console]::Out.WriteLine('PESTER-VERSAO=' + $MaPesterLoaded[0].Version.ToString() + ' ' + $MaPesterLoaded[0].Path)
    $MaPesterConfiguration = New-PesterConfiguration
    $MaPesterConfiguration.Run.Container = New-PesterContainer -Path $env:MA_PESTER_ADAPTER -Data @{ Executor = $env:MA_PESTER_EXECUTOR; SuiteFile = $env:MA_PESTER_SUITE }
    $MaPesterConfiguration.Run.PassThru = $true
    $MaPesterConfiguration.Output.Verbosity = 'None'
    $MaPesterConfiguration.TestDrive.Enabled = $false
    $MaPesterConfiguration.TestRegistry.Enabled = $false
    $MaPesterRun = Invoke-Pester -Configuration $MaPesterConfiguration
    $MaPesterFirst = { param($Records) $text = ''; if (@($Records).Count -gt 0) { $text = [string]@($Records)[0].Exception.Message }; $text }
    foreach ($MaPesterTest in @($MaPesterRun.Tests)) {
        $MaPesterCase = $null
        if ($null -ne $MaPesterTest.Data -and $MaPesterTest.Data -is [System.Collections.IDictionary] -and $MaPesterTest.Data.Contains('MaCaseName')) { $MaPesterCase = [string]$MaPesterTest.Data['MaCaseName'] }
        [Console]::Out.WriteLine('PESTER-CASO=' + (ConvertTo-Json -Compress -InputObject ([ordered]@{ Case = $MaPesterCase; Name = [string]$MaPesterTest.ExpandedName; Result = [string]$MaPesterTest.Result; Message = (& $MaPesterFirst $MaPesterTest.ErrorRecord) })))
    }
    foreach ($MaPesterBlock in @($MaPesterRun.FailedBlocks)) { [Console]::Out.WriteLine('PESTER-BLOCO=' + [string]$MaPesterBlock.Name + ' :: ' + (& $MaPesterFirst $MaPesterBlock.ErrorRecord)) }
    foreach ($MaPesterContainer in @($MaPesterRun.FailedContainers)) { [Console]::Out.WriteLine('PESTER-CONTEINER=' + [string]$MaPesterContainer.Name + ' :: ' + (& $MaPesterFirst $MaPesterContainer.ErrorRecord)) }
    [Console]::Out.WriteLine('PESTER-FIM=' + (ConvertTo-Json -Compress -InputObject ([ordered]@{ Result = [string]$MaPesterRun.Result; Total = [int]$MaPesterRun.TotalCount; Passed = [int]$MaPesterRun.PassedCount; Failed = [int]$MaPesterRun.FailedCount
        Skipped = [int]$MaPesterRun.SkippedCount; NotRun = [int]$MaPesterRun.NotRunCount; Inconclusive = [int]$MaPesterRun.InconclusiveCount; FailedContainers = [int]$MaPesterRun.FailedContainersCount; FailedBlocks = [int]$MaPesterRun.FailedBlocksCount })))
    if ([string]$MaPesterRun.Result -ceq 'Passed') { exit 0 }
    if ([string]$MaPesterRun.Result -ceq 'Failed') { exit 1 }
    exit 4
} catch {
    [Console]::Out.WriteLine('PESTER-ERRO=' + $_.Exception.Message)
    exit 4
}
'@

# --- Isolamento --------------------------------------------------------------------

function New-OwnedDirectory {
    param([string]$Prefix)
    $path = [IO.Path]::Combine([IO.Path]::GetTempPath(), $Prefix + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    $script:OwnedRoots.Add($path)
    return $path
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()) } finally { $sha.Dispose() }
}

# Conteudo de uma raiz, exceto .git: caminhos, tipos e SHA-256 dos arquivos.
function Get-TreeSnapshot {
    param([string]$Root)
    $lines = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in (Get-ChildItem -LiteralPath $directory -Force)) {
            if ($directory -eq $Root -and $entry.Name -ieq '.git') { continue }
            $relative = $entry.FullName.Substring($Root.Length).TrimStart('\')
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $lines.Add($relative + '|reparse'); continue }
            if ($entry.PSIsContainer) { $lines.Add($relative + '|dir'); $pending.Push($entry.FullName) }
            else { $lines.Add($relative + '|' + (Get-Sha256Hex ([IO.File]::ReadAllBytes($entry.FullName)))) }
        }
    }
    $sorted = $lines.ToArray(); [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return ($sorted -join "`n")
}

function Compare-Snapshot {
    param([string]$Before, [string]$After)
    $old = @($Before -split "`n" | Where-Object { $_ }); $new = @($After -split "`n" | Where-Object { $_ })
    # Uma linha por diferenca; nenhuma saida quando iguais (chamadores usam @()).
    # Compare-Object recusa lista vazia no 5.1: os lados vazios sao tratados aqui.
    if ($old.Count -eq 0 -or $new.Count -eq 0) {
        foreach ($line in $old) { '- ' + ($line -split '\|')[0] }
        foreach ($line in $new) { '+ ' + ($line -split '\|')[0] }
        return
    }
    Compare-Object -ReferenceObject $old -DifferenceObject $new -CaseSensitive | ForEach-Object {
        $marker = '+'; if ($_.SideIndicator -eq '<=') { $marker = '-' }
        $marker + ' ' + ($_.InputObject -split '\|')[0]
    }
}

# --- Pacote isolado ----------------------------------------------------------------

function Get-PackageInventory {
    param([string]$Root)
    $manifest = [IO.File]::ReadAllText([IO.Path]::Combine($Root, 'package.manifest.json'), $Utf8) | ConvertFrom-Json
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($manifest.files)) {
        $path = [string]$entry.path
        # Caminho relativo controlado: sem raiz, sem . ou .., sem .git e sem o proprio manifesto.
        if ($path -cnotmatch '\A(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\z' -or $path -match '(?:\A|/)\.{1,2}(?:/|\z)' -or
            $path -imatch '\A(?:\.git(?:/|\z)|package\.manifest\.json\z)') { throw ('entrada invalida no manifesto: ' + $path) }
        $paths.Add($path)
    }
    return [pscustomobject]@{ Version = [string]$manifest.distributionVersion; State = [string]$manifest.state; Paths = $paths.ToArray() }
}

function New-IsolatedPackage {
    param([string]$Source)
    $inventory = Get-PackageInventory $Source
    $root = [IO.Path]::Combine((New-OwnedDirectory 'ma-pacote-'), 'template-dev-multiagente')
    foreach ($relative in (@($inventory.Paths) + 'package.manifest.json')) {
        $target = [IO.Path]::Combine($root, $relative.Replace('/', '\'))
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes([IO.Path]::Combine($Source, $relative.Replace('/', '\'))))
    }
    return [pscustomobject]@{ Root = $root; Inventory = $inventory }
}

# Integridade conferida pelo modulo da propria copia, em processo separado: o
# modulo da copia nunca e carregado no executor. Caminho por variavel de ambiente.
$IntegrityProbe = @'
$ErrorActionPreference = 'Stop'
$root = $env:MA_PACKAGE_ROOT
$module = Import-Module -Name ([IO.Path]::Combine($root, 'scripts', 'MultiAgentTemplate.psm1')) -Force -PassThru -DisableNameChecking
$integrity = Test-MaPackageIntegrity -PackageRoot $root
[Console]::Out.WriteLine('MODULO=' + $module.Path)
foreach ($issue in @($integrity.Issues)) { [Console]::Out.WriteLine('OCORRENCIA=' + $issue.Code + ' ' + $issue.Path) }
[Console]::Out.WriteLine('VALIDO=' + ([bool]$integrity.Valid).ToString())
'@

function Test-IsolatedPackage {
    param($Copy, [string]$HostPath, [string]$WorkingDirectory)
    $root = $Copy.Root
    Write-Output ('Pacote isolado: ' + $root)
    Write-Output ('  Versao do manifesto: ' + $Copy.Inventory.Version + ' (' + $Copy.Inventory.State + '), ' + @($Copy.Inventory.Paths).Count + ' arquivos inventariados')
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)
    $check = @{}
    $check['arquivos copiados = inventario + manifesto'] = ($files.Count -eq (@($Copy.Inventory.Paths).Count + 1))
    $check['nenhum arquivo de poc/'] = (@($files | Where-Object { $_.FullName.Substring($root.Length + 1) -like 'poc\*' }).Count -eq 0 -and
        @($Copy.Inventory.Paths | Where-Object { $_ -like 'poc/*' }).Count -eq 0)
    $check['nenhum .git nem link no pacote'] = (-not (Test-Path -LiteralPath ([IO.Path]::Combine($root, '.git')))) -and
        (@(Get-ChildItem -LiteralPath $root -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -eq 0)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($IntegrityProbe))
    $integrity = Invoke-ChildProcess -FilePath $HostPath -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WorkingDirectory $WorkingDirectory -TimeoutMilliseconds 300000 -Environment @{ MA_PACKAGE_ROOT = $root }
    $lines = @($integrity.StdOut -split "`r?`n")
    foreach ($line in @($lines | Where-Object { $_ -cmatch '\AOCORRENCIA=' })) { Write-Output ('    ' + $line.Substring(11)) }
    $modulePath = @($lines | Where-Object { $_ -cmatch '\AMODULO=' } | ForEach-Object { $_.Substring(7) })
    $check['integridade pelo modulo da copia (Test-MaPackageIntegrity)'] = ($integrity.ExitCode -eq 0 -and @($lines | Where-Object { $_ -ceq 'VALIDO=True' }).Count -eq 1)
    $check['modulo carregado da copia'] = ($modulePath.Count -eq 1 -and $modulePath[0].StartsWith($root, [StringComparison]::OrdinalIgnoreCase))

    # Ponto de entrada em modos sem modificacao, sobre um consumidor descartavel
    # (workspace vazio). Codigo 2: Incompleto, com acoes previstas ou simuladas.
    $consumer = New-OwnedDirectory 'ma-consumidor-'
    $workspace = [IO.Path]::Combine($consumer, 'workspace')
    [void][IO.Directory]::CreateDirectory($workspace)
    $config = [IO.Path]::Combine($consumer, 'multiagente.config.json')
    $json = '{"schemaVersion":"1.0","project":{"name":"Homologacao local","slug":"demo-homologacao"},"repository":{"url":"https://example.invalid/org/demo-homologacao.git"},"workspace":{"parentDirectory":' +
        ($workspace | ConvertTo-Json) + '}}'
    [IO.File]::WriteAllBytes($config, $Utf8.GetBytes($json))
    $entry = [IO.Path]::Combine($root, 'scripts', 'Install-MultiAgentProject.ps1')
    $packageBefore = Get-TreeSnapshot $root
    $consumerBefore = Get-TreeSnapshot $consumer
    $runs = @(
        @{ Name = 'Plan'; Arguments = @(); Expected = 'Fase: Plan' }
        @{ Name = 'Validate'; Arguments = @('-Phase', 'Validate'); Expected = 'Fase: Validate' }
        @{ Name = 'PrepareMaintenance -WhatIf'; Arguments = @('-Phase', 'PrepareMaintenance', '-AuthorizationReference', 'homologacao-local#ficticia', '-BaseCommit', ('a' * 40), '-WhatIf'); Expected = 'PrepareMaintenance' }
    )
    foreach ($run in $runs) {
        $result = Invoke-ChildProcess -FilePath $HostPath -Arguments (@('-NoProfile', '-NonInteractive', '-File', $entry, '-Config', $config) + $run.Arguments) -WorkingDirectory $WorkingDirectory -TimeoutMilliseconds 300000
        $text = $result.StdOut + $result.StdErr
        $check[('ponto de entrada ' + $run.Name + ': codigo 2 e fase identificada')] = ($result.ExitCode -eq 2 -and $text.Contains($run.Expected) -and $result.Termination -eq 'JobVazio')
        Write-Output ('    ' + $run.Name + ': codigo ' + $result.ExitCode + ', processos ' + $result.ProcessesInJob + ', ' + $result.Termination)
    }
    foreach ($pair in @(@('consumidor descartavel inalterado pelo ponto de entrada', $consumerBefore, $consumer), @('pacote inalterado pelo ponto de entrada', $packageBefore, $root))) {
        $changes = @(Compare-Snapshot $pair[1] (Get-TreeSnapshot $pair[2]))
        $check[$pair[0]] = ($changes.Count -eq 0)
        foreach ($change in ($changes | Select-Object -First 20)) { Write-Output ('    ' + $change) }
    }
    foreach ($name in @($check.Keys | Sort-Object)) {
        $mark = '[ok]   '; if (-not $check[$name]) { $mark = '[FALHA]'; $script:Failures.Add('pacote: ' + $name) }
        Write-Output ('  ' + $mark + ' ' + $name)
    }
}

# --- Suites ------------------------------------------------------------------------

function Get-SuiteFile {
    param([string]$Root, [string]$Name)
    $parts = $Name.Split('.')
    $folder = 'unit'; if ($parts[1] -eq 'Integration') { $folder = 'integration' }
    return [IO.Path]::Combine($Root, 'tests', $folder, $parts[0] + '.' + $parts[1] + '.Tests.ps1')
}

# Texto de um nome de caso pela AST: literais, concatenacao com + e variaveis de
# lacos ja resolvidas em $Bindings. $null para qualquer outra construcao.
function Get-CatalogText {
    param($Node, [hashtable]$Bindings)
    if ($Node -is [Management.Automation.Language.StringConstantExpressionAst]) { return $Node.Value }
    if ($Node -is [Management.Automation.Language.VariableExpressionAst]) {
        $name = $Node.VariablePath.UserPath
        if ($Bindings.ContainsKey($name)) { return $Bindings[$name] }
        return $null
    }
    if ($Node -is [Management.Automation.Language.BinaryExpressionAst] -and $Node.Operator -eq 'Plus') {
        $left = Get-CatalogText $Node.Left $Bindings; $right = Get-CatalogText $Node.Right $Bindings
        if ($null -eq $left -or $null -eq $right) { return $null }
        return ($left + $right)
    }
    if ($Node -is [Management.Automation.Language.ParenExpressionAst]) {
        $pipeline = $Node.Pipeline
        if ($pipeline -is [Management.Automation.Language.PipelineAst] -and $pipeline.PipelineElements.Count -eq 1 -and
            $pipeline.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst]) { return (Get-CatalogText $pipeline.PipelineElements[0].Expression $Bindings) }
    }
    return $null
}

# Itens de um laco foreach sobre lista literal de textos; $null para outro formato.
function Get-CatalogLoopValues {
    param([Management.Automation.Language.ForEachStatementAst]$Loop)
    $condition = $Loop.Condition
    if (-not ($condition -is [Management.Automation.Language.PipelineAst]) -or $condition.PipelineElements.Count -ne 1 -or
        -not ($condition.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst])) { return $null }
    $expression = $condition.PipelineElements[0].Expression
    if ($expression -is [Management.Automation.Language.ArrayExpressionAst]) {
        $statements = $expression.SubExpression.Statements
        if ($statements.Count -ne 1 -or -not ($statements[0] -is [Management.Automation.Language.PipelineAst]) -or $statements[0].PipelineElements.Count -ne 1 -or
            -not ($statements[0].PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst])) { return $null }
        $expression = $statements[0].PipelineElements[0].Expression
    }
    $elements = @($expression)
    if ($expression -is [Management.Automation.Language.ArrayLiteralAst]) { $elements = @($expression.Elements) }
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($element in $elements) {
        if (-not ($element -is [Management.Automation.Language.StringConstantExpressionAst])) { return $null }
        $values.Add($element.Value)
    }
    return , $values.ToArray()
}

# Pre-requisitos declarados num It (-Requires A, B), somente como literais.
# Devolve a lista (vazia sem -Requires) ou $null se nao literal.
function Get-CatalogRequires {
    param([Management.Automation.Language.CommandAst]$Call)
    $elements = @($Call.CommandElements)
    for ($i = 2; $i -lt $elements.Count; $i++) {
        $element = $elements[$i]
        if (-not ($element -is [Management.Automation.Language.CommandParameterAst]) -or $element.ParameterName -ne 'Requires') { continue }
        $value = $element.Argument
        if ($null -eq $value -and $i + 1 -lt $elements.Count) { $value = $elements[$i + 1] }
        $items = @($value)
        if ($value -is [Management.Automation.Language.ArrayLiteralAst]) { $items = @($value.Elements) }
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($item in $items) {
            if (-not ($item -is [Management.Automation.Language.StringConstantExpressionAst])) { return $null }
            $names.Add($item.Value)
        }
        return , $names.ToArray()
    }
    return , @()
}

# Casos esperados de uma suite, obtidos da AST do arquivo sem executa-lo: cada
# chamada It com nome literal ou composto de literais e da variavel de lacos
# foreach sobre listas literais (expandido por item, na ordem). It em condicional,
# catch, funcao, bloco de script, outro tipo de laco, nome nao resolvido, nomes
# repetidos, pre-requisito nao literal, erro de sintaxe ou nenhum caso tornam o
# catalogo indeterminado: a suite nao pode ser aprovada. Cases traz, por caso, a
# chamada, o bloco do caso, as variaveis do laco e os pre-requisitos declarados.
function Get-SuiteCatalog {
    param([string]$Path)
    $names = New-Object System.Collections.Generic.List[string]
    $entries = New-Object System.Collections.Generic.List[object]
    $problems = New-Object System.Collections.Generic.List[string]
    $tokens = $null; $errors = $null
    $ast = $null
    if (-not [IO.File]::Exists($Path)) { $problems.Add('arquivo ausente') }
    else {
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { $problems.Add('erro de sintaxe') }
    }
    $calls = @()
    if ($null -ne $ast) { $calls = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'It' }, $true)) }
    foreach ($call in $calls) {
        $line = $call.Extent.StartLineNumber
        $loops = New-Object System.Collections.Generic.List[object]
        $reason = $null
        $child = $call; $node = $call.Parent
        while ($null -ne $node -and $null -eq $reason) {
            if ($node -is [Management.Automation.Language.ForEachStatementAst]) {
                if ($child -ne $node.Body) { $reason = 'It fora do corpo do laco' } else { $loops.Insert(0, $node) }
            } elseif ($node -is [Management.Automation.Language.TryStatementAst]) {
                if ($child -ne $node.Body) { $reason = 'It em catch ou finally' }
            } elseif ($node -is [Management.Automation.Language.ScriptBlockAst]) {
                if ($null -ne $node.Parent) { $reason = 'It dentro de bloco de script' }
            } elseif (-not ($node -is [Management.Automation.Language.PipelineAst] -or $node -is [Management.Automation.Language.StatementBlockAst] -or
                    $node -is [Management.Automation.Language.NamedBlockAst])) { $reason = ('It em ' + $node.GetType().Name) }
            $child = $node; $node = $node.Parent
        }
        $nameNode = $null
        if ($call.CommandElements.Count -ge 2) { $nameNode = $call.CommandElements[1] }
        if ($null -eq $reason -and ($null -eq $nameNode -or $nameNode -is [Management.Automation.Language.CommandParameterAst])) { $reason = 'nome do caso ausente ou nomeado' }
        $requires = Get-CatalogRequires $call
        if ($null -eq $reason -and $null -eq $requires) { $reason = 'pre-requisito nao literal' }
        $body = @($call.CommandElements | Select-Object -Skip 2 | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] }) | Select-Object -Last 1
        $bindings = @(@{})
        foreach ($loop in $loops) {
            if ($null -ne $reason) { break }
            $values = Get-CatalogLoopValues $loop
            if ($null -eq $values) { $reason = 'laco sem lista literal'; break }
            $variable = $loop.Variable.VariablePath.UserPath
            $expanded = New-Object System.Collections.Generic.List[hashtable]
            foreach ($binding in $bindings) { foreach ($value in $values) { $next = $binding.Clone(); $next[$variable] = $value; $expanded.Add($next) } }
            $bindings = $expanded.ToArray()
        }
        if ($null -ne $reason) { $problems.Add($reason + ' (linha ' + $line + ')'); continue }
        foreach ($binding in $bindings) {
            $text = Get-CatalogText $nameNode $binding
            if ($null -eq $text -or $text.Length -eq 0) { $problems.Add('nome nao resolvido (linha ' + $line + ')'); break }
            $names.Add($text)
            $entries.Add([pscustomobject]@{ Name = $text; Line = $line; Call = $call; Body = $body; Bindings = $binding; Requires = $requires })
        }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($name in $names) { if (-not $seen.Add($name)) { $problems.Add('nome repetido: ' + $name) } }
    if ($null -ne $ast -and $names.Count -eq 0 -and $problems.Count -eq 0) { $problems.Add('nenhum caso') }
    $requiresByName = @{}; foreach ($entry in $entries) { $requiresByName[$entry.Name] = $entry.Requires }
    return [pscustomobject]@{ Path = $Path; Names = $names.ToArray(); Determined = ($problems.Count -eq 0); Problems = $problems.ToArray(); Ast = $ast; Cases = $entries.ToArray(); Requires = $requiresByName }
}

# Bloco de script com somente as instrucoes indicadas do arquivo da suite: o
# restante do texto vira espacos, exceto quebras de linha e ';' (separador entre
# instrucoes na mesma linha, fora da extensao delas; isolado, e instrucao vazia), de
# modo que linhas, nome do arquivo e $PSScriptRoot continuam os da suite. $null se
# o resultado nao analisar.
function New-MaskedScriptBlock {
    param([string]$Text, [string]$Path, [object[]]$Keep)
    $chars = New-Object char[] $Text.Length
    for ($i = 0; $i -lt $Text.Length; $i++) { if ($Text[$i] -eq "`r" -or $Text[$i] -eq "`n" -or $Text[$i] -eq ';') { $chars[$i] = $Text[$i] } else { $chars[$i] = ' ' } }
    foreach ($node in $Keep) { for ($i = $node.Extent.StartOffset; $i -lt $node.Extent.EndOffset; $i++) { $chars[$i] = $Text[$i] } }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput((New-Object string (, $chars)), $Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { return $null }
    return $ast.GetScriptBlock()
}

# Dentro de funcao ou bloco de script abaixo de Root? (Ali, exit nao executa ao definir.)
function Test-AstNested {
    param($Node, $Root)
    for ($parent = $Node.Parent; $null -ne $parent -and $parent -ne $Root; $parent = $parent.Parent) {
        if ($parent -is [Management.Automation.Language.ScriptBlockExpressionAst] -or $parent -is [Management.Automation.Language.FunctionDefinitionAst]) { return $true }
    }
    return $false
}

# Plano de execucao nativa de uma suite pelo Pester 5 (tests/pester/NativeSuite.Tests.ps1),
# obtido da AST sem executar o arquivo e sem altera-lo. Forma exigida (a das nove
# suites): preambulo no nivel do arquivo, com o mini-harness (funcao It com try e
# parametros Name, Body e, opcionalmente, Requires conferido em $script:Prereq); uma
# unica instrucao try com finally e sem catch, cujo corpo tem somente os casos (It
# direto ou em laco foreach do catalogo), titulos (Write-Output de texto literal),
# funcoes e atribuicoes; e o resumo depois dela, que nao e executado. Partes:
#   Prelude      preambulo sem o mini-harness e sem o bloqueio da suite (BeforeAll)
#   Gate*        bloqueio da suite inteira: if do preambulo terminado em exit; a
#                condicao e o corpo, sem o exit, sao avaliados no BeforeAll
#   Segments     funcoes e atribuicoes do bloco de casos, na ordem (BeforeAll)
#   CaseCleanup  finally do mini-harness (AfterEach)
#   SuiteCleanup finally da suite (AfterAll)
#   Exported*    variaveis e funcoes do nivel do arquivo, publicadas no escopo
#                global do processo Pester como o -File do harness as deixa
#   Cases        um It do Pester por caso, que executa o proprio bloco do caso
# O mini-harness nao executa nada: o Pester executa e avalia cada caso. Fora dessa
# forma o plano e indeterminado e a suite nao pode ser aprovada pelo motor Pester.
function Get-SuitePlan {
    param([string]$Path)
    $catalog = Get-SuiteCatalog $Path
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($problem in $catalog.Problems) { $problems.Add($problem) }
    $plan = [ordered]@{ Path = $Path; Catalog = $catalog; Determined = $false; Problems = $null; Prelude = $null; GateCondition = $null; GateBody = $null
        Segments = $null; CaseCleanup = $null; SuiteCleanup = $null; HarnessRequires = $false; ExportedVariables = @(); ExportedFunctions = @(); Cases = @() }
    $ast = $catalog.Ast
    if ($null -eq $ast -or $problems.Count -gt 0) { $plan.Problems = $problems.ToArray(); return [pscustomobject]$plan }
    if ($null -ne $ast.ParamBlock -or $null -ne $ast.BeginBlock -or $null -ne $ast.ProcessBlock -or $null -ne $ast.DynamicParamBlock) { $problems.Add('param, begin, process ou dynamicparam no arquivo') }
    $top = @($ast.EndBlock.Statements)
    $tries = @($top | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
    if ($tries.Count -ne 1) { $problems.Add('esperada uma unica instrucao try no nivel do arquivo; encontradas ' + $tries.Count) }
    elseif ($null -eq $tries[0].Finally -or @($tries[0].CatchClauses).Count -gt 0) { $problems.Add('try dos casos sem finally ou com catch') }
    if ($problems.Count -gt 0) { $plan.Problems = $problems.ToArray(); return [pscustomobject]$plan }
    $try = $tries[0]
    $text = $ast.Extent.Text
    $prelude = @($top | Select-Object -First ([Array]::IndexOf($top, $try)))

    # Mini-harness: somente o finally (por caso) e o pre-requisito por caso sao reproduzidos.
    $harness = @($prelude | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'It' })
    $caseCleanup = @()
    if ($harness.Count -ne 1) { $problems.Add('mini-harness It ausente ou repetido no preambulo') }
    else {
        $parameters = @()
        if ($null -ne $harness[0].Body.ParamBlock) { $parameters = @($harness[0].Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
        $signature = ($parameters -join ',')
        if ($signature -cne 'Name,Body' -and $signature -cne 'Name,Body,Requires') { $problems.Add('mini-harness It com parametros inesperados: ' + $signature) }
        if ($signature -ceq 'Name,Body,Requires') {
            $plan.HarnessRequires = $true
            if (-not $harness[0].Extent.Text.Contains('-not $script:Prereq[$_]')) { $problems.Add('pre-requisito do mini-harness fora de $script:Prereq') }
        }
        $inner = @($harness[0].Body.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })
        if ($inner.Count -ne 1) { $problems.Add('mini-harness It sem uma unica instrucao try') }
        elseif ($null -ne $inner[0].Finally) { $caseCleanup = @($inner[0].Finally.Statements) }
    }

    # Bloqueio da suite inteira: if do preambulo terminado em exit.
    $gates = @($prelude | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] -and $null -ne $_.Find({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] }, $true) })
    $gate = $null
    if ($gates.Count -gt 1) { $problems.Add('mais de um bloqueio de suite no preambulo') }
    elseif ($gates.Count -eq 1) {
        $gate = $gates[0]
        $statements = @(); if (@($gate.Clauses).Count -eq 1) { $statements = @($gate.Clauses[0].Item2.Statements) }
        $exits = @($gate.FindAll({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] }, $true))
        if (@($gate.Clauses).Count -ne 1 -or $null -ne $gate.ElseClause -or $exits.Count -ne 1 -or $statements.Count -eq 0 -or $statements[-1] -ne $exits[0]) { $problems.Add('bloqueio de suite fora da forma if { ...; exit } (linha ' + $gate.Extent.StartLineNumber + ')') }
        else {
            $plan.GateCondition = New-MaskedScriptBlock $text $Path @($gate.Clauses[0].Item1)
            $plan.GateBody = New-MaskedScriptBlock $text $Path @($statements | Select-Object -First ($statements.Count - 1))
        }
    }
    foreach ($statement in $prelude) {
        if ($statement -eq $gate) { continue }
        foreach ($exit in @($statement.FindAll({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] }, $true))) {
            if (-not (Test-AstNested $exit $statement)) { $problems.Add('exit no preambulo fora do bloqueio da suite (linha ' + $exit.Extent.StartLineNumber + ')') }
        }
    }

    # Bloco de casos: casos, titulos, funcoes e atribuicoes; nada mais.
    $segments = New-Object System.Collections.Generic.List[object]
    $isIt = { param($s) $s -is [Management.Automation.Language.PipelineAst] -and @($s.PipelineElements).Count -eq 1 -and $s.PipelineElements[0] -is [Management.Automation.Language.CommandAst] -and $s.PipelineElements[0].GetCommandName() -ceq 'It' }
    foreach ($statement in $try.Body.Statements) {
        if (& $isIt $statement) { continue }
        if ($statement -is [Management.Automation.Language.ForEachStatementAst] -and @($statement.Body.Statements | Where-Object { -not (& $isIt $_) }).Count -eq 0) { continue }
        if ($statement -is [Management.Automation.Language.FunctionDefinitionAst] -or $statement -is [Management.Automation.Language.AssignmentStatementAst]) { $segments.Add($statement); continue }
        $command = $null; if ($statement -is [Management.Automation.Language.PipelineAst] -and @($statement.PipelineElements).Count -eq 1) { $command = $statement.PipelineElements[0] }
        if ($command -is [Management.Automation.Language.CommandAst] -and $command.GetCommandName() -ceq 'Write-Output' -and @($command.CommandElements).Count -eq 2 -and
            $command.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst]) { continue }
        $problems.Add('instrucao nao suportada no bloco de casos (linha ' + $statement.Extent.StartLineNumber + ')')
    }
    foreach ($case in $catalog.Cases) {
        if ($case.Call.Extent.StartOffset -lt $try.Body.Extent.StartOffset -or $case.Call.Extent.EndOffset -gt $try.Body.Extent.EndOffset) { $problems.Add('caso fora do bloco de casos: ' + $case.Name) }
        if ($null -eq $case.Body) { $problems.Add('caso sem bloco: ' + $case.Name) }
        if (@($case.Requires).Count -gt 0 -and -not $plan.HarnessRequires) { $problems.Add('pre-requisito sem suporte no mini-harness: ' + $case.Name) }
    }
    if ($problems.Count -gt 0) { $plan.Problems = $problems.ToArray(); return [pscustomobject]$plan }

    $definitions = @($prelude | Where-Object { $_ -ne $harness[0] -and $_ -ne $gate }) + $segments.ToArray()
    $plan.Prelude = New-MaskedScriptBlock $text $Path @($prelude | Where-Object { $_ -ne $harness[0] -and $_ -ne $gate })
    $plan.Segments = New-MaskedScriptBlock $text $Path $segments.ToArray()
    # Nomes definidos no nivel do arquivo: com -File, o harness os deixa no escopo
    # global, visivel ao codigo executado no escopo do modulo (InModule); o
    # adaptador os publica no global do processo Pester. Preferencias ficam de fora.
    $variables = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $functions = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($statement in $definitions) {
        if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) { [void]$functions.Add($statement.Name); continue }
        foreach ($assignment in @($statement.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true))) {
            if (Test-AstNested $assignment $statement) { continue }
            $target = $assignment.Left
            if ($target -is [Management.Automation.Language.ConvertExpressionAst]) { $target = $target.Child }
            if (-not ($target -is [Management.Automation.Language.VariableExpressionAst])) { continue }
            $variable = $target.VariablePath
            $name = $variable.UserPath.Substring($variable.UserPath.IndexOf(':') + 1)
            if (-not ($variable.IsUnqualified -or $variable.IsScript -or $variable.IsLocal) -or $name -like '*Preference') { continue }
            [void]$variables.Add($name)
        }
    }
    $plan.ExportedVariables = @($variables)
    $plan.ExportedFunctions = @($functions)
    $plan.CaseCleanup = New-MaskedScriptBlock $text $Path $caseCleanup
    $plan.SuiteCleanup = New-MaskedScriptBlock $text $Path @($try.Finally.Statements)
    foreach ($part in @('Prelude', 'Segments', 'CaseCleanup', 'SuiteCleanup')) { if ($null -eq $plan[$part]) { $problems.Add('trecho ' + $part + ' sem analise valida') } }
    if ($null -ne $gate -and ($null -eq $plan.GateCondition -or $null -eq $plan.GateBody)) { $problems.Add('trecho do bloqueio da suite sem analise valida') }
    $plan.Cases = @(foreach ($case in $catalog.Cases) { [pscustomobject]@{ Name = $case.Name; Body = $case.Body.ScriptBlock.GetScriptBlock(); Bindings = $case.Bindings; Requires = $case.Requires } })
    $plan.Problems = $problems.ToArray()
    $plan.Determined = ($problems.Count -eq 0)
    return [pscustomobject]$plan
}

# Nome do caso de uma linha: o mais longo do catalogo igual ao restante da linha,
# seguido de ' :: ' (falha, pre-requisito) ou, em [ok], de ' (N s)'. $null se nenhum.
function Resolve-CaseName {
    param([string]$Rest, [string]$Kind, [string[]]$Names)
    $best = $null
    foreach ($name in $Names) {
        if ($null -ne $best -and $name.Length -le $best.Length) { continue }
        if ($Kind -eq 'ok') { $match = ($Rest -ceq $name) -or ($Rest.StartsWith($name + ' (', [StringComparison]::Ordinal) -and $Rest.Substring($name.Length) -cmatch '\A \([0-9]+ s\)\z') }
        else { $match = $Rest.StartsWith($name + ' :: ', [StringComparison]::Ordinal) }
        if ($match) { $best = $name }
    }
    return $best
}

# Falha da execucao do processo, independente do conteudo da saida ('' se nenhuma).
function Get-RunFailure {
    param($Run)
    if ($Run.StartError) { return ('execucao nao iniciada: ' + $Run.StartError) }
    if ($Run.Termination -eq 'NaoConfirmado') { return ('encerramento dos processos nao confirmado (' + $Run.TerminationDetail + ')') }
    if ($Run.TimedOut) { return 'prazo excedido; processos encerrados e conferidos' }
    if ($Run.Interrupted) { return ('execucao interrompida: ' + $Run.InterruptDetail) }
    if ($Run.Persisted) { return 'processo descendente ativo apos o fim da suite; encerrado e conferido' }
    if (-not $Run.StreamsComplete) { return 'saida nao concluida' }
    return ''
}

# Resultado de uma suite do harness confrontado com o catalogo de casos esperados.
# Contagens separadas: aprovados, falhos, ignorados (o harness nao ignora casos),
# bloqueados por pre-requisito e nao executados. Status: Aprovada, Falha,
# Pendente (pre-requisito) ou Inconclusiva (completude nao comprovada).
function Get-SuiteVerdict {
    param($Run, $Catalog)
    $names = @($Catalog.Names)
    $lines = @([string]$Run.StdOut -split "`r?`n")
    $summaryPattern = '\AResultado: ([0-9]+) aprovados, ([0-9]+) falhas(?:, ([0-9]+) nao executados por pre-requisito)?\s*\z'
    $blockedPattern = '\AResultado: 0 aprovados, 0 falhas; suite nao executada por pre-requisito ausente\s*\z'
    $summaries = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -cmatch $summaryPattern -or $lines[$i] -cmatch $blockedPattern) { $i } })
    $end = $lines.Count; if ($summaries.Count -gt 0) { $end = $summaries[-1] }
    $cases = @{}; foreach ($name in $names) { $cases[$name] = 'NaoExecutado' }
    $seen = @{}
    $details = New-Object System.Collections.Generic.List[string]
    $counts = @{ ok = 0; falha = 0; prereq = 0; suitePrereq = 0; late = 0; unexpected = 0; duplicated = 0 }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -cmatch '\A  \[ok\]    (.*)\z') { $kind = 'ok' } elseif ($line -cmatch '\A  \[FALHA\] (.*)\z') { $kind = 'falha' } elseif ($line -cmatch '\A  \[PRE-REQ\] (.*)\z') { $kind = 'prereq' } else { continue }
        $rest = $Matches[1]
        if ($i -gt $end) { $counts.late++; $details.Add('linha de caso apos o resumo: ' + $line.Trim()); continue }
        $name = Resolve-CaseName $rest $kind $names
        if ($null -eq $name) {
            if ($kind -eq 'prereq' -and $rest.StartsWith('ausente: ', [StringComparison]::Ordinal)) { $counts.suitePrereq++; continue }
            $counts.unexpected++; $details.Add('nao catalogado: ' + $line.Trim()); continue
        }
        $counts[$kind]++
        if ($seen.ContainsKey($name)) { $counts.duplicated++; $details.Add('duplicado: ' + $name); $cases[$name] = 'Duplicado'; continue }
        $seen[$name] = $true
        $cases[$name] = @{ ok = 'Aprovado'; falha = 'Falha'; prereq = 'PreRequisito' }[$kind]
    }
    # Lista do resumo ('  - [PRE-REQ] <nome> :: ausente: ...'), identificada pelo catalogo.
    $listed = @($lines | Select-Object -Skip ($end + 1) | Where-Object { $_ -cmatch '\A  - \[PRE-REQ\] ' } | ForEach-Object {
            $listedName = Resolve-CaseName $_.Substring(14) 'prereq' $names
            if ($null -eq $listedName) { '?' + $_ } else { $listedName }
        })
    $notRun = @($names | Where-Object { $cases[$_] -eq 'NaoExecutado' })
    $passed = @($names | Where-Object { $cases[$_] -eq 'Aprovado' }).Count
    $failed = @($names | Where-Object { $cases[$_] -eq 'Falha' }).Count
    $blocked = @($names | Where-Object { $cases[$_] -eq 'PreRequisito' }).Count
    $suiteBlocked = ($summaries.Count -gt 0 -and $lines[$end] -cmatch $blockedPattern)

    $status = 'Inconclusiva'; $reason = ''
    $summaryPassed = $null; $summaryFailed = $null; $summaryBlocked = 0
    if ($summaries.Count -gt 0 -and $lines[$end] -cmatch $summaryPattern) { $summaryPassed = [int]$Matches[1]; $summaryFailed = [int]$Matches[2]; if ($Matches[3]) { $summaryBlocked = [int]$Matches[3] } }
    $runFailure = Get-RunFailure $Run
    if ($runFailure) { $status = 'Falha'; $reason = $runFailure }
    elseif (-not $Catalog.Determined) { $reason = ('casos esperados indeterminados: ' + (@($Catalog.Problems) -join '; ')) }
    elseif ($summaries.Count -eq 0) { $reason = 'resumo ausente ou malformado' }
    elseif ($summaries.Count -gt 1) { $reason = 'resumo repetido' }
    elseif ($counts.late -gt 0) { $reason = 'linha de caso apos o resumo' }
    elseif ($suiteBlocked) {
        if ($counts.ok + $counts.falha + $counts.prereq + $counts.unexpected -gt 0) { $reason = 'suite bloqueada por pre-requisito com linhas de caso' }
        elseif ($counts.suitePrereq -eq 0) { $reason = 'suite bloqueada sem pre-requisito identificado' }
        elseif ($Run.ExitCode -ne 2) { $status = 'Falha'; $reason = ('codigo de saida ' + $Run.ExitCode + ' incompativel com a suite bloqueada') }
        else { $status = 'Pendente'; $reason = 'suite nao executada por pre-requisito ausente' }
    }
    elseif ($counts.unexpected -gt 0 -or $counts.duplicated -gt 0 -or $notRun.Count -gt 0 -or $counts.suitePrereq -gt 0) {
        $reason = ('execucao incompleta: ' + $notRun.Count + ' nao executados, ' + $counts.duplicated + ' duplicados, ' + ($counts.unexpected + $counts.suitePrereq) + ' nao catalogados')
    }
    elseif ($summaryPassed -ne $counts.ok -or $summaryFailed -ne $counts.falha -or $summaryBlocked -ne $counts.prereq) {
        $reason = ('resumo inconsistente com as linhas ([ok] ' + $counts.ok + ', [FALHA] ' + $counts.falha + ', [PRE-REQ] ' + $counts.prereq + ')')
    }
    elseif ((@($listed | Sort-Object) -join "`n") -cne (@($names | Where-Object { $cases[$_] -eq 'PreRequisito' } | Sort-Object) -join "`n")) {
        $reason = 'lista [PRE-REQ] do resumo diverge dos casos bloqueados'
    }
    elseif ($Run.ExitCode -eq 0 -and $failed -eq 0 -and $blocked -eq 0 -and $passed -eq $names.Count) { $status = 'Aprovada' }
    elseif ($Run.ExitCode -eq 1 -and $failed -gt 0) { $status = 'Falha'; $reason = 'casos com falha' }
    elseif ($Run.ExitCode -eq 2 -and $failed -eq 0 -and $blocked -gt 0) { $status = 'Pendente'; $reason = 'pre-requisito ausente' }
    else { $status = 'Falha'; $reason = ('codigo de saida ' + $Run.ExitCode + ' incompativel com o resumo') }
    if ($suiteBlocked -and $status -eq 'Pendente') { $blocked = $names.Count; $notRun = @(); foreach ($name in $names) { $cases[$name] = 'PreRequisito' } }
    foreach ($name in ($notRun | Select-Object -First 20)) { $details.Add('nao executado: ' + $name) }
    return [pscustomobject]@{
        Status = $status; Reason = $reason; Expected = $names.Count; Passed = $passed; Failed = $failed; Skipped = 0; Blocked = $blocked; NotExecuted = $notRun.Count
        Duplicated = $counts.duplicated; Unexpected = ($counts.unexpected + $counts.suitePrereq); SuiteBlocked = $suiteBlocked; Cases = $cases; Details = $details.ToArray()
    }
}

# Resultado de uma suite executada nativamente pelo Pester 5 (adaptador
# tests/pester/NativeSuite.Tests.ps1), confrontado com o catalogo. Cada caso
# esperado deve aparecer exatamente uma vez, identificado por Data.MaCaseName e com
# o nome do teste igual ao do caso. Passed: aprovado; Failed: falha; Skipped:
# bloqueado por pre-requisito somente se o caso declara -Requires ou a suite inteira
# foi bloqueada (PESTER-PRE-REQ-SUITE); outro Skipped e ignorado indevidamente;
# NotRun: nao executado; outro resultado: indeterminado. Aprovada somente com
# resultado global Passed, codigo 0, versao carregada igual a fixada, nenhuma falha
# de bloco ou conteiner, todos os casos aprovados e contagens do resumo iguais as dos
# testes emitidos. Resultado global Failed nunca e aprovado, mesmo com todos os
# casos Passed (falha de BeforeAll/AfterAll ou incoerencia).
function Get-PesterVerdict {
    param($Run, $Catalog, [string]$RequiredVersion = '')
    $names = @($Catalog.Names)
    $requiresOf = @{}; if ($null -ne $Catalog.PSObject.Properties['Requires']) { $requiresOf = $Catalog.Requires }
    $lines = @([string]$Run.StdOut -split "`r?`n")
    $cases = @{}; foreach ($name in $names) { $cases[$name] = 'NaoExecutado' }
    $details = New-Object System.Collections.Generic.List[string]
    $tests = New-Object System.Collections.Generic.List[object]
    $finals = New-Object System.Collections.Generic.List[object]
    $versions = New-Object System.Collections.Generic.List[string]
    $suitePrereq = New-Object System.Collections.Generic.List[string]
    $malformed = 0; $duplicated = 0; $unexpected = 0; $errors = 0
    # Objeto JSON com exatamente os campos esperados; $null se malformado.
    $parse = {
        param([string]$Json, [string[]]$Fields)
        try { $object = $Json | ConvertFrom-Json } catch { return $null }
        if ($null -eq $object -or $object -isnot [pscustomobject]) { return $null }
        if ((@($object.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') -cne ($Fields -join ',')) { return $null }
        return $object
    }
    $caseFields = @('Case', 'Name', 'Result', 'Message')
    $finalFields = @('Result', 'Total', 'Passed', 'Failed', 'Skipped', 'NotRun', 'Inconclusive', 'FailedContainers', 'FailedBlocks')
    foreach ($line in $lines) {
        if ($line -cmatch '\APESTER-ERRO=(.*)\z') { $errors++; $details.Add('pester: ' + $Matches[1]) }
        elseif ($line -cmatch '\APESTER-VERSAO=(.*)\z') { $versions.Add($Matches[1]) }
        elseif ($line -cmatch '\APESTER-PRE-REQ-SUITE=(.*)\z') { $suitePrereq.Add($Matches[1]) }
        elseif ($line -cmatch '\APESTER-(?:BLOCO|CONTEINER)=') { $details.Add('pester: ' + $line.Substring(7)) }
        elseif ($line -cmatch '\APESTER-CASO=(.*)\z') { $item = & $parse $Matches[1] $caseFields; if ($null -eq $item) { $malformed++ } else { $tests.Add($item) } }
        elseif ($line -cmatch '\APESTER-FIM=(.*)\z') { $item = & $parse $Matches[1] $finalFields; if ($null -eq $item) { $malformed++ } else { $finals.Add($item) } }
    }
    $suiteBlocked = ($suitePrereq.Count -gt 0)
    $map = @{ Passed = 'Aprovado'; Failed = 'Falha'; Skipped = 'PreRequisito'; NotRun = 'NaoExecutado' }
    $all = @(foreach ($test in $tests) { $test })
    foreach ($test in $all) {
        if ($null -eq $test.Case) { $unexpected++; $details.Add('teste Pester nao catalogado: ' + $test.Name); continue }
        $name = [string]$test.Case
        if (-not $cases.ContainsKey($name)) { $unexpected++; $details.Add('nao catalogado: ' + $name); continue }
        if ($cases[$name] -ne 'NaoExecutado' -or @($all | Where-Object { [string]$_.Case -ceq $name }).Count -gt 1) {
            if ($cases[$name] -ne 'Duplicado') { $duplicated++; $details.Add('duplicado: ' + $name) }
            $cases[$name] = 'Duplicado'; continue
        }
        $result = [string]$test.Result
        if ([string]$test.Name -cne $name) { $cases[$name] = 'Indeterminado'; $details.Add('nome Pester diferente do caso: ' + $test.Name + ' / ' + $name); continue }
        if ($map.ContainsKey($result)) { $cases[$name] = $map[$result] } else { $cases[$name] = 'Indeterminado'; $details.Add('resultado Pester ' + $result + ': ' + $name) }
        $declared = $requiresOf[$name]
        if ($result -ceq 'Skipped' -and -not $suiteBlocked -and -not ($null -ne $declared -and @($declared).Count -gt 0)) { $cases[$name] = 'Ignorado'; $details.Add('ignorado sem pre-requisito declarado: ' + $name + ' :: ' + $test.Message) }
        if ($result -ceq 'Failed' -and $test.Message) { $details.Add('falha: ' + $name + ' :: ' + $test.Message) }
    }
    $count = { param([string]$State) @($names | Where-Object { $cases[$_] -eq $State }).Count }
    $notRun = @($names | Where-Object { $cases[$_] -eq 'NaoExecutado' })
    $passed = & $count 'Aprovado'; $failed = & $count 'Falha'; $blocked = & $count 'PreRequisito'; $ignored = & $count 'Ignorado'; $odd = & $count 'Indeterminado'
    $emitted = { param([string]$Result) @($all | Where-Object { [string]$_.Result -ceq $Result }).Count }
    $status = 'Inconclusiva'; $reason = ''
    $runFailure = Get-RunFailure $Run
    $final = $null; if ($finals.Count -eq 1) { $final = $finals[0] }
    $global = ''; if ($null -ne $final) { $global = [string]$final.Result }
    if ($runFailure) { $status = 'Falha'; $reason = $runFailure }
    elseif (-not $Catalog.Determined) { $reason = ('casos esperados indeterminados: ' + (@($Catalog.Problems) -join '; ')) }
    elseif ($Run.ExitCode -eq 3) { $status = 'Falha'; $reason = 'versao do Pester carregada diferente da fixada' }
    elseif ($errors -gt 0) { $status = 'Falha'; $reason = 'erro do processo Pester' }
    elseif ($null -eq $final -or $malformed -gt 0) { $reason = 'resumo Pester ausente, repetido ou malformado' }
    elseif ($versions.Count -ne 1 -or -not $RequiredVersion -or -not $versions[0].StartsWith($RequiredVersion + ' ', [StringComparison]::Ordinal)) { $reason = ('versao do Pester nao comprovada (fixada ' + $RequiredVersion + '; carregada ' + ($versions -join ', ') + ')') }
    elseif ([int]$final.FailedContainers -ne 0 -or [int]$final.FailedBlocks -ne 0) { $status = 'Falha'; $reason = ('falha de descoberta, conteiner ou bloco (BeforeAll/AfterAll) no Pester; resultado global ' + $global) }
    elseif (($global -ceq 'Passed' -and $Run.ExitCode -ne 0) -or ($global -ceq 'Failed' -and $Run.ExitCode -ne 1)) { $status = 'Falha'; $reason = ('codigo de saida ' + $Run.ExitCode + ' incompativel com o resultado global ' + $global) }
    elseif ($global -cne 'Passed' -and $global -cne 'Failed') { $reason = ('resultado global Pester ' + $global) }
    elseif ($unexpected -gt 0 -or $duplicated -gt 0 -or $notRun.Count -gt 0 -or $odd -gt 0 -or $ignored -gt 0) {
        $reason = ('execucao incompleta: ' + $notRun.Count + ' nao executados, ' + $duplicated + ' duplicados, ' + $unexpected + ' nao catalogados, ' + $ignored + ' ignorados, ' + $odd + ' indeterminados')
    }
    elseif ([int]$final.Total -ne $all.Count -or [int]$final.Passed -ne (& $emitted 'Passed') -or [int]$final.Failed -ne (& $emitted 'Failed') -or
        [int]$final.Skipped -ne (& $emitted 'Skipped') -or [int]$final.NotRun -ne (& $emitted 'NotRun') -or [int]$final.Inconclusive -ne (& $emitted 'Inconclusive')) { $reason = 'resumo Pester inconsistente com os testes emitidos' }
    elseif ($suiteBlocked) {
        if ($blocked -eq $names.Count -and $global -ceq 'Passed') { $status = 'Pendente'; $reason = ('suite nao executada por pre-requisito ausente: ' + ($suitePrereq -join '; ')) }
        else { $reason = 'suite bloqueada por pre-requisito com casos executados' }
    }
    elseif ($failed -gt 0) {
        if ($global -ceq 'Failed') { $status = 'Falha'; $reason = 'casos com falha' } else { $reason = 'casos com falha e resultado global Passed (incoerente)' }
    }
    elseif ($global -cne 'Passed') { $reason = 'resultado global Failed sem caso, bloco ou conteiner com falha (incoerente)' }
    elseif ($blocked -gt 0) { $status = 'Pendente'; $reason = 'pre-requisito ausente' }
    elseif ($passed -eq $names.Count) { $status = 'Aprovada' }
    else { $reason = 'casos aprovados diferentes dos esperados' }
    foreach ($name in ($notRun | Select-Object -First 20)) { $details.Add('nao executado: ' + $name) }
    return [pscustomobject]@{
        Status = $status; Reason = $reason; Expected = $names.Count; Passed = $passed; Failed = $failed; Skipped = $ignored; Blocked = $blocked; NotExecuted = $notRun.Count
        Duplicated = $duplicated; Unexpected = $unexpected; SuiteBlocked = $suiteBlocked; Cases = $cases; Details = $details.ToArray()
    }
}

# Suite nao executada (motor indisponivel no PowerShell): todos os casos pendentes.
function New-NotRunVerdict {
    param($Catalog, [string]$Reason)
    $cases = @{}; foreach ($name in @($Catalog.Names)) { $cases[$name] = 'NaoExecutado' }
    return [pscustomobject]@{
        Status = 'Pendente'; Reason = $Reason; Expected = @($Catalog.Names).Count; Passed = 0; Failed = 0; Skipped = 0; Blocked = 0; NotExecuted = @($Catalog.Names).Count
        Duplicated = 0; Unexpected = 0; SuiteBlocked = $false; Cases = $cases; Details = @()
    }
}

# Situacao de um criterio pelos resultados: Pending quando todas as suites foram
# aprovadas, mas o criterio exige os dois PowerShells e so um foi aprovado.
function Get-CriterionState {
    param([System.Collections.IDictionary]$Criterion, [string[]]$Selected, $Results, [string[]]$Editions)
    if ($Criterion.Contains('External')) { return [pscustomobject]@{ State = 'Externo: revisao ou decisao fora do executor'; Pending = $false } }
    $needed = @($Criterion.Suites)
    $missing = @($needed | Where-Object { $Selected -notcontains $_ })
    $approvedIn = @($Editions | Select-Object -Unique | Where-Object {
        $edition = $_
        @($needed | Where-Object { $n = $_; @($Results | Where-Object { $_.Edition -eq $edition -and $_.Suite -eq $n -and $_.Verdict.Status -eq 'Aprovada' }).Count -eq 1 }).Count -eq $needed.Count
    })
    $notApproved = @($Results | Where-Object { $needed -contains $_.Suite -and $_.Verdict.Status -ne 'Aprovada' })
    $pending = $false
    if ($missing.Count -gt 0) { $state = 'Nao avaliado: suites fora da selecao (' + ($missing -join ', ') + ')' }
    elseif ($notApproved.Count -gt 0) { $state = 'Nao comprovado: suite sem aprovacao (' + (($notApproved | ForEach-Object { $_.Edition + ' ' + $_.Suite }) -join ', ') + ')' }
    elseif ($approvedIn.Count -eq 0) { $state = 'Nao comprovado: nenhum PowerShell executado' }
    elseif ($Criterion.Contains('Hosts') -and -not ($approvedIn -contains 'Desktop' -and $approvedIn -contains 'Core')) { $state = 'Pendente: aprovado somente em ' + ($approvedIn -join ', ') + '; exige os dois PowerShells'; $pending = $true }
    else { $state = 'Coberto e aprovado em ' + ($approvedIn -join ', ') + ' (' + ($needed -join ', ') + ')' }
    return [pscustomobject]@{ State = $state; Pending = $pending }
}

# --- Execucao ----------------------------------------------------------------------

# Carregado por dot-sourcing (testes do proprio executor): somente as funcoes.
if ($MyInvocation.InvocationName -eq '.') { return }

$selected = @($SuiteNames | Where-Object {
    ($Group -eq 'All' -or $_.EndsWith('.' + $Group)) -and ($Suite.Count -eq 0 -or $Suite -contains $_)
})
foreach ($name in $Suite) { if ($SuiteNames -notcontains $name) { [Console]::Error.WriteLine('Suite desconhecida: ' + $name + '. Validas: ' + ($SuiteNames -join ', ')); exit 3 } }
if ($selected.Count -eq 0) { [Console]::Error.WriteLine('Nenhuma suite selecionada.'); exit 3 }

# Uma instancia por sessao: suites observam processos e mutexes do sistema.
$mutex = New-Object System.Threading.Mutex($false, 'Local\ma-invoke-tests')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { [Console]::Error.WriteLine('Outra execucao de Invoke-Tests em andamento; nada executado.'); $mutex.Dispose(); exit 3 }

$results = New-Object System.Collections.Generic.List[object]
$executedEditions = New-Object System.Collections.Generic.List[string]
$reachedEnd = $false
try {
    $work = New-OwnedDirectory 'ma-executor-'
    # Copia montada antes de qualquer processo: com -Package, a contencao e as suites vem dela.
    $runRoot = $SourceRoot
    $copy = $null
    if ($Package) { $copy = New-IsolatedPackage $SourceRoot; $runRoot = $copy.Root; $script:ContainmentRoot = $runRoot }
    $os = [Environment]::OSVersion.Version
    $release = ''
    try { $release = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).DisplayVersion } catch { }
    Write-Output 'Executor de testes do instalador multiagente'
    Write-Output ('Windows: ' + $os.ToString() + ' ' + $release)
    Write-Output ('Git: ' + (Get-GitIdentity $work))
    Write-Output ('Origem: ' + $SourceRoot)
    Write-Output ('Selecao: ' + ($selected -join ', '))
    if ($Engine -eq 'Pester') { Write-Output 'Motor: Pester (nativo: cada caso executado e avaliado por um It do Pester 5, no processo Pester contido em Job Object)' }
    else { Write-Output 'Motor: Harness (auxiliar: mini-harness autocontido de cada suite; nao demonstra a secao 8)' }
    Write-Output ('Contencao: Job Object pelo executor nativo de ' + (Get-ContainmentModule).Path)

    Write-Output ('Raiz executada: ' + $runRoot)
    $requirement = Read-PesterRequirement $runRoot
    $pinned = [string]$requirement['RequiredVersion']; if (-not $pinned) { $pinned = 'nao fixada' }
    Write-Output ('Pester exigido: ' + [string]$requirement['ModuleName'] + ' ' + [string]$requirement['MajorVersion'] + ', versao exata ' + $pinned + ' (tests/PesterRequirement.psd1)')
    $hosts = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in (Get-HostCandidates)) {
        if (-not $candidate.Path -or -not [IO.File]::Exists($candidate.Path)) {
            $script:Pending.Add($candidate.Label + ': nao encontrado; suites nao executadas neste PowerShell')
            Write-Output ('PowerShell: ' + $candidate.Label + ' ausente (pendente)')
            continue
        }
        $identity = Get-HostIdentity -Path $candidate.Path -WorkingDirectory $work
        $pester = Test-PesterRequirement -Requirement $requirement -Available $identity.PesterVersions
        $found = 'ausente'; if (@($identity.PesterVersions).Count -gt 0) { $found = (@($identity.PesterVersions) -join ',') }
        Write-Output ('PowerShell: ' + $identity.Edition + ' ' + $identity.Version + ' ' + $identity.Architecture + ', politica ' + $identity.Policy + ', Pester instalado ' + $found + ' (' + $candidate.Path + ')')
        Write-Output ('  Pester 5: ' + $pester.State + ' - ' + $pester.Text)
        $hosts.Add([pscustomobject]@{ Label = $candidate.Label; Path = $candidate.Path; Identity = $identity; Pester = $pester })
    }
    if ($Engine -eq 'Harness') { $script:Pending.Add('Pester 5 (especificacao secao 8): nao demonstrado nesta execucao; suites executadas pelo harness auxiliar (-Engine Harness); o motor padrao e o Pester') }
    Write-Output ''

    if ($Package) {
        if ($hosts.Count -gt 0) { Test-IsolatedPackage -Copy $copy -HostPath $hosts[0].Path -WorkingDirectory $work }
        else { $script:Pending.Add('pacote: ponto de entrada nao exercitado sem PowerShell') }
        Write-Output ''
    }

    # Casos esperados, pela AST de cada suite, antes de qualquer execucao; com o
    # motor Pester, tambem o plano de execucao nativa (forma da suite conferida).
    $catalogs = @{}
    $plans = @{}
    Write-Output 'Casos esperados (AST das suites, antes da execucao)'
    foreach ($name in $selected) {
        $note = ''
        if ($Engine -eq 'Pester') {
            $plan = Get-SuitePlan (Get-SuiteFile $runRoot $name)
            $plans[$name] = $plan
            $catalog = $plan.Catalog
            if ($catalog.Determined -and -not $plan.Determined) { $note = '  PLANO NATIVO INDETERMINADO: ' + (@($plan.Problems) -join '; ') }
        } else { $catalog = Get-SuiteCatalog (Get-SuiteFile $runRoot $name) }
        $catalogs[$name] = $catalog
        if (-not $catalog.Determined) { $note = '  INDETERMINADO: ' + (@($catalog.Problems) -join '; ') }
        Write-Output ('  {0,-31} {1,4}{2}' -f $name, @($catalog.Names).Count, $note)
    }
    Write-Output ('  {0,-31} {1,4}' -f 'Total', (@($selected | ForEach-Object { @($catalogs[$_].Names).Count }) | Measure-Object -Sum).Sum)
    Write-Output ''

    $rootBefore = Get-TreeSnapshot $runRoot
    $executorFile = [IO.Path]::Combine($runRoot, 'tests', 'Invoke-Tests.ps1')
    $adapter = [IO.Path]::Combine($runRoot, 'tests', 'pester', 'NativeSuite.Tests.ps1')
    $pesterEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($PesterProbe))
    foreach ($hostInfo in $hosts) {
        Write-Output ('== ' + $hostInfo.Identity.Edition + ' ' + $hostInfo.Identity.Version + ' ' + $hostInfo.Identity.Architecture + ' (' + $Engine + ')')
        if ($Engine -eq 'Pester' -and $hostInfo.Pester.State -ne 'Disponivel') {
            $script:Pending.Add($hostInfo.Identity.Edition + ' ' + $hostInfo.Identity.Architecture + ': motor Pester nao executado: ' + $hostInfo.Pester.Text)
            Write-Output ('  motor Pester nao executado: ' + $hostInfo.Pester.Text)
            foreach ($name in $selected) { $results.Add([pscustomobject]@{ Edition = $hostInfo.Identity.Edition; Suite = $name; Verdict = (New-NotRunVerdict $catalogs[$name] 'motor Pester indisponivel'); Seconds = 0 }) }
            $executedEditions.Add($hostInfo.Identity.Edition)
            continue
        }
        foreach ($name in $selected) {
            $file = Get-SuiteFile $runRoot $name
            if ($Engine -eq 'Pester' -and $catalogs[$name].Determined -and -not $plans[$name].Determined) {
                # Forma fora do plano nativo: a suite nao e executada nem aprovada.
                $run = [pscustomobject]@{ Elapsed = [TimeSpan]::Zero; ExitCode = $null; ProcessesInJob = $null; StdOut = ''; StdErr = '' }
                $verdict = New-NotRunVerdict $catalogs[$name] ('plano nativo indeterminado: ' + (@($plans[$name].Problems) -join '; '))
                $verdict.Status = 'Inconclusiva'
            } elseif ($Engine -eq 'Pester') {
                $environment = @{ MA_PESTER_VERSION = [string]$requirement['RequiredVersion']; MA_PESTER_ADAPTER = $adapter; MA_PESTER_EXECUTOR = $executorFile; MA_PESTER_SUITE = $file }
                # Prazo da suite mais a carga do Pester.
                $run = Invoke-ChildProcess -FilePath $hostInfo.Path -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $pesterEncoded) -WorkingDirectory $work -TimeoutMilliseconds (($TimeoutMinutes + 5) * 60000) -Environment $environment
                $verdict = Get-PesterVerdict $run $catalogs[$name] ([string]$requirement['RequiredVersion'])
            } else {
                $run = Invoke-ChildProcess -FilePath $hostInfo.Path -Arguments @('-NoProfile', '-NonInteractive', '-File', $file) -WorkingDirectory $work -TimeoutMilliseconds ($TimeoutMinutes * 60000)
                $verdict = Get-SuiteVerdict $run $catalogs[$name]
            }
            $residue = @(Get-ChildItem -LiteralPath $work -Force)
            if ($residue.Count -gt 0) { $verdict.Status = 'Falha'; $verdict.Reason = (($verdict.Reason + ' gravou no diretorio de trabalho').Trim()) }
            $line = ('  {0,-31} {1,-12} {2,4} esperados: {3,4} ok {4,3} falhas {5,3} ignorados {6,3} pre-req {7,3} nao exec  {8,7:N1}s  saida {9}  processos {10}' -f
                $name, $verdict.Status, $verdict.Expected, $verdict.Passed, $verdict.Failed, $verdict.Skipped, $verdict.Blocked, $verdict.NotExecuted, $run.Elapsed.TotalSeconds, $run.ExitCode, $run.ProcessesInJob)
            if ($verdict.Reason) { $line += '  (' + $verdict.Reason + ')' }
            Write-Output $line
            if ($verdict.Status -ne 'Aprovada') {
                foreach ($detail in @($run.StdOut -split "`r?`n" | Where-Object { $_ -cmatch '\A  (?:\[FALHA\]|- |\[PRE-REQ\])' } | Select-Object -First 40)) { Write-Output ('      ' + $detail.Trim()) }
                foreach ($detail in @($verdict.Details | Select-Object -First 40)) { Write-Output ('      ' + $detail) }
                if ($run.StdErr.Trim()) { foreach ($detail in @($run.StdErr.Trim() -split "`r?`n" | Select-Object -First 10)) { Write-Output ('      stderr: ' + $detail) } }
            }
            if ($verdict.Status -eq 'Falha' -or $verdict.Status -eq 'Inconclusiva') { $script:Failures.Add($hostInfo.Identity.Edition + ' ' + $name + ': ' + $verdict.Status + ': ' + $verdict.Reason) }
            if ($verdict.Status -eq 'Pendente') { $script:Pending.Add($hostInfo.Identity.Edition + ' ' + $name + ': ' + $verdict.Reason) }
            $results.Add([pscustomobject]@{ Edition = $hostInfo.Identity.Edition; Suite = $name; Verdict = $verdict; Seconds = $run.Elapsed.TotalSeconds })
        }
        $executedEditions.Add($hostInfo.Identity.Edition)
    }
    $changes = @(Compare-Snapshot $rootBefore (Get-TreeSnapshot $runRoot))
    if ($changes.Count -gt 0) {
        $script:Failures.Add('raiz executada alterada pelas suites')
        Write-Output 'Raiz executada alterada pelas suites:'
        foreach ($change in ($changes | Select-Object -First 20)) { Write-Output ('  ' + $change) }
    }

    # Totais: soma das suites, por PowerShell.
    Write-Output ''
    Write-Output 'Totais'
    foreach ($edition in ($executedEditions | Select-Object -Unique)) {
        $items = @($results | Where-Object { $_.Edition -eq $edition })
        $sum = @{}
        foreach ($field in @('Expected', 'Passed', 'Failed', 'Skipped', 'Blocked', 'NotExecuted')) { $sum[$field] = [int](($items | ForEach-Object { $_.Verdict.$field } | Measure-Object -Sum).Sum) }
        $seconds = ($items | ForEach-Object { $_.Seconds } | Measure-Object -Sum).Sum
        Write-Output ('  {0}: {1} suites, {2} aprovadas; {3} casos esperados: {4} aprovados, {5} falhas, {6} ignorados, {7} bloqueados por pre-requisito, {8} nao executados; {9:N0}s' -f
            $edition, $items.Count, @($items | Where-Object { $_.Verdict.Status -eq 'Aprovada' }).Count, $sum.Expected, $sum.Passed, $sum.Failed, $sum.Skipped, $sum.Blocked, $sum.NotExecuted, $seconds)
    }

    # Cobertura dos criterios pelos resultados desta execucao.
    Write-Output ''
    Write-Output 'Cobertura dos criterios de aceitacao (secao 9), pelos casos das suites'
    foreach ($criterion in $Criteria) {
        $coverage = Get-CriterionState -Criterion $criterion -Selected $selected -Results $results -Editions @($executedEditions)
        # Criterio que exige os dois PowerShells nunca deixa o resultado geral aprovado.
        if ($coverage.Pending) { $script:Pending.Add($criterion.Id + ': ' + $coverage.State) }
        Write-Output ('  ' + $criterion.Id + '  ' + $criterion.Text)
        Write-Output ('        ' + $coverage.State)
    }
    $reachedEnd = $true
} catch {
    $reachedEnd = $true
    $script:Failures.Add('falha operacional do executor: ' + $_.Exception.Message)
    Write-Output ('Falha operacional do executor: ' + $_.Exception.Message)
} finally {
    # Parada do pipeline (Ctrl+C): nao passa por catch e a saida normal ja nao e
    # emitida; o estado dos encerramentos vai direto para o erro padrao. Termino
    # abrupto do executor nao chega aqui (KILL_ON_JOB_CLOSE, sem confirmacao).
    if (-not $reachedEnd) {
        $journal = Get-ProcessJournalSummary $script:ProcessJournal
        $interrupted = @(foreach ($item in $script:ProcessJournal) { if ($item.PipelineStopped) { $item } })
        $confirmed = @($interrupted | Where-Object { $_.Termination -eq 'Confirmado' }).Count
        [Console]::Error.WriteLine('Execucao interrompida (parada do pipeline, por exemplo Ctrl+C) antes do resultado: sem resultado geral; ' + $journal.Runs + ' execucoes em Job Object; ' +
            'processos em execucao na interrupcao: ' + $interrupted.Count + ' job(s), ' + $confirmed + ' com encerramento confirmado, ' + @($journal.Unconfirmed).Count + ' nao confirmados. Fixtures das suites interrompidas podem restar sob o TEMP.')
    }
    foreach ($root in $script:OwnedRoots) {
        if (-not [IO.Directory]::Exists($root)) { continue }
        if ($KeepPackage -and ([IO.Path]::GetFileName($root)).StartsWith('ma-pacote-')) { Write-Output ('Pacote isolado preservado: ' + $root); continue }
        Get-ChildItem -LiteralPath $root -Recurse -Force -File | ForEach-Object { $_.Attributes = 'Normal' }
        [IO.Directory]::Delete($root, $true)
    }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

# Processos: toda execucao contida; encerramento nao conferido e falha.
$journal = Get-ProcessJournalSummary $script:ProcessJournal
Write-Output ''
$reasons = ''; if ($journal.Reasons) { $reasons = ' (' + $journal.Reasons + ')' }
Write-Output ('Processos: ' + $journal.Runs + ' execucoes em Job Object, ' + $journal.Processes + ' processos nas arvores; ' + $journal.Stopped + ' encerramentos do job pelo executor' + $reasons + '; ' + @($journal.Unconfirmed).Count + ' nao confirmados')
foreach ($entry in $journal.Unconfirmed) { $script:Failures.Add('encerramento nao confirmado: ' + $entry.FilePath + ' (PID ' + $entry.ProcessId + ', ' + $entry.TerminationDetail + ')') }

Write-Output ''
foreach ($item in $script:Failures) { Write-Output ('FALHA: ' + $item) }
foreach ($item in $script:Pending) { Write-Output ('PENDENTE: ' + $item) }
if ($script:Failures.Count -gt 0) { Write-Output 'Resultado geral: FALHA'; exit 1 }
if ($script:Pending.Count -gt 0) { Write-Output 'Resultado geral: PENDENTE (nada falhou; compatibilidade, Pester 5 ou pre-requisito nao comprovado)'; exit 2 }
Write-Output 'Resultado geral: APROVADO'
exit 0
