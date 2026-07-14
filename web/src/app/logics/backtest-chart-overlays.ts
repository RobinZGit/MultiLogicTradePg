import {
  ChartEquityPoint,
  ChartShadedRange,
  ChartStopMarker,
  ChartTradeMarker,
} from '../models/market.model';
import { LogicTradeRow } from '../shared/logic-trade';

export function dtKey(dt: string): string {
  return String(dt || '')
    .replace('T', ' ')
    .replace(/Z$/i, '')
    .replace(/\.\d+/, '')
    .slice(0, 19);
}

/** Минимальная / максимальная дата сделок бумаги (для окна графика). */
export function tradeDtWindow(trades: LogicTradeRow[]): { from: string; to: string } | null {
  const keys = trades
    .map((t) => dtKey(t.bar_dt || t.executed_at))
    .filter((k) => k.length >= 10)
    .sort();
  if (keys.length === 0) return null;
  return { from: keys[0], to: keys[keys.length - 1] };
}

export function tradesForSecurity(
  trades: LogicTradeRow[],
  securityId: number,
  dateFrom?: string | null,
  dateTo?: string | null
): LogicTradeRow[] {
  const fromKey = dateFrom ? `${dateFrom} 00:00:00` : null;
  const toKey = dateTo ? `${dateTo} 23:59:59` : null;
  return trades
    .filter((t) => {
      if (t.security_id !== securityId) return false;
      const key = dtKey(t.bar_dt || t.executed_at);
      if (fromKey && key < fromKey) return false;
      if (toKey && key > toKey) return false;
      return t.status === 'filled' || t.status === 'submitted';
    })
    .sort((a, b) => dtKey(a.bar_dt).localeCompare(dtKey(b.bar_dt)));
}

/** Бумаги, по которым были сделки в тесте. */
export function papersWithTrades(
  trades: LogicTradeRow[],
  dateFrom?: string | null,
  dateTo?: string | null
): {
  security_id: number;
  security_name: string;
  security_prefix: string | null;
  pnl: number;
  trade_count: number;
}[] {
  const map = new Map<
    number,
    {
      security_id: number;
      security_name: string;
      security_prefix: string | null;
      pnl: number;
      trade_count: number;
    }
  >();
  for (const t of trades) {
    if (t.status !== 'filled' && t.status !== 'submitted') continue;
    const key = dtKey(t.bar_dt || t.executed_at);
    if (dateFrom && key < `${dateFrom} 00:00:00`) continue;
    if (dateTo && key > `${dateTo} 23:59:59`) continue;
    const row = map.get(t.security_id) ?? {
      security_id: t.security_id,
      security_name: t.security_name,
      security_prefix: t.security_prefix,
      pnl: 0,
      trade_count: 0,
    };
    row.trade_count += 1;
    if (
      !t.is_shadow &&
      t.financial_result != null &&
      Number.isFinite(Number(t.financial_result))
    ) {
      row.pnl += Number(t.financial_result);
    }
    map.set(t.security_id, row);
  }
  return [...map.values()].sort((a, b) =>
    (a.security_prefix || a.security_name).localeCompare(
      b.security_prefix || b.security_name,
      'ru'
    )
  );
}

export function buildTradeMarkers(trades: LogicTradeRow[]): ChartTradeMarker[] {
  return trades.map((t) => ({
    dt: t.bar_dt || t.executed_at,
    price: Number(t.price),
    kind: t.side_name === 'Close' ? 'close' : 'open',
    side: t.action_name === 'Short' ? 'short' : 'long',
    isShadow: Boolean(t.is_shadow),
    label: t.trade_reason || undefined,
  }));
}

export function buildStopMarkers(trades: LogicTradeRow[]): ChartStopMarker[] {
  const out: ChartStopMarker[] = [];
  for (const t of trades) {
    if (t.side_name !== 'Close' || !t.trade_reason) continue;
    const reason = t.trade_reason.toLowerCase();
    let ruleKind: ChartStopMarker['ruleKind'] = 'other';
    if (reason.includes('stop_loss') || reason.startsWith('stop')) {
      ruleKind = 'stop_loss';
    } else if (reason.includes('take_profit') || reason.includes('take')) {
      ruleKind = 'take_profit';
    } else {
      continue;
    }
    out.push({
      dt: t.bar_dt || t.executed_at,
      price: Number(t.price),
      ruleKind,
      label: shortenStopLabel(t.trade_reason),
    });
  }
  return out;
}

function shortenStopLabel(reason: string): string {
  const s = reason.trim();
  if (s.length <= 42) return s;
  return `${s.slice(0, 40)}…`;
}

/**
 * Периоды отключения бумаги: is_shadow и пауза после stop_loss
 * до следующего обычного (не теневого) Open — бумага снова «вкл.».
 * Close во время паузы (в т.ч. хвост позиции) зону выкл. не снимает.
 */
export function buildShadedDisabledRanges(trades: LogicTradeRow[]): ChartShadedRange[] {
  const sorted = [...trades].sort((a, b) =>
    dtKey(a.bar_dt || a.executed_at).localeCompare(dtKey(b.bar_dt || b.executed_at))
  );
  const ranges: ChartShadedRange[] = [];
  let start: string | null = null;
  let lastOffDt: string | null = null;

  const flush = (endDt: string) => {
    if (!start) return;
    const end = endDt || lastOffDt || start;
    if (dtKey(end) < dtKey(start)) return;
    ranges.push({
      startDt: start,
      endDt: end,
      label: 'выкл.',
    });
    start = null;
    lastOffDt = null;
  };

  for (const t of sorted) {
    const dt = t.bar_dt || t.executed_at;
    const reason = (t.trade_reason || '').toLowerCase();
    const stopPause =
      t.side_name === 'Close' &&
      (reason.includes('stop_loss') || reason.includes('security_resume'));

    if (t.is_shadow || stopPause) {
      if (!start) start = dt;
      lastOffDt = dt;
      continue;
    }
    if (start) {
      if (t.side_name === 'Open') {
        flush(dt);
      } else {
        // Реальный Close в паузе — зона выкл. продолжается
        lastOffDt = dt;
      }
    }
  }
  if (start && lastOffDt) {
    flush(lastOffDt);
  }
  return ranges;
}

/** Кумулятивный PnL по закрытиям (!shadow), старт 0 с первой сделки бумаги. */
export function buildEquityPoints(trades: LogicTradeRow[]): ChartEquityPoint[] {
  const sorted = [...trades].sort((a, b) =>
    dtKey(a.bar_dt || a.executed_at).localeCompare(dtKey(b.bar_dt || b.executed_at))
  );
  const closes = sorted.filter(
    (t) =>
      t.side_name === 'Close' &&
      !t.is_shadow &&
      t.financial_result != null &&
      Number.isFinite(Number(t.financial_result))
  );
  if (closes.length === 0) return [];

  const firstDt = sorted[0]?.bar_dt || sorted[0]?.executed_at || closes[0].bar_dt;
  let cum = 0;
  const points: ChartEquityPoint[] = [{ dt: firstDt, value: 0 }];
  for (const t of closes) {
    cum += Number(t.financial_result);
    const dt = t.bar_dt || t.executed_at;
    // Не дублировать точку 0 на том же dt, если первое закрытие = первая сделка
    if (points.length === 1 && dtKey(points[0].dt) === dtKey(dt) && points[0].value === 0) {
      points[0] = { dt, value: cum };
    } else {
      points.push({ dt, value: cum });
    }
  }
  return points;
}

/** Свеча строго внутри зоны «выкл.» (границы оставляем для шага PnL). */
export function isDtInsideDisabledShade(
  dt: string,
  ranges: ChartShadedRange[]
): boolean {
  const key = dtKey(dt);
  for (const r of ranges) {
    const a = dtKey(r.startDt);
    const b = dtKey(r.endDt);
    if (key > a && key < b) return true;
  }
  return false;
}
