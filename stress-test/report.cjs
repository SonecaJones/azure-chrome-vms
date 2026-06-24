/**
 * S4 — Relatorio do ensaio de stress do WAF.
 *
 * Le a colecao watcher.stress_telemetria (gravada pelo watcher quando STRESS_TELEMETRIA=true)
 * e imprime, em ASCII puro:
 *   - taxa de challenge Cloudflare global (cloudflare / total);
 *   - quebra por REGIAO e por IP (chave do teste IP/ASN, I1);
 *   - taxa de session_drop e duracao media de ciclo;
 *   - resumo por cenario (use --cenario A|B ao gravar, ou filtre por janela de tempo).
 *
 * Uso (PowerShell):
 *   $env:TEST_DB_CONN = "<conn da base de teste>"
 *   node report.cjs                 # tudo
 *   node report.cjs --desde 30      # so os ultimos 30 min
 *
 * Doc esperado: { ts, container, region, ip, outcome, cfChallengeCount, durationMs }
 *   outcome in { online, cloudflare, session_drop, manutencao, outro }
 */

let mongoose;
try { mongoose = require('mongoose'); }
catch { mongoose = require(require('path').resolve(__dirname, '../../DPC AGENDA/dpc-agenda-watcher/node_modules/mongoose')); }

const TEST = process.env.TEST_DB_CONN;
const argDesde = (() => {
  const i = process.argv.indexOf('--desde');
  return (i >= 0 && process.argv[i + 1]) ? Number(process.argv[i + 1]) : 0;
})();

function pct(n, d) { return d > 0 ? ((100 * n / d).toFixed(1) + '%') : '-'; }
function pad(s, w) { s = String(s); return s.length >= w ? s.slice(0, w) : s + ' '.repeat(w - s.length); }

function tabela(titulo, linhas, cols) {
  console.log('\n# ' + titulo);
  console.log('-'.repeat(cols.reduce((a, c) => a + c.w + 2, 0)));
  console.log(cols.map(c => pad(c.t, c.w)).join('  '));
  console.log('-'.repeat(cols.reduce((a, c) => a + c.w + 2, 0)));
  for (const l of linhas) console.log(cols.map(c => pad(l[c.k], c.w)).join('  '));
}

function agrega(docs) {
  const total = docs.length;
  const cloudflare = docs.filter(d => d.outcome === 'cloudflare').length;
  const sessionDrop = docs.filter(d => d.outcome === 'session_drop').length;
  const online = docs.filter(d => d.outcome === 'online').length;
  const outros = total - cloudflare - sessionDrop - online;
  const durMedia = total ? Math.round(docs.reduce((a, d) => a + (d.durationMs || 0), 0) / total) : 0;
  return { total, cloudflare, sessionDrop, online, outros, durMedia };
}

function linhaResumo(nome, a) {
  return {
    grupo: nome, total: a.total,
    challenge: `${a.cloudflare} (${pct(a.cloudflare, a.total)})`,
    drop: `${a.sessionDrop} (${pct(a.sessionDrop, a.total)})`,
    online: a.online, durMs: a.durMedia
  };
}

(async () => {
  if (!TEST) { console.error('[report] defina TEST_DB_CONN.'); process.exit(1); }
  const conn = await mongoose.createConnection(TEST).asPromise();
  const col = conn.collection('stress_telemetria');

  const filtro = argDesde > 0 ? { ts: { $gte: new Date(Date.now() - argDesde * 60 * 1000) } } : {};
  const docs = await col.find(filtro).toArray();
  if (docs.length === 0) { console.log('[report] sem telemetria (STRESS_TELEMETRIA estava on? base certa?).'); process.exit(0); }

  const janela = `${new Date(Math.min(...docs.map(d => +new Date(d.ts)))).toISOString()} -> ${new Date(Math.max(...docs.map(d => +new Date(d.ts)))).toISOString()}`;
  console.log('===== RELATORIO STRESS WAF =====');
  console.log(`Ciclos: ${docs.length}  |  Janela: ${janela}`);

  const g = agrega(docs);
  tabela('GLOBAL', [linhaResumo('TODOS', g)], [
    { t: 'GRUPO', k: 'grupo', w: 16 }, { t: 'CICLOS', k: 'total', w: 8 },
    { t: 'CHALLENGE CF', k: 'challenge', w: 16 }, { t: 'SESSION_DROP', k: 'drop', w: 16 },
    { t: 'ONLINE', k: 'online', w: 8 }, { t: 'DUR.MED(ms)', k: 'durMs', w: 12 }
  ]);

  const porRegiao = {};
  for (const d of docs) (porRegiao[d.region || '?'] ||= []).push(d);
  tabela('POR REGIAO (capacidade IP/ASN - I1)', Object.entries(porRegiao)
    .map(([r, ds]) => linhaResumo(r, agrega(ds)))
    .sort((a, b) => b.total - a.total), [
    { t: 'REGIAO', k: 'grupo', w: 16 }, { t: 'CICLOS', k: 'total', w: 8 },
    { t: 'CHALLENGE CF', k: 'challenge', w: 16 }, { t: 'SESSION_DROP', k: 'drop', w: 16 },
    { t: 'ONLINE', k: 'online', w: 8 }, { t: 'DUR.MED(ms)', k: 'durMs', w: 12 }
  ]);

  const porIp = {};
  for (const d of docs) (porIp[d.ip || '(sem ip)'] ||= []).push(d);
  tabela('POR IP (top 25 por challenge)', Object.entries(porIp)
    .map(([ip, ds]) => linhaResumo(ip, agrega(ds)))
    .sort((a, b) => b.total - a.total).slice(0, 25), [
    { t: 'IP', k: 'grupo', w: 18 }, { t: 'CICLOS', k: 'total', w: 8 },
    { t: 'CHALLENGE CF', k: 'challenge', w: 16 }, { t: 'SESSION_DROP', k: 'drop', w: 16 },
    { t: 'ONLINE', k: 'online', w: 8 }, { t: 'DUR.MED(ms)', k: 'durMs', w: 12 }
  ]);

  console.log('\n# LEITURA');
  console.log(`- Taxa de challenge CF global: ${pct(g.cloudflare, g.total)} (${g.cloudflare}/${g.total} ciclos).`);
  console.log(`- IPs distintos: ${Object.keys(porIp).length}  |  Regioes: ${Object.keys(porRegiao).length}`);
  console.log('- Compare a taxa de challenge entre Cenario A (1 regiao) e B (3 regioes) rodando');
  console.log('  o report com --desde apos cada cenario (ou separe por janela de tempo).');

  await conn.close();
  process.exit(0);
})().catch(e => { console.error('[report] ERRO: ' + e.message); process.exit(1); });
