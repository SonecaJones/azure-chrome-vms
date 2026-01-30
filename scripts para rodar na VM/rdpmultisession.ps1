# enable-multiple-rdp-sessions.ps1

Start-Transcript -Path "C:\logs\enable-multiple-sessions.log"

Write-Host "Habilitando multiplas sessoes RDP simultaneas..."

# 1. Permitir múltiplas sessões por usuário
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fSingleSessionPerUser" -Value 0
Write-Host "fSingleSessionPerUser = 0"

# 2. Habilitar Remote Desktop
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Write-Host "RDP habilitado"

# 3. Permitir conexões de qualquer versão do RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 0
Write-Host "UserAuthentication configurado"

# 4. Desabilitar limite de conexões
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\Licensing Core' -Name "EnableConcurrentSessions" -Value 1 -ErrorAction SilentlyContinue
Write-Host "Sessoes concorrentes habilitadas"

# 5. Aumentar o número máximo de conexões
New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "MaxInstanceCount" -Value 999999 -PropertyType DWORD -Force
Write-Host "MaxInstanceCount configurado"

# 6. Configurar para não desconectar sessões existentes
Set-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services' -Name "MaxDisconnectionTime" -Value 0 -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKLM:\Software\Policies\Microsoft\Windows NT\Terminal Services' -Name "MaxIdleTime" -Value 0 -Force -ErrorAction SilentlyContinue
Write-Host "Timeouts desabilitados"

# 7. Reiniciar serviço Terminal Services
Write-Host "Reiniciando servico Terminal Services..."
Restart-Service TermService -Force
Write-Host "Servico reiniciado"

Write-Host ""
Write-Host "=========================================="
Write-Host "CONFIGURACAO CONCLUIDA"
Write-Host "=========================================="
Write-Host "Agora voce pode conectar via RDP sem desconectar o autologon"
Write-Host ""
Write-Host "Teste conectando com:"
Write-Host "- Usuario: rdpadmin"
Write-Host "- Senha: SenhaSegura123"

Stop-Transcript