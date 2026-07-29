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

# --- set-resolution.ps1 (FERRAMENTA MANUAL, nao roda no startup) ---
# A VM sobe em ~1024x768 sem monitor. Isso NAO era a causa da falha do desafio Cloudflare — em
# 2026-07-28 ficou provado que a causa era o `scale: 0.15` do clip em `captureAndSave`, que
# encolhia a pagina renderizada a 15%. Use este script so para diagnostico ou para acompanhar a
# VM por VNC/RDP numa tela maior.

# Ver o que o driver de video oferece (nao altera nada):
.\set-resolution.ps1 -Query

# Aplicar pontualmente (idempotente; persiste via CDS_UPDATEREGISTRY):
.\set-resolution.ps1

# Ver logs do Node em tempo real
Get-Content C:\logs\node\output-$(Get-Date -Format 'yyyyMMdd').log -Wait -Tail 50