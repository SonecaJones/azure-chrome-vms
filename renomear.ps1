# rename-vmss-fixed.ps1

Write-Host "=========================================="
Write-Host "RENOMEANDO HOSTNAMES VMSS"
Write-Host "=========================================="
Write-Host ""

# FORÇAR o nome sem underscore
$resourceGroup = "dpcrobos"
$vmssName = "VMSSRoboDPC"  # EXATAMENTE como aparece em: az vmss list

Write-Host "Resource Group: $resourceGroup"
Write-Host "VMSS Name: $vmssName"
Write-Host ""

# Testar conexão com o VMSS
Write-Host "Testando acesso ao VMSS..."
try {
    $vmssInfo = az vmss show `
      --resource-group $resourceGroup `
      --name $vmssName `
      --query "{Name:name, Capacity:sku.capacity, Mode:orchestrationMode}" `
      -o json 2>&1 | ConvertFrom-Json
    
    if ($vmssInfo) {
        Write-Host "✓ VMSS encontrado:"
        Write-Host "  Nome: $($vmssInfo.Name)"
        Write-Host "  Capacidade: $($vmssInfo.Capacity)"
        Write-Host "  Modo: $($vmssInfo.Mode)"
        Write-Host ""
    }
} catch {
    Write-Host "✗ Erro ao acessar VMSS: $_"
    Write-Host ""
    Write-Host "Verifique o nome exato executando:"
    Write-Host "  az vmss list --resource-group $resourceGroup --output table"
    exit 1
}

# Obter instâncias
Write-Host "Obtendo lista de instâncias..."
$instancesJson = az vmss list-instances `
  --resource-group $resourceGroup `
  --name $vmssName `
  -o json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Erro ao listar instâncias:"
    Write-Host $instancesJson
    exit 1
}

$instances = $instancesJson | ConvertFrom-Json

Write-Host "Total de instâncias: $($instances.Count)"
Write-Host ""

if ($instances.Count -eq 0) {
    Write-Host "Nenhuma instância encontrada no VMSS"
    exit 0
}

# Filtrar 34-67
$instancesToRename = $instances | Where-Object { 
    $id = [int]$_.instanceId
    $id -ge 34 -and $id -le 67
}

Write-Host "Instâncias no range 34-67: $($instancesToRename.Count)"
Write-Host ""

if ($instancesToRename.Count -eq 0) {
    Write-Host "Nenhuma instância no range 34-67"
    Write-Host ""
    Write-Host "Instâncias disponíveis:"
    $instances | ForEach-Object { Write-Host "  - Instance ID: $($_.instanceId)" }
    exit 0
}

# Preview
Write-Host "=========================================="
Write-Host "PREVIEW"
Write-Host "=========================================="
foreach ($instance in $instancesToRename) {
    $newHostname = "VMRoboDPC$($instance.instanceId)"
    $currentHostname = $instance.osProfile.computerName
    
    Write-Host "ID: $($instance.instanceId)"
    Write-Host "  Atual: $currentHostname"
    Write-Host "  Novo: $newHostname"
    Write-Host ""
}

# Confirmar
$confirmation = Read-Host "Prosseguir? (S/N)"
if ($confirmation -ne 'S' -and $confirmation -ne 's') {
    Write-Host "Cancelado"
    exit
}

Write-Host ""
Write-Host "=========================================="
Write-Host "RENOMEANDO"
Write-Host "=========================================="
Write-Host ""

$successCount = 0
$skipCount = 0
$errorCount = 0

foreach ($instance in $instancesToRename) {
    $instanceId = $instance.instanceId
    $newHostname = "VMRoboDPC_$instanceId"
    $currentHostname = $instance.osProfile.computerName
    
    Write-Host "[$instanceId] Processando..."
    
    if ($currentHostname -eq $newHostname) {
        Write-Host "  ✓ Já correto"
        Write-Host ""
        $skipCount++
        continue
    }
    
    $script = @"
if (`$env:COMPUTERNAME -ne '$newHostname') {
    Rename-Computer -NewName '$newHostname' -Force
    "Renomeado para $newHostname em `$(Get-Date)" | Set-Content C:\logs\hostname-renamed.flag
    Start-Sleep 15
    Restart-Computer -Force
}
"@
    
    try {
        $tempScript = [System.IO.Path]::GetTempFileName() + ".ps1"
        $script | Set-Content $tempScript -Encoding UTF8

        az vmss run-command invoke `
          --resource-group $resourceGroup `
          --name $vmssName `
          --instance-id $instanceId `
          --command-id RunPowerShellScript `
          --scripts "@$tempScript" `
          --output none

        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ Enviado"
            $successCount++
        } else {
            Write-Host "  ✗ Erro (código: $LASTEXITCODE)"
            $errorCount++
        }
    } catch {
        Write-Host "  ✗ Exceção: $_"
        $errorCount++
    }
    
    Write-Host ""
    Start-Sleep -Seconds 2
}

Write-Host "=========================================="
Write-Host "CONCLUÍDO"
Write-Host "=========================================="
Write-Host "Sucesso: $successCount"
Write-Host "Já corretas: $skipCount"
Write-Host "Erros: $errorCount"
Write-Host ""
Write-Host "Aguarde ~5 minutos"