# coletar-logs-na-vm.ps1
# ------------------------------------------------------------------------------------------------
# Roda DENTRO de cada VM da VMSS, empurrado por `az vmss run-command invoke` (ver
# ..\coletar-logs-vmss.ps1). Junta os logs de C:\logs, zipa e faz PUT num blob via SAS.
#
# Por que blob e nao stdout: o `run-command` TRUNCA a saida em ~4 KB. Um log de tentativa real
# passa de 400 KB por VM. O stdout aqui e so o recibo da operacao.
#
# SO LE do disco da VM. Nao reinicia servico, nao mata processo, nao toca no bot em execucao.
# O unico descarte e da propria area temporaria criada por este script.
#
# O SAS chega em base64 de proposito: o token tem `&`, `=` e `%`, que se perdem na passagem por
# `--parameters` do az / cmd.
# ------------------------------------------------------------------------------------------------
param(
    [Parameter(Mandatory=$true)][string]$SasUrlBase,   # https://<conta>.blob.core.windows.net/<container>
    [Parameter(Mandatory=$true)][string]$SasB64,       # token SAS (sem '?') em base64
    [string]$Prefixo  = "vmss",                        # pasta logica dentro do container
    [string]$Desde    = "",                            # yyyyMMdd; vazio = todos os arquivos
    [string]$BaseLogs = "C:\logs"                      # raiz dos logs (parametrizada para teste)
)

# Nao usar 'Stop': stderr de comando nativo viraria NativeCommandError e mataria a coleta no meio.
$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- identidade da VM: mesma fonte que o bot usa (index.js), para casar com o campo `container`
#     do Mongo ---------------------------------------------------------------------------------
$vmName = $env:COMPUTERNAME
$meta = $null
try {
    $meta = Invoke-RestMethod -Headers @{"Metadata"="true"} -Method GET -TimeoutSec 5 `
        -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01"
    if ($meta.compute.name) { $vmName = $meta.compute.name }
} catch { }

$seguro  = ($vmName -replace '[^A-Za-z0-9_.-]', '_')
$staging = Join-Path $env:TEMP "coleta-$seguro"
$zip     = Join-Path $env:TEMP "$seguro.zip"

# Limpeza de sobra de execucao anterior — sempre dentro de $env:TEMP.
if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $zip)     { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

# --- copia tolerante a arquivo aberto ------------------------------------------------------------
# O bot esta escrevendo no bot-*.log neste exato momento (redirecionamento `>>` do cmd).
# Copy-Item/Compress-Archive podem falhar com "sendo usado por outro processo"; abrir com
# FileShare::ReadWrite sempre le.
function Copia-Aberto($origem, $alvo) {
    try {
        $fsIn  = [System.IO.File]::Open($origem, [System.IO.FileMode]::Open,
                                        [System.IO.FileAccess]::Read,
                                        [System.IO.FileShare]::ReadWrite)
        $fsOut = [System.IO.File]::Create($alvo)
        $fsIn.CopyTo($fsOut)
        $fsOut.Close(); $fsIn.Close()
        return $true
    } catch {
        return $false
    }
}

$corte = $null
if ($Desde) {
    try { $corte = [datetime]::ParseExact($Desde, 'yyyyMMdd', $null) } catch { $corte = $null }
}

# Padroes coletados. `sempre` ignora o filtro de data (arquivos minusculos de ponteiro/estado).
$raiz = $BaseLogs.TrimEnd('\')
$padroes = @(
    @{ p = "$raiz\node\bot-*.log";        sempre = $false },
    @{ p = "$raiz\node\supervisor-*.log"; sempre = $false },   # reinicios do bot (bot-supervisor.ps1)
    @{ p = "$raiz\node\output-*.log";     sempre = $false },   # legado (imagem pre-S1)
    @{ p = "$raiz\node\errors-*.log";     sempre = $false },   # legado (nunca chegou a existir)
    @{ p = "$raiz\node\node.pid";         sempre = $true  },
    @{ p = "$raiz\node\bot-atual.txt";    sempre = $true  },
    @{ p = "$raiz\startup-master-*.log";  sempre = $false },
    @{ p = "$raiz\gui-session-*.log";     sempre = $false },
    @{ p = "$raiz\setup-complete-vm.log"; sempre = $true  }
)

$copiados = @()
$naoLidos = @()
foreach ($item in $padroes) {
    Get-ChildItem -Path $item.p -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($corte -and -not $item.sempre -and $_.LastWriteTime -lt $corte) { return }
        $alvo = Join-Path $staging $_.Name
        if (Copia-Aberto $_.FullName $alvo) {
            $copiados += [pscustomobject]@{ Nome = $_.Name; Bytes = $_.Length }
        } else {
            $naoLidos += $_.Name
        }
    }
}

# --- _meta.txt: contexto da VM no momento da coleta ----------------------------------------------
# NUNCA incluir o .env do bot: carrega DB_CONN com senha.
$linhas = @()
$linhas += "vmName        : $vmName"
$linhas += "computerName  : $env:COMPUTERNAME"
$linhas += "instanceId    : " + ($vmName -split '_')[-1]
if ($meta) {
    $linhas += "location      : $($meta.compute.location)"
    $linhas += "vmId          : $($meta.compute.vmId)"
    $linhas += "vmSize        : $($meta.compute.vmSize)"
    $linhas += "vmScaleSet    : $($meta.compute.vmScaleSetName)"
    try {
        $ip = $meta.network.interface[0].ipv4.ipAddress[0]
        $linhas += "ipPublico     : $($ip.publicIpAddress)"
        $linhas += "ipPrivado     : $($ip.privateIpAddress)"
    } catch { }
}
$agora = Get-Date
$linhas += "coletadoEm    : $($agora.ToString('yyyy-MM-dd HH:mm:ss')) (local)"
$linhas += "coletadoUTC   : $($agora.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
$linhas += "coletadoGMT-3 : $($agora.ToUniversalTime().AddHours(-3).ToString('yyyy-MM-dd HH:mm:ss'))"
try {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $linhas += "ultimoBoot    : $($boot.ToString('yyyy-MM-dd HH:mm:ss')) (uptime $([int]($agora - $boot).TotalMinutes) min)"
} catch { }
$linhas += "filtroDesde   : $(if ($Desde) { $Desde } else { '(nenhum)' })"
$linhas += "baseLogs      : $raiz"
$linhas += ""
$linhas += "--- processos ---"
Get-Process node, chrome -ErrorAction SilentlyContinue | Sort-Object ProcessName, Id | ForEach-Object {
    $ini = ""
    try { $ini = $_.StartTime.ToString('HH:mm:ss') } catch { }
    $linhas += ("{0,-8} pid={1,-6} inicio={2,-9} ws={3} MB" -f $_.ProcessName, $_.Id, $ini, [int]($_.WorkingSet64/1MB))
}
$linhas += ""
$linhas += "--- versoes ---"
foreach ($exe in @("C:\Program Files\Google\Chrome\Application\chrome.exe",
                   "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                   "C:\Program Files\nodejs\node.exe")) {
    if (Test-Path $exe) {
        $linhas += ("{0,-10} {1}" -f (Split-Path $exe -Leaf), (Get-Item $exe).VersionInfo.ProductVersion)
    }
}
$linhas += ""
$linhas += "--- disco ---"
try {
    $d = Get-PSDrive C
    $linhas += ("C: usado {0} GB / livre {1} GB" -f [int]($d.Used/1GB), [int]($d.Free/1GB))
} catch { }
$linhas += ""
$linhas += "--- arquivos coletados ---"
foreach ($c in $copiados) { $linhas += ("{0,-46} {1,10} bytes" -f $c.Nome, $c.Bytes) }
if ($naoLidos.Count -gt 0) { $linhas += "NAO LIDOS: " + ($naoLidos -join ", ") }

Set-Content -Path (Join-Path $staging "_meta.txt") -Value $linhas -Encoding UTF8

# --- zip + upload --------------------------------------------------------------------------------
$totalBytes = ($copiados | Measure-Object -Property Bytes -Sum).Sum
if (-not $totalBytes) { $totalBytes = 0 }

Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zip -CompressionLevel Optimal -Force
if (-not (Test-Path $zip)) {
    Write-Output "[COLETA] vm=$vmName ERRO=zip-nao-gerado arquivos=$($copiados.Count)"
    exit 1
}
$zipBytes = (Get-Item $zip).Length

$sas = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SasB64))
$uri = "{0}/{1}/{2}.zip?{3}" -f $SasUrlBase.TrimEnd('/'), $Prefixo, $seguro, $sas

$upload = "OK"
try {
    Invoke-RestMethod -Method Put -Uri $uri -InFile $zip -ContentType "application/zip" `
        -Headers @{ "x-ms-blob-type" = "BlockBlob" } -TimeoutSec 120 | Out-Null
} catch {
    $upload = "ERRO: " + $_.Exception.Message
}

Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

# Recibo curto: o run-command trunca a saida em ~4 KB.
Write-Output ("[COLETA] vm={0} arquivos={1} bytes={2} zip={3} upload={4}" -f `
    $vmName, $copiados.Count, $totalBytes, $zipBytes, $upload)
foreach ($c in $copiados) { Write-Output ("  {0,-46} {1,10}" -f $c.Nome, $c.Bytes) }
if ($upload -ne "OK") { exit 2 }
