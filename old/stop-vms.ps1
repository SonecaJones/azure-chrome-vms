# stop-all-vms.ps1
$resourceGroup = "RG-DPC"

Write-Output "Listando VMs do resource group $resourceGroup..."
$vms = az vm list -g $resourceGroup --query "[].name" -o tsv

foreach ($vm in $vms) {
    Write-Output "Desalocando VM: $vm"
    az vm deallocate -g $resourceGroup -n $vm --no-wait
}

Write-Output "Comando enviado para todas as VMs. Elas serão desligadas e desalocadas."
