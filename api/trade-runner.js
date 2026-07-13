'use strict';

const RUNNER_INTERVAL_MS = Number(process.env.TRADE_RUNNER_INTERVAL_MS) || 60000;
const { writeTechLogEvent } = require('./lib/tech-log');

let running = false;

/**
 * Цикл сделок выполняется в PostgreSQL: run_trade_cycle().
 * Node — fallback, если pg_cron недоступен (Windows).
 * TRADE_RUNNER_ENABLED=0 — отключить fallback.
 */
async function runTradeCycle(pool) {
  if (running) return { skipped: true, reason: 'node_busy' };
  running = true;
  try {
    const { rows } = await pool.query('SELECT run_trade_cycle() AS result');
    const result = rows[0]?.result ?? {};
    if (result.skipped) {
      await writeTechLogEvent(pool, {
        threadKey: 'trade-runner',
        operation: 'cycle.skip',
        message: `Node fallback: ${result.reason ?? 'skipped'}`,
        source: 'node',
        payload: result,
      }).catch(() => {});
      return result;
    }
    const out = {
      processed: result.processed ?? 0,
      created: result.created ?? 0,
      at: result.at,
      source: 'postgresql',
    };
    await writeTechLogEvent(pool, {
      threadKey: 'trade-runner',
      operation: 'cycle.node',
      message: `Node fallback: processed=${out.processed} created=${out.created}`,
      source: 'node',
      payload: out,
    }).catch(() => {});
    return out;
  } finally {
    running = false;
  }
}

function startTradeRunner(pool) {
  const enabled = process.env.TRADE_RUNNER_ENABLED !== '0';
  if (!enabled) {
    console.log('Trade runner fallback: disabled (TRADE_RUNNER_ENABLED=0, use pg_cron or POST /api/logic-trades/run)');
    return;
  }

  console.log(
    `Trade runner fallback: every ${RUNNER_INTERVAL_MS}ms → SELECT run_trade_cycle() (pg_cron preferred on Linux)`
  );

  setTimeout(() => {
    runTradeCycle(pool).catch((err) => {
      console.error('Trade runner cycle error', err.message);
    });
  }, 5000);

  setInterval(() => {
    runTradeCycle(pool).catch((err) => {
      console.error('Trade runner cycle error', err.message);
    });
  }, RUNNER_INTERVAL_MS);
}

module.exports = {
  runTradeCycle,
  startTradeRunner,
};
