$resourceGroup = "RG-DPC"
$scriptUrl = "https://raw.githubusercontent.com/SonecaJones/azure-chrome-vms/main/install-chrome.ps1"

# Criar arquivo JSON de settings
$settingsObj = @{
    fileUris = @($scriptUrl)
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -File install-chrome.ps1"
}

$settingsPath = ".\settings-chrome.json"
$settingsObj | ConvertTo-Json -Depth 10 | Out-File -Encoding UTF8 $settingsPath

Write-Host "Arquivo JSON gerado em: $settingsPath"

# Anexar extensão
az vm extension set `
    --publisher Microsoft.Compute `
    --name CustomScriptExtension `
    --resource-group $resourceGroup `
    --vm-name chrome-vm-001 `
    --settings $settingsPath `
    --protected-settings "{}"