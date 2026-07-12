require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
const {
  hashToken,
  fetchTbankPortfolioBalance,
  fetchTbankAccounts,
  resolveTbankAccountByToken,
} = require('./tbank');

const app = express();
const port = Number(process.env.PORT) || 3000;
const corsOrigin = process.env.CORS_ORIGIN || 'http://localhost:4200';

const pool = new Pool({
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT) || 5432,
  database: process.env.PGDATABASE || 'multilogictrade',
  user: process.env.PGUSER || 'postgres',
  password: process.env.PGPASSWORD,
});

app.use(cors({ origin: corsOrigin }));
app.use(express.json());

app.get('/api/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ ok: true, database: process.env.PGDATABASE || 'multilogictrade' });
  } catch (err) {
    res.status(503).json({ ok: false, error: err.message });
  }
});

app.get('/api/indicators', async (req, res) => {
  const withCalc = req.query.with_calc === '1';
  try {
    const { rows } = await pool.query(
      `
      SELECT
        i.id,
        i.code,
        i.name,
        i.script,
        i.description,
        i.category,
        i.is_active,
        COALESCE(
          json_agg(
            json_build_object(
              'id', vt.id,
              'code', vt.code,
              'name', vt.name,
              'value_type', vt.value_type,
              'is_threshold', vt.is_threshold,
              'threshold_value', vt.threshold_value,
              'display_order', vt.display_order
            )
            ORDER BY vt.display_order, vt.id
          ) FILTER (WHERE vt.id IS NOT NULL),
          '[]'::json
        ) AS value_types
      FROM indicators i
      LEFT JOIN indicator_value_types vt ON vt.indicator_id = i.id
      WHERE ($1::boolean = FALSE OR (i.script IS NOT NULL AND BTRIM(i.script) <> ''))
      GROUP BY i.id
      ORDER BY i.code
    `,
      [withCalc]
    );
    res.json(rows);
  } catch (err) {
    console.error('GET /api/indicators', err);
    res.status(500).json({ error: err.message });
  }
});

app.put('/api/indicators/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) {
    res.status(400).json({ error: 'Invalid indicator id' });
    return;
  }
  const parsed = parseIndicatorBody(req.body);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  try {
    const { rows } = await pool.query(
      `UPDATE indicators
       SET name = $1, description = $2, category = $3, script = $4, is_active = $5
       WHERE id = $6
       RETURNING id, code, name, script, description, category, is_active`,
      [
        parsed.name,
        parsed.description,
        parsed.category,
        parsed.script,
        parsed.is_active,
        id,
      ]
    );
    if (rows.length === 0) {
      res.status(404).json({ error: 'Indicator not found' });
      return;
    }
    const { rows: full } = await pool.query(
      `
      SELECT
        i.id,
        i.code,
        i.name,
        i.script,
        i.description,
        i.category,
        i.is_active,
        COALESCE(
          json_agg(
            json_build_object(
              'id', vt.id,
              'code', vt.code,
              'name', vt.name,
              'value_type', vt.value_type,
              'is_threshold', vt.is_threshold,
              'threshold_value', vt.threshold_value,
              'display_order', vt.display_order
            )
            ORDER BY vt.display_order, vt.id
          ) FILTER (WHERE vt.id IS NOT NULL),
          '[]'::json
        ) AS value_types
      FROM indicators i
      LEFT JOIN indicator_value_types vt ON vt.indicator_id = i.id
      WHERE i.id = $1
      GROUP BY i.id
    `,
      [id]
    );
    res.json(full[0]);
  } catch (err) {
    handleDbError(res, err, 'PUT /api/indicators/:id');
  }
});

app.get('/api/logics', async (_req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT
        l.id,
        l.name,
        l.account_id,
        l.is_enabled,
        a.account_code,
        a.name AS account_name,
        a.account_type,
        a.broker_id,
        a.is_active AS account_is_active,
        b.code AS broker_code,
        b.name AS broker_name
      FROM logics l
      JOIN accounts a ON a.id = l.account_id
      JOIN brokers b ON b.id = a.broker_id
      ORDER BY l.id
    `);
    res.json(rows);
  } catch (err) {
    console.error('GET /api/logics', err);
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/brokers', async (_req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT id, code, name, api_url, is_active
      FROM brokers
      ORDER BY code
    `);
    res.json(rows);
  } catch (err) {
    console.error('GET /api/brokers', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/brokers', async (req, res) => {
  const parsed = parseBrokerBody(req.body);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  try {
    const { rows } = await pool.query(
      `INSERT INTO brokers (code, name, api_url, is_active)
       VALUES ($1, $2, $3, $4)
       RETURNING id, code, name, api_url, is_active`,
      [parsed.code, parsed.name, parsed.api_url, parsed.is_active]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    handleDbError(res, err, 'POST /api/brokers');
  }
});

app.put('/api/brokers/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) {
    res.status(400).json({ error: 'Invalid broker id' });
    return;
  }
  const parsed = parseBrokerBody(req.body);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  try {
    const { rows } = await pool.query(
      `UPDATE brokers SET code = $1, name = $2, api_url = $3, is_active = $4
       WHERE id = $5
       RETURNING id, code, name, api_url, is_active`,
      [parsed.code, parsed.name, parsed.api_url, parsed.is_active, id]
    );
    if (rows.length === 0) {
      res.status(404).json({ error: 'Broker not found' });
      return;
    }
    res.json(rows[0]);
  } catch (err) {
    handleDbError(res, err, 'PUT /api/brokers/:id');
  }
});

app.delete('/api/brokers/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) {
    res.status(400).json({ error: 'Invalid broker id' });
    return;
  }
  try {
    const { rowCount } = await pool.query('DELETE FROM brokers WHERE id = $1', [id]);
    if (rowCount === 0) {
      res.status(404).json({ error: 'Broker not found' });
      return;
    }
    res.json({ ok: true, id });
  } catch (err) {
    handleDbError(res, err, 'DELETE /api/brokers/:id');
  }
});

app.get('/api/exchanges', async (_req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT id, name FROM exchanges ORDER BY name
    `);
    res.json(rows);
  } catch (err) {
    console.error('GET /api/exchanges', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/exchanges', async (req, res) => {
  const parsed = parseExchangeBody(req.body);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  try {
    const { rows } = await pool.query(
      `INSERT INTO exchanges (name) VALUES ($1) RETURNING id, name`,
      [parsed.name]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    handleDbError(res, err, 'POST /api/exchanges');
  }
});

app.put('/api/exchanges/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) {
    res.status(400).json({ error: 'Invalid exchange id' });
    return;
  }
  const parsed = parseExchangeBody(req.body);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  try {
    const { rows } = await pool.query(
      `UPDATE exchanges SET name = $1 WHERE id = $2 RETURNING id, name`,
      [parsed.name, id]
    );
    if (rows.length === 0) {
      res.status(404).json({ error: 'Exchange not found' });
      return;
    }
    res.json(rows[0]);
  } catch (err) {
    handleDbError(res, err, 'PUT /api/exchanges/:id');
  }
});

app.delete('/api/exchanges/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) {
    res.status(400).json({ error: 'Invalid exchange id' });
    return;
  }
  try {
    const { rowCount } = await pool.query('DELETE FROM exchanges WHERE id = $1', [id]);
    if (rowCount === 0) {
      res.status(404).json({ error: 'Exchange not found' });
      return;
    }
    res.json({ ok: true, id });
  } catch (err) {
    handleDbError(res, err, 'DELETE /api/exchanges/:id');
  }
});

app.get('/api/accounts', async (req, res) => {
  try {
    const brokerId = req.query.broker_id ? Number(req.query.broker_id) : null;
    const withBalance = req.query.with_balance === '1' || req.query.with_balance === 'true';
    const params = [];
    let where = '';
    if (brokerId && Number.isInteger(brokerId) && brokerId > 0) {
      where = 'WHERE a.broker_id = $1';
      params.push(brokerId);
    }
    const { rows } = await pool.query(
      `
      SELECT
        a.id,
        a.broker_id,
        a.account_code,
        a.name,
        a.account_type,
        a.is_efficient,
        a.is_active,
        (a.token_encrypted IS NOT NULL AND btrim(a.token_encrypted) <> '') AS has_token,
        b.code AS broker_code,
        b.name AS broker_name,
        b.api_url AS broker_api_url
      FROM accounts a
      JOIN brokers b ON b.id = a.broker_id
      ${where}
      ORDER BY b.code, a.account_code
      `,
      params
    );
    if (!withBalance) {
      res.json(rows.map(stripAccountSecrets));
      return;
    }
    const enriched = await Promise.all(
      rows.map((row) => enrichAccountBalance(row))
    );
    res.json(enriched.map(stripAccountSecrets));
  } catch (err) {
    console.error('GET /api/accounts', err);
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/accounts/preview-connection', async (req, res) => {
  try {
    const preview = await resolveAccountConnection(req.body);
    if (preview.error) {
      res.status(400).json({ error: preview.error });
      return;
    }
    const resolved = await resolveTbankAccountByToken(
      preview.broker_api_url,
      preview.token,
      preview.account_code || null
    );
    let balance = null;
    let balance_error = null;
    try {
      balance = await fetchTbankPortfolioBalance(
        preview.broker_api_url,
        preview.token,
        resolved.accountId
      );
    } catch (balErr) {
      balance_error = balErr.message;
    }
    res.json({
      ok: true,
      accounts: resolved.accounts,
      selected_account_id: resolved.accountId,
      selected_account_name: resolved.accountName,
      accounts_found: resolved.accounts.length,
      balance: balance?.amount ?? null,
      balance_currency: balance?.currency ?? null,
      balance_display: balance?.display ?? null,
      balance_error,
    });
  } catch (err) {
    console.error('POST /api/accounts/preview-connection', err);
    res.status(502).json({ error: err.message || 'Не удалось проверить подключение' });
  }
});

app.post('/api/accounts', async (req, res) => {
  let parsed = parseAccountBody(req.body);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  parsed = await fillRealTbankAccountFromToken(parsed, req.body?.account_id);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  if (parsed.account_type === 'real' && !parsed.api_token && !parsed._has_stored_token) {
    res.status(400).json({ error: 'Для реального счёта укажите API-токен' });
    return;
  }
  try {
    const tokenFields = tokenFieldsFromParsed(parsed);
    const { rows } = await pool.query(
      `INSERT INTO accounts (broker_id, account_code, name, account_type, is_efficient, is_active, token_encrypted, token_hash)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING id, broker_id, account_code, name, account_type, is_efficient, is_active,
         (token_encrypted IS NOT NULL AND btrim(token_encrypted) <> '') AS has_token`,
      [
        parsed.broker_id,
        parsed.account_code,
        parsed.name,
        parsed.account_type,
        parsed.is_efficient,
        parsed.is_active,
        tokenFields.token_encrypted,
        tokenFields.token_hash,
      ]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    handleDbError(res, err, 'POST /api/accounts');
  }
});

app.put('/api/accounts/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) {
    res.status(400).json({ error: 'Invalid account id' });
    return;
  }
  const parsed = parseAccountBody(req.body);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  let filled = await fillRealTbankAccountFromToken(parsed, id);
  if (filled.error) {
    res.status(400).json({ error: filled.error });
    return;
  }
  try {
    const tokenUpdate = buildTokenUpdateClause(filled, 8);
    const values = [
      filled.broker_id,
      filled.account_code,
      filled.name,
      filled.account_type,
      filled.is_efficient,
      filled.is_active,
      id,
      ...tokenUpdate.extraValues,
    ];
    const { rows } = await pool.query(
      `UPDATE accounts
       SET broker_id = $1, account_code = $2, name = $3, account_type = $4,
           is_efficient = $5, is_active = $6, updated_at = CURRENT_TIMESTAMP
           ${tokenUpdate.sql}
       WHERE id = $7
       RETURNING id, broker_id, account_code, name, account_type, is_efficient, is_active,
         (token_encrypted IS NOT NULL AND btrim(token_encrypted) <> '') AS has_token`,
      values
    );
    if (rows.length === 0) {
      res.status(404).json({ error: 'Account not found' });
      return;
    }
    res.json(rows[0]);
  } catch (err) {
    handleDbError(res, err, 'PUT /api/accounts/:id');
  }
});

app.delete('/api/accounts/:id', async (req, res) => {
  const id = parseId(req.params.id);
  if (!id) {
    res.status(400).json({ error: 'Invalid account id' });
    return;
  }
  try {
    const { rowCount } = await pool.query('DELETE FROM accounts WHERE id = $1', [id]);
    if (rowCount === 0) {
      res.status(404).json({ error: 'Account not found' });
      return;
    }
    res.json({ ok: true, id });
  } catch (err) {
    handleDbError(res, err, 'DELETE /api/accounts/:id');
  }
});

app.post('/api/logics', async (req, res) => {
  const parsed = parseLogicBody(req.body);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  try {
    const { rows } = await pool.query(
      `
      INSERT INTO logics (name, account_id, is_enabled)
      VALUES ($1, $2, $3)
      RETURNING id, name, account_id, is_enabled
      `,
      [parsed.name, parsed.account_id, parsed.is_enabled]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    console.error('POST /api/logics', err);
    if (err.code === '23505') {
      res.status(409).json({ error: 'Логика с таким именем уже существует' });
      return;
    }
    if (err.code === '23503') {
      res.status(400).json({ error: 'Указан несуществующий счёт' });
      return;
    }
    res.status(500).json({ error: err.message });
  }
});

app.put('/api/logics/:id', async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    res.status(400).json({ error: 'Invalid logic id' });
    return;
  }
  const parsed = parseLogicBody(req.body);
  if (parsed.error) {
    res.status(400).json({ error: parsed.error });
    return;
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const existing = await client.query(
      'SELECT id, name FROM logics WHERE id = $1',
      [id]
    );
    if (existing.rows.length === 0) {
      await client.query('ROLLBACK');
      res.status(404).json({ error: 'Logic not found' });
      return;
    }
    const oldName = existing.rows[0].name;
    if (oldName !== parsed.name) {
      await client.query(
        'UPDATE logics_detail SET logic_name = $1 WHERE logic_name = $2',
        [parsed.name, oldName]
      );
    }
    const { rows } = await client.query(
      `
      UPDATE logics
      SET name = $1, account_id = $2, is_enabled = $3
      WHERE id = $4
      RETURNING id, name, account_id, is_enabled
      `,
      [parsed.name, parsed.account_id, parsed.is_enabled, id]
    );
    await client.query('COMMIT');
    res.json(rows[0]);
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('PUT /api/logics/:id', err);
    if (err.code === '23505') {
      res.status(409).json({ error: 'Логика с таким именем уже существует' });
      return;
    }
    if (err.code === '23503') {
      res.status(400).json({ error: 'Указан несуществующий счёт' });
      return;
    }
    res.status(500).json({ error: err.message });
  } finally {
    client.release();
  }
});

app.delete('/api/logics/:id', async (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    res.status(400).json({ error: 'Invalid logic id' });
    return;
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const existing = await client.query(
      'SELECT id, name FROM logics WHERE id = $1',
      [id]
    );
    if (existing.rows.length === 0) {
      await client.query('ROLLBACK');
      res.status(404).json({ error: 'Logic not found' });
      return;
    }
    await client.query('DELETE FROM logics_detail WHERE logic_name = $1', [
      existing.rows[0].name,
    ]);
    await client.query('DELETE FROM logics WHERE id = $1', [id]);
    await client.query('COMMIT');
    res.json({ ok: true, id });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('DELETE /api/logics/:id', err);
    res.status(500).json({ error: err.message });
  } finally {
    client.release();
  }
});

app.patch('/api/logics/:id', async (req, res) => {
  const id = Number(req.params.id);
  const { is_enabled } = req.body;
  if (!Number.isInteger(id) || id <= 0) {
    res.status(400).json({ error: 'Invalid logic id' });
    return;
  }
  if (typeof is_enabled !== 'boolean') {
    res.status(400).json({ error: 'is_enabled must be boolean' });
    return;
  }
  try {
    const { rows } = await pool.query(
      `UPDATE logics SET is_enabled = $1 WHERE id = $2 RETURNING id, is_enabled`,
      [is_enabled, id]
    );
    if (rows.length === 0) {
      res.status(404).json({ error: 'Logic not found' });
      return;
    }
    res.json(rows[0]);
  } catch (err) {
    console.error('PATCH /api/logics/:id', err);
    res.status(500).json({ error: err.message });
  }
});

/** Живая структура БД multilogictrade (public) */
app.get('/api/schema', async (_req, res) => {
  try {
    const [tablesResult, routinesResult, extensionsResult] = await Promise.all([
      pool.query(`
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
        ORDER BY table_name
      `),
      pool.query(`
        SELECT
          p.oid,
          p.proname AS name,
          p.prokind AS kind,
          pg_get_function_identity_arguments(p.oid) AS arguments,
          pg_get_function_result(p.oid) AS result_type,
          obj_description(p.oid, 'pg_proc') AS description
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p')
        ORDER BY p.prokind, p.proname, p.oid
      `),
      pool.query(`
        SELECT extname AS name, extversion AS version
        FROM pg_extension
        ORDER BY extname
      `),
    ]);

    const tables = [];
    for (const { table_name } of tablesResult.rows) {
      const [columns, indexes, constraints, tableComment] = await Promise.all([
        pool.query(
          `
          SELECT
            c.column_name,
            c.data_type,
            c.udt_name,
            c.is_nullable,
            c.column_default,
            c.character_maximum_length,
            c.numeric_precision,
            c.numeric_scale,
            c.ordinal_position,
            pg_catalog.col_description(cls.oid, c.ordinal_position) AS comment
          FROM information_schema.columns c
          JOIN pg_catalog.pg_class cls ON cls.relname = c.table_name
          JOIN pg_catalog.pg_namespace n ON n.oid = cls.relnamespace AND n.nspname = c.table_schema
          WHERE c.table_schema = 'public' AND c.table_name = $1
          ORDER BY c.ordinal_position
          `,
          [table_name]
        ),
        pool.query(
          `
          SELECT indexname AS name, indexdef AS definition
          FROM pg_indexes
          WHERE schemaname = 'public' AND tablename = $1
          ORDER BY indexname
          `,
          [table_name]
        ),
        pool.query(
          `
          SELECT
            c.conname AS name,
            c.contype AS type,
            pg_get_constraintdef(c.oid) AS definition
          FROM pg_constraint c
          JOIN pg_class rel ON rel.oid = c.conrelid
          JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
          WHERE nsp.nspname = 'public' AND rel.relname = $1
          ORDER BY c.conname
          `,
          [table_name]
        ),
        pool.query(
          `
          SELECT obj_description(c.oid, 'pg_class') AS comment
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public' AND c.relname = $1
          `,
          [table_name]
        ),
      ]);

      tables.push({
        name: table_name,
        comment: tableComment.rows[0]?.comment || null,
        columns: columns.rows.map(formatColumn),
        indexes: indexes.rows,
        constraints: constraints.rows.map(formatConstraint),
      });
    }

    res.json({
      schema: 'public',
      database: process.env.PGDATABASE || 'multilogictrade',
      tables,
      routines: routinesResult.rows.map(formatRoutine),
      extensions: extensionsResult.rows,
    });
  } catch (err) {
    console.error('GET /api/schema', err);
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/schema/routine/:oid/source', async (req, res) => {
  const oid = Number(req.params.oid);
  if (!Number.isInteger(oid) || oid <= 0) {
    res.status(400).json({ error: 'Invalid routine oid' });
    return;
  }
  try {
    const { rows } = await pool.query(
      `
      SELECT
        p.proname AS name,
        p.prokind AS kind,
        pg_get_function_identity_arguments(p.oid) AS arguments,
        pg_get_functiondef(p.oid) AS source
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.oid = $1
      `,
      [oid]
    );
    if (rows.length === 0) {
      res.status(404).json({ error: 'Routine not found' });
      return;
    }
    res.json(rows[0]);
  } catch (err) {
    console.error('GET /api/schema/routine/:oid/source', err);
    res.status(500).json({ error: err.message });
  }
});

function formatColumn(col) {
  let type = col.data_type;
  if (col.character_maximum_length) {
    type += `(${col.character_maximum_length})`;
  } else if (col.data_type === 'numeric' && col.numeric_precision) {
    type += `(${col.numeric_precision}${col.numeric_scale != null ? `,${col.numeric_scale}` : ''})`;
  } else if (col.data_type === 'USER-DEFINED') {
    type = col.udt_name;
  }
  return {
    name: col.column_name,
    type,
    nullable: col.is_nullable === 'YES',
    default: col.column_default,
    comment: col.comment || null,
  };
}

function formatConstraint(c) {
  const types = { p: 'PRIMARY KEY', f: 'FOREIGN KEY', u: 'UNIQUE', c: 'CHECK', x: 'EXCLUDE' };
  return {
    name: c.name,
    type: types[c.type] || c.type,
    definition: c.definition,
  };
}

function formatRoutine(r) {
  return {
    oid: r.oid,
    name: r.name,
    kind: r.kind === 'p' ? 'procedure' : 'function',
    arguments: r.arguments || '',
    result_type: r.result_type || null,
    description: r.description || null,
  };
}

function parseLogicBody(body) {
  const name = typeof body?.name === 'string' ? body.name.trim() : '';
  const account_id = Number(body?.account_id);
  const is_enabled =
    body?.is_enabled === undefined ? true : Boolean(body.is_enabled);

  if (!name) {
    return { error: 'Укажите имя логики' };
  }
  if (name.length > 100) {
    return { error: 'Имя логики не длиннее 100 символов' };
  }
  if (!Number.isInteger(account_id) || account_id <= 0) {
    return { error: 'Выберите счёт' };
  }
  return { name, account_id, is_enabled };
}

function parseId(value) {
  const id = Number(value);
  return Number.isInteger(id) && id > 0 ? id : null;
}

function parseBrokerBody(body) {
  const code = typeof body?.code === 'string' ? body.code.trim() : '';
  const name = typeof body?.name === 'string' ? body.name.trim() : '';
  const api_url =
    body?.api_url == null || body.api_url === ''
      ? null
      : String(body.api_url).trim();
  const is_active = body?.is_active === undefined ? true : Boolean(body.is_active);

  if (!code) return { error: 'Укажите код брокера' };
  if (code.length > 50) return { error: 'Код брокера не длиннее 50 символов' };
  if (!name) return { error: 'Укажите название брокера' };
  if (name.length > 100) return { error: 'Название брокера не длиннее 100 символов' };
  if (api_url && api_url.length > 255) return { error: 'URL API слишком длинный' };
  return { code, name, api_url, is_active };
}

function parseExchangeBody(body) {
  const name = typeof body?.name === 'string' ? body.name.trim() : '';
  if (!name) return { error: 'Укажите название площадки' };
  if (name.length > 50) return { error: 'Название площадки не длиннее 50 символов' };
  return { name };
}

function parseIndicatorBody(body) {
  const name = typeof body?.name === 'string' ? body.name.trim() : '';
  const description =
    body?.description == null || body.description === ''
      ? null
      : String(body.description).trim();
  const category =
    body?.category == null || body.category === ''
      ? null
      : String(body.category).trim();
  const script =
    body?.script == null || body.script === ''
      ? null
      : String(body.script).trim();
  const is_active = body?.is_active === undefined ? true : Boolean(body.is_active);

  if (!name) return { error: 'Укажите название индикатора' };
  if (name.length > 100) return { error: 'Название индикатора не длиннее 100 символов' };
  if (category && category.length > 50) return { error: 'Категория не длиннее 50 символов' };
  return { name, description, category, script, is_active };
}

function parseAccountBody(body) {
  const broker_id = Number(body?.broker_id);
  const account_code =
    typeof body?.account_code === 'string' ? body.account_code.trim() : '';
  const name = typeof body?.name === 'string' ? body.name.trim() : '';
  const account_type = body?.account_type === 'real' ? 'real' : 'fake';
  const is_efficient = Boolean(body?.is_efficient);
  const is_active = body?.is_active === undefined ? true : Boolean(body.is_active);

  let api_token;
  if (body?.clear_token === true) {
    api_token = '';
  } else if (body?.api_token !== undefined) {
    api_token = typeof body.api_token === 'string' ? body.api_token.trim() : '';
  }

  if (!Number.isInteger(broker_id) || broker_id <= 0) {
    return { error: 'Выберите брокера' };
  }
  const isReal = account_type === 'real';
  if (!isReal && !account_code) return { error: 'Укажите код счёта' };
  if (account_code && account_code.length > 100) {
    return { error: 'Код счёта не длиннее 100 символов' };
  }
  if (!isReal && !name) return { error: 'Укажите название счёта' };
  if (name && name.length > 100) return { error: 'Название счёта не длиннее 100 символов' };
  return {
    broker_id,
    account_code,
    name,
    account_type,
    is_efficient,
    is_active,
    api_token,
  };
}

async function fillRealTbankAccountFromToken(parsed, existingAccountId) {
  if (parsed.account_type !== 'real') {
    return parsed;
  }
  const { rows: brokers } = await pool.query(
    'SELECT id, code, api_url FROM brokers WHERE id = $1',
    [parsed.broker_id]
  );
  if (brokers.length === 0 || brokers[0].code !== 'T-BANK') {
    return parsed;
  }

  let token = parsed.api_token;
  if (!token && existingAccountId) {
    const { rows } = await pool.query(
      'SELECT token_encrypted FROM accounts WHERE id = $1',
      [existingAccountId]
    );
    token = rows[0]?.token_encrypted || '';
    if (token) parsed._has_stored_token = true;
  }

  if (!token) {
    if (!parsed.account_code) {
      return { error: 'Укажите API-токен T-Bank' };
    }
    return parsed;
  }

  try {
    const resolved = await resolveTbankAccountByToken(
      brokers[0].api_url,
      token,
      parsed.account_code || null
    );
    parsed.account_code = resolved.accountId;
    if (!parsed.name) {
      parsed.name = resolved.accountName || `T-Bank ${resolved.accountId.slice(0, 8)}`;
    }
    return parsed;
  } catch (err) {
    return { error: err.message };
  }
}

function tokenFieldsFromParsed(parsed) {
  const token = parsed.api_token || null;
  return {
    token_encrypted: token,
    token_hash: token ? hashToken(token) : null,
  };
}

function buildTokenUpdateClause(parsed, startIndex) {
  if (parsed.api_token === undefined) {
    return { sql: '', extraValues: [] };
  }
  if (parsed.api_token === '') {
    return {
      sql: ', token_encrypted = NULL, token_hash = NULL',
      extraValues: [],
    };
  }
  return {
    sql: `, token_encrypted = $${startIndex}, token_hash = $${startIndex + 1}`,
    extraValues: [parsed.api_token, hashToken(parsed.api_token)],
  };
}

function stripAccountSecrets(row) {
  const { broker_api_url, token_encrypted, ...safe } = row;
  return safe;
}

async function enrichAccountBalance(row) {
  const base = {
    ...row,
    balance: null,
    balance_currency: null,
    balance_display: '—',
    balance_error: null,
  };
  if (!row.has_token) {
    return base;
  }
  if (row.account_type === 'fake') {
    base.balance_display = 'демо';
    return base;
  }
  if (row.broker_code !== 'T-BANK') {
    base.balance_display = 'н/д';
    return base;
  }
  try {
    const { rows: tokenRows } = await pool.query(
      `SELECT a.token_encrypted, b.api_url AS broker_api_url
       FROM accounts a JOIN brokers b ON b.id = a.broker_id
       WHERE a.id = $1`,
      [row.id]
    );
    const token = tokenRows[0]?.token_encrypted;
    if (!token) {
      return base;
    }
    const bal = await fetchTbankPortfolioBalance(
      tokenRows[0].broker_api_url,
      token,
      (
        await resolveTbankAccountByToken(
          tokenRows[0].broker_api_url,
          token,
          row.account_code || null
        )
      ).accountId
    );
    base.balance = bal.amount;
    base.balance_currency = bal.currency;
    base.balance_display = bal.display;
  } catch (err) {
    base.balance_error = err.message;
    base.balance_display = 'ошибка';
  }
  return base;
}

async function resolveAccountConnection(body) {
  const broker_id = Number(body?.broker_id);
  const account_code =
    typeof body?.account_code === 'string' ? body.account_code.trim() : '';
  const account_id = body?.account_id ? Number(body.account_id) : null;
  let api_token =
    typeof body?.api_token === 'string' ? body.api_token.trim() : '';

  let brokerRow;
  if (Number.isInteger(broker_id) && broker_id > 0) {
    const { rows: brokers } = await pool.query(
      'SELECT id, code, api_url FROM brokers WHERE id = $1',
      [broker_id]
    );
    brokerRow = brokers[0];
  } else {
    const { rows: brokers } = await pool.query(
      "SELECT id, code, api_url FROM brokers WHERE code = 'T-BANK' LIMIT 1"
    );
    brokerRow = brokers[0];
  }

  if (!brokerRow) {
    return { error: 'Брокер T-Bank не найден в справочнике' };
  }
  if (brokerRow.code !== 'T-BANK') {
    return { error: 'Проверка по токену пока поддерживается только для T-Bank' };
  }

  if (!api_token && account_id) {
    const { rows } = await pool.query(
      'SELECT token_encrypted FROM accounts WHERE id = $1',
      [account_id]
    );
    api_token = rows[0]?.token_encrypted || '';
  }
  if (!api_token) {
    return { error: 'Укажите API-токен' };
  }

  return {
    token: api_token,
    account_code: account_code || null,
    broker_api_url: brokerRow.api_url,
    broker_id: brokerRow.id,
  };
}

function handleDbError(res, err, label) {
  console.error(label, err);
  if (err.code === '23505') {
    res.status(409).json({ error: 'Запись с такими ключевыми полями уже существует' });
    return;
  }
  if (err.code === '23503') {
    res.status(400).json({
      error: 'Нельзя удалить или изменить: есть связанные записи в других таблицах',
    });
    return;
  }
  res.status(500).json({ error: err.message });
}

app.use((_req, res) => {
  res.status(404).json({
    error: `Маршрут API не найден. Перезапустите web\\MultiLogic_Trade_Progress_Start.bat.`,
  });
});

app.listen(port, () => {
  console.log(`MultiLogicTrade API: http://localhost:${port}`);
  console.log(`CORS origin: ${corsOrigin}`);
});
