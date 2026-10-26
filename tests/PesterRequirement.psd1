# Requisito de Pester da distribuicao de testes (especificacao, secao 8: Pester 5
# com versao fixada, execucao separada nos dois PowerShells). Lido como dados por
# tests/Invoke-Tests.ps1 (Import-PowerShellDataFile).
#
# RequiredVersion: versao exata (5.x.y) usada pelo motor Pester, fixada por decisao
# humana em 5.7.1 (PowerShell Gallery, pacote Pester 5.7.1). O executor nunca
# instala, baixa ou carrega outra versao: exige esta versao instalada em cada
# PowerShell e confere a versao efetivamente carregada no processo de teste.
@{
    ModuleName      = 'Pester'
    MajorVersion    = 5
    RequiredVersion = '5.7.1'
}
