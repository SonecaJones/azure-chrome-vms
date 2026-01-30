# configure-vm-image.ps1
# Execute este script na VM ANTES de criar a imagem

param(
    [string]$AutoLoginUser = "robodpc",
    [string]$AutoLoginPassword = "robodpc2025#",
    [string]$RdpUser = "rdpadmin",
    [string]$RdpPassword = "SenhaSegura123!"
)

Start-Transcript -Path "C:\logs\vm-image-config.log"

Write-Host "=========================================="
Write-Host "CONFIGURACAO DA IMAGEM ROBODPC"
Write-Host "=========================================="

# 1. Criar pasta de scripts
$scriptsPath = "C:\Scripts"
$logsPath = "C:\logs"
New-Item -ItemType Directory -Force -Path $scriptsPath
New-Item -ItemType Directory -Force -Path $logsPath
Write-Host "Pastas criadas"

# 2. Configurar Autologon
Write-Host ""
Write-Host "--- Configurando Autologon ---"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultUsername" -Value $AutoLoginUser
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultPassword" -Value $AutoLoginPassword
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultDomainName" -Value $env:COMPUTERNAME
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "ForceAutoLogon" -Value "1"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "dontdisplaylastusername" -Value 0

# Desabilitar tela de bloqueio
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Value 1
Write-Host "Autologon configurado para: $AutoLoginUser"

# 3. Criar script de verificacao de GUI
$ensureGuiScript = @'
Start-Transcript -Path "C:\logs\gui-session-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Write-Host "Verificando sessao grafica..."
$timeout = 120
$elapsed = 0
while ($elapsed -lt $timeout) {
    if (Get-Process explorer -ErrorAction SilentlyContinue) {
        Write-Host "Explorer.exe detectado! Sessao grafica ativa."
        break
    }
    Write-Host "Aguardando... ($elapsed seg)"
    Start-Sleep -Seconds 5
    $elapsed += 5
}
if ($elapsed -ge $timeout) {
    Write-Host "Forcando inicio do Explorer..."
    Start-Process explorer.exe
    Start-Sleep -Seconds 10
}
Write-Host "Session ID: $((Get-Process -Id $PID).SessionId)"
Write-Host "Usuario: $env:USERNAME"
Stop-Transcript
'@
Set-Content -Path "$scriptsPath\ensure-gui-session.ps1" -Value $ensureGuiScript
Write-Host "Script GUI criado"

# 4. Criar script master de startup
$startupMasterScript = @'
Start-Transcript -Path "C:\logs\startup-master-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Write-Host "=== STARTUP MASTER ==="
Write-Host "Usuario: $env:USERNAME"
Write-Host "Data: $(Get-Date)"

# Garantir GUI
& "C:\Scripts\ensure-gui-session.ps1"

# Aguardar rede
Write-Host "Aguardando rede..."
for ($i = 0; $i -lt 30; $i++) {
    if (Test-Connection 8.8.8.8 -Count 1 -Quiet) {
        Write-Host "Rede OK"
        break
    }
    Start-Sleep -Seconds 2
}

# Iniciar Chrome
Write-Host "Iniciando Chrome..."
$chromeExe = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (Test-Path $chromeExe) {
    $chrome = Start-Process $chromeExe -ArgumentList "--remote-debugging-port=9222","--user-data-dir=C:\chrome-debug-profile" -PassThru
    Write-Host "Chrome PID: $($chrome.Id)"
    Start-Sleep -Seconds 10
}

# Iniciar Node
Write-Host "Iniciando Node..."
$scriptPath = "C:\dpc\dpc-interno-rep\index.js"
if (Test-Path $scriptPath) {
    Set-Location "C:\dpc\dpc-interno-rep"
    
    $logFile = "C:\logs\node-output-$(Get-Date -Format 'yyyyMMdd').log"
    
    $node = Start-Process node `
        -ArgumentList $scriptPath `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError "C:\logs\node-errors-$(Get-Date -Format 'yyyyMMdd').log" `
        -PassThru `
        -WindowStyle Hidden
    
    Write-Host "Node PID: $($node.Id)"
    Write-Host "Log: $logFile"
}

Write-Host "=== STARTUP CONCLUIDO ==="
Stop-Transcript
'@
Set-Content -Path "$scriptsPath\startup-master.ps1" -Value $startupMasterScript
Write-Host "Script master criado"

# 5. Criar atalho na Startup
Write-Host ""
Write-Host "--- Configurando Startup ---"
$startupFolder = "C:\Users\$AutoLoginUser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Force -Path $startupFolder | Out-Null

$shortcutPath = "$startupFolder\RoboDPC-Startup.lnk"
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($shortcutPath)
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\startup-master.ps1"
$Shortcut.WorkingDirectory = "C:\Scripts"
$Shortcut.Save()
Write-Host "Atalho criado em Startup"

# 6. Criar usuario RDP
Write-Host ""
Write-Host "--- Configurando usuario RDP ---"
$rdpPasswordSecure = ConvertTo-SecureString $RdpPassword -AsPlainText -Force
$userExists = Get-LocalUser -Name $RdpUser -ErrorAction SilentlyContinue
if (-not $userExists) {
    New-LocalUser -Name $RdpUser -Password $rdpPasswordSecure -FullName "RDP Administrator" -Description "Usuario para acesso RDP" -PasswordNeverExpires:$true
    Write-Host "Usuario $RdpUser criado"
}
else {
    Write-Host "Usuario $RdpUser ja existe"
}
Add-LocalGroupMember -Group "Administrators" -Member $RdpUser -ErrorAction SilentlyContinue

# 7. Configurar RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fSingleSessionPerUser /t REG_DWORD /d 0 /f
Write-Host "RDP configurado"

Write-Host ""
Write-Host "=========================================="
Write-Host "CONFIGURACAO CONCLUIDA!"
Write-Host "=========================================="
Write-Host ""
Write-Host "Resumo:"
Write-Host "- Autologon: $AutoLoginUser (sessao grafica completa)"
Write-Host "- Usuario RDP: $RdpUser"
Write-Host "- Scripts em: $scriptsPath"
Write-Host "- Logs em: $logsPath"
Write-Host ""
Write-Host "Proximos passos:"
Write-Host "1. Teste reiniciando a VM"
Write-Host "2. Verifique se Chrome e Node iniciam automaticamente"
Write-Host "3. Conecte via RDP com o usuario RDP para verificar"
Write-Host "4. Se tudo OK, capture a imagem"

Stop-Transcript