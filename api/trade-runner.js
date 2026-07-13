'use strict';

const {
  parseSignalFormula,
  parseParamSeries,
  evaluateCondition,
} = require('./lib/signal-formula');

const DEFAULT_TF = 'M15';
const RUNNER_INTERVAL_MS = Number(process.env.TRADE_RUNNER_INTERVAL_MS) || 15000;

let sideOpenId = null;
let actionLongId = null;
let actionShortId = null;
let defaultTimeframeId = null;
let lookupReady = false;
let running = false;

async function ensureLookups(pool) {
  if (lookupReady) return;
  const [sides, actions, tfs] = await Promise.all([
    pool.query(`SELECT id, name FROM sides`),
    pool.query(`SELECT id, name FROM actions`),
    pool.query(`SELECT id, tf FROM timeframes WHERE is_active = TRUE ORDER BY sec`),
  ]);
  sideOpenId = sides.rows.find((r) => r.name === 'Open')?.id ?? null;
  actionLongId = actions.rows.find((r) => r.name === 'Long')?.id ?? null;
  actionShortId = actions.rows.find((r) => r.name === 'Short')?.id ?? null;
  defaultTimeframeId =
    tfs.rows.find((r) => r.tf === DEFAULT_TF)?.id ?? tfs.rows[0]?.id ?? null;
  lookupReady = Boolean(
    sideOpenId && actionLongId && actionShortId && defaultTimeframeId
  );
}

async function latestIndicatorPoint(pool, securityId, timeframeId, indicatorId, lineCode) {
  const { rows } = await pool.query(
    `
    SELECT iv.dt, iv.value, ivt.code AS line_code
    FROM indicator_values iv
    JOIN indicator_value_types ivt ON ivt.id = iv.indicator_value_type_id
    WHERE iv.security_id = $1
      AND iv.timeframe_id = $2
      AND iv.indicator_id = $3
      AND UPPER(ivt.code) = UPPER($4)
    ORDER BY iv.dt DESC
    LIMIT 1
    `,
    [securityId, timeframeId, indicatorId, lineCode]
  );
  return rows[0] ?? null;
}

async function latestClosePrice(pool, securityId, timeframeId, barDt) {
  const { rows } = await pool.query(
    `
    SELECT close_price, dt
    FROM prices
    WHERE security_id = $1 AND timeframe_id = $2 AND dt <= $3
    ORDER BY dt DESC
    LIMIT 1
    `,
    [securityId, timeframeId, barDt]
  );
  const row = rows[0];
  if (!row) return null;
  return { price: Number(row.close_price), dt: row.dt };
}

async function insertTrade(pool, payload) {
  const { rows } = await pool.query(
    `
    INSERT INTO logic_trades (
      logic_id, account_id, security_id, timeframe_id,
      side_id, action_id, signal_kind, signal_formula,
      quantity, price, bar_dt, is_simulated, is_fictitious,
      broker_order_id, status, note
    )
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
    ON CONFLICT (logic_id, security_id, signal_kind, bar_dt) DO NOTHING
    RETURNING id
    `,
    [
      payload.logic_id,
      payload.account_id,
      payload.security_id,
      payload.timeframe_id,
      payload.side_id,
      payload.action_id,
      payload.signal_kind,
      payload.signal_formula,
      payload.quantity,
      payload.price,
      payload.bar_dt,
      payload.is_simulated,
      payload.is_fictitious,
      payload.broker_order_id,
      payload.status,
      payload.note,
    ]
  );
  return rows[0]?.id ?? null;
}

async function tryRealOrder(pool, accountId, securityId, quantity, price, direction) {
  try {
    const { rows: figiRows } = await pool.query(
      `
      SELECT sp.tbank_figi, sp.prefix
      FROM security_prefixes sp
      WHERE sp.security_id = $1 AND sp.tbank_figi IS NOT NULL
      ORDER BY sp.exchange_id
      LIMIT 1
      `,
      [securityId]
    );
    const figi = figiRows[0]?.tbank_figi;
    if (!figi) {
      return { ok: false, orderId: null, note: 'Нет tbank_figi для бумаги' };
    }
    const { rows } = await pool.query(
      `SELECT tbank_post_order($1, $2, $3, $4, $5) AS resp`,
      [accountId, figi, quantity, price, direction]
    );
    const resp = rows[0]?.resp;
    const orderId =
      resp?.orderId ?? resp?.order_id ?? resp?.orderState?.orderId ?? null;
    return { ok: Boolean(orderId), orderId, note: orderId ? null : JSON.stringify(resp) };
  } catch (err) {
    return { ok: false, orderId: null, note: err.message };
  }
}

async function processLogic(pool, logic) {
  const isFake = logic.account_type === 'fake';
  const tfId = defaultTimeframeId;

  const [{ rows: signals }, { rows: securities }] = await Promise.all([
    pool.query(
      `
      SELECT lis.id, lis.signal_kind, lis.formula, lis.indicator_id, i.code AS indicator_code
      FROM logic_indicator_signals lis
      JOIN indicators i ON i.id = lis.indicator_id
      WHERE lis.logic_id = $1 AND lis.is_active = TRUE
      `,
      [logic.id]
    ),
    pool.query(
      `
      SELECT ls.security_id
      FROM logic_securities ls
      WHERE ls.logic_id = $1 AND ls.is_active = TRUE
      `,
      [logic.id]
    ),
  ]);

  if (signals.length === 0 || securities.length === 0) {
    return 0;
  }

  let created = 0;

  for (const sec of securities) {
    for (const sig of signals) {
      const parsed = parseSignalFormula(sig.formula);
      if (!parsed.valid) continue;

      const series = parseParamSeries(parsed.params);
      const point = await latestIndicatorPoint(
        pool,
        sec.security_id,
        tfId,
        sig.indicator_id,
        series
      );
      if (!point) continue;

      const valueMap = { [series]: Number(point.value), VALUE: Number(point.value) };
      if (!evaluateCondition(parsed.condition, valueMap)) continue;

      const priceRow = await latestClosePrice(pool, sec.security_id, tfId, point.dt);
      if (!priceRow || !Number.isFinite(priceRow.price) || priceRow.price <= 0) continue;

      const actionId = sig.signal_kind === 'counter' ? actionShortId : actionLongId;
      const direction = sig.signal_kind === 'counter' ? 'SELL' : 'BUY';

      let isSimulated = isFake;
      let brokerOrderId = null;
      let status = 'filled';
      let note = null;

      if (isFake) {
        isSimulated = true;
      } else {
        isSimulated = false;
        const order = await tryRealOrder(
          pool,
          logic.account_id,
          sec.security_id,
          1,
          priceRow.price,
          direction
        );
        if (order.ok) {
          brokerOrderId = order.orderId;
          status = 'submitted';
        } else {
          status = 'rejected';
          note = order.note;
        }
      }

      const tradeId = await insertTrade(pool, {
        logic_id: logic.id,
        account_id: logic.account_id,
        security_id: sec.security_id,
        timeframe_id: tfId,
        side_id: sideOpenId,
        action_id: actionId,
        signal_kind: sig.signal_kind,
        signal_formula: sig.formula,
        quantity: 1,
        price: priceRow.price,
        bar_dt: point.dt,
        is_simulated: isSimulated,
        is_fictitious: false,
        broker_order_id: brokerOrderId,
        status,
        note,
      });
      if (tradeId) created += 1;
    }
  }

  return created;
}

async function runTradeCycle(pool) {
  if (running) return { skipped: true };
  running = true;
  try {
    await ensureLookups(pool);
    if (!lookupReady) {
      return { error: 'lookups not ready' };
    }

    const { rows: logics } = await pool.query(
      `
      SELECT l.id, l.account_id, a.account_type
      FROM logics l
      JOIN accounts a ON a.id = l.account_id
      WHERE l.is_enabled = TRUE AND a.is_active = TRUE
      `
    );

    let total = 0;
    for (const logic of logics) {
      total += await processLogic(pool, logic);
    }
    return { processed: logics.length, created: total };
  } finally {
    running = false;
  }
}

function startTradeRunner(pool) {
  const enabled = process.env.TRADE_RUNNER_ENABLED !== '0';
  if (!enabled) {
    console.log('Trade runner: disabled (TRADE_RUNNER_ENABLED=0)');
    return;
  }

  console.log(
    `Trade runner: every ${RUNNER_INTERVAL_MS}ms (tf=${DEFAULT_TF})`
  );

  setTimeout(() => {
    runTradeCycle(pool).catch((err) => {
      console.error('Trade runner cycle error', err);
    });
  }, 3000);

  setInterval(() => {
    runTradeCycle(pool).catch((err) => {
      console.error('Trade runner cycle error', err);
    });
  }, RUNNER_INTERVAL_MS);
}

module.exports = {
  runTradeCycle,
  startTradeRunner,
};
