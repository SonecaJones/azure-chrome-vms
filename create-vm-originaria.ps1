# create-vm-originaria.ps1
# Cria a VM "originaria" (base) do RoboDPC no Azure: Resource Group + VNet/Subnet + NSG + VM Windows 11.
#
# ESCOPO: SOMENTE CRIACAO. A configuracao continua manual, com os scripts que ja existem em
# "scripts para rodar na VM\" (instalar Node, instalar Chrome, rodar configure-vm-image.ps1).
# Este script NAO aplica nenhuma VM extension de proposito: o handler da extension ficaria gravado
# no disco e iria junto para a imagem capturada.
#
# Fluxo completo do qual este script e o passo 1:
#   1. create-vm-originaria.ps1   <- ESTE (cria a VM)
#   2. RDP + instalar Node/Chrome + configure-vm-image.ps1   (manual, dentro da VM)
#   3. capturar imagem na Compute Gallery  (ver create-50-vmss-image.ps1)
#   4. create-multiregion-vmss.ps1  (sobe as VMSS a partir da imagem)
#
# Idempotente: reusa RG/VNet/Subnet/NSG que ja existirem. Se a VM ja existir, ABORTA sem alterar nada.

param(
  [string] $ResourceGroup = "dpcrobos",
  [string] $Subscription  = "5c27bb8e-190b-4cf7-bd0e-c9dfca554525",
  [string] $Regiao        = "brazilsouth",
  [string] $VmName        = "VMrobodpc",
  [string] $VmSize        = "Standard_F2s_v2",
  [string] $AdminUser     = "robodpc",

  # Senha do admin. Default vem da env var; se vazia, o script pergunta (sem eco).
  # ATENCAO: precisa ser a MESMA senha passada depois em configure-vm-image.ps1 -UserPassword,
  # porque ela alimenta o autologon via registry. Senhas diferentes quebram o autologon em silencio.
  [string] $AdminPassword = $env:DPC_VM_ADMIN_PASSWORD,

  # Windows 11 Pro 25H2 (build 26200) = mesma build da maquina local onde o dpc-login captura o UA.
  # O offer correto e "windows-11" COM hifen ("windows11" retorna NotFound).
  # Alternativa conservadora: MicrosoftWindowsDesktop:windows-11:win11-24h2-pro:latest (build 26100).
  [string] $ImageUrn = "MicrosoftWindowsDesktop:windows-11:win11-25h2-pro:latest",

  # Imagens Windows CLIENT pressupoem direitos proprios de licenca (Multi-tenant Hosting Rights via
  # E3/E5/M365). Preencha com "Windows_Client" se voce tem esses direitos. Vazio = flag nao enviada.
  [string] $LicenseType = "",

  [string] $OrigemAcesso = "*",

  [ValidateSet("Spot","Regular")]      [string] $Prioridade     = "Spot",
  # A frota usa Delete (seguro la: a imagem ja esta pronta). Na originaria Delete APAGARIA a VM e
  # todo o trabalho de instalacao manual numa eviccao Spot -> default Deallocate (disco persiste).
  [ValidateSet("Deallocate","Delete")] [string] $EvictionPolicy = "Deallocate",

  [int]    $OsDiskSizeGb = 0,   # 0 = usa o default da imagem (127 GB)
  [switch] $DryRun
)

$ErrorActionPreference = "Stop"
# Queremos checar $LASTEXITCODE na mao; sem isso o PS 7.3+ lanca excecao em qualquer stderr do az.
$PSNativeCommandUseErrorActionPreference = $false

# Nomes dedicados: nao colidem com as VNets/NSGs por regiao que create-multiregion-vmss.ps1 cria
# (VNet-RoboDPC-<regiao>), entao aquele script segue funcionando sem alteracao.
$VNetName   = "VNet-RoboDPC-origem"
$SubnetName = "Subnet-RoboDPC-origem"
$NsgName    = "NSG-$VmName"
$Tags       = @("projeto=DPC", "papel=origem", "criado=$(Get-Date -Format 'yyyy-MM-dd')")

$RegrasNsg = @(
  @{ nome = "Allow-RDP";     porta = 3389; prio = 1000; desc = "RDP" },
  @{ nome = "Allow-VNC";     porta = 5900; prio = 1010; desc = "TightVNC" },
  @{ nome = "Allow-WATCHER"; porta = 3000; prio = 1020; desc = "WS Watcher" }
)

# ============================================================
# HELPERS
# ============================================================

function Write-Etapa([string]$Texto) { Write-Host ""; Write-Host "== $Texto" }
function Write-Ok([string]$Texto)    { Write-Host "   [OK]   $Texto" }
function Write-Skip([string]$Texto)  { Write-Host "   [SKIP] $Texto" }
function Write-Aviso([string]$Texto) { Write-Host "   [!]    $Texto" }

# Confirmacao de algo que foi efetivamente criado. Em -DryRun fica calada: a linha [DRY] ja mostrou
# o comando, e dizer "criado" sobre o que nao foi criado engana quem le a saida.
function Write-Criado([string]$Texto) {
  if ($DryRun) { return }
  Write-Ok $Texto
}

# Monta a linha de comando para log, mascarando a senha.
function Format-AzParaLog([string[]]$AzArgs) {
  $partes = @()
  for ($i = 0; $i -lt $AzArgs.Count; $i++) {
    $atual = $AzArgs[$i]
    if ($atual -eq "--admin-password") {
      $partes += $atual
      $partes += "***"
      $i++            # pula o valor real da senha
      continue
    }
    if ($atual -match '\s') { $partes += ('"' + $atual + '"') } else { $partes += $atual }
  }
  return ("az " + ($partes -join " "))
}

# O Windows PowerShell 5.1 transforma QUALQUER stderr de comando nativo em NativeCommandError e,
# com $ErrorActionPreference='Stop', aborta o script -- inclusive quando a saida de erro e esperada
# (recurso ainda nao existe) ou e so um aviso (o 'WARNING: --max-price is in preview' que o az emite
# num 'vm create' bem-sucedido). A variavel $PSNativeCommandUseErrorActionPreference nao existe no
# 5.1, entao a supressao tem de ser LOCAL a cada chamada: rebaixar a preferencia durante o & az e
# decidir o desfecho pelo $LASTEXITCODE, que e a unica fonte confiavel nas duas versoes.
function Invoke-AzQuieto([string[]]$AzArgs, [switch]$CapturaErro) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try {
    if ($CapturaErro) { $saida = & az @AzArgs 2>&1 } else { $saida = & az @AzArgs 2>$null }
    return [pscustomobject]@{ Saida = $saida; Codigo = $LASTEXITCODE }
  } finally {
    $ErrorActionPreference = $antes
  }
}

# Comando de ESCRITA: respeita -DryRun, aborta se o az retornar erro.
function Invoke-Az([string[]]$AzArgs, [string]$Rotulo) {
  if ($DryRun) {
    Write-Host "   [DRY]  $(Format-AzParaLog $AzArgs)"
    return $null
  }
  $r = Invoke-AzQuieto $AzArgs -CapturaErro
  $saida = $r.Saida
  if ($r.Codigo -ne 0) {
    Write-Host ""
    Write-Host "ERRO em: $Rotulo"
    Write-Host "Comando: $(Format-AzParaLog $AzArgs)"
    Write-Host "Resposta do Azure:"
    Write-Host ($saida | Out-String)
    throw "Falha ao executar: $Rotulo"
  }
  return $saida
}

# Comando de LEITURA: executa sempre (inclusive em -DryRun, pois nao altera nada).
function Get-AzValor([string[]]$AzArgs) {
  $r = Invoke-AzQuieto $AzArgs
  if ($r.Codigo -ne 0) { return "" }
  # Query que nao casa nada devolve $null (ex.: SKU sem restricoes) -- Join com null lanca excecao.
  if ($null -eq $r.Saida) { return "" }
  return ([string]::Join("", @($r.Saida))).Trim()
}

# Existencia de recurso: qualquer "az ... show" que retorne exit 0. O caminho "nao existe" e o
# fluxo NORMAL aqui, nao um erro -- por isso passa pelo Invoke-AzQuieto.
function Test-AzExiste([string[]]$AzArgs) {
  $r = Invoke-AzQuieto ($AzArgs + @("-o", "none"))
  return ($r.Codigo -eq 0)
}

# Regras de senha de VM Windows no Azure: 12-123 chars e 3 das 4 categorias.
function Test-SenhaWindows([string]$Senha) {
  if ($Senha.Length -lt 12 -or $Senha.Length -gt 123) { return $false }
  $categorias = 0
  if ($Senha -cmatch '[a-z]')            { $categorias++ }
  if ($Senha -cmatch '[A-Z]')            { $categorias++ }
  if ($Senha -match  '[0-9]')            { $categorias++ }
  if ($Senha -match  '[^a-zA-Z0-9]')     { $categorias++ }
  return ($categorias -ge 3)
}

function Read-SenhaSegura() {
  $secure = Read-Host "Senha do admin '$AdminUser' da VM (nao sera exibida)" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try   { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ============================================================
# CABECALHO
# ============================================================

Write-Host "=================================================="
Write-Host " CRIACAO DA VM ORIGINARIA - RoboDPC"
Write-Host "=================================================="
Write-Host " RG / Regiao : $ResourceGroup / $Regiao"
Write-Host " VM          : $VmName  ($VmSize, $Prioridade)"
Write-Host " Imagem      : $ImageUrn"
Write-Host " Rede        : $VNetName / $SubnetName / $NsgName"
Write-Host " Acesso NSG  : $OrigemAcesso"
if ($DryRun) { Write-Host " MODO        : DRY-RUN (nada sera criado)" }

# ============================================================
# [1/5] PRE-FLIGHT
# ============================================================
Write-Etapa "[1/5] Pre-flight"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) nao encontrado no PATH. Instale o Azure CLI e rode 'az login'."
}
Write-Ok "Azure CLI encontrado"

$contaAtual = Get-AzValor @("account", "show", "--query", "user.name", "-o", "tsv")
if ([string]::IsNullOrWhiteSpace($contaAtual)) {
  throw "Nao ha sessao ativa no Azure CLI. Rode 'az login' e tente de novo."
}
Write-Ok "Logado como $contaAtual"

# Executado tambem em -DryRun: trocar de subscription so muda o contexto local do CLI, nao cria nem
# altera recurso -- e sem isso as checagens de existencia do dry-run olhariam a subscription errada.
$rSub = Invoke-AzQuieto @("account", "set", "--subscription", $Subscription) -CapturaErro
if ($rSub.Codigo -ne 0) { throw "Nao foi possivel selecionar a subscription ${Subscription}: $($rSub.Saida | Out-String)" }
$subNome = Get-AzValor @("account", "show", "--query", "name", "-o", "tsv")
Write-Ok "Subscription: $subNome"

# Senha: env var -> prompt. Validada ANTES de criar rede, senao so falharia no az vm create.
if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
  Write-Aviso "DPC_VM_ADMIN_PASSWORD nao definida."
  $AdminPassword = Read-SenhaSegura
}
if (-not (Test-SenhaWindows $AdminPassword)) {
  throw "Senha invalida para VM Windows: precisa de 12 a 123 caracteres e 3 das 4 categorias (minuscula, maiuscula, digito, simbolo)."
}
Write-Ok "Senha do admin atende as regras do Azure"

# A imagem tem de ser Gen2: Windows 11 exige TPM 2.0 + Secure Boot (TrustedLaunch), e a Image
# Definition da galeria e criada com --hyper-v-generation V2.
$geracao = Get-AzValor @("vm", "image", "show", "--urn", $ImageUrn, "--query", "hyperVGeneration", "-o", "tsv")
if ([string]::IsNullOrWhiteSpace($geracao)) {
  throw "Imagem nao encontrada: $ImageUrn (confira publisher:offer:sku:version -- o offer do Win11 e 'windows-11', com hifen)."
}
if ($geracao -ne "V2") {
  throw "Imagem $ImageUrn e $geracao. Windows 11 + TrustedLaunch exigem Gen2 (V2)."
}
$buildImagem = Get-AzValor @("vm", "image", "show", "--urn", $ImageUrn, "--query", "name", "-o", "tsv")
Write-Ok "Imagem OK: Gen2, build $buildImagem"

# Quota de vCPU. Nao usamos 'az vm list-skus' aqui: baixar o catalogo inteiro de SKUs da regiao
# leva minutos. Se o SKU estiver restrito, o proprio 'az vm create' falha com mensagem clara.
$nomeQuota = "Total Regional vCPUs"
if ($Prioridade -eq "Spot") { $nomeQuota = "Total Regional Low-priority vCPUs" }

$linhaQuota = Get-AzValor @("vm", "list-usage", "--location", $Regiao,
                            "--query", "[?localName=='$nomeQuota'].[currentValue,limit]", "-o", "tsv")
if ([string]::IsNullOrWhiteSpace($linhaQuota)) {
  Write-Aviso "Nao foi possivel ler a quota '$nomeQuota' em $Regiao (seguindo em frente)."
} else {
  $campos = $linhaQuota -split "`t"
  $usado  = [int]$campos[0]
  $limite = [int]$campos[1]
  $folga  = $limite - $usado
  Write-Ok "Quota '$nomeQuota' em ${Regiao}: $usado/$limite vCPUs (folga $folga)"
  if ($folga -lt 2) {
    Write-Aviso "Folga de quota abaixo de 2 vCPUs -- a criacao da VM pode ser recusada."
  }
}

if ($LicenseType -eq "") {
  Write-Aviso "Sem --license-type. Imagens Windows client pressupoem direitos proprios de licenca."
  Write-Aviso "Se tiver Multi-tenant Hosting Rights, rode com: -LicenseType Windows_Client"
}
if ($VmSize -eq "Standard_F2s_v2") {
  Write-Aviso "F2s_v2 tem 4 GB (minimo do Win11). Chrome + Node rodam, mas sem folga."
  Write-Aviso "Se a configuracao ficar lenta: -VmSize Standard_F4s_v2 (nao muda o SKU da frota)."
}

# ============================================================
# [2/5] RESOURCE GROUP
# ============================================================
Write-Etapa "[2/5] Resource Group"

if ((Get-AzValor @("group", "exists", "--name", $ResourceGroup)) -eq "true") {
  Write-Skip "RG $ResourceGroup ja existe"
} else {
  $null = Invoke-Az (@("group", "create", "--name", $ResourceGroup, "--location", $Regiao, "--tags") + $Tags) "criar RG"
  Write-Criado "RG $ResourceGroup criado"
}

# ============================================================
# [3/5] VNET + SUBNET
# ============================================================
Write-Etapa "[3/5] VNet e Subnet"

if (Test-AzExiste @("network", "vnet", "show", "-g", $ResourceGroup, "-n", $VNetName)) {
  Write-Skip "VNet $VNetName ja existe"
  if (Test-AzExiste @("network", "vnet", "subnet", "show", "-g", $ResourceGroup, "--vnet-name", $VNetName, "-n", $SubnetName)) {
    Write-Skip "Subnet $SubnetName ja existe"
  } else {
    $null = Invoke-Az @("network", "vnet", "subnet", "create", "-g", $ResourceGroup,
                        "--vnet-name", $VNetName, "-n", $SubnetName,
                        "--address-prefix", "10.0.1.0/24") "criar subnet"
    Write-Criado "Subnet $SubnetName criada"
  }
} else {
  $null = Invoke-Az (@("network", "vnet", "create", "-g", $ResourceGroup, "-n", $VNetName,
                       "--location", $Regiao, "--address-prefix", "10.0.0.0/16",
                       "--subnet-name", $SubnetName, "--subnet-prefix", "10.0.1.0/24",
                       "--tags") + $Tags) "criar VNet"
  Write-Criado "VNet $VNetName (10.0.0.0/16) + subnet $SubnetName (10.0.1.0/24) criadas"
}

# ============================================================
# [4/5] NSG + REGRAS
# ============================================================
Write-Etapa "[4/5] NSG e regras"

if (Test-AzExiste @("network", "nsg", "show", "-g", $ResourceGroup, "-n", $NsgName)) {
  Write-Skip "NSG $NsgName ja existe"
} else {
  $null = Invoke-Az (@("network", "nsg", "create", "-g", $ResourceGroup, "-n", $NsgName,
                       "--location", $Regiao, "--tags") + $Tags) "criar NSG"
  Write-Criado "NSG $NsgName criado"
}

foreach ($regra in $RegrasNsg) {
  $existe = Test-AzExiste @("network", "nsg", "rule", "show", "-g", $ResourceGroup,
                            "--nsg-name", $NsgName, "-n", $regra.nome)
  if ($existe) {
    # O Azure guarda origem unica em sourceAddressPrefix e multiplas em sourceAddressPrefixes.
    # Consultado em dois passos porque join() em campo nulo quebra a expressao JMESPath.
    $origemAtual = Get-AzValor @("network", "nsg", "rule", "show", "-g", $ResourceGroup,
                                 "--nsg-name", $NsgName, "-n", $regra.nome,
                                 "--query", "sourceAddressPrefix", "-o", "tsv")
    if ([string]::IsNullOrWhiteSpace($origemAtual)) {
      $origemAtual = Get-AzValor @("network", "nsg", "rule", "show", "-g", $ResourceGroup,
                                   "--nsg-name", $NsgName, "-n", $regra.nome,
                                   "--query", "join(',', sourceAddressPrefixes)", "-o", "tsv")
    }
    if ($origemAtual -eq $OrigemAcesso) {
      Write-Skip "$($regra.nome) (porta $($regra.porta)) ja existe com origem $OrigemAcesso"
    } else {
      $null = Invoke-Az @("network", "nsg", "rule", "update", "-g", $ResourceGroup,
                          "--nsg-name", $NsgName, "-n", $regra.nome,
                          "--source-address-prefixes", $OrigemAcesso) "atualizar regra $($regra.nome)"
      Write-Criado "$($regra.nome): origem atualizada de '$origemAtual' para '$OrigemAcesso'"
    }
  } else {
    $null = Invoke-Az @("network", "nsg", "rule", "create", "-g", $ResourceGroup,
                        "--nsg-name", $NsgName, "-n", $regra.nome,
                        "--priority", "$($regra.prio)", "--protocol", "Tcp", "--direction", "Inbound",
                        "--access", "Allow", "--source-address-prefixes", $OrigemAcesso,
                        "--source-port-ranges", "*", "--destination-address-prefixes", "*",
                        "--destination-port-ranges", "$($regra.porta)",
                        "--description", $regra.desc) "criar regra $($regra.nome)"
    Write-Criado "$($regra.nome) criada (porta $($regra.porta), origem $OrigemAcesso)"
  }
}

# NSG na subnet, como create-multiregion-vmss.ps1 faz para a frota.
$nsgDaSubnet = Get-AzValor @("network", "vnet", "subnet", "show", "-g", $ResourceGroup,
                             "--vnet-name", $VNetName, "-n", $SubnetName,
                             "--query", "networkSecurityGroup.id", "-o", "tsv")
if ($nsgDaSubnet -match "/$NsgName$") {
  Write-Skip "NSG ja associado a subnet"
} else {
  $null = Invoke-Az @("network", "vnet", "subnet", "update", "-g", $ResourceGroup,
                      "--vnet-name", $VNetName, "-n", $SubnetName,
                      "--network-security-group", $NsgName) "associar NSG a subnet"
  Write-Criado "NSG associado a subnet"
}

# ============================================================
# [5/5] VM
# ============================================================
Write-Etapa "[5/5] VM"

if (Test-AzExiste @("vm", "show", "-g", $ResourceGroup, "-n", $VmName)) {
  $ipExistente = Get-AzValor @("vm", "show", "-d", "-g", $ResourceGroup, "-n", $VmName, "--query", "publicIps", "-o", "tsv")
  Write-Host ""
  Write-Host "A VM '$VmName' JA EXISTE no RG '$ResourceGroup' (IP: $ipExistente)."
  Write-Host "Nada foi alterado -- este script nunca sobrescreve uma VM em configuracao."
  Write-Host ""
  Write-Host "Para conectar:  mstsc /v:$ipExistente"
  Write-Host "Para recriar do zero:"
  Write-Host "  az vm delete -g $ResourceGroup -n $VmName --yes"
  Write-Host "  .\create-vm-originaria.ps1"
  exit 0
}

$argsVm = @(
  "vm", "create",
  "--resource-group", $ResourceGroup,
  "--name", $VmName,
  "--location", $Regiao,
  "--image", $ImageUrn,
  "--size", $VmSize,
  "--admin-username", $AdminUser,
  "--admin-password", $AdminPassword,
  "--vnet-name", $VNetName,
  "--subnet", $SubnetName,
  # Reusa o NSG que acabamos de criar em vez de deixar o az inventar um "<vm>-nsg" na NIC.
  "--nsg", $NsgName,
  # IP estatico: a VM sera parada/reiniciada varias vezes durante a configuracao e o endereco
  # de RDP nao deve mudar. Standard SKU so suporta alocacao static.
  "--public-ip-sku", "Standard",
  "--public-ip-address-allocation", "static",
  "--storage-sku", "StandardSSD_LRS",
  # Obrigatorio para Windows 11 (TPM 2.0 + Secure Boot) e exigido pela Image Definition da galeria.
  "--security-type", "TrustedLaunch",
  "--enable-vtpm", "true",
  "--enable-secure-boot", "true",
  "--os-disk-delete-option", "Delete",
  "--nic-delete-option", "Delete"
)

if ($OsDiskSizeGb -gt 0) { $argsVm += @("--os-disk-size-gb", "$OsDiskSizeGb") }
if ($LicenseType -ne "") { $argsVm += @("--license-type", $LicenseType) }

if ($Prioridade -eq "Spot") {
  # --max-price -1 = paga ate o preco on-demand, o que minimiza eviccao por preco.
  $argsVm += @("--priority", "Spot", "--eviction-policy", $EvictionPolicy, "--max-price", "-1")
}

$argsVm += @("--tags") + $Tags

if (-not $DryRun) { Write-Host "   Criando a VM (leva alguns minutos)..." }
$null = Invoke-Az $argsVm "criar VM $VmName"

if ($DryRun) {
  Write-Host ""
  Write-Host "DRY-RUN concluido. Nenhum recurso foi criado."
  Write-Host "Rode sem -DryRun para criar de verdade."
  exit 0
}

Write-Criado "VM $VmName criada"

$ip     = Get-AzValor @("vm", "show", "-d", "-g", $ResourceGroup, "-n", $VmName, "--query", "publicIps", "-o", "tsv")
$estado = Get-AzValor @("vm", "show", "-g", $ResourceGroup, "-n", $VmName, "--query", "provisioningState", "-o", "tsv")
$secTipo = Get-AzValor @("vm", "show", "-g", $ResourceGroup, "-n", $VmName, "--query", "securityProfile.securityType", "-o", "tsv")

# ============================================================
# PROXIMOS PASSOS
# ============================================================

Write-Host ""
Write-Host "=================================================="
Write-Host " VM PRONTA"
Write-Host "=================================================="
Write-Host " Nome         : $VmName"
Write-Host " Estado       : $estado"
Write-Host " Security     : $secTipo"
Write-Host " IP publico   : $ip  (estatico)"
Write-Host " Usuario      : $AdminUser"
Write-Host ""
Write-Host " Conectar:  mstsc /v:$ip"

if ($Prioridade -eq "Spot") {
  Write-Host ""
  Write-Host " ATENCAO - VM Spot (eviction-policy $EvictionPolicy):"
  if ($EvictionPolicy -eq "Deallocate") {
    Write-Host "   Numa eviccao a VM PARA e o disco persiste. Para voltar:"
    Write-Host "     az vm start -g $ResourceGroup -n $VmName"
  } else {
    Write-Host "   Numa eviccao a VM e APAGADA e o trabalho de configuracao se perde."
    Write-Host "   Considere -EvictionPolicy Deallocate na proxima criacao."
  }
}

Write-Host ""
Write-Host "-- PASSO 2: configurar a VM (manual, dentro dela) --"
Write-Host ""
Write-Host " 1. Instalar Node.js e Chrome (downloads manuais)."
Write-Host " 2. Copiar o conteudo de 'scripts para rodar na VM\configure-vm-image.ps1'"
Write-Host "    para C:\setup-complete-vm.ps1 na VM e rodar:"
Write-Host "      cd C:\ ; .\setup-complete-vm.ps1 -UserName $AdminUser -UserPassword <a MESMA senha>"
Write-Host "    (senha diferente da senha do admin quebra o autologon em silencio)"
Write-Host " 3. Windows 11 Pro limita a 1 sessao RDP simultanea. Se precisar de varias, rodar"
Write-Host "    tambem 'scripts para rodar na VM\rdpmultisession.ps1' dentro da VM."
Write-Host " 4. Conferir: Get-Content C:\logs\setup-complete-vm.log"
Write-Host ""
Write-Host "-- PASSO 3: capturar a imagem (aqui, na sua maquina) --"
Write-Host ""
Write-Host " Captura SPECIALIZED, sem sysprep/generalize (nao rode 'az vm generalize')."
Write-Host ""
Write-Host "   az vm deallocate -g $ResourceGroup -n $VmName"
Write-Host ""
Write-Host "   az sig create -g $ResourceGroup --gallery-name robodpc --location $Regiao"
Write-Host ""
Write-Host "   az sig image-definition create -g $ResourceGroup --gallery-name robodpc ``"
Write-Host "     --gallery-image-definition robodpcVMI ``"
Write-Host "     --publisher RoboDPC --offer Windows-11 --sku win11-25h2-pro ``"
Write-Host "     --os-type Windows --os-state Specialized --hyper-v-generation V2 ``"
Write-Host "     --features SecurityType=TrustedLaunch --location $Regiao"
Write-Host ""
Write-Host "   Os identificadores (publisher/offer/sku) sao IMUTAVEIS apos a criacao."
Write-Host "   Os valores acima refletem Windows 11; o create-50-vmss-image.ps1 ainda mostra"
Write-Host "   WindowsServer/2022-Datacenter, da epoca em que a base era Windows Server."
Write-Host ""
Write-Host "   `$vmId = az vm show -g $ResourceGroup -n $VmName --query id -o tsv"
Write-Host "   az sig image-version create -g $ResourceGroup --gallery-name robodpc ``"
Write-Host "     --gallery-image-definition robodpcVMI --gallery-image-version 2.0.0 ``"
Write-Host "     --virtual-machine `$vmId --target-regions $Regiao ``"
Write-Host "     --storage-account-type Standard_LRS --replica-count 1"
Write-Host ""
Write-Host "-- PASSO 4: subir a frota --"
Write-Host ""
Write-Host "   .\create-multiregion-vmss.ps1 -ImageVersion 2.0.0"
Write-Host ""
