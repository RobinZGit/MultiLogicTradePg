'use strict';

const RUNNER_INTERVAL_MS = Number(process.env.TRADE_RUNNER_INTERVAL_MS) || 60000;

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
      return result;
    }
    return {
      processed: result.processed ?? 0,
      created: result.created ?? 0,
      at: result.at,
      source: 'postgresql',
    };
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
