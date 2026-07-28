# install-node-chrome.ps1
# RODA DENTRO DA VM ORIGINARIA, como Administrador.
#
# Instala Node.js e Google Chrome -- a unica parte do preparo da VM que nao tinha script
# (o roteiro.ps1 pedia "instalar node / instalar chrome" a mao). Nao substitui nem altera o
# configure-vm-image.ps1, que continua cuidando de usuario/autologon/VNC/startup/firewall.
#
# Ordem do preparo da VM originaria:
#   1. install-node-chrome.ps1   <- ESTE
#   2. configure-vm-image.ps1
#   3. (na sua maquina) capturar a imagem na Compute Gallery
#
# Por que MSI e nao o instalador stub do Chrome: o stub pode instalar por usuario em
# %LOCALAPPDATA%, e o MSI enterprise instala em Program Files (per-machine). Com autologon e
# imagem clonada, per-machine e o unico caminho previsivel. O bot acha o Chrome via
# chrome-launcher (cdp.js chama launch() sem chromePath), que procura nos dois lugares --
# mas per-machine evita depender de qual usuario logou.

param(
  # Fixa de proposito (nao "latest"): a imagem base precisa ser reprodutivel e as ~50 VMs da frota
  # devem sair todas com a mesma versao. v24.18.0 = LTS Krypton (2026-06-23).
  # Os bots pedem Node 18+ (type:module, mongoose 7, node-fetch 3); nenhum package.json fixa engines.
  [string] $NodeVersion = "24.18.0",
  [string] $NodeMsiUrl  = "",   # vazio = derivada de $NodeVersion

  [string] $ChromeMsiUrl = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi",

  # Congela a versao do Chrome desligando o Google Update. Ligado por default de proposito:
  # o UA de cada registro e IMUTAVEL (capturado no login GOV, amarrado ao cookiesGov/PHPSESSID) e
  # e enviado a cada requisicao via setAgent. Se o Chrome se auto-atualizar numa VM, a versao real
  # do browser passa a divergir da versao declarada na UA -- exatamente o tipo de inconsistencia
  # de fingerprint que o projeto tenta evitar no WAF. Desligue com -CongelarVersaoChrome:$false.
  [bool]   $CongelarVersaoChrome = $true,

  [string] $PastaTemp = "C:\temp",
  [switch] $Forcar,    # reinstala mesmo se ja houver versao instalada
  [switch] $DryRun
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($NodeMsiUrl)) {
  $NodeMsiUrl = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-x64.msi"
}

# GUID do Google Chrome no Google Update (Omaha) -- usado na policy por aplicativo.
$GuidChrome = "{8A69D345-D564-463C-AFF1-A69D9E530F96}"

$CaminhosChrome = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)

# ============================================================
# HELPERS
# ============================================================

function Write-Etapa([string]$Texto) { Write-Host ""; Write-Host "== $Texto" }
function Write-Ok([string]$Texto)    { Write-Host "   [OK]   $Texto" }
function Write-Skip([string]$Texto)  { Write-Host "   [SKIP] $Texto" }
function Write-Aviso([string]$Texto) { Write-Host "   [!]    $Texto" }
function Write-Dry([string]$Texto)   { Write-Host "   [DRY]  $Texto" }

function Test-Administrador() {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# O Windows PowerShell 5.1 transforma stderr de comando nativo em NativeCommandError e, com
# $ErrorActionPreference='Stop', aborta o script. $PSNativeCommandUseErrorActionPreference so existe
# no PS 7.3+, entao a supressao precisa ser local a cada chamada de executavel externo.
function Invoke-Quieto([scriptblock]$Bloco) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try {
    $saida = & $Bloco 2>$null
    return [pscustomobject]@{ Saida = $saida; Codigo = $LASTEXITCODE }
  } finally {
    $ErrorActionPreference = $antes
  }
}

function Get-VersaoNode() {
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return "" }
  $r = Invoke-Quieto { node --version }
  if ($r.Codigo -ne 0 -or $null -eq $r.Saida) { return "" }
  return ([string]$r.Saida).Trim().TrimStart("v")
}

function Get-CaminhoChrome() {
  foreach ($c in $CaminhosChrome) {
    if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path $c)) { return $c }
  }
  return ""
}

function Get-VersaoChrome([string]$Caminho) {
  if ([string]::IsNullOrWhiteSpace($Caminho)) { return "" }
  return (Get-Item $Caminho).VersionInfo.ProductVersion
}

# O MSI grava o PATH na maquina, mas o processo atual so ve o PATH de quando iniciou.
function Update-PathDaSessao() {
  $maquina = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $usuario = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = (@($maquina, $usuario) | Where-Object { $_ }) -join ";"
}

function Get-Arquivo([string]$Url, [string]$Destino, [string]$Rotulo) {
  if ($DryRun) { Write-Dry "baixaria ${Rotulo}: $Url"; return }
  Write-Host "   Baixando $Rotulo ..."
  # Sem isso o Invoke-WebRequest fica ordens de magnitude mais lento desenhando a barra de progresso.
  $progressoAntes = $ProgressPreference
  $ProgressPreference = "SilentlyContinue"
  try {
    Invoke-WebRequest -Uri $Url -OutFile $Destino -UseBasicParsing -TimeoutSec 900
  } finally {
    $ProgressPreference = $progressoAntes
  }
  if (-not (Test-Path $Destino)) { throw "${Rotulo}: download nao produziu arquivo em $Destino" }
  $mb = [math]::Round((Get-Item $Destino).Length / 1MB, 1)
  Write-Ok "$Rotulo baixado ($mb MB)"
}

function Install-Msi([string]$Caminho, [string]$Rotulo) {
  if ($DryRun) { Write-Dry "msiexec /i `"$Caminho`" /quiet /norestart"; return }
  Write-Host "   Instalando $Rotulo (silencioso) ..."
  # Sem ADDLOCAL=ALL de proposito: no MSI do Node isso ativaria a feature NativeTools, que baixa
  # Chocolatey + Python + VS Build Tools. A instalacao default ja traz runtime + npm + PATH.
  $p = Start-Process msiexec.exe -ArgumentList @("/i", "`"$Caminho`"", "/quiet", "/norestart") -Wait -PassThru
  if ($p.ExitCode -eq 3010 -or $p.ExitCode -eq 1641) {
    Write-Aviso "$Rotulo instalado, com reboot pendente (codigo $($p.ExitCode))"
    return
  }
  if ($p.ExitCode -ne 0) { throw "${Rotulo}: msiexec retornou $($p.ExitCode)" }
  Write-Ok "$Rotulo instalado"
}

# ============================================================
# CABECALHO
# ============================================================

Write-Host "=================================================="
Write-Host " INSTALACAO DE NODE + CHROME - VM RoboDPC"
Write-Host "=================================================="
Write-Host " Node   : v$NodeVersion"
Write-Host " Chrome : MSI enterprise (per-machine)"
Write-Host " Congela versao do Chrome: $CongelarVersaoChrome"
if ($Forcar) { Write-Host " MODO   : -Forcar (reinstala mesmo se presente)" }
if ($DryRun) { Write-Host " MODO   : DRY-RUN (nada sera baixado nem instalado)" }

# ============================================================
# [1/4] PRE-FLIGHT
# ============================================================
Write-Etapa "[1/4] Pre-flight"

if ($env:OS -ne "Windows_NT") { throw "Este script roda somente em Windows." }

if (Test-Administrador) {
  Write-Ok "Sessao elevada (Administrador)"
} elseif ($DryRun) {
  # Dry-run nao instala nada, entao nao precisa de elevacao -- da para conferir o plano de qualquer sessao.
  Write-Aviso "Sessao NAO elevada. Ok para -DryRun; a execucao real vai exigir Administrador."
} else {
  throw "Rode como Administrador: a instalacao per-machine (MSI) e as policies do Chrome exigem elevacao."
}

if (-not $DryRun) {
  foreach ($pasta in @("C:\logs", $PastaTemp)) {
    if (-not (Test-Path $pasta)) { New-Item -ItemType Directory -Force -Path $pasta | Out-Null }
  }
  Start-Transcript -Path "C:\logs\install-node-chrome.log" -Append | Out-Null
  Write-Ok "Log em C:\logs\install-node-chrome.log"
} else {
  Write-Dry "criaria C:\logs e $PastaTemp, e iniciaria o transcript"
}

try {

  # ============================================================
  # [2/4] NODE.JS
  # ============================================================
  Write-Etapa "[2/4] Node.js"

  $versaoNode = Get-VersaoNode
  if ($versaoNode -ne "" -and -not $Forcar) {
    Write-Skip "Node ja instalado: v$versaoNode"
    if ($versaoNode -ne $NodeVersion) {
      Write-Aviso "Versao instalada (v$versaoNode) difere da alvo (v$NodeVersion). Use -Forcar para trocar."
    }
  } else {
    if ($versaoNode -ne "") { Write-Aviso "-Forcar: reinstalando sobre a v$versaoNode" }
    $msiNode = Join-Path $PastaTemp "node-v$NodeVersion-x64.msi"
    Get-Arquivo $NodeMsiUrl $msiNode "Node v$NodeVersion"
    Install-Msi $msiNode "Node v$NodeVersion"
    Update-PathDaSessao

    if (-not $DryRun) {
      $versaoNode = Get-VersaoNode
      if ($versaoNode -eq "") {
        throw "Node instalado mas 'node' nao responde nesta sessao. Abra um novo PowerShell e confira 'node --version'."
      }
      Write-Ok "node v$versaoNode"
    }
  }

  if (-not $DryRun) {
    $versaoNpm = ""
    if (Get-Command npm -ErrorAction SilentlyContinue) { $versaoNpm = (Invoke-Quieto { npm --version }).Saida }
    if ([string]::IsNullOrWhiteSpace($versaoNpm)) {
      Write-Aviso "npm nao respondeu nesta sessao (costuma resolver num PowerShell novo)."
    } else {
      Write-Ok "npm $(([string]$versaoNpm).Trim())"
    }
  }

  # ============================================================
  # [3/4] GOOGLE CHROME
  # ============================================================
  Write-Etapa "[3/4] Google Chrome"

  $caminhoChrome = Get-CaminhoChrome
  if ($caminhoChrome -ne "" -and -not $Forcar) {
    Write-Skip "Chrome ja instalado: $(Get-VersaoChrome $caminhoChrome)"
    Write-Host "          $caminhoChrome"
  } else {
    if ($caminhoChrome -ne "") { Write-Aviso "-Forcar: reinstalando sobre $(Get-VersaoChrome $caminhoChrome)" }
    $msiChrome = Join-Path $PastaTemp "googlechromestandaloneenterprise64.msi"
    Get-Arquivo $ChromeMsiUrl $msiChrome "Chrome (MSI enterprise)"
    Install-Msi $msiChrome "Chrome"

    if (-not $DryRun) {
      $caminhoChrome = Get-CaminhoChrome
      if ($caminhoChrome -eq "") {
        throw "Chrome instalado mas chrome.exe nao foi encontrado nos caminhos conhecidos."
      }
      Write-Ok "Chrome $(Get-VersaoChrome $caminhoChrome)"
      Write-Host "          $caminhoChrome"
    }
  }

  # ============================================================
  # [4/4] CONGELAR A VERSAO DO CHROME
  # ============================================================
  Write-Etapa "[4/4] Congelar a versao do Chrome"

  if (-not $CongelarVersaoChrome) {
    Write-Skip "-CongelarVersaoChrome:`$false -- Google Update mantido ativo"
    Write-Aviso "Atencao: com auto-update ligado, VMs da frota podem divergir da versao da imagem."
  } elseif ($DryRun) {
    Write-Dry "gravaria HKLM:\SOFTWARE\Policies\Google\Update (UpdateDefault=0, AutoUpdateCheckPeriodMinutes=0, Update$GuidChrome=0)"
    Write-Dry "desabilitaria servicos gupdate/gupdatem e tarefas GoogleUpdate*"
  } else {
    $chave = "HKLM:\SOFTWARE\Policies\Google\Update"
    if (-not (Test-Path $chave)) { New-Item -Path $chave -Force | Out-Null }
    Set-ItemProperty -Path $chave -Name "UpdateDefault" -Value 0 -Type DWord
    Set-ItemProperty -Path $chave -Name "AutoUpdateCheckPeriodMinutes" -Value 0 -Type DWord
    Set-ItemProperty -Path $chave -Name "Update$GuidChrome" -Value 0 -Type DWord
    Write-Ok "Policies de Google Update gravadas (update desabilitado)"

    foreach ($nomeSvc in @("gupdate", "gupdatem")) {
      $svc = Get-Service -Name $nomeSvc -ErrorAction SilentlyContinue
      if ($null -eq $svc) { continue }
      try {
        Set-Service -Name $nomeSvc -StartupType Disabled
        if ($svc.Status -eq "Running") { Stop-Service -Name $nomeSvc -Force -ErrorAction SilentlyContinue }
        Write-Ok "Servico $nomeSvc desabilitado"
      } catch {
        Write-Aviso "Nao foi possivel desabilitar o servico ${nomeSvc}: $($_.Exception.Message)"
      }
    }

    $tarefas = @(Get-ScheduledTask -TaskName "GoogleUpdate*" -ErrorAction SilentlyContinue)
    if ($tarefas.Count -eq 0) {
      Write-Skip "Nenhuma tarefa agendada GoogleUpdate* encontrada"
    } else {
      foreach ($t in $tarefas) {
        try {
          Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop | Out-Null
          Write-Ok "Tarefa desabilitada: $($t.TaskName)"
        } catch {
          Write-Aviso "Nao foi possivel desabilitar a tarefa $($t.TaskName)"
        }
      }
    }
  }

  # ============================================================
  # RESUMO
  # ============================================================

  if ($DryRun) {
    Write-Host ""
    Write-Host "DRY-RUN concluido. Nada foi baixado nem instalado."
    Write-Host "Rode sem -DryRun (como Administrador) para instalar."
  } else {
    $caminhoChrome = Get-CaminhoChrome
    Write-Host ""
    Write-Host "=================================================="
    Write-Host " INSTALACAO CONCLUIDA"
    Write-Host "=================================================="
    Write-Host " Node   : v$(Get-VersaoNode)"
    Write-Host " Chrome : $(Get-VersaoChrome $caminhoChrome)"
    Write-Host "          $caminhoChrome"
    Write-Host " Auto-update do Chrome: $(if ($CongelarVersaoChrome) { 'DESABILITADO (versao congelada)' } else { 'ativo' })"
    Write-Host ""
    Write-Host "-- PROXIMO PASSO --"
    Write-Host ""
    Write-Host " Rodar o configure-vm-image.ps1 (usuario, autologon, VNC, startup, firewall):"
    Write-Host "   cd C:\ ; .\setup-complete-vm.ps1 -UserName robodpc -UserPassword <senha do admin da VM>"
    Write-Host ""
    Write-Host " A senha precisa ser a MESMA do admin da VM -- ela alimenta o autologon."
    Write-Host ""
    Write-Host " Lembrete: o startup criado por aquele script aponta para"
    Write-Host " C:\dpc\dpc-interno-rep\index.js -- o codigo do bot precisa estar nesse caminho"
    Write-Host " com as dependencias instaladas (npm install) antes de capturar a imagem."
  }

} finally {
  if (-not $DryRun) { try { Stop-Transcript | Out-Null } catch { } }
}
