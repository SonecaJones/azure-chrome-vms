# ================================================================================================
# S3 - Startup do WATCHER em modo STRESS (roda DENTRO de cada VM do ensaio).
#
# Diferente do startup de producao (que sobe o dpc-interno-rep), este sobe o dpc-agenda-watcher
# apontando para a BASE DE TESTE, com a injecao de queda de sessao e a telemetria de stress
# ligadas. O watcher SO acessa o site (nunca agenda) - ferramenta ideal para medir o WAF.
#
# Como aplicar nas instancias de um VMSS ja existente (do laptop do Fabricio):
#   az vmss list-instances -g dpcrobos -n VMSSRoboDPC-brazilsouth --query "[].instanceId" -o tsv |
#     ForEach-Object {
#       az vmss run-command invoke -g dpcrobos -n VMSSRoboDPC-brazilsouth --instance-id $_ `
#         --command-id RunPowerShellScript --scripts "@startup-watcher-stress.ps1" `
#         --parameters DbConn="<TEST_DB_CONN>" TotalMachines=24 DropMs=15000
#     }
# (Tudo ASCII. Ver STRESS_TEST.md para o passo-a-passo completo dos cenarios A e B.)
# ================================================================================================

param(
  [string] $WatcherPath = "C:\dpc\dpc-agenda-watcher",  # pasta do watcher na VM (precisa existir na imagem)
  [string] $DbConn      = "",                            # OBRIGATORIO: conn da BASE DE TESTE
  [int]    $TotalMachines = 24,                          # total GLOBAL de VMs do ensaio (soma das regioes)
  [int]    $DropMs      = 15000,                          # SIMULA_SESSION_DROP_INTERVALO_MS (0 = sem drop)
  [int]    $DelayAgenda = 2000,                           # DELAY_TENTATIVA_AGENDA durante o ensaio
  [int]    $DelayPreAbertura = 2000
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DbConn)) {
  Write-Error "DbConn (TEST_DB_CONN) e obrigatorio. ABORTANDO para nao rodar contra producao."
  exit 1
}
if (-not (Test-Path $WatcherPath)) {
  Write-Error "Watcher nao encontrado em $WatcherPath. Coloque o dpc-agenda-watcher na imagem/VM."
  exit 1
}

# 1) Escreve o .env do watcher com a config de STRESS (sobrescreve o .env da VM de teste).
$envPath = Join-Path $WatcherPath ".env"
$envLines = @(
  "DB_CONN=$DbConn",
  "STRESS_TELEMETRIA=true",
  "SIMULA_SESSION_DROP_INTERVALO_MS=$DropMs",
  "TOTAL_MACHINES=$TotalMachines",
  "DELAY_TENTATIVA_AGENDA=$DelayAgenda",
  "DELAY_TENTATIVA_PRE_ABERTURA=$DelayPreAbertura",
  "NODE_TLS_REJECT_UNAUTHORIZED=0"
)
Set-Content -Path $envPath -Value $envLines -Encoding ascii
Write-Host "[stress] .env do watcher escrito em $envPath (DB de teste, drop=$DropMs ms, telemetria ON)."

# 2) Derruba qualquer node em execucao (ex.: o rep de producao) para a VM rodar SO o watcher.
Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# 3) Sobe o watcher com log datado.
$logDir = "C:\logs\watcher-stress"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("watcher-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$node = (Get-Command node).Source

Push-Location $WatcherPath
Start-Process -FilePath $node -ArgumentList "index.js" `
  -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" `
  -WindowStyle Hidden
Pop-Location

Write-Host "[stress] watcher iniciado. Log: $logFile"
