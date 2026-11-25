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

## 2b. Véspera: validar o W1 no Azure (VM originária, ~30 min)

**Por quê.** Em 2026-10-30 ficou provado no Chrome **local** que a "queda de sessão aos ~885 s" é a liberação do
Cloudflare vencendo (403 com `cf-mitigated: challenge` ~900 s depois do desafio resolvido), não a sessão do PHP.
O W1 passou a resgatar a sessão e a renovar a liberação antes da abertura. Mas lá o desafio **se resolve sozinho,
sem clique**. Na VM do Azure o solver **clica** (B3-fast), e é isso que este teste mede: o mecanismo vale lá também,
e quanto custa?

**Pré-requisitos**
- A VM originária montada (seção 2), com o código do W1 em `C:\dpc\dpc-interno-rep` e `npm install` rodado.
- **O bot PARADO na VM** enquanto o teste roda: ele tocaria a sessão e sujaria a medição. Crie `C:\Scripts\supervisor.off` e faça Ctrl+C no bot. O Chrome da 9222 continua aberto.
- **Um Mongo de teste que a VM alcance.** O de 2026-10-30 era `127.0.0.1` na máquina local, e a VM não chega
  nele. Use uma base de teste no Atlas e grave `DB_CONN_TESTE=<uri>` no `.env` da VM. Se a URI não tiver "teste"
  no nome, o probe exige `--db-qualquer`.
- **Representante de teste logado na hora:** rode o `dpc-login` na máquina **local** (o hCaptcha só passa lá),
  gravando o `cookiesGov` nessa mesma base. Ele vale ~45 min, então rode o teste logo em seguida.

**O teste: uma rodada só cobre as duas coisas (~28 min)**

```powershell
cd C:\dpc\dpc-interno-rep
node scripts/probe-vida-sessao.mjs --rep=<cpf-de-teste> --base=rep1 [--db-qualquer] `
     --tocar=on --intervalo=20000 --max=1680000 --renova-clearance-aos=600 > C:\logs\w1-azure.txt 2>&1
```

**O que esperar, em ordem**

| Momento | Linha no log | Passa se... |
|---|---|---|
| abertura | `[DESAFIO] ultima passagem conhecida: ... (desafio resolvido na abertura)` | o solver resolveu (com clique). Anote quanto tempo levou. |
| 600 s | `[RENOVA] ... renovado=true` | **renovou** (`renovado=false restaurado=true` = falhou). Anote se houve `[CLEAN]` com clique e a duração. |
| ~1500 s (600 + ~900) | `[DESAFIO] ... 403 cf-mitigated=challenge` | o desafio vem ~900 s **depois da renovação**. Se vier ~900 s depois da abertura, a renovação não pegou. |
| logo depois | `[DESAFIO] leitura apos o resgate: viva=true` | a **mesma sessão** continua logada depois do resgate, sem login novo. |

Se as quatro linhas passarem, o W1 vale no Azure. Se só o resgate falhar ou ficar lento demais (o clique não
resolve, ou leva mais de ~20 s), considere `WAF_RESGATA_SESSAO`. Se a renovação falhar, `CF_RENOVA_PASSAGEM=false`
desliga a renovação proativa sem deploy, e o resgate reativo continua.

**No fim**
- Logout da Marinha (o mesmo do botão "Sair": navegar para `.../sisap/agendamento/server/logout.php`).
- Apague `C:\Scripts\supervisor.off`, para a imagem não sair com a vigilância desligada.
- **Copie o `C:\logs\w1-azure.txt` para o notebook antes do bake**. A imagem não precisa dele, e ele é o registro
  do resultado.
- Referência do resultado local: `dpc-interno-rep/CLAUDE.md`, seção W1 (desafios a 914-916 s, renovação 18:02:22 → desafio 18:17:37, sessão viva a 1684 s).

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

Nas 1-2 VMs de watcher: parar o `dpc-interno-rep` e subir o watcher à mão via VNC — **com
`npm run prod`, nunca `node index.js`**:

```powershell
cd C:\dpc\dpc-agenda-watcher
npm run prod
```

`npm run prod` (`scripts/roda-com-log.ps1`) redireciona stdout+stderr para
`C:\logs\node\bot-watcher-<vm>-<data>.log`, que é **onde o coletor procura** (ele varre
`bot-*.log`), abre uma janela de acompanhamento e roda o bot em foreground — o Ctrl+C continua
encerrando como sempre. `node index.js` escreve só no scrollback do `cmd` e o traço do dia se
perde (medido em 2026-09-30; ver a seção 9). O `npm start` segue existindo, sem redirecionamento:
é o que o supervisor usa.

O mesmo vale para o `dpc-interno-rep` subido à mão (`npm run prod`, que grava
`bot-rep-<vm>-<data>.log`). `npm run prod -- -SemTail` dispensa a janela de acompanhamento.

Confirmar `Servidor socket.io ouvindo na porta 3000` e o registro em `ws_servers`.

Subir a frota **com folga**: o portal só aceita POST com ~30 s de PHPSESSID, e quem chega maduro na
abertura é quem marca.

### Tirar uma VM da disputa no meio do dia D

Quando uma VM fica doente no meio da disputa — no dia D 2026-10-30 a VM2 ficou ~2,5 min presa
recebendo 522 na carga de GRU (`validargruinformada`), **segurando um registro**, enquanto outra VM
recebia 200 —, desligar o bot dela à mão é a decisão certa: ela deixa de pegar registros que uma VM
saudável pegaria. O SIGHUP/Ctrl+C libera o registro corretamente (o handler de shutdown faz o
`salvaAgendamento`). Procedimento, nesta ordem:

1. Criar a sentinela do supervisor, **antes** de matar o bot, para ele não religá-lo:
   `New-Item -ItemType File C:\Scripts\supervisor.off -Force` (ou `az vmss run-command`).
2. `Ctrl+C` na janela do bot (ou fechar a janela) — o registro é liberado no shutdown.
3. Para religar depois: apagar `C:\Scripts\supervisor.off` e subir com `npm run prod` (grava
   `bot-rep-<vm>-<data>.log`). `node index.js` à mão **não** grava log em arquivo — ver a seção 9.

Com o slice que solta o registro no 1º 522 da carga de GRU (em implementação), esse caso deve se
resolver sozinho em ~20 s. Desligar à mão continua valendo se a VM seguir doente.

## 9. Depois da tentativa (antes de derrubar a frota)

> **A coleta dos logs das VMs (`coletar-logs-vmss.ps1`) é OBRIGATÓRIA em todo dia D.** "Baixar os
> logs do dia" inclui sempre a frota, mesmo que ninguém cite as VMs. É a **única** fonte para
> verificar as melhorias feitas no período anterior ao dia D: `[WAF403]`/`[WAF_RESGATE]` (W1),
> `[HTTP5XX]` com `cf-ray` (K1), `[POLLING_52X]` (K2), tempo do solver `[CLEAN]` (Y1b),
> `[PORTAO_CAPTCHA]`, `[SESSAO_VIDA]`, `[MANUT_ONLINE]`, `[CONCORRENTE]` só existem lá. O dump do
> Mongo **não substitui** (guarda quase só os ciclos que deram certo) e o log dos containers é só do
> `dpc-login-gov`. Sem ela o dia D vira "deu X agendamentos" e nenhum slice fica provado.
> Em 2026-11-25 ela se perdeu e não há como refazer.

```powershell
.\coletar-logs-vmss.ps1          # a frota (VMSS) - OBRIGATORIA, rodar primeiro
.\coletar-logs-originaria.ps1    # a VM originaria (VMrobodpc, a que virou watcher)
.\coletar-logs-containers.ps1    # os containers do dpc-login-gov (ACI)
```

**Só derrubar a frota / o RG depois de os TRÊS coletores terminarem com `LIBERADO`** na última
linha. `NAO DERRUBE ... AINDA` lista o que falta. Em 2026-11-25 o RG foi apagado com a coleta da
frota em curso: 16 VMs tinham feito upload, o download falhou em silêncio, o container foi apagado
e os logs das 36 VMs do dia se perderam. Desde então o coletor mostra o erro do download, retenta,
compara com o que há no blob e **não apaga o container** se faltar zip (imprime o comando para
rebaixar). Teste offline: `powershell.exe -File testa-coleta-blob.ps1`.

VM **desligada (deallocated) não perdeu o log** — o disco do SO é persistente. O coletor da frota
agora não a ignora mais em silêncio: lista as desligadas no `NAO DERRUBE` com o `az vmss start` e o
comando para coletar só elas (ao religar o bot sobe sozinho no boot: coletar e desligar logo). Sai
com exit 2 sempre que não liberar. VMSS apagada é perda definitiva.

VM desligada não aceita `run-command`. O coletor cria storage account + SAS write-only, empurra
`coletar-logs-na-vm.ps1` em cada instância, baixa e gera `_resumo.csv` (a coluna `Reinicios` em 0
significa que a VM atravessou o dia sem cair). Os três são **somente leitura** e aceitam `-DryRun`.

- **A originária precisa de script próprio**: o coletor da frota só fala com VMSS
  (`az vmss run-command --instance-id`); a VM avulsa exige `az vm run-command`. O script empurrado
  para dentro dela é o MESMO `coletar-logs-na-vm.ps1`.
- **Bot subido à mão com `node index.js` não deixa log em arquivo** (medido 2026-09-30): o
  redirecionamento `>> arquivo 2>&1` é do `startup-master.ps1`/`bot-supervisor.ps1`, então o
  comando digitado na sessão gráfica escreve só no scrollback do `cmd`. A coleta volta
  `arquivos=9 upload=OK` e **sem nenhum log da data da tentativa** — o
  `coletar-logs-originaria.ps1` avisa isso no fim. **É o que o `npm run prod` da seção 8
  resolve**; se alguém subiu com `node index.js`, conferir ANTES de derrubar a frota (existe
  `C:\logs\node\*-<hoje>.log`?): depois não há recuperação, e do watcher sobra só
  `watcher.watchers.log[]` no Mongo.
- **Container não escreve log em arquivo, só stdout**, e ele se perde ao apagar o container group.
  Coletar pela API REST: `az container logs` trunca em ~2000 linhas em silêncio, e o `az rest`
  devolve o conteúdo certo mas **sai com exit 1** em log grande (daí o `Invoke-RestMethod`).
  Integridade se confere pela PRIMEIRA linha (deve ser a do `DB_CONN`), nunca pela contagem.

E o dump do Mongo, também somente leitura (a base é derrubada entre temporadas):

```powershell
cd "..\DPC REPRESENTANTE\dpc-interno-rep"
node scripts/dump-colecoes.cjs --inventario   # confere bases/contagens
node scripts/dump-colecoes.cjs --tudo         # -> logs\dump-<yyyyMMdd>\
node scripts/analisa-telemetria.cjs --dias=1 --json=logs\telemetria-dump-<yyyyMMdd>.json > logs\telemetria-analise-<yyyyMMdd>.txt
```

O arquivo de sucessos para o cliente sai do dump (sem Mongo), já conferindo os comprovantes:

```powershell
node scripts/gera-agendamentos-sucesso.cjs --pdfs="C:\Dev\free\DPC\AUXILIAR\AUXILIAR\resultados\<pasta do mes>"
# -> logs\dump-<hoje>\agendamentos-sucesso.txt ; lista os sucessos SEM pdf (cidagendamento salvo p/ reimprimir)
```

A conferência casa pelo nome inteiro (`<cpf rep>_<numero>.pdf`), não só pelo CPF: o mesmo
representante aparece em rep1 e rep2 e pode ter dois agendamentos.

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
