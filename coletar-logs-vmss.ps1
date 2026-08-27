# coletar-logs-vmss.ps1
# ------------------------------------------------------------------------------------------------
# Baixa os logs do `dpc-interno-rep` de TODAS as instancias de TODAS as VMSS (todas as regioes)
# para uma pasta local, apos uma tentativa real.
#
# COMO FUNCIONA
#   1. Cria (ou reusa) um storage account descartavel no proprio RG e um container.
#   2. Gera um SAS de container SO DE ESCRITA (create/add/write - sem read, sem list), valido por
#      poucas horas.
#   3. Empurra `scripts para rodar na VM\coletar-logs-na-vm.ps1` para cada instancia via
#      `az vmss run-command invoke`. Cada VM zipa C:\logs e faz PUT do zip no container.
#   4. Baixa tudo com a chave da conta e descompacta por VM.
#   5. Imprime um resumo e grava _resumo.csv. Apaga o container ao fim (salvo -ManterContainer).
#
# POR QUE BLOB, E NAO O STDOUT DO RUN-COMMAND
#   O `run-command` trunca a saida em ~4 KB; um log de tentativa real passa de 400 KB por VM.
#   O stdout aqui e usado so como recibo.
#
# QUANDO RODAR
#   Depois da tentativa e ANTES de desligar/derrubar a frota (stress-test\teardown.ps1,
#   `az vmss deallocate`): VM parada nao aceita run-command.
#
# PRE-REQUISITOS
#   - `az login` feito (o script confere).
#   - Nada e instalado nas VMs; o script SO LE o disco delas.
#
# EXEMPLOS
#   .\coletar-logs-vmss.ps1 -DryRun
#   .\coletar-logs-vmss.ps1 -Vmss VMSSRoboDPC-brazilsouth -InstanceIds 0      # ensaio numa VM
#   .\coletar-logs-vmss.ps1 -Desde 20260824                                   # frota inteira
# ------------------------------------------------------------------------------------------------
param(
    [string]   $ResourceGroup = "dpcrobos",
    [string]   $Subscription  = "5c27bb8e-190b-4cf7-bd0e-c9dfca554525",
    # Mesma derivacao de nome usada em create-multiregion-vmss.ps1.
    [string[]] $Regioes       = @("brazilsouth"),
    [string[]] $Vmss,                          # nomes explicitos; sobrepoe -Regioes
    [int[]]    $InstanceIds,                   # filtro de instancias (ensaio)
    [string]   $Destino,                       # default: .\coleta-logs\<yyyyMMdd-HHmmss>
    [string]   $StorageAccount,                # default: deterministico a partir da subscription
    [string]   $Container     = "coleta",
    [string]   $LocalStorage  = "brazilsouth",
    [int]      $SasHoras      = 2,
    [string]   $Desde,                         # yyyyMMdd; default = hoje
    [int]      $Paralelo      = 8,
    [switch]   $ManterContainer,
    [switch]   $DryRun
)

# NAO usar 'Stop': o `az` escreve avisos em stderr e, sob Stop, isso vira NativeCommandError e
# mata o script no meio da frota. O controle de erro aqui e por $LASTEXITCODE.
$ErrorActionPreference = "Continue"

# Relativo ao script, nao ao diretorio corrente: o destino nao pode depender de onde voce chamou.
if (-not $Destino) { $Destino = Join-Path $PSScriptRoot ("coleta-logs\" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
if (-not $Desde)   { $Desde   = Get-Date -Format 'yyyyMMdd' }

function Titulo($t) {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host $t
    Write-Host "=========================================="
}

# Retorna o stdout do az como objeto, ou $null se a chamada falhou.
function Az-Json([string[]]$a) {
    $out = & az @a 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    try { return ($out | ConvertFrom-Json) } catch { return $null }
}

# ------------------------------------------------------------------------------------------------
# 1) Pre-checks
# ------------------------------------------------------------------------------------------------
Titulo "COLETA DE LOGS DA FROTA - dpc-interno-rep"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "ERRO: Azure CLI (az) nao encontrado no PATH." -ForegroundColor Red
    exit 1
}
$conta = Az-Json @('account','show','-o','json')
if (-not $conta) {
    Write-Host "ERRO: sem sessao no Azure. Rode 'az login' e tente de novo." -ForegroundColor Red
    exit 1
}
Write-Host "Conta        : $($conta.user.name)"
& az account set --subscription $Subscription 2>$null | Out-Null

$scriptRemoto = Join-Path $PSScriptRoot "scripts para rodar na VM\coletar-logs-na-vm.ps1"
if (-not (Test-Path $scriptRemoto)) {
    Write-Host "ERRO: script remoto nao encontrado: $scriptRemoto" -ForegroundColor Red
    exit 1
}
# O caminho do repo tem espacos e o `--scripts @arquivo` do az se da mal com isso: copia para um
# temporario sem espacos (mesmo cuidado de renomear.ps1).
$scriptTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("coleta-vm-" + [guid]::NewGuid().ToString('N') + ".ps1")
Copy-Item $scriptRemoto $scriptTemp -Force

if (-not $Vmss) {
    $Vmss = $Regioes | ForEach-Object { "VMSSRoboDPC"}
}

Write-Host "ResourceGroup: $ResourceGroup"
Write-Host "VMSS alvo    : $($Vmss -join ', ')"
Write-Host "Desde        : $Desde"
Write-Host "Destino      : $Destino"

# ------------------------------------------------------------------------------------------------
# 2) Descobrir instancias (VMSS ausente e aviso, nao erro: a infra fica zerada entre temporadas)
# ------------------------------------------------------------------------------------------------
Titulo "INSTANCIAS"

$alvos = @()
foreach ($nome in $Vmss) {
    if (-not (Az-Json @('vmss','show','-g',$ResourceGroup,'-n',$nome,'-o','json'))) {
        Write-Host "  [--] $nome : nao existe neste RG - pulando" -ForegroundColor DarkYellow
        continue
    }

    # --expand instanceView traz o power state; nem toda versao do az aceita, dai o fallback.
    $inst = Az-Json @('vmss','list-instances','-g',$ResourceGroup,'-n',$nome,'--expand','instanceView','-o','json')
    if (-not $inst) { $inst = Az-Json @('vmss','list-instances','-g',$ResourceGroup,'-n',$nome,'-o','json') }
    if (-not $inst) {
        Write-Host "  [!!] $nome : falha ao listar instancias" -ForegroundColor Red
        continue
    }

    $n = 0
    foreach ($i in @($inst)) {
        $id = [int]$i.instanceId
        if ($InstanceIds -and ($InstanceIds -notcontains $id)) { continue }

        $power = $null
        try {
            $power = ($i.instanceView.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).code
        } catch { }
        if ($power -and $power -ne 'PowerState/running') {
            Write-Host "  [--] $nome/$id : $power - pulando (run-command exige VM ligada)" -ForegroundColor DarkYellow
            continue
        }

        $alvos += [pscustomobject]@{ Vmss = $nome; Id = $id; Nome = $i.name }
        $n++
    }
    Write-Host "  [ok] $nome : $n instancia(s)"
}

if ($alvos.Count -eq 0) {
    Write-Host ""
    Write-Host "Nenhuma instancia elegivel. Nada a coletar." -ForegroundColor Yellow
    exit 0
}
Write-Host ""
Write-Host "Total: $($alvos.Count) instancia(s)"

if ($DryRun) {
    Write-Host ""
    Write-Host "-DryRun: parando aqui (nada foi criado, nada foi invocado)." -ForegroundColor Cyan
    exit 0
}

# ------------------------------------------------------------------------------------------------
# 3) Storage descartavel + SAS so de escrita
# ------------------------------------------------------------------------------------------------
Titulo "STORAGE"

if (-not $StorageAccount) {
    $hex = ($Subscription -replace '[^0-9a-f]', '')
    $StorageAccount = "dpclogs" + $hex.Substring(0, 8)
}
Write-Host "Conta        : $StorageAccount"

if (-not (Az-Json @('storage','account','show','-g',$ResourceGroup,'-n',$StorageAccount,'-o','json'))) {
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
# Permissao minima: create/add/write. Sem read e sem list - se o token vazar (ele viaja como
# parametro do run-command e fica na Activity Log), nao serve para ler o que foi enviado.
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
# 4) Disparar a coleta em cada instancia
# ------------------------------------------------------------------------------------------------
Titulo "COLETA ($($alvos.Count) instancias, ate $Paralelo em paralelo)"

$trabalho = {
    param($rg, $vmss, $id, $script, $urlBase, $sasB64, $desde)
    $saida = & az vmss run-command invoke -g $rg -n $vmss --instance-id $id `
        --command-id RunPowerShellScript --scripts "@$script" `
        --parameters "SasUrlBase=$urlBase" "SasB64=$sasB64" "Prefixo=$vmss" "Desde=$desde" `
        -o json 2>$null
    [pscustomobject]@{
        Vmss  = $vmss
        Id    = $id
        Code  = $LASTEXITCODE
        Saida = ($saida -join "`n")
    }
}

$jobs = @()
$resultados = @()
foreach ($alvo in $alvos) {
    while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $Paralelo) {
        Start-Sleep -Milliseconds 500
    }
    $jobs += Start-Job -ScriptBlock $trabalho -ArgumentList `
        $ResourceGroup, $alvo.Vmss, $alvo.Id, $scriptTemp, $urlBase, $sasB64, $Desde
}

Write-Host "Aguardando conclusao..."
$jobs | Wait-Job -Timeout 900 | Out-Null

foreach ($j in $jobs) {
    $r = $null
    if ($j.State -eq 'Completed') { $r = Receive-Job $j }
    elseif ($j.State -eq 'Running') { Stop-Job $j -ErrorAction SilentlyContinue }   # estourou o timeout
    Remove-Job $j -Force -ErrorAction SilentlyContinue

    if (-not $r) {
        $resultados += [pscustomobject]@{ Vmss='?'; Id=-1; VmName=''; Arquivos=0; Bytes=0; Upload='ERRO: job sem retorno'; Recibo='' }
        continue
    }

    $recibo = ''
    if ($r.Saida) {
        try {
            $v = ($r.Saida | ConvertFrom-Json).value
            $std = ($v | Where-Object { $_.code -like '*StdOut*' } | Select-Object -First 1).message
            $err = ($v | Where-Object { $_.code -like '*StdErr*' } | Select-Object -First 1).message
            $recibo = $std
            if (-not $recibo -and $err) { $recibo = "STDERR: $err" }
        } catch { $recibo = $r.Saida }
    }

    $linha = ($recibo -split "`r?`n" | Where-Object { $_ -like '`[COLETA`]*' } | Select-Object -First 1)
    $vmName = ''; $arquivos = 0; $bytes = 0; $upload = 'ERRO: sem recibo'
    if ($linha) {
        if ($linha -match 'vm=(\S+)')       { $vmName   = $Matches[1] }
        if ($linha -match 'arquivos=(\d+)') { $arquivos = [int]$Matches[1] }
        if ($linha -match 'bytes=(\d+)')    { $bytes    = [int]$Matches[1] }
        if ($linha -match 'upload=(.+)$')   { $upload   = $Matches[1] }
    } elseif ($r.Code -ne 0) {
        $upload = 'ERRO: run-command falhou (VM desligada?)'
    }

    $cor = if ($upload -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("  {0,-26} id={1,-3} vm={2,-24} arq={3,-3} {4}" -f $r.Vmss, $r.Id, $vmName, $arquivos, $upload) -ForegroundColor $cor

    $resultados += [pscustomobject]@{
        Vmss = $r.Vmss; Id = $r.Id; VmName = $vmName
        Arquivos = $arquivos; Bytes = $bytes; Upload = $upload; Recibo = $recibo
    }
}

# ------------------------------------------------------------------------------------------------
# 5) Baixar e descompactar
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

# Conta as linhas do log do bot de cada VM (0 = VM sem log: imagem antiga, ou bot que nao subiu) e
# quantas vezes o supervisor teve de reiniciar o bot (0 = a VM atravessou o dia sem cair).
foreach ($r in $resultados) {
    $linhas = 0
    $reinicios = 0
    if ($r.VmName) {
        $pasta = Join-Path $Destino (Join-Path $r.Vmss ($r.VmName -replace '[^A-Za-z0-9_.-]', '_'))
        Get-ChildItem -Path $pasta -Filter "bot-*.log" -ErrorAction SilentlyContinue | ForEach-Object {
            $linhas += @(Get-Content $_.FullName -ErrorAction SilentlyContinue).Count
        }
        Get-ChildItem -Path $pasta -Filter "supervisor-*.log" -ErrorAction SilentlyContinue | ForEach-Object {
            $reinicios += @(Select-String -Path $_.FullName -Pattern 'node ausente \(reinicio #' -ErrorAction SilentlyContinue).Count
        }
    }
    $r | Add-Member -NotePropertyName LinhasLogBot -NotePropertyValue $linhas -Force
    $r | Add-Member -NotePropertyName Reinicios -NotePropertyValue $reinicios -Force
}

# ------------------------------------------------------------------------------------------------
# 6) Resumo
# ------------------------------------------------------------------------------------------------
Titulo "RESUMO"

$resultados | Select-Object Vmss, Id, VmName, Arquivos, Bytes, LinhasLogBot, Reinicios, Upload |
    Sort-Object Vmss, Id | Format-Table -AutoSize

$csv = Join-Path $Destino "_resumo.csv"
$resultados | Select-Object Vmss, Id, VmName, Arquivos, Bytes, LinhasLogBot, Reinicios, Upload |
    Sort-Object Vmss, Id | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

$ok      = @($resultados | Where-Object { $_.Upload -eq 'OK' })
$semLog  = @($ok | Where-Object { $_.LinhasLogBot -eq 0 })
$falhou  = @($resultados | Where-Object { $_.Upload -ne 'OK' })
$reiniciadas = @($ok | Where-Object { $_.Reinicios -gt 0 })

Write-Host "Coletadas com sucesso : $($ok.Count) de $($resultados.Count)"
Write-Host "Falharam              : $($falhou.Count)"
if ($semLog.Count -gt 0) {
    Write-Host ""
    Write-Host "ATENCAO: $($semLog.Count) VM(s) responderam mas vieram SEM log do bot:" -ForegroundColor Yellow
    Write-Host "  $(($semLog | ForEach-Object { $_.VmName }) -join ', ')" -ForegroundColor Yellow
    Write-Host "  Causas tipicas: imagem anterior a correcao do redirecionamento de stdout," -ForegroundColor Yellow
    Write-Host "  bot que nao subiu no boot, ou -Desde recente demais." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Arquivos em : $Destino"
Write-Host "Resumo em   : $csv"

# ------------------------------------------------------------------------------------------------
# 7) Limpeza
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
