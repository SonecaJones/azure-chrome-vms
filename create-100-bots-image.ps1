# --- CONFIGURAÇÕES ---
$ResourceGroup = "rg-bot-farm"
$Location = "eastus"  # Escolha uma região barata para Spot
$ImageId = "/subscriptions/SEU-ID-AQUI/resourceGroups/SEU-RG/providers/Microsoft.Compute/galleries/SuaGaleria/images/SuaImagem/versions/1.0.0"
$VmCount = 100
$BatchSize = 20
$SleepSeconds = 120 # 2 minutos de pausa entre lotes para o disco 'respirar'

# 1. Criar o Resource Group (se não existir)
Write-Host "Criando/Verificando Resource Group..." -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location

# 2. Criar uma VNet única (IMPORTANTE)
# Se deixarmos o comando da VM criar a rede, ele criará 100 VNets. Queremos 1 VNet com 100 VMs.
Write-Host "Criando Infra de Rede..." -ForegroundColor Cyan
az network vnet create --resource-group $ResourceGroup --name "vnet-bots" --address-prefix 10.0.0.0/16 --subnet-name "subnet-bots" --subnet-prefix 10.0.0.0/24

# 3. Loop de Criação das VMs
Write-Host "Iniciando deploy de $VmCount VMs..." -ForegroundColor Green

for ($i = 1; $i -le $VmCount; $i++) {
    $VmName = "worker-{0:D3}" -f $i # Gera nomes como worker-001, worker-002...
    
    Write-Host "Disparando criação da: $VmName (Spot)"

    # O comando AZ VM CREATE
    # --no-wait: Não trava o terminal esperando a VM ficar pronta (assíncrono)
    # --specialized: Indica que a imagem já tem usuário/senha (NÃO pede user novo)
    # --public-ip-address-allocation dynamic: Garante IP público
    # --os-disk-delete-option Delete: Deleta o disco quando a VM for apagada
    az vm create `
        --resource-group $ResourceGroup `
        --name $VmName `
        --image $ImageId `
        --specialized `
        --vnet-name "vnet-bots" `
        --subnet "subnet-bots" `
        --priority Spot `
        --eviction-policy Delete `
        --max-price -1 `
        --size Standard_D2s_v3 `
        --os-disk-delete-option Delete `
        --nic-delete-option Delete `
        --public-ip-address-dns-name $VmName `
        --no-wait

    # Lógica de Batch (Pausa a cada 20 máquinas)
    if ($i % $BatchSize -eq 0 -and $i -lt $VmCount) {
        Write-Host "Lote de $BatchSize atingido. Pausando por $SleepSeconds segundos para aliviar a imagem..." -ForegroundColor Yellow
        Start-Sleep -Seconds $SleepSeconds
    }
}

Write-Host "Todos os comandos de criação foram enviados!" -ForegroundColor Cyan