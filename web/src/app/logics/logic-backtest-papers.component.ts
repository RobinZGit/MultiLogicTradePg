import { CommonModule } from '@angular/common';
import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  Input,
  OnChanges,
  OnDestroy,
  SimpleChanges,
  inject,
} from '@angular/core';
import { Subscription, of } from 'rxjs';
import { catchError, finalize } from 'rxjs/operators';
import { PriceChartComponent } from '../price-chart/price-chart.component';
import {
  ChartEquityPoint,
  ChartIndicatorSeries,
  ChartShadedRange,
  ChartStopMarker,
  ChartTradeMarker,
  ChartVisibleRange,
  IndicatorValueRow,
  PriceCandle,
} from '../models/market.model';
import { SecuritiesService } from '../services/securities.service';
import { LogicTradeRow } from '../shared/logic-trade';
import {
  buildEquityPoints,
  buildShadedDisabledRanges,
  buildStopMarkers,
  buildTradeMarkers,
  dtKey,
  papersWithTrades,
  tradeDtWindow,
  tradesForSecurity,
} from './backtest-chart-overlays';

export interface BacktestPaperRow {
  security_id: number;
  security_name: string;
  security_prefix: string | null;
  pnl: number;
  trade_count: number;
}

function humanizeChartLoadError(err: unknown): string {
  const e = err as { name?: string; message?: string; error?: { error?: string } };
  if (
    e?.name === 'TimeoutError' ||
    /timeout/i.test(e?.message || '') ||
    /timeout/i.test(e?.error?.error || '')
  ) {
    return 'Сервер не ответил вовремя — раскройте бумагу ещё раз';
  }
  return e?.error?.error || e?.message || 'Не удалось загрузить цены';
}

interface PaperOverlays {
  markers: ChartTradeMarker[];
  stops: ChartStopMarker[];
  shaded: ChartShadedRange[];
  equity: ChartEquityPoint[];
}

interface PaperChartState {
  candles: PriceCandle[];
  loading: boolean;
  loadingOlder: boolean;
  hasMore: boolean;
  error: string | null;
  status: string | null;
  focusDt: string | null;
  indicatorSeries: ChartIndicatorSeries[];
  suppressIndicators: boolean;
  syncGen: number;
  lastRangeKey: string;
}

const EMPTY_SERIES: ChartIndicatorSeries[] = [];
const SERIES_COLORS = [
  '#2563eb',
  '#9333ea',
  '#ea580c',
  '#0891b2',
  '#ca8a04',
  '#db2777',
  '#059669',
  '#4f46e5',
];
const PRICE_SCALE_CODES = new Set(['SMA', 'EMA', 'WMA', 'PACC', 'SMAT3']);
const MAX_CANDLES = 900;
const MAX_LOAD_PAGES = 12;

@Component({
  selector: 'app-logic-backtest-papers',
  standalone: true,
  imports: [CommonModule, PriceChartComponent],
  templateUrl: './logic-backtest-papers.component.html',
  styleUrl: './logic-backtest-papers.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class LogicBacktestPapersComponent implements OnChanges, OnDestroy {
  private readonly securitiesApi = inject(SecuritiesService);
  private readonly cdr = inject(ChangeDetectorRef);

  @Input() trades: LogicTradeRow[] = [];
  @Input() dateFrom: string | null = null;
  @Input() dateTo: string | null = null;
  @Input() timeframeId: number | null = null;
  @Input() signalIndicatorIds: number[] = [];

  expandedPapers = false;
  expandedSecurityIds = new Set<number>();

  paperRows: BacktestPaperRow[] = [];
  private overlaysBySec = new Map<number, PaperOverlays>();
  private charts = new Map<number, PaperChartState>();
  private rangeTimers = new Map<number, ReturnType<typeof setTimeout>>();
  private subs = new Subscription();
  private uniqueIndicatorIds: number[] = [];

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['signalIndicatorIds']) {
      this.uniqueIndicatorIds = [
        ...new Set(this.signalIndicatorIds.filter((id) => id != null).map(Number)),
      ];
    }
    if (changes['trades'] || changes['dateFrom'] || changes['dateTo']) {
      this.rebuildPaperCache();
    }
  }

  ngOnDestroy(): void {
    this.subs.unsubscribe();
    for (const t of this.rangeTimers.values()) clearTimeout(t);
  }

  togglePapersBlock(event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    this.expandedPapers = !this.expandedPapers;
    if (this.expandedPapers && this.paperRows.length === 0) {
      this.rebuildPaperCache();
    }
  }

  isPaperExpanded(securityId: number): boolean {
    return this.expandedSecurityIds.has(securityId);
  }

  togglePaper(event: Event, securityId: number): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedSecurityIds.has(securityId)) {
      this.expandedSecurityIds.delete(securityId);
      return;
    }
    this.expandedSecurityIds.add(securityId);
    // Сразу показать контейнер, загрузку — следующим тиком.
    this.ensureChartLoaded(securityId);
  }

  chartState(securityId: number): PaperChartState {
    let st = this.charts.get(securityId);
    if (!st) {
      st = {
        candles: [],
        loading: false,
        loadingOlder: false,
        hasMore: true,
        error: null,
        status: null,
        focusDt: null,
        indicatorSeries: [],
        suppressIndicators: false,
        syncGen: 0,
        lastRangeKey: '',
      };
      this.charts.set(securityId, st);
    }
    return st;
  }

  chartIndicatorsForDisplay(securityId: number): ChartIndicatorSeries[] {
    const st = this.chartState(securityId);
    if (st.suppressIndicators) return EMPTY_SERIES;
    return st.indicatorSeries;
  }

  overlays(securityId: number): PaperOverlays {
    let o = this.overlaysBySec.get(securityId);
    if (!o) {
      o = { markers: [], stops: [], shaded: [], equity: [] };
      this.overlaysBySec.set(securityId, o);
    }
    return o;
  }

  formatPnl(value: number): string {
    const sign = value > 0 ? '+' : '';
    return `${sign}${value.toFixed(2)}`;
  }

  onLoadOlder(securityId: number): void {
    const tfId = this.resolveTimeframeId(securityId);
    const st = this.chartState(securityId);
    if (!tfId || st.loadingOlder || !st.hasMore || st.candles.length === 0) return;
    const before = st.candles[0].dt;
    st.loadingOlder = true;
    // Timeout/сеть — тихо; не пишем на график и не режем hasMore.
    let softFail = false;
    const sub = this.securitiesApi
      .getPrices(securityId, tfId, 120, before)
      .pipe(
        catchError(() => {
          softFail = true;
          return of([] as PriceCandle[]);
        }),
        finalize(() => {
          st.loadingOlder = false;
          this.cdr.detectChanges();
        })
      )
      .subscribe({
        next: (rows) => {
          if (rows.length === 0) {
            if (!softFail) st.hasMore = false;
            return;
          }
          const merged = [...rows, ...st.candles];
          st.candles = merged.length > MAX_CANDLES ? merged.slice(-MAX_CANDLES) : merged;
          // Маркеры / PnL / стопы — из кэша overlays, перерисуются со свечами.
          this.cdr.detectChanges();
        },
      });
    this.subs.add(sub);
  }

  onVisibleRange(securityId: number, range: ChartVisibleRange): void {
    // Индикаторы — фоном; маркеры/PnL/стопы рисуются из кэша сделок без HTTP.
    if (!range.userInitiated) {
      this.loadIndicatorValues(securityId, range);
      return;
    }
    const st = this.chartState(securityId);
    st.suppressIndicators = true;
    this.cdr.detectChanges();
    const prev = this.rangeTimers.get(securityId);
    if (prev) clearTimeout(prev);
    const timer = setTimeout(() => this.loadIndicatorValues(securityId, range), 650);
    this.rangeTimers.set(securityId, timer);
  }

  private resolveTimeframeId(securityId: number): number | null {
    if (this.timeframeId != null && Number.isFinite(Number(this.timeframeId))) {
      return Number(this.timeframeId);
    }
    const fromTrade = this.trades.find((t) => t.security_id === securityId)?.timeframe_id;
    if (fromTrade != null && Number.isFinite(Number(fromTrade))) {
      return Number(fromTrade);
    }
    const any = this.trades.find((t) => t.timeframe_id != null)?.timeframe_id;
    return any != null ? Number(any) : null;
  }

  private rebuildPaperCache(): void {
    this.paperRows = papersWithTrades(this.trades, this.dateFrom, this.dateTo);
    this.overlaysBySec.clear();
    for (const paper of this.paperRows) {
      const secTrades = tradesForSecurity(
        this.trades,
        paper.security_id,
        this.dateFrom,
        this.dateTo
      );
      this.overlaysBySec.set(paper.security_id, {
        markers: buildTradeMarkers(secTrades),
        stops: buildStopMarkers(secTrades),
        shaded: buildShadedDisabledRanges(secTrades),
        equity: buildEquityPoints(secTrades, this.dateFrom),
      });
    }
  }

  private ensureChartLoaded(securityId: number): void {
    const st = this.chartState(securityId);
    const tfId = this.resolveTimeframeId(securityId);
    if (!tfId) {
      st.error = 'Не задан таймфрейм логики (и нет timeframe_id в сделках)';
      st.status = null;
      st.loading = false;
      return;
    }
    if (st.candles.length > 0 || st.loading) return;

    const secTrades = tradesForSecurity(
      this.trades,
      securityId,
      this.dateFrom,
      this.dateTo
    );
    const win = tradeDtWindow(secTrades);
    // Грузим от конца окна сделок (или date_to), затем догружаем до начала теста (PnL с нуля).
    const endKey = win?.to || (this.dateTo ? `${this.dateTo} 23:59:59` : null);
    const before = endKey ? endKey.replace(' ', 'T') : undefined;
    st.focusDt = win?.to ?? null;
    const coverFrom = this.periodCoverFrom(win?.from ?? null);

    st.loading = true;
    st.error = null;
    st.status = win
      ? `Загрузка свечей вокруг сделок ${win.from.slice(0, 10)}…${win.to.slice(0, 10)}`
      : `Загрузка свечей (tf=${tfId})…`;

    const sub = this.securitiesApi
      .getPrices(securityId, tfId, 200, before)
      .pipe(
        catchError((err) => {
          st.error = humanizeChartLoadError(err);
          return of([] as PriceCandle[]);
        })
      )
      .subscribe({
        next: (rows) => {
          if (rows.length === 0 && before) {
            st.status = 'Повторная загрузка свечей без фильтра даты…';
            const retry = this.securitiesApi.getPrices(securityId, tfId, 200).subscribe({
              next: (retryRows) =>
                this.finishCandleLoad(securityId, st, retryRows, coverFrom),
              error: (err) => {
                st.loading = false;
                st.error = humanizeChartLoadError(err);
                st.status = null;
                this.cdr.detectChanges();
              },
            });
            this.subs.add(retry);
            return;
          }
          this.finishCandleLoad(securityId, st, rows, coverFrom);
        },
        error: () => {
          st.loading = false;
          this.cdr.detectChanges();
        },
      });
    this.subs.add(sub);
  }

  /** Начало покрытия свечей: date_from теста (якорь PnL=0), иначе первая сделка. */
  private periodCoverFrom(firstTradeDt: string | null): string | null {
    if (this.dateFrom) {
      const d = String(this.dateFrom).trim();
      if (/^\d{4}-\d{2}-\d{2}$/.test(d)) return `${d} 00:00:00`;
      return d;
    }
    return firstTradeDt;
  }

  /** Догрузить историю до начала теста / первой сделки (PnL и маркеры в окне). */
  private finishCandleLoad(
    securityId: number,
    st: PaperChartState,
    rows: PriceCandle[],
    coverFrom: string | null
  ): void {
    st.candles = rows;
    st.hasMore = rows.length >= 200;
    if (rows.length === 0) {
      st.loading = false;
      st.error = st.error || 'В БД нет свечей для этой бумаги / таймфрейма';
      st.status = null;
      this.cdr.detectChanges();
      return;
    }

    const needFrom = coverFrom ? dtKey(coverFrom) : null;
    const firstKey = dtKey(st.candles[0].dt);
    if (!needFrom || firstKey <= needFrom || !st.hasMore) {
      this.applyCandles(securityId, st, st.candles);
      return;
    }

    st.status = `Догрузка истории до ${needFrom.slice(0, 16)}…`;
    this.loadOlderUntilCovered(securityId, st, needFrom, 1);
  }

  private loadOlderUntilCovered(
    securityId: number,
    st: PaperChartState,
    needFrom: string,
    page: number
  ): void {
    const tfId = this.resolveTimeframeId(securityId);
    if (!tfId || page > MAX_LOAD_PAGES || st.candles.length === 0) {
      this.applyCandles(securityId, st, st.candles);
      return;
    }
    const before = st.candles[0].dt;
    const sub = this.securitiesApi.getPrices(securityId, tfId, 200, before).subscribe({
      next: (older) => {
        if (older.length === 0) {
          st.hasMore = false;
          this.applyCandles(securityId, st, st.candles);
          return;
        }
        const merged = [...older, ...st.candles];
        // Не отбрасывать «хвост» со сделками: при обрезке оставляем конец массива.
        st.candles =
          merged.length > MAX_CANDLES ? merged.slice(merged.length - MAX_CANDLES) : merged;
        st.hasMore = older.length >= 200;
        const firstKey = dtKey(st.candles[0].dt);
        // Если упёрлись в лимит и всё ещё не покрыли — обрежем окно вокруг сделок ниже в apply.
        if (firstKey <= needFrom || !st.hasMore || st.candles.length >= MAX_CANDLES) {
          this.applyCandles(securityId, st, st.candles);
          return;
        }
        st.status = `Догрузка истории (${st.candles.length} свечей)…`;
        this.cdr.detectChanges();
        this.loadOlderUntilCovered(securityId, st, needFrom, page + 1);
      },
      error: () => this.applyCandles(securityId, st, st.candles),
    });
    this.subs.add(sub);
  }

  private applyCandles(
    securityId: number,
    st: PaperChartState,
    rows: PriceCandle[]
  ): void {
    st.candles = rows;
    st.hasMore = rows.length >= 200;
    st.loading = false;
    const ov = this.overlays(securityId);
    st.error = rows.length === 0 ? 'В БД нет свечей для этой бумаги / таймфрейма' : null;
    st.status =
      rows.length > 0
        ? `${rows.length} свечей · сделок: ${ov.markers.length} · стопов: ${ov.stops.length}`
        : null;
    if (!st.focusDt && ov.markers.length > 0) {
      st.focusDt = ov.markers[ov.markers.length - 1].dt;
    }
    this.cdr.detectChanges();
    if (rows.length > 0) {
      this.loadIndicatorValues(securityId, {
        startDt: rows[0].dt,
        endDt: rows[rows.length - 1].dt,
        count: rows.length,
        viewStart: 0,
        userInitiated: false,
      });
    }
  }

  /** Только GET indicator-values — без sync POST (не блокируем UI). */
  private loadIndicatorValues(securityId: number, range: ChartVisibleRange): void {
    const tfId = this.resolveTimeframeId(securityId);
    if (!tfId || this.uniqueIndicatorIds.length === 0) {
      const st = this.chartState(securityId);
      st.suppressIndicators = false;
      st.indicatorSeries = EMPTY_SERIES;
      return;
    }
    if (!range.startDt || !range.endDt) return;
    const st = this.chartState(securityId);
    if (st.candles.length === 0) return;

    const rangeKey = `${range.startDt}|${range.endDt}|${this.uniqueIndicatorIds.join(',')}`;
    if (rangeKey === st.lastRangeKey && st.indicatorSeries.length > 0 && !range.userInitiated) {
      st.suppressIndicators = false;
      return;
    }

    const syncGen = ++st.syncGen;
    const sub = this.securitiesApi
      .getIndicatorValues(
        securityId,
        tfId,
        this.uniqueIndicatorIds,
        range.startDt,
        range.endDt
      )
      .pipe(
        // Timeout при перемотке — тихо, без баннера на графике
        catchError(() => of([] as IndicatorValueRow[]))
      )
      .subscribe({
        next: (values) => {
          if (syncGen !== st.syncGen) return;
          if (values.length > 0) {
            st.indicatorSeries = this.buildChartSeries(values);
            st.lastRangeKey = rangeKey;
          }
          st.suppressIndicators = false;
          this.cdr.detectChanges();
        },
      });
    this.subs.add(sub);
  }

  private buildChartSeries(values: IndicatorValueRow[]): ChartIndicatorSeries[] {
    const groups = new Map<string, IndicatorValueRow[]>();
    for (const v of values) {
      if (!this.uniqueIndicatorIds.includes(v.indicator_id)) continue;
      const key = `${v.indicator_id}:${v.line_code}`;
      const list = groups.get(key) ?? [];
      list.push(v);
      groups.set(key, list);
    }
    const series: ChartIndicatorSeries[] = [];
    let colorIdx = 0;
    for (const key of groups.keys()) {
      const rows = groups.get(key)!;
      const sample = rows[0];
      const onPrice =
        (PRICE_SCALE_CODES.has(sample.indicator_code) && sample.line_code === 'VALUE') ||
        (sample.indicator_code === 'BB' &&
          ['UPPER', 'MIDDLE', 'LOWER'].includes(sample.line_code));
      series.push({
        indicator_code: sample.indicator_code,
        line_code: sample.line_code,
        line_name: sample.line_name,
        color: SERIES_COLORS[colorIdx % SERIES_COLORS.length],
        on_price_scale: onPrice,
        is_threshold: sample.is_threshold,
        points: rows.map((r) => ({ dt: r.dt, value: Number(r.value) })),
      });
      if (!sample.is_threshold) colorIdx += 1;
    }
    return series;
  }
}
