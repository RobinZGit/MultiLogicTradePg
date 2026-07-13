'use strict';

const { writeTechLogEvent } = require('./lib/tech-log');

async function backtestLog(pool, runId, logicId, operation, message, payload = null, securityId = null, tfId = null) {
  try {
    await pool.query(
      `SELECT logic_backtest_log($1, $2, $3, $4, $5::jsonb, $6, $7)`,
      [
        runId,
        logicId,
        operation,
        message,
        payload != null ? JSON.stringify(payload) : null,
        securityId,
        tfId,
      ]
    );
  } catch (err) {
    console.warn('backtestLog', operation, err.message);
  }
  try {
    await writeTechLogEvent(pool, {
      threadKey: `logic:${logicId}:backtest:${runId}`,
      operation,
      message,
      source: 'backtest',
      logicId,
      securityId,
      timeframeId: tfId,
      payload: { run_id: runId, ...(payload || {}) },
    });
  } catch (_err) {
    /* APP_TECH_LOGGING may be off */
  }
}

async function updateRun(pool, runId, patch) {
  const fields = [];
  const values = [runId];
  let i = 2;
  for (const [key, val] of Object.entries(patch)) {
    if (val === undefined) continue;
    fields.push(`${key} = $${i}`);
    values.push(val);
    i += 1;
  }
  if (fields.length === 0) return;
  await pool.query(
    `UPDATE logic_backtest_runs SET ${fields.join(', ')} WHERE id = $1`,
    values
  );
}

async function isCancelRequested(pool, runId) {
  const { rows } = await pool.query(
    'SELECT cancel_requested, status FROM logic_backtest_runs WHERE id = $1',
    [runId]
  );
  if (rows.length === 0) return true;
  return rows[0].cancel_requested || !['pending', 'loading_prices', 'loading_indicators', 'running'].includes(rows[0].status);
}

async function fetchActiveSecurityIds(pool, logicId) {
  const { rows } = await pool.query(
    `SELECT ls.security_id, s.name
     FROM logic_securities ls
     JOIN securities s ON s.id = ls.security_id
     WHERE ls.logic_id = $1 AND ls.is_active = TRUE
     ORDER BY ls.display_order, ls.id`,
    [logicId]
  );
  return rows;
}

async function fetchActiveIndicatorIds(pool, logicId) {
  const { rows } = await pool.query(
    `SELECT DISTINCT indicator_id FROM logic_indicator_signals
     WHERE logic_id = $1 AND is_active = TRUE`,
    [logicId]
  );
  return rows.map((r) => r.indicator_id);
}

async function pricesCached(pool, secId, tfId, warmupFrom, dateFrom, dateTo) {
  const { rows } = await pool.query(
    `SELECT backtest_prices_cached($1, $2, $3, $4, $5, 20) AS cached`,
    [secId, tfId, warmupFrom, dateFrom, dateTo]
  );
  return Boolean(rows[0]?.cached);
}

async function indicatorsCached(pool, secId, tfId, indicatorId, dateFrom, dateTo) {
  const { rows } = await pool.query(
    `SELECT backtest_indicators_cached($1, $2, $3, $4, $5) AS cached`,
    [secId, tfId, indicatorId, dateFrom, dateTo]
  );
  return Boolean(rows[0]?.cached);
}

async function fetchPriceLoadLog(pool, logicId, tfId, dateFrom, dateTo) {
  const { rows } = await pool.query(
    `SELECT pll.source, pll.records_loaded, pll.error_message, pll.date_from, pll.date_to
     FROM price_load_log pll
     JOIN logic_securities ls ON ls.security_id = pll.security_id
     WHERE ls.logic_id = $1 AND ls.is_active = TRUE
       AND pll.timeframe_id = $2
       AND pll.date_from >= $3::date - 30
       AND pll.date_to <= $4::date
     ORDER BY pll.id DESC
     LIMIT 10`,
    [logicId, tfId, dateFrom, dateTo]
  );
  return rows;
}

async function countPricesInPeriod(pool, logicId, tfId, dateFrom, dateTo) {
  const { rows } = await pool.query(
    `SELECT COUNT(*)::int AS cnt FROM prices p
     JOIN logic_securities ls ON ls.security_id = p.security_id
     WHERE ls.logic_id = $1 AND ls.is_active = TRUE
       AND p.timeframe_id = $2 AND p.dt::date BETWEEN $3 AND $4`,
    [logicId, tfId, dateFrom, dateTo]
  );
  return rows[0]?.cnt ?? 0;
}

async function countIndicatorsInPeriod(pool, logicId, tfId, dateFrom, dateTo) {
  const { rows } = await pool.query(
    `SELECT COUNT(*)::int AS cnt FROM indicator_values iv
     JOIN logic_securities ls ON ls.security_id = iv.security_id
     WHERE ls.logic_id = $1 AND ls.is_active = TRUE
       AND iv.timeframe_id = $2 AND iv.dt::date BETWEEN $3 AND $4`,
    [logicId, tfId, dateFrom, dateTo]
  );
  return rows[0]?.cnt ?? 0;
}

async function logicTimeframeSec(pool, logicId) {
  const { rows } = await pool.query(
    `SELECT t.sec FROM timeframes t
     WHERE t.id = logic_resolve_timeframe_id($1)`,
    [logicId]
  );
  return Number(rows[0]?.sec ?? 86400);
}

async function ensureTbankForBacktest(pool, runId, logicId) {
  const tfSec = await logicTimeframeSec(pool, logicId);
  if (tfSec >= 86400) return true;

  const { rows } = await pool.query(`SELECT tbank_verify_token() AS s`);
  const status = rows[0]?.s ?? {};
  if (status.valid) return true;

  await backtestLog(
    pool,
    runId,
    logicId,
    'backtest.tbank.missing',
    status.error_message ||
      'Токен T-Bank не задан или невалиден — загрузка цен через MOEX',
    { tbank_status: status }
  );
  return true;
}

/**
 * Подготовка одной бумаги: кэш цен → load_prices только при необходимости;
 * индикаторы по текущим активным сигналам логики.
 */
async function ensureSecurityData(
  pool,
  runId,
  logicId,
  secId,
  secName,
  tfId,
  loadDateFrom,
  dateFrom,
  dateTo,
  endDt,
  pointCount,
  stats
) {
  const cached = await pricesCached(pool, secId, tfId, loadDateFrom, dateFrom, dateTo);
  let pricesReloaded = false;

  if (cached) {
    stats.pricesCached += 1;
    await backtestLog(
      pool,
      runId,
      logicId,
      'backtest.prices.cached',
      `Кэш цен: ${secName || secId} (${loadDateFrom} — ${dateTo})`,
      { security_id: secId, name: secName },
      secId,
      tfId
    );
  } else {
    await backtestLog(
      pool,
      runId,
      logicId,
      'backtest.prices.load',
      `Загрузка цен: ${secName || secId} (${loadDateFrom} — ${dateTo})`,
      { security_id: secId, name: secName, date_from: loadDateFrom, date_to: dateTo },
      secId,
      tfId
    );
    try {
      await pool.query('CALL load_prices($1, $2, $3, $4)', [secId, tfId, loadDateFrom, dateTo]);
      stats.pricesLoaded += 1;
      pricesReloaded = true;
    } catch (e) {
      stats.pricesErr += 1;
      await backtestLog(
        pool,
        runId,
        logicId,
        'backtest.prices.error',
        e.message,
        { security_id: secId, name: secName },
        secId,
        tfId
      );
      return;
    }
    const okAfterLoad = await pricesCached(pool, secId, tfId, loadDateFrom, dateFrom, dateTo);
    const inPeriod = await countPricesInPeriod(pool, logicId, tfId, dateFrom, dateTo);
    await backtestLog(
      pool,
      runId,
      logicId,
      okAfterLoad ? 'backtest.prices.loaded' : 'backtest.prices.insufficient',
      okAfterLoad
        ? `Цены загружены: ${secName || secId}, в периоде ${inPeriod} свечей`
        : `Недостаточно свечей после загрузки (${inPeriod} в периоде ${dateFrom} — ${dateTo})`,
      { security_id: secId, prices_in_period: inPeriod, coverage_ok: okAfterLoad },
      secId,
      tfId
    );
    if (!okAfterLoad) {
      stats.pricesErr += 1;
      return;
    }
  }

  const indicatorIds = await fetchActiveIndicatorIds(pool, logicId);
  for (const indicatorId of indicatorIds) {
    if (
      !pricesReloaded &&
      (await indicatorsCached(pool, secId, tfId, indicatorId, dateFrom, dateTo))
    ) {
      stats.indCached += 1;
      continue;
    }
    try {
      await pool.query('CALL ensure_security_indicator_series($1, $2)', [secId, indicatorId]);
      await pool.query(
        'CALL sync_security_indicator_series_for_indicator($1, $2, $3, $4, $5, $6)',
        [secId, indicatorId, tfId, endDt, pointCount, false]
      );
      stats.indSynced += 1;
    } catch (e) {
      stats.indErr += 1;
      await backtestLog(
        pool,
        runId,
        logicId,
        'backtest.indicator.error',
        e.message,
        { security_id: secId, indicator_id: indicatorId, name: secName },
        secId,
        tfId
      );
    }
  }
}

/**
 * Читает актуальный список бумаг из logic_securities и подготавливает данные.
 * При изменении состава — логирует и подхватывает новые бумаги.
 */
async function syncActiveSecurities(
  pool,
  runId,
  logicId,
  tfId,
  loadDateFrom,
  dateFrom,
  dateTo,
  endDt,
  pointCount,
  knownIds,
  stats,
  phaseLabel
) {
  const secRows = await fetchActiveSecurityIds(pool, logicId);
  const currentIds = secRows.map((r) => r.security_id);
  const added = currentIds.filter((id) => !knownIds.has(id));
  const removed = [...knownIds].filter((id) => !currentIds.includes(id));

  if (added.length > 0 || removed.length > 0) {
    await backtestLog(pool, runId, logicId, 'backtest.config_changed', phaseLabel, {
      securities_active: currentIds,
      added,
      removed,
    });
  }

  // Начальная загрузка — все бумаги; на барах — только новые (added).
  const isInitialLoad = knownIds.size === 0;
  const rowsToPrepare = isInitialLoad
    ? secRows
    : secRows.filter((r) => added.includes(r.security_id));

  for (let i = 0; i < rowsToPrepare.length; i += 1) {
    const { security_id: secId, name: secName } = rowsToPrepare[i];
    try {
      await ensureSecurityData(
        pool,
        runId,
        logicId,
        secId,
        secName,
        tfId,
        loadDateFrom,
        dateFrom,
        dateTo,
        endDt,
        pointCount,
        stats
      );
      if (isInitialLoad && secRows.length > 0) {
        await updateRun(pool, runId, {
          progress_pct: Math.min(35, Math.round(((i + 1) / secRows.length) * 35 * 100) / 100),
          phase_detail: `Подготовка ${i + 1} / ${secRows.length}: ${secName || secId}`,
        });
      }
    } catch (e) {
      stats.pricesErr += 1;
      await backtestLog(
        pool,
        runId,
        logicId,
        'backtest.prices.error',
        e.message,
        { security_id: secId, name: secName },
        secId,
        tfId
      );
    }
  }

  knownIds.clear();
  for (const id of currentIds) knownIds.add(id);
  return secRows.length;
}

async function runBacktestAsync(pool, logicId, dateFrom, dateTo, runId) {
  const knownSecIds = new Set();
  const stats = {
    pricesLoaded: 0,
    pricesCached: 0,
    pricesErr: 0,
    indSynced: 0,
    indCached: 0,
    indErr: 0,
  };

  try {
    if (!(await ensureTbankForBacktest(pool, runId, logicId))) {
      return;
    }

    const { rows: logicRows } = await pool.query(
      `SELECT l.id, l.account_id FROM logics l WHERE l.id = $1`,
      [logicId]
    );
    if (logicRows.length === 0) {
      await updateRun(pool, runId, {
        status: 'failed',
        error_message: 'Логика не найдена',
        progress_pct: 100,
        finished_at: new Date(),
      });
      return;
    }
    const logic = logicRows[0];

    const { rows: tfRows } = await pool.query(
      `SELECT logic_resolve_timeframe_id($1) AS tf_id`,
      [logicId]
    );
    const tfId = tfRows[0]?.tf_id;
    if (!tfId) {
      await backtestLog(pool, runId, logicId, 'backtest.failed', 'Не задан timeframe', null, null, null);
      await updateRun(pool, runId, {
        status: 'failed',
        error_message: 'Не задан timeframe',
        progress_pct: 100,
        finished_at: new Date(),
      });
      return;
    }

    const { rows: balRows } = await pool.query(
      `SELECT COALESCE(get_logic_param_numeric($1, 'initial_balance', 0), 1000000)::float8 AS bal`,
      [logicId]
    );
    let balance = Number(balRows[0]?.bal ?? 1000000);

    await pool.query('DELETE FROM logic_trades WHERE logic_id = $1 AND is_test = TRUE', [logicId]);
    await pool.query('DELETE FROM logic_backtest_security_state WHERE run_id = $1', [runId]);

    const { rows: tfMetaRows } = await pool.query(
      `SELECT t.sec AS tf_sec, t.tf AS tf_name FROM timeframes t WHERE t.id = $1`,
      [tfId]
    );
    const tfSec = Number(tfMetaRows[0]?.tf_sec ?? 900);
    const tfName = tfMetaRows[0]?.tf_name ?? '?';

    const loadDateFrom = shiftDate(dateFrom, -30);
    const endDt = `${dateTo} 23:59:59`;
    const daysSpan =
      Math.ceil((Date.parse(dateTo) - Date.parse(loadDateFrom)) / 86400000) + 1;
    const pointCount = Math.max(500, Math.ceil(daysSpan * (86400 / tfSec)) + 200);

    await backtestLog(pool, runId, logicId, 'backtest.start', `Старт ${dateFrom} — ${dateTo}`, {
      date_from: dateFrom,
      date_to: dateTo,
      load_date_from: loadDateFrom,
    });

    await updateRun(pool, runId, {
      status: 'loading_prices',
      progress_pct: 0,
      phase_message: 'Подготовка данных',
      phase_detail: 'Чтение бумаг из logic_securities',
      test_balance: balance,
    });

    const secTotal = await syncActiveSecurities(
      pool,
      runId,
      logicId,
      tfId,
      loadDateFrom,
      dateFrom,
      dateTo,
      endDt,
      pointCount,
      knownSecIds,
      stats,
      'Стартовый состав бумаг'
    );

    if (secTotal === 0) {
      await updateRun(pool, runId, {
        status: 'failed',
        error_message: 'Нет активных бумаг в логике',
        progress_pct: 100,
        finished_at: new Date(),
      });
      return;
    }

    const indicatorIds = await fetchActiveIndicatorIds(pool, logicId);
    if (indicatorIds.length === 0) {
      await updateRun(pool, runId, {
        status: 'failed',
        error_message: 'Нет активных сигналов в логике',
        progress_pct: 100,
        finished_at: new Date(),
      });
      return;
    }

    await backtestLog(
      pool,
      runId,
      logicId,
      'backtest.config',
      `TF=${tfName} бумаг=${secTotal} сигналов=${indicatorIds.length}`,
      {
        tf_id: tfId,
        tf_name: tfName,
        load_date_from: loadDateFrom,
        point_count: pointCount,
        securities: secTotal,
        indicators: indicatorIds.length,
        initial_balance: balance,
        prices_loaded: stats.pricesLoaded,
        prices_cached: stats.pricesCached,
      },
      null,
      tfId
    );

    const pricesInPeriod = await countPricesInPeriod(pool, logicId, tfId, dateFrom, dateTo);
    await backtestLog(
      pool,
      runId,
      logicId,
      'backtest.prices.done',
      `Цены: load=${stats.pricesLoaded} cache=${stats.pricesCached} err=${stats.pricesErr} в периоде=${pricesInPeriod}`,
      {
        prices_loaded: stats.pricesLoaded,
        prices_cached: stats.pricesCached,
        prices_err: stats.pricesErr,
        prices_in_period: pricesInPeriod,
      },
      null,
      tfId
    );

    if (pricesInPeriod === 0) {
      const priceLog = await fetchPriceLoadLog(pool, logicId, tfId, dateFrom, dateTo);
      await backtestLog(
        pool,
        runId,
        logicId,
        'backtest.failed',
        'Нет свечей в периоде',
        { prices_in_period: 0, price_load_log: priceLog },
        null,
        tfId
      );
      await updateRun(pool, runId, {
        status: 'failed',
        progress_pct: 100,
        phase_message: 'Нет свечей',
        error_message: `Не загружены цены (ошибок: ${stats.pricesErr}). Задайте токен T-Bank для M15.`,
        finished_at: new Date(),
      });
      return;
    }

    const indInPeriod = await countIndicatorsInPeriod(pool, logicId, tfId, dateFrom, dateTo);
    await backtestLog(
      pool,
      runId,
      logicId,
      'backtest.indicators.done',
      `Индикаторы: sync=${stats.indSynced} cache=${stats.indCached} err=${stats.indErr} в периоде=${indInPeriod}`,
      {
        indicator_values_in_period: indInPeriod,
        sync_errors: stats.indErr,
        ind_synced: stats.indSynced,
        ind_cached: stats.indCached,
      },
      null,
      tfId
    );

    if (indInPeriod === 0) {
      await updateRun(pool, runId, {
        status: 'failed',
        progress_pct: 100,
        phase_message: 'Нет индикаторов',
        error_message: 'Индикаторы не рассчитаны. См. backtest.indicator.error.',
        finished_at: new Date(),
      });
      return;
    }

    const { rows: barRows } = await pool.query(
      `
      SELECT DISTINCT p.dt AS bar_dt
      FROM prices p
      JOIN logic_securities ls ON ls.security_id = p.security_id
      WHERE ls.logic_id = $1 AND ls.is_active = TRUE
        AND p.timeframe_id = $2
        AND p.dt::date BETWEEN $3 AND $4
      ORDER BY p.dt
      `,
      [logicId, tfId, dateFrom, dateTo]
    );
    const bars = barRows.map((r) => r.bar_dt);
    const totalBars = bars.length;

    await updateRun(pool, runId, {
      total_bars: totalBars,
      processed_bars: 0,
      status: 'running',
      progress_pct: 40,
      phase_message: 'Прогон по свечам',
      phase_detail: `0 / ${totalBars} баров`,
    });

    if (totalBars === 0) {
      await updateRun(pool, runId, {
        status: 'failed',
        progress_pct: 100,
        phase_message: 'Нет свечей',
        error_message: 'Нет цен в выбранном периоде',
        finished_at: new Date(),
      });
      return;
    }

    for (let bi = 0; bi < bars.length; bi += 1) {
      if (await isCancelRequested(pool, runId)) {
        await finishCancelled(pool, runId, logicId, balance, bi, totalBars);
        return;
      }

      if (bi > 0 && bi % 20 === 0) {
        await syncActiveSecurities(
          pool,
          runId,
          logicId,
          tfId,
          loadDateFrom,
          dateFrom,
          dateTo,
          endDt,
          pointCount,
          knownSecIds,
          stats,
          `Обновление на баре ${bi + 1}/${totalBars}`
        );
      }

      const barDt = bars[bi];

      const { rows: riskRows } = await pool.query(
        `SELECT logic_backtest_process_risk($1, $2, $3, $4, $5, $6::numeric) AS balance`,
        [runId, logicId, logic.account_id, tfId, barDt, balance]
      );
      balance = Number(riskRows[0]?.balance ?? balance);

      const { rows: sigRows } = await pool.query(
        `SELECT logic_backtest_process_signals($1, $2, $3, $4, $5, $6::numeric) AS balance`,
        [runId, logicId, logic.account_id, tfId, barDt, balance]
      );
      balance = Number(sigRows[0]?.balance ?? balance);

      if (bi % 3 === 0 || bi === bars.length - 1) {
        const pnl = await sumTestPnl(pool, logicId);
        const { rows: tcRows } = await pool.query(
          `SELECT trades_created FROM logic_backtest_runs WHERE id = $1`,
          [runId]
        );
        await updateRun(pool, runId, {
          progress_pct: 40 + Math.round(((bi + 1) / totalBars) * 60 * 100) / 100,
          phase_detail: `${bi + 1} / ${totalBars} баров, бумаг ${knownSecIds.size}`,
          current_bar_dt: barDt,
          processed_bars: bi + 1,
          test_balance: balance,
          financial_result: pnl,
        });
        if (bi > 0 && bi % 200 === 0) {
          await backtestLog(
            pool,
            runId,
            logicId,
            'backtest.progress',
            `Бар ${bi + 1}/${totalBars}, сделок=${tcRows[0]?.trades_created ?? 0}`,
            { processed_bars: bi + 1, total_bars: totalBars, securities: knownSecIds.size },
            null,
            tfId
          );
        }
      }
    }

    const pnl = await sumTestPnl(pool, logicId);
    const { rows: diagRows } = await pool.query(
      `SELECT logic_backtest_diagnose($1, $2, $3, $4, $5) AS d`,
      [runId, logicId, tfId, dateFrom, dateTo]
    );
    const { rows: tcFinal } = await pool.query(
      `SELECT trades_created FROM logic_backtest_runs WHERE id = $1`,
      [runId]
    );
    const tradesCreated = tcFinal[0]?.trades_created ?? 0;
    const diag = diagRows[0]?.d ?? {};

    await backtestLog(
      pool,
      runId,
      logicId,
      'backtest.complete',
      tradesCreated > 0
        ? `Завершено: ${tradesCreated} сделок, PnL=${pnl.toFixed(2)}`
        : `Завершено без сделок (баров=${totalBars}, бумаг=${knownSecIds.size})`,
      {
        ...diag,
        trades_created: tradesCreated,
        financial_result: pnl,
        total_bars: totalBars,
        prices_loaded: stats.pricesLoaded,
        prices_cached: stats.pricesCached,
      },
      null,
      tfId
    );

    await updateRun(pool, runId, {
      status: 'completed',
      progress_pct: 100,
      phase_message: tradesCreated > 0 ? 'Тестирование завершено' : 'Тест завершён — сделок нет',
      phase_detail: `${totalBars} баров, ${knownSecIds.size} бумаг, сделок: ${tradesCreated}`,
      processed_bars: totalBars,
      test_balance: balance,
      financial_result: pnl,
      finished_at: new Date(),
    });
  } catch (err) {
    await backtestLog(pool, runId, logicId, 'backtest.failed', err.message, { stack: err.stack });
    await updateRun(pool, runId, {
      status: 'failed',
      error_message: err.message,
      progress_pct: 100,
      finished_at: new Date(),
    });
  }
}

async function sumTestPnl(pool, logicId) {
  const { rows } = await pool.query(
    `SELECT COALESCE(SUM(financial_result), 0)::float8 AS pnl
     FROM logic_trades WHERE logic_id = $1 AND is_test = TRUE`,
    [logicId]
  );
  return Number(rows[0]?.pnl ?? 0);
}

async function finishCancelled(pool, runId, logicId, balance, processed, total) {
  const pnl = await sumTestPnl(pool, logicId);
  await backtestLog(pool, runId, logicId, 'backtest.cancelled', `Отменено на ${processed}/${total}`, {
    processed,
    total,
    financial_result: pnl,
  });
  await updateRun(pool, runId, {
    status: 'cancelled',
    phase_message: 'Отменено',
    phase_detail: `${processed} / ${total}`,
    test_balance: balance,
    financial_result: pnl,
    finished_at: new Date(),
  });
}

async function startBacktest(pool, logicId, dateFrom, dateTo) {
  const { rows } = await pool.query(
    `
    INSERT INTO logic_backtest_runs (logic_id, date_from, date_to, status, progress_pct, phase_message, started_at)
    VALUES ($1, $2, $3, 'pending', 0, 'Старт', CURRENT_TIMESTAMP)
    RETURNING id
    `,
    [logicId, dateFrom, dateTo]
  );
  const runId = rows[0].id;
  setImmediate(() => {
    runBacktestAsync(pool, logicId, dateFrom, dateTo, runId).catch((err) => {
      console.error('backtest run failed', err);
    });
  });
  return runId;
}

async function getBacktestStatus(pool, logicId, runId) {
  const params = [logicId];
  let sql = `
    SELECT id, logic_id, date_from, date_to, status,
      progress_pct::float8 AS progress_pct,
      phase_message, phase_detail, current_bar_dt,
      total_bars, processed_bars, trades_created,
      test_balance::float8 AS test_balance,
      financial_result::float8 AS financial_result,
      cancel_requested, error_message, started_at, finished_at, created_at
    FROM logic_backtest_runs
    WHERE logic_id = $1
  `;
  if (runId) {
    sql += ' AND id = $2';
    params.push(runId);
  }
  sql += ' ORDER BY id DESC LIMIT 1';
  const { rows } = await pool.query(sql, params);
  return rows[0] ?? null;
}

async function cancelBacktest(pool, runId) {
  const { rowCount } = await pool.query(
    `
    UPDATE logic_backtest_runs
    SET cancel_requested = TRUE
    WHERE id = $1
      AND status IN ('pending', 'loading_prices', 'loading_indicators', 'running')
    `,
    [runId]
  );
  return rowCount > 0;
}

module.exports = {
  startBacktest,
  getBacktestStatus,
  cancelBacktest,
};

function shiftDate(isoDate, days) {
  const d = new Date(isoDate);
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}
