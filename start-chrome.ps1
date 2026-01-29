$LogFile = "C:\dpc\startup_log.txt"

function Log($msg) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$timestamp - $msg"
}

Log "=== SCRIPT INICIADO ==="

try {
    Log "Esperando explorer..."
    while (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Log "explorer ainda não iniciou"
        Start-Sleep -Seconds 1
    }

    Log "Explorer iniciado!"

    Log "Esperando DWM..."
    while (-not (Get-Process dwm -ErrorAction SilentlyContinue)) {
        Log "dwm ainda não iniciou"
        Start-Sleep -Seconds 1
    }

    Log "DWM iniciado!"

    Log "Esperando StartMenuExperienceHost..."
    while (-not (Get-Process StartMenuExperienceHost -ErrorAction SilentlyContinue)) {
        Log "StartMenuExperienceHost ainda não iniciou"
        Start-Sleep -Seconds 1
    }

    Log "StartMenuExperienceHost iniciado!"

    Log "Aguardando 10s adicionais para estabilizar o desktop..."
    Start-Sleep -Seconds 10

    Log "Desktop totalmente carregado"

    Log "Aguardando 30s extras..."
    Start-Sleep -Seconds 30

    Log "Iniciando npm start em C:\dpc\dpc-interno-rep"

    Start-Process "powershell.exe" `
        -WorkingDirectory "C:\dpc\dpc-interno-rep" `
        -ArgumentList "-NoExit", "-Command", "npm start"

    Log "Processo npm start iniciado (Start-Process OK)"

} catch {
    Log "❌ ERRO no script: $($_.Exception.Message)"
}

Log "=== SCRIPT FINALIZADO ==="
