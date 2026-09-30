# testa-roda-com-log.ps1 - roda o wrapper `scripts/roda-com-log.ps1` contra um bot FALSO e confere
# que o log sai no lugar e no formato que o coletor alcanca.
#
# Offline: nao toca a Marinha, nao toca o Mongo, nao precisa de Azure nem de Chrome.
#
# RODAR EM `powershell.exe` (5.1), que e o que existe na VM:
#     powershell.exe -ExecutionPolicy Bypass -File .\testa-roda-com-log.ps1
#
# Por que um bot FALSO e nao o real: o que esta sob teste e o REDIRECIONAMENTO (nome do arquivo,
# BOM, merge de stderr, foreground), nao o bot. Um bot falso em Node permite exercitar stdout,
# stderr, acento e codigo de saida em ~1s e de forma deterministica.

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $raiz "..\DPC AGENDA\dpc-agenda-watcher\scripts\roda-com-log.ps1"
$wrapperRep = Join-Path $raiz "..\DPC REPRESENTANTE\dpc-interno-rep\scripts\roda-com-log.ps1"

$falhas = 0
function Ok($cond, $msg) {
    if ($cond) { Write-Host "  ok    $msg" }
    else { Write-Host "  FALHA $msg" -ForegroundColor Red; $script:falhas++ }
}

Write-Host "== testa-roda-com-log =="

# ---- 0) paridade entre os dois bots -------------------------------------------------------------
$a = [IO.File]::ReadAllBytes((Resolve-Path $wrapper))
$b = [IO.File]::ReadAllBytes((Resolve-Path $wrapperRep))
Ok ($a.Length -eq $b.Length -and -not (Compare-Object $a $b)) "o wrapper e byte-identico nos dois bots"

# ---- ambiente de teste --------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP ("roda-com-log-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$repoFalso = Join-Path $tmp 'repo'
$scriptsFalso = Join-Path $repoFalso 'scripts'
$logsFalso = Join-Path $tmp 'logs'
New-Item -ItemType Directory -Path $scriptsFalso -Force | Out-Null

Copy-Item $wrapper (Join-Path $scriptsFalso 'roda-com-log.ps1')

# Bot falso: escreve em stdout E em stderr, com acento, e sai com codigo conhecido.
# O acento importa: e ele que denuncia o encoding errado (o defeito de 2026-08-30).
$botFalso = @'
console.log('linha de stdout com acento: manutencao / disponiveis / conexao');
console.error('linha de STDERR (o aws-sdk escreve avisos assim em toda partida)');
console.log('┌─┐ bordas do console.table');
process.exit(7);
'@
Set-Content -Path (Join-Path $repoFalso 'index.js') -Value $botFalso -Encoding UTF8

try {
    # ---- 1) execucao -----------------------------------------------------------------------------
    # `ErrorActionPreference = Continue` SO nesta chamada, e nao e detalhe: se o wrapper deixar o
    # stderr do node vazar para o PowerShell (merge fora do cmd, ou sem merge), o PS 5.1 o converte
    # em `NativeCommandError` e, com 'Stop', ABORTA este teste na primeira linha de stderr — sem
    # imprimir assert nenhum. Foi o que aconteceu ao rodar a prova negativa: o contrato estava
    # certo, mas o resultado saia como "0 falhas" em vez de um assert legivel.
    $prefAnterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $scriptsFalso 'roda-com-log.ps1') `
        -Rotulo 'watcher' -LogsDir $logsFalso -SemTail -SemAvisoSupervisor 2>&1
    $codigo = $LASTEXITCODE
    $ErrorActionPreference = $prefAnterior

    Ok ($codigo -eq 7) "o codigo de saida do node chega ao chamador (esperado 7, veio $codigo)"

    $logs = @(Get-ChildItem -Path $logsFalso -Filter 'bot-*.log' -ErrorAction SilentlyContinue)
    Ok ($logs.Count -eq 1) "criou exatamente um bot-*.log (achou $($logs.Count))"
    if ($logs.Count -ne 1) { throw "sem log, o resto do teste nao faz sentido" }
    $log = $logs[0]

    # ---- 2) o NOME e o contrato com o coletor ----------------------------------------------------
    # `coletar-logs-na-vm.ps1` e a coluna LinhasLogBot do resumo varrem por glob `bot-*.log`.
    Ok ($log.Name -like 'bot-*.log') "o nome casa o glob 'bot-*.log' que o coletor usa"
    Ok ($log.Name -match '^bot-watcher-') "o rotulo entra no nome (distingue do log do supervisor)"
    Ok ($log.Name -match ('-' + (Get-Date -Format 'yyyyMMdd') + '\.log$')) "o nome carrega a data de hoje"
    Ok ($log.Name -notmatch '^bot-\d') "nao colide com o 'bot-<vm>-<data>.log' do supervisor"

    # ---- 3) NAO tocar no que e do supervisor -----------------------------------------------------
    Ok (-not (Test-Path (Join-Path $logsFalso 'bot-atual.txt'))) "nao escreve bot-atual.txt (o supervisor o usa para ADOTAR)"
    Ok (-not (Test-Path (Join-Path $logsFalso 'node.pid'))) "nao escreve node.pid"

    # ---- 4) BOM no offset 0 ----------------------------------------------------------------------
    # Sem ele, Get-Content/notepad sem flag leem UTF-8 como ANSI e mostram mojibake.
    $bytes = [IO.File]::ReadAllBytes($log.FullName)
    Ok ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
        "o arquivo comeca com BOM UTF-8"

    # ---- 5) stdout E stderr no arquivo -----------------------------------------------------------
    $conteudo = Get-Content $log.FullName -Raw -Encoding UTF8
    Ok ($conteudo -match 'linha de stdout') "stdout foi para o arquivo"
    Ok ($conteudo -match 'linha de STDERR') "stderr foi para o arquivo (o 2>&1 esta DENTRO do cmd)"
    Ok ($conteudo -match '==========') "o cabecalho com o nome da VM foi gravado"
    Ok ($conteudo -match 'manual') "o cabecalho marca que a execucao foi manual"

    # ---- 6) stderr do node NAO aborta o wrapper --------------------------------------------------
    # Sob PS 5.1 stderr de comando nativo vira NativeCommandError. Se o merge vazasse para o
    # PowerShell, o wrapper morreria no primeiro aviso do Node e o item 1 ja teria falhado -
    # este assert existe para nomear o motivo quando isso acontecer.
    # Nada em `$saida` pode ser um ErrorRecord: com o merge DENTRO do cmd, o PowerShell nunca ve
    # o stderr do node. Comparar a string nao basta — o ErrorRecord se converte na mensagem do
    # comando ("linha de STDERR..."), nao no texto "NativeCommandError".
    $errosVazados = @($saida | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    Ok ($errosVazados.Count -eq 0) "stderr do node nao vazou para o PowerShell ($($errosVazados.Count) ErrorRecord)"

    # ---- 6b) nenhum caractere de controle na saida nem no log -----------------------------------
    # Em PowerShell o backtick e escape: `b dentro de uma STRING vira BACKSPACE, nao o texto
    # "`bot". O defeito e invisivel na leitura do fonte e so aparece na saida (aconteceu na
    # primeira versao deste teste: "o nome casa o glob ot-*.log"). Mesma familia do `\b` que
    # corrompeu uma regex e um caminho do CLAUDE.md em 2026-09-30.
    $textoSaida = ($saida | Out-String)
    Ok ($textoSaida -notmatch "[\x00-\x08\x0b\x0c\x0e-\x1f]") "a saida do wrapper nao tem caractere de controle"
    $corpoLog = Get-Content $log.FullName -Raw -Encoding UTF8
    Ok ($corpoLog -notmatch "[\x00-\x08\x0b\x0c\x0e-\x1f]") "o log gravado nao tem caractere de controle"

    # ---- 7) append: rodar de novo nao injeta um segundo BOM --------------------------------------
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $scriptsFalso 'roda-com-log.ps1') `
        -Rotulo 'watcher' -LogsDir $logsFalso -SemTail -SemAvisoSupervisor 2>&1 | Out-Null
    $bytes2 = [IO.File]::ReadAllBytes($log.FullName)
    $ocorrencias = 0
    for ($i = 0; $i -lt $bytes2.Length - 2; $i++) {
        if ($bytes2[$i] -eq 0xEF -and $bytes2[$i + 1] -eq 0xBB -and $bytes2[$i + 2] -eq 0xBF) { $ocorrencias++ }
    }
    Ok ($ocorrencias -eq 1) "a 2a execucao faz append sem injetar outro BOM (achou $ocorrencias)"
    Ok (@(Get-ChildItem -Path $logsFalso -Filter 'bot-*.log').Count -eq 1) "a 2a execucao reusa o mesmo arquivo do dia"

    # ---- 8) rotulo sanitizado --------------------------------------------------------------------
    # O rotulo entra num nome de arquivo; sem sanitizar viraria caminho.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $scriptsFalso 'roda-com-log.ps1') `
        -Rotulo '..\..\evade' -LogsDir $logsFalso -SemTail -SemAvisoSupervisor 2>&1 | Out-Null
    $fora = @(Get-ChildItem -Path $tmp -Filter 'bot-*.log' -ErrorAction SilentlyContinue)
    Ok ($fora.Count -eq 0) "rotulo com separador de caminho nao escapa da pasta de logs"
    $todos = @(Get-ChildItem -Path $logsFalso -Filter 'bot-*.log')
    Ok ($todos.Count -eq 2) "o rotulo sanitizado gerou um arquivo dentro de LogsDir (achou $($todos.Count))"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
if ($falhas -eq 0) { Write-Host "TODOS OS TESTES PASSARAM" -ForegroundColor Green; exit 0 }
else { Write-Host "$falhas TESTE(S) FALHARAM" -ForegroundColor Red; exit 1 }
