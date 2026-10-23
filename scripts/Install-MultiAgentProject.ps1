#Requires -Version 5.1
<#
.SYNOPSIS
Instalador multiagente. Esta entrega implementa as fases Plan e PrepareMaintenance.

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

CompleteWorktrees e Validate sao recusadas ate entrega e autorizacao proprias.

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

if ($Phase -notin @('Plan', 'PrepareMaintenance')) {
    [Console]::Error.WriteLine('MA_PHASE_NOT_IMPLEMENTED: fase ' + $Phase + ' nao implementada nesta entrega; somente Plan e PrepareMaintenance. Nenhuma modificacao foi realizada.')
    exit 4
}

try {
    Import-Module -Name ([IO.Path]::Combine($PSScriptRoot, 'MultiAgentTemplate.psm1')) -Force -DisableNameChecking
    # Caminho relativo resolvido de forma literal, sem expansao de variaveis.
    $configPath = $Config
    if (-not [IO.Path]::IsPathRooted($configPath)) {
        $configPath = [IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $configPath)
    }
    $packageRoot = [IO.Path]::GetDirectoryName($PSScriptRoot)
    $arguments = @{
        ConfigPath = $configPath; PackageRoot = $packageRoot; AuthorizationReference = $AuthorizationReference
        BaseCommit = $BaseCommit; IntegratedCommit = $IntegratedCommit; IntegrationReference = $IntegrationReference
        WhatIfRequested = [bool]$WhatIfPreference
    }
    if ($Phase -eq 'PrepareMaintenance') {
        $result = Invoke-MaPrepareMaintenance @arguments
        Format-MaPrepareReport -Result $result | Write-Output
    } else {
        $result = Invoke-MaPlan @arguments
        Format-MaPlanReport -Plan $result | Write-Output
    }
    exit (Get-MaExitCode $result.Status)
} catch {
    if ($Phase -eq 'PrepareMaintenance') {
        [Console]::Error.WriteLine('MA_PREPARE_UNEXPECTED_FAILURE: falha operacional inesperada. Operacoes eventualmente realizadas foram preservadas; confira o estado com Plan.')
    } else {
        [Console]::Error.WriteLine('MA_PLAN_UNEXPECTED_FAILURE: falha operacional inesperada. Nenhuma modificacao foi realizada.')
    }
    exit 4
}
