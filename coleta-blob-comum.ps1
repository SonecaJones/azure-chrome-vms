# coleta-blob-comum.ps1
# ------------------------------------------------------------------------------------------------
# Funcoes compartilhadas pelo coletar-logs-vmss.ps1 e pelo coletar-logs-originaria.ps1 (dot-source).
# Cuidam da parte que PERDEU os logs da frota em 2026-11-25: baixar os zips do container e decidir
# se o container pode ser apagado.
#
# O QUE ACONTECEU
#   16 VMs fizeram upload OK, o `az storage blob download-batch` falhou EM SILENCIO (stderr ia para
#   $null), o script imprimiu "Zips baixados: 0", contou LinhasLogBot=0 em todas ("VM sem log do
#   bot" - falso: o zip e que nao tinha descido) e APAGOU O CONTAINER mesmo assim. O operador, lendo
#   "coleta terminada", derrubou o RG. Os logs do dia sumiram.
#
# REGRAS DAQUI
#   - O erro do download aparece na tela (nada de 2>$null).
#   - O esperado vem do PROPRIO container (lista de blobs), nao so dos recibos das VMs.
#   - Download incompleto -> retenta com backoff; persistindo, o container NAO e apagado.
#   - O veredito final diz em letras claras se pode ou nao derrubar a infra.
#
# Rodar sob powershell.exe 5.1 (o que existe no notebook e na VM). ASCII puro de proposito.
# ------------------------------------------------------------------------------------------------

# Roda um comando do az e devolve @{ Code; Texto } com stdout+stderr juntos, como texto.
# 2>&1 sob EAP=Continue nao aborta no PS 5.1 (o ErrorRecord vira so texto aqui).
function Invoca-AzTexto([string[]]$a) {
    $linhas = & az @a 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Texto = (($linhas | Where-Object { $_ }) -join "`n") }
}

# Nomes dos blobs .zip no container, ou $null se a listagem falhou (conta/container inexistente).
function Lista-ZipsNoContainer([string]$Conta, [string]$Chave, [string]$Container) {
    $r = Invoca-AzTexto @('storage','blob','list','--account-name',$Conta,'--account-key',$Chave,
                          '-c',$Container,'--query',"[?ends_with(name,'.zip')].name",'-o','tsv')
    if ($r.Code -ne 0) {
        Write-Host "  [!!] falha ao listar o container '$Container': $($r.Texto)" -ForegroundColor Red
        return $null
    }
    # Virgula unaria: sem ela o PS desenrola o array vazio em $null e um container VAZIO pareceria
    # "listagem falhou" (achado pelo testa-coleta-blob.ps1, cenario 6).
    return ,@($r.Texto -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Baixa o container para $Destino com retentativa e descompacta cada zip numa pasta homonima.
# $EsperadosMin: piso de zips esperados (ex.: VMs com upload=OK). O esperado real e o maior entre
# esse piso e o que a listagem do container mostrar.
# Devolve @{ Completo; Baixados; Esperados; NoContainer }.
function Baixa-Coleta {
    param(
        [string] $Destino,
        [string] $Conta,
        [string] $Chave,
        [string] $Container,
        [int]    $EsperadosMin = 0,
        [int]    $Tentativas   = 3,
        [int]    $BaseEsperaMs = 5000      # backoff 5s, 10s (+ jitter 0-1s); o teste usa 0
    )
    New-Item -ItemType Directory -Force -Path $Destino | Out-Null

    $noContainer = Lista-ZipsNoContainer $Conta $Chave $Container
    $nNoContainer = if ($null -eq $noContainer) { -1 } else { $noContainer.Count }
    $esperados = [Math]::Max($EsperadosMin, [Math]::Max($nNoContainer, 0))
    if ($nNoContainer -ge 0) { Write-Host "Zips no container: $nNoContainer (piso pelos recibos: $EsperadosMin)" }

    $zips = @()
    for ($t = 1; $t -le $Tentativas; $t++) {
        $r = Invoca-AzTexto @('storage','blob','download-batch','-d',$Destino,'-s',$Container,
                              '--account-name',$Conta,'--account-key',$Chave,'--pattern','*','-o','none')
        $zips = @(Get-ChildItem -Path $Destino -Filter "*.zip" -Recurse -ErrorAction SilentlyContinue)
        if ($r.Code -ne 0) {
            Write-Host "  [!!] download-batch tentativa $t/$Tentativas saiu com exit $($r.Code):" -ForegroundColor Red
            Write-Host "       $($r.Texto)" -ForegroundColor Red
        }
        if ($zips.Count -ge $esperados -and $zips.Count -gt 0) { break }
        if ($esperados -eq 0 -and $r.Code -eq 0) { break }   # nada a baixar, e o az confirmou
        if ($t -lt $Tentativas) {
            $espera = if ($BaseEsperaMs -le 0) { 0 } else { [int]($BaseEsperaMs * [Math]::Pow(2, $t - 1) + (Get-Random -Maximum 1000)) }
            Write-Host "  Baixados $($zips.Count) de $esperados - nova tentativa em $([int]($espera/1000))s..." -ForegroundColor Yellow
            Start-Sleep -Milliseconds $espera
        }
    }
    Write-Host "Zips baixados: $($zips.Count) de $esperados esperados"

    foreach ($z in $zips) {
        $pasta = Join-Path $z.DirectoryName $z.BaseName
        New-Item -ItemType Directory -Force -Path $pasta | Out-Null
        try { Expand-Archive -Path $z.FullName -DestinationPath $pasta -Force }
        catch { Write-Host "  [!!] falha ao descompactar $($z.Name): $_" -ForegroundColor Red }
    }

    # Completo = baixou tudo que se sabia existir E a listagem funcionou (sem listagem nao ha como
    # saber o que ficou para tras, entao nao conta como completo).
    $completo = ($nNoContainer -ge 0) -and ($zips.Count -ge $esperados)
    return [pscustomobject]@{
        Completo    = $completo
        Baixados    = $zips.Count
        Esperados   = $esperados
        NoContainer = $nNoContainer
    }
}

# Apaga o container so quando o download foi completo. Caso contrario preserva e diz como rebaixar.
function Fecha-ContainerColeta {
    param(
        [string] $Conta,
        [string] $Chave,
        [string] $Container,
        [string] $ResourceGroup,
        [string] $Destino,
        [bool]   $Completo,
        [bool]   $Manter
    )
    Write-Host ""
    if ($Manter) {
        Write-Host "-ManterContainer: container '$Container' preservado no storage $Conta."
        return
    }
    if (-not $Completo) {
        Write-Host "Container '$Container' NAO foi apagado: o download ficou incompleto." -ForegroundColor Red
        Write-Host "Para rebaixar (o storage '$Conta' precisa continuar existindo):" -ForegroundColor Red
        Write-Host "  `$k = az storage account keys list -g $ResourceGroup -n $Conta --query `"[0].value`" -o tsv"
        Write-Host "  az storage blob download-batch -d `"$Destino`" -s $Container --account-name $Conta --account-key `$k"
        return
    }
    $r = Invoca-AzTexto @('storage','container','delete','--account-name',$Conta,'--account-key',$Chave,'-n',$Container,'-o','none')
    if ($r.Code -ne 0) {
        Write-Host "Aviso: falha ao apagar o container '$Container' (os logs ja estao no disco): $($r.Texto)" -ForegroundColor Yellow
    } else {
        Write-Host "Container '$Container' apagado (o storage account foi mantido para a proxima coleta)."
    }
}

# Ultima linha da coleta: e o que o operador le antes de derrubar a infra. $Motivos vazio = liberado.
# $Perda (opcional): o que se perde se derrubar assim mesmo - impresso so no NAO DERRUBE.
function Escreve-Veredito([string[]]$Motivos, [string]$Alvo, [string[]]$Perda = @()) {
    Write-Host ""
    Write-Host "=========================================="
    if (-not $Motivos -or $Motivos.Count -eq 0) {
        Write-Host "LIBERADO: os logs estao no disco. Pode derrubar $Alvo." -ForegroundColor Green
    } else {
        Write-Host "NAO DERRUBE $Alvo AINDA:" -ForegroundColor Red
        foreach ($m in $Motivos) {
            if ($m -like '    *') { Write-Host "  $m" -ForegroundColor Red }   # linha de comando
            else                { Write-Host "  - $m" -ForegroundColor Red }
        }
        if ($Perda -and $Perda.Count -gt 0) {
            Write-Host ""
            foreach ($p in $Perda) { Write-Host "  $p" -ForegroundColor Red }
        }
    }
    Write-Host "=========================================="
}
