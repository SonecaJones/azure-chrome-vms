# coletar-logs-vmss.ps1
# ------------------------------------------------------------------------------------------------
# Baixa os logs do `dpc-interno-rep` de TODAS as instancias de TODAS as VMSS (todas as regioes)
# para uma pasta local, apos uma tentativa real.
#
# ESTA COLETA E OBRIGATORIA EM TODO DIA D - NAO E OPCIONAL
#   "Baixar os logs do dia" inclui ESTA coleta, mesmo que ninguem cite as VMs. Os logs das VMs sao
#   a UNICA fonte para verificar as melhorias feitas no periodo anterior ao dia D. Quase tudo que
#   um slice novo instrumenta sai so no log da VM:
#     [WAF403] [WAF_RESGATE] [CF_PASSAGEM] (W1)   [HTTP5XX] cf-ray (K1)   [POLLING_52X] (K2)
#     [CLEAN] tempo do solver (Y1b)   [PORTAO_CAPTCHA] [PORTAO_W3] (captcha)   [SESSAO_VIDA]
#     [MANUT_ONLINE] (quem liberou o semaforo)   [CONCORRENTE]   [DATA_TROCADA]   [CONFIG]
#   O dump do Mongo NAO substitui: ele guarda quase so os ciclos que deram certo (ver a memoria
#   "taxa de captcha nao sai do Mongo"), e o log dos containers e so do dpc-login-gov.
#   Sem esta coleta o dia D vira "deu X agendamentos" e nenhuma melhoria fica provada ou refutada.
#   Em 2026-11-25 ela se perdeu (RG apagado com a coleta em curso) e nao ha como refazer.
#
# COMO FUNCIONA
#   1. Cria (ou reusa) um storage account descartavel no proprio RG e um container.
#   2. Gera um SAS de container SO DE ESCRITA (create/add/write - sem read, sem list), valido por
#      poucas horas.
#   3. Empurra `scripts para rodar na VM\coletar-logs-na-vm.ps1` para cada instancia via
#      `az vmss run-command invoke`. Cada VM zipa C:\logs e faz PUT do zip no container.
#   4. Baixa tudo com a chave da conta e descompacta por VM.
#   5. Imprime um resumo e grava _resumo.csv. Apaga o container ao fim (salvo -ManterContainer)
#      SO SE todos os zips chegaram ao disco, e termina com o veredito LIBERADO / NAO DERRUBE.
#      Em 2026-11-25 o download falhou em silencio, o container foi apagado e o RG derrubado em
#      seguida: os logs da frota do dia se perderam (ver coleta-blob-comum.ps1).
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

# Download com retentativa, limpeza condicional do container e veredito final (2026-11-25).
. (Join-Path $PSScriptRoot "coleta-blob-comum.ps1")

# ------------------------------------------------------------------------------------------------
# 1) Pre-checks
# ------------------------------------------------------------------------------------------------
Titulo "COLETA DE LOGS DA FROTA - dpc-interno-rep"
Write-Host "OBRIGATORIA: os logs das VMs sao a unica fonte para verificar as melhorias" -ForegroundColor Yellow
Write-Host "do periodo (W1, K1, K2, Y1b, captcha...). O dump do Mongo NAO substitui." -ForegroundColor Yellow
Write-Host "Nao derrube a frota nem o RG antes da linha LIBERADO no fim deste script." -ForegroundColor Yellow

# O que se perde se esta coleta nao terminar: vai junto do veredito NAO DERRUBE.
$perda = @(
    "Sem os logs das VMs nao ha como verificar as melhorias do periodo anterior ao dia D",
    "([WAF403]/[WAF_RESGATE], [HTTP5XX] cf-ray, [POLLING_52X], [CLEAN], [PORTAO_CAPTCHA]...).",
    "O dump do Mongo NAO substitui. Depois que a VM for apagada, nao ha recuperacao."
)

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
$desligadas = @()      # VM existe mas nao esta ligada: o disco (e o log) continuam la
$ausentes = @()        # VMSS que nao existe mais: se houve dia D, o log ja se perdeu
foreach ($nome in $Vmss) {
    if (-not (Az-Json @('vmss','show','-g',$ResourceGroup,'-n',$nome,'-o','json'))) {
        Write-Host "  [--] $nome : nao existe neste RG - pulando" -ForegroundColor DarkYellow
        $ausentes += $nome
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
            $desligadas += [pscustomobject]@{ Vmss = $nome; Id = $id; Power = $power }
            continue
        }

        $alvos += [pscustomobject]@{ Vmss = $nome; Id = $id; Nome = $i.name }
        $n++
    }
    Write-Host "  [ok] $nome : $n instancia(s)"
}

# VM desligada (deallocated) NAO perdeu o log: o disco do SO e persistente (a VMSS nao usa disco
# efemero). Religar, coletar e desligar de novo. Ao religar o bot sobe sozinho no boot - coletar
# logo e desligar. VMSS ausente e perda definitiva (ou infra zerada entre temporadas).
$motivosPulo = @()
if ($desligadas.Count -gt 0) {
    $porVmss = $desligadas | Group-Object Vmss
    foreach ($g in $porVmss) {
        $ids = ($g.Group | ForEach-Object { $_.Id }) -join ' '
        $motivosPulo += "$($g.Count) VM(s) desligadas em $($g.Name) NAO foram coletadas (o log continua no disco). Religar e rodar de novo:"
        $motivosPulo += "    az vmss start -g $ResourceGroup -n $($g.Name) --instance-ids $ids"
        $motivosPulo += "    .\coletar-logs-vmss.ps1 -Vmss $($g.Name) -InstanceIds $(($g.Group | ForEach-Object { $_.Id }) -join ',')"
    }
}
foreach ($a in $ausentes) {
    $motivosPulo += "VMSS '$a' nao existe: se houve dia D com ela, os logs dela ja se perderam (ou a infra esta zerada entre temporadas)"
}

if ($alvos.Count -eq 0) {
    Write-Host ""
    Write-Host "Nenhuma instancia ligada para coletar." -ForegroundColor Yellow
    if ($motivosPulo.Count -gt 0) {
        Escreve-Veredito $motivosPulo "a frota / o RG" $perda
        exit 2
    }
    Write-Host "Nada a coletar." -ForegroundColor Yellow
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

$uploadsOk = @($resultados | Where-Object { $_.Upload -eq 'OK' }).Count
$download = Baixa-Coleta -Destino $Destino -Conta $StorageAccount -Chave $chave -Container $Container -EsperadosMin $uploadsOk

# Conta as linhas do log do bot de cada VM (0 = VM sem log: imagem antiga, ou bot que nao subiu) e
# quantas vezes o supervisor teve de reiniciar o bot (0 = a VM atravessou o dia sem cair).
# `Baixado` separa "VM sem log" de "o zip dela nao desceu" - em 2026-11-25 os dois saiam como 0.
foreach ($r in $resultados) {
    $linhas = 0
    $reinicios = 0
    $baixado = $false
    if ($r.VmName) {
        $pasta = Join-Path $Destino (Join-Path $r.Vmss ($r.VmName -replace '[^A-Za-z0-9_.-]', '_'))
        $baixado = Test-Path -LiteralPath $pasta
        Get-ChildItem -Path $pasta -Filter "bot-*.log" -ErrorAction SilentlyContinue | ForEach-Object {
            $linhas += @(Get-Content $_.FullName -ErrorAction SilentlyContinue).Count
        }
        Get-ChildItem -Path $pasta -Filter "supervisor-*.log" -ErrorAction SilentlyContinue | ForEach-Object {
            $reinicios += @(Select-String -Path $_.FullName -Pattern 'node ausente \(reinicio #' -ErrorAction SilentlyContinue).Count
        }
    }
    $r | Add-Member -NotePropertyName LinhasLogBot -NotePropertyValue $linhas -Force
    $r | Add-Member -NotePropertyName Reinicios -NotePropertyValue $reinicios -Force
    $r | Add-Member -NotePropertyName Baixado -NotePropertyValue $(if ($baixado) { 'sim' } else { 'NAO' }) -Force
}

# ------------------------------------------------------------------------------------------------
# 6) Resumo
# ------------------------------------------------------------------------------------------------
Titulo "RESUMO"

$resultados | Select-Object Vmss, Id, VmName, Arquivos, Bytes, Baixado, LinhasLogBot, Reinicios, Upload |
    Sort-Object Vmss, Id | Format-Table -AutoSize

$csv = Join-Path $Destino "_resumo.csv"
$resultados | Select-Object Vmss, Id, VmName, Arquivos, Bytes, Baixado, LinhasLogBot, Reinicios, Upload |
    Sort-Object Vmss, Id | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

$ok      = @($resultados | Where-Object { $_.Upload -eq 'OK' })
$naoDesceu = @($ok | Where-Object { $_.Baixado -ne 'sim' })
$semLog  = @($ok | Where-Object { $_.Baixado -eq 'sim' -and $_.LinhasLogBot -eq 0 })
$falhou  = @($resultados | Where-Object { $_.Upload -ne 'OK' })
$reiniciadas = @($ok | Where-Object { $_.Reinicios -gt 0 })

Write-Host "Coletadas com sucesso : $($ok.Count) de $($resultados.Count)"
Write-Host "No disco              : $($ok.Count - $naoDesceu.Count) de $($ok.Count)"
Write-Host "Falharam              : $($falhou.Count)"
if ($naoDesceu.Count -gt 0) {
    Write-Host ""
    Write-Host "ATENCAO: $($naoDesceu.Count) VM(s) fizeram upload OK mas o zip NAO chegou ao disco:" -ForegroundColor Red
    Write-Host "  $(($naoDesceu | ForEach-Object { $_.VmName }) -join ', ')" -ForegroundColor Red
}
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

Fecha-ContainerColeta -Conta $StorageAccount -Chave $chave -Container $Container -ResourceGroup $ResourceGroup `
    -Destino $Destino -Completo ($download.Completo -and $naoDesceu.Count -eq 0) -Manter ([bool]$ManterContainer)

$motivos = @()
if (-not $download.Completo) { $motivos += "download incompleto: $($download.Baixados) de $($download.Esperados) zips no disco" }
if ($naoDesceu.Count -gt 0)  { $motivos += "$($naoDesceu.Count) VM(s) com upload OK sem zip no disco" }
if ($falhou.Count -gt 0)     { $motivos += "$($falhou.Count) VM(s) ligadas nao entregaram o log (rode de novo so nelas com -InstanceIds)" }
# Antes de 2026-11-25 VM desligada era so pulada, e o veredito podia sair LIBERADO sem o log dela.
$motivos += $motivosPulo
Escreve-Veredito $motivos "a frota / o RG" $perda
if ($motivos.Count -gt 0) { exit 2 }
