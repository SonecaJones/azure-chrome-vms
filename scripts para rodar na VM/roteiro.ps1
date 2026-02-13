instalar node
instalar chrome

# Salvar o script
notepad C:\setup-complete-vm.ps1

# Colar o conteúdo acima

# Executar
cd C:\
.\setup-complete-vm.ps1

# OU com parâmetros customizados:
.\setup-complete-vm.ps1 -UserName "meuuser" -UserPassword "MinhaS3nh@" -VncPassword "VNC123" -NodeScriptPath "C:\meu\app\server.js"

# Ver log de instalação
Get-Content C:\logs\setup-complete-vm.log

# Ver log de startup
Get-Content C:\logs\startup-master-*.log | Select-Object -Last 100

# Ver logs do Node em tempo real
Get-Content C:\logs\node\output-$(Get-Date -Format 'yyyyMMdd').log -Wait -Tail 50