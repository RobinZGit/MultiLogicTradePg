'use strict';

const { getTradingParams } = require('./lib/logic-params');
const { writeTechLogEvent } = require('./lib/tech-log');

/** In-memory jobs: logicId → status (фон, не блокирует бой). */
const jobs = new Map();

function idleJob(logicId) {
  return {
    logic_id: logicId,
    status: 'idle',
    progress_pct: 0,
    phase_message: '',
    bars_total: 0,
    bars_done: 0,
    lookback_days: 7,
    error: null,
    started_at: null,
    finished_at: null,
  };
}

function getRatingPrecalcStatus(logicId) {
  return jobs.get(logicId) || idleJob(logicId);
}

function patchJob(logicId, patch) {
  const cur = jobs.get(logicId) || idleJob(logicId);
  const next = { ...cur, ...patch, logic_id: logicId };
  jobs.set(logicId, next);
  return next;
}

async function startRatingPrecalc(pool, logicId) {
  const cur = jobs.get(logicId);
  if (cur && (cur.status === 'pending' || cur.status === 'running')) {
    return cur;
  }

  const job = patchJob(logicId, {
    status: 'pending',
    progress_pct: 0,
    phase_message: 'Ожидание предрасчёта',
    bars_total: 0,
    bars_done: 0,
    lookback_days: 7,
    error: null,
    started_at: new Date().toISOString(),
    finished_at: null,
  });

  setImmediate(() => {
    runRatingPrecalc(pool, logicId).catch((err) => {
      console.error('rating precalc', logicId, err);
      patchJob(logicId, {
        status: 'failed',
        progress_pct: 100,
        phase_message: 'Ошибка предрасчёта',
        error: err.message || String(err),
        finished_at: new Date().toISOString(),
      });
    });
  });

  return job;
}

async function runRatingPrecalc(pool, logicId) {
  patchJob(logicId, {
    status: 'running',
    progress_pct: 1,
    phase_message: 'Сброс боевого рейтинга',
  });

  const trading = await getTradingParams(pool, logicId);
  let lookback = Number(trading.rating_lookback_days);
  if (!Number.isFinite(lookback)) lookback = 7;
  lookback = Math.max(1, Math.min(90, Math.round(lookback)));

  const { rows: tfRows } = await pool.query(
    `SELECT logic_resolve_timeframe_id($1) AS tf_id`,
    [logicId]
  );
  const tfId = tfRows[0]?.tf_id;
  if (!tfId) {
    patchJob(logicId, {
      status: 'failed',
      progress_pct: 100,
      phase_message: 'Нет таймфрейма логики',
      error: 'logic_resolve_timeframe_id returned null',
      lookback_days: lookback,
      finished_at: new Date().toISOString(),
    });
    return;
  }

  patchJob(logicId, {
    lookback_days: lookback,
    phase_message: `Предрасчёт за ${lookback} дн.`,
    progress_pct: 3,
  });

  await pool.query(`SELECT logic_signal_rating_reset_live($1)`, [logicId]);

  const { rows: barRows } = await pool.query(
    `
    SELECT DISTINCT p.dt AS bar_dt
    FROM prices p
    JOIN logic_securities ls
      ON ls.security_id = p.security_id
     AND ls.logic_id = $1
     AND ls.is_active = TRUE
    WHERE p.timeframe_id = $2
      AND p.dt >= (CURRENT_TIMESTAMP - ($3::text || ' days')::interval)
      AND p.dt < CURRENT_TIMESTAMP
    ORDER BY p.dt
    `,
    [logicId, tfId, lookback]
  );

  const bars = barRows.map((r) => r.bar_dt);
  const total = bars.length;
  patchJob(logicId, {
    bars_total: total,
    bars_done: 0,
    progress_pct: total === 0 ? 100 : 5,
    phase_message:
      total === 0
        ? 'Нет свечей в окне предрасчёта'
        : `Свечи: 0 / ${total}`,
  });

  if (total === 0) {
    patchJob(logicId, {
      status: 'done',
      finished_at: new Date().toISOString(),
    });
    try {
      await writeTechLogEvent(pool, {
        threadKey: `logic:${logicId}:rating-precalc`,
        operation: 'logic.rating_precalc.empty',
        message: 'Предрасчёт боевых рейтингов: нет свечей',
        source: 'api',
        logicId,
        payload: { lookback_days: lookback },
      });
    } catch (_e) {
      /* optional */
    }
    return;
  }

  for (let i = 0; i < bars.length; i += 1) {
    await pool.query(`SELECT logic_signal_rate_bar($1, $2, $3, FALSE, NULL)`, [
      logicId,
      tfId,
      bars[i],
    ]);

    if (i === bars.length - 1 || i % 15 === 0) {
      const done = i + 1;
      const pct = Math.min(99, 5 + Math.round((done / total) * 94));
      patchJob(logicId, {
        bars_done: done,
        progress_pct: pct,
        phase_message: `Свечи: ${done} / ${total}`,
      });
    }
  }

  // Досчитать pending, у которых уже есть следующая свеча
  await pool.query(
    `SELECT logic_signal_rating_resolve_pending($1, $2, NULL, FALSE, NULL)`,
    [logicId, tfId]
  );

  patchJob(logicId, {
    status: 'done',
    bars_done: total,
    progress_pct: 100,
    phase_message: `Готово: ${total} свечей`,
    finished_at: new Date().toISOString(),
    error: null,
  });

  try {
    await writeTechLogEvent(pool, {
      threadKey: `logic:${logicId}:rating-precalc`,
      operation: 'logic.rating_precalc.done',
      message: 'Предрасчёт боевых рейтингов завершён',
      source: 'api',
      logicId,
      payload: { lookback_days: lookback, bars: total },
    });
  } catch (_e) {
    /* optional */
  }
}

module.exports = {
  startRatingPrecalc,
  getRatingPrecalcStatus,
};
