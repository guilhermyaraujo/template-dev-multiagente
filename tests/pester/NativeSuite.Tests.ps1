#Requires -Version 5.1
<#
Execucao nativa de uma suite pelo Pester 5 (especificacao, secao 8), usada somente
por tests/Invoke-Tests.ps1 -Engine Pester, com a versao fixada em
tests/PesterRequirement.psd1. A suite nao e alterada nem executada como script.

O plano da suite (Get-SuitePlan, pela AST) define um It do Pester por caso do
catalogo, identificado por Data.MaCaseName. Cada It executa o bloco do proprio
caso: o Pester executa e avalia o caso, e qualquer excecao do bloco falha o teste.
O mini-harness da suite nao e executado. BeforeAll executa o preambulo e as
definicoes intercaladas do bloco de casos, na ordem do arquivo, e publica no
escopo global do processo Pester (dedicado a suite) as variaveis e funcoes
definidas no nivel do arquivo, como o powershell -File do harness as deixa,
visiveis ao codigo executado no escopo do modulo; AfterEach, o
finally do mini-harness; AfterAll, o finally da suite. Pre-requisito por caso
(-Requires) ausente em $script:Prereq vira Set-ItResult -Skipped, com o mesmo
criterio do mini-harness. O bloqueio da suite inteira (if do preambulo terminado
em exit) e avaliado sem o exit: os casos sao ignorados e os pre-requisitos
ausentes informados (PESTER-PRE-REQ-SUITE). Plano indeterminado interrompe a
descoberta (falha de conteiner) e a suite nunca e aprovada.
#>
param(
    [Parameter(Mandatory = $true)][string]$Executor,
    [Parameter(Mandatory = $true)][string]$SuiteFile
)

BeforeDiscovery {
    # Executor carregado num escopo proprio: somente o plano sai dele.
    $MaPlan = & { . $Executor; Get-SuitePlan $SuiteFile }
    if (-not $MaPlan.Determined) { throw ('plano nativo indeterminado: ' + (@($MaPlan.Problems) -join '; ')) }
    $MaCases = @(foreach ($case in $MaPlan.Cases) { @{ MaCaseName = $case.Name; MaCase = $case } })
}

Describe 'Suite' -ForEach @(@{ MaPlan = $MaPlan }) {
    BeforeAll {
        $MaSuiteBlocked = $false
        . $MaPlan.Prelude
        if ($null -ne $MaPlan.GateCondition -and (. $MaPlan.GateCondition)) {
            $MaSuiteBlocked = $true
            $MaGateItems = @(. $MaPlan.GateBody | ForEach-Object { [string]$_ } | Where-Object { $_ -cmatch '\A  \[PRE-REQ\] ausente: ' } | ForEach-Object { $_.Substring(21) })
            if ($MaGateItems.Count -eq 0) { [Console]::Out.WriteLine('PESTER-ERRO=bloqueio da suite sem pre-requisito identificado') }
            foreach ($MaItem in $MaGateItems) { [Console]::Out.WriteLine('PESTER-PRE-REQ-SUITE=' + $MaItem) }
        }
        if (-not $MaSuiteBlocked) {
            . $MaPlan.Segments
            # Como no -File do harness: definicoes do arquivo visiveis no escopo global,
            # inclusive ao codigo executado no escopo do modulo. Processo dedicado a suite.
            foreach ($MaName in $MaPlan.ExportedVariables) {
                $MaVariable = Get-Variable -Name $MaName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $MaVariable) { Set-Variable -Name $MaName -Value $MaVariable.Value -Scope Global }
            }
            foreach ($MaName in $MaPlan.ExportedFunctions) { Set-Item -LiteralPath ('function:global:' + $MaName) -Value (Get-Item -LiteralPath ('function:' + $MaName)).ScriptBlock }
        }
    }

    # Como no mini-harness: o caso bloqueado por pre-requisito retorna antes do try,
    # sem o finally dele; os parametros do mini-harness ficam visiveis ao caso e ao finally.
    AfterEach {
        if (-not $MaSuiteBlocked -and $null -eq (Get-Variable -Name MaCaseBlocked -Scope Local -ErrorAction SilentlyContinue)) {
            $Name = $MaCaseName; $Body = $MaCase.Body; if ($MaPlan.HarnessRequires) { $Requires = $MaCase.Requires }
            . $MaPlan.CaseCleanup
        }
    }

    AfterAll {
        if (-not $MaSuiteBlocked) { . $MaPlan.SuiteCleanup }
    }

    It '<MaCaseName>' -ForEach $MaCases {
        if ($MaSuiteBlocked) { Set-ItResult -Skipped -Because 'pre-requisito da suite ausente' }
        if (@($MaCase.Requires).Count -gt 0) {
            $MaMissing = @($MaCase.Requires | Where-Object { -not $script:Prereq[$_] })
            if ($MaMissing.Count -gt 0) { $MaCaseBlocked = $true; Set-ItResult -Skipped -Because ('ausente: ' + ($MaMissing -join ', ')) }
        }
        $Name = $MaCaseName; $Body = $MaCase.Body; if ($MaPlan.HarnessRequires) { $Requires = $MaCase.Requires }
        foreach ($MaBinding in $MaCase.Bindings.GetEnumerator()) { Set-Variable -Name $MaBinding.Key -Value $MaBinding.Value }
        & $MaCase.Body
    }
}
