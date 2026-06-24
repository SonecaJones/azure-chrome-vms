# Roteiro - Teste de stress do WAF Cloudflare (simulacao do dia D)

Ensaio reproduzivel que mede como o Cloudflare reage ao VOLUME de varias VMs batendo juntas no
portal da Marinha, e se distribuir por regioes (I1) reduz a taxa de challenge. Usa o
`dpc-agenda-watcher` (que SO acessa o site, nunca agenda) e forca a queda de PHPSESSID de forma
sistematica. Tudo aditivo e OFF por default - o codigo de producao nao muda quando as flags
nao estao setadas.

## O que mede
- **Taxa de challenge Cloudflare** sob volume (ciclos `cloudflare` / total).
- **Capacidade de IP/ASN (I1)**: challenge por regiao e por IP; concentrado (1 regiao) vs
  distribuido (3 regioes), com o mesmo total de VMs.

## Pecas
| Arquivo | Papel |
|---|---|
| `seed-pool.cjs` | Copia N registros reais (cookiesGov+UA frescos) de PROD -> base de TESTE |
| `startup-watcher-stress.ps1` | Roda DENTRO da VM: sobe o watcher apontando pra base de teste |
| `report.cjs` | Le `watcher.stress_telemetria` e imprime taxa de challenge por regiao/IP |
| `teardown.ps1` | Scale 0 / delete das VMSS de teste |
| `.env.stress.example` | Template do .env do watcher em modo stress |

## Flags novas (watcher) - defaults de PRODUCAO sao OFF
| Env | Default (prod) | No ensaio | Efeito |
|---|---|---|---|
| `SIMULA_SESSION_DROP_INTERVALO_MS` | `0` (off) | `15000` | A cada N ms dropa a PHPSESSID -> session_drop real. cookiesGov preservado. |
| `STRESS_TELEMETRIA` | `false` | `true` | Grava 1 doc/ciclo em `watcher.stress_telemetria`. |

---

## Pre-requisitos
- `DB_CONN` de uma **base de teste** separada (lake free / Mongo dedicado). NUNCA producao.
- Sessoes GOV frescas no pool de teste (cookiesGov valido ~45 min) - rode o seed pouco antes.
- `az login` e a subscription certa.
- **Folga ate o proximo dia D real**: 20+ VMs no mesmo ASN Azure podem influenciar a reputacao
  vista pelo Cloudflare. Rode o ensaio com VMSS NOVAS (IPs frescos) e bem antes da abertura.
- A imagem/VM de teste precisa conter o `dpc-agenda-watcher` (ex.: `C:\dpc\dpc-agenda-watcher`)
  e o Chrome (porta 9222), igual a imagem de producao.

---

## Passo 1 - Seed do pool de teste
```powershell
cd "C:\Dev\free\DPC\azure-chrome-vms\stress-test"
$env:PROD_DB_CONN = "<conn de producao (somente leitura)>"
$env:TEST_DB_CONN = "<conn da base de teste>"
$env:N = "24"            # >= numero de VMs do ensaio
$env:MAX_AGE_MIN = "40"  # idade max do cookiesGov
node seed-pool.cjs
```
Se aparecer "so X sessoes frescas", as VMs vao compartilhar cookiesGov/UA - ok para teste de
volume/ASN; **anote no relatorio**.

> Janela do ensaio < ~40 min (TTL do cookiesGov). Para estender, aponte uma instancia do
> `dpc-login-gov` para a base de teste e deixe renovando.

---

## Passo 2 - Cenario A (CONCENTRADO: 1 regiao x 24)
```powershell
cd "C:\Dev\free\DPC\azure-chrome-vms"
./create-multiregion-vmss.ps1 -Regioes @("brazilsouth") -InstanceCountPorRegiao 24
```
Quando as VMs subirem, aplique o modo stress em cada instancia:
```powershell
cd "C:\Dev\free\DPC\azure-chrome-vms\stress-test"
$rg="dpcrobos"; $vmss="VMSSRoboDPC-brazilsouth"
az vmss list-instances -g $rg -n $vmss --query "[].instanceId" -o tsv | ForEach-Object {
  az vmss run-command invoke -g $rg -n $vmss --instance-id $_ `
    --command-id RunPowerShellScript --scripts "@startup-watcher-stress.ps1" `
    --parameters DbConn="<TEST_DB_CONN>" TotalMachines=24 DropMs=15000
}
```
Deixe coletar **~20-30 min**. Depois:
```powershell
$env:TEST_DB_CONN = "<conn da base de teste>"
node report.cjs --desde 30
./teardown.ps1 -Regioes @("brazilsouth") -Delete
```
Guarde a saida do report (e a janela de horario) como "Cenario A".

---

## Passo 3 - Cenario B (DISTRIBUIDO: 3 regioes x 8 = 24)
```powershell
cd "C:\Dev\free\DPC\azure-chrome-vms"
./create-multiregion-vmss.ps1 -Regioes @("brazilsouth","eastus2","westus3") -InstanceCountPorRegiao 8
```
Aplique o stress em cada VMSS (repita o loop do Passo 2 trocando `$vmss` para
`VMSSRoboDPC-eastus2` e `VMSSRoboDPC-westus3`). Colete ~20-30 min e:
```powershell
node report.cjs --desde 30
./teardown.ps1 -Delete
```
Guarde como "Cenario B".

---

## Passo 4 - Leitura dos resultados
- **Taxa de challenge global** (linha GLOBAL do report): quao agressivo o WAF foi sob volume.
- **POR REGIAO / POR IP**: a tese do I1 se confirma se o **Cenario B (distribuido) tiver taxa de
  challenge menor** que o A (concentrado) com o mesmo total de VMs.
- **SESSION_DROP**: confirma que o drop sistematico funcionou e que o jitter de reentrada nao
  derrubou tudo junto. `DUR.MED(ms)` alto sugere timeouts (a Marinha derruba sessao sob carga -
  ver "Invariante critica" no CLAUDE.md).

---

## Teardown e checklist de limpeza
- `./teardown.ps1 -Delete` em TODAS as regioes usadas.
- `az vmss list -g dpcrobos -o table` -> confirmar que nao sobrou VMSS de teste.
- Confirmar custo de compute zerado (Spot, mas ainda assim).
- Opcional: limpar `watcher.stress_telemetria` na base de teste.

---

## Riscos e criterios de abortar
- **ABORTAR** se a taxa de challenge ficar ~100% em AMBOS os cenarios logo no inicio: o ASN
  provavelmente ja esta marcado; nao insistir (e nao repetir perto do dia D).
- **NUNCA** apontar `DB_CONN`/`PROD_DB_CONN==TEST_DB_CONN` para producao - o `seed-pool.cjs`
  aborta se forem iguais, mas confira manualmente.
- Manter a janela curta e os bots de producao (dpc-interno-rep) DESLIGADOS durante o ensaio.
