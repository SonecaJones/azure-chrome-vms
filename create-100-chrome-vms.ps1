# create-100-chrome-vms.ps1 vmCount = instancias
# Requisitos: Azure CLI (az) autenticado no subscription correto.
# Execute no PowerShell (Windows) como seu usuário normal.

# --------- CONFIGURAÇÃO ----------
$resourceGroup = "RG-DPC"
$location = "brazilsouth"           # ajuste se quiser outra região
$nsgName = "nsg-chrome-win11"
$vmBaseName = "chrome-vm"
$imageUrn = "MicrosoftWindowsDesktop:windows11preview:win11-25h2-pro:latest"
$vmSize = "Standard_D2s_v5"
$vmCount = 100

$adminUser = ""
$adminPass = ""   # <-- troque por senha forte

# URL pública do install-chrome.ps1 (suba o script e coloque a URL aqui)
$scriptUrl = "https://raw.githubusercontent.com/SEU-USER/SEU-REPO/main/install-chrome.ps1"  # <-- substitua

# --------- CRIAR RESOURCE GROUP (se já existir, ignora) ----------
Write-Output "Criando resource group $resourceGroup (se não existir)..."
az group create --name $resourceGroup --location $location | Out-Null

# --------- CRIAR NSG E REGRAS ----------
Write-Output "Criando NSG $nsgName..."
az network nsg create --resource-group $resourceGroup --name $nsgName | Out-Null

Write-Output "Criando regra RDP (3389)..."
az network nsg rule create `
  --resource-group $resourceGroup `
  --nsg-name $nsgName `
  --name allow-rdp `
  --priority 100 `
  --protocol Tcp `
  --destination-port-ranges 3389 `
  --access Allow | Out-Null

Write-Output "Criando regra Chrome CDP (9222)..."
az network nsg rule create `
  --resource-group $resourceGroup `
  --nsg-name $nsgName `
  --name allow-9222 `
  --priority 200 `
  --protocol Tcp `
  --destination-port-ranges 9222 `
  --access Allow | Out-Null

# --------- LOOP PARA CRIAR VMS ----------
for ($i = 1; $i -le $vmCount; $i++) {
    $index = $i.ToString("000")            # chrome-vm-001, chrome-vm-002, ...
    $vmName = "$vmBaseName-$index"

    Write-Output "-------------------------------"
    Write-Output "Criando VM: $vmName"

    # Criar VM (inclui NIC e Public IP automaticamente)
    az vm create `
      --resource-group $resourceGroup `
      --name $vmName `
      --image $imageUrn `
      --size $vmSize `
      --admin-username $adminUser `
      --admin-password $adminPass `
      --public-ip-sku Standard `
      --nsg $nsgName `
      --no-wait | Out-Null

    Write-Output "VM $vmName criada. Aguardando disponibilidade para anexar extensão..."

    # Aguarda até a VM ter estado 'Succeeded' (pouco polling simples)
    do {
        Start-Sleep -Seconds 5
        $provisioning = az vm get-instance-view --resource-group $resourceGroup --name $vmName --query "instanceView.statuses[?starts_with(code, 'ProvisioningState/')].displayStatus" -o tsv 2>$null
    } while ($provisioning -ne "Provisioning succeeded")

    Write-Output "Anexando Custom Script Extension (instala Chrome)..."

    $extSettings = @{
      "fileUris" = @($scriptUrl)
      "commandToExecute" = "powershell -ExecutionPolicy Unrestricted -File install-chrome.ps1"
    } | ConvertTo-Json -Depth 4

    az vm extension set `
      --publisher Microsoft.Compute `
      --name CustomScriptExtension `
      --resource-group $resourceGroup `
      --vm-name $vmName `
      --settings "$extSettings" | Out-Null

    Write-Output "Extensão anexada à VM $vmName. Próxima VM..."
    # Pequena pausa para reduzir chance de throttling
    Start-Sleep -Seconds 2
}

Write-Output "-------------------------------"
Write-Output "Criação das VMs iniciada. Aguarde até todas completarem provisioning."

# --------- LISTAR IPs PÚBLICOS (após todas criadas) ----------
Write-Output "`nAguardando 30s antes de coletar IPs públicos..."
Start-Sleep -Seconds 30

Write-Output "`nListando IPs públicos das VMs no resource group $resourceGroup..."
az vm list-ip-addresses --resource-group $resourceGroup -o table

Write-Output "`nScript finalizado. Use 'az vm list-ip-addresses -g $resourceGroup -o table' para ver IPs atualizados."
