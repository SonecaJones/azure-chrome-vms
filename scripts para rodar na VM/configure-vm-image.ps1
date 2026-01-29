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
Write-Host "CONFIGURAÇÃO DA IMAGEM ROBODPC"
Write-Host "=========================================="

# 1. Criar pasta de scripts
$scriptsPath = "C:\Scripts"
$logsPath = "C:\logs"
New-Item -ItemType Directory -Force -Path $scriptsPath
New-Item -ItemType Directory -Force -Path $logsPath
Write-Host "✓ Pastas criadas"

# 2. Configurar Autologon
Write-Host "`n--- Configurando Autologon ---"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultUsername" -Value $AutoLoginUser
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultPassword" -Value $AutoLoginPassword
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultDomainName" -Value $env:COMPUTERNAME
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "ForceAutoLogon" -Value "1"
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "dontdisplaylastusername" -Value 0

# Desabilitar tela de bloqueio
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Value 1
Write-Host "✓ Autologon configurado para: $AutoLoginUser"

# 3. Criar script de verificação de GUI
$ensureGuiScript = @'
Start-Transcript -Path "C:\logs\gui-session-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Write-Host "Verificando sessão gráfica..."
$timeout = 120
$elapsed = 0
while ($elapsed -lt $timeout) {
    if (Get-Process explorer -ErrorAction SilentlyContinue) {
        Write-Host "✓ Explorer.exe detectado! Sessão gráfica ativa."
        break
    }
    Write-Host "Aguardando... ($elapsed seg)"
    Start-Sleep -Seconds 5
    $elapsed += 5
}
if ($elapsed -ge $timeout) {
    Write-Host "⚠ Forçando inicio do Explorer..."
    Start-Process explorer.exe
    Start-Sleep -Seconds 10
}
Write-Host "Session ID: $((Get-Process -Id $PID).SessionId)"
Write-Host "Usuário: $env:USERNAME"
Stop-Transcript
'@
Set-Content -Path "$scriptsPath\ensure-gui-session.ps1" -Value $ensureGuiScript
Write-Host "✓ Script GUI criado"

# 4. Criar script master de startup
$startupMasterScript = @'
Start-Transcript -Path "C:\logs\startup-master-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Write-Host "=== STARTUP MASTER ==="
Write-Host "Usuário: $env:USERNAME"
Write-Host "Data: $(Get-Date)"

# Garantir GUI
& "C:\Scripts\ensure-gui-session.ps1"

# Aguardar rede
Write-Host "Aguardando rede..."
for ($i = 0; $i -lt 30; $i++) {
    if (Test-Connection 8.8.8.8 -Count 1 -Quiet) {
        Write-Host "✓ Rede OK"
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
$scriptPath = "C:\dpc\dpc-interno-rep\index.js"  # AJUSTE AQUI
if (Test-Path $scriptPath) {
    Set-Location "C:\dpc\dpc-interno-rep"
    $node = Start-Process node -ArgumentList $scriptPath -PassThru
    Write-Host "Node PID: $($node.Id)"
}

Write-Host "=== STARTUP CONCLUÍDO ==="
Stop-Transcript
'@
Set-Content -Path "$scriptsPath\startup-master.ps1" -Value $startupMasterScript
Write-Host "✓ Script master criado"

# 5. Criar atalho na Startup
Write-Host "`n--- Configurando Startup ---"
$startupFolder = "C:\Users\$AutoLoginUser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Force -Path $startupFolder | Out-Null

$shortcutPath = "$startupFolder\RoboDPC-Startup.lnk"
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($shortcutPath)
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\startup-master.ps1"
$Shortcut.WorkingDirectory = "C:\Scripts"
$Shortcut.Save()
Write-Host "✓ Atalho criado em Startup"

# 6. Criar usuário RDP
Write-Host "`n--- Configurando usuário RDP ---"
$rdpPasswordSecure = ConvertTo-SecureString $RdpPassword -AsPlainText -Force
$userExists = Get-LocalUser -Name $RdpUser -ErrorAction SilentlyContinue
if (-not $userExists) {
    New-LocalUser -Name $RdpUser -Password $rdpPasswordSecure -FullName "RDP Administrator" -PasswordNeverExpires $true
    Write-Host "✓ Usuário $RdpUser criado"
} else {
    Write-Host "! Usuário $RdpUser já existe"
}
Add-LocalGroupMember -Group "Administrators" -Member $RdpUser -ErrorAction SilentlyContinue

# 7. Configurar RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fSingleSessionPerUser /t REG_DWORD /d 0 /f
Write-Host "✓ RDP configurado"

Write-Host "`n=========================================="
Write-Host "CONFIGURAÇÃO CONCLUÍDA!"
Write-Host "=========================================="
Write-Host "`nResumo:"
Write-Host "- Autologon: $AutoLoginUser (sessão gráfica completa)"
Write-Host "- Usuário RDP: $RdpUser"
Write-Host "- Scripts em: $scriptsPath"
Write-Host "- Logs em: $logsPath"
Write-Host "`nPróximos passos:"
Write-Host "1. Teste reiniciando a VM"
Write-Host "2. Verifique se Chrome e Node iniciam automaticamente"
Write-Host "3. Conecte via RDP com '$RdpUser' para verificar"
Write-Host "4. Se tudo OK, capture a imagem"

Stop-Transcript