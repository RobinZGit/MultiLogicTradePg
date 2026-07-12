require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');

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

app.get('/api/logics', async (_req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT
        l.id,
        l.name,
        l.account_id,
        a.account_code,
        a.name AS account_name,
        a.account_type,
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

app.listen(port, () => {
  console.log(`MultiLogicTrade API: http://localhost:${port}`);
  console.log(`CORS origin: ${corsOrigin}`);
});
