# ================================================================================================
# S5 - Teardown do ensaio de stress do WAF.
#
# Zera (scale 0) ou DELETA as VMSS de teste por regiao apos o ensaio, para nao deixar custo nem
# IP pendurado. Use -Delete para apagar de vez; sem ele, faz scale para 0 (mantem a VMSS vazia).
#
# Uso (PowerShell, do laptop):
#   ./teardown.ps1                                  # scale 0 nas 3 regioes padrao
#   ./teardown.ps1 -Delete                          # deleta as VMSS de teste
#   ./teardown.ps1 -Regioes @("brazilsouth")        # so a regiao do cenario A
# ================================================================================================

param(
  [string]   $ResourceGroup = "dpcrobos",
  [string]   $Subscription  = "5c27bb8e-190b-4cf7-bd0e-c9dfca554525",
  [string[]] $Regioes       = @("brazilsouth", "eastus2", "westus3"),
  [switch]   $Delete
)

$ErrorActionPreference = "Stop"
az account set --subscription $Subscription | Out-Null

Write-Host "=========================================="
Write-Host ("TEARDOWN - " + ($(if ($Delete) { "DELETE" } else { "SCALE 0" })) + " em: " + ($Regioes -join ', '))
Write-Host "=========================================="

foreach ($regiao in $Regioes) {
  $sufixo = ($regiao -replace '[^a-zA-Z0-9]', '')
  $vmss   = "VMSSRoboDPC-$sufixo"

  $existe = az vmss show -g $ResourceGroup -n $vmss --query "name" -o tsv 2>$null
  if (-not $existe) { Write-Host "[$regiao] $vmss nao existe, pulando."; continue }

  if ($Delete) {
    Write-Host "[$regiao] Deletando $vmss ..."
    az vmss delete -g $ResourceGroup -n $vmss --output none
    Write-Host "[$regiao] $vmss deletado."
  } else {
    Write-Host "[$regiao] Escalando $vmss para 0 instancias ..."
    az vmss scale -g $ResourceGroup -n $vmss --new-capacity 0 --output none
    Write-Host "[$regiao] $vmss em 0 (sem custo de compute; VMSS preservada)."
  }
}

Write-Host "`nTeardown concluido. Checklist:"
Write-Host "  - Confirme custo zerado: az vmss list -g $ResourceGroup -o table"
Write-Host "  - Limpe a colecao de telemetria de teste se nao precisar mais (watcher.stress_telemetria)."
