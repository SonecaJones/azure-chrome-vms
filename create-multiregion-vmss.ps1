# create-multiregion-vmss.ps1
# ------------------------------------------------------------------------------------------------
# I1 — Provisao de VMSS em MULTIPLAS REGIOES Azure (diversidade de IP/ASN anti-WAF Cloudflare).
#
# Por que multi-regiao: ~50 VMs num unico VMSS compartilham o mesmo subnet/ASN (AS8075). No pico
# (10h) isso e um sinal de bot forte para o Cloudflare. Espalhar a MESMA quantidade de VMs por
# 2-4 regioes da faixas de IP distintas pelo mesmo custo, fragmenta o burst e aprofunda o pool de
# IPs por onde cada registro pode rotacionar (os bots compartilham o pool de registros no Mongo).
#
# Este script e ADITIVO: nao altera o cookbook single-region (create-50-vmss-image.ps1). Ele
# parametriza os comandos `az` ja validados ali (bloco Uniform) e os executa por regiao.
#
# PRE-REQUISITOS:
#   - Imagem ja capturada na galeria (ver create-50-vmss-image.ps1, passos 1-3).
#   - `az login` feito; subscription correta selecionada.
#   - O Fabricio executa este script (nunca rodar provisao de producao a partir do agente).
#
# NUMERACAO DE INSTANCIA (instanceId) E TOTAL_MACHINES:
#   - O bot deriva `instanceId` de compute.name.split("_").pop() — 0-based POR scale set.
#     Em multi-regiao os ids colidem entre regioes (cada VMSS comeca em 0).
#   - Isso so importa se o jitter DETERMINISTICO for ligado (SESSION_DROP_JITTER_STEP_MS > 0),
#     que hoje esta OFF por padrao. Com jitter aleatorio (default) a colisao e irrelevante.
#   - `TOTAL_MACHINES` (env dos bots) deve ser a SOMA das instancias de TODAS as regioes.
#   - FUTURO (quando ligar jitter por slot cross-regiao): injetar um INSTANCE_ID_OFFSET por regiao
#     via custom-data/extension e somar no bot, para ter instanceId global unico. Ver TODO no fim.
# ------------------------------------------------------------------------------------------------

param(
  [string]   $ResourceGroup  = "dpcrobos",
  [string]   $Subscription   = "5c27bb8e-190b-4cf7-bd0e-c9dfca554525",
  # Lista de regioes alvo. Ex.: brazilsouth (principal) + eastus2 + westus3.
  [string[]] $Regioes        = @("brazilsouth", "eastus2", "westus3"),
  # Instancias POR regiao. Total global = InstanceCountPorRegiao * Regioes.Count.
  [int]      $InstanceCountPorRegiao = 16,
  [string]   $VmSku          = "Standard_F2s_v2",
  [string]   $GalleryName    = "robodpc",
  [string]   $ImageDefinition = "robodpcVMI",
  [string]   $ImageVersion   = "2.0.0",
  [string]   $AdminUser      = "robodpc"
)

$ErrorActionPreference = "Stop"
az account set --subscription $Subscription | Out-Null

$imageId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/galleries/$GalleryName/images/$ImageDefinition/versions/$ImageVersion"

Write-Host "=========================================="
Write-Host "PROVISAO MULTI-REGIAO — $($Regioes.Count) regioes x $InstanceCountPorRegiao VMs = $($Regioes.Count * $InstanceCountPorRegiao) VMs"
Write-Host "Regioes: $($Regioes -join ', ')"
Write-Host "=========================================="

# 1) Replicar a versao da imagem para TODAS as regioes alvo (galeria fica em brazilsouth, mas a
#    versao precisa ter replica em cada regiao onde o VMSS sera criado).
Write-Host "`n[1/3] Replicando imagem $ImageVersion para as regioes alvo..."
az sig image-version update `
  --resource-group $ResourceGroup `
  --gallery-name $GalleryName `
  --gallery-image-definition $ImageDefinition `
  --gallery-image-version $ImageVersion `
  --target-regions $Regioes `
  --output none
Write-Host "Replicacao solicitada (pode levar minutos para concluir)."

# 2) Por regiao: VNet + Subnet + NSG (RDP/VNC/WS) + VMSS Uniform (ids sequenciais).
$idxRegiao = 0
foreach ($regiao in $Regioes) {
  $sufixo   = ($regiao -replace '[^a-zA-Z0-9]', '')
  $vnet     = "VNet-RoboDPC-$sufixo"
  $subnet   = "Subnet-RoboDPC-$sufixo"
  $nsg      = "NSG-RoboDPC-$sufixo"
  $vmss     = "VMSSRoboDPC-$sufixo"
  $offset   = $idxRegiao * $InstanceCountPorRegiao  # base global do instanceId (uso futuro)

  Write-Host "`n[2/3] Regiao $regiao -> VMSS $vmss (offset instanceId global: $offset)"

  az network vnet create `
    --resource-group $ResourceGroup --name $vnet --location $regiao `
    --address-prefix 10.0.0.0/16 --subnet-name $subnet --subnet-prefix 10.0.1.0/24 `
    --output none

  az network nsg create --resource-group $ResourceGroup --name $nsg --location $regiao --output none
  $prioridade = 1000
  foreach ($regra in @(
      @{ nome = "Allow-RDP";     porta = 3389 },
      @{ nome = "Allow-VNC";     porta = 5900 },
      @{ nome = "Allow-WATCHER"; porta = 3000 }
  )) {
    az network nsg rule create `
      --resource-group $ResourceGroup --nsg-name $nsg --name $regra.nome `
      --priority $prioridade --source-address-prefixes '*' --destination-port-ranges $regra.porta `
      --access Allow --protocol Tcp --direction Inbound --output none
    $prioridade += 10
  }
  az network vnet subnet update `
    --resource-group $ResourceGroup --vnet-name $vnet --name $subnet `
    --network-security-group $nsg --output none

  # VMSS Uniform (mesmo bloco validado no cookbook): instanceIds sequenciais que o bot le.
  az vmss create `
    --resource-group $ResourceGroup `
    --name $vmss `
    --location $regiao `
    --orchestration-mode Uniform `
    --image $imageId `
    --instance-count $InstanceCountPorRegiao `
    --vm-sku $VmSku `
    --priority Spot `
    --eviction-policy Delete `
    --max-price -1 `
    --public-ip-per-vm `
    --storage-sku StandardSSD_LRS `
    --vnet-name $vnet `
    --subnet $subnet `
    --security-type TrustedLaunch `
    --enable-vtpm true `
    --enable-secure-boot true `
    --upgrade-policy-mode Manual `
    --specialized `
    --output none

  Write-Host "VMSS $vmss criado em $regiao."
  $idxRegiao++
}

# 3) Lembrete de configuracao dos bots.
$total = $Regioes.Count * $InstanceCountPorRegiao
Write-Host "`n[3/3] CONCLUIDO."
Write-Host "=========================================="
Write-Host "PROXIMOS PASSOS (config dos bots):"
Write-Host "  - Defina TOTAL_MACHINES=$total no .env dos bots (soma global de todas as regioes)."
Write-Host "  - Liste os IPs por regiao:"
foreach ($regiao in $Regioes) {
  $sufixo = ($regiao -replace '[^a-zA-Z0-9]', '')
  Write-Host "      az vmss list-instance-public-ips -g $ResourceGroup -n VMSSRoboDPC-$sufixo -o table"
}
Write-Host "=========================================="

# ------------------------------------------------------------------------------------------------
# TODO (futuro, so se ligar jitter por slot cross-regiao, SESSION_DROP_JITTER_STEP_MS > 0):
#   Injetar INSTANCE_ID_OFFSET=<offset> por regiao via custom-data/extension e somar no bot ao
#   calcular o slot, garantindo instanceId global unico. Hoje (jitter aleatorio) nao e necessario.
# ------------------------------------------------------------------------------------------------
