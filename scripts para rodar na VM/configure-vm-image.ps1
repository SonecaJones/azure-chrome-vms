# setup-complete-vm-uniform.ps1
# SCRIPT COMPLETO OTIMIZADO PARA MODO UNIFORM
# 1 usuário + autologon + VNC + Chrome + Node
# Versão: 2.1 - Uniform Mode
# Data: 2026-01-30

param(
    [string]$UserName = "robodpc",
    [string]$UserPassword = "robodpc2025#",
    [string]$VncPassword = "RoboVNC2025",
    [string]$NodeScriptPath = "C:\dpc\dpc-interno-rep\index.js"
)

$ErrorActionPreference = "Continue"

Start-Transcript -Path "C:\logs\setup-complete-vm.log"

Write-Host ""
Write-Host "=========================================="
Write-Host "SETUP VM ROBODPC - UNIFORM MODE"
Write-Host "=========================================="
Write-Host "Data: $(Get-Date)"
Write-Host "Usuario: $UserName"
Write-Host "Node Script: $NodeScriptPath"
Write-Host ""

# ============================================
# PARTE 1: ESTRUTURA DE PASTAS
# ============================================
Write-Host "--- Criando estrutura de pastas ---"
$folders = @(
    "C:\Scripts",
    "C:\logs",
    "C:\logs\node",
    "C:\temp"
)

foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Write-Host "Pasta criada: $folder"
    } else {
        Write-Host "Pasta já existe: $folder"
    }
}

# ============================================
# PARTE 2: CONFIGURAR USUÁRIO PRINCIPAL
# ============================================
Write-Host ""
Write-Host "--- Configurando usuário ---"

# Garantir que usuário principal existe
$userExists = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if (-not $userExists) {
    $securePassword = ConvertTo-SecureString $UserPassword -AsPlainText -Force
    New-LocalUser -Name $UserName `
        -Password $securePassword `
        -FullName "RoboDPC User" `
        -Description "Usuario principal RoboDPC" `
        -AccountNeverExpires `
        -PasswordNeverExpires:$true `
        -UserMayNotChangePassword:$false
    Write-Host "Usuario criado: $UserName"
} else {
    Write-Host "Usuario já existe: $UserName"
    # Atualizar senha
    $securePassword = ConvertTo-SecureString $UserPassword -AsPlainText -Force
    Set-LocalUser -Name $UserName -Password $securePassword
    Write-Host "Senha atualizada: $UserName"
}

# Adicionar ao grupo Administrators
Add-LocalGroupMember -Group "Administrators" -Member $UserName -ErrorAction SilentlyContinue
Write-Host "Usuario configurado como Administrador: $UserName"

# ============================================
# PARTE 3: CONFIGURAR AUTOLOGON
# ============================================
Write-Host ""
Write-Host "--- Configurando Autologon ---"

Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "AutoAdminLogon" -Value "1" -Type String
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultUsername" -Value $UserName -Type String
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultPassword" -Value $UserPassword -Type String
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "DefaultDomainName" -Value $env:COMPUTERNAME -Type String
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "ForceAutoLogon" -Value "1" -Type String
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "dontdisplaylastusername" -Value 0 -Type DWord

# Desabilitar tela de bloqueio
if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization")) {
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Force | Out-Null
}
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Value 1 -Type DWord

Write-Host "Autologon configurado para: $UserName"

# ============================================
# PARTE 4: INSTALAR E CONFIGURAR VNC
# ============================================
Write-Host ""
Write-Host "--- Instalando TightVNC ---"

$vncUrl = "https://www.tightvnc.com/download/2.8.84/tightvnc-2.8.84-gpl-setup-64bit.msi"
$vncInstaller = "C:\temp\tightvnc-setup.msi"

try {
    Write-Host "Baixando TightVNC..."
    Invoke-WebRequest -Uri $vncUrl -OutFile $vncInstaller -UseBasicParsing
    Write-Host "TightVNC baixado"
    
    # Instalar silenciosamente
    Write-Host "Instalando TightVNC..."
    $installArgs = @(
        "/i"
        "`"$vncInstaller`""
        "/quiet"
        "/norestart"
        "SERVER_REGISTER_AS_SERVICE=1"
        "SERVER_ADD_FIREWALL_EXCEPTION=1"
        "SET_USEVNCAUTHENTICATION=1"
        "VALUE_OF_USEVNCAUTHENTICATION=1"
        "SET_PASSWORD=1"
        "VALUE_OF_PASSWORD=$VncPassword"
        "SET_USECONTROLAUTHENTICATION=1"
        "VALUE_OF_USECONTROLAUTHENTICATION=1"
        "SET_CONTROLPASSWORD=1"
        "VALUE_OF_CONTROLPASSWORD=$VncPassword"
    )
    
    $process = Start-Process msiexec.exe -ArgumentList $installArgs -Wait -NoNewWindow -PassThru
    
    if ($process.ExitCode -eq 0) {
        Write-Host "TightVNC instalado com sucesso"
    } else {
        Write-Host "Código de saída: $($process.ExitCode)"
    }
    
    # Aguardar serviço
    Start-Sleep -Seconds 15
    
    # Configurar serviço VNC
    $vncService = Get-Service -Name "tvnserver" -ErrorAction SilentlyContinue
    if ($vncService) {
        Set-Service -Name "tvnserver" -StartupType Automatic
        Start-Service -Name "tvnserver" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        
        $vncServiceStatus = (Get-Service -Name "tvnserver").Status
        Write-Host "Serviço VNC: $vncServiceStatus"
        
        if ($vncServiceStatus -eq 'Running') {
            Write-Host "VNC configurado e rodando (porta 5900)"
        }
    }
    
} catch {
    Write-Host "ERRO ao instalar VNC: $_"
}

# Configurar Firewall para VNC
Write-Host "Configurando Firewall (porta 5900)..."
try {
    New-NetFirewallRule -DisplayName "TightVNC Server" `
        -Direction Inbound `
        -LocalPort 5900 `
        -Protocol TCP `
        -Action Allow `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Firewall configurado para VNC"
} catch {
    Write-Host "Firewall já configurado"
}

# ============================================
# PARTE 5: CONFIGURAR RDP (OPCIONAL)
# ============================================
# Write-Host ""
# Write-Host "--- Configurando RDP ---"

# Habilitar RDP como fallback
# Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
# Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

# Permitir múltiplas sessões
# Stop-Service TermService -Force -ErrorAction SilentlyContinue
# reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fSingleSessionPerUser /t REG_DWORD /d 0 /f | Out-Null
# reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v MaxInstanceCount /t REG_DWORD /d 999999 /f | Out-Null
# Start-Service TermService -ErrorAction SilentlyContinue

# Write-Host "RDP habilitado (fallback)"

# ============================================
# PARTE 6: SCRIPTS DE STARTUP
# ============================================
Write-Host ""
Write-Host "--- Criando scripts de startup ---"

# Script 1: ensure-gui-session.ps1
$ensureGuiScript = @'
Start-Transcript -Path "C:\logs\gui-session-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Write-Host "Verificando sessão gráfica..."
$timeout = 120
$elapsed = 0
while ($elapsed -lt $timeout) {
    if (Get-Process explorer -ErrorAction SilentlyContinue) {
        Write-Host "Explorer.exe detectado! Sessão gráfica ativa."
        break
    }
    Write-Host "Aguardando GUI... ($elapsed seg)"
    Start-Sleep -Seconds 5
    $elapsed += 5
}
if ($elapsed -ge $timeout) {
    Write-Host "Forçando inicio do Explorer..."
    Start-Process explorer.exe -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
}
Write-Host "Session ID: $((Get-Process -Id $PID).SessionId)"
Write-Host "Usuario: $env:USERNAME"
Stop-Transcript
'@
Set-Content -Path "C:\Scripts\ensure-gui-session.ps1" -Value $ensureGuiScript
Write-Host "Script GUI criado"

# Script 2: startup-master.ps1
$startupMasterScript = @"
Start-Transcript -Path "C:\logs\startup-master-`$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Write-Host "=== STARTUP MASTER ==="
Write-Host "Usuario: `$env:USERNAME"
Write-Host "Data: `$(Get-Date)"
Write-Host "Hostname: `$env:COMPUTERNAME"

# Garantir GUI
& "C:\Scripts\ensure-gui-session.ps1"

# Aguardar rede
Write-Host "Aguardando rede..."
for (`$i = 0; `$i -lt 30; `$i++) {
    if (Test-Connection 8.8.8.8 -Count 1 -Quiet) {
        Write-Host "Rede OK"
        break
    }
    Start-Sleep -Seconds 2
}

# Obter metadata da Azure VM
Write-Host "Obtendo metadata da VM..."
`$vmName = `$env:COMPUTERNAME
`$vmId = "unknown"

try {
    `$metadata = Invoke-RestMethod -Headers @{"Metadata"="true"} -Method GET -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" -TimeoutSec 10
    `$vmName = `$metadata.compute.name
    `$vmId = `$metadata.compute.vmId
    `$vmLocation = `$metadata.compute.location
    
    Write-Host "VM Name: `$vmName"
    Write-Host "VM ID: `$vmId"
    Write-Host "Location: `$vmLocation"
} catch {
    Write-Host "Metadata não disponível"
}

# Atualizar .env com informações da VM
`$scriptDir = Split-Path -Parent "$NodeScriptPath"
`$envFile = Join-Path `$scriptDir ".env"

if (Test-Path `$envFile) {
    Write-Host "Atualizando .env: `$envFile"
    try {
        `$content = Get-Content `$envFile -Raw -ErrorAction SilentlyContinue
        if (`$content) {
            # Remover linhas antigas
            `$content = `$content -replace "VM_NAME=.*``n", ""
            `$content = `$content -replace "VM_ID=.*``n", ""
            `$content = `$content -replace "AZURE_VM_NAME=.*``n", ""
            `$content = `$content -replace "AZURE_VM_ID=.*``n", ""
            
            # Adicionar novas linhas
            `$content += "``nVM_NAME=`$vmName"
            `$content += "``nVM_ID=`$vmId"
            `$content += "``nAZURE_VM_NAME=`$vmName"
            `$content += "``nAZURE_VM_ID=`$vmId"
            
            `$content | Set-Content `$envFile -NoNewline
            Write-Host ".env atualizado"
        }
    } catch {
        Write-Host "Erro ao atualizar .env: `$_"
    }
}

# Verificar VNC
Write-Host "Verificando VNC..."
`$vncService = Get-Service -Name "tvnserver" -ErrorAction SilentlyContinue
if (`$vncService) {
    if (`$vncService.Status -ne 'Running') {
        Write-Host "Iniciando VNC..."
        Start-Service -Name "tvnserver" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    
    `$vncStatus = (Get-Service -Name "tvnserver" -ErrorAction SilentlyContinue).Status
    if (`$vncStatus -eq 'Running') {
        Write-Host "VNC rodando (porta 5900)"
    }
}

# Iniciar Node.js
Write-Host "Iniciando Node.js..."
`$scriptPath = "$NodeScriptPath"
if (Test-Path `$scriptPath) {
    `$scriptDir = Split-Path -Parent `$scriptPath
    Set-Location `$scriptDir
    
    # Variáveis de ambiente
    `$env:AZURE_VM_NAME = `$vmName
    `$env:AZURE_VM_ID = `$vmId
    `$env:NODE_ENV = "production"
    
    # Logs
    `$logsDir = "C:\logs\node"
    New-Item -ItemType Directory -Force -Path `$logsDir | Out-Null
    
    `$logDate = Get-Date -Format 'yyyyMMdd'
    `$outputLog = "`$logsDir\output-`$logDate.log"
    `$errorLog = "`$logsDir\errors-`$logDate.log"
    
    "``n========== VM: `$vmName - Iniciado em `$(Get-Date) ==========" | Add-Content `$outputLog
    
    try {
        # Matar processos Node antigos
        Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        # NOVA FORMA: Abrir Node em janela CMD visível
        `$nodeCommand = "node `$scriptPath` 2>&1 | Tee-Object -FilePath `$outputLog` -Append" ``
        
        `$node = Start-Process cmd.exe ``
            -ArgumentList "/k cd /d `$scriptDir` && set AZURE_VM_NAME=`$vmName` && set AZURE_VM_ID=`$vmId` && node `$scriptPath`" ``
            -PassThru ``
            -WindowStyle Normal`
        
        Write-Host "Node PID: `$(`$node.Id)"
        Write-Host "Output: `$outputLog"
        Write-Host "Errors: `$errorLog"
        
        # Salvar PID
        `$node.Id | Set-Content "`$logsDir\node.pid"
        
        Start-Sleep -Seconds 5
        
        if (Get-Process -Id `$node.Id -ErrorAction SilentlyContinue) {
            Write-Host "Node.js rodando"
        }
        
    } catch {
        Write-Host "Erro ao iniciar Node: `$_"
    }
} else {
    Write-Host "Script Node não encontrado: `$scriptPath"
    Write-Host "AJUSTE: C:\Scripts\startup-master.ps1"
}

Write-Host ""
Write-Host "=== STARTUP CONCLUÍDO ==="
Write-Host "Hostname: `$env:COMPUTERNAME"
Write-Host "Chrome: Debug porta 9222"
Write-Host 'Node.js: Logs em C:\logs\node\'
Write-Host "VNC: Porta 5900"

Stop-Transcript
"@
Set-Content -Path "C:\Scripts\startup-master.ps1" -Value $startupMasterScript
Write-Host "Script master criado"

# ============================================
# PARTE 7: CRIAR ATALHO NA STARTUP
# ============================================
Write-Host ""
Write-Host "--- Configurando Startup ---"

$startupFolder = "C:\Users\$UserName\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Force -Path $startupFolder | Out-Null

$shortcutPath = "$startupFolder\RoboDPC-Startup.lnk"

try {
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($shortcutPath)
    $Shortcut.TargetPath = "powershell.exe"
    $Shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Scripts\startup-master.ps1"
    $Shortcut.WorkingDirectory = "C:\Scripts"
    $Shortcut.Description = "RoboDPC Startup"
    $Shortcut.Save()
    
    Write-Host "Atalho criado: $shortcutPath"
} catch {
    Write-Host "ERRO ao criar atalho: $_"
}

# ============================================
# PARTE 8: CONFIGURAÇÕES FINAIS
# ============================================
Write-Host ""
Write-Host "--- Configurações finais ---"

# Desabilitar UAC
try {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 0 -Type DWord
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 0 -Type DWord
    Write-Host "UAC desabilitado"
} catch {}

# ExecutionPolicy
try {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force
    Write-Host "ExecutionPolicy: Bypass"
} catch {}

# Desabilitar proteção de tela
try {
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ScreenSaveActive" -Value "0" -Type String -ErrorAction SilentlyContinue
} catch {}

# Desabilitar hibernação
try {
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change hibernate-timeout-dc 0
    Write-Host "Hibernação desabilitada"
} catch {}

# ============================================
# RESUMO FINAL
# ============================================
Write-Host ""
Write-Host "=========================================="
Write-Host "CONFIGURAÇÃO COMPLETA!"
Write-Host "=========================================="
Write-Host ""
Write-Host "Usuario: $UserName"
Write-Host "Senha: $UserPassword"
Write-Host "Autologon: Habilitado"
Write-Host ""
Write-Host "VNC Server: Porta 5900"
Write-Host "  Senha: $VncPassword"
Write-Host "  Conectar: <IP>:5900"
Write-Host ""
Write-Host "RDP: Porta 3389 (fallback)"
Write-Host ""
Write-Host "Chrome: Debug porta 9222"
Write-Host 'Node.js: $NodeScriptPath'
Write-Host '  Logs: C:\logs\node\'
Write-Host ""
Write-Host 'PRÓXIMOS PASSOS:'
Write-Host '=========================================='
Write-Host ""
Write-Host '1. Ajuste caminho Node (se necessário):'
Write-Host '   notepad C:\Scripts\startup-master.ps1'
Write-Host ""
Write-Host '2. Reinicie para testar:'
Write-Host "   Restart-Computer"
Write-Host ""
Write-Host '3. Verifique:'
Write-Host '   - VNC: IP:5900'
Write-Host '   - Chrome abrindo'
Write-Host '   - Node rodando'
Write-Host ""
Write-Host '4. Ver logs:'
Write-Host '   Get-Content C:\logs\startup-master-*.log -Tail 100'
Write-Host ""
Write-Host '5. Capture a imagem e crie VMSS Uniform:'
Write-Host ""
Write-Host '   az vmss create \'
Write-Host '     --orchestration-mode Uniform \'
Write-Host '     --computer-name-prefix VMRoboDPC \'
Write-Host '     ...'
Write-Host ""
Write-Host '   Hostnames serão: VMRoboDPC000000, VMRoboDPC000001, etc.'
Write-Host ""
Write-Host '=========================================='

Stop-Transcript

# Perguntar se quer reiniciar
Write-Host ""
$restart = Read-Host 'Reiniciar AGORA para testar? (S/N)'
if ($restart -eq 'S' -or $restart -eq 's') {
    Write-Host ""
    Write-Host 'Reiniciando em 10 segundos...'
    Start-Sleep -Seconds 10
    Restart-Computer -Force
} else {
    Write-Host ""
    Write-Host 'Reinicie quando pronto: Restart-Computer'
}