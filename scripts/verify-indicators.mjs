#!/usr/bin/env node
/**
 * Smoke-тесты индикаторов и security_indicator_series на verify-БД.
 * Запускается после verify-sql.mjs (та же БД multilogictrade_verify).
 *
 *   node scripts/verify-indicators.mjs
 *   SKIP_INDICATOR_VERIFY=1 npm run build
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const verifyDb = process.env.SQL_VERIFY_DB || 'multilogictrade_verify';

if (process.env.SKIP_INDICATOR_VERIFY === '1') {
  console.log('verify-indicators: SKIP_INDICATOR_VERIFY=1 — пропуск');
  process.exit(0);
}

const pgBinCandidates = [
  process.env.PG_BIN,
  'C:/Program Files/PostgreSQL/15/bin',
  'C:/Program Files/PostgreSQL/16/bin',
  '/usr/lib/postgresql/15/bin',
  '/usr/bin',
].filter(Boolean);

function findPsql() {
  for (const dir of pgBinCandidates) {
    const exe = path.join(dir, process.platform === 'win32' ? 'psql.exe' : 'psql');
    if (fs.existsSync(exe)) return exe;
  }
  return null;
}

function runPsql(psql, sql, { database = verifyDb, timeoutMs = 30_000 } = {}) {
  const env = { ...process.env, PGCLIENTENCODING: 'UTF8' };
  const result = spawnSync(
    psql,
    [
      '-h',
      process.env.PGHOST || 'localhost',
      '-p',
      process.env.PGPORT || '5432',
      '-U',
      process.env.PGUSER || 'postgres',
      '-d',
      database,
      '-v',
      'ON_ERROR_STOP=1',
      '-t',
      '-A',
      '-c',
      sql,
    ],
    { encoding: 'utf8', env, timeout: timeoutMs }
  );
  if (result.status !== 0) {
    if (result.stdout) process.stdout.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    throw new Error(`psql failed (${result.status}): ${sql.slice(0, 80)}…`);
  }
  return (result.stdout || '').trim();
}

function assertEq(label, actual, expected) {
  const a = String(actual).trim();
  const e = String(expected);
  if (a !== e) {
    console.error(`verify-indicators: FAIL ${label}: expected ${e}, got ${a}`);
    process.exit(1);
  }
  console.log(`verify-indicators: OK ${label}`);
}

function assertGte(label, actual, min) {
  const n = Number(actual);
  if (!Number.isFinite(n) || n < min) {
    console.error(`verify-indicators: FAIL ${label}: expected >= ${min}, got ${actual}`);
    process.exit(1);
  }
  console.log(`verify-indicators: OK ${label} (${n})`);
}

const psql = findPsql();
if (!psql) {
  console.error('verify-indicators: psql не найден');
  process.exit(1);
}

console.log(`verify-indicators: БД ${verifyDb}`);

try {
  // Seed: SBER + STOCH K/D
  assertGte(
    'SBER STOCH seed series',
    runPsql(
      psql,
      `SELECT COUNT(*)::text FROM security_indicator_series sis
       JOIN securities s ON s.id = sis.security_id
       JOIN security_prefixes sp ON sp.security_id = s.id AND sp.prefix = 'SBER'
       JOIN indicators i ON i.id = sis.indicator_id AND i.code = 'STOCH'`
    ),
    2
  );

  const sberId = runPsql(
    psql,
    `SELECT s.id::text FROM securities s
     JOIN security_prefixes sp ON sp.security_id = s.id AND sp.prefix = 'SBER' LIMIT 1`
  );
  const m15Id = runPsql(psql, `SELECT id::text FROM timeframes WHERE tf = 'M15' LIMIT 1`);

  assertEq(
    'no prices for SBER before test',
    runPsql(
      psql,
      `SELECT COUNT(*)::text FROM prices WHERE security_id = ${sberId} AND timeframe_id = ${m15Id}`
    ),
    '0'
  );

  // sync без цен — быстрый выход, без записей
  const t0 = Date.now();
  runPsql(
    psql,
    `CALL sync_security_indicator_series_all(${sberId}, ${m15Id}, NULL, NULL, TRUE)`
  );
  const elapsed = Date.now() - t0;
  if (elapsed > 5000) {
    console.error(`verify-indicators: FAIL sync without prices too slow: ${elapsed}ms`);
    process.exit(1);
  }
  console.log(`verify-indicators: OK sync without prices (${elapsed}ms)`);

  assertEq(
    'no indicator_values after sync without prices',
    runPsql(
      psql,
      `SELECT COUNT(*)::text FROM indicator_values WHERE security_id = ${sberId} AND timeframe_id = ${m15Id}`
    ),
    '0'
  );

  assertEq(
    'calc_ind_stoch_array empty without prices',
    runPsql(
      psql,
      `SELECT COUNT(*)::text FROM calc_ind_stoch_array(
         14, 3, 3, 'K', ${sberId}, ${m15Id}, 100, NULL
       )`
    ),
    '0'
  );

  const rsiId = runPsql(psql, `SELECT id::text FROM indicators WHERE code = 'RSI' LIMIT 1`);
  runPsql(psql, `CALL ensure_security_indicator_series(${sberId}, ${rsiId})`);
  assertGte(
    'ensure_security_indicator_series RSI',
    runPsql(
      psql,
      `SELECT COUNT(*)::text FROM security_indicator_series
       WHERE security_id = ${sberId} AND indicator_id = ${rsiId}`
    ),
    1
  );

  // Синтетические свечи → sync должен записать значения STOCH
  runPsql(
    psql,
    `INSERT INTO prices (security_id, timeframe_id, dt, open_price, high_price, low_price, close_price, volume)
     SELECT ${sberId}, ${m15Id},
            ts,
            250 + (n * 0.01),
            251 + (n * 0.01),
            249 + (n * 0.01),
            250.5 + (n * 0.01),
            1000
     FROM generate_series(
       1, 40
     ) AS n
     CROSS JOIN LATERAL (
       SELECT ('2026-01-02 10:00:00'::timestamp + (n - 1) * interval '15 minutes') AS ts
     ) t
     ON CONFLICT (security_id, timeframe_id, dt) DO NOTHING`
  );

  runPsql(
    psql,
    `CALL sync_security_indicator_series_all(${sberId}, ${m15Id}, NULL, 30, FALSE)`
  );

  assertGte(
    'indicator_values after sync with prices',
    runPsql(
      psql,
      `SELECT COUNT(*)::text FROM indicator_values iv
       JOIN indicators i ON i.id = iv.indicator_id AND i.code = 'STOCH'
       WHERE iv.security_id = ${sberId} AND iv.timeframe_id = ${m15Id}`
    ),
    1
  );

  // PACC: многочленная формула pp * (1;-2;1)
  const paccId = runPsql(psql, `SELECT id::text FROM indicators WHERE code = 'PACC' LIMIT 1`);
  runPsql(psql, `CALL ensure_security_indicator_series(${sberId}, ${paccId})`);

  const paccSeriesId = runPsql(
    psql,
    `SELECT id::text FROM security_indicator_series
     WHERE security_id = ${sberId} AND indicator_id = ${paccId} LIMIT 1`
  );

  assertEq(
    'PACC invoke_formula is polynomial',
    runPsql(
      psql,
      `SELECT CASE WHEN poly_is_formula(invoke_formula) THEN 1 ELSE 0 END::text
       FROM security_indicator_series
       WHERE security_id = ${sberId} AND indicator_id = ${paccId} LIMIT 1`
    ),
    '1'
  );

  runPsql(
    psql,
    `CALL sync_security_indicator_series(${paccSeriesId}, ${m15Id}, NULL, 20, FALSE)`
  );

  assertGte(
    'PACC indicator_values after sync',
    runPsql(
      psql,
      `SELECT COUNT(*)::text FROM indicator_values iv
       WHERE iv.security_id = ${sberId} AND iv.timeframe_id = ${m15Id}
         AND iv.indicator_id = ${paccId}`
    ),
    1
  );

  // SMAT3: sma(sma(sma(pp))) через единый парсер
  const smat3Id = runPsql(psql, `SELECT id::text FROM indicators WHERE code = 'SMAT3' LIMIT 1`);
  assertEq(
    'SMAT3 formula set',
    runPsql(psql, `SELECT btrim(formula) FROM indicators WHERE code = 'SMAT3'`),
    'sma(sma(sma(pp)))'
  );
  assertEq(
    'SMAT3 is_custom',
    runPsql(
      psql,
      `SELECT CASE WHEN is_custom THEN 1 ELSE 0 END::text FROM indicators WHERE code = 'SMAT3'`
    ),
    '1'
  );
  assertGte(
    'calc_poly SMAT3 on synthetic prices',
    runPsql(
      psql,
      `SELECT COUNT(*)::text FROM calc_poly_formula_array(
         'sma(sma(sma(pp)))', 'VALUE', ${sberId}, ${m15Id}, 15, NULL, 20, NULL, NULL, NULL, NULL, NULL, NULL, NULL
       )`
    ),
    1
  );

  // Линейный ряд close → вторая разность ≈ 0
  const paccLast = runPsql(
    psql,
    `SELECT ABS(value)::text FROM indicator_values
     WHERE security_id = ${sberId} AND timeframe_id = ${m15Id} AND indicator_id = ${paccId}
     ORDER BY dt DESC LIMIT 1`
  );
  if (Number(paccLast) > 0.001) {
    console.error(`verify-indicators: FAIL PACC linear close accel: expected ~0, got ${paccLast}`);
    process.exit(1);
  }
  console.log('verify-indicators: OK PACC linear close accel ~0');

  console.log('\nverify-indicators: OK — индикаторы и серии работают');
} catch (err) {
  console.error('verify-indicators:', err.message);
  process.exit(1);
}
