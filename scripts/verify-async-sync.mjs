#!/usr/bin/env node
/**
 * Регрессия: POST /sync с async:true не должен ждать расчёта в HTTP-ответе.
 * Запуск: node scripts/verify-async-sync.mjs (нужен API на API_URL, БД с ценами SBER).
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const apiUrl = (process.env.API_URL || 'http://localhost:3000/api').replace(/\/$/, '');

if (process.env.SKIP_ASYNC_SYNC_VERIFY === '1') {
  console.log('verify-async-sync: SKIP_ASYNC_SYNC_VERIFY=1 — пропуск');
  process.exit(0);
}

function assertSourceHasAsyncSyncRoute() {
  const serverPath = path.join(root, 'api', 'server.js');
  const src = fs.readFileSync(serverPath, 'utf8');
  if (!src.includes("req.body?.async === true")) {
    console.error('verify-async-sync: FAIL server.js must support async sync flag');
    process.exit(1);
  }
  if (!src.includes('runIndicatorSyncBackground')) {
    console.error('verify-async-sync: FAIL server.js missing runIndicatorSyncBackground');
    process.exit(1);
  }
  const panelPath = path.join(
    root,
    'web',
    'src',
    'app',
    'securities-panel',
    'securities-panel.component.ts'
  );
  const panel = fs.readFileSync(panelPath, 'utf8');
  if (!panel.includes('async: true')) {
    console.error('verify-async-sync: FAIL panel must pass async: true to sync');
    process.exit(1);
  }
  if (panel.includes('.syncIndicatorSeries({') && panel.match(/syncIndicatorSeries\(\{[^}]*\}\)[\s\S]*?async:\s*true/g)?.length === 0) {
    // runAsyncIndicatorSync centralizes async:true
    if (!panel.includes('runAsyncIndicatorSync')) {
      console.error('verify-async-sync: FAIL panel missing runAsyncIndicatorSync helper');
      process.exit(1);
    }
  }
  console.log('verify-async-sync: OK source uses async indicator sync');
}

async function probeLiveApi() {
  try {
    const health = await fetch(`${apiUrl}/health`, { signal: AbortSignal.timeout(3000) });
    if (!health.ok) return false;
  } catch {
    console.log('verify-async-sync: API offline — только проверка исходников');
    return false;
  }

  const secRes = await fetch(`${apiUrl}/securities?exchange_id=1&kind=stock`);
  if (!secRes.ok) throw new Error(`securities ${secRes.status}`);
  const securities = await secRes.json();
  const sber = securities.find((s) => s.prefix === 'SBER' || s.name === 'SBER');
  if (!sber) {
    console.log('verify-async-sync: SBER not found — skip live probe');
    return true;
  }

  const tfRes = await fetch(`${apiUrl}/timeframes`);
  const tfs = await tfRes.json();
  const m15 = tfs.find((t) => t.tf === 'M15');
  if (!m15) throw new Error('M15 timeframe missing');

  const t0 = Date.now();
  const syncRes = await fetch(`${apiUrl}/security-indicator-series/sync`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      security_id: sber.id,
      timeframe_id: m15.id,
      point_count: 15,
      incremental: true,
      async: true,
    }),
    signal: AbortSignal.timeout(10_000),
  });
  const elapsed = Date.now() - t0;
  const body = await syncRes.json().catch(() => ({}));

  if (syncRes.status !== 202) {
    console.error(`verify-async-sync: FAIL expected 202, got ${syncRes.status}`, body);
    process.exit(1);
  }
  if (elapsed > 8000) {
    console.error(`verify-async-sync: FAIL async sync took ${elapsed}ms (blocking)`);
    process.exit(1);
  }
  console.log(`verify-async-sync: OK live POST async sync in ${elapsed}ms`);
  return true;
}

assertSourceHasAsyncSyncRoute();
await probeLiveApi();
console.log('verify-async-sync: OK');
