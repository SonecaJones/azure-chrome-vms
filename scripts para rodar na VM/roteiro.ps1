# 1. Execute o script de configuração
.\configure-vm-image.ps1

# 2. AJUSTE o caminho do seu script Node no startup-master.ps1
# Edite: C:\Scripts\startup-master.ps1
# Linha: $scriptPath = "C:\dpc\dpc-interno-rep\SEU-SCRIPT.js"

# 3. Reinicie e teste
Restart-Computer

# 4. Após reiniciar, verifique os logs
Get-Content C:\logs\startup-master-*.log -Tail 50

# 5. Se tudo estiver OK, capture a imagem
# (NÃO execute sysprep se quiser imagem especializada)