# setup-complete-vm-uniform.ps1
# SCRIPT COMPLETO OTIMIZADO PARA MODO UNIFORM
# 1 usuário + autologon + VNC + Chrome + Node
# Versão: 2.1 - Uniform Mode
# Data: 2026-01-30

param(
    [string]$UserName = "robodpc",
    [string]$UserPassword = "robodpc2025#",
    [string]$VncPassword = "RoboVNC2025",
    [string]$NodeScriptPath = "C:\dpc\dpc-interno-rep\index.js",
    # Rollback: gera a imagem SEM o laco de supervisao (o bot sobe uma vez por boot, como antes).
    # O bot-supervisor.ps1 continua sendo criado, mas e chamado com -SemLaco.
    [switch]$SemSupervisor
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

# -SemSupervisor gera a imagem no formato antigo: o bot sobe uma vez, sem laco de vigilancia.
$argSupervisor = if ($SemSupervisor) { " -SemLaco" } else { "" }

# Script 3: bot-supervisor.ps1
# Here-string LITERAL (@'...'@): nada e interpolado na geracao, entao nao ha backtick para escapar
# - que e a maior fonte de erro deste arquivo. Tudo o que varia entra por parametro.
$botSupervisorScript = @'
# bot-supervisor.ps1 - sobe o bot e o mantem no ar.
#
# POR QUE EXISTE: nao havia supervisor de processo. O startup-master subia o node UMA vez por boot,
# entao um processo que morresse deixava a VM fora ate reboot manual - e ninguem percebia no dia D.
# Neste projeto encerrar e sempre o pior desfecho, entao o laco NUNCA desiste: so espaca as
# tentativas com backoff.
#
# TRES ARMADILHAS que este script existe para nao repetir:
#
#  1. Start-Process cmd.exe -PassThru devolve o PID do CMD, e o /k mantem o cmd VIVO depois que o
#     node morre. Vigiar esse PID diria "saudavel" para sempre. Por isso Get-BotPid resolve o
#     processo FILHO (Win32_Process/ParentProcessId) - e e esse PID que vai para o node.pid.
#  2. O nome do log carrega a data e e fixado no >> do start. Cada restart reavalia a data e
#     reaponta o bot-atual.txt, senao o log vira em silencio na meia-noite.
#  3. Matar node incondicionalmente derruba um bot SAUDAVEL quando o script roda de novo (por
#     az vmss run-command, ou um segundo disparo da Startup). Aqui um node vivo e ADOTADO - o que
#     torna seguro reexecutar o startup-master como watchdog-do-watchdog.
#
# O CHROME NAO E TOCADO no restart: o node morto deixa o Chrome na 9222 com o perfil aquecido, e o
# abreDPC reconecta nele preservando o cf_clearance. Matar o Chrome jogaria fora exatamente o
# aquecimento que o resto do projeto protege.
#
# KILL-SWITCH sem re-bake: criar C:\Scripts\supervisor.off (via az vmss run-command) faz o laco
# sair SEM derrubar o bot.
param(
  [string]$ScriptPath  = "C:\dpc\dpc-interno-rep\index.js",
  [string]$VmName      = $env:COMPUTERNAME,
  [string]$VmId        = "unknown",
  [string]$LogsDir     = "C:\logs\node",
  [int]   $IntervaloS  = 10,    # cadencia da vigilancia
  [int]   $EsperaBaseS = 5,     # backoff inicial (curto: restart na janela critica ja custa caro)
  [int]   $EsperaMaxS  = 300,   # teto do backoff - freio contra loop rapido, nao desistencia
  [int]   $SaudavelS   = 300,   # node vivo por este tempo zera o contador de reinicios
  [string]$ProcNome    = "node.exe",  # hook de teste: exercitar o laco com outro processo
  [string]$Sentinela   = "C:\Scripts\supervisor.off",  # kill-switch: existe -> para de vigiar
  [switch]$SemTail,                   # nao abre a janela de acompanhamento (headless/teste)
  [switch]$SemLaco,                   # rollback: sobe o bot e sai (comportamento antigo)
  [switch]$UmaVolta                   # hook de teste: uma iteracao e sai
)

$ErrorActionPreference = "Continue"

function Log-Sup($msg) {
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[SUPERVISOR] $msg"
    # Recalculado a cada chamada: o arquivo acompanha a virada de data.
    $arq = "$LogsDir\supervisor-$VmName-$(Get-Date -Format 'yyyyMMdd').log"
    try { "$ts [SUPERVISOR] $msg" | Add-Content $arq } catch { }
}

function Get-BotPid($cmdPid) {
    # O node e FILHO do cmd. Sem resolver o filho, o supervisor vigiaria o cmd (que nunca morre).
    for ($i = 0; $i -lt 15; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ParentProcessId=$cmdPid" -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -eq $ProcNome } | Select-Object -First 1
        if ($p) { return [int]$p.ProcessId }
        Start-Sleep -Seconds 1
    }
    return 0
}

function Vivo($processId) {
    if (-not $processId) { return $false }
    return [bool](Get-Process -Id $processId -ErrorAction SilentlyContinue)
}

function Sobe-Bot {
    $scriptDir = Split-Path -Parent $ScriptPath
    Set-Location $scriptDir
    $env:AZURE_VM_NAME = $VmName
    $env:AZURE_VM_ID = $VmId
    $env:NODE_ENV = "production"
    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

    $vmName = $VmName
    $vmId = $VmId
    $logsDir = $LogsDir
    $scriptPath = $ScriptPath
    $logDate = Get-Date -Format 'yyyyMMdd'
    $outputLog = "$logsDir\bot-$vmName-$logDate.log"

    "`n========== VM: $vmName - Iniciado em $(Get-Date) ==========" | Add-Content $outputLog
    # Ponteiro para o log corrente: o coletor le daqui em vez de adivinhar data/nome.
    $outputLog | Set-Content "$logsDir\bot-atual.txt"

    # Node em janela CMD, com stdout+stderr REDIRECIONADOS para arquivo.
    # O merge (2>&1) fica no cmd, NAO no PowerShell: no PS 5.1 stderr de comando nativo vira
    # NativeCommandError e abortaria o startup nos proprios avisos do Node.
    # Arquivo (e nao pipe/Tee-Object) porque no Windows stdout para arquivo e escrita sincrona:
    # a cauda do log sobrevive a uma queda do processo.
    $cmd = Start-Process cmd.exe `
        -ArgumentList "/k cd /d $scriptDir && set AZURE_VM_NAME=$vmName && set AZURE_VM_ID=$vmId && node $scriptPath >> ""$outputLog"" 2>&1" `
        -PassThru `
        -WindowStyle Normal

    $botPid = Get-BotPid $cmd.Id
    if ($botPid) { $botPid | Set-Content "$logsDir\node.pid" }
    Log-Sup "bot iniciado: cmd=$($cmd.Id) node=$botPid log=$outputLog"
    return @{ CmdPid = $cmd.Id; BotPid = $botPid; Log = $outputLog; Inicio = Get-Date }
}

function Sobe-Tail($outputLog) {
    # Janela so de acompanhamento por VNC - a fonte da verdade e o arquivo.
    $t = Start-Process powershell.exe `
        -ArgumentList "-NoExit","-NoProfile","-ExecutionPolicy","Bypass","-Command","Get-Content -Path '$outputLog' -Wait -Tail 50" `
        -PassThru `
        -WindowStyle Normal
    return $t.Id
}

# --- adocao: nunca derrubar um node saudavel ---------------------------------------------------
$nomeProc = $ProcNome -replace '\.exe$', ''
$existente = Get-Process $nomeProc -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existente) {
    $logAtual = ""
    try { $logAtual = (Get-Content "$LogsDir\bot-atual.txt" -ErrorAction SilentlyContinue | Select-Object -First 1) } catch { }
    Log-Sup "adotando processo ja em execucao (pid $($existente.Id)); nao reinicia"
    $estado = @{ CmdPid = 0; BotPid = $existente.Id; Log = $logAtual; Inicio = Get-Date }
} else {
    $estado = Sobe-Bot
}

$tailPid = 0
if ($estado.Log -and -not $SemTail) { $tailPid = Sobe-Tail $estado.Log }

if ($SemLaco) {
    Log-Sup "-SemLaco: bot iniciado sem supervisao (comportamento antigo)."
    return
}

$falhas = 0
$tailFalhas = 0
Log-Sup "supervisao ativa (intervalo ${IntervaloS}s, backoff ${EsperaBaseS}-${EsperaMaxS}s)"

while ($true) {
    Start-Sleep -Seconds $IntervaloS
    try {
        if (Test-Path $Sentinela) {
            Log-Sup "sentinela $Sentinela presente: supervisao DESLIGADA (o bot segue rodando)"
            break
        }

        if (Vivo $estado.BotPid) {
            if ($falhas -gt 0 -and ((Get-Date) - $estado.Inicio).TotalSeconds -ge $SaudavelS) {
                # Reinicios sao falhas CONSECUTIVAS, nao a vida da VM - mesmo padrao de
                # tentInplace/falhasCloudflare/recuperacoesConsecutivas no bot.
                Log-Sup "node estavel ha ${SaudavelS}s; zerando contador de reinicios ($falhas)"
                $falhas = 0
            }
            if ($estado.Log -and -not $SemTail -and -not (Vivo $tailPid) -and $tailFalhas -lt 5) {
                $tailPid = Sobe-Tail $estado.Log
                $tailFalhas++
            }
        } else {
            $falhas++
            # A janela do cmd (/k) sobrevive ao node: fechar a orfa antes de reabrir.
            if ($estado.CmdPid -and (Vivo $estado.CmdPid)) {
                Stop-Process -Id $estado.CmdPid -Force -ErrorAction SilentlyContinue
            }
            $espera = [math]::Min($EsperaBaseS * [math]::Pow(2, $falhas - 1), $EsperaMaxS)
            Log-Sup "node ausente (reinicio #$falhas). Aguardando ${espera}s..."
            Start-Sleep -Seconds $espera

            $anterior = $estado.Log
            $estado = Sobe-Bot
            if ($estado.Log -ne $anterior -and -not $SemTail) {
                if (Vivo $tailPid) { Stop-Process -Id $tailPid -Force -ErrorAction SilentlyContinue }
                $tailPid = Sobe-Tail $estado.Log
                $tailFalhas = 0
            }
        }
    } catch {
        Log-Sup "erro no laco (ignorado): $_"
    }
    if ($UmaVolta) { break }
}
'@
Set-Content -Path "C:\Scripts\bot-supervisor.ps1" -Value $botSupervisorScript
Write-Host "Script supervisor criado"

# Script 2: startup-master.ps1
$startupMasterScript = @"
Start-Transcript -Path "C:\logs\startup-master-`$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Write-Host "=== STARTUP MASTER ==="
Write-Host "Usuario: `$env:USERNAME"
Write-Host "Data: `$(Get-Date)"
Write-Host "Hostname: `$env:COMPUTERNAME"

# Guarda de instancia unica: um segundo disparo da Startup (ou um `az vmss run-command` de
# emergencia) nao pode virar dois supervisores brigando pelo mesmo bot. Quem chegou depois sai.
`$outrosStartup = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { `$_.ProcessId -ne `$PID -and `$_.CommandLine -like '*startup-master.ps1*' })
if (`$outrosStartup.Count -gt 0) {
    Write-Host "startup-master ja em execucao (PID `$(`$outrosStartup[0].ProcessId)); saindo sem tocar no bot."
    Stop-Transcript
    exit 0
}

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

# Iniciar o bot SOB SUPERVISAO.
# Subir, vigiar e reiniciar ficam no bot-supervisor.ps1 — ele roda DENTRO deste processo, entao o
# transcript segue capturando e a arvore de processos nao muda. Antes o node subia UMA vez por boot:
# se o processo morresse, a VM ficava fora ate reboot manual e ninguem percebia no dia D.
`$supervisor = "C:\Scripts\bot-supervisor.ps1"
if (Test-Path `$supervisor) {
    & `$supervisor -ScriptPath "$NodeScriptPath" -VmName `$vmName -VmId `$vmId$argSupervisor
} else {
    Write-Host "Supervisor nao encontrado: `$supervisor"
    Write-Host "AJUSTE: C:\Scripts\bot-supervisor.ps1"
}

Write-Host ""
Write-Host "=== STARTUP CONCLUÍDO ==="
Write-Host "Hostname: `$env:COMPUTERNAME"
Write-Host "Chrome: Debug porta 9222"
Write-Host 'Node.js: Log em C:\logs\node\bot-<vm>-<data>.log (ponteiro: bot-atual.txt)'
Write-Host 'Supervisor: C:\logs\node\supervisor-<vm>-<data>.log (off: C:\Scripts\supervisor.off)'
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

# Configurar Firewall para WS WATCHER
Write-Host "Configurando Firewall WS WATCHER (porta 3000)..."
try {
    New-NetFirewallRule -DisplayName "WS WATCHER" `
        -Direction Inbound `
        -LocalPort 3000 `
        -Protocol TCP `
        -Action Allow `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Firewall configurado para WS WATCHER"
} catch {
    Write-Host "Firewall já configurado"
}


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