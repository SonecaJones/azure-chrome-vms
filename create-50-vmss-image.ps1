#opcao com VNet
# Primeiro, crie uma VNet e Subnet
az network vnet create `
  --resource-group dpcrobos `
  --name VNet-RoboDPC `
  --address-prefix 10.0.0.0/16

az network vnet subnet create `
  --resource-group dpcrobos `
  --vnet-name VNet-RoboDPC `
  --name Subnet-RoboDPC `
  --address-prefix 10.0.1.0/24

# 1. Criar Network Security Group (NSG)
az network nsg create `
  --resource-group dpcrobos `
  --name NSG-RoboDPC `
  --location brazilsouth

# 2. Criar regra para permitir RDP (porta 3389)
az network nsg rule create `
  --resource-group dpcrobos `
  --nsg-name NSG-RoboDPC `
  --name Allow-RDP `
  --priority 1000 `
  --source-address-prefixes '*' `
  --source-port-ranges '*' `
  --destination-address-prefixes '*' `
  --destination-port-ranges 3389 `
  --access Allow `
  --protocol Tcp `
  --direction Inbound `
  --description "Permitir RDP de qualquer origem"

# Adicionar regra NSG para porta 5900 (VNC)
az network nsg rule create `
  --resource-group dpcrobos `
  --nsg-name VMrobodpc-nsg `
  --name Allow-VNC `
  --priority 1040 `
  --source-address-prefixes '*' `
  --destination-port-ranges 5900 `
  --access Allow `
  --protocol Tcp `
  --direction Inbound `
  --description "Permitir VNC"

  #VMrobodpc-nsg nome do NSG associado à VM individual, não ao VMSS. Para o VMSS, associe o NSG à subnet.

# 3. Associar NSG à Subnet
az network vnet subnet update `
  --resource-group dpcrobos `
  --vnet-name VNet-RoboDPC `
  --name Subnet-RoboDPC `
  --network-security-group NSG-RoboDPC

#********************* Essa é a mais próxima do sucesso até agora ******************************************
# Depois crie o VMSS referenciando essa VNet  (Standard_F4s_v2 ou Standard_D2s_v3)
az vmss create `
  --resource-group dpcrobos `
  --name VMSSRoboDPC1 `
  --orchestration-mode Flexible `
  --image "/subscriptions/5c27bb8e-190b-4cf7-bd0e-c9dfca554525/resourceGroups/dpcrobos/providers/Microsoft.Compute/galleries/vmssrobodpc/images/vmrobodpcimg/versions/1.0.0" `
  --instance-count 1 `
  --vm-sku Standard_D2s_v3 `
  --priority Spot `
  --eviction-policy Delete `
  --public-ip-per-vm `
  --storage-sku StandardSSD_LRS `
  --vnet-name VNet-RoboDPC `
  --subnet Subnet-RoboDPC `
  --admin-username robodpc `
  --admin-password "robodpc2025#" `
  --specialized `
  --security-type TrustedLaunch `
  --enable-vtpm true `
  --enable-secure-boot true


  # *********** dando erro de imagem especializada em modo UNIFORM **************
#MODO UNIFORM PARA IDS SEQUENCIAIS
az vmss create `
  --resource-group dpcrobos `
  --name VMSSRoboDPC `
  --orchestration-mode Uniform `
  --computer-name-prefix VMRoboDPC `
  --image "/subscriptions/5c27bb8e-190b-4cf7-bd0e-c9dfca554525/resourceGroups/dpcrobos/providers/Microsoft.Compute/galleries/robodpc/images/robodpcVMI/versions/2.0.0" `
  --instance-count 3 `
  --vm-sku Standard_D2s_v3 `
  --priority Spot `
  --eviction-policy Delete `
  --max-price -1 `
  --public-ip-per-vm `
  --storage-sku StandardSSD_LRS `
  --vnet-name VNet-RoboDPC `
  --subnet Subnet-RoboDPC `
  --admin-username robodpc `
  --admin-password "robodpc2025#" `
  --security-type TrustedLaunch `
  --enable-vtpm true `
  --enable-secure-boot true `
  --upgrade-policy-mode Manual

# 1. Capturar nova imagem (na máquina local, não na VM)
az vm deallocate --resource-group dpcrobos --name VMrobodpc

# Se quiser generalizar (opcional):
# az vm generalize --resource-group dpcrobos --name VMrobodpc

# Criar versão da imagem
az sig image-version create `
  --resource-group dpcrobos `
  --gallery-name robodpc `
  --gallery-image-definition robodpcVMI `
  --gallery-image-version 2.0.0 `
  --managed-image /subscriptions/.../VMrobodpc

# 2. Criar VMSS com a nova imagem
az vmss create `
  --resource-group dpcrobos `
  --name VMSSRoboDPC_ `
  --orchestration-mode Flexible `
  --image "/subscriptions/.../versions/2.0.0" `
  --instance-count 2 `
  --vm-sku Standard_D2s_v3 `
  --priority Spot `
  --eviction-policy Delete `
  --public-ip-per-vm `
  --storage-sku StandardSSD_LRS `
  --vnet-name VNet-RoboDPC `
  --subnet Subnet-RoboDPC `
  --admin-username robodpc `
  --admin-password "robodpc2025#" `
  --specialized `
  --security-type TrustedLaunch `
  --enable-vtpm true `
  --enable-secure-boot true








  
# SCRIPT DURANTE CRIACAO
$customScript = @'
#ps1_sysnative
$envFile = "C:\dpc\dpc-interno-rep\.env"
if (Test-Path $envFile) {
    $content = Get-Content $envFile -Raw
    $content = $content -replace 'STRING_ANTIGA', 'STRING_NOVA'
    $content | Set-Content $envFile -NoNewline
}
'@

$encodedScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($customScript))

# Adicione ao comando de criação do VMSS:
az vmss create `
  --resource-group dpcrobos `
  --name VMSSRoboDPC_ `
  --custom-data $encodedScript
  # ... outros parâmetros ...

# Opção A: Script inline (para mudanças simples)
# 1. Aplicar a extensão
az vmss extension set `
  --resource-group dpcrobos `
  --vmss-name VMSSRoboDPC_ `
  --name CustomScriptExtension `
  --publisher Microsoft.Compute `
  --version 1.10 `
  --settings '{\"commandToExecute\": \"powershell -Command \\\"(Get-Content C:\\dpc\\dpc-interno-rep\\.env -Raw) -replace ''cluster0.kuvrubv'', ''teste.kuvrubv'' | Set-Content C:\\dpc\\dpc-interno-rep\\.env -NoNewline\\\"\"}'

# 2. Atualizar as instâncias para aplicar a extensão
az vmss update-instances `
  --resource-group dpcrobos `
  --name VMSSRoboDPC_ `
  --instance-ids "*"

# LISTAR TODOS OS INSTANCES
az vmss list-instances --resource-group dpcrobos --name VMSSRoboDPC_ --output table

# LISTAR TODOS OS IPS
az vmss list-instance-public-ips `
  --resource-group dpcrobos `
  --name VMSSRoboDPC_ `
  -o table

# STOP + DEALLOCATE TODOS OS INSTANCES
az vmss deallocate `
  --resource-group dpcrobos `
  --name VMSSRoboDPC_
  

# START EM TODOS OS INSTANCES
az vmss start `
  --resource-group dpcrobos `
  --name VMSSRoboDPC_
# reSTART EM TODOS OS INSTANCES
az vmss restart `
  --resource-group dpcrobos `
  --name VMSSRoboDPC_

az vm user update `
  --resource-group dpcrobos `
  --name dpcrobos `
  --username robodpc `
  --password robodpc2025#

net user manut "robodpc2025#" /add
net localgroup administrators manut /add
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /d robodpc /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /d "robodpc2025#" /f

verifica se o usuario logou
qwinsta 

lista chromes ativos
Get-Process chrome | select MainWindowTitle,Id,SessionId

encerra todos os chromes
Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force

criar imagem da VM especializada, sem sysprep

#localizar a imagem
az sig image-definition list -g dpcrobos --gallery-name vmssrobodpc -o table  

az sig image-version list `
  --resource-group dpcrobos `
  --gallery-name vmssrobodpc `
  --gallery-image-definition vmrobodpcimg `
  --output table

az sig image-version show `
   --resource-group dpcrobos `
   --gallery-name vmssrobodpc `
   --gallery-image-definition vmrobodpcimg `
   --gallery-image-version 1.0.0 `
   --query id -o tsv