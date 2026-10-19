#Requires -Version 5.1
<#
.SYNOPSIS
Instalador multiagente. Esta entrega implementa somente a fase Plan.

.DESCRIPTION
Plan valida o pacote e a configuracao, renderiza em memoria e inspeciona os
ambientes, sem modificar arquivos, indice, referencias ou configuracao, sem
fetch, clone, temporarios, relatorios em disco ou execucao de hooks.
As demais fases sao recusadas ate entrega e autorizacao proprias.

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

if ($Phase -ne 'Plan') {
    [Console]::Error.WriteLine('MA_PHASE_NOT_IMPLEMENTED: fase ' + $Phase + ' nao implementada nesta entrega; somente Plan. Nenhuma modificacao foi realizada.')
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
    $plan = Invoke-MaPlan -ConfigPath $configPath -PackageRoot $packageRoot -AuthorizationReference $AuthorizationReference `
        -BaseCommit $BaseCommit -IntegratedCommit $IntegratedCommit -IntegrationReference $IntegrationReference `
        -WhatIfRequested:([bool]$WhatIfPreference)
    Format-MaPlanReport -Plan $plan | Write-Output
    exit (Get-MaExitCode $plan.Status)
} catch {
    [Console]::Error.WriteLine('MA_PLAN_UNEXPECTED_FAILURE: falha operacional inesperada. Nenhuma modificacao foi realizada.')
    exit 4
}
