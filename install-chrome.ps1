# ================================================================
# install-chrome.ps1
# Script para uso em Custom Script Extension no Azure
# Instala Google Chrome, cria auto-start e abre Chrome com CDP 9222
# ================================================================

Write-Output "====== SCRIPT INICIADO ======"

# ------------------------------------------------
# 1. Baixar instalador do Chrome
# ------------------------------------------------

$chromeUrl = "https://dl.google.com/chrome/install/latest/chrome_installer.exe"
$installer = "$env:TEMP\chrome_installer.exe"

Write-Output "Baixando Chrome..."
Invoke-WebRequest $chromeUrl -OutFile $installer -UseBasicParsing

# ------------------------------------------------
# 2. Instalar Chrome silenciosamente
# ------------------------------------------------

Write-Output "Instalando Chrome..."
Start-Process $installer -ArgumentList "/silent /install" -Wait

# ------------------------------------------------
# 3. Criar script de inicialização automática
# ------------------------------------------------

Write-Output "Criando script de auto-start do Chrome (porta 9222)..."

$startScriptPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\chrome_autostart.ps1"

$startScriptContent = @"
Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9223 --user-data-dir="C:\chrome-data" --no-first-run --no-default-browser-check --disable-popup-blocking --ignore-certificate-errors
"@

$startScriptContent | Out-File -FilePath $startScriptPath -Encoding UTF8 -Force

# ------------------------------------------------
# 4. Permitir porta 9222 no firewall interno
# ------------------------------------------------

Write-Output "Liberando porta 9222 no firewall interno..."

New-NetFirewallRule `
  -DisplayName "Chrome CDP SSH 9222" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 9222 `
  -Action Allow `
  -ErrorAction SilentlyContinue

Write-Output "Liberando porta 22 no firewall interno..."

New-NetFirewallRule `
  -DisplayName "SSH 22" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 22 `
  -Action Allow `
  -ErrorAction SilentlyContinue

# ------------------------------------------------
# 5. Criar atalho para executar o script no startup via PowerShell
#    (necessário porque Windows ignora .ps1 direto no Startup)
# ------------------------------------------------

Write-Output "Criando atalho de inicialização..."

$shortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\chrome_autostart.lnk"

$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut($shortcutPath)
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -File `"$startScriptPath`""
$Shortcut.Save()


Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH*'

Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0

Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# Start the sshd service
Start-Service sshd

# OPTIONAL but recommended:
Set-Service -Name sshd -StartupType 'Automatic'

# ------------------------------------------------
# 6. Conclusão
# ------------------------------------------------

Write-Output "====== SCRIPT CONCLUÍDO COM SUCESSO ======"
