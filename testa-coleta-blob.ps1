# testa-coleta-blob.ps1
# ------------------------------------------------------------------------------------------------
# Testa OFFLINE (sem Azure) o coleta-blob-comum.ps1: o `az` e substituido por uma funcao falsa que
# simula o storage. Cobre o defeito de 2026-11-25 (download falhou em silencio, container apagado,
# RG derrubado em seguida) e o caminho feliz.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File testa-coleta-blob.ps1
#
# Rodar em powershell.exe (5.1), que e o que existe no notebook de operacao.
# ------------------------------------------------------------------------------------------------
$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "coleta-blob-comum.ps1")

$script:falhas = 0
function Confere([bool]$cond, [string]$nome) {
    if ($cond) { Write-Host "  [ok] $nome" -ForegroundColor Green }
    else       { Write-Host "  [FALHA] $nome" -ForegroundColor Red; $script:falhas++ }
}

# ---- az falso -----------------------------------------------------------------------------------
# $script:blobs        : nomes dos zips "no container"
# $script:falhaDownload: quantas chamadas de download-batch ainda falham antes de funcionar
# $script:listaFalha   : a listagem do container falha (conta/container inexistente)
# $script:chamadas     : log das subcomandos chamados
function az {
    $a = @($args)
    $script:chamadas += ($a[0..2] -join ' ')
    $sub = "$($a[0]) $($a[1]) $($a[2])"
    if ($sub -eq 'storage blob list') {
        if ($script:listaFalha) { $global:LASTEXITCODE = 1; Write-Error "ResourceNotFound: The specified container does not exist."; return }
        $global:LASTEXITCODE = 0; $script:blobs | ForEach-Object { $_ }; return
    }
    if ($sub -eq 'storage blob download-batch') {
        $dest = $a[[array]::IndexOf($a, '-d') + 1]
        if ($script:falhaDownload -gt 0) {
            $script:falhaDownload--
            $global:LASTEXITCODE = 1; Write-Error "AuthorizationFailure: This request is not authorized."; return
        }
        foreach ($b in $script:blobs) {
            $arq = Join-Path $dest $b
            New-Item -ItemType Directory -Force -Path (Split-Path $arq) | Out-Null
            $tmp = Join-Path $env:TEMP ("cb-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            Set-Content -Path (Join-Path $tmp "bot-x-20261125.log") -Value "linha1`nlinha2" -Encoding UTF8
            Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $arq -Force
            Remove-Item $tmp -Recurse -Force
        }
        $global:LASTEXITCODE = 0; return
    }
    if ($sub -eq 'storage container delete') { $script:apagou = $true; $global:LASTEXITCODE = 0; return }
    $global:LASTEXITCODE = 0
}

function Novo-Cenario($blobs, $falhaDownload, $listaFalha) {
    $script:blobs = $blobs; $script:falhaDownload = $falhaDownload; $script:listaFalha = $listaFalha
    $script:chamadas = @(); $script:apagou = $false
    $d = Join-Path $env:TEMP ("testa-coleta-" + [guid]::NewGuid().ToString('N'))
    return $d
}
$base = @{ Conta = 'conta'; Chave = 'k'; Container = 'coleta'; BaseEsperaMs = 0 }
$zips2 = @('VMSSRoboDPC/VMSSRoboDPC_0.zip', 'VMSSRoboDPC/VMSSRoboDPC_1.zip')

Write-Host "`n1) caminho feliz: 2 zips, download ok"
$d = Novo-Cenario $zips2 0 $false
$r = Baixa-Coleta -Destino $d -EsperadosMin 2 @base
Confere ($r.Completo) "completo"
Confere ($r.Baixados -eq 2) "baixou 2"
Confere (Test-Path (Join-Path $d 'VMSSRoboDPC\VMSSRoboDPC_0\bot-x-20261125.log')) "descompactou na pasta da VM"
Fecha-ContainerColeta -Conta conta -Chave k -Container coleta -ResourceGroup rg -Destino $d -Completo $r.Completo -Manter $false
Confere ($script:apagou) "apagou o container"

Write-Host "`n2) o defeito de 2026-11-25: download falha SEMPRE"
$d = Novo-Cenario $zips2 99 $false
$saida = Baixa-Coleta -Destino $d -EsperadosMin 2 @base 6>&1 | Out-String
$script:chamadas = @(); $script:falhaDownload = 99
$r = Baixa-Coleta -Destino (Join-Path $d 'b') -EsperadosMin 2 @base
Confere (-not $r.Completo) "NAO completo"
Confere ($r.Baixados -eq 0) "0 baixados"
Confere ($saida -match 'AuthorizationFailure') "o erro do az aparece na tela"
Confere (@($script:chamadas | Where-Object { $_ -like 'storage blob download-batch*' }).Count -eq 3) "retentou 3x"
Fecha-ContainerColeta -Conta conta -Chave k -Container coleta -ResourceGroup rg -Destino $d -Completo $r.Completo -Manter $false
Confere (-not $script:apagou) "NAO apagou o container"
$v = Escreve-Veredito @("download incompleto") "a frota" 6>&1 | Out-String
Confere ($v -match 'NAO DERRUBE') "veredito NAO DERRUBE"

Write-Host "`n3) download falha na 1a e passa na 2a (retentativa)"
$d = Novo-Cenario $zips2 1 $false
$r = Baixa-Coleta -Destino $d -EsperadosMin 2 @base
Confere ($r.Completo) "completo apos retentativa"
Confere (@($script:chamadas | Where-Object { $_ -like 'storage blob download-batch*' }).Count -eq 2) "2 chamadas"

Write-Host "`n4) recibos dizem 2, container tem 3: o esperado vem do container"
$d = Novo-Cenario ($zips2 + 'VMSSRoboDPC/VMSSRoboDPC_2.zip') 0 $false
$r = Baixa-Coleta -Destino $d -EsperadosMin 2 @base
Confere ($r.Esperados -eq 3) "esperados = 3"
Confere ($r.Completo) "completo com 3"

Write-Host "`n5) listagem do container falha (conta apagada): nunca conta como completo"
$d = Novo-Cenario @() 0 $true
$r = Baixa-Coleta -Destino $d -EsperadosMin 2 @base
Confere (-not $r.Completo) "NAO completo sem listagem"

Write-Host "`n6) nada a coletar (0 uploads, container vazio)"
$d = Novo-Cenario @() 0 $false
$r = Baixa-Coleta -Destino $d -EsperadosMin 0 @base
Confere ($r.Completo) "completo trivial"
Confere (@($script:chamadas | Where-Object { $_ -like 'storage blob download-batch*' }).Count -eq 1) "1 chamada so"

Write-Host "`n7) veredito liberado"
$v = Escreve-Veredito @() "a frota" 6>&1 | Out-String
Confere ($v -match 'LIBERADO') "veredito LIBERADO"

Write-Host "`n8) NAO DERRUBE explica o que se perde (VMs desligadas + texto de perda)"
$mot = @("2 VM(s) desligadas em VMSSRoboDPC NAO foram coletadas", "    az vmss start -g rg -n VMSSRoboDPC --instance-ids 3 7")
$v = Escreve-Veredito $mot "a frota" @("Sem os logs das VMs nao ha como verificar as melhorias") 6>&1 | Out-String
Confere ($v -match 'NAO DERRUBE') "veredito NAO DERRUBE"
Confere ($v -match 'verificar as melhorias') "texto de perda aparece"
Confere ($v -match '(?m)^\s+az vmss start') "comando sai sem marcador de item"
$v = Escreve-Veredito @() "a frota" @("Sem os logs das VMs nao ha como verificar as melhorias") 6>&1 | Out-String
Confere ($v -notmatch 'verificar as melhorias') "LIBERADO nao imprime o texto de perda"

Write-Host ""
if ($script:falhas -eq 0) { Write-Host "RESULTADO: tudo ok" -ForegroundColor Green; exit 0 }
Write-Host "RESULTADO: $($script:falhas) falha(s)" -ForegroundColor Red; exit 1
