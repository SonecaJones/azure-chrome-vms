/**
 * S0 — Seed do pool de teste para o ensaio de stress do WAF (dia D).
 *
 * Copia N registros REAIS com cookiesGov+UA frescos do Mongo de PRODUCAO para o Mongo de TESTE,
 * zerando o estado de claim (on/tent/claimedAt/erro/log/resultado). O ensaio roda SOMENTE contra
 * a base de teste — producao e apenas LEITURA aqui.
 *
 * Uso (PowerShell):
 *   $env:PROD_DB_CONN = "<conn de producao>"     # origem (somente leitura)
 *   $env:TEST_DB_CONN = "<conn da base de teste>" # destino
 *   $env:N = "30"                                  # quantos registros (>= numero de VMs)
 *   $env:MAX_AGE_MIN = "40"                        # idade max do cookiesGov (TTL ~45min)
 *   node seed-pool.cjs
 *
 * Colecao: 'watchers' (model mongoose 'Watcher' -> colecao pluralizada) na base default da conn.
 */

let mongoose;
try { mongoose = require('mongoose'); }
catch { mongoose = require(require('path').resolve(__dirname, '../../DPC AGENDA/dpc-agenda-watcher/node_modules/mongoose')); }

const PROD = process.env.PROD_DB_CONN;
const TEST = process.env.TEST_DB_CONN;
const N = Number(process.env.N) || 30;
const MAX_AGE_MIN = Number(process.env.MAX_AGE_MIN) || 40;

function abort(msg) { console.error('[seed] ERRO: ' + msg); process.exit(1); }

(async () => {
  if (!PROD) abort('defina PROD_DB_CONN (origem, producao).');
  if (!TEST) abort('defina TEST_DB_CONN (destino, base de teste).');
  if (PROD === TEST) abort('PROD_DB_CONN e TEST_DB_CONN sao iguais — o ensaio NAO pode rodar contra producao.');

  const connProd = await mongoose.createConnection(PROD).asPromise();
  const connTest = await mongoose.createConnection(TEST).asPromise();
  console.log('[seed] conectado em producao (RO) e teste.');

  const colProd = connProd.collection('watchers');
  const colTest = connTest.collection('watchers');

  const limite = new Date(Date.now() - MAX_AGE_MIN * 60 * 1000);
  const candidatos = await colProd.find({
    cookiesGov: { $ne: null },
    tempoGov: { $gte: limite }
  }, {
    projection: { cpf: 1, senha: 1, cookiesGov: 1, tempoGov: 1, UA: 1, nome: 1 }
  }).limit(N).toArray();

  console.log(`[seed] ${candidatos.length} registros com cookiesGov fresco (< ${MAX_AGE_MIN}min) encontrados (alvo: ${N}).`);
  if (candidatos.length === 0) abort('nenhum registro com cookiesGov fresco — rode o login/login-gov antes do ensaio.');
  if (candidatos.length < N) {
    console.warn(`[seed] AVISO: so ${candidatos.length} sessoes frescas. As VMs vao compartilhar cookiesGov/UA (ok para teste de volume/ASN; anote no relatorio).`);
  }

  let ok = 0;
  for (const r of candidatos) {
    await colTest.updateOne(
      { cpf: r.cpf },
      { $set: {
          cpf: r.cpf, senha: r.senha, cookiesGov: r.cookiesGov, tempoGov: r.tempoGov,
          UA: r.UA, nome: r.nome || null,
          on: false, tent: 0, claimedAt: null,
          erro: [], log: [], resultado: [], agenda: false,
          cookies: null, container: null, ip: null
      } },
      { upsert: true }
    );
    ok++;
  }

  console.log(`[seed] OK — ${ok} registros gravados no pool de teste (on:false, tent:0).`);
  await connProd.close();
  await connTest.close();
  process.exit(0);
})().catch(e => abort(e.message));
