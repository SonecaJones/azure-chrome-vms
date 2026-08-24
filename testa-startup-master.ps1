# Valida o S1 sem Azure e sem executar nada.
#   1) o .ps1 gerador parseia;
#   2) a here-string $startupMasterScript e expandida DE VERDADE (executando o proprio
#      bloco, nao simulando com ExpandString - a semantica de aspas difere);
#   3) o startup-master.ps1 produzido parseia;
#   4) o produto tem o redirecionamento, a janela de tail e o ponteiro, e preserva o que
#      ja funcionava;
#   5) a command line do cmd, expandida com valores de runtime, sai correta.
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
$sb = [scriptblock]::Create('$NodeScriptPath = "C:\dpc\dpc-interno-rep\index.js"' + "`r`n" + $m.Value + "`r`n" + '$startupMasterScript')
$produto = & $sb

$errs2 = $null
[System.Management.Automation.Language.Parser]::ParseInput($produto, [ref]$null, [ref]$errs2) | Out-Null
Ok ($errs2.Count -eq 0) "startup-master.ps1 produzido parseia (erros: $($errs2.Count))"
$errs2 | Select-Object -First 3 | ForEach-Object { Write-Host "          L$($_.Extent.StartLineNumber): $($_.Message)" }

# --- o que o S1 introduz -------------------------------------------------------
$esperado = @(
    @{ t = 'node $scriptPath >> ""$outputLog"" 2>&1'; d = 'node redireciona stdout+stderr para arquivo' },
    @{ t = '$outputLog = "$logsDir\bot-$vmName-$logDate.log"'; d = 'log nomeado pela VM, nao so pela data' },
    @{ t = "Get-Content -Path '`$outputLog' -Wait -Tail 50"; d = 'janela de tail para acompanhar por VNC' },
    @{ t = '$outputLog | Set-Content "$logsDir\bot-atual.txt"'; d = 'ponteiro bot-atual.txt para o coletor' }
)
foreach ($e in $esperado) { Ok ($produto.Contains($e.t)) $e.d }

# --- o que o S1 remove ---------------------------------------------------------
foreach ($e in @(
    @{ t = 'nodeCommand'; d = 'linha morta $nodeCommand removida' },
    @{ t = 'errorLog';    d = 'errors-*.log fantasma removido' }
)) { Ok (-not $produto.Contains($e.t)) $e.d }

# --- o que NAO pode ter mudado -------------------------------------------------
foreach ($e in @(
    @{ t = '| Add-Content $outputLog';                     d = 'cabecalho de boot preservado' },
    @{ t = '$node.Id | Set-Content "$logsDir\node.pid"';   d = 'node.pid preservado' },
    @{ t = 'Get-Process node -ErrorAction SilentlyContinue'; d = 'kill de node antigo preservado' },
    @{ t = 'Start-Transcript';                             d = 'transcript do startup preservado' },
    @{ t = 'http://169.254.169.254/metadata/instance';     d = 'metadata da VM preservado' }
)) { Ok ($produto.Contains($e.t)) $e.d }

# --- command line real do cmd --------------------------------------------------
$linha = @($produto -split "`r?`n" | Where-Object { $_ -match '-ArgumentList "/k cd /d' })
Ok ($linha.Count -eq 1) "uma unica linha -ArgumentList do cmd"
if ($linha.Count -eq 1 -and -not $Legado) {
    $vmName = "VMSSRoboDPC-brazilsouth_3"; $vmId = "abc-123"
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
