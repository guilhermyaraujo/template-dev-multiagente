#Requires -Version 5.1
<#
Testes unitarios do executor central tests/Invoke-Tests.ps1. Autocontidos: nao
dependem de Pester. O executor e carregado por dot-sourcing, que define somente as
funcoes, sem obter a exclusao mutua nem executar suites. Fixtures sao descartaveis,
criadas sob o TEMP do executor e nunca apontam para o projeto atual. O Git real e
usado somente fora de repositorios (rev-parse --sq-quote) para conferir argumentos.
Nenhum caso usa WMI/CIM.

Processos: os casos de encerramento criam arvores descartaveis de PowerShell
(pai, filho e neto) que gravam PID e instante de criacao em arquivos da fixture;
o termino e conferido por esses registros, independentemente do executor. O
processo preexistente e criado pelo proprio caso, fora do job do executor, e
encerrado pelo caso ao final.

Uso: powershell -NoProfile -File tests/unit/InvokeTests.Unit.Tests.ps1
Codigo de saida: 0 quando todos os casos passam; 1 se algum caso falha.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PackageSource = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..'))
. ([IO.Path]::Combine($PackageSource, 'tests', 'Invoke-Tests.ps1'))
$Host5 = (Get-Process -Id $PID).Path
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:FixtureRoots = New-Object System.Collections.Generic.List[string]

# --- Mini-harness -----------------------------------------------------------------

function It {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Output ('  [ok]    ' + $Name) }
    catch { $script:Failed.Add($Name + ' :: ' + $_.Exception.Message); Write-Output ('  [FALHA] ' + $Name + ' :: ' + $_.Exception.Message) }
    finally { & (Get-ContainmentModule) { $script:MaNativeFaults = @{}; if ($script:MaNativeApi -is [bool]) { $script:MaNativeApi = $null } } }
}
function Assert-Equal { param($Expected, $Actual, [string]$Message = '') if (-not [object]::Equals($Expected, $Actual)) { throw ('esperado <' + $Expected + '> obtido <' + $Actual + '> ' + $Message) } }
function Assert-True { param([bool]$Condition, [string]$Message = 'condicao falsa') if (-not $Condition) { throw $Message } }

function New-Fixture {
    $root = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ma-exec-tests-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $script:FixtureRoots.Add($root)
    return $root
}

function Write-Text {
    param([string]$Path, [string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllBytes($Path, $Utf8.GetBytes($Text))
}

# Execucao simulada de uma suite: saida padrao, codigo de saida e estado do processo.
function New-Run {
    param([string[]]$Lines, $ExitCode, [switch]$TimedOut, [switch]$Truncated, [string]$Termination = 'JobVazio', [switch]$Persisted)
    return [pscustomobject]@{
        ExitCode = $ExitCode; StdOut = (($Lines -join "`r`n") + "`r`n"); StdErr = ''; TimedOut = [bool]$TimedOut; StreamsComplete = -not $Truncated; Elapsed = [TimeSpan]::Zero
        StartError = ''; Termination = $Termination; TerminationDetail = ''; Interrupted = $false; InterruptDetail = ''; Persisted = [bool]$Persisted; ProcessesInJob = 1
    }
}

function New-Catalog {
    param([string[]]$Names, [hashtable]$Requires = @{})
    return [pscustomobject]@{ Path = ''; Names = $Names; Determined = $true; Problems = @(); Requires = $Requires }
}

# Catalogo de um arquivo de suite escrito na fixture.
function Get-TextCatalog {
    param([string]$Text)
    $path = [IO.Path]::Combine((New-Fixture), 'suite.Tests.ps1')
    Write-Text $path $Text
    return (Get-SuiteCatalog $path)
}

# Arvore descartavel: pai -> filho -> neto, cada um grava '<PID>|<criacao UTC>' em
# <nivel>.pid. Modo: 'espera' (pai dorme), 'sai' (pai sai depois do neto existir,
# descendentes herdam os pipes) ou 'solto' (pai sai; filho iniciado por
# Start-Process, sem herdar os pipes).
function New-ProcessTree {
    $root = New-Fixture
    $record = { param([string]$Level) '$me = Get-Process -Id $PID; [IO.File]::WriteAllText([IO.Path]::Combine($args[0], ''' + $Level + '.pid''), [string]$PID + ''|'' + $me.StartTime.ToFileTimeUtc())' + "`n" }
    $start = '$i = New-Object Diagnostics.ProcessStartInfo($exe, $arguments); $i.UseShellExecute = $false; $i.CreateNoWindow = $true; [void][Diagnostics.Process]::Start($i)' + "`n"
    # neto.ps1 <dir>
    Write-Text ([IO.Path]::Combine($root, 'neto.ps1')) ((& $record 'neto') + "Start-Sleep -Seconds 120`n")
    # filho.ps1 <dir> <exe>
    Write-Text ([IO.Path]::Combine($root, 'filho.ps1')) ((& $record 'filho') +
        '$exe = $args[1]; $arguments = ''-NoProfile -NonInteractive -File "'' + [IO.Path]::Combine($args[0], ''neto.ps1'') + ''" "'' + $args[0] + ''"''' + "`n" + $start + "Start-Sleep -Seconds 120`n")
    # pai.ps1 <dir> <modo>
    Write-Text ([IO.Path]::Combine($root, 'pai.ps1')) ((& $record 'pai') +
        '$mode = $args[1]; $exe = (Get-Process -Id $PID).Path' + "`n" +
        '$arguments = ''-NoProfile -NonInteractive -File "'' + [IO.Path]::Combine($args[0], ''filho.ps1'') + ''" "'' + $args[0] + ''" "'' + $exe + ''"''' + "`n" +
        'if ($mode -eq ''solto'') { [void](Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru) } else {' + "`n" + $start + "}`n" +
        'Write-Output ''  [ok]    iniciado''' + "`n" +
        'if ($mode -eq ''espera'') { Start-Sleep -Seconds 120; exit 0 }' + "`n" +
        '$deadline = [DateTime]::UtcNow.AddSeconds(60); while (-not [IO.File]::Exists([IO.Path]::Combine($args[0], ''neto.pid'')) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }' + "`nexit 0`n")
    return $root
}

function Wait-TreeRecorded {
    param([string]$Root, [int]$Seconds = 60)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (@('pai', 'filho', 'neto' | Where-Object { [IO.File]::Exists([IO.Path]::Combine($Root, $_ + '.pid')) }).Count -eq 3) { return }
        Start-Sleep -Milliseconds 100
    }
    throw 'arvore descartavel nao registrada no prazo'
}

# Processo registrado e ainda ativo (mesmo PID e mesmo instante de criacao)?
function Test-RecordedAlive {
    param([string]$File)
    $parts = [IO.File]::ReadAllText($File).Split('|')
    $process = Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try { return (-not $process.HasExited -and $process.StartTime.ToFileTimeUtc() -eq [long]$parts[1]) } catch { return $false }
}

# Os tres niveis registrados e nenhum ativo. Sem espera: o executor ja conferiu.
function Assert-TreeGone {
    param([string]$Root, [int]$GraceSeconds = 0)
    $deadline = [DateTime]::UtcNow.AddSeconds($GraceSeconds)
    foreach ($level in @('pai', 'filho', 'neto')) {
        $file = [IO.Path]::Combine($Root, $level + '.pid')
        Assert-True ([IO.File]::Exists($file)) ('nivel nao registrado: ' + $level)
        while ((Test-RecordedAlive $file) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Assert-True (-not (Test-RecordedAlive $file)) ('processo ativo depois do encerramento: ' + $level)
    }
}

function Invoke-Tree {
    param([string]$Root, [string]$Mode, [int]$TimeoutMilliseconds, [scriptblock]$Interrupt = $null, [int]$DrainMilliseconds = 30000)
    return (Invoke-ChildProcess -FilePath $Host5 -Arguments @('-NoProfile', '-NonInteractive', '-File', [IO.Path]::Combine($Root, 'pai.ps1'), $Root, $Mode) -WorkingDirectory $Root -TimeoutMilliseconds $TimeoutMilliseconds -Interrupt $Interrupt -DrainMilliseconds $DrainMilliseconds)
}

# Processo descartavel de propriedade do caso, fora do job do executor.
function Start-Bystander {
    $info = New-Object Diagnostics.ProcessStartInfo($Host5, '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 120')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($info)
}
function Stop-Bystander { param($Process) if ($null -ne $Process -and -not $Process.HasExited) { $Process.Kill(); [void]$Process.WaitForExit(15000) } }

# Linhas do processo Pester para Get-PesterVerdict. Tests: @(caso, nome, resultado).
# Final: $null (resumo coerente com os testes), dicionario (substitui campos do
# resumo coerente) ou texto (resumo omitido). Extra: linhas adicionais.
function New-PesterRun {
    param([object[]]$Tests, $Final = $null, $ExitCode = $null, [string[]]$Extra = @(), [string]$Version = '5.7.1')
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Version) { $lines.Add('PESTER-VERSAO=' + $Version + ' C:\simulado\Pester.psd1') }
    foreach ($line in $Extra) { $lines.Add($line) }
    foreach ($test in $Tests) { $lines.Add('PESTER-CASO=' + (ConvertTo-Json -Compress -InputObject ([ordered]@{ Case = $test[0]; Name = $test[1]; Result = $test[2]; Message = '' }))) }
    $all = @($Tests)
    $count = { param([string]$Result) @($all | Where-Object { $_[2] -eq $Result }).Count }
    $summary = [ordered]@{ Result = 'Passed'; Total = $all.Count; Passed = (& $count 'Passed'); Failed = (& $count 'Failed'); Skipped = (& $count 'Skipped'); NotRun = (& $count 'NotRun')
        Inconclusive = (& $count 'Inconclusive'); FailedContainers = 0; FailedBlocks = 0 }
    if ($summary.Failed -gt 0) { $summary.Result = 'Failed' }
    if ($Final -is [System.Collections.IDictionary]) { foreach ($key in @($Final.Keys)) { $summary[$key] = $Final[$key] } }
    if ($Final -isnot [string]) { $lines.Add('PESTER-FIM=' + (ConvertTo-Json -Compress -InputObject $summary)) }
    if ($null -eq $ExitCode) { $ExitCode = 0; if ($summary.Result -ceq 'Failed') { $ExitCode = 1 } }
    return (New-Run $lines.ToArray() $ExitCode)
}

# Suite descartavel no formato das suites (preambulo, mini-harness, try/finally),
# para execucao nativa real pelo Pester. Grava marcas na propria pasta: corpo do
# caso a, finally do mini-harness por caso e finally da suite. O modulo dinamico
# le $Base pelo escopo global, como o codigo do instalador executado por InModule.
function New-NativeFixtureSuite {
    $root = New-Fixture
    $path = [IO.Path]::Combine($root, 'Nativa.Unit.Tests.ps1')
    Write-Text $path (@(
            'Set-StrictMode -Version 2.0'
            '$ErrorActionPreference = ''Stop'''
            '$Marker = [IO.Path]::Combine($PSScriptRoot, ''marcas.txt''); $Base = ''valor do preambulo'''
            '$script:Passed = 0'
            '$Probe = New-Module -ScriptBlock { function Get-Base { $Base } }'
            'function It {'
            '    param([string]$Name, [scriptblock]$Body)'
            '    try { & $Body; $script:Passed++ } catch { Write-Output (''  [FALHA] '' + $Name) }'
            '    finally { [IO.File]::AppendAllText($Marker, (''fim '' + $Name + "`n")) }'
            '}'
            'try {'
            '    Write-Output ''Casos'''
            '    It ''a'' { [IO.File]::AppendAllText($Marker, "a`n"); if ((& $Probe { Get-Base }) -ne ''valor do preambulo'') { throw ''global'' } }'
            '    foreach ($x in @(''p'', ''q'')) { It (''b '' + $x) { if ($env:MA_FALHAR_CASO -eq $x) { throw (''falha simulada '' + $x) } } }'
            '} finally {'
            '    [IO.File]::AppendAllText($Marker, "limpeza`n")'
            '    if ($env:MA_FALHAR_LIMPEZA) { throw ''limpeza da suite falhou'' }'
            '}'
            'Write-Output (''Resultado: '' + $script:Passed + '' aprovados, 0 falhas'')'
            'exit 0'
        ) -join "`n")
    return $path
}

# Executa uma suite pelo processo Pester real do executor (versao fixada no pacote).
function Invoke-NativePester {
    param([string]$SuiteFile, [hashtable]$Environment = @{})
    $requirement = Read-PesterRequirement $PackageSource
    $variables = @{ MA_PESTER_VERSION = [string]$requirement['RequiredVersion']; MA_PESTER_ADAPTER = [IO.Path]::Combine($PackageSource, 'tests', 'pester', 'NativeSuite.Tests.ps1')
        MA_PESTER_EXECUTOR = [IO.Path]::Combine($PackageSource, 'tests', 'Invoke-Tests.ps1'); MA_PESTER_SUITE = $SuiteFile }
    foreach ($key in $Environment.Keys) { $variables[$key] = $Environment[$key] }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($PesterProbe))
    return (Invoke-ChildProcess -FilePath $Host5 -Arguments @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -WorkingDirectory ([IO.Path]::GetDirectoryName($SuiteFile)) -TimeoutMilliseconds 300000 -Environment $variables)
}

# Plano de um arquivo de suite escrito na fixture.
function Get-TextPlan {
    param([string]$Text)
    $path = [IO.Path]::Combine((New-Fixture), 'suite.Tests.ps1')
    Write-Text $path $Text
    return (Get-SuitePlan $path)
}

# --- Casos ------------------------------------------------------------------------

Write-Output 'Executor central (tests/Invoke-Tests.ps1)'
try {
    It 'dot-sourcing define as funcoes e nao alcanca a execucao (selecao, exclusao mutua e resultados ausentes)' {
        foreach ($name in @('Invoke-ChildProcess', 'Get-SuiteVerdict', 'Get-SuiteCatalog', 'Get-SuitePlan', 'Get-PesterVerdict', 'Test-PesterRequirement', 'New-IsolatedPackage', 'Get-TreeSnapshot', 'Get-PackageInventory')) { Assert-True ($null -ne (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue)) ('ausente: ' + $name) }
        foreach ($name in @('selected', 'mutex', 'results')) { Assert-True ($null -eq (Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue)) ('execucao alcancada: ' + $name) }
        Assert-Equal 9 @($SuiteNames).Count 'suites conhecidas'
        foreach ($name in $SuiteNames) { Assert-True ([IO.File]::Exists((Get-SuiteFile $PackageSource $name))) ('arquivo da suite ausente: ' + $name) }
    }

    Write-Output 'Completude: catalogo de casos pela AST'
    It 'catalogo das nove suites determinado, sem nomes repetidos; laco literal de Plan.Unit expandido por item' {
        $total = 0
        foreach ($name in $SuiteNames) {
            $catalog = Get-SuiteCatalog (Get-SuiteFile $PackageSource $name)
            Assert-True $catalog.Determined ($name + ': ' + (@($catalog.Problems) -join '; '))
            Assert-True (@($catalog.Names).Count -gt 0) ($name + ' sem casos')
            $total += @($catalog.Names).Count
        }
        $plan = @((Get-SuiteCatalog (Get-SuiteFile $PackageSource 'Plan.Unit')).Names)
        foreach ($point in @('JobLimitSet', 'JobLimitQuery')) { Assert-Equal 1 @($plan | Where-Object { $_ -ceq ('limite do job nao confirmado (' + $point + ' simulado): nenhum processo criado') }).Count $point }
        Assert-True ($total -gt 0) 'total'
    }

    It 'catalogo: nomes literais e lacos aninhados sobre listas literais, na ordem do arquivo' {
        $catalog = Get-TextCatalog ("It 'a' { }`nforeach (`$x in @('p', 'q')) { foreach (`$y in 'r', 's') { It ('c ' + `$x + `$y) { } } }`nIt `"b`" { }`n")
        Assert-True $catalog.Determined (@($catalog.Problems) -join '; ')
        Assert-Equal 'a|c pr|c ps|c qr|c qs|b' (@($catalog.Names) -join '|')
        Assert-Equal 'x=q;y=r' ((@($catalog.Cases[3].Bindings.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Key + '=' + $_.Value })) -join ';') 'variaveis do laco'
    }

    It 'suites compativeis com o PowerShell 7: nenhuma variavel de ambiente limpa ou restaurada com $null (vira vazia no 7); [NullString] remove' {
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($name in $SuiteNames) {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Get-SuiteFile $PackageSource $name), [ref]$tokens, [ref]$errors)
            foreach ($call in @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -ceq 'SetEnvironmentVariable' }, $true))) {
                $value = @($call.Arguments)[1]
                if ($value -is [Management.Automation.Language.VariableExpressionAst] -and $value.VariablePath.UserPath -eq 'null') { $offenders.Add($name + ':' + $call.Extent.StartLineNumber) }
            }
        }
        Assert-Equal '' ($offenders -join ', ') 'restauracao com $null'
        [Environment]::SetEnvironmentVariable('MA_EXEC_TESTE_NULO', 'x')
        [Environment]::SetEnvironmentVariable('MA_EXEC_TESTE_NULO', [NullString]::Value)
        Assert-True ($null -eq [Environment]::GetEnvironmentVariable('MA_EXEC_TESTE_NULO')) 'variavel nao removida'
    }

    It 'catalogo: pre-requisitos -Requires somente literais, por caso; sem -Requires, lista vazia' {
        $catalog = Get-TextCatalog "It 'a' -Requires Git, Job { }`nIt 'b' -Requires Sh { }`nIt 'c' { }`n"
        Assert-True $catalog.Determined (@($catalog.Problems) -join '; ')
        Assert-Equal 'Git,Job' (@($catalog.Requires['a']) -join ',')
        Assert-Equal 'Sh' (@($catalog.Requires['b']) -join ',')
        Assert-Equal 0 @($catalog.Requires['c']).Count
        foreach ($text in @("It 'a' -Requires `$lista { }", "It 'a' -Requires (Get-Lista) { }", "It 'a' -Requires Git, `$x { }")) {
            $bad = Get-TextCatalog $text
            Assert-True (-not $bad.Determined) ('aceito: ' + $text)
            Assert-True ((@($bad.Problems) -join ';').Contains('pre-requisito nao literal')) (@($bad.Problems) -join ';')
        }
    }

    It 'catalogo indeterminado: It em condicional, funcao, bloco de script, while, catch, nome nao literal, repetido, sintaxe ou nenhum caso' {
        $cases = @(
            "if (`$true) { It 'a' { } }",
            "function F { It 'a' { } }",
            "& { It 'a' { } }",
            "1..2 | ForEach-Object { It 'a' { } }",
            "while (`$false) { It 'a' { } }",
            "try { } catch { It 'a' { } }",
            "It `"a `$x`" { }",
            "It (Get-Name) { }",
            "foreach (`$x in `$lista) { It ('a' + `$x) { } }",
            "It -Name 'a' { }",
            "It 'a' { }`nIt 'a' { }",
            "foreach (`$x in 'p', 'p') { It ('a' + `$x) { } }",
            "It 'a' {",
            "Write-Output 'sem casos'"
        )
        foreach ($text in $cases) {
            $catalog = Get-TextCatalog $text
            Assert-True (-not $catalog.Determined) ('aceito: ' + $text)
            Assert-True (@($catalog.Problems).Count -gt 0) ('sem motivo: ' + $text)
        }
        Assert-True (-not (Get-SuiteCatalog ([IO.Path]::Combine((New-Fixture), 'ausente.ps1'))).Determined) 'arquivo ausente'
    }

    Write-Output 'Completude: veredito confrontado com o catalogo'
    It 'suite aprovada: cada caso esperado uma vez, resumo e codigo 0 concordantes; tempo em [ok] aceito' {
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', '  [ok]    b (12 s)', '', 'Resultado: 2 aprovados, 0 falhas') 0) (New-Catalog @('a', 'b'))
        Assert-Equal 'Aprovada' $v.Status $v.Reason
        Assert-Equal 2 $v.Passed; Assert-Equal 2 $v.Expected; Assert-Equal 0 $v.NotExecuted; Assert-Equal 0 $v.Skipped
        Assert-Equal 'Aprovado' $v.Cases['b']
    }

    It 'sucesso falso: codigo 0 e resumo coerente com as linhas, mas caso esperado ausente: Inconclusiva e caso identificado' {
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', '  [ok]    b', '', 'Resultado: 2 aprovados, 0 falhas') 0) (New-Catalog @('a', 'b', 'c'))
        Assert-Equal 'Inconclusiva' $v.Status
        Assert-True ($v.Reason.StartsWith('execucao incompleta: 1 nao executados')) $v.Reason
        Assert-Equal 1 $v.NotExecuted; Assert-Equal 2 $v.Passed
        Assert-Equal 'NaoExecutado' $v.Cases['c']
        Assert-True (@($v.Details) -contains 'nao executado: c') (@($v.Details) -join ', ')
    }

    It 'truncamento real: suite que emite resumo coerente e sai com 0 antes do ultimo caso: Inconclusiva' {
        $root = New-Fixture
        $suite = [IO.Path]::Combine($root, 'truncada.Tests.ps1')
        Write-Text $suite ("function It { param([string]`$Name, [scriptblock]`$Body) & `$Body; Write-Output ('  [ok]    ' + `$Name) }`n" +
            "It 'a' { }`nIt 'b' { }`nWrite-Output ''`nWrite-Output 'Resultado: 2 aprovados, 0 falhas'`nexit 0`nIt 'c' { }`n")
        $catalog = Get-SuiteCatalog $suite
        Assert-Equal 'a|b|c' (@($catalog.Names) -join '|')
        $run = Invoke-ChildProcess -FilePath $Host5 -Arguments @('-NoProfile', '-NonInteractive', '-File', $suite) -WorkingDirectory $root -TimeoutMilliseconds 120000
        Assert-Equal 0 $run.ExitCode $run.StdErr
        $v = Get-SuiteVerdict $run $catalog
        Assert-Equal 'Inconclusiva' $v.Status $v.Reason
        Assert-Equal 1 $v.NotExecuted
        Assert-Equal 'NaoExecutado' $v.Cases['c']
    }

    It 'duplicidade e caso nao catalogado: Inconclusiva, mesmo com resumo que soma as linhas' {
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', '  [ok]    a', '', 'Resultado: 2 aprovados, 0 falhas') 0) (New-Catalog @('a', 'b'))
        Assert-Equal 'Inconclusiva' $v.Status
        Assert-Equal 1 $v.Duplicated; Assert-Equal 'Duplicado' $v.Cases['a']
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', '  [ok]    b', '  [ok]    intruso', '', 'Resultado: 3 aprovados, 0 falhas') 0) (New-Catalog @('a', 'b'))
        Assert-Equal 'Inconclusiva' $v.Status
        Assert-Equal 1 $v.Unexpected
        Assert-True (@($v.Details) -contains 'nao catalogado: [ok]    intruso') (@($v.Details) -join ', ')
    }

    It 'ausencia de casos: nenhuma linha, ou catalogo vazio/indeterminado: nunca aprovada' {
        $v = Get-SuiteVerdict (New-Run @('', 'Resultado: 0 aprovados, 0 falhas') 0) (New-Catalog @('a'))
        Assert-Equal 'Inconclusiva' $v.Status; Assert-Equal 1 $v.NotExecuted
        $empty = [pscustomobject]@{ Path = ''; Names = @(); Determined = $false; Problems = @('nenhum caso') }
        $v = Get-SuiteVerdict (New-Run @('', 'Resultado: 0 aprovados, 0 falhas') 0) $empty
        Assert-Equal 'Inconclusiva' $v.Status; Assert-True ($v.Reason.Contains('nenhum caso')) $v.Reason
        $undetermined = [pscustomobject]@{ Path = ''; Names = @('a'); Determined = $false; Problems = @('It em IfStatementAst (linha 3)') }
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', 'Resultado: 1 aprovados, 0 falhas') 0) $undetermined
        Assert-Equal 'Inconclusiva' $v.Status; Assert-True ($v.Reason.Contains('indeterminados')) $v.Reason
    }

    It 'casos com falha: codigo 1 e Falha; nome identificado mesmo com '' :: '' no nome (o mais longo)' {
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', '  [FALHA] b :: c :: x', '', 'Resultado: 1 aprovados, 1 falhas', '  - b :: c :: x') 1) (New-Catalog @('a', 'b', 'b :: c'))
        Assert-Equal 'Inconclusiva' $v.Status 'b nao executado'
        Assert-Equal 'Falha' $v.Cases['b :: c']
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', '  [FALHA] b :: x', '', 'Resultado: 1 aprovados, 1 falhas', '  - b :: x') 1) (New-Catalog @('a', 'b'))
        Assert-Equal 'Falha' $v.Status; Assert-Equal 'casos com falha' $v.Reason; Assert-Equal 1 $v.Failed
    }

    It 'pre-requisito por caso: Pendente somente com [PRE-REQ], resumo e lista final concordantes' {
        $lines = @('  [ok]    a', '  [PRE-REQ] b :: ausente: Git', '', 'Resultado: 1 aprovados, 0 falhas, 1 nao executados por pre-requisito', '  - [PRE-REQ] b :: ausente: Git')
        $v = Get-SuiteVerdict (New-Run $lines 2) (New-Catalog @('a', 'b'))
        Assert-Equal 'Pendente' $v.Status $v.Reason; Assert-Equal 1 $v.Blocked; Assert-Equal 0 $v.NotExecuted; Assert-Equal 'PreRequisito' $v.Cases['b']
        # Resumo declara bloqueio sem a linha [PRE-REQ] do caso.
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', '', 'Resultado: 1 aprovados, 0 falhas, 1 nao executados por pre-requisito', '  - [PRE-REQ] b :: ausente: Git') 2) (New-Catalog @('a', 'b'))
        Assert-Equal 'Inconclusiva' $v.Status $v.Reason
        # Linha [PRE-REQ] sem contagem no resumo.
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', '  [PRE-REQ] b :: ausente: Git', '', 'Resultado: 1 aprovados, 0 falhas, 0 nao executados por pre-requisito') 2) (New-Catalog @('a', 'b'))
        Assert-Equal 'Inconclusiva' $v.Status $v.Reason
        # Lista final aponta outro caso.
        $v = Get-SuiteVerdict (New-Run @('  [ok]    a', '  [PRE-REQ] b :: ausente: Git', '', 'Resultado: 1 aprovados, 0 falhas, 1 nao executados por pre-requisito', '  - [PRE-REQ] a :: ausente: Git') 2) (New-Catalog @('a', 'b'))
        Assert-Equal 'Inconclusiva' $v.Status; Assert-True ($v.Reason.Contains('[PRE-REQ]')) $v.Reason
        # Bloqueio com codigo 0 nunca e aprovado.
        $v = Get-SuiteVerdict (New-Run $lines 0) (New-Catalog @('a', 'b'))
        Assert-Equal 'Falha' $v.Status $v.Reason
    }

    It 'suite bloqueada por pre-requisito: todos os casos bloqueados; com linhas de caso ou codigo diferente de 2, nunca pendente' {
        $blocked = @('  [PRE-REQ] ausente: Git', 'Resultado: 0 aprovados, 0 falhas; suite nao executada por pre-requisito ausente')
        $v = Get-SuiteVerdict (New-Run $blocked 2) (New-Catalog @('a', 'b'))
        Assert-Equal 'Pendente' $v.Status $v.Reason; Assert-True $v.SuiteBlocked 'suite bloqueada'; Assert-Equal 2 $v.Blocked; Assert-Equal 0 $v.NotExecuted
        $v = Get-SuiteVerdict (New-Run $blocked 0) (New-Catalog @('a', 'b'))
        Assert-Equal 'Falha' $v.Status $v.Reason
        $v = Get-SuiteVerdict (New-Run (@('  [ok]    a') + $blocked) 2) (New-Catalog @('a', 'b'))
        Assert-Equal 'Inconclusiva' $v.Status $v.Reason
        $v = Get-SuiteVerdict (New-Run @('Resultado: 0 aprovados, 0 falhas; suite nao executada por pre-requisito ausente') 2) (New-Catalog @('a'))
        Assert-Equal 'Inconclusiva' $v.Status 'sem pre-requisito identificado'
    }

    It 'codigo de saida incompativel com o resumo: Falha' {
        foreach ($pair in @(
                @(@('  [FALHA] a :: x', 'Resultado: 0 aprovados, 1 falhas'), 0),
                @(@('  [ok]    a', 'Resultado: 1 aprovados, 0 falhas'), 1),
                @(@('  [ok]    a', 'Resultado: 1 aprovados, 0 falhas'), 2),
                @(@('  [ok]    a', 'Resultado: 1 aprovados, 0 falhas'), 4))) {
            $v = Get-SuiteVerdict (New-Run $pair[0] $pair[1]) (New-Catalog @('a'))
            Assert-Equal 'Falha' $v.Status ('saida ' + $pair[1])
        }
    }

    It 'resumo divergente, ausente, malformado, repetido ou com caso depois dele: nunca aprovada' {
        foreach ($lines in @(
                @('  [ok]    a', 'Resultado: 2 aprovados, 0 falhas'),
                @('  [ok]    a'),
                @('  [ok]    a', 'Resultado: tudo certo'),
                @('  [ok]    a', 'Resultado: 1 aprovados, 0 falhas', 'Resultado: 1 aprovados, 0 falhas'),
                @('Resultado: 0 aprovados, 0 falhas', '  [ok]    a'))) {
            $v = Get-SuiteVerdict (New-Run $lines 0) (New-Catalog @('a'))
            Assert-Equal 'Inconclusiva' $v.Status ($lines -join ' / ')
        }
    }

    It 'prazo, saida incompleta, descendente persistente ou encerramento nao confirmado: Falha mesmo com resultado favoravel' {
        $lines = @('  [ok]    a', 'Resultado: 1 aprovados, 0 falhas')
        $v = Get-SuiteVerdict (New-Run $lines $null -TimedOut -Termination 'Confirmado') (New-Catalog @('a'))
        Assert-Equal 'Falha' $v.Status; Assert-True ($v.Reason.StartsWith('prazo excedido')) $v.Reason
        $v = Get-SuiteVerdict (New-Run $lines 0 -Truncated) (New-Catalog @('a'))
        Assert-Equal 'Falha' $v.Status; Assert-Equal 'saida nao concluida' $v.Reason
        $v = Get-SuiteVerdict (New-Run $lines 0 -Persisted -Termination 'Confirmado') (New-Catalog @('a'))
        Assert-Equal 'Falha' $v.Status; Assert-True ($v.Reason.StartsWith('processo descendente ativo')) $v.Reason
        $v = Get-SuiteVerdict (New-Run $lines $null -TimedOut -Termination 'NaoConfirmado') (New-Catalog @('a'))
        Assert-Equal 'Falha' $v.Status; Assert-True ($v.Reason.StartsWith('encerramento dos processos nao confirmado')) $v.Reason
    }

    Write-Output 'Processos contidos em Job Object'
    It 'argumentos com espacos, aspas, barras finais, apostrofo e vazio chegam literais ao processo' {
        $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $values = @('a b', 'com"aspas', 'barra final\', 'C:\dir com espaco\', '', 'x\\"y', "apostrofo'", '$env:PATH', '&;|<>')
        $root = New-Fixture
        $result = Invoke-ChildProcess -FilePath $git.Path -Arguments (@('rev-parse', '--sq-quote') + $values) -WorkingDirectory $root -TimeoutMilliseconds 30000
        Assert-Equal 0 $result.ExitCode $result.StdErr
        $expected = (($values | ForEach-Object { " '" + $_.Replace("'", "'\''") + "'" }) -join '')
        Assert-Equal $expected ($result.StdOut.TrimEnd("`r", "`n"))
    }

    It 'processo real: codigo de saida, saida padrao, erro e ambiente; job conferido vazio no fim normal' {
        $root = New-Fixture
        $suite = [IO.Path]::Combine($root, 'suite.ps1')
        Write-Text $suite "Write-Output '  [ok]    a'`nWrite-Output '  [FALHA] b :: x'`nWrite-Output 'Resultado: 1 aprovados, 1 falhas'`n[Console]::Error.WriteLine('erro ' + `$env:MA_TESTE_VALOR)`nexit 1`n"
        $run = Invoke-ChildProcess -FilePath $Host5 -Arguments @('-NoProfile', '-NonInteractive', '-File', $suite) -WorkingDirectory $root -TimeoutMilliseconds 120000 -Environment @{ MA_TESTE_VALOR = 'com espaco & aspas"' }
        Assert-Equal 1 $run.ExitCode
        Assert-True ($run.StdErr.Contains('erro com espaco & aspas"')) $run.StdErr
        Assert-Equal 'JobVazio' $run.Termination; Assert-True $run.Contained 'contido'; Assert-Equal 0 $run.ActiveAtEnd
        Assert-True ($run.ProcessesInJob -ge 1) 'processos no job'
        $v = Get-SuiteVerdict $run (New-Catalog @('a', 'b'))
        Assert-Equal 'Falha' $v.Status; Assert-Equal 1 $v.Passed; Assert-Equal 1 $v.Failed
    }

    It 'prazo: pai, filho e neto encerrados e conferidos; saida parcial preservada; processo preexistente fora do job intacto' {
        $root = New-ProcessTree
        $bystander = Start-Bystander
        try {
            $run = Invoke-Tree $root 'espera' 15000
            Assert-True $run.TimedOut 'prazo'
            Assert-Equal 'Confirmado' $run.Termination $run.TerminationDetail
            Assert-Equal 'prazo' $run.StopReason
            Assert-Equal 0 $run.ActiveAtEnd
            Assert-True ($run.ProcessesInJob -ge 3) ('processos no job: ' + $run.ProcessesInJob)
            Assert-True ($run.Elapsed.TotalSeconds -lt 60) ('encerramento tardio: ' + $run.Elapsed.TotalSeconds)
            Assert-TreeGone $root
            Assert-True ($run.StdOut.Contains('  [ok]    iniciado')) 'saida parcial perdida'
            Assert-True (-not $bystander.HasExited) 'processo fora do job encerrado'
            $v = Get-SuiteVerdict $run (New-Catalog @('iniciado', 'seguinte'))
            Assert-Equal 'Falha' $v.Status; Assert-Equal 1 $v.Passed; Assert-Equal 1 $v.NotExecuted
        } finally { Stop-Bystander $bystander }
    }

    It 'descendente ativo depois do fim do processo principal (com e sem os pipes herdados): encerrado, conferido e Falha' {
        foreach ($mode in @('sai', 'solto')) {
            $root = New-ProcessTree
            $run = Invoke-Tree $root $mode 120000 -DrainMilliseconds 3000
            Assert-Equal 0 $run.ExitCode ($mode + ': ' + $run.StdErr)
            Assert-True $run.Persisted ($mode + ': descendente nao detectado')
            Assert-Equal 'Confirmado' $run.Termination ($mode + ': ' + $run.TerminationDetail)
            Assert-True ($run.StopReason -in @('saida retida por descendente', 'descendente ativo')) ($mode + ': ' + $run.StopReason)
            Assert-TreeGone $root
            Assert-Equal 'Falha' (Get-SuiteVerdict $run (New-Catalog @('iniciado'))).Status $mode
        }
    }

    It 'interrupcao controlada do executor: erro propagado, arvore encerrada e conferida antes do retorno' {
        $root = New-ProcessTree
        $bystander = Start-Bystander
        try {
            $before = $script:ProcessJournal.Count
            $raised = $null
            # O bloco executa na sessao deste arquivo: le a raiz pelo escopo de script.
            $script:TreeRoot = $root
            try { [void](Invoke-Tree $root 'espera' 120000 -Interrupt { param($Entry) Wait-TreeRecorded $script:TreeRoot; throw 'interrupcao controlada' }) }
            catch { $raised = $_.Exception.Message }
            Assert-Equal 'interrupcao controlada' $raised
            $entry = $script:ProcessJournal[$before]
            Assert-True $entry.Interrupted 'interrupcao registrada'
            Assert-Equal 'interrupcao controlada' $entry.StopReason
            Assert-True (-not $entry.PipelineStopped) 'confundida com parada do pipeline'
            Assert-Equal 'Confirmado' $entry.Termination $entry.TerminationDetail
            Assert-TreeGone $root
            Assert-True (-not $bystander.HasExited) 'processo fora do job encerrado'
        } finally { Stop-Bystander $bystander }
    }

    It 'encerramento nao confirmavel (TerminateJobObject recusado, simulado): NaoConfirmado, Falha e registro; nunca limpeza concluida' {
        $root = New-ProcessTree
        & (Get-ContainmentModule) { $script:MaNativeFaults['TerminateJobObject'] = { $true } }
        $run = Invoke-Tree $root 'espera' 15000
        & (Get-ContainmentModule) { $script:MaNativeFaults = @{} }
        Assert-True $run.TimedOut 'prazo'
        Assert-Equal 'NaoConfirmado' $run.Termination
        Assert-True ($run.TerminationDetail.Contains('MA_NATIVE_TERMINATION_UNCONFIRMED') -and $run.TerminationDetail.Contains('TerminateJobObject')) $run.TerminationDetail
        $v = Get-SuiteVerdict $run (New-Catalog @('iniciado'))
        Assert-Equal 'Falha' $v.Status; Assert-True ($v.Reason.StartsWith('encerramento dos processos nao confirmado')) $v.Reason
        $summary = Get-ProcessJournalSummary @($run)
        Assert-Equal 1 @($summary.Unconfirmed).Count
        # O fechamento do job (KILL_ON_JOB_CLOSE) ainda encerra a arvore; isso nao vira confirmacao.
        Assert-TreeGone $root 15
    }

    It 'contencao indisponivel: nenhum processo criado e chamada sem resultado' {
        $root = New-Fixture
        $marker = [IO.Path]::Combine($root, 'executou.txt')
        & (Get-ContainmentModule) { $script:MaNativeApi = $false }
        $run = Invoke-ChildProcess -FilePath $Host5 -Arguments @('-NoProfile', '-NonInteractive', '-Command', ('Set-Content -LiteralPath ''' + $marker + ''' -Value x')) -WorkingDirectory $root -TimeoutMilliseconds 60000
        & (Get-ContainmentModule) { $script:MaNativeApi = $null }
        Assert-Equal 'MA_NATIVE_CONTAINMENT_UNAVAILABLE' $run.StartError
        Assert-Equal 'NaoIniciado' $run.Termination
        Assert-True (-not $run.Contained) 'contido'
        Start-Sleep -Milliseconds 500
        Assert-True (-not [IO.File]::Exists($marker)) 'processo executou sem contencao'
        Assert-Equal 'Falha' (Get-SuiteVerdict $run (New-Catalog @('a'))).Status
    }

    It 'registro de processos (List[object], como no executor): totais de execucoes, processos e encerramentos' {
        $items = New-Object System.Collections.Generic.List[object]
        $items.Add([pscustomobject]@{ ProcessesInJob = 3; StopReason = 'prazo'; Termination = 'Confirmado' })
        $items.Add([pscustomobject]@{ ProcessesInJob = 2; StopReason = ''; Termination = 'JobVazio' })
        $items.Add([pscustomobject]@{ ProcessesInJob = $null; StopReason = ''; Termination = 'NaoIniciado' })
        $items.Add([pscustomobject]@{ ProcessesInJob = 4; StopReason = 'parada do pipeline (Ctrl+C)'; Termination = 'Confirmado' })
        $summary = Get-ProcessJournalSummary $items
        Assert-Equal 4 $summary.Runs; Assert-Equal 9 $summary.Processes; Assert-Equal 2 $summary.Stopped; Assert-Equal 0 @($summary.Unconfirmed).Count
        Assert-Equal 'parada do pipeline (Ctrl+C) 1, prazo 1' $summary.Reasons
    }

    It 'parada do pipeline (efeito do Ctrl+C): atendida durante a espera, arvore encerrada e conferida antes do retorno; motivo distinto' {
        $root = New-ProcessTree
        $bystander = Start-Bystander
        $journal = New-Object System.Collections.Generic.List[object]
        $shell = [powershell]::Create()
        try {
            # Mesmo mecanismo do Ctrl+C no console: o host para o pipeline em execucao.
            [void]$shell.AddScript('param($Executor, $HostPath, $Root, $Journal) . $Executor; $script:ProcessJournal = $Journal; [void](Invoke-ChildProcess -FilePath $HostPath -Arguments @(''-NoProfile'', ''-NonInteractive'', ''-File'', [IO.Path]::Combine($Root, ''pai.ps1''), $Root, ''espera'') -WorkingDirectory $Root -TimeoutMilliseconds 600000)')
            [void]$shell.AddArgument([IO.Path]::Combine($PackageSource, 'tests', 'Invoke-Tests.ps1')).AddArgument($Host5).AddArgument($root).AddArgument($journal)
            $pending = $shell.BeginInvoke()
            Wait-TreeRecorded $root
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $shell.Stop()
            Assert-True ($clock.Elapsed.TotalSeconds -lt 30) ('parada tardia: ' + $clock.Elapsed.TotalSeconds + ' s (prazo da suite: 600 s)')
            Assert-Equal 'Stopped' ([string]$shell.InvocationStateInfo.State)
            Assert-True $pending.IsCompleted 'pipeline concluido'
            Assert-Equal 1 $journal.Count
            $entry = $journal[0]
            Assert-True $entry.PipelineStopped 'parada registrada'
            Assert-Equal 'parada do pipeline (Ctrl+C)' $entry.StopReason
            Assert-True (-not $entry.Interrupted -and -not $entry.TimedOut) 'confundida com interrupcao controlada ou prazo'
            Assert-Equal 'Confirmado' $entry.Termination $entry.TerminationDetail
            Assert-Equal 0 $entry.ActiveAtEnd
            Assert-TreeGone $root
            Assert-True (-not $bystander.HasExited) 'processo fora do job encerrado'
        } finally { $shell.Dispose(); Stop-Bystander $bystander }
    }

    Write-Output 'Pester 5: requisito fixado e motor preparado'
    It 'requisito: somente versao exata de Pester 5 fixada e instalada fica disponivel; nada e escolhido no lugar' {
        $base = @{ ModuleName = 'Pester'; MajorVersion = 5; RequiredVersion = '' }
        Assert-Equal 'NaoFixada' (Test-PesterRequirement $base @('5.7.1', '3.4.0')).State 'nao fixada com Pester 5 instalado'
        foreach ($bad in @('4.10.1', '5.7', '5', '5.7.1.0', '5.7.1-beta', 'v5.7.1', '6.0.0')) {
            $requirement = $base.Clone(); $requirement.RequiredVersion = $bad
            Assert-Equal 'ForaDoContrato' (Test-PesterRequirement $requirement @($bad)).State $bad
        }
        foreach ($other in @(@{ ModuleName = 'pester'; MajorVersion = 5; RequiredVersion = '5.7.1' }, @{ ModuleName = 'Pester'; MajorVersion = 4; RequiredVersion = '5.7.1' })) {
            Assert-Equal 'ForaDoContrato' (Test-PesterRequirement $other @('5.7.1')).State ($other.ModuleName + ' ' + $other.MajorVersion)
        }
        $pinned = $base.Clone(); $pinned.RequiredVersion = '5.7.1'
        $absent = Test-PesterRequirement $pinned @('5.6.1', '3.4.0')
        Assert-Equal 'Ausente' $absent.State; Assert-True ($absent.Text.Contains('5.6.1, 3.4.0')) $absent.Text
        Assert-Equal 'Ausente' (Test-PesterRequirement $pinned @()).State
        Assert-Equal 'Disponivel' (Test-PesterRequirement $pinned @('5.6.1', '5.7.1')).State
    }

    It 'requisito distribuido: lido como dados, Pester 5 com versao exata 5.7.1 fixada' {
        $requirement = Read-PesterRequirement $PackageSource
        Assert-Equal 'Pester' $requirement['ModuleName']; Assert-Equal 5 $requirement['MajorVersion']
        Assert-Equal '5.7.1' $requirement['RequiredVersion']
        Assert-Equal 'Ausente' (Test-PesterRequirement $requirement @('5.6.1', '3.4.0')).State
        Assert-Equal 'Disponivel' (Test-PesterRequirement $requirement @('5.7.1', '3.4.0')).State
    }

    It 'adaptador nativo: sintaxe valida, parametros iguais aos dados do processo Pester, um It por caso e versao fixada na importacao' {
        $path = [IO.Path]::Combine($PackageSource, 'tests', 'pester', 'NativeSuite.Tests.ps1')
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        Assert-Equal 0 @($errors).Count 'sintaxe'
        $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } | Sort-Object)
        $data = @([regex]::Matches($PesterProbe, '(\w+) = \$env:MA_PESTER_') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        Assert-Equal 'Executor,SuiteFile' ($data -join ',')
        Assert-Equal ($data -join ',') ($parameters -join ',')
        $its = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'It' }, $true) | ForEach-Object { $_.CommandElements[1].Value })
        Assert-Equal '<MaCaseName>' ($its -join '|')
        foreach ($expected in @("Contains('MaCaseName')", '-RequiredVersion $MaPesterRequired', 'TestDrive.Enabled = $false', 'TestRegistry.Enabled = $false')) { Assert-True ($PesterProbe.Contains($expected)) ('processo Pester sem: ' + $expected) }
    }

    It 'plano nativo das nove suites: determinado, mesmos casos do catalogo, um bloco por caso; bloqueio de suite nas integracoes' {
        $total = 0
        foreach ($name in $SuiteNames) {
            $plan = Get-SuitePlan (Get-SuiteFile $PackageSource $name)
            Assert-True $plan.Determined ($name + ': ' + (@($plan.Problems) -join '; '))
            Assert-Equal ((@($plan.Catalog.Names)) -join '|') ((@($plan.Cases | ForEach-Object { $_.Name })) -join '|') $name
            Assert-Equal 0 @($plan.Cases | Where-Object { $_.Body -isnot [scriptblock] }).Count ($name + ': caso sem bloco')
            Assert-Equal ($name.EndsWith('.Integration')) ($null -ne $plan.GateCondition) ($name + ': bloqueio de suite')
            foreach ($part in @('Prelude', 'Segments', 'CaseCleanup', 'SuiteCleanup')) { Assert-True ($plan.$part -is [scriptblock]) ($name + ': ' + $part) }
            Assert-True (@($plan.ExportedFunctions) -notcontains 'It') ($name + ': mini-harness publicado')
            $total += @($plan.Cases).Count
        }
        $plan = Get-SuitePlan (Get-SuiteFile $PackageSource 'Plan.Unit')
        Assert-True $plan.HarnessRequires 'Plan.Unit: pre-requisito por caso'
        Assert-Equal 'JobLimitSet|JobLimitQuery' ((@($plan.Cases | Where-Object { $_.Bindings.Contains('point') } | ForEach-Object { $_.Bindings['point'] })) -join '|')
        Assert-True ($total -gt 0) 'total'
    }

    It 'plano nativo: preambulo mascarado preserva linhas, separador ; e $PSScriptRoot da suite; mini-harness e resumo fora' {
        $plan = Get-TextPlan ("`$a = 1; `$b = [IO.Path]::GetFileName(`$PSScriptRoot)`n" +
            "function It { param([string]`$Name, [scriptblock]`$Body) try { & `$Body } finally { `$script:Limpo = `$true } }`n" +
            "try {`n    It 'x' { }`n    `$c = 3`n    function F { 4 }`n} finally { `$script:Fim = 1 }`nexit 9`n")
        Assert-True $plan.Determined (@($plan.Problems) -join '; ')
        Assert-Equal 5 $plan.Segments.Ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true).Extent.StartLineNumber 'linha preservada'
        $values = & { . $plan.Prelude; . $plan.Segments; @($a, $b, $c, (F)) }
        Assert-Equal 1 $values[0]; Assert-Equal ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($plan.Path))) $values[1] '$PSScriptRoot da suite'
        Assert-Equal 3 $values[2]; Assert-Equal 4 $values[3]
        Assert-True (-not $plan.Prelude.ToString().Contains('function It')) 'mini-harness no preambulo'
        Assert-True ($plan.CaseCleanup.ToString().Contains('$script:Limpo = $true')) 'finally do mini-harness'
        Assert-True ($plan.SuiteCleanup.ToString().Contains('$script:Fim = 1')) 'finally da suite'
        Assert-True (-not ($plan.Prelude.ToString() + $plan.Segments.ToString()).Contains('exit')) 'resumo fora'
        Assert-Equal 'a,b,c' (@($plan.ExportedVariables) -join ','); Assert-Equal 'F' (@($plan.ExportedFunctions) -join ',')
    }

    It 'plano nativo indeterminado: forma fora do contrato nunca e executada pelo Pester' {
        $harness = "function It { param([string]`$Name, [scriptblock]`$Body) try { & `$Body } catch { } }`n"
        $cases = @(
            "It 'a' { }",
            ($harness + "try { It 'a' { } } finally { }`ntry { } finally { }"),
            ($harness + "try { It 'a' { } } catch { }"),
            ("try { It 'a' { } } finally { }"),
            ("function It { param([string]`$Nome, [scriptblock]`$Body) try { & `$Body } catch { } }`ntry { It 'a' { } } finally { }"),
            ("function It { param([string]`$Name, [scriptblock]`$Body, [string[]]`$Requires) try { & `$Body } catch { } }`ntry { It 'a' -Requires Git { } } finally { }"),
            ($harness + "try { It 'a' -Requires Git { } } finally { }"),
            ($harness + "try { It 'a' { }`n    Get-Date } finally { }"),
            ($harness + "try { It 'a' { }`n    if (`$true) { `$x = 1 } } finally { }"),
            ($harness + "It 'b' { }`ntry { It 'a' { } } finally { }"),
            ($harness + "exit 2`ntry { It 'a' { } } finally { }"),
            ($harness + "if (`$x) { exit 2 } else { }`ntry { It 'a' { } } finally { }"),
            ($harness + "if (`$x) { exit 2; Write-Output 'depois' }`ntry { It 'a' { } } finally { }"),
            ($harness + "try { It 'a' }`nfinally { }")
        )
        foreach ($text in $cases) {
            $plan = Get-TextPlan $text
            Assert-True (-not $plan.Determined) ('aceito: ' + $text)
            Assert-True (@($plan.Problems).Count -gt 0) ('sem motivo: ' + $text)
        }
        $plan = Get-TextPlan ($harness + "`$missing = @('Git')`nif (`$missing.Count -gt 0) { Write-Output '  [PRE-REQ] ausente: Git'; exit 2 }`ntry { It 'a' { } } finally { }")
        Assert-True $plan.Determined (@($plan.Problems) -join '; ')
        Assert-Equal $true (& { . $plan.Prelude; . $plan.GateCondition }) 'condicao do bloqueio'
        Assert-Equal '  [PRE-REQ] ausente: Git' (& { . $plan.Prelude; . $plan.GateBody }) 'corpo do bloqueio sem exit'
    }

    It 'motor Pester: aprovada somente com resultado global Passed, codigo 0, versao fixada, cada caso uma vez e resumo coerente' {
        $catalog = New-Catalog @('a', 'b')
        $ok = @(@('a', 'a', 'Passed'), @('b', 'b', 'Passed'))
        $v = Get-PesterVerdict (New-PesterRun $ok) $catalog '5.7.1'
        Assert-Equal 'Aprovada' $v.Status $v.Reason; Assert-Equal 2 $v.Passed; Assert-Equal 0 $v.NotExecuted
        $checks = @(
            @('caso ausente', (New-PesterRun @(@('a', 'a', 'Passed'))), 'Inconclusiva'),
            @('duplicado', (New-PesterRun ($ok + , @('a', 'a', 'Passed'))), 'Inconclusiva'),
            @('teste sem caso', (New-PesterRun ($ok + , @($null, 'extra', 'Passed'))), 'Inconclusiva'),
            @('caso nao catalogado', (New-PesterRun ($ok + , @('c', 'c', 'Passed'))), 'Inconclusiva'),
            @('nome diferente do caso', (New-PesterRun @(@('a', 'a', 'Passed'), @('b', 'outro', 'Passed'))), 'Inconclusiva'),
            @('NotRun', (New-PesterRun @(@('a', 'a', 'Passed'), @('b', 'b', 'NotRun'))), 'Inconclusiva'),
            @('Inconclusive', (New-PesterRun @(@('a', 'a', 'Passed'), @('b', 'b', 'Inconclusive'))), 'Inconclusiva'),
            @('Skipped sem pre-requisito declarado', (New-PesterRun @(@('a', 'a', 'Passed'), @('b', 'b', 'Skipped'))), 'Inconclusiva'),
            @('resumo inconsistente', (New-PesterRun $ok @{ Total = 9; Passed = 9 }), 'Inconclusiva'),
            @('resumo ausente', (New-PesterRun $ok 'sem-resumo'), 'Inconclusiva'),
            @('resumo repetido', (New-PesterRun $ok -Extra @('PESTER-FIM={"Result":"Passed","Total":2,"Passed":2,"Failed":0,"Skipped":0,"NotRun":0,"Inconclusive":0,"FailedContainers":0,"FailedBlocks":0}')), 'Inconclusiva'),
            @('resumo sem campo', (New-PesterRun $ok 'sem-resumo' -Extra @('PESTER-FIM={"Result":"Passed","Total":2,"Passed":2,"Failed":0,"Skipped":0,"NotRun":0}')), 'Inconclusiva'),
            @('caso malformado', (New-PesterRun $ok -Extra @('PESTER-CASO={"Case":"a"')), 'Inconclusiva'),
            @('versao diferente da fixada', (New-PesterRun $ok -Version '5.6.1'), 'Inconclusiva'),
            @('versao nao informada', (New-PesterRun $ok -Version ''), 'Inconclusiva'),
            @('versao carregada recusada (codigo 3)', (New-PesterRun $ok -ExitCode 3), 'Falha'),
            @('erro do processo Pester', (New-PesterRun $ok -Extra @('PESTER-ERRO=Import-Module falhou')), 'Falha'),
            @('Passed com codigo 1', (New-PesterRun $ok -ExitCode 1), 'Falha'),
            @('resultado global desconhecido', (New-PesterRun $ok @{ Result = 'NotRun' } -ExitCode 4), 'Inconclusiva'),
            @('caso com falha', (New-PesterRun @(@('a', 'a', 'Passed'), @('b', 'b', 'Failed'))), 'Falha'),
            @('caso com falha e resultado global Passed', (New-PesterRun @(@('a', 'a', 'Passed'), @('b', 'b', 'Failed')) @{ Result = 'Passed' } -ExitCode 0), 'Inconclusiva'),
            @('falha de descoberta', (New-PesterRun $ok @{ Result = 'Failed'; FailedContainers = 1 } -ExitCode 1), 'Falha')
        )
        foreach ($check in $checks) {
            $v = Get-PesterVerdict $check[1] $catalog '5.7.1'
            Assert-Equal $check[2] $v.Status ($check[0] + ': ' + $v.Reason)
        }
        Assert-Equal 'Inconclusiva' (Get-PesterVerdict (New-PesterRun $ok) $catalog '').Status 'versao fixada vazia'
        $v = Get-PesterVerdict (New-PesterRun @(@('a', 'a', 'Passed'), @('b', 'b', 'Skipped'))) $catalog '5.7.1'
        Assert-Equal 1 $v.Skipped 'ignorado contado'
    }

    It 'falso positivo corrigido: resultado global Failed com todos os casos Passed nunca e aprovado' {
        $catalog = New-Catalog @('a', 'b')
        $ok = @(@('a', 'a', 'Passed'), @('b', 'b', 'Passed'))
        # Defeito apontado na revisao: Failed sem contagem de bloco ou conteiner e codigo 0 era aprovado.
        $v = Get-PesterVerdict (New-PesterRun $ok @{ Result = 'Failed' } -ExitCode 0) $catalog '5.7.1'
        Assert-Equal 'Falha' $v.Status $v.Reason; Assert-True ($v.Reason.Contains('incompativel com o resultado global Failed')) $v.Reason
        $v = Get-PesterVerdict (New-PesterRun $ok @{ Result = 'Failed' } -ExitCode 1) $catalog '5.7.1'
        Assert-Equal 'Inconclusiva' $v.Status $v.Reason; Assert-True ($v.Reason.Contains('incoerente')) $v.Reason
        # Falha de BeforeAll/AfterAll: casos Passed, bloco com falha.
        $v = Get-PesterVerdict (New-PesterRun $ok @{ Result = 'Failed'; FailedBlocks = 1 } -ExitCode 1 -Extra @('PESTER-BLOCO=Suite :: limpeza falhou')) $catalog '5.7.1'
        Assert-Equal 'Falha' $v.Status $v.Reason; Assert-Equal 2 $v.Passed
        Assert-True (@($v.Details) -contains 'pester: BLOCO=Suite :: limpeza falhou') (@($v.Details) -join ', ')
    }

    It 'motor Pester: pre-requisito por caso e bloqueio de suite ficam pendentes; bloqueio com caso executado, nunca' {
        $catalog = New-Catalog @('a', 'b') @{ a = @(); b = @('Git') }
        $v = Get-PesterVerdict (New-PesterRun @(@('a', 'a', 'Passed'), @('b', 'b', 'Skipped'))) $catalog '5.7.1'
        Assert-Equal 'Pendente' $v.Status $v.Reason; Assert-Equal 1 $v.Blocked; Assert-Equal 0 $v.Skipped
        $plain = New-Catalog @('a', 'b')
        $blocked = @('PESTER-PRE-REQ-SUITE=Git >= 2.44')
        $v = Get-PesterVerdict (New-PesterRun @(@('a', 'a', 'Skipped'), @('b', 'b', 'Skipped')) -Extra $blocked) $plain '5.7.1'
        Assert-Equal 'Pendente' $v.Status $v.Reason; Assert-True $v.SuiteBlocked 'suite bloqueada'; Assert-Equal 2 $v.Blocked
        Assert-True ($v.Reason.Contains('Git >= 2.44')) $v.Reason
        $v = Get-PesterVerdict (New-PesterRun @(@('a', 'a', 'Passed'), @('b', 'b', 'Skipped')) -Extra $blocked) $plain '5.7.1'
        Assert-Equal 'Inconclusiva' $v.Status $v.Reason
    }

    It 'motor Pester real (5.7.1): casos executados pelo Pester; falha de caso e falha da limpeza da suite reprovam' {
        $requirement = Read-PesterRequirement $PackageSource
        $installed = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.ToString() -ceq [string]$requirement['RequiredVersion'] })
        Assert-True ($installed.Count -gt 0) ('Pester ' + $requirement['RequiredVersion'] + ' ausente neste PowerShell; caso nao executavel')
        $suite = New-NativeFixtureSuite
        $catalog = Get-SuiteCatalog $suite
        Assert-Equal 'a|b p|b q' (@($catalog.Names) -join '|')
        $marks = [IO.Path]::Combine([IO.Path]::GetDirectoryName($suite), 'marcas.txt')
        $run = Invoke-NativePester $suite
        $v = Get-PesterVerdict $run $catalog ([string]$requirement['RequiredVersion'])
        Assert-Equal 'Aprovada' $v.Status ($v.Reason + ' | ' + $run.StdOut + $run.StdErr)
        Assert-Equal 0 $run.ExitCode
        Assert-Equal 'JobVazio' $run.Termination
        # Corpo do caso executado; finally do mini-harness por caso; finally da suite uma vez.
        Assert-Equal 'a|fim a|fim b p|fim b q|limpeza' (([IO.File]::ReadAllText($marks).TrimEnd("`n") -split "`n") -join '|')
        Assert-True ($run.StdOut.Contains('PESTER-VERSAO=' + $requirement['RequiredVersion'] + ' ')) 'versao carregada'
        [IO.File]::Delete($marks)
        $v = Get-PesterVerdict (Invoke-NativePester $suite @{ MA_FALHAR_CASO = 'q' }) $catalog ([string]$requirement['RequiredVersion'])
        Assert-Equal 'Falha' $v.Status $v.Reason; Assert-Equal 'Falha' $v.Cases['b q']; Assert-Equal 'Aprovado' $v.Cases['b p']
        [IO.File]::Delete($marks)
        # Cenario do falso positivo, real: todos os casos Passed e AfterAll com falha.
        $run = Invoke-NativePester $suite @{ MA_FALHAR_LIMPEZA = '1' }
        $v = Get-PesterVerdict $run $catalog ([string]$requirement['RequiredVersion'])
        Assert-Equal 3 $v.Passed ($run.StdOut)
        Assert-Equal 'Falha' $v.Status $v.Reason
        Assert-Equal 1 $run.ExitCode
        Assert-True ($run.StdOut.Contains('"Result":"Failed"')) 'resultado global'
    }

    Write-Output 'Pacote, isolamento e cobertura'
    It 'inventario recusa caminho absoluto, com . ou .., .git ou o proprio manifesto' {
        foreach ($bad in @('../fora.txt', 'a/../b', 'a/./b', 'C:/x', '/raiz', '.git/config', 'package.manifest.json', 'a\b', 'a//b', '')) {
            $root = New-Fixture
            Write-Text ([IO.Path]::Combine($root, 'package.manifest.json')) ('{"distributionVersion":"0.0.0","state":"t","files":[{"path":' + ($bad | ConvertTo-Json) + '}]}')
            $refused = $false
            try { [void](Get-PackageInventory $root) } catch { $refused = $true }
            Assert-True $refused ('aceito: ' + $bad)
        }
        $root = New-Fixture
        Write-Text ([IO.Path]::Combine($root, 'package.manifest.json')) '{"distributionVersion":"0.0.0","state":"t","files":[{"path":"docs/a.md"},{"path":".githooks/pre-commit"}]}'
        $inventory = Get-PackageInventory $root
        Assert-Equal 2 @($inventory.Paths).Count
    }

    It 'copia isolada: somente arquivos inventariados e manifesto, bytes identicos, poc/ e .git fora' {
        $source = New-Fixture
        Write-Text ([IO.Path]::Combine($source, 'package.manifest.json')) '{"distributionVersion":"0.0.0","state":"t","files":[{"path":"docs/a.md"},{"path":"scripts/b.ps1"}]}'
        Write-Text ([IO.Path]::Combine($source, 'docs', 'a.md')) "documento`n"
        Write-Text ([IO.Path]::Combine($source, 'scripts', 'b.ps1')) "Write-Output 1`n"
        Write-Text ([IO.Path]::Combine($source, 'poc', 'experimento.ps1')) "experimental`n"
        Write-Text ([IO.Path]::Combine($source, '.git', 'HEAD')) "ref: refs/heads/x`n"
        Write-Text ([IO.Path]::Combine($source, 'nao-inventariado.txt')) "x`n"
        $copy = New-IsolatedPackage $source
        $script:FixtureRoots.Add([IO.Path]::GetDirectoryName($copy.Root))
        $files = @(Get-ChildItem -LiteralPath $copy.Root -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($copy.Root.Length + 1) } | Sort-Object)
        Assert-Equal 'docs\a.md|package.manifest.json|scripts\b.ps1' ($files -join '|')
        foreach ($relative in $files) {
            $a = Get-Sha256Hex ([IO.File]::ReadAllBytes([IO.Path]::Combine($source, $relative)))
            $b = Get-Sha256Hex ([IO.File]::ReadAllBytes([IO.Path]::Combine($copy.Root, $relative)))
            Assert-Equal $a $b $relative
        }
        Assert-True (-not $copy.Root.StartsWith($source, [StringComparison]::OrdinalIgnoreCase)) 'copia dentro da origem'
    }

    It 'instantaneo da raiz detecta arquivo criado, removido ou alterado, e ignora .git' {
        $root = New-Fixture
        Write-Text ([IO.Path]::Combine($root, 'a.txt')) "a`n"
        Write-Text ([IO.Path]::Combine($root, 'd', 'b.txt')) "b`n"
        $before = Get-TreeSnapshot $root
        Assert-Equal 0 @(Compare-Snapshot $before (Get-TreeSnapshot $root)).Count 'estavel'
        Write-Text ([IO.Path]::Combine($root, '.git', 'index')) "x`n"
        Assert-Equal 0 @(Compare-Snapshot $before (Get-TreeSnapshot $root)).Count '.git ignorado'
        Write-Text ([IO.Path]::Combine($root, 'd', 'b.txt')) "B`n"
        Write-Text ([IO.Path]::Combine($root, 'novo.txt')) "n`n"
        [IO.File]::Delete([IO.Path]::Combine($root, 'a.txt'))
        $changes = @(Compare-Snapshot $before (Get-TreeSnapshot $root))
        foreach ($expected in @('- a.txt', '+ novo.txt', '- d\b.txt', '+ d\b.txt')) { Assert-True ($changes -contains $expected) ('ausente: ' + $expected + ' em ' + ($changes -join ', ')) }
        # Regressao: instantaneos iguais contam zero diferencas; lado vazio nao lanca.
        Assert-Equal 0 @(Compare-Snapshot '' '').Count 'vazios'
        Assert-Equal '+ x.txt' ((@(Compare-Snapshot '' 'x.txt|00')) -join ',')
        Assert-Equal '- x.txt' ((@(Compare-Snapshot 'x.txt|00' '')) -join ',')
    }

    It 'cobertura: criterio dos dois PowerShells aprovado so no 5.1 fica pendente, nunca coberto' {
        $ok = [pscustomobject]@{ Status = 'Aprovada' }; $bad = [pscustomobject]@{ Status = 'Falha' }
        $both = @{ Id = 'AC01'; Hosts = $true; Suites = @('A', 'B') }
        $single = @{ Id = 'AC05'; Suites = @('A') }
        $desktop = @([pscustomobject]@{ Edition = 'Desktop'; Suite = 'A'; Verdict = $ok }, [pscustomobject]@{ Edition = 'Desktop'; Suite = 'B'; Verdict = $ok })
        $c = Get-CriterionState -Criterion $both -Selected @('A', 'B') -Results $desktop -Editions @('Desktop')
        Assert-True $c.Pending $c.State; Assert-True ($c.State.StartsWith('Pendente')) $c.State
        $c = Get-CriterionState -Criterion $single -Selected @('A', 'B') -Results $desktop -Editions @('Desktop')
        Assert-True (-not $c.Pending) $c.State; Assert-True ($c.State.StartsWith('Coberto')) $c.State
        $all = $desktop + @([pscustomobject]@{ Edition = 'Core'; Suite = 'A'; Verdict = $ok }, [pscustomobject]@{ Edition = 'Core'; Suite = 'B'; Verdict = $ok })
        $c = Get-CriterionState -Criterion $both -Selected @('A', 'B') -Results $all -Editions @('Desktop', 'Core')
        Assert-True (-not $c.Pending) $c.State; Assert-True ($c.State.StartsWith('Coberto')) $c.State
        $failed = @($desktop[0], [pscustomobject]@{ Edition = 'Desktop'; Suite = 'B'; Verdict = $bad })
        $c = Get-CriterionState -Criterion $both -Selected @('A', 'B') -Results $failed -Editions @('Desktop')
        Assert-True ($c.State.StartsWith('Nao comprovado')) $c.State
        $c = Get-CriterionState -Criterion $both -Selected @('A') -Results @($desktop[0]) -Editions @('Desktop')
        Assert-True ($c.State.StartsWith('Nao avaliado')) $c.State
        $c = Get-CriterionState -Criterion @{ Id = 'AC21'; External = $true } -Selected @() -Results @() -Editions @()
        Assert-True ($c.State.StartsWith('Externo') -and -not $c.Pending) $c.State
    }

    It 'candidatos padrao: Windows PowerShell 5.1 do System32 e PowerShell 7; lista explicita substitui' {
        $candidates = @(Get-HostCandidates)
        Assert-Equal 'Windows PowerShell 5.1|PowerShell 7' (($candidates | ForEach-Object { $_.Label }) -join '|')
        Assert-Equal ([IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe')) $candidates[0].Path
        $PowerShellPath = @('C:\inexistente\pwsh.exe')
        $explicit = @(Get-HostCandidates)
        Assert-Equal 1 $explicit.Count
        Assert-Equal 'C:\inexistente\pwsh.exe' $explicit[0].Path
    }
} finally {
    foreach ($root in $script:FixtureRoots) { if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) } }
}

Write-Output ''
Write-Output ('Resultado: ' + $script:Passed + ' aprovados, ' + $script:Failed.Count + ' falhas')
foreach ($failure in $script:Failed) { Write-Output ('  - ' + $failure) }
if ($script:Failed.Count -gt 0) { exit 1 }
exit 0
