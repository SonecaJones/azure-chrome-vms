# Valida o gerador de scripts da VM sem Azure e sem executar nada.
#   1) o .ps1 gerador parseia;
#   2) as here-strings $startupMasterScript e $botSupervisorScript sao expandidas DE VERDADE
#      (executando o proprio bloco, nao simulando com ExpandString - a semantica de aspas difere);
#   3) os dois scripts produzidos parseiam;
#   4) o produto tem o redirecionamento, a janela de tail, o ponteiro e a supervisao, e preserva
#      o que ja funcionava;
#   5) a command line do cmd, expandida com valores de runtime, sai correta.
#
# O startup-master DELEGA a partida do bot ao bot-supervisor.ps1, entao os asserts de log/redireciona-
# mento valem sobre a CONCATENACAO dos dois produtos - e o teste cobre tambem que a delegacao existe.
param([Parameter(Mandatory=$true)][string]$Arquivo, [switch]$Legado)

$ErrorActionPreference = "Continue"
$falhas = 0
function Ok($cond, $msg) {
    if ($cond) { Write-Host "  [ok]    $msg" }
    else       { Write-Host "  [FALHA] $msg"; $script:falhas++ }
}

Write-Host ""
Write-Host "=== $(Split-Path $Arquivo -Leaf) ==="

$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($Arquivo, [ref]$null, [ref]$errs) | Out-Null
Ok ($errs.Count -eq 0) "gerador parseia (erros: $($errs.Count))"
$errs | Select-Object -First 3 | ForEach-Object { Write-Host "          $($_.Message)" }

$txt = Get-Content $Arquivo -Raw
$m = [regex]::Match($txt, '\$startupMasterScript = @"\r?\n.*?\r?\n"@', 'Singleline')
Ok $m.Success "here-string do startup-master encontrada"
if (-not $m.Success) { exit 1 }

# Expansao fiel: executa a propria atribuicao da here-string.
$prologo = '$NodeScriptPath = "C:\dpc\dpc-interno-rep\index.js"' + "`r`n" + '$argSupervisor = ""' + "`r`n"
$sb = [scriptblock]::Create($prologo + $m.Value + "`r`n" + '$startupMasterScript')
$produtoMaster = & $sb

$errs2 = $null
[System.Management.Automation.Language.Parser]::ParseInput($produtoMaster, [ref]$null, [ref]$errs2) | Out-Null
Ok ($errs2.Count -eq 0) "startup-master.ps1 produzido parseia (erros: $($errs2.Count))"
$errs2 | Select-Object -First 3 | ForEach-Object { Write-Host "          L$($_.Extent.StartLineNumber): $($_.Message)" }

# --- supervisor: here-string LITERAL (@'...'@), nao interpola nada ---------------
$produtoSup = ""
if (-not $Legado) {
    $ms = [regex]::Match($txt, "\`$botSupervisorScript = @'\r?\n.*?\r?\n'@", 'Singleline')
    Ok $ms.Success "here-string do bot-supervisor encontrada"
    if ($ms.Success) {
        $produtoSup = & ([scriptblock]::Create($ms.Value + "`r`n" + '$botSupervisorScript'))
        $errs3 = $null
        [System.Management.Automation.Language.Parser]::ParseInput($produtoSup, [ref]$null, [ref]$errs3) | Out-Null
        Ok ($errs3.Count -eq 0) "bot-supervisor.ps1 produzido parseia (erros: $($errs3.Count))"
        $errs3 | Select-Object -First 3 | ForEach-Object { Write-Host "          L$($_.Extent.StartLineNumber): $($_.Message)" }
    }
}

# Os asserts de partida do bot valem sobre os dois produtos: as linhas migraram do master para o
# supervisor, mas o COMPORTAMENTO tem de continuar presente na imagem.
$produto = $produtoMaster + "`r`n" + $produtoSup

# --- log em arquivo (S1) --------------------------------------------------------
$esperado = @(
    @{ t = 'node $scriptPath >> ""$outputLog"" 2>&1'; d = 'node redireciona stdout+stderr para arquivo' },
    @{ t = '$outputLog = "$logsDir\bot-$vmName-$logDate.log"'; d = 'log nomeado pela VM, nao so pela data' },
    @{ t = "Get-Content -Path '`$outputLog' -Wait -Tail 50"; d = 'janela de tail para acompanhar por VNC' },
    @{ t = '$outputLog | Set-Content "$logsDir\bot-atual.txt"'; d = 'ponteiro bot-atual.txt para o coletor' }
)
foreach ($e in $esperado) { Ok ($produto.Contains($e.t)) $e.d }

# --- o que o S1 removeu ---------------------------------------------------------
foreach ($e in @(
    @{ t = 'nodeCommand'; d = 'linha morta $nodeCommand removida' },
    @{ t = 'errorLog';    d = 'errors-*.log fantasma removido' }
)) { Ok (-not $produto.Contains($e.t)) $e.d }

# --- o que NAO pode ter mudado --------------------------------------------------
foreach ($e in @(
    @{ t = '| Add-Content $outputLog';                 d = 'cabecalho de boot preservado' },
    @{ t = 'Start-Transcript';                         d = 'transcript do startup preservado' },
    @{ t = 'http://169.254.169.254/metadata/instance'; d = 'metadata da VM preservado' }
)) { Ok ($produto.Contains($e.t)) $e.d }

if (-not $Legado) {
    # --- supervisao -------------------------------------------------------------
    foreach ($e in @(
        @{ t = 'C:\Scripts\bot-supervisor.ps1'; d = 'startup-master delega a partida ao supervisor' },
        @{ t = 'while ($true)';                 d = 'laco de supervisao presente' },
        @{ t = '[SUPERVISOR]';                  d = 'log proprio do supervisor' },
        @{ t = 'C:\Scripts\supervisor.off';     d = 'kill-switch por sentinela (desliga sem derrubar o bot)' },
        @{ t = 'supervisor-$VmName-$(Get-Date -Format ''yyyyMMdd'').log'; d = 'log do supervisor por VM e por data' }
    )) { Ok ($produto.Contains($e.t)) $e.d }

    # O PID que interessa e o do NODE. `Start-Process cmd -PassThru` devolve o PID do CMD, e com /k
    # o cmd sobrevive a morte do node: vigiar aquele PID diria "saudavel" para sempre.
    Ok ($produtoSup.Contains('ParentProcessId=$cmdPid')) 'supervisor resolve o PID do processo FILHO (nao o do cmd)'
    Ok ($produtoSup.Contains('$botPid | Set-Content "$logsDir\node.pid"')) 'node.pid guarda o PID do node (antes ia o do cmd)'
    Ok (-not $produtoSup.Contains('$node.Id | Set-Content')) 'node.pid nao usa mais o PID do Start-Process'

    # O nome do log carrega a data: se ela fosse calculada uma vez so, o log viraria em silencio
    # na meia-noite e o restart continuaria escrevendo no arquivo do dia anterior.
    $corpoSobeBot = [regex]::Match($produtoSup, 'function Sobe-Bot \{.*?\r?\n\}', 'Singleline').Value
    Ok ($corpoSobeBot -and $corpoSobeBot.Contains("`$logDate = Get-Date -Format 'yyyyMMdd'")) 'a data do log e reavaliada a cada restart'

    # Reexecutar o startup (run-command, segundo disparo da Startup) nao pode matar um bot vivo.
    Ok ($produtoSup.Contains('adotando processo ja em execucao')) 'node saudavel e ADOTADO'
    Ok (-not $produto.Contains('Get-Process node -ErrorAction SilentlyContinue')) 'kill incondicional de node REMOVIDO (mudanca deliberada)'
    Ok ($produtoMaster.Contains('startup-master ja em execucao')) 'guarda de instancia unica no startup-master'

    # O Chrome fica de fora de proposito: o perfil aquecido na 9222 carrega o cf_clearance, que o
    # abreDPC reaproveita no restart.
    Ok (-not $produtoSup.Contains('Stop-Process -Name chrome')) 'supervisor nao mata o Chrome (preserva o cf_clearance)'
}

# --- command line real do cmd ---------------------------------------------------
$linha = @($produto -split "`r?`n" | Where-Object { $_ -match '-ArgumentList "/k cd /d' })
Ok ($linha.Count -eq 1) "uma unica linha -ArgumentList do cmd"
if ($linha.Count -eq 1 -and -not $Legado) {
    $vmName = "VMSSRoboDPC_3"; $vmId = "abc-123"
    $scriptDir = "C:\dpc\dpc-interno-rep"; $scriptPath = "$scriptDir\index.js"
    $logsDir = "C:\logs\node"; $outputLog = "$logsDir\bot-$vmName-20260823.log"
    $bruto = $linha[0].Trim()
    $bruto = $bruto.Substring($bruto.IndexOf('"')).TrimEnd('`').Trim()
    $cmdline = & ([scriptblock]::Create($bruto))
    Write-Host "  cmd  -> $cmdline"
    $alvo = 'node ' + $scriptPath + ' >> "' + $outputLog + '" 2>&1'
    Ok ($cmdline.Contains($alvo)) "command line final do cmd correta"
    Ok ($cmdline.StartsWith("/k cd /d $scriptDir &&")) "cmd ainda entra no diretorio do bot"
    Ok ($cmdline.Contains("set AZURE_VM_NAME=$vmName")) "envs AZURE_VM_* preservadas"
}

Write-Host ""
if ($falhas -eq 0) { Write-Host "RESULTADO: tudo ok" } else { Write-Host "RESULTADO: $falhas falha(s)" }
exit $falhas
