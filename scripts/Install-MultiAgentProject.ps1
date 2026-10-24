#Requires -Version 5.1
<#
.SYNOPSIS
Instalador multiagente. Esta entrega implementa as fases Plan, PrepareMaintenance e CompleteWorktrees.

.DESCRIPTION
Plan valida o pacote e a configuracao, renderiza em memoria e inspeciona os
ambientes, sem modificar arquivos, indice, referencias ou configuracao, sem
fetch, clone, temporarios, relatorios em disco ou execucao de hooks.

PrepareMaintenance exige AuthorizationReference e BaseCommit completo. Clona a
coordenacao quando ausente, cria a manutencao ausente na base autorizada e gera
nela somente os destinos governados ausentes. Clone e worktree sao criados sem
checkout, em destinos fixados por handles; o checkout so ocorre se nenhum filtro,
hook, submodulo ou origem alternativa de atributos se aplicar, e um checkout
recusado fica pendente e retomavel. Nao cria Codex/Claude, nao ativa
hooks, nao prepara o indice, nao faz commit, push ou PR. Com -WhatIf, nenhuma
operacao mutavel e executada.

CompleteWorktrees exige AuthorizationReference, IntegratedCommit completo e
IntegrationReference: caminho do registro JSON da integracao (PR, revisao
independente, autorizacao humana vinculada ao PR e ao HEAD revisado, resultado,
commit integrado, origem da comprovacao do merge humano e alcance autorizado da
conclusao), conferido contra a configuracao e os objetos Git locais, sem consulta
ao servidor. Exige a coordenacao ja sincronizada e o conteudo governado do HEAD
revisado, do commit integrado e da coordenacao identico ao esperado. Cria Codex e
Claude ausentes na base integrada, sem reposicionar branches, e insere
core.hooksPath=.githooks na configuracao local somente se os quatro worktrees
permitirem. Nao faz fetch, nao sincroniza a coordenacao, nao faz commit, push, PR
ou merge. Com -WhatIf, nenhuma operacao mutavel e executada.

Validate e recusada ate entrega e autorizacao proprias.

Codigos de saida: 0 Sucesso, 2 Incompleto, 3 Bloqueado, 4 Falha operacional.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Config,
    [ValidateSet('Plan', 'PrepareMaintenance', 'CompleteWorktrees', 'Validate')][string]$Phase = 'Plan',
    [string]$AuthorizationReference = '',
    [string]$BaseCommit = '',
    [string]$IntegratedCommit = '',
    [string]$IntegrationReference = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($Phase -notin @('Plan', 'PrepareMaintenance', 'CompleteWorktrees')) {
    [Console]::Error.WriteLine('MA_PHASE_NOT_IMPLEMENTED: fase ' + $Phase + ' nao implementada nesta entrega; somente Plan, PrepareMaintenance e CompleteWorktrees. Nenhuma modificacao foi realizada.')
    exit 4
}

try {
    Import-Module -Name ([IO.Path]::Combine($PSScriptRoot, 'MultiAgentTemplate.psm1')) -Force -DisableNameChecking
    # Caminhos relativos resolvidos de forma literal, sem expansao de variaveis.
    $workingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    $configPath = $Config
    if (-not [IO.Path]::IsPathRooted($configPath)) { $configPath = [IO.Path]::Combine($workingDirectory, $configPath) }
    $integrationPath = $IntegrationReference
    if ($integrationPath -and -not [IO.Path]::IsPathRooted($integrationPath)) { $integrationPath = [IO.Path]::Combine($workingDirectory, $integrationPath) }
    $packageRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
    $arguments = @{
        ConfigPath = $configPath; PackageRoot = $packageRoot; AuthorizationReference = $AuthorizationReference
        BaseCommit = $BaseCommit; IntegratedCommit = $IntegratedCommit; IntegrationReference = $integrationPath
        WhatIfRequested = [bool]$WhatIfPreference
    }
    if ($Phase -eq 'PrepareMaintenance') {
        $result = Invoke-MaPrepareMaintenance @arguments
        Format-MaPrepareReport -Result $result | Write-Output
    } elseif ($Phase -eq 'CompleteWorktrees') {
        $result = Invoke-MaCompleteWorktrees @arguments
        Format-MaCompleteReport -Result $result | Write-Output
    } else {
        $result = Invoke-MaPlan @arguments
        Format-MaPlanReport -Plan $result | Write-Output
    }
    exit (Get-MaExitCode $result.Status)
} catch {
    if ($Phase -eq 'PrepareMaintenance') {
        [Console]::Error.WriteLine('MA_PREPARE_UNEXPECTED_FAILURE: falha operacional inesperada. Operacoes eventualmente realizadas foram preservadas; confira o estado com Plan.')
    } elseif ($Phase -eq 'CompleteWorktrees') {
        [Console]::Error.WriteLine('MA_COMPLETE_UNEXPECTED_FAILURE: falha operacional inesperada. Operacoes eventualmente realizadas foram preservadas; confira o estado com Plan.')
    } else {
        [Console]::Error.WriteLine('MA_PLAN_UNEXPECTED_FAILURE: falha operacional inesperada. Nenhuma modificacao foi realizada.')
    }
    exit 4
}
