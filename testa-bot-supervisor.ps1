# Exercita o bot-supervisor.ps1 DE VERDADE no notebook, sem Azure e sem tocar a Marinha.
#
# O supervisor e extraido da here-string do configure-vm-image.ps1 (fonte unica da verdade) e
# roda contra um "bot" falso em Node que so fica vivo. O que se prova aqui e o que o teste de
# texto nao alcanca: que o PID guardado e o do NODE (e nao o do cmd, que sobrevive ao /k), que a
# morte do processo dispara restart com backoff, que um node vivo e adotado em vez de morto, e
# que a sentinela desliga a vigilancia sem derrubar o bot.
#
# Uso:  powershell.exe -ExecutionPolicy Bypass -File .\testa-bot-supervisor.ps1
#       (rodar em powershell.exe 5.1, que e o que existe na VM - nao so em pwsh)
param(
    [string]$Gerador = "$PSScriptRoot\scripts para rodar na VM\configure-vm-image.ps1",
    [string]$Base    = "$env:TEMP\dpc-sup-teste"
)

$ErrorActionPreference = "Continue"
$falhas = 0
function Ok($cond, $msg) {
    if ($cond) { Write-Host "  [ok]    $msg" }
    else       { Write-Host "  [FALHA] $msg"; $script:falhas++ }
}
function Vivo($processId) {
    if (-not $processId) { return $false }
    return [bool](Get-Process -Id $processId -ErrorAction SilentlyContinue)
}
function Espera($cond, $segundos, $rotulo) {
    $fim = (Get-Date).AddSeconds($segundos)
    while ((Get-Date) -lt $fim) {
        if (& $cond) { return $true }
        Start-Sleep -Milliseconds 300
    }
    Write-Host "          (timeout esperando: $rotulo)"
    return $false
}

Write-Host ""
Write-Host "=== bot-supervisor.ps1 (comportamento real) ==="

# Node em execucao antes do teste faria a ADOCAO disparar e mediria o processo errado.
$nodePrevios = @(Get-Process node -ErrorAction SilentlyContinue)
if ($nodePrevios.Count -gt 0) {
    Write-Host "  [PULADO] ha $($nodePrevios.Count) processo(s) node em execucao; feche-os e rode de novo."
    exit 0
}

# --- preparo ------------------------------------------------------------------------------
if (Test-Path $Base) { Remove-Item $Base -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path "$Base\logs" | Out-Null

$txt = Get-Content $Gerador -Raw
$ms = [regex]::Match($txt, "\`$botSupervisorScript = @'\r?\n.*?\r?\n'@", 'Singleline')
if (-not $ms.Success) { Write-Host "  [FALHA] here-string do supervisor nao encontrada"; exit 1 }
$sup = "$Base\bot-supervisor.ps1"
(& ([scriptblock]::Create($ms.Value + "`r`n" + '$botSupervisorScript'))) | Set-Content $sup -Encoding ASCII
Ok (Test-Path $sup) "supervisor extraido do gerador"

# "Bot" falso: fica vivo e escreve no stdout, para o log ter conteudo como o do bot real.
$fake = "$Base\fake-bot.js"
@'
console.log("fake-bot vivo, pid " + process.pid);
setInterval(function () { console.log("heartbeat " + new Date().toISOString()); }, 1000);
'@ | Set-Content $fake -Encoding ASCII

$sentinela = "$Base\supervisor.off"
$logsDir   = "$Base\logs"
$args = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $sup,
    "-ScriptPath", $fake, "-VmName", "VM-TESTE", "-VmId", "id-teste",
    "-LogsDir", $logsDir, "-Sentinela", $sentinela,
    "-IntervaloS", "2", "-EsperaBaseS", "1", "-EsperaMaxS", "4", "-SaudavelS", "3600", "-SemTail"
)
$supProc = Start-Process powershell.exe -ArgumentList $args -PassThru -WindowStyle Minimized

try {
    # --- 1) partida ------------------------------------------------------------------------
    Ok (Espera { Test-Path "$logsDir\node.pid" } 30 "node.pid") "node.pid criado"
    $botPid = 0
    if (Test-Path "$logsDir\node.pid") { $botPid = [int](Get-Content "$logsDir\node.pid" | Select-Object -First 1) }
    $proc = Get-Process -Id $botPid -ErrorAction SilentlyContinue
    Ok ($proc -and $proc.ProcessName -eq 'node') "node.pid aponta para um processo NODE (nao para o cmd)"

    Ok (Test-Path "$logsDir\bot-atual.txt") "ponteiro bot-atual.txt criado"
    $logBot = (Get-Content "$logsDir\bot-atual.txt" | Select-Object -First 1)
    Ok ($logBot -like "*bot-VM-TESTE-*.log") "log nomeado pela VM: $(Split-Path $logBot -Leaf)"
    Ok (Espera { (Test-Path $logBot) -and (Select-String -Path $logBot -Pattern 'heartbeat' -Quiet) } 20 "saida do bot no log") `
       "stdout do bot chega ao arquivo de log"

    # --- 2) restart apos morte -------------------------------------------------------------
    Stop-Process -Id $botPid -Force
    Ok (Espera { -not (Vivo $botPid) } 10 "morte do bot") "bot morto para o teste"
    Ok (Espera {
            (Test-Path "$logsDir\node.pid") -and
            ([int](Get-Content "$logsDir\node.pid" | Select-Object -First 1) -ne $botPid)
        } 30 "restart") "supervisor reiniciou o bot"
    $novoPid = [int](Get-Content "$logsDir\node.pid" | Select-Object -First 1)
    Ok (Vivo $novoPid) "o bot reiniciado esta vivo (pid $novoPid)"

    $logSup = Get-ChildItem "$logsDir\supervisor-VM-TESTE-*.log" -ErrorAction SilentlyContinue | Select-Object -First 1
    Ok ($logSup -ne $null) "log proprio do supervisor criado"
    if ($logSup) {
        $conteudo = Get-Content $logSup.FullName -Raw
        Ok ($conteudo -match 'node ausente \(reinicio #1\)') "o restart ficou registrado no log do supervisor"
        Ok ($conteudo -match 'Aguardando 1s') "backoff comeca no valor base (1s)"
    }

    # --- 3) backoff cresce -----------------------------------------------------------------
    Stop-Process -Id $novoPid -Force
    Ok (Espera {
            $c = Get-Content $logSup.FullName -Raw -ErrorAction SilentlyContinue
            $c -match 'reinicio #2' -and $c -match 'Aguardando 2s'
        } 30 "segundo restart") "backoff dobra no reinicio seguinte (1s -> 2s)"

    # --- 4) adocao: uma segunda instancia NAO derruba o bot vivo ----------------------------
    # Esperar o pid NOVO: a linha do backoff sai ANTES do restart, entao ler o node.pid aqui sem
    # esperar pega o pid do processo que acabou de morrer.
    Ok (Espera {
            $p = 0
            if (Test-Path "$logsDir\node.pid") { $p = [int](Get-Content "$logsDir\node.pid" | Select-Object -First 1) }
            (Vivo $p)
        } 40 "bot vivo apos o 2o restart") "bot no ar antes do teste de adocao"
    $pidVivo = [int](Get-Content "$logsDir\node.pid" | Select-Object -First 1)
    $sup2 = Start-Process powershell.exe -ArgumentList ($args + @("-UmaVolta")) -PassThru -WindowStyle Minimized
    $sup2.WaitForExit(60000) | Out-Null
    Ok (Vivo $pidVivo) "segunda instancia ADOTOU o bot em vez de mata-lo"
    $conteudo2 = Get-Content $logSup.FullName -Raw -ErrorAction SilentlyContinue
    Ok ($conteudo2 -match 'adotando processo ja em execucao') "a adocao ficou registrada no log"

    # --- 5) sentinela desliga a vigilancia sem derrubar o bot -------------------------------
    New-Item -ItemType File -Path $sentinela -Force | Out-Null
    Ok (Espera { -not (Vivo $supProc.Id) } 30 "saida do supervisor") "sentinela encerrou o laco de supervisao"
    Ok (Vivo $pidVivo) "o bot continua rodando depois da sentinela (kill-switch nao derruba o bot)"
}
finally {
    if (Vivo $supProc.Id) { Stop-Process -Id $supProc.Id -Force -ErrorAction SilentlyContinue }
    Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*fake-bot.js*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($falhas -eq 0) { Write-Host "RESULTADO: tudo ok" } else { Write-Host "RESULTADO: $falhas falha(s)" }
exit $falhas
