#!/usr/bin/env node
/**
 * Подставляет модули sql/*.sql в 02_multilogictrade_functions_and_procedures.sql
 * (секции с @include-комментариями).
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');

function read(name) {
  return fs.readFileSync(path.join(root, name), 'utf8');
}

function replaceBetween(content, startMarker, endMarker, replacement, label) {
  const start = content.indexOf(startMarker);
  const end = content.indexOf(endMarker, start + startMarker.length);
  if (start === -1 || end === -1) {
    throw new Error(`sync-02: markers not found for ${label}`);
  }
  const next =
    typeof replacement === 'function' ? replacement() : replacement;
  return content.slice(0, start) + next + content.slice(end);
}

let sql02 = read('02_multilogictrade_functions_and_procedures.sql');

const stopRunner = read('sql/logic_stop_runner.sql').trimEnd() + '\n\n';
sql02 = replaceBetween(
  sql02,
  'CREATE OR REPLACE FUNCTION logic_long_position_qty(',
  'CREATE OR REPLACE FUNCTION logic_calc_open_quantity(',
  `-- @include sql/logic_stop_runner.sql (см. sql/logic_stop_runner.sql — дублируется ниже)\n${stopRunner}`,
  'logic_stop_runner'
);

const closeAll = read('sql/logic_close_all_positions.sql').trimEnd() + '\n\n';
sql02 = replaceBetween(
  sql02,
  '-- @include sql/logic_close_all_positions.sql (см. sql/logic_close_all_positions.sql — дублируется ниже)',
  'CREATE OR REPLACE FUNCTION process_logic_trades(p_logic_id INTEGER)',
  `-- @include sql/logic_close_all_positions.sql (см. sql/logic_close_all_positions.sql — дублируется ниже)\n${closeAll}`,
  'logic_close_all_positions'
);

const tradeTail = read('sql/logic_trade_runner.sql');
const tradeStart = tradeTail.indexOf('CREATE OR REPLACE FUNCTION process_logic_trades');
const tradeEnd = tradeTail.indexOf('COMMENT ON FUNCTION run_trade_cycle()');
if (tradeStart === -1 || tradeEnd === -1) {
  throw new Error('sync-02: process_logic_trades / run_trade_cycle not found in logic_trade_runner.sql');
}
const tradeBlock =
  tradeTail.slice(tradeStart, tradeEnd).trimEnd() +
  '\n\n' +
  tradeTail.slice(tradeEnd).trimEnd() +
  '\n';

sql02 = replaceBetween(
  sql02,
  'CREATE OR REPLACE FUNCTION process_logic_trades(p_logic_id INTEGER)',
  '-- @optional-pgcron-block',
  tradeBlock + '\n',
  'process_logic_trades + run_trade_cycle'
);

const backtestBlock = read('sql/logic_backtest_runner.sql').trimEnd() + '\n\n';
if (sql02.includes('-- @include sql/logic_backtest_runner.sql')) {
  sql02 = replaceBetween(
    sql02,
    '-- @include sql/logic_backtest_runner.sql',
    '-- @optional-pgcron-block',
    () =>
      `-- @include sql/logic_backtest_runner.sql (см. sql/logic_backtest_runner.sql — дублируется ниже)\n${backtestBlock}`,
    'logic_backtest_runner'
  );
} else {
  const insertBacktest = () =>
    `-- @include sql/logic_backtest_runner.sql (см. sql/logic_backtest_runner.sql — дублируется ниже)\n${backtestBlock}-- @optional-pgcron-block`;
  sql02 = sql02.replace('-- @optional-pgcron-block', insertBacktest);
}

fs.writeFileSync(path.join(root, '02_multilogictrade_functions_and_procedures.sql'), sql02, 'utf8');
console.log('sync-02: OK — 02_multilogictrade_functions_and_procedures.sql updated');
