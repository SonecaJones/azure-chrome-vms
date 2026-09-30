# coletar-logs-originaria.ps1
# ------------------------------------------------------------------------------------------------
# Baixa os logs de C:\logs de uma VM AVULSA (a originaria, `VMrobodpc`, que no dia D vira watcher).
#
# POR QUE UM SCRIPT SEPARADO
#   O `coletar-logs-vmss.ps1` so fala com VMSS (`az vmss run-command invoke --instance-id`). A
#   originaria nao pertence a VMSS nenhuma, entao precisa do `az vm run-command invoke`. Toda a
#   mecanica (storage descartavel + SAS so de escrita + blob) e a MESMA, e o script empurrado para
#   dentro da VM e o MESMO `scripts para rodar na VM\coletar-logs-na-vm.ps1` - nao ha copia.
#
#   Por que blob e nao stdout: o `run-command` trunca a saida em ~4 KB.
#
# CUIDADO - O WATCHER SUBIDO A MAO NAO TEM LOG EM ARQUIVO
#   O arquivo de log e criado pelo redirecionamento `>> arquivo 2>&1` que o `startup-master.ps1` /
#   `bot-supervisor.ps1` montam. O runbook do dia D manda parar o `dpc-interno-rep` e subir o
#   watcher a mao por VNC (`node index.js`) - essa saida vive so no scrollback da janela do cmd e
#   NAO e coletavel. Medido em 2026-09-30: a VM respondeu `arquivos=9 upload=OK` e nao havia
#   nenhum log da data da tentativa. Conferir ANTES da tentativa se existe
#   `C:\logs\node\*-<data de hoje>.log`; depois nao ha recuperacao.
#
# QUANDO RODAR
#   Depois da tentativa e ANTES de desligar a VM: VM parada nao aceita run-command.
#
# SO LE o disco da VM. Nada e instalado, nenhum processo e tocado.
#
# EXEMPLOS
#   .\coletar-logs-originaria.ps1 -DryRun
#   .\coletar-logs-originaria.ps1 -Desde 20260925
# ------------------------------------------------------------------------------------------------
param(
    [string] $ResourceGroup = "dpcrobos",
    [string] $Subscription  = "5c27bb8e-190b-4cf7-bd0e-c9dfca554525",
    [string] $Vm            = "VMrobodpc",
    [string] $Destino,                      # default: .\coleta-logs\originaria-<yyyyMMdd-HHmmss>
    [string] $StorageAccount,               # default: deterministico a partir da subscription
    [string] $Container     = "coleta-orig",
    [string] $LocalStorage  = "brazilsouth",
    [int]    $SasHoras      = 2,
    [string] $Desde,                        # yyyyMMdd; default = hoje
    [switch] $ManterContainer,
    [switch] $DryRun
)

# NAO usar 'Stop': o `az` escreve avisos em stderr e, sob Stop, isso vira NativeCommandError e
# mata o script no meio. O controle de erro aqui e por $LASTEXITCODE.
$ErrorActionPreference = "Continue"

# Relativo ao script, nao ao diretorio corrente.
if (-not $Destino) { $Destino = Join-Path $PSScriptRoot ("coleta-logs\originaria-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
if (-not $Desde)   { $Desde   = Get-Date -Format 'yyyyMMdd' }

function Titulo($t) {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host $t
    Write-Host "=========================================="
}

Titulo "COLETA DE LOGS - VM AVULSA ($Vm)"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "ERRO: Azure CLI (az) nao encontrado no PATH." -ForegroundColor Red
    exit 1
}
$conta = & az account show -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $conta) {
    Write-Host "ERRO: sem sessao no Azure. Rode 'az login' e tente de novo." -ForegroundColor Red
    exit 1
}
& az account set --subscription $Subscription 2>$null | Out-Null

$scriptRemoto = Join-Path $PSScriptRoot "scripts para rodar na VM\coletar-logs-na-vm.ps1"
if (-not (Test-Path $scriptRemoto)) {
    Write-Host "ERRO: script remoto nao encontrado: $scriptRemoto" -ForegroundColor Red
    exit 1
}
# O caminho do repo tem espacos e o `--scripts @arquivo` do az se da mal com isso: copia para um
# temporario sem espacos (mesmo cuidado de coletar-logs-vmss.ps1).
$scriptTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("coleta-orig-" + [guid]::NewGuid().ToString('N') + ".ps1")
Copy-Item $scriptRemoto $scriptTemp -Force

# Power state: run-command exige VM ligada.
$power = & az vm get-instance-view -g $ResourceGroup -n $Vm `
            --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRO: VM '$Vm' nao encontrada no RG '$ResourceGroup'." -ForegroundColor Red
    exit 1
}
Write-Host "VM           : $Vm ($power)"
Write-Host "Desde        : $Desde"
Write-Host "Destino      : $Destino"
if ($power -and $power.Trim() -ne 'PowerState/running') {
    Write-Host "ERRO: a VM nao esta running - run-command exige VM ligada." -ForegroundColor Red
    exit 1
}

if (-not $StorageAccount) {
    $hex = ($Subscription -replace '[^0-9a-f]', '')
    $StorageAccount = "dpclogs" + $hex.Substring(0, 8)
}
Write-Host "Storage      : $StorageAccount / container $Container"

if ($DryRun) {
    Write-Host ""
    Write-Host "-DryRun: parando aqui (nada foi criado, nada foi invocado)." -ForegroundColor Cyan
    Remove-Item -LiteralPath $scriptTemp -Force -ErrorAction SilentlyContinue
    exit 0
}

# ------------------------------------------------------------------------------------------------
# Storage descartavel + SAS so de escrita
# ------------------------------------------------------------------------------------------------
Titulo "STORAGE"

& az storage account show -g $ResourceGroup -n $StorageAccount -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Criando storage account (pode levar ~30s)..."
    & az storage account create -g $ResourceGroup -n $StorageAccount -l $LocalStorage `
        --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
        --allow-blob-public-access false -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: nao foi possivel criar o storage account." -ForegroundColor Red
        exit 1
    }
}

$chave = & az storage account keys list -g $ResourceGroup -n $StorageAccount --query "[0].value" -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or -not $chave) {
    Write-Host "ERRO: nao foi possivel obter a chave do storage account." -ForegroundColor Red
    exit 1
}

& az storage container create --account-name $StorageAccount --account-key $chave -n $Container -o none 2>$null

$expira = (Get-Date).ToUniversalTime().AddHours($SasHoras).ToString("yyyy-MM-ddTHH:mm:ssZ")
# Permissao minima: create/add/write. Sem read e sem list - o token viaja como parametro do
# run-command e fica na Activity Log do Azure.
$sas = & az storage container generate-sas --account-name $StorageAccount --account-key $chave `
        -n $Container --permissions acw --expiry $expira -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or -not $sas) {
    Write-Host "ERRO: nao foi possivel gerar o SAS." -ForegroundColor Red
    exit 1
}
$sas = $sas.Trim()
# base64 porque o token tem '&', '=' e '%', que nao sobrevivem a passagem por --parameters/cmd.
$sasB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sas))
$urlBase = "https://$StorageAccount.blob.core.windows.net/$Container"
Write-Host "Container    : $Container (SAS de escrita valido ate $expira UTC)"

# ------------------------------------------------------------------------------------------------
# Disparar a coleta na VM
# ------------------------------------------------------------------------------------------------
Titulo "RUN-COMMAND"

$saida = & az vm run-command invoke -g $ResourceGroup -n $Vm `
    --command-id RunPowerShellScript --scripts "@$scriptTemp" `
    --parameters "SasUrlBase=$urlBase" "SasB64=$sasB64" "Prefixo=originaria" "Desde=$Desde" `
    -o json 2>$null
$code = $LASTEXITCODE

$recibo = ''
if ($saida) {
    try {
        $v = (($saida -join "`n") | ConvertFrom-Json).value
        $std = ($v | Where-Object { $_.code -like '*StdOut*' } | Select-Object -First 1).message
        $err = ($v | Where-Object { $_.code -like '*StdErr*' } | Select-Object -First 1).message
        $recibo = $std
        if ($err) { $recibo = $recibo + "`nSTDERR: " + $err }
    } catch { $recibo = ($saida -join "`n") }
}
if ($code -ne 0 -and -not $recibo) {
    Write-Host "ERRO: run-command falhou (exit $code)." -ForegroundColor Red
}
Write-Host $recibo

# ------------------------------------------------------------------------------------------------
# Baixar e descompactar
# ------------------------------------------------------------------------------------------------
Titulo "DOWNLOAD"

New-Item -ItemType Directory -Force -Path $Destino | Out-Null
& az storage blob download-batch -d $Destino -s $Container `
    --account-name $StorageAccount --account-key $chave --pattern "*" -o none 2>$null

$zips = @(Get-ChildItem -Path $Destino -Filter "*.zip" -Recurse -ErrorAction SilentlyContinue)
Write-Host "Zips baixados: $($zips.Count)"
foreach ($z in $zips) {
    $pasta = Join-Path $z.DirectoryName $z.BaseName
    New-Item -ItemType Directory -Force -Path $pasta | Out-Null
    try { Expand-Archive -Path $z.FullName -DestinationPath $pasta -Force }
    catch { Write-Host "  [!!] falha ao descompactar $($z.Name): $_" -ForegroundColor Red }
}

Get-ChildItem -Path $Destino -Recurse -File | ForEach-Object {
    Write-Host ("  {0,-60} {1,10} bytes" -f $_.FullName.Substring($Destino.Length + 1), $_.Length)
}

# Log do bot COM A DATA DA COLETA: sua ausencia e o sintoma do watcher subido a mao (ver cabecalho).
$hoje = Get-Date -Format 'yyyyMMdd'
$doDia = @(Get-ChildItem -Path $Destino -Recurse -File -Filter "bot-*$hoje.log" -ErrorAction SilentlyContinue)
if ($doDia.Count -eq 0) {
    Write-Host ""
    Write-Host "ATENCAO: nenhum bot-*-$hoje.log nesta coleta." -ForegroundColor Yellow
    Write-Host "  Causas tipicas: processo subido A MAO (sem o redirecionamento do startup-master/" -ForegroundColor Yellow
    Write-Host "  supervisor, caso do watcher por VNC), ou bot que nao rodou hoje." -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------------------------
# Limpeza
# ------------------------------------------------------------------------------------------------
if (Test-Path $scriptTemp) { Remove-Item -LiteralPath $scriptTemp -Force -ErrorAction SilentlyContinue }

if ($ManterContainer) {
    Write-Host ""
    Write-Host "-ManterContainer: container '$Container' preservado no storage $StorageAccount."
} else {
    & az storage container delete --account-name $StorageAccount --account-key $chave -n $Container -o none 2>$null
    Write-Host ""
    Write-Host "Container '$Container' apagado (o storage account foi mantido para a proxima coleta)."
}
Write-Host ""
Write-Host "Arquivos em : $Destino"
