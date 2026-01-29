# start-all-vms.ps1
$resourceGroup = "RG-DPC"

Write-Output "Listando VMs do resource group $resourceGroup..."
$vms = az vm list -g $resourceGroup --query "[].name" -o tsv

foreach ($vm in $vms) {
    Write-Output "Iniciando VM: $vm"
    az vm start -g $resourceGroup -n $vm --no-wait
}

Write-Output "Comando enviado para inicializar todas as VMs."
