# rename-vmss-instances-sequential.ps1

Write-Host "=========================================="
Write-Host "RENOMEANDO INSTÂNCIAS DO VMSS"
Write-Host "=========================================="

$resourceGroup = "dpcrobos"
$vmssName = "VMSSRoboDPC_"

# Obter todas as instâncias
$instances = az vmss list-instances `
  --resource-group $resourceGroup `
  --name $vmssName `
  --query "[].{id:instanceId, name:name}" `
  -o json | ConvertFrom-Json

Write-Host "Total de instâncias: $($instances.Count)"
Write-Host ""

# Ordenar por instanceId para consistência
$instances = $instances | Sort-Object id

# Preview
Write-Host "Preview das alterações:"
Write-Host "----------------------------------------"
$index = 0
foreach ($instance in $instances) {
    $newHostname = "VMRoboDPC-$index"
    Write-Host "Instance ID: $($instance.id) -> Hostname: $newHostname"
    $index++
}
Write-Host "----------------------------------------"

# Confirmar
$confirmation = Read-Host "`nDeseja prosseguir? (S/N)"
if ($confirmation -ne 'S' -and $confirmation -ne 's') {
    Write-Host "Operação cancelada"
    exit
}

# Executar renomeação
$index = 0
foreach ($instance in $instances) {
    $newHostname = "VMRoboDPC-$index"
    
    Write-Host "`nProcessando instância $($instance.id)..."
    
    $renameScript = @"
`$flagFile = 'C:\logs\hostname-renamed.flag'
`$newHostname = '$newHostname'
`$currentHostname = `$env:COMPUTERNAME

Write-Host "Hostname atual: `$currentHostname"
Write-Host "Novo hostname: `$newHostname"

if (`$currentHostname -ne `$newHostname) {
    Write-Host "Renomeando..."
    Rename-Computer -NewName `$newHostname -Force
    "Renomeado para `$newHostname em `$(Get-Date)" | Set-Content `$flagFile
    Write-Host "Reiniciando em 10 segundos..."
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}
else {
    Write-Host "Hostname já está correto"
    "Hostname OK: `$newHostname em `$(Get-Date)" | Set-Content `$flagFile
}
"@
    
    az vmss run-command invoke `
      --resource-group $resourceGroup `
      --name $vmssName `
      --instance-id $instance.id `
      --command-id RunPowerShellScript `
      --scripts $renameScript | Out-Null
    
    Write-Host "✓ Comando enviado para instância $($instance.id)"
    
    $index++
    Start-Sleep -Seconds 3
}

Write-Host ""
Write-Host "=========================================="
Write-Host "RENOMEAÇÃO CONCLUÍDA"
Write-Host "=========================================="
Write-Host "As VMs estão sendo renomeadas e reiniciadas"
Write-Host "Aguarde ~5 minutos para todas voltarem online"
Write-Host ""
Write-Host "Hostnames após reinicialização:"
for ($i = 0; $i -lt $instances.Count; $i++) {
    Write-Host "  - VMRoboDPC-$i"
}