import { IndicatorRow } from '../models/lookup.model';

/** Краткая подсказка под полем формулы (create / edit). */
export const INDICATOR_FORMULA_HINT =
  'pp, sma(pp), * — свёртка, @CODE — ряд индикатора по коду из справочника (SMA, RSI…). Кнопка «И.» — полный список.';

/** Базовая справка (без каталога индикаторов). */
export const INDICATOR_FORMULA_HELP_BASE = `Многочленная формула — выражение над числовыми рядами (массивами по барам).

Рыночные ряды
  pp — Close; oo, hh, ll, vv — Open, High, Low, Volume

Ядра
  (a; b; c) — коэффициенты фильтра (запятая = точка с запятой)
  Пример: pp * (1; -2; 1) — ускорение цены (PACC)

Операции
  * — свёртка (скользящий фильтр): левый и правый операнды вычисляются как ряды, затем сворачиваются
  #, /# — покомponentное умножение / деление
  +, − — покомponentное сложение / вычитание

Функции (строят ряд из выражения)
  sma(expr) — простое MA от expr
  ema(expr) — экспоненциальное MA
  ww() — только ядро SMA периода N (для pp * ww() * ww() … без sma)

@CODE — ссылка на индикатор из справочника
  Код индикатора в таблице (SMA, RSI, MACD, SMAT3…) = короткое обозначение в формулах.
  @SMA — основная серия SMA; @MACD:HISTOGRAM — конкретная линия (серия из indicator_value_types).
  Без «:СЕРИЯ» берётся первая нетreshold-серия или VALUE.

Когда @CODE, когда sma(pp)?
  sma(pp), ema(pp) — собираете новый ряд из цены и ядер в этой формуле.
  @SMA — берёте уже заданный индикатор SMA (тот же период, что param_period серии на бумаге).
  Для комбинаций (@RSI # pp, @MACD:HISTOGRAM - @MACD:SIGNAL) используйте @.
  Для свёртки с ядром: pp * ww() или pp * (1; -2; 1) (PACC).
  Для свёртки ряда с самим собой: sma(pp) * sma(pp) (SMAT3).

SMAT3 vs SMAT3COMP
  SMAT3 — sma(pp) * sma(pp) * sma(pp): * = свёртка вычисленных рядов (S сворачивается с S)
  SMAT3COMP — sma(sma(sma(pp))): композиция — каждый sma() снова фильтрует результат
  При том же N значения разные; композиция ≈ pp * ww() * ww() * ww()`;

const IMPLEMENTED_CODES = new Set([
  'RSI',
  'SMA',
  'EMA',
  'MACD',
  'BB',
  'ATR',
  'STOCH',
  'PACC',
  'SMAT3',
  'SMAT3COMP',
]);

function seriesRef(code: string, seriesCode: string, isThreshold: boolean): string {
  if (isThreshold) return '';
  const main =
    seriesCode === 'VALUE' || seriesCode === code ? `@${code}` : `@${code}:${seriesCode}`;
  return main;
}

/** Каталог индикаторов для справки «И.» (из API /api/indicators). */
export function buildIndicatorCatalogHelp(indicators: IndicatorRow[]): string {
  const lines: string[] = [
    '',
    '─── Справочник индикаторов (@CODE) ───',
    'Доступны для @ только с реализованным расчётом (ниже отмечены ✓).',
    '',
  ];

  const sorted = [...indicators].sort((a, b) => a.code.localeCompare(b.code));
  for (const ind of sorted) {
    const implemented =
      IMPLEMENTED_CODES.has(ind.code) ||
      Boolean(ind.formula?.trim()) ||
      Boolean(ind.script?.trim());
    const mark = implemented ? '✓' : '○';
    const refs: string[] = [];
    const types = (ind.value_types ?? []).filter((t) => !t.is_threshold);
    for (const t of types) {
      const r = seriesRef(ind.code, t.code, t.is_threshold);
      if (r && !refs.includes(r)) refs.push(r);
    }
    if (refs.length === 0 && implemented) refs.push(`@${ind.code}`);

    const inline = ind.formula?.trim() ? `inline: ${ind.formula.trim()}` : '';
    const parts = [`${mark} ${ind.code} — ${ind.name}`];
    if (refs.length) parts.push(`| ${refs.join(', ')}`);
    if (inline) parts.push(`| ${inline}`);
    if (types.length) {
      parts.push(`| серии: ${types.map((t) => t.code).join(', ')}`);
    }
    if (!implemented) parts.push('| расчёт пока не реализован — @ недоступен');
    lines.push(parts.join(' '));
  }

  lines.push('');
  lines.push('Примеры');
  lines.push('  sma(pp) * sma(pp) * sma(pp) — SMAT3 (свёртка ряда SMA с собой)');
  lines.push('  sma(sma(sma(pp)))         — SMAT3COMP (композиция, другие числа)');
  lines.push('  pp * ww() * ww() * ww()   — то же что SMAT3COMP при том же N');
  lines.push('  @RSI # pp                  — RSI покомponentно × цена');
  lines.push('  @MACD:HISTOGRAM            — гистограмма MACD');
  lines.push('  pp * (1; -2; 1)            — PACC');

  return lines.join('\n');
}

export function buildFullFormulaHelp(indicators: IndicatorRow[]): string {
  return INDICATOR_FORMULA_HELP_BASE + buildIndicatorCatalogHelp(indicators);
}

/** @deprecated используйте buildFullFormulaHelp */
export const INDICATOR_FORMULA_HELP_DETAIL = INDICATOR_FORMULA_HELP_BASE;
