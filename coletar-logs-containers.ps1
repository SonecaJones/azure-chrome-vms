# coletar-logs-containers.ps1
# ------------------------------------------------------------------------------------------------
# Baixa o log COMPLETO de cada container group do `dpc-login-gov` (Azure Container Instances) para
# .\coleta-logs\containers-<timestamp>\full\<grupo>.log.
#
# O container NAO escreve log em arquivo - so stdout. Este e o unico registro do que o bot de
# renovacao do `cookiesGov` fez no dia D, e ele se perde quando o container group e apagado.
#
# POR QUE NAO `az container logs`
#   Ele TRUNCA em ~2000 linhas em silencio (medido 2026-09-23: 11 containers devolveram
#   exatamente 2001 linhas cada) e o `azure-cli 2.63.0` nao aceita `--tail` nesse comando. A API
#   REST aceita. Integridade se confere pela PRIMEIRA linha (deve ser o inicio do processo, aqui a
#   linha do DB_CONN), nunca pela contagem - contagem igual entre alvos distintos JA e o sintoma.
#
# POR QUE NAO `az rest`
#   Medido 2026-09-30: com log de ~140 KB ele devolve o `content` inteiro E sai com exit code 1.
#   Script que confia no $LASTEXITCODE joga fora um resultado bom. Aqui o corpo vem por
#   `Invoke-RestMethod` (token do `az account get-access-token`) e nunca passa pelo console.
#
# SO LE. Nao reinicia container, nao apaga nada.
#
# QUANDO RODAR
#   Depois da tentativa e ANTES de apagar os container groups.
#
# EXEMPLOS
#   .\coletar-logs-containers.ps1 -DryRun
#   .\coletar-logs-containers.ps1
# ------------------------------------------------------------------------------------------------
param(
    [string] $ResourceGroup = "dpcrobos",
    [string] $Subscription  = "5c27bb8e-190b-4cf7-bd0e-c9dfca554525",
    [string] $Destino,                 # default: .\coleta-logs\containers-<yyyyMMdd-HHmmss>
    [string[]] $Grupos,                # nomes explicitos; default = todos os do RG
    [int]    $Tail          = 100000,
    [string] $ApiVersion    = "2023-05-01",
    [switch] $DryRun
)

# NAO usar 'Stop': avisos do `az` em stderr virariam NativeCommandError sob PS 5.1.
$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Destino) { $Destino = Join-Path $PSScriptRoot ("coleta-logs\containers-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }

function Titulo($t) {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host $t
    Write-Host "=========================================="
}

Titulo "COLETA DE LOGS - CONTAINERS (dpc-login-gov)"

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

if (-not $Grupos) {
    $lista = & az container list -g $ResourceGroup --query "[].name" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO: falha ao listar container groups em '$ResourceGroup'." -ForegroundColor Red
        exit 1
    }
    $Grupos = @($lista | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($Grupos.Count -eq 0) {
    Write-Host "Nenhum container group em '$ResourceGroup'. Nada a coletar." -ForegroundColor Yellow
    exit 0
}

Write-Host "ResourceGroup: $ResourceGroup"
Write-Host "Grupos       : $($Grupos -join ', ')"
Write-Host "Destino      : $Destino"

if ($DryRun) {
    Write-Host ""
    Write-Host "-DryRun: parando aqui (nada foi baixado, nada foi gravado)." -ForegroundColor Cyan
    exit 0
}

$token = & az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or -not $token) {
    Write-Host "ERRO: nao foi possivel obter token de acesso." -ForegroundColor Red
    exit 1
}
$headers = @{ Authorization = "Bearer $($token.Trim())" }

$pastaFull = Join-Path $Destino "full"
New-Item -ItemType Directory -Force -Path $pastaFull | Out-Null

Titulo "DOWNLOAD"

$resumo = @()
foreach ($cg in $Grupos) {
    # O container INTERNO nao tem o nome do group (group `robodpc_gov_rep1_0`, container `robo`).
    # Usar o nome do group na URL devolve ContainerNotFound.
    $det = & az container show -g $ResourceGroup -n $cg -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $det) {
        Write-Host ("  [!!] {0}: falha em 'az container show' - pulando" -f $cg) -ForegroundColor Red
        continue
    }
    $det = ($det -join "`n") | ConvertFrom-Json

    foreach ($c in @($det.containers)) {
        $nomeCont = $c.name
        $uri = "https://management.azure.com/subscriptions/$Subscription/resourceGroups/$ResourceGroup" +
               "/providers/Microsoft.ContainerInstance/containerGroups/$cg/containers/$nomeCont" +
               "/logs?api-version=$ApiVersion&tail=$Tail"

        $conteudo = $null
        try {
            $r = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET -TimeoutSec 300
            $conteudo = $r.content
        } catch {
            Write-Host ("  [!!] {0}/{1}: {2}" -f $cg, $nomeCont, $_.Exception.Message) -ForegroundColor Red
            continue
        }
        if ($null -eq $conteudo) { $conteudo = "" }

        # UTF-8 COM BOM: o log tem acento e sem BOM o Get-Content do PS 5.1 le como ANSI/CP1252
        # (mesma armadilha do log das VMs).
        $arquivo = Join-Path $pastaFull ("{0}.log" -f $cg)
        [System.IO.File]::WriteAllText($arquivo, $conteudo, (New-Object System.Text.UTF8Encoding($true)))

        $linhasArr = $conteudo -split "`r?`n"
        $primeira  = ($linhasArr | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)

        Write-Host ("  [ok] {0,-24} restarts={1} estado={2} linhas={3} bytes={4}" -f `
            $cg, $c.instanceView.restartCount, $c.instanceView.currentState.state, $linhasArr.Count, $conteudo.Length)
        Write-Host ("       1a linha: {0}" -f $primeira)

        $resumo += [pscustomobject]@{
            Grupo         = $cg
            Container     = $nomeCont
            Estado        = $c.instanceView.currentState.state
            Restarts      = $c.instanceView.restartCount
            Inicio        = $c.instanceView.currentState.startTime
            Linhas        = $linhasArr.Count
            Bytes         = $conteudo.Length
            PrimeiraLinha = $primeira
        }
    }
}

Titulo "RESUMO"

if ($resumo.Count -eq 0) {
    Write-Host "Nenhum log coletado." -ForegroundColor Yellow
    exit 1
}

$resumo | Select-Object Grupo, Container, Estado, Restarts, Linhas, Bytes | Format-Table -AutoSize

$csv = Join-Path $Destino "_resumo.csv"
$resumo | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

# Contagem IDENTICA entre grupos distintos e a assinatura do truncamento (ver cabecalho).
$iguais = @($resumo | Group-Object Linhas | Where-Object { $_.Count -gt 1 })
if ($iguais.Count -gt 0 -and $resumo.Count -gt 1) {
    Write-Host "ATENCAO: grupos com contagem de linhas IDENTICA - conferir a 1a linha de cada:" -ForegroundColor Yellow
    foreach ($g in $iguais) {
        Write-Host ("  {0} linhas: {1}" -f $g.Name, (($g.Group | ForEach-Object { $_.Grupo }) -join ', ')) -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Arquivos em : $pastaFull"
Write-Host "Resumo em   : $csv"
