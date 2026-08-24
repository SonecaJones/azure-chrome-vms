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

# --- LOGS DO BOT ---
# O startup-master.ps1 redireciona stdout+stderr do node para arquivo e abre uma 2a janela
# so de acompanhamento. O nome do log leva a VM (o antigo output-<data>.log era so por data,
# e na pratica ficava vazio: o redirecionamento estava montado numa variavel que ninguem usava).

# Ver o log corrente em tempo real (o ponteiro evita adivinhar data/nome):
Get-Content (Get-Content C:\logs\node\bot-atual.txt) -Wait -Tail 50

# Ou pelo nome completo:
Get-Content C:\logs\node\bot-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd').log -Wait -Tail 50

# --- BAIXAR OS LOGS DA FROTA INTEIRA (roda no notebook, nao na VM) ---
# Depois da tentativa e ANTES de desligar/derrubar as VMs (run-command exige VM ligada):
#   cd ..\ ; .\coletar-logs-vmss.ps1 -DryRun          # so lista o alcance
#   .\coletar-logs-vmss.ps1 -Desde 20260824           # coleta de verdade