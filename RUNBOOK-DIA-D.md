# Runbook do dia D — 2026-09-23, abertura 10:00 GMT-3

Montagem da frota do zero. A assinatura estava **vazia** em 2026-09-22 (0 VMs, 0 VMSS, 0 imagens,
0 galerias, 0 ACR), então tudo abaixo cria recurso novo.

**Configuração desta temporada** (já aplicada nos `.env`):

| | |
|---|---|
| OM | `NIDOM=75` |
| Abertura | `HORA_ABERTURA=10:00` (idêntico nos dois bots VMSS) |
| Frota | 30 VMs, VMSS única, `brazilsouth`, `Standard_F2s_v2` Spot |
| Bases | `TOTAL_BASES=2`, `TOTAL_MACHINES=30` → instâncias 0-14 em `rep1`, 15-29 em `rep2` |
| Slots | `TOTAL_SLOTS=33` = **maior `instanceId` + 1** (a VMSS sobe 0..32) |
| Mongo | **produção** `cluster0.g8ou0.mongodb.net` |
| Preferenciais | `PREF_DIAS_RESERVADOS=0` (inerte) |

> **`TOTAL_MACHINES` e `TOTAL_SLOTS` são coisas diferentes — conferir os dois (R5, 2026-09-23).**
> `TOTAL_MACHINES` divide a frota entre as bases e continua sendo a contagem de VMs **de
> agendamento** (as que viram watcher não contam). `TOTAL_SLOTS` é o divisor do slot
> (`instanceId % TOTAL_SLOTS`) na partição da agenda (L6) e no jitter pós-manutenção (M5), e tem
> de ser **maior que o maior `instanceId` da VMSS**. No dia D 2026-09-23 os dois eram o mesmo
> valor (30) com ids indo até 32: a VM_30 caiu no slot 0 e a VM_31 no slot 1 — duas VMs varrendo a
> agenda a partir do mesmo ponto. Se subir/derrubar VMs, reavaliar os dois separadamente.

Quota conferida: Spot usa *Total Regional Low-priority vCPUs* = **150**; 30 × 2 = 60. Folga de 2,5×.

---

## 1. VM originária

```powershell
cd "C:\Dev\free\DPC\azure-chrome-vms"
$env:DPC_VM_ADMIN_PASSWORD = "<senha forte>"   # ANOTAR: reusada no passo 2
.\create-vm-originaria.ps1 -DryRun
.\create-vm-originaria.ps1
```

Cria `dpcrobos` + `VNet-RoboDPC-origem`/`Subnet-RoboDPC-origem` + `NSG-VMrobodpc` + a VM
`VMrobodpc` (Windows 11 Pro 25H2, Spot com `-EvictionPolicy Deallocate` — o disco sobrevive a uma
evicção no meio da instalação). Idempotente; aborta se a VM já existir.

Se a configuração ficar lenta: `-VmSize Standard_F4s_v2`. **Não muda o SKU da frota.**

## 2. Dentro da VM (RDP, como Admin)

**Antes de qualquer script**, levar o código — nenhum `.ps1` automatiza isto:

```
C:\dpc\dpc-interno-rep\      <- com o .env já corrigido, e npm install rodado
C:\dpc\dpc-agenda-watcher\   <- idem (para as 1-2 VMs de watcher)
C:\dpc\install-node-chrome.ps1
C:\dpc\configure-vm-image.ps1
```

```powershell
cd C:\dpc
.\install-node-chrome.ps1                 # Node 24.18.0 + Chrome MSI, auto-update congelado
.\configure-vm-image.ps1 -UserName robodpc -UserPassword "<a MESMA senha do passo 1>"
```

A senha **tem** de ser a mesma: o autologon é gravado no registro e uma senha diferente quebra em
silêncio — a VM sobe sem sessão GUI, o Chrome não abre e o bot não roda.

Conferir `C:\logs\setup-complete-vm.log`, **reiniciar** e validar que o bot sobe sozinho:

- `C:\logs\node\bot-<vm>-<data>.log` com linhas de ciclo
- `C:\logs\node\bot-atual.txt` apontando para esse arquivo
- `C:\logs\node\heartbeat-<vm>.txt` sendo atualizado ← é o V4; **sem esse arquivo o supervisor não
  vigia travamento**
- `C:\logs\node\supervisor-<vm>-<data>.log` sem reinícios em loop

## 3. Capturar a imagem

```powershell
az vm deallocate -g dpcrobos -n VMrobodpc      # NAO rodar az vm generalize: a imagem e Specialized

az sig create -g dpcrobos --gallery-name robodpc --location brazilsouth

az sig image-definition create -g dpcrobos --gallery-name robodpc `
  --gallery-image-definition robodpcVMI `
  --publisher RoboDPC --offer Windows-11 --sku win11-25h2-pro `
  --os-type Windows --os-state Specialized --hyper-v-generation V2 `
  --features SecurityType=TrustedLaunch --location brazilsouth

$vmId = az vm show -g dpcrobos -n VMrobodpc --query id -o tsv
az sig image-version create -g dpcrobos --gallery-name robodpc `
  --gallery-image-definition robodpcVMI --gallery-image-version 1.0.0 `
  --virtual-machine $vmId --target-regions brazilsouth `
  --storage-account-type Standard_LRS --replica-count 1
```

**Usar estes rótulos, não os de `create-50-vmss-image.ps1`** — aquele runbook ainda traz
`--offer WindowsServer --sku 2022-Datacenter`, resíduo da época de Windows Server. Publisher, offer
e sku são **imutáveis** depois de criados, e como não existe nenhuma galeria na assinatura, esta é
a chance de acertar.

Acompanhar a replicação:

```powershell
az sig image-version show -g dpcrobos --gallery-name robodpc `
  --gallery-image-definition robodpcVMI --gallery-image-version 1.0.0 `
  --query "{State:provisioningState, Replicas:publishingProfile.targetRegions[0].regionalReplicaCount}"
```

## 4. Rede da frota + VMSS de 30

A rede da frota é um conjunto **separado** do `-origem` do passo 1:

```powershell
az network vnet create -g dpcrobos --name VNet-RoboDPC --address-prefix 10.0.0.0/16 --location brazilsouth
az network vnet subnet create -g dpcrobos --vnet-name VNet-RoboDPC --name Subnet-RoboDPC --address-prefix 10.0.1.0/24

az network nsg create -g dpcrobos --name NSG-RoboDPC --location brazilsouth
az network nsg rule create -g dpcrobos --nsg-name NSG-RoboDPC --name Allow-RDP `
  --priority 1000 --source-address-prefixes '*' --destination-port-ranges 3389 `
  --access Allow --protocol Tcp --direction Inbound
az network nsg rule create -g dpcrobos --nsg-name NSG-RoboDPC --name Allow-VNC `
  --priority 1040 --source-address-prefixes '*' --destination-port-ranges 5900 `
  --access Allow --protocol Tcp --direction Inbound
az network nsg rule create -g dpcrobos --nsg-name NSG-RoboDPC --name Allow-WATCHER `
  --priority 1050 --source-address-prefixes '*' --destination-port-ranges 3000 `
  --access Allow --protocol Tcp --direction Inbound

az network vnet subnet update -g dpcrobos --vnet-name VNet-RoboDPC --name Subnet-RoboDPC `
  --network-security-group NSG-RoboDPC
```

A porta **3000** é o socket.io do watcher: sem ela as VMs não recebem `agenda_aberta`/`dpc_online`.

**O nome da VMSS é o que define a identidade de cada VM.** Em `--orchestration-mode Uniform` o
Instance Metadata devolve `compute.name` como `<nome-da-VMSS>_<instanceId>` — ou seja,
`VMSSRoboDPC_0` … `VMSSRoboDPC_29`, já com underscore e `instanceId` decimal. É exatamente o que
`instanceIdDeContainer` espera (`nome.split("_").pop()`), então **não há nada a renomear**: as
instâncias já nascem sequenciais. Não trocar o modo para `Flexible` nem pôr underscore no nome da
VMSS.

```powershell
az vmss create -g dpcrobos -n VMSSRoboDPC `
  --orchestration-mode Uniform `
  --image "/subscriptions/5c27bb8e-190b-4cf7-bd0e-c9dfca554525/resourceGroups/dpcrobos/providers/Microsoft.Compute/galleries/robodpc/images/robodpcVMI/versions/1.0.0" `
  --instance-count 30 `
  --vm-sku Standard_F2s_v2 `
  --priority Spot --eviction-policy Delete --max-price -1 `
  --public-ip-per-vm `
  --storage-sku StandardSSD_LRS `
  --vnet-name VNet-RoboDPC --subnet Subnet-RoboDPC `
  --security-type TrustedLaunch --enable-vtpm true --enable-secure-boot true `
  --upgrade-policy-mode Manual `
  --specialized
```

`--public-ip-per-vm` é o que dá diversidade de IP — sem ele as 30 VMs saem pelo mesmo NAT.
`--orchestration-mode Uniform` é o que garante `instanceId` sequencial.

## 5. Conferir a identidade das instâncias (não há renomeação)

As instâncias já nascem sequenciais: o bot lê `compute.name` do Instance Metadata, que em Uniform
é `VMSSRoboDPC_<instanceId>`. **Os scripts `renomear.ps1` e `rename-vmss-instances-sequential.ps1`
são legado** — eles mexem no *hostname do Windows*, que não é a fonte que o bot usa.

```powershell
az vmss list-instances -g dpcrobos -n VMSSRoboDPC --query "[].instanceId" -o tsv
```

Esperado: `0` … `29`, sem buraco. No log de boot de cada VM a linha correspondente é
`Obtido nome da VM AZURE: VMSSRoboDPC_<N>`.

Quirk conhecido e aceito: a instância `_0` devolve `null` no `parseInt` (`0` é falsy). Ela sai da
partição densa e cai no hash; a base dela continua `rep1`, que é onde a fórmula já a colocaria.
Está coberto por teste — **não corrigir agora**.

## 6. `dpc-login-gov` (containers)

```powershell
az acr create -g dpcrobos -n robodpc --sku Basic --admin-enabled true
az acr credential show -n robodpc          # anotar usuario e senha NOVOS
```

Build e push (manual, em `C:\Dev\free\DPC\DPC LOGIN\dpc-login-gov`):

```
docker login robodpc.azurecr.io --username robodpc
docker build -t robodpc.azurecr.io/robodpc_gov:latest .
docker push robodpc.azurecr.io/robodpc_gov:latest
```

Antes de publicar, editar **os dois** templates em `azure\` (`deployNGroups_REP1.json` e
`deployNGroups_REP2.json`):

- `DB_CONN` → produção (`cluster0.g8ou0.mongodb.net/rep1` e `/rep2`). Hoje o REP1 aponta para
  `teste.kuvrubv` — é o **template** que decide, não o `ENV` do Dockerfile.
- `imageRegistryCredentials.password` → a senha nova do ACR (a do arquivo é do registry apagado).
- `copy.count` → hoje `3` no REP1 e `5` no REP2; equalizar (as duas bases têm 15 VMs cada).

```powershell
az deployment group create -g dpcrobos --template-file deployNGroups_REP1.json
az deployment group create -g dpcrobos --template-file deployNGroups_REP2.json
az container list -g dpcrobos -o table
az container logs -g dpcrobos -n robodpc_gov_rep1_0 --container-name robo
```

Não usar `deployNGroups_WAT.json` (o watcher vai em VM) nem `deployNGroups_AV.json` (base `avulso`).

**Armadilha do build:** não existe `.dockerignore`, então o `COPY . .` copia o `node_modules` do
Windows por cima do que o `RUN npm install` gerou no Linux. As dependências deste bot são JS puro e
sempre funcionou assim — mas se aparecer erro de módulo nativo, apagar `node_modules` local antes
do `docker build`.

## 7. Login inicial (local, com Chrome na 9222)

O `dpc-login` roda **local** por causa do hCaptcha. Com `TOTAL_BASES=2` ele precisa atender as duas
bases, e ele **não alterna sozinho** (lê um `DB_CONN` com a base embutida):

1. `.env` já está em `.../rep1` — rodar até a fila de registros sem `cookiesGov` esvaziar;
2. trocar a linha ativa do `DB_CONN` para `.../rep2` e rodar de novo.

Esquecer a segunda base é falha silenciosa: as 15 VMs de `rep2` não acham registro elegível
(`cookiesGov: null` reprova no claim) e passam o dia logando "Sem registros encontrados".

Representantes PJ (e-CNPJ, documento com 14 dígitos): o `.pfx` precisa estar em
`dpc-login\certificados` **e** importado em `Cert:\CurrentUser\My`:

```powershell
Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -match '<CNPJ>' }   # HasPrivateKey: True
```

Hoje há dois: `41069716000122.pfx` e `55340692000109.pfx`.

## 8. Antes das 10:00

```powershell
# testes offline do gerador (rodar em powershell.exe 5.1, que e o que existe na VM)
powershell.exe -ExecutionPolicy Bypass -File .\testa-startup-master.ps1 -Arquivo "scripts para rodar na VM\configure-vm-image.ps1"
powershell.exe -ExecutionPolicy Bypass -File .\testa-bot-supervisor.ps1
```

Conferir no log de boot de algumas VMs:

- `[CONFIG]` com `dev=false`, `HORA_ABERTURA=10:00`, `TOTAL_MACHINES=30`, `TOTAL_SLOTS=33`,
  `NIDOM=75`, `PREF_DIAS_RESERVADOS=0`. Um `[CONFIG][ALERTA]` significa `DEV=true`, que desliga os
  três aceleradores da abertura de uma vez.
- `[MANUT_SAIDA] ... (slot k/33)` em VMs diferentes: **dois `k` iguais em VMs diferentes é o
  sintoma do R5** (divisor de slot menor que o maior `instanceId`).
- `DB_CONN_MODIFIED:` em **uma VM de cada metade** — abaixo de `VMRoboDPC_15` termina em `rep1`,
  dali para cima em `rep2`.
- `[SESSAO] sobreviveu=...` aparecendo (L0/L1 medindo).

Nas 1-2 VMs de watcher: parar o `dpc-interno-rep` e subir o watcher à mão via VNC
(`cd C:\dpc\dpc-agenda-watcher && node index.js`). Confirmar `Servidor socket.io ouvindo na porta
3000` e o registro em `ws_servers`.

Subir a frota **com folga**: o portal só aceita POST com ~30 s de PHPSESSID, e quem chega maduro na
abertura é quem marca.

## 9. Depois da tentativa (antes de derrubar a frota)

```powershell
.\coletar-logs-vmss.ps1
```

VM desligada não aceita `run-command`. O coletor cria storage account + SAS write-only, empurra
`coletar-logs-na-vm.ps1` em cada instância, baixa e gera `_resumo.csv` (a coluna `Reinicios` em 0
significa que a VM atravessou o dia sem cair).

### O que olhar primeiro (a partir de 2026-09-23)

1. **A corrida com o concorrente** — `node scripts/analisa-telemetria.cjs`, seção **R3**. Ela
   imprime a faixa em que as GRUs passaram de livres a `EM USO`, isto é, quando o concorrente
   agendou. **Cruzar com os episódios de manutenção.** Se as tomadas caem dentro de uma janela em
   que a frota recebia 522, ele enxerga o portal quando nós não enxergamos — e o problema deixa de
   ser velocidade e passa a ser **caminho até o origin** (o 522 é gerado pelo POP do Cloudflare, e
   a frota inteira está em `brazilsouth`). No log da VM a linha é `[CONCORRENTE]`.
2. **`grep [CLAIM_SESSAO]`** — quantas vezes a VM claimou o dono da sessão viva (R1). A linha de
   base do dia D 2026-09-23 é **7 sessões reusadas de 27 sobreviventes**; se esse número não subir,
   o R1 não entregou.
3. **`grep [PORTAO] rep_limite`** — quantos POSTs bateram na recusa definitiva do titular (R2).
   Cada um desses, antes, custava até 4 POSTs e 5 captchas.
4. Registros que terminam em `SEM GRUS VALIDAS!` **continuam banidos do pool** — é o desfecho certo,
   e a base é recriada na importação do próximo dia D.
