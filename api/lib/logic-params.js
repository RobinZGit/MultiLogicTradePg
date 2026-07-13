'use strict';

/** Ключи торговых параметров логики (строки в logic_params). */
const PARAM_KEYS = {
  POSITION_SIZE_PCT: 'position_size_pct',
  MAX_OPEN_POSITIONS: 'max_open_positions',
  INITIAL_BALANCE: 'initial_balance',
  CURRENT_BALANCE: 'current_balance',
};

const DEFAULTS = {
  [PARAM_KEYS.POSITION_SIZE_PCT]: { value: '10', type: 'number' },
  [PARAM_KEYS.MAX_OPEN_POSITIONS]: { value: '5', type: 'integer' },
  [PARAM_KEYS.INITIAL_BALANCE]: { value: '', type: 'money' },
  [PARAM_KEYS.CURRENT_BALANCE]: { value: '', type: 'money' },
};

function parseParamValue(paramKey, raw, valueType) {
  const text = raw == null ? '' : String(raw).trim();
  if (text === '') {
    if (paramKey === PARAM_KEYS.INITIAL_BALANCE || paramKey === PARAM_KEYS.CURRENT_BALANCE) {
      return null;
    }
    return null;
  }
  const t = valueType || DEFAULTS[paramKey]?.type || 'text';
  if (t === 'integer') {
    const n = Number(text);
    return Number.isInteger(n) ? n : null;
  }
  if (t === 'number' || t === 'money') {
    const n = Number(text.replace(',', '.'));
    return Number.isFinite(n) ? n : null;
  }
  if (t === 'boolean') {
    return text === 'true' || text === '1' || text === 'yes';
  }
  return text;
}

function formatParamStorage(value) {
  if (value == null || value === '') return '';
  return String(value);
}

function rowsToTradingParams(rows) {
  const map = {};
  for (const r of rows) {
    map[r.param_key] = parseParamValue(r.param_key, r.param_value, r.value_type);
  }
  return {
    position_size_pct:
      map[PARAM_KEYS.POSITION_SIZE_PCT] != null
        ? Number(map[PARAM_KEYS.POSITION_SIZE_PCT])
        : 10,
    max_open_positions:
      map[PARAM_KEYS.MAX_OPEN_POSITIONS] != null
        ? Number(map[PARAM_KEYS.MAX_OPEN_POSITIONS])
        : 5,
    initial_balance: map[PARAM_KEYS.INITIAL_BALANCE],
    current_balance: map[PARAM_KEYS.CURRENT_BALANCE],
  };
}

async function fetchParamRows(pool, logicId) {
  const { rows } = await pool.query(
    `
    SELECT lp.param_key, lp.param_value, lp.value_type
    FROM logic_params lp
    WHERE lp.logic_id = $1
    ORDER BY lp.param_key
    `,
    [logicId]
  );
  return rows;
}

async function getTradingParams(pool, logicId) {
  await ensureDefaultParams(pool, logicId);
  const rows = await fetchParamRows(pool, logicId);
  return rowsToTradingParams(rows);
}

async function ensureDefaultParams(pool, logicId) {
  await pool.query(
    `
    INSERT INTO logic_params (logic_id, param_key, param_value, value_type)
    SELECT $1, d.param_key, d.default_value, d.value_type
    FROM logic_param_defs d
    ON CONFLICT (logic_id, param_key) DO NOTHING
    `,
    [logicId]
  );
}

async function upsertParam(pool, logicId, paramKey, value, valueType) {
  const def = DEFAULTS[paramKey];
  const vt = valueType || def?.type || 'text';
  await pool.query(
    `
    INSERT INTO logic_params (logic_id, param_key, param_value, value_type)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT (logic_id, param_key) DO UPDATE SET
      param_value = EXCLUDED.param_value,
      value_type = EXCLUDED.value_type,
      updated_at = CURRENT_TIMESTAMP
    `,
    [logicId, paramKey, formatParamStorage(value), vt]
  );
}

async function saveTradingParams(pool, logicId, payload) {
  await ensureDefaultParams(pool, logicId);

  if (payload.position_size_pct !== undefined) {
    await upsertParam(
      pool,
      logicId,
      PARAM_KEYS.POSITION_SIZE_PCT,
      payload.position_size_pct,
      'number'
    );
  }
  if (payload.max_open_positions !== undefined) {
    await upsertParam(
      pool,
      logicId,
      PARAM_KEYS.MAX_OPEN_POSITIONS,
      payload.max_open_positions,
      'integer'
    );
  }
  if (payload.initial_balance !== undefined) {
    await upsertParam(
      pool,
      logicId,
      PARAM_KEYS.INITIAL_BALANCE,
      payload.initial_balance,
      'money'
    );
    if (payload.reset_balance) {
      await upsertParam(
        pool,
        logicId,
        PARAM_KEYS.CURRENT_BALANCE,
        payload.initial_balance,
        'money'
      );
    }
  }

  return getTradingParams(pool, logicId);
}

async function updateCurrentBalance(pool, logicId, balance) {
  await upsertParam(pool, logicId, PARAM_KEYS.CURRENT_BALANCE, balance, 'money');
}

async function getLogicParamsDetailed(pool, logicId) {
  await ensureDefaultParams(pool, logicId);
  const { rows } = await pool.query(
    `
    SELECT
      lp.id,
      lp.logic_id,
      lp.param_key,
      lp.param_value,
      lp.value_type,
      lp.updated_at,
      d.name_ru,
      d.description
    FROM logic_params lp
    JOIN logic_param_defs d ON d.param_key = lp.param_key
    WHERE lp.logic_id = $1
    ORDER BY d.display_order, lp.param_key
    `,
    [logicId]
  );
  return rows;
}

module.exports = {
  PARAM_KEYS,
  DEFAULTS,
  parseParamValue,
  rowsToTradingParams,
  getTradingParams,
  ensureDefaultParams,
  saveTradingParams,
  updateCurrentBalance,
  getLogicParamsDetailed,
};
