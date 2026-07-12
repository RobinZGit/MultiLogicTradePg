import { Component, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { finalize, forkJoin, switchMap } from 'rxjs';
import { ReferencesService } from '../services/references.service';
import { SecuritiesService } from '../services/securities.service';
import { ExchangeRow } from '../models/lookup.model';
import {
  ChartIndicatorSeries,
  ChartVisibleRange,
  IndicatorValueRow,
  PriceCandle,
  PriceLoadResult,
  PriceLoadUiState,
  SecurityChartState,
  SecurityIndicatorSeriesRow,
  SecurityRow,
  TimeframeRow,
} from '../models/market.model';
import {
  AppConfigService,
  logicsLoadErrorMessage,
} from '../services/app-config.service';
import { PriceChartComponent } from '../price-chart/price-chart.component';
import { SecurityEditorComponent } from '../security-editor/security-editor.component';

@Component({
  selector: 'app-securities-panel',
  standalone: true,
  imports: [
    CommonModule,
    FormsModule,
    PriceChartComponent,
    SecurityEditorComponent,
  ],
  templateUrl: './securities-panel.component.html',
  styleUrl: './securities-panel.component.css',
})
export class SecuritiesPanelComponent implements OnInit {
  exchanges: ExchangeRow[] = [];
  timeframes: TimeframeRow[] = [];

  exchangeId: number | null = null;
  timeframeId: number | null = null;

  stocks: SecurityRow[] = [];
  futures: SecurityRow[] = [];

  stocksExpanded = false;
  futuresExpanded = false;
  expandedSecurities = new Set<number>();

  charts = new Map<number, SecurityChartState>();
  priceLoads = new Map<number, PriceLoadUiState>();
  securityIndicatorSeries = new Map<number, SecurityIndicatorSeriesRow[]>();
  indicatorSeries = new Map<number, ChartIndicatorSeries[]>();
  indicatorsLoading = new Set<number>();
  /** Drag-and-drop: привязка серии к бумаге (быстрый POST без полного sync). */
  indicatorAssigning = new Set<number>();
  indicatorCalcError = new Map<number, string | null>();
  dropTargetId: number | null = null;
  private loadAbort = new Map<number, boolean>();
  private emptyChunks = new Map<number, number>();
  private visibleRangeTimers = new Map<number, ReturnType<typeof setTimeout>>();

  private readonly chunkDays = 7;
  private readonly maxDaysBack = 365 * 3;
  private readonly maxEmptyChunks = 5;
  private readonly maxIndicatorCandles = 150;
  private readonly seriesColors = [
    '#2563eb',
    '#9333ea',
    '#ea580c',
    '#0891b2',
    '#ca8a04',
    '#db2777',
    '#059669',
    '#4f46e5',
  ];
  /** Индикаторы с серией VALUE на шкале цены (SMA, PACC, пользовательские …) */
  private readonly priceScaleOverlayCodes = new Set([
    'SMA',
    'EMA',
    'WMA',
    'PACC',
    'SMAT3',
  ]);

  loading = true;
  error: string | null = null;

  editorOpen = false;
  editorKind: 'stock' | 'futures' = 'stock';

  constructor(
    private readonly refs: ReferencesService,
    private readonly securities: SecuritiesService,
    private readonly appConfig: AppConfigService
  ) {}

  ngOnInit(): void {
    this.loadMeta();
  }

  get exchangeName(): string {
    return this.exchanges.find((e) => e.id === this.exchangeId)?.name ?? '';
  }

  chartState(id: number): SecurityChartState {
    return (
      this.charts.get(id) ?? {
        candles: [],
        loading: false,
        loadingOlder: false,
        hasMore: true,
        error: null,
      }
    );
  }

  assignedIndicatorSeries(id: number): SecurityIndicatorSeriesRow[] {
    return this.securityIndicatorSeries.get(id) ?? [];
  }

  chartIndicatorSeries(id: number): ChartIndicatorSeries[] {
    return this.indicatorSeries.get(id) ?? [];
  }

  isIndicatorsLoading(id: number): boolean {
    return this.indicatorsLoading.has(id) || this.indicatorAssigning.has(id);
  }

  indicatorStatus(id: number): string | null {
    if (this.indicatorAssigning.has(id)) {
      return 'Добавление индикатора…';
    }
    if (this.indicatorsLoading.has(id)) {
      return 'Расчёт индикаторов…';
    }
    return null;
  }

  indicatorError(id: number): string | null {
    return this.indicatorCalcError.get(id) ?? null;
  }

  isDropTarget(id: number): boolean {
    return this.dropTargetId === id;
  }

  onDragOver(event: DragEvent, securityId: number): void {
    event.preventDefault();
    if (event.dataTransfer) {
      event.dataTransfer.dropEffect = 'copy';
    }
    this.dropTargetId = securityId;
  }

  onDragLeave(event: DragEvent, securityId: number): void {
    const related = event.relatedTarget as Node | null;
    const current = event.currentTarget as Node;
    if (related && current.contains(related)) return;
    if (this.dropTargetId === securityId) {
      this.dropTargetId = null;
    }
  }

  onDrop(event: DragEvent, row: SecurityRow): void {
    event.preventDefault();
    event.stopPropagation();
    this.dropTargetId = null;
    const raw = event.dataTransfer?.getData('application/x-indicator-id');
    const indicatorId = raw ? parseInt(raw, 10) : NaN;
    if (!Number.isInteger(indicatorId) || indicatorId <= 0) return;
    this.assignIndicator(row, indicatorId);
  }

  removeIndicatorSeries(assignment: SecurityIndicatorSeriesRow, event: Event): void {
    event.stopPropagation();
    this.securities.removeIndicatorSeries(assignment.id).subscribe({
      next: () => {
        const list = (
          this.securityIndicatorSeries.get(assignment.security_id) ?? []
        ).filter((x) => x.id !== assignment.id);
        this.securityIndicatorSeries.set(assignment.security_id, list);
        if (this.expandedSecurities.has(assignment.security_id)) {
          this.refreshIndicatorChart(assignment.security_id);
        }
      },
      error: (err) => {
        console.error(err);
      },
    });
  }

  seriesLabel(row: SecurityIndicatorSeriesRow): string {
    const code = row.series_code === 'VALUE' ? '' : ` ${row.series_code}`;
    return `${row.indicator_code}${code} — ${row.indicator_name}`;
  }

  private assignIndicator(row: SecurityRow, indicatorId: number): void {
    if (!this.timeframeId) return;
    this.indicatorAssigning.add(row.id);
    this.indicatorCalcError.set(row.id, null);
    this.securities
      .assignIndicatorSeries(row.id, indicatorId, this.timeframeId)
      .subscribe({
        next: (created) => {
          this.indicatorAssigning.delete(row.id);
          const list = [...(this.securityIndicatorSeries.get(row.id) ?? [])];
          for (const s of created) {
            if (!list.some((x) => x.id === s.id)) {
              list.push(s);
            }
          }
          this.securityIndicatorSeries.set(row.id, list);
          if (!this.expandedSecurities.has(row.id)) {
            this.expandedSecurities.add(row.id);
            this.loadChart(row.id, false);
          } else {
            this.refreshIndicatorChart(row.id);
          }
        },
        error: (err) => {
          this.indicatorAssigning.delete(row.id);
          const msg =
            err?.name === 'TimeoutError'
              ? 'Таймаут при добавлении индикатора'
              : err?.error?.error || err?.message || 'Ошибка добавления индикатора';
          this.indicatorCalcError.set(row.id, msg);
          console.error(err);
        },
      });
  }

  private refreshIndicatorChart(securityId: number): void {
    const candles = this.chartState(securityId).candles;
    if (candles.length === 0) {
      this.indicatorSeries.set(securityId, []);
      return;
    }
    const end = candles.length - 1;
    const start = Math.max(0, end - this.maxIndicatorCandles + 1);
    this.syncIndicatorsForRange(
      securityId,
      {
        startDt: candles[start].dt,
        endDt: candles[end].dt,
        count: end - start + 1,
        viewStart: start,
      },
      { incremental: true }
    );
  }

  isSecurityExpanded(id: number): boolean {
    return this.expandedSecurities.has(id);
  }

  toggleGroup(kind: 'stock' | 'futures'): void {
    if (kind === 'stock') {
      this.stocksExpanded = !this.stocksExpanded;
    } else {
      this.futuresExpanded = !this.futuresExpanded;
    }
  }

  toggleSecurity(row: SecurityRow): void {
    if (this.expandedSecurities.has(row.id)) {
      this.expandedSecurities.delete(row.id);
      return;
    }
    this.expandedSecurities.add(row.id);
    this.charts.set(row.id, {
      candles: [],
      loading: true,
      loadingOlder: false,
      hasMore: true,
      error: null,
    });
    this.indicatorSeries.set(row.id, []);
    this.indicatorCalcError.set(row.id, null);
    this.indicatorsLoading.delete(row.id);

    this.loadChart(row.id, false);
    this.securities.getSecurityIndicatorSeries(row.id).subscribe({
      next: (rows) => {
        this.securityIndicatorSeries.set(row.id, rows);
        this.refreshIndicatorChart(row.id);
      },
      error: () => {
        this.securityIndicatorSeries.set(row.id, []);
      },
    });
  }

  onExchangeChange(): void {
    this.expandedSecurities.clear();
    this.charts.clear();
    this.securityIndicatorSeries.clear();
    this.indicatorSeries.clear();
    this.loadSecurities();
  }

  onTimeframeChange(): void {
    for (const id of [...this.expandedSecurities]) {
      this.charts.set(id, {
        candles: [],
        loading: true,
        loadingOlder: false,
        hasMore: true,
        error: null,
      });
      this.loadChart(id, false, { fullIndicatorRefresh: true });
    }
  }

  openAdd(kind: 'stock' | 'futures'): void {
    this.editorKind = kind;
    this.editorOpen = true;
  }

  onSecuritySaved(): void {
    this.loadSecurities();
  }

  onLoadOlder(securityId: number): void {
    const state = this.chartState(securityId);
    if (state.loadingOlder || !state.hasMore || state.candles.length === 0) {
      return;
    }
    this.loadChart(securityId, true);
  }

  onChartVisibleRange(securityId: number, range: ChartVisibleRange): void {
    if (!range.startDt || !range.endDt || range.count <= 0) return;
    const prev = this.visibleRangeTimers.get(securityId);
    if (prev) clearTimeout(prev);
    this.visibleRangeTimers.set(
      securityId,
      setTimeout(() => {
        this.syncIndicatorsForRange(securityId, range, { incremental: true });
      }, 300)
    );
  }

  onRecalcIndicators(securityId: number, range: ChartVisibleRange): void {
    if (!range.startDt || !range.endDt || range.count <= 0) return;
    this.syncIndicatorsForRange(securityId, range, { incremental: false });
  }

  priceLoadState(id: number): PriceLoadUiState {
    return (
      this.priceLoads.get(id) ?? {
        active: false,
        message: null,
        error: null,
      }
    );
  }

  isPriceLoadActive(id: number): boolean {
    return this.priceLoadState(id).active;
  }

  startLoadPrices(row: SecurityRow, event: Event): void {
    event.stopPropagation();
    if (!this.timeframeId || this.isPriceLoadActive(row.id)) return;

    this.loadAbort.set(row.id, true);
    this.emptyChunks.set(row.id, 0);
    this.priceLoads.set(row.id, {
      active: true,
      message: 'Загрузка с сегодня назад…',
      error: null,
    });

    const today = this.todayDate();
    this.loadNextChunk(row.id, today, 0);
  }

  stopLoadPrices(row: SecurityRow, event: Event): void {
    event.stopPropagation();
    this.loadAbort.set(row.id, false);
    const prev = this.priceLoadState(row.id);
    this.priceLoads.set(row.id, {
      active: false,
      message: 'Остановлено пользователем',
      error: prev.error,
    });
  }

  private loadNextChunk(
    securityId: number,
    cursorTo: Date,
    daysBack: number
  ): void {
    if (!this.loadAbort.get(securityId) || !this.timeframeId) {
      this.finishPriceLoad(securityId, 'Остановлено');
      return;
    }
    if (daysBack >= this.maxDaysBack) {
      this.finishPriceLoad(securityId, 'Достигнут предел истории (3 года)');
      return;
    }

    const dateTo = this.formatDate(cursorTo);
    const dateFromDate = new Date(cursorTo);
    dateFromDate.setDate(dateFromDate.getDate() - this.chunkDays);
    const dateFrom = this.formatDate(dateFromDate);

    this.securities
      .loadPrices({
        security_id: securityId,
        timeframe_id: this.timeframeId!,
        date_from: dateFrom,
        date_to: dateTo,
      })
      .subscribe({
        next: (res) => {
          if (!this.loadAbort.get(securityId)) {
            this.finishPriceLoad(securityId, 'Остановлено');
            return;
          }

          this.priceLoads.set(securityId, {
            active: true,
            message: this.formatLoadMessage(res, dateFrom, dateTo),
            error: null,
          });

          if ((res.records_loaded ?? 0) === 0 && res.candles === 0) {
            const streak = (this.emptyChunks.get(securityId) ?? 0) + 1;
            this.emptyChunks.set(securityId, streak);
            if (streak >= this.maxEmptyChunks) {
              const hint =
                res.tbank?.error || res.moex?.error
                  ? ` ${res.tbank?.error || res.moex?.error}`
                  : '';
              this.finishPriceLoad(
                securityId,
                `Нет данных за ${streak} периодов подряд — остановлено${hint}`
              );
              return;
            }
          } else {
            this.emptyChunks.set(securityId, 0);
          }

          if (this.expandedSecurities.has(securityId)) {
            this.loadChart(securityId, false);
          }

          const nextCursor = new Date(dateFromDate);
          nextCursor.setDate(nextCursor.getDate() - 1);
          this.loadNextChunk(securityId, nextCursor, daysBack + this.chunkDays);
        },
        error: (err) => {
          this.loadAbort.set(securityId, false);
          const msg =
            err?.name === 'TimeoutError'
              ? 'Таймаут загрузки (PostgreSQL/API). Перезапустите Start.bat или проверьте блокировки в БД.'
              : err?.error?.error ||
                err?.message ||
                'Ошибка загрузки цен (T-Bank / MOEX)';
          this.priceLoads.set(securityId, {
            active: false,
            message: null,
            error: msg,
          });
        },
      });
  }

  private finishPriceLoad(securityId: number, message: string): void {
    this.loadAbort.set(securityId, false);
    const prev = this.priceLoadState(securityId);
    this.priceLoads.set(securityId, {
      active: false,
      message,
      error: prev.error,
    });
  }

  private todayDate(): Date {
    const now = new Date();
    return new Date(now.getFullYear(), now.getMonth(), now.getDate());
  }

  private formatDate(d: Date): string {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }

  private loadMeta(): void {
    this.loading = true;
    forkJoin({
      exchanges: this.refs.getExchanges(),
      timeframes: this.securities.getTimeframes(),
      indicators: this.refs.getIndicators(true),
    }).subscribe({
      next: ({ exchanges, timeframes, indicators }) => {
        this.exchanges = exchanges;
        this.timeframes = timeframes;
        for (const ind of indicators) {
          if (ind.is_custom && ind.formula) {
            this.priceScaleOverlayCodes.add(ind.code);
          }
        }
        this.exchangeId =
          exchanges.find((e) => e.name === 'MOEX')?.id ?? exchanges[0]?.id ?? null;
        const m15 = timeframes.find((t) => t.tf === 'M15');
        this.timeframeId = m15?.id ?? timeframes[0]?.id ?? null;
        this.loadSecurities();
      },
      error: (err) => {
        this.loading = false;
        this.error = logicsLoadErrorMessage(this.appConfig.apiUrl, err);
      },
    });
  }

  private loadSecurities(): void {
    if (!this.exchangeId) {
      this.loading = false;
      return;
    }
    this.loading = true;
    forkJoin({
      stocks: this.securities.getSecurities(this.exchangeId, 'stock'),
      futures: this.securities.getSecurities(this.exchangeId, 'futures'),
    }).subscribe({
      next: ({ stocks, futures }) => {
        this.stocks = stocks;
        this.futures = futures;
        this.loading = false;
        this.error = null;
      },
      error: (err) => {
        this.loading = false;
        this.error = logicsLoadErrorMessage(this.appConfig.apiUrl, err);
      },
    });
  }

  private loadChart(
    securityId: number,
    older: boolean,
    opts?: { fullIndicatorRefresh?: boolean }
  ): void {
    if (!this.timeframeId) return;
    const prev = this.chartState(securityId);
    const before =
      older && prev.candles.length > 0 ? prev.candles[0].dt : undefined;

    this.charts.set(securityId, {
      ...prev,
      loading: !older,
      loadingOlder: older,
      error: null,
    });

    this.securities
      .getPrices(securityId, this.timeframeId, 120, before)
      .subscribe({
        next: (rows: PriceCandle[]) => {
          const merged = older ? [...rows, ...prev.candles] : rows;
          const dedup = this.dedupeCandles(merged);
          this.charts.set(securityId, {
            candles: dedup,
            loading: false,
            loadingOlder: false,
            hasMore: rows.length >= 120,
            error:
              dedup.length === 0
                ? 'Нет свечей — нажмите «Загрузить цены»'
                : null,
          });
          if (dedup.length > 0) {
            const end = dedup.length - 1;
            const start = Math.max(0, end - this.maxIndicatorCandles + 1);
            this.syncIndicatorsForRange(
              securityId,
              {
                startDt: dedup[start].dt,
                endDt: dedup[end].dt,
                count: end - start + 1,
                viewStart: start,
              },
              { incremental: !opts?.fullIndicatorRefresh }
            );
          } else {
            this.indicatorSeries.set(securityId, []);
          }
        },
        error: (err) => {
          this.charts.set(securityId, {
            ...prev,
            loading: false,
            loadingOlder: false,
            error: err?.error?.error || err?.message || 'Ошибка загрузки цен',
          });
        },
      });
  }

  private formatLoadMessage(
    res: PriceLoadResult,
    dateFrom: string,
    dateTo: string
  ): string {
    const parts: string[] = [];
    if (res.tbank) {
      const tb = `T-Bank: ${res.tbank.records ?? 0}`;
      parts.push(res.tbank.error ? `${tb} (${res.tbank.error})` : tb);
    }
    if (res.moex) {
      const mx = `MOEX: ${res.moex.records ?? 0}`;
      parts.push(res.moex.error ? `${mx} (${res.moex.error})` : mx);
    }
    const detail = parts.length > 0 ? parts.join(' · ') : res.source;
    const contracts =
      res.contracts?.length
        ? ` · контр.: ${res.contracts.map((c) => c.prefix).join(', ')}`
        : '';
    return `${dateFrom} — ${dateTo}: +${res.candles} свечей [${detail}]${contracts}`;
  }

  private dedupeCandles(candles: PriceCandle[]): PriceCandle[] {
    const map = new Map<string, PriceCandle>();
    for (const c of candles) {
      map.set(c.dt, c);
    }
    return [...map.values()].sort(
      (a, b) => new Date(a.dt).getTime() - new Date(b.dt).getTime()
    );
  }

  private syncIndicatorsForRange(
    securityId: number,
    range: ChartVisibleRange,
    opts?: { incremental?: boolean }
  ): void {
    const candles = this.chartState(securityId).candles;
    if (!this.timeframeId || candles.length === 0) {
      this.indicatorsLoading.delete(securityId);
      this.indicatorSeries.set(securityId, []);
      this.indicatorCalcError.set(securityId, null);
      return;
    }
    const assigned = this.securityIndicatorSeries.get(securityId) ?? [];
    if (assigned.length === 0) {
      this.indicatorsLoading.delete(securityId);
      this.indicatorSeries.set(securityId, []);
      this.indicatorCalcError.set(securityId, null);
      return;
    }

    const pointCount = Math.min(
      Math.max(range.count, 1),
      this.maxIndicatorCandles
    );
    const incremental = opts?.incremental !== false;
    const indicatorIds = [...new Set(assigned.map((a) => a.indicator_id))];

    this.indicatorsLoading.add(securityId);
    this.indicatorCalcError.set(securityId, null);

    this.securities
      .syncIndicatorSeries({
        security_id: securityId,
        timeframe_id: this.timeframeId,
        end_dt: range.endDt,
        point_count: pointCount,
        incremental,
      })
      .pipe(
        switchMap(() =>
          this.securities.getIndicatorValues(
            securityId,
            this.timeframeId!,
            indicatorIds,
            range.startDt,
            range.endDt
          )
        ),
        finalize(() => this.indicatorsLoading.delete(securityId))
      )
      .subscribe({
        next: (values) => {
          this.indicatorCalcError.set(securityId, null);
          this.indicatorSeries.set(
            securityId,
            this.buildChartSeries(values, assigned)
          );
        },
        error: (err) => {
          const msg =
            err?.name === 'TimeoutError'
              ? 'Таймаут расчёта индикаторов'
              : err?.error?.error || err?.message || 'Ошибка расчёта индикаторов';
          this.indicatorCalcError.set(securityId, msg);
          this.indicatorSeries.set(securityId, []);
        },
      });
  }

  private buildChartSeries(
    values: IndicatorValueRow[],
    assigned: SecurityIndicatorSeriesRow[]
  ): ChartIndicatorSeries[] {
    const orderMap = new Map<string, number>();
    assigned.forEach((a, idx) =>
      orderMap.set(`${a.indicator_id}:${a.series_code}`, idx)
    );
    const groups = new Map<string, IndicatorValueRow[]>();
    for (const v of values) {
      const key = `${v.indicator_id}:${v.line_code}`;
      const list = groups.get(key) ?? [];
      list.push(v);
      groups.set(key, list);
    }

    const series: ChartIndicatorSeries[] = [];
    let colorIdx = 0;
    const sortedKeys = [...groups.keys()].sort((a, b) => {
      return (orderMap.get(a) ?? 0) - (orderMap.get(b) ?? 0);
    });

    for (const key of sortedKeys) {
      const rows = groups.get(key)!;
      const sample = rows[0];
      const onPrice = this.isPriceScaleSeries(
        sample.indicator_code,
        sample.line_code
      );
      series.push({
        indicator_code: sample.indicator_code,
        line_code: sample.line_code,
        line_name: sample.line_name,
        color: this.seriesColors[colorIdx % this.seriesColors.length],
        on_price_scale: onPrice,
        is_threshold: sample.is_threshold,
        points: rows.map((r) => ({ dt: r.dt, value: Number(r.value) })),
      });
      if (!sample.is_threshold) {
        colorIdx += 1;
      }
    }
    return series;
  }

  private isPriceScaleSeries(indicatorCode: string, lineCode: string): boolean {
    if (this.priceScaleOverlayCodes.has(indicatorCode) && lineCode === 'VALUE') {
      return true;
    }
    if (indicatorCode === 'BB' && ['UPPER', 'MIDDLE', 'LOWER'].includes(lineCode)) {
      return true;
    }
    return false;
  }
}
