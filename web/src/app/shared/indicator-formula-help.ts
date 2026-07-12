import { IndicatorRow } from '../models/lookup.model';

/** Краткая подсказка под полем формулы (create / edit). */
export const INDICATOR_FORMULA_HINT =
  'pp, sma, ema, * — свёртка, @CODE — ряд индикатора (SMA, RSI…). Кнопка «И.» — полный список.';

/** Базовая справка (без каталога индикаторов). */
export const INDICATOR_FORMULA_HELP_BASE = `Многочленная формула — выражение над числовыми рядами (массивами по барам).

Рыночные ряды
  pp — Close; oo, hh, ll, vv — Open, High, Low, Volume

Ядра
  (a; b; c) — коэффициенты фильтра (запятая = точка с запятой)
  Пример: pp * (1; -2; 1) — ускорение цены (PACC)

Операции
  * — свёртка: левый и правый операнды вычисляются как ряды, затем сворачиваются
  #, /# — покомponentное умножение / деление
  +, − — покомponentное сложение / вычитание

Функции (всегда от close, pp)
  sma — простое MA от close; sma() то же
  ema — экспоненциальное MA от close
  ww() — только ядро SMA периода N (для pp * ww() …)

@CODE — ссылка на индикатор из справочника
  Код в таблице (SMA, RSI, MACD, SMAT3…) = @CODE в формулах.
  @SMA — серия SMA; @MACD:HISTOGRAM — конкретная линия.
  Без «:СЕРИЯ» — первая нетreshold-серия или VALUE.

Когда @CODE, когда sma?
  sma, ema — новый ряд от close в этой формуле (без sma(pp) в скобках).
  @SMA — уже рассчитанный индикатор с param_period серии на бумаге.
  Для комбинаций (@RSI # pp) — @; для свёрток (sma * sma, PACC) — функции и *.

SMAT3
  sma * sma * sma — три раза SMA(close), свёртка ряда с собой (нормализация на шкале цены)`;

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
  lines.push('  sma * sma * sma         — SMAT3');
  lines.push('  sma                     — SMA от close');
  lines.push('  @RSI # pp               — RSI покомponentно × цена');
  lines.push('  @MACD:HISTOGRAM         — гистограмма MACD');
  lines.push('  pp * (1; -2; 1)         — PACC');

  return lines.join('\n');
}

export function buildFullFormulaHelp(indicators: IndicatorRow[]): string {
  return INDICATOR_FORMULA_HELP_BASE + buildIndicatorCatalogHelp(indicators);
}
