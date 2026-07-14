import { Component, OnDestroy, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, switchMap, takeUntil, timer } from 'rxjs';
import { forkJoin } from 'rxjs';
import { LogicsService } from '../services/logics.service';
import { ReferencesService } from '../services/references.service';
import { SecuritiesService } from '../services/securities.service';
import { SettingsService } from '../services/settings.service';
import { TechLogService } from '../services/tech-log.service';
import { LogicIndicatorSignalRow, LogicRow, LogicSecurityRow, LogicStopRow } from '../models/logic.model';
import { IndicatorRow } from '../models/lookup.model';
import { SecurityRow } from '../models/market.model';
import {
  AppConfigService,
  logicsLoadErrorMessage,
} from '../services/app-config.service';
import {
  LogicEditorComponent,
  LogicEditorMode,
} from '../logic-editor/logic-editor.component';
import { TbankTokenDialogComponent } from '../tbank-token-dialog/tbank-token-dialog.component';
import {
  buildLogicSignalFormula,
  parseSignalFormula,
  positionEventLabel,
  PositionEvent,
  positionSideLabel,
  PositionSide,
  signalKindLabel,
  SignalKind,
} from '../shared/signal-formula';
import {
  LOGIC_STOP_UNITS,
  LogicStopRuleKind,
  LogicStopScopeType,
  LogicStopValueUnit,
  ruleKindLabel,
  scopeTypeLabel,
  stopScopesForRuleKind,
  valueUnitLabel,
} from '../shared/logic-stop';
import {
  costMethodLabel,
  tradeOperationHint,
  tradeOperationLabel,
  tradeStatusLabel,
  yesNoLabel,
  LogicTradeLotRow,
  LogicTradeRow,
} from '../shared/logic-trade';
import {
  BacktestRunStatus,
  LogicPositionsPanelComponent,
} from './logic-positions-panel.component';

const POLL_INTERVAL_MS = 2000;

type SignalPickerState = {
  logicId: number;
  positionEvent: PositionEvent;
  positionSide: PositionSide;
  signalKind: SignalKind;
} | null;

type StopFormState = {
  logicId: number;
  ruleKind: LogicStopRuleKind;
} | null;

type StopFormDraft = {
  scope_type: LogicStopScopeType;
  value: string;
  value_unit: LogicStopValueUnit;
};

@Component({
  selector: 'app-logics',
  standalone: true,
  imports: [CommonModule, FormsModule, LogicEditorComponent, TbankTokenDialogComponent, LogicPositionsPanelComponent],
  templateUrl: './logics.component.html',
  styleUrl: './logics.component.css',
})
export class LogicsComponent implements OnInit, OnDestroy {
  logics: LogicRow[] = [];
  loading = true;
  error: string | null = null;
  pollIntervalMs = POLL_INTERVAL_MS;

  editorOpen = false;
  editorMode: LogicEditorMode = 'add';
  editorLogic: LogicRow | null = null;

  expandedLogics = new Set<number>();
  expandedParamsBlocks = new Set<number>();
  expandedSignalsBlocks = new Set<number>();
  expandedStopsBlocks = new Set<number>();
  expandedSecuritiesBlocks = new Set<number>();
  expandedTradesBlocks = new Set<number>();
  expandedTestTradesBlocks = new Set<number>();
  expandedOpenPositionsBlocks = new Set<number>();
  expandedClosedPositionsBlocks = new Set<number>();
  expandedTradeRows = new Set<number>();
  logicSignals = new Map<number, LogicIndicatorSignalRow[]>();
  logicStops = new Map<number, LogicStopRow[]>();
  logicSecurities = new Map<number, LogicSecurityRow[]>();
  logicTrades = new Map<number, LogicTradeRow[]>();
  logicTradesTest = new Map<number, LogicTradeRow[]>();
  backtestRuns = new Map<number, BacktestRunStatus>();
  private backtestPollIds = new Set<number>();
  logicTradeLots = new Map<number, LogicTradeLotRow[]>();
  signalsLoading = new Set<number>();
  stopsLoading = new Set<number>();
  securitiesLoading = new Set<number>();
  tradesLoading = new Set<number>();
  tradeLotsLoading = new Set<number>();
  closeAllLoading = new Set<number>();

  readonly costMethodOptions: Array<{ value: 'FIFO' | 'AVERAGE'; label: string }> = [
    { value: 'FIFO', label: 'FIFO (первая покупка — первая продажа)' },
    { value: 'AVERAGE', label: 'Средняя цена остатка' },
  ];

  indicatorsCatalog: IndicatorRow[] = [];
  indicatorsLoaded = false;

  signalPicker: SignalPickerState = null;
  pickerSelectedIds = new Set<number>();

  securityPickerLogicId: number | null = null;
  pickerSelectedSecurityIds = new Set<number>();
  stocksCatalog: SecurityRow[] = [];
  futuresCatalog: SecurityRow[] = [];
  securitiesCatalogLoaded = false;
  securitiesCatalogLoading = false;
  moexExchangeId: number | null = null;

  stopForm: StopFormState = null;
  stopFormDraft: StopFormDraft = {
    scope_type: 'security',
    value: '',
    value_unit: 'percent',
  };

  readonly stopUnits = LOGIC_STOP_UNITS;
  stopScopesFor = stopScopesForRuleKind;

  tbankTokenDialogOpen = false;
  tbankTokenDialogContext: 'prices' | 'logic' | 'trades' = 'logic';
  tbankTokenDialogReason: 'missing' | 'invalid' = 'missing';
  /** Постоянное предупреждение у блока «Сделки», пока токен невалиден и логика включена. */
  tbankTokenAlert: { reason: 'missing' | 'invalid'; message: string } | null = null;
  private pendingEnableLogic: LogicRow | null = null;
  private pendingBacktest: { logicId: number; period: { date_from: string; date_to: string } } | null =
    null;
  private lastTbankTokenCheckAt = 0;
  private readonly tbankTokenCheckMs = 30000;

  private readonly destroy$ = new Subject<void>();
  private savingIds = new Set<number>();
  private formulaDrafts = new Map<number, string>();
  private savingFormulaIds = new Set<number>();
  private savingStopIds = new Set<number>();
  private savingParamsIds = new Set<number>();
  paramsDrafts = new Map<
    number,
    {
      timeframe: string;
      position_size_pct: string;
      max_open_positions: string;
      initial_balance: string;
      commission_pct: string;
      cost_method: 'FIFO' | 'AVERAGE';
      stop_loss_timeframe: string;
      reset_balance: boolean;
    }
  >();
  paramsSaveErrors = new Map<number, string>();
  paramsLoading = new Set<number>();
  timeframesCatalog: { id: number; tf: string; full_name: string }[] = [];
  /** Пользователь менял черновик — poll не перезаписывает поля ввода. */
  private paramsDirtyIds = new Set<number>();

  constructor(
    private readonly logicsService: LogicsService,
    private readonly refs: ReferencesService,
    private readonly securitiesService: SecuritiesService,
    private readonly settings: SettingsService,
    private readonly techLog: TechLogService,
    private readonly appConfig: AppConfigService
  ) {}

  ngOnInit(): void {
    this.loadIndicatorsCatalog();
    this.loadMoexExchangeId();
    this.securitiesService.getTimeframes().subscribe({
      next: (rows) => {
        this.timeframesCatalog = rows.filter((r) => r.is_active !== false);
      },
    });
    timer(0, POLL_INTERVAL_MS)
      .pipe(
        takeUntil(this.destroy$),
        switchMap(() => this.logicsService.getLogics())
      )
      .subscribe({
        next: (rows) => {
          this.logics = rows.map((row) => {
            if (this.savingIds.has(row.id)) {
              const local = this.logics.find((x) => x.id === row.id);
              return local ? { ...row, is_enabled: local.is_enabled } : row;
            }
            if (this.savingParamsIds.has(row.id) || this.paramsDirtyIds.has(row.id)) {
              const local = this.logics.find((x) => x.id === row.id);
              return local
                ? {
                    ...row,
                    position_size_pct: local.position_size_pct,
                    max_open_positions: local.max_open_positions,
                    initial_balance: local.initial_balance,
                    // current_balance — только для отображения, берём с сервера
                  }
                : row;
            }
            return row;
          });
          this.loading = false;
          this.error = null;
          // Сделки — read-only, обновляем; редактируемые блоки (параметры, формулы) — нет
          this.refreshAllTradesSummaries();
          this.maybeCheckTbankTokenForTrades();
        },
        error: (err) => {
          if (this.loading || this.logics.length === 0) {
            this.error = logicsLoadErrorMessage(this.appConfig.apiUrl, err);
          }
          this.loading = false;
        },
      });
  }

  ngOnDestroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  signalKindLabel = signalKindLabel;
  positionSideLabel = positionSideLabel;
  positionEventLabel = positionEventLabel;
  ruleKindLabel = ruleKindLabel;
  scopeTypeLabel = scopeTypeLabel;
  valueUnitLabel = valueUnitLabel;
  tradeStatusLabel = tradeStatusLabel;
  yesNoLabel = yesNoLabel;

  isLogicExpanded(id: number): boolean {
    return this.expandedLogics.has(id);
  }

  isParamsBlockExpanded(id: number): boolean {
    return this.expandedParamsBlocks.has(id);
  }

  isSignalsBlockExpanded(id: number): boolean {
    return this.expandedSignalsBlocks.has(id);
  }

  isStopsBlockExpanded(id: number): boolean {
    return this.expandedStopsBlocks.has(id);
  }

  isSecuritiesBlockExpanded(id: number): boolean {
    return this.expandedSecuritiesBlocks.has(id);
  }

  isTradesBlockExpanded(id: number): boolean {
    return this.expandedTradesBlocks.has(id);
  }

  toggleLogicExpand(row: LogicRow, event: Event): void {
    const target = event.target as HTMLElement;
    if (
      target.closest('button, input, a, .col-actions, .logic-signals-panel')
    ) {
      return;
    }
    if (this.expandedLogics.has(row.id)) {
      this.expandedLogics.delete(row.id);
      this.expandedParamsBlocks.delete(row.id);
      this.paramsDirtyIds.delete(row.id);
      this.expandedSignalsBlocks.delete(row.id);
      this.expandedStopsBlocks.delete(row.id);
      this.expandedSecuritiesBlocks.delete(row.id);
      this.expandedTradesBlocks.delete(row.id);
      this.expandedTestTradesBlocks.delete(row.id);
      this.closeSignalPicker();
      this.closeStopForm();
      this.closeSecurityPicker();
      return;
    }
    this.expandedLogics.add(row.id);
    this.ensureParamsDraft(row.id);
  }

  /** Черновик параметров — всегда объект из Map (не временный литерал). */
  getParamsDraft(logicId: number) {
    this.ensureParamsDraft(logicId);
    return this.paramsDrafts.get(logicId)!;
  }

  paramsSaveError(logicId: number): string | null {
    return this.paramsSaveErrors.get(logicId) ?? null;
  }

  onParamsTimeframeChange(logicId: number, value: string): void {
    this.getParamsDraft(logicId).timeframe = value;
    this.paramsDirtyIds.add(logicId);
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsStopLossTimeframeChange(logicId: number, value: string): void {
    this.getParamsDraft(logicId).stop_loss_timeframe = value;
    this.paramsDirtyIds.add(logicId);
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsPctChange(logicId: number, value: string): void {
    this.getParamsDraft(logicId).position_size_pct = value;
    this.paramsDirtyIds.add(logicId);
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsMaxPositionsChange(logicId: number, value: string): void {
    this.getParamsDraft(logicId).max_open_positions = value;
    this.paramsDirtyIds.add(logicId);
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsInitialBalanceChange(logicId: number, value: string): void {
    this.getParamsDraft(logicId).initial_balance = value;
    this.paramsDirtyIds.add(logicId);
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsCommissionPctChange(logicId: number, value: string): void {
    this.getParamsDraft(logicId).commission_pct = value;
    this.paramsDirtyIds.add(logicId);
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsCostMethodChange(logicId: number, value: 'FIFO' | 'AVERAGE'): void {
    this.getParamsDraft(logicId).cost_method = value;
    this.paramsDirtyIds.add(logicId);
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsResetBalanceChange(logicId: number, value: boolean): void {
    this.getParamsDraft(logicId).reset_balance = value;
    this.paramsDirtyIds.add(logicId);
    this.paramsSaveErrors.delete(logicId);
  }

  private formatPctParam(value: number | string | null | undefined): string {
    if (value == null || value === '') return '10';
    const n =
      typeof value === 'number'
        ? value
        : Number(String(value).trim().replace(/\s/g, '').replace(',', '.'));
    if (!Number.isFinite(n)) return '10';
    const rounded = Math.round(n * 10000) / 10000;
    if (Math.abs(rounded - Math.round(rounded)) < 1e-9) {
      return String(Math.round(rounded));
    }
    return String(rounded);
  }

  private formatIntParam(value: number | string | null | undefined, fallback: number): string {
    if (value == null || value === '') return String(fallback);
    const n = Number(String(value).trim().replace(/\s/g, ''));
    if (!Number.isFinite(n)) return String(fallback);
    return String(Math.round(n));
  }

  private formatBalanceDraft(value: number | string | null | undefined): string {
    if (value == null || value === '') return '';
    const n =
      typeof value === 'number'
        ? value
        : Number(String(value).trim().replace(/\s/g, '').replace(',', '.'));
    if (!Number.isFinite(n)) return '';
    return String(n);
  }

  private parseDecimalInput(raw: string): number {
    return Number(raw.trim().replace(/\s/g, '').replace(',', '.'));
  }

  isParamsLoading(logicId: number): boolean {
    return this.paramsLoading.has(logicId);
  }

  loadParamsForLogic(logicId: number, silent = false): void {
    if (silent && this.paramsDirtyIds.has(logicId)) {
      return;
    }
    if (!silent) {
      this.paramsLoading.add(logicId);
    }
    this.logicsService.getLogicParams(logicId).subscribe({
      next: (resp) => {
        this.applyTradingParamsToLogic(logicId, resp.trading);
        if (!this.paramsDirtyIds.has(logicId)) {
          this.paramsDrafts.set(logicId, this.draftFromTrading(resp.trading));
        }
        this.paramsLoading.delete(logicId);
      },
      error: () => {
        this.paramsLoading.delete(logicId);
        if (!silent) {
          this.paramsSaveErrors.set(logicId, 'Не удалось загрузить параметры');
        }
      },
    });
  }

  private applyTradingParamsToLogic(
    logicId: number,
    trading: {
      timeframe?: string;
      position_size_pct: number;
      max_open_positions: number;
      initial_balance: number | null;
      current_balance: number | null;
      commission_pct?: number;
      cost_method?: 'FIFO' | 'AVERAGE';
      stop_loss_timeframe?: string;
    }
  ): void {
    const idx = this.logics.findIndex((l) => l.id === logicId);
    if (idx >= 0) {
      this.logics[idx] = { ...this.logics[idx], ...trading };
    }
  }

  private draftFromTrading(trading: {
    timeframe?: string;
    position_size_pct: number;
    max_open_positions: number;
    initial_balance: number | null;
    current_balance: number | null;
    commission_pct?: number;
    cost_method?: 'FIFO' | 'AVERAGE';
    stop_loss_timeframe?: string;
  }): {
    timeframe: string;
    position_size_pct: string;
    max_open_positions: string;
    initial_balance: string;
    commission_pct: string;
    cost_method: 'FIFO' | 'AVERAGE';
    stop_loss_timeframe: string;
    reset_balance: boolean;
  } {
    const method: 'FIFO' | 'AVERAGE' =
      trading.cost_method === 'AVERAGE' ? 'AVERAGE' : 'FIFO';
    return {
      timeframe: (trading.timeframe ?? 'M15').toUpperCase(),
      position_size_pct: this.formatPctParam(trading.position_size_pct),
      max_open_positions: this.formatIntParam(trading.max_open_positions, 5),
      initial_balance: this.formatBalanceDraft(trading.initial_balance),
      commission_pct: this.formatPctParam(trading.commission_pct ?? 0.05),
      cost_method: method,
      stop_loss_timeframe: (trading.stop_loss_timeframe ?? 'M5').toUpperCase(),
      reset_balance: false,
    };
  }

  toggleParamsBlock(logicId: number, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedParamsBlocks.has(logicId)) {
      this.expandedParamsBlocks.delete(logicId);
      this.paramsDirtyIds.delete(logicId);
    } else {
      this.expandedParamsBlocks.add(logicId);
      this.paramsDirtyIds.delete(logicId);
      this.loadParamsForLogic(logicId);
    }
  }

  ensureParamsDraft(logicId: number, force = false): void {
    if (!force && this.paramsDrafts.has(logicId)) return;
    const row = this.logics.find((l) => l.id === logicId);
    if (!row) return;
    this.paramsDrafts.set(logicId, this.draftFromLogicRow(row));
  }

  private draftFromLogicRow(row: LogicRow) {
    return this.draftFromTrading({
      timeframe: row.timeframe ?? 'M15',
      position_size_pct: row.position_size_pct,
      max_open_positions: row.max_open_positions,
      initial_balance: row.initial_balance,
      current_balance: row.current_balance,
      commission_pct: row.commission_pct,
      cost_method: row.cost_method,
      stop_loss_timeframe: row.stop_loss_timeframe,
    });
  }

  isParamsSaving(logicId: number): boolean {
    return this.savingParamsIds.has(logicId);
  }

  saveTradingParams(row: LogicRow, event: Event): void {
    event.stopPropagation();
    const draft = this.getParamsDraft(row.id);
    const position_size_pct = this.parseDecimalInput(draft.position_size_pct);
    const max_open_positions = Math.round(this.parseDecimalInput(draft.max_open_positions));
    const initialRaw = draft.initial_balance.trim();
    const initial_balance =
      initialRaw === '' ? null : this.parseDecimalInput(initialRaw.replace(',', '.'));
    const commission_pct = this.parseDecimalInput(draft.commission_pct);

    if (!Number.isFinite(position_size_pct) || position_size_pct <= 0 || position_size_pct > 100) {
      this.paramsSaveErrors.set(
        row.id,
        '% депозита: число от 0.01 до 100 (без пробелов, например 10)'
      );
      return;
    }
    if (!Number.isInteger(max_open_positions) || max_open_positions <= 0) {
      this.paramsSaveErrors.set(row.id, 'Макс. позиций: целое число больше 0');
      return;
    }
    if (initial_balance != null && (!Number.isFinite(initial_balance) || initial_balance < 0)) {
      this.paramsSaveErrors.set(row.id, 'Начальный остаток: число ≥ 0 или пусто');
      return;
    }
    if (!Number.isFinite(commission_pct) || commission_pct < 0 || commission_pct > 100) {
      this.paramsSaveErrors.set(row.id, '% комиссии: число от 0 до 100');
      return;
    }

    this.paramsSaveErrors.delete(row.id);
    this.savingParamsIds.add(row.id);
    this.logicsService
      .saveLogicParams(row.id, {
        timeframe: draft.timeframe,
        position_size_pct,
        max_open_positions,
        initial_balance,
        commission_pct,
        cost_method: draft.cost_method,
        stop_loss_timeframe: draft.stop_loss_timeframe,
        reset_balance: draft.reset_balance,
      })
      .subscribe({
        next: (resp) => {
          this.applyTradingParamsToLogic(row.id, resp.trading);
          this.paramsDrafts.set(row.id, this.draftFromTrading(resp.trading));
          this.paramsDirtyIds.delete(row.id);
          this.savingParamsIds.delete(row.id);
          this.paramsSaveErrors.delete(row.id);
          this.techLog.event(
            this.techLog.logicThreadKey(row.id, 'params'),
            'logic.params.saved',
            'Параметры логики сохранены (UI)',
            {
              logicId: row.id,
              payload: { trading: resp.trading, params: resp.params },
            }
          );
        },
        error: (err) => {
          this.savingParamsIds.delete(row.id);
          this.paramsSaveErrors.set(
            row.id,
            err?.error?.error ?? 'Не удалось сохранить параметры'
          );
        },
      });
  }

  formatMoney(value: number | null | undefined): string {
    if (value == null || !Number.isFinite(Number(value))) return '—';
    return Number(value).toLocaleString('ru-RU', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
  }

  toggleSignalsBlock(logicId: number, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedSignalsBlocks.has(logicId)) {
      this.expandedSignalsBlocks.delete(logicId);
      this.closeSignalPicker();
    } else {
      this.expandedSignalsBlocks.add(logicId);
      this.loadSignalsForLogic(logicId);
    }
  }

  toggleStopsBlock(logicId: number, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedStopsBlocks.has(logicId)) {
      this.expandedStopsBlocks.delete(logicId);
      this.closeStopForm();
    } else {
      this.expandedStopsBlocks.add(logicId);
      this.loadStopsForLogic(logicId);
    }
  }

  toggleSecuritiesBlock(logicId: number, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedSecuritiesBlocks.has(logicId)) {
      this.expandedSecuritiesBlocks.delete(logicId);
      this.closeSecurityPicker();
    } else {
      this.expandedSecuritiesBlocks.add(logicId);
      this.loadSecuritiesForLogic(logicId);
    }
  }

  isTestTradesBlockExpanded(id: number): boolean {
    return this.expandedTestTradesBlocks.has(id);
  }

  toggleTestTradesBlock(logicId: number, event?: Event): void {
    event?.preventDefault();
    event?.stopPropagation();
    if (this.expandedTestTradesBlocks.has(logicId)) {
      this.expandedTestTradesBlocks.delete(logicId);
    } else {
      this.expandedTestTradesBlocks.add(logicId);
      this.loadTestTradesForLogic(logicId);
      this.refreshBacktestStatus(logicId);
    }
  }

  toggleTradesBlock(logicId: number, event?: Event): void {
    event?.preventDefault();
    event?.stopPropagation();
    if (this.expandedTradesBlocks.has(logicId)) {
      this.expandedTradesBlocks.delete(logicId);
      this.expandedOpenPositionsBlocks.delete(logicId);
      this.expandedClosedPositionsBlocks.delete(logicId);
      for (const tr of this.tradesFor(logicId)) {
        this.expandedTradeRows.delete(tr.id);
      }
    } else {
      this.expandedTradesBlocks.add(logicId);
      this.expandedOpenPositionsBlocks.add(logicId);
      this.loadTradesForLogic(logicId);
    }
  }

  toggleOpenPositionsBlock(logicId: number, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedOpenPositionsBlocks.has(logicId)) {
      this.expandedOpenPositionsBlocks.delete(logicId);
    } else {
      this.expandedOpenPositionsBlocks.add(logicId);
      this.loadLotsForOpenPositions(logicId);
    }
  }

  toggleClosedPositionsBlock(logicId: number, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedClosedPositionsBlocks.has(logicId)) {
      this.expandedClosedPositionsBlocks.delete(logicId);
    } else {
      this.expandedClosedPositionsBlocks.add(logicId);
      this.loadLotsForClosedPositions(logicId);
    }
  }

  isOpenPositionsExpanded(logicId: number): boolean {
    return this.expandedOpenPositionsBlocks.has(logicId);
  }

  isClosedPositionsExpanded(logicId: number): boolean {
    return this.expandedClosedPositionsBlocks.has(logicId);
  }

  openPositionTrades(logicId: number, isTest = false): LogicTradeRow[] {
    return this.tradesFor(logicId, isTest)
      .filter((t) => this.isOpenPositionTrade(t))
      .sort(
        (a, b) =>
          new Date(b.executed_at).getTime() - new Date(a.executed_at).getTime()
      );
  }

  closePositionTrades(logicId: number): LogicTradeRow[] {
    return this.tradesFor(logicId)
      .filter(
        (t) =>
          t.side_name === 'Close' &&
          (t.status === 'filled' || t.status === 'submitted')
      )
      .sort(
        (a, b) =>
          new Date(b.executed_at).getTime() - new Date(a.executed_at).getTime()
      );
  }

  closedPartialLotsForOpen(openTradeId: number): LogicTradeLotRow[] {
    return this.tradeLotsFor(openTradeId).filter(
      (l) => l.open_trade_id === openTradeId
    );
  }

  closedLotsForClose(closeTradeId: number): LogicTradeLotRow[] {
    return this.tradeLotsFor(closeTradeId).filter(
      (l) => l.close_trade_id === closeTradeId
    );
  }

  totalFinancialResult(logicId: number, isTest = false): number {
    return this.tradesFor(logicId, isTest)
      .filter((t) => !t.is_shadow)
      .reduce(
        (sum, t) =>
          t.financial_result != null && Number.isFinite(Number(t.financial_result))
            ? sum + Number(t.financial_result)
            : sum,
        0
      );
  }

  hasOpenPositions(logicId: number): boolean {
    return this.openPositionTrades(logicId).length > 0;
  }

  isCloseAllLoading(logicId: number): boolean {
    return this.closeAllLoading.has(logicId);
  }

  closeAllPositionsAtMarket(logicId: number, event?: Event): void {
    event?.preventDefault();
    event?.stopPropagation();
    if (this.closeAllLoading.has(logicId) || !this.hasOpenPositions(logicId)) {
      return;
    }
    if (
      !confirm(
        'Закрыть все открытые позиции по текущим рыночным ценам? Фин. результат будет пересчитан.'
      )
    ) {
      return;
    }
    this.closeAllLoading.add(logicId);
    this.logicsService.closeAllPositionsAtMarket(logicId).subscribe({
      next: (result) => {
        this.closeAllLoading.delete(logicId);
        if (!result.ok) {
          alert(result.error ?? 'Не удалось закрыть позиции');
          return;
        }
        this.logicTradeLots.clear();
        this.expandedTradeRows.clear();
        this.loadTradesForLogic(logicId);
        if (this.isClosedPositionsExpanded(logicId)) {
          this.loadLotsForClosedPositions(logicId);
        }
        if ((result.closed ?? 0) === 0 && (result.skipped ?? 0) > 0) {
          alert('Не удалось закрыть позиции: нет цен или ошибка брокера');
        }
      },
      error: (err) => {
        this.closeAllLoading.delete(logicId);
        alert(err?.error?.error ?? err?.message ?? 'Ошибка закрытия позиций');
      },
    });
  }

  isOpenPositionTrade(trade: LogicTradeRow): boolean {
    if (trade.side_name !== 'Open') {
      return false;
    }
    const rem = trade.remaining_qty;
    if (rem == null) {
      return true;
    }
    return Number(rem) > 0;
  }

  private loadLotsForClosedPositions(logicId: number): void {
    for (const close of this.closePositionTrades(logicId)) {
      this.loadTradeLots(close.id);
    }
  }

  private loadLotsForOpenPositions(logicId: number): void {
    for (const open of this.openPositionTrades(logicId)) {
      const rem = open.remaining_qty ?? open.quantity;
      if (Number(open.quantity) > Number(rem)) {
        this.loadTradeLots(open.id);
      }
    }
  }

  toggleTradeRow(trade: LogicTradeRow, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedTradeRows.has(trade.id)) {
      this.expandedTradeRows.delete(trade.id);
    } else {
      this.expandedTradeRows.add(trade.id);
      this.loadTradeLots(trade.id);
    }
  }

  isTradeRowExpanded(tradeId: number): boolean {
    return this.expandedTradeRows.has(tradeId);
  }

  isTradeLotsLoading(tradeId: number): boolean {
    return this.tradeLotsLoading.has(tradeId);
  }

  tradeLotsFor(tradeId: number): LogicTradeLotRow[] {
    return this.logicTradeLots.get(tradeId) ?? [];
  }

  tradeHasPackages(trade: LogicTradeRow): boolean {
    return trade.side_name === 'Close' || trade.side_name === 'Open';
  }

  tradeOperationLabel = tradeOperationLabel;
  tradeOperationHint = tradeOperationHint;
  costMethodLabel = costMethodLabel;

  formatPnl(value: number | null | undefined): string {
    if (value == null || !Number.isFinite(Number(value))) return '—';
    const n = Number(value);
    const formatted = this.formatMoney(Math.abs(n));
    if (n > 0) return `+${formatted}`;
    if (n < 0) return `−${formatted}`;
    return formatted;
  }

  requestTradeLots(tradeId: number): void {
    this.loadTradeLots(tradeId);
  }

  private loadTradeLots(tradeId: number): void {
    if (this.tradeLotsLoading.has(tradeId)) return;
    this.tradeLotsLoading.add(tradeId);
    this.logicsService.getLogicTradeLots(tradeId).subscribe({
      next: (rows) => {
        this.logicTradeLots.set(tradeId, rows);
        this.tradeLotsLoading.delete(tradeId);
      },
      error: () => {
        this.tradeLotsLoading.delete(tradeId);
      },
    });
  }

  tradesFor(logicId: number, isTest = false): LogicTradeRow[] {
    return isTest ? this.logicTradesTest.get(logicId) ?? [] : this.logicTrades.get(logicId) ?? [];
  }

  backtestFor(logicId: number): BacktestRunStatus | null {
    return this.backtestRuns.get(logicId) ?? null;
  }

  timeframeIdForLogic(row: LogicRow): number | null {
    const draft = this.paramsDrafts.get(row.id);
    const tfName = (draft?.timeframe || row.timeframe || 'M15').trim();
    const byName = this.timeframesCatalog.find((t) => t.tf === tfName)?.id;
    if (byName != null) return byName;
    // fallback: M15 / первый из каталога
    return (
      this.timeframesCatalog.find((t) => t.tf === 'M15')?.id ??
      this.timeframesCatalog[0]?.id ??
      null
    );
  }

  signalIndicatorIdsFor(logicId: number): number[] {
    const ids = new Set<number>();
    for (const s of this.signalsFor(logicId)) {
      if (s.is_active && s.indicator_id != null) ids.add(Number(s.indicator_id));
    }
    return [...ids];
  }

  isBacktestRunning(logicId: number): boolean {
    const s = this.backtestRuns.get(logicId)?.status;
    return s === 'pending' || s === 'loading_prices' || s === 'loading_indicators' || s === 'running';
  }

  isTradesLoading(logicId: number): boolean {
    return this.tradesLoading.has(logicId);
  }

  tradeActionLabel(trade: LogicTradeRow): string {
    return tradeOperationLabel(trade);
  }

  openTradeHasPartialCloses(trade: LogicTradeRow): boolean {
    const rem = trade.remaining_qty ?? trade.quantity;
    return Number(trade.quantity) > Number(rem);
  }

  formatTradeDt(iso: string): string {
    if (!iso) return '—';
    try {
      return new Date(iso).toLocaleString('ru-RU');
    } catch {
      return iso;
    }
  }

  securitiesFor(logicId: number): LogicSecurityRow[] {
    return this.logicSecurities.get(logicId) ?? [];
  }

  isSecuritiesLoading(logicId: number): boolean {
    return this.securitiesLoading.has(logicId);
  }

  securityKindLabel(row: LogicSecurityRow): string {
    return row.instrument_market === 'futures' ? 'Фьючерс' : 'Акция';
  }

  openSecurityPicker(logicId: number, event: Event): void {
    event.stopPropagation();
    this.securityPickerLogicId = logicId;
    this.pickerSelectedSecurityIds.clear();
    if (!this.expandedLogics.has(logicId)) {
      this.expandedLogics.add(logicId);
    }
    this.expandedSecuritiesBlocks.add(logicId);
    this.loadSecuritiesForLogic(logicId);
    this.ensureSecuritiesCatalogLoaded();
  }

  closeSecurityPicker(): void {
    this.securityPickerLogicId = null;
    this.pickerSelectedSecurityIds.clear();
  }

  isSecurityPickerOpen(logicId: number): boolean {
    return this.securityPickerLogicId === logicId;
  }

  toggleSecurityPickerSelection(securityId: number): void {
    if (this.pickerSelectedSecurityIds.has(securityId)) {
      this.pickerSelectedSecurityIds.delete(securityId);
    } else {
      this.pickerSelectedSecurityIds.add(securityId);
    }
  }

  isSecurityPickerSelected(securityId: number): boolean {
    return this.pickerSelectedSecurityIds.has(securityId);
  }

  pickerStocksAvailable(logicId: number): SecurityRow[] {
    const assigned = new Set(
      this.securitiesFor(logicId).map((s) => s.security_id)
    );
    return this.stocksCatalog.filter((s) => !assigned.has(s.id));
  }

  pickerFuturesAvailable(logicId: number): SecurityRow[] {
    const assigned = new Set(
      this.securitiesFor(logicId).map((s) => s.security_id)
    );
    return this.futuresCatalog.filter((s) => !assigned.has(s.id));
  }

  allStocksPickerSelected(logicId: number): boolean {
    const list = this.pickerStocksAvailable(logicId);
    return list.length > 0 && list.every((s) => this.pickerSelectedSecurityIds.has(s.id));
  }

  someStocksPickerSelected(logicId: number): boolean {
    const list = this.pickerStocksAvailable(logicId);
    const n = list.filter((s) => this.pickerSelectedSecurityIds.has(s.id)).length;
    return n > 0 && n < list.length;
  }

  allFuturesPickerSelected(logicId: number): boolean {
    const list = this.pickerFuturesAvailable(logicId);
    return list.length > 0 && list.every((s) => this.pickerSelectedSecurityIds.has(s.id));
  }

  someFuturesPickerSelected(logicId: number): boolean {
    const list = this.pickerFuturesAvailable(logicId);
    const n = list.filter((s) => this.pickerSelectedSecurityIds.has(s.id)).length;
    return n > 0 && n < list.length;
  }

  toggleAllStocksPicker(logicId: number, checked: boolean): void {
    for (const s of this.pickerStocksAvailable(logicId)) {
      if (checked) {
        this.pickerSelectedSecurityIds.add(s.id);
      } else {
        this.pickerSelectedSecurityIds.delete(s.id);
      }
    }
  }

  toggleAllFuturesPicker(logicId: number, checked: boolean): void {
    for (const s of this.pickerFuturesAvailable(logicId)) {
      if (checked) {
        this.pickerSelectedSecurityIds.add(s.id);
      } else {
        this.pickerSelectedSecurityIds.delete(s.id);
      }
    }
  }

  addSelectedSecurities(): void {
    if (this.securityPickerLogicId == null || this.pickerSelectedSecurityIds.size === 0) {
      return;
    }
    const logicId = this.securityPickerLogicId;
    const ids = [...this.pickerSelectedSecurityIds];
    this.logicsService.addLogicSecuritiesBulk(logicId, ids).subscribe({
      next: (created) => {
        const list = [...this.securitiesFor(logicId)];
        for (const row of created) {
          const idx = list.findIndex((x) => x.id === row.id);
          if (idx >= 0) {
            list[idx] = row;
          } else {
            list.push(row);
          }
        }
        this.logicSecurities.set(logicId, list);
        this.closeSecurityPicker();
      },
      error: (err) => {
        alert(err?.error?.error || 'Не удалось добавить бумаги');
      },
    });
  }

  deleteLogicSecurity(row: LogicSecurityRow, event: Event): void {
    event.stopPropagation();
    this.logicsService.deleteLogicSecurity(row.id).subscribe({
      next: () => {
        const list = (this.logicSecurities.get(row.logic_id) ?? []).filter(
          (s) => s.id !== row.id
        );
        this.logicSecurities.set(row.logic_id, list);
      },
    });
  }

  stopsFor(logicId: number): LogicStopRow[] {
    return this.logicStops.get(logicId) ?? [];
  }

  isStopsLoading(logicId: number): boolean {
    return this.stopsLoading.has(logicId);
  }

  openStopForm(logicId: number, ruleKind: LogicStopRuleKind, event: Event): void {
    event.stopPropagation();
    this.stopForm = { logicId, ruleKind };
    this.stopFormDraft = {
      scope_type: 'security',
      value: '',
      value_unit: 'percent',
    };
    if (!this.expandedLogics.has(logicId)) {
      this.expandedLogics.add(logicId);
    }
    this.expandedStopsBlocks.add(logicId);
    this.loadStopsForLogic(logicId);
  }

  closeStopForm(): void {
    this.stopForm = null;
  }

  isStopFormOpen(logicId: number, ruleKind: LogicStopRuleKind): boolean {
    return (
      this.stopForm?.logicId === logicId && this.stopForm.ruleKind === ruleKind
    );
  }

  submitStopForm(): void {
    if (!this.stopForm) return;
    const value = Number(this.stopFormDraft.value.replace(',', '.'));
    if (!Number.isFinite(value) || value <= 0) {
      alert('Укажите положительное число в поле «Значение»');
      return;
    }
    const { logicId, ruleKind } = this.stopForm;
    this.logicsService
      .createLogicStop({
        logic_id: logicId,
        rule_kind: ruleKind,
        scope_type: this.stopFormDraft.scope_type,
        value,
        value_unit: this.stopFormDraft.value_unit,
      })
      .subscribe({
        next: (created) => {
          const list = [...(this.logicStops.get(logicId) ?? []), created];
          this.logicStops.set(logicId, list);
          this.closeStopForm();
        },
        error: (err) => {
          alert(err?.error?.error || 'Не удалось добавить правило');
        },
      });
  }

  saveStopRow(
    stop: LogicStopRow,
    patch: {
      scope_type?: LogicStopScopeType;
      value?: number;
      value_unit?: LogicStopValueUnit;
    }
  ): void {
    if (this.savingStopIds.has(stop.id)) return;
    this.savingStopIds.add(stop.id);
    this.logicsService.updateLogicStop(stop.id, patch).subscribe({
      next: (updated) => {
        const list = this.logicStops.get(stop.logic_id) ?? [];
        this.logicStops.set(
          stop.logic_id,
          list.map((s) => (s.id === updated.id ? updated : s))
        );
        this.savingStopIds.delete(stop.id);
      },
      error: () => this.savingStopIds.delete(stop.id),
    });
  }

  onStopValueBlur(stop: LogicStopRow, raw: string): void {
    const value = Number(raw.replace(',', '.'));
    if (!Number.isFinite(value) || value <= 0 || value === stop.value) {
      return;
    }
    this.saveStopRow(stop, { value });
  }

  deleteStop(stop: LogicStopRow, event: Event): void {
    event.stopPropagation();
    this.logicsService.deleteLogicStop(stop.id).subscribe({
      next: () => {
        const list = (this.logicStops.get(stop.logic_id) ?? []).filter(
          (s) => s.id !== stop.id
        );
        this.logicStops.set(stop.logic_id, list);
      },
    });
  }

  isStopSaving(id: number): boolean {
    return this.savingStopIds.has(id);
  }

  signalsFor(logicId: number): LogicIndicatorSignalRow[] {
    return this.logicSignals.get(logicId) ?? [];
  }

  isSignalsLoading(logicId: number): boolean {
    return this.signalsLoading.has(logicId);
  }

  openSignalPicker(logicId: number, positionEvent: PositionEvent, event: Event): void {
    event.stopPropagation();
    this.signalPicker = {
      logicId,
      positionEvent,
      positionSide: 'long',
      signalKind: positionEvent === 'open' ? 'trend' : 'counter',
    };
    this.pickerSelectedIds.clear();
    if (!this.expandedLogics.has(logicId)) {
      this.expandedLogics.add(logicId);
    }
    this.expandedSignalsBlocks.add(logicId);
    this.loadSignalsForLogic(logicId);
  }

  onPickerSignalKindChange(kind: SignalKind): void {
    if (this.signalPicker) {
      this.signalPicker = { ...this.signalPicker, signalKind: kind };
    }
  }

  onPickerPositionSideChange(side: PositionSide): void {
    if (this.signalPicker) {
      this.signalPicker = { ...this.signalPicker, positionSide: side };
    }
  }

  pickerPreviewFormula(indicator: IndicatorRow): string {
    if (!this.signalPicker) return '';
    return buildLogicSignalFormula(indicator, this.signalPicker.signalKind);
  }

  closeSignalPicker(): void {
    this.signalPicker = null;
    this.pickerSelectedIds.clear();
  }

  isPickerOpen(logicId: number): boolean {
    return this.signalPicker?.logicId === logicId;
  }

  togglePickerSelection(indicatorId: number): void {
    if (this.pickerSelectedIds.has(indicatorId)) {
      this.pickerSelectedIds.delete(indicatorId);
    } else {
      this.pickerSelectedIds.add(indicatorId);
    }
  }

  isPickerSelected(indicatorId: number): boolean {
    return this.pickerSelectedIds.has(indicatorId);
  }

  onPickerRowDblClick(indicator: IndicatorRow): void {
    if (!this.signalPicker) return;
    this.pickerSelectedIds.clear();
    this.pickerSelectedIds.add(indicator.id);
    this.addSelectedSignals();
  }

  addSelectedSignals(): void {
    if (!this.signalPicker || this.pickerSelectedIds.size === 0) return;
    const { logicId, positionEvent, positionSide, signalKind } = this.signalPicker;
    const existing = new Set(
      this.signalsFor(logicId)
        .filter(
          (s) =>
            s.position_event === positionEvent &&
            s.position_side === positionSide &&
            s.signal_kind === signalKind
        )
        .map((s) => s.indicator_id)
    );
    const toAdd = [...this.pickerSelectedIds].filter((id) => !existing.has(id));
    if (toAdd.length === 0) {
      this.closeSignalPicker();
      return;
    }
    let pending = toAdd.length;
    for (const indicatorId of toAdd) {
      const ind = this.indicatorsCatalog.find((i) => i.id === indicatorId);
      if (!ind) {
        pending -= 1;
        continue;
      }
      const formula = buildLogicSignalFormula(ind, signalKind);
      this.logicsService
        .createLogicIndicatorSignal({
          logic_id: logicId,
          indicator_id: indicatorId,
          position_event: positionEvent,
          position_side: positionSide,
          signal_kind: signalKind,
          formula,
        })
        .subscribe({
          next: (created) => {
            const list = [...(this.logicSignals.get(logicId) ?? [])];
            const idx = list.findIndex((x) => x.id === created.id);
            if (idx >= 0) {
              list[idx] = created;
            } else {
              list.push(created);
            }
            this.logicSignals.set(logicId, list);
            this.formulaDrafts.set(created.id, created.formula);
            pending -= 1;
            if (pending === 0) {
              this.closeSignalPicker();
            }
          },
          error: () => {
            pending -= 1;
            if (pending === 0) {
              this.closeSignalPicker();
            }
          },
        });
    }
  }

  formulaDraft(signal: LogicIndicatorSignalRow): string {
    return this.formulaDrafts.get(signal.id) ?? signal.formula;
  }

  onFormulaInput(signal: LogicIndicatorSignalRow, value: string): void {
    this.formulaDrafts.set(signal.id, value);
  }

  formulaParseHint(signal: LogicIndicatorSignalRow): string | null {
    const parsed = parseSignalFormula(this.formulaDraft(signal));
    if (parsed.valid) return null;
    return parsed.errors[0] ?? 'Неверный формат';
  }

  saveSignalFormula(signal: LogicIndicatorSignalRow): void {
    const draft = this.formulaDraft(signal).trim();
    if (!draft || draft === signal.formula || this.savingFormulaIds.has(signal.id)) {
      return;
    }
    this.savingFormulaIds.add(signal.id);
    this.logicsService.updateLogicIndicatorSignal(signal.id, { formula: draft }).subscribe({
      next: (updated) => {
        const list = this.logicSignals.get(signal.logic_id) ?? [];
        this.logicSignals.set(
          signal.logic_id,
          list.map((s) => (s.id === updated.id ? updated : s))
        );
        this.formulaDrafts.set(updated.id, updated.formula);
        this.savingFormulaIds.delete(signal.id);
      },
      error: () => {
        this.formulaDrafts.set(signal.id, signal.formula);
        this.savingFormulaIds.delete(signal.id);
      },
    });
  }

  deleteSignal(signal: LogicIndicatorSignalRow, event: Event): void {
    event.stopPropagation();
    this.logicsService.deleteLogicIndicatorSignal(signal.id).subscribe({
      next: () => {
        const list = (this.logicSignals.get(signal.logic_id) ?? []).filter(
          (s) => s.id !== signal.id
        );
        this.logicSignals.set(signal.logic_id, list);
        this.formulaDrafts.delete(signal.id);
      },
    });
  }

  openAdd(): void {
    this.editorMode = 'add';
    this.editorLogic = null;
    this.editorOpen = true;
  }

  openEdit(row: LogicRow, event: Event): void {
    event.stopPropagation();
    this.editorMode = 'edit';
    this.editorLogic = row;
    this.editorOpen = true;
  }

  closeEditor(): void {
    this.editorOpen = false;
    this.editorLogic = null;
  }

  onEditorSaved(): void {
    this.loadLogicsOnce();
  }

  deleteLogic(row: LogicRow, event: Event): void {
    event.stopPropagation();
    const ok = confirm(`Удалить логику «${row.name}»?`);
    if (!ok) return;
    this.logicsService.deleteLogic(row.id).subscribe({
      next: () => {
        this.logicSignals.delete(row.id);
        this.logicStops.delete(row.id);
        this.logicSecurities.delete(row.id);
        this.logicTrades.delete(row.id);
        this.expandedLogics.delete(row.id);
        this.expandedSecuritiesBlocks.delete(row.id);
        this.expandedTradesBlocks.delete(row.id);
        this.loadLogicsOnce();
      },
      error: (err) => {
        alert(err?.error?.error || 'Не удалось удалить логику');
      },
    });
  }

  onEnabledChange(row: LogicRow, checked: boolean, event: Event): void {
    event.stopPropagation();
    if (this.savingIds.has(row.id)) return;

    if (checked && row.account_type === 'fake') {
      this.settings.getTbankTokenStatus(true).subscribe({
        next: (status) => {
          if (!status.has_token || !status.valid) {
            this.pendingEnableLogic = row;
            this.tbankTokenDialogContext = 'logic';
            this.tbankTokenDialogReason = status.has_token ? 'invalid' : 'missing';
            this.tbankTokenDialogOpen = true;
            return;
          }
          this.applyEnabledChange(row, checked);
        },
        error: () => this.applyEnabledChange(row, checked),
      });
      return;
    }

    this.applyEnabledChange(row, checked);
  }

  onTbankTokenSavedForLogic(): void {
    this.tbankTokenDialogOpen = false;
    this.lastTbankTokenCheckAt = Date.now();
    const row = this.pendingEnableLogic;
    const pendingBt = this.pendingBacktest;
    this.pendingEnableLogic = null;
    this.pendingBacktest = null;
    this.settings.getTbankTokenStatus(true).subscribe({
      next: (status) => {
        this.applyTbankTokenStatus(status);
        if (row && status.valid) {
          this.applyEnabledChange(row, true);
        }
        if (pendingBt && status.valid) {
          this.doStartBacktestRun(pendingBt.logicId, pendingBt.period);
        }
      },
      error: () => {},
    });
  }

  onTbankTokenCancelledForLogic(): void {
    this.tbankTokenDialogOpen = false;
    this.pendingEnableLogic = null;
    this.pendingBacktest = null;
  }

  openTbankTokenDialogFromAlert(event?: Event): void {
    event?.preventDefault();
    event?.stopPropagation();
    if (this.tbankTokenDialogOpen) return;
    const alert = this.tbankTokenAlert;
    this.tbankTokenDialogContext = 'trades';
    this.tbankTokenDialogReason = alert?.reason ?? 'missing';
    this.tbankTokenDialogOpen = true;
  }

  tbankTokenAlertShortLabel(): string {
    if (!this.tbankTokenAlert) return '';
    return this.tbankTokenAlert.reason === 'invalid'
      ? 'Токен T-Bank неактивен'
      : 'Токен T-Bank не задан';
  }

  private hasEnabledLogic(): boolean {
    return this.logics.some((l) => l.is_enabled);
  }

  private applyTbankTokenStatus(status: {
    has_token: boolean;
    valid?: boolean;
    error_message?: string | null;
  }): void {
    if (!this.hasEnabledLogic() || status.valid) {
      this.tbankTokenAlert = null;
      return;
    }
    const reason: 'missing' | 'invalid' = status.has_token ? 'invalid' : 'missing';
    this.tbankTokenAlert = {
      reason,
      message:
        status.error_message?.trim() ||
        (reason === 'invalid'
          ? 'Токен T-Bank неактивен или просрочен. Нажмите, чтобы ввести новый API-токен.'
          : 'Токен T-Bank не задан. Нажмите, чтобы ввести API-токен для котировок и сделок.'),
    };
  }

  /** Проверка токена для runner: баннер + диалог только по клику. */
  private maybeCheckTbankTokenForTrades(): void {
    if (!this.hasEnabledLogic()) {
      this.tbankTokenAlert = null;
      return;
    }

    const now = Date.now();
    if (now - this.lastTbankTokenCheckAt < this.tbankTokenCheckMs) return;
    this.lastTbankTokenCheckAt = now;

    this.settings.getTbankTokenStatus(true).subscribe({
      next: (status) => this.applyTbankTokenStatus(status),
      error: () => {},
    });
  }

  private applyEnabledChange(row: LogicRow, checked: boolean): void {
    const previous = row.is_enabled;
    row.is_enabled = checked;
    this.savingIds.add(row.id);
    this.logicsService.updateLogicEnabled(row.id, checked).subscribe({
      next: () => {
        this.savingIds.delete(row.id);
        this.techLog.event(
          this.techLog.logicThreadKey(row.id, 'control'),
          checked ? 'logic.enabled' : 'logic.disabled',
          checked ? 'Логика включена (UI)' : 'Логика выключена (UI)',
          { logicId: row.id, payload: { is_enabled: checked } }
        );
        if (checked) {
          this.lastTbankTokenCheckAt = 0;
          this.maybeCheckTbankTokenForTrades();
        } else if (!this.hasEnabledLogic()) {
          this.tbankTokenAlert = null;
        }
      },
      error: () => {
        row.is_enabled = previous;
        this.savingIds.delete(row.id);
      },
    });
  }

  isSaving(row: LogicRow): boolean {
    return this.savingIds.has(row.id);
  }

  isFormulaSaving(signalId: number): boolean {
    return this.savingFormulaIds.has(signalId);
  }

  accountTypeLabel(type: string): string {
    return type === 'fake' ? 'фейковый' : 'реальный';
  }

  private loadIndicatorsCatalog(): void {
    this.refs.getIndicators(false).subscribe({
      next: (rows) => {
        this.indicatorsCatalog = rows.filter((r) => r.is_active);
        this.indicatorsLoaded = true;
      },
      error: () => {
        this.indicatorsLoaded = true;
      },
    });
  }

  private loadStopsForLogic(logicId: number): void {
    if (this.stopsLoading.has(logicId)) return;
    this.stopsLoading.add(logicId);
    this.logicsService.getLogicStops(logicId).subscribe({
      next: (rows) => {
        this.logicStops.set(logicId, rows);
        this.stopsLoading.delete(logicId);
      },
      error: () => {
        this.stopsLoading.delete(logicId);
      },
    });
  }

  private loadSignalsForLogic(logicId: number): void {
    if (this.signalsLoading.has(logicId)) return;
    this.signalsLoading.add(logicId);
    this.logicsService.getLogicIndicatorSignals(logicId).subscribe({
      next: (rows) => {
        this.logicSignals.set(logicId, rows);
        for (const r of rows) {
          if (!this.isFormulaDraftDirty(r.id, r.formula)) {
            this.formulaDrafts.set(r.id, r.formula);
          }
        }
        this.signalsLoading.delete(logicId);
      },
      error: () => {
        this.signalsLoading.delete(logicId);
      },
    });
  }

  private loadSecuritiesForLogic(logicId: number): void {
    if (this.securitiesLoading.has(logicId)) return;
    this.securitiesLoading.add(logicId);
    this.logicsService.getLogicSecurities(logicId).subscribe({
      next: (rows) => {
        this.logicSecurities.set(logicId, rows);
        this.securitiesLoading.delete(logicId);
      },
      error: () => {
        this.securitiesLoading.delete(logicId);
      },
    });
  }

  startBacktestRun(logicId: number, period: { date_from: string; date_to: string }): void {
    this.settings.getTbankTokenStatus(true).subscribe({
      next: (status) => {
        if (!status.has_token || !status.valid) {
          this.pendingBacktest = { logicId, period };
          this.tbankTokenDialogContext = 'logic';
          this.tbankTokenDialogReason = status.has_token ? 'invalid' : 'missing';
          this.tbankTokenDialogOpen = true;
          return;
        }
        this.doStartBacktestRun(logicId, period);
      },
      error: () => this.doStartBacktestRun(logicId, period),
    });
  }

  private doStartBacktestRun(logicId: number, period: { date_from: string; date_to: string }): void {
    this.logicsService
      .startBacktest({ logic_id: logicId, date_from: period.date_from, date_to: period.date_to })
      .subscribe({
        next: () => {
          this.backtestPollIds.add(logicId);
          this.expandedTestTradesBlocks.add(logicId);
          this.refreshBacktestStatus(logicId);
        },
        error: (err) => alert(err?.error?.error || 'Не удалось запустить тест'),
      });
  }

  cancelBacktestRun(logicId: number): void {
    const run = this.backtestRuns.get(logicId);
    if (!run?.id) return;
    this.logicsService.cancelBacktest(run.id).subscribe({
      next: () => this.refreshBacktestStatus(logicId),
      error: (err) => alert(err?.error?.error || 'Не удалось остановить тест'),
    });
  }

  private refreshBacktestStatus(logicId: number): void {
    this.logicsService.getBacktestStatus(logicId).subscribe({
      next: (row) => {
        if (row) {
          this.backtestRuns.set(logicId, row);
          const st = String(row.status ?? '');
          if (['pending', 'loading_prices', 'loading_indicators', 'running'].includes(st)) {
            this.backtestPollIds.add(logicId);
          } else {
            this.backtestPollIds.delete(logicId);
            this.loadTestTradesForLogic(logicId, true);
          }
        } else {
          this.backtestRuns.delete(logicId);
          this.backtestPollIds.delete(logicId);
        }
      },
    });
  }

  private loadTradesForLogic(logicId: number, silent = false): void {
    if (!silent && this.tradesLoading.has(logicId)) return;
    if (!silent) {
      this.tradesLoading.add(logicId);
    }
    this.logicsService.getLogicTrades(logicId, 200, false).subscribe({
      next: (rows) => {
        this.logicTrades.set(logicId, rows);
        this.tradesLoading.delete(logicId);
      },
      error: () => {
        this.tradesLoading.delete(logicId);
      },
    });
    this.loadTestTradesForLogic(logicId, true);
  }

  private loadTestTradesForLogic(logicId: number, _silent = false): void {
    this.logicsService.getLogicTrades(logicId, 200, true).subscribe({
      next: (rows) => {
        this.logicTradesTest.set(logicId, rows);
      },
    });
  }

  private refreshAllTradesSummaries(): void {
    for (const row of this.logics) {
      this.loadTradesForLogic(row.id, true);
    }
    for (const logicId of this.backtestPollIds) {
      this.refreshBacktestStatus(logicId);
    }
  }

  private loadMoexExchangeId(): void {
    this.refs.getExchanges().subscribe({
      next: (rows) => {
        const moex =
          rows.find((e) => e.name === 'MOEX') ?? rows[0];
        this.moexExchangeId = moex?.id ?? null;
      },
    });
  }

  private ensureSecuritiesCatalogLoaded(): void {
    if (this.securitiesCatalogLoaded || this.securitiesCatalogLoading) {
      return;
    }
    if (!this.moexExchangeId) {
      this.refs.getExchanges().subscribe({
        next: (rows) => {
          const moex =
            rows.find((e) => e.name === 'MOEX') ?? rows[0];
          this.moexExchangeId = moex?.id ?? null;
          if (this.moexExchangeId) {
            this.fetchSecuritiesCatalog(this.moexExchangeId);
          } else {
            this.securitiesCatalogLoaded = true;
          }
        },
        error: () => {
          this.securitiesCatalogLoaded = true;
        },
      });
      return;
    }
    this.fetchSecuritiesCatalog(this.moexExchangeId);
  }

  private fetchSecuritiesCatalog(exchangeId: number): void {
    this.securitiesCatalogLoading = true;
    forkJoin({
      stocks: this.securitiesService.getSecurities(exchangeId, 'stock'),
      futures: this.securitiesService.getSecurities(exchangeId, 'futures'),
    }).subscribe({
      next: ({ stocks, futures }) => {
        this.stocksCatalog = stocks;
        this.futuresCatalog = futures;
        this.securitiesCatalogLoaded = true;
        this.securitiesCatalogLoading = false;
      },
      error: () => {
        this.securitiesCatalogLoaded = true;
        this.securitiesCatalogLoading = false;
      },
    });
  }

  private isFormulaDraftDirty(signalId: number, savedFormula: string): boolean {
    const draft = this.formulaDrafts.get(signalId);
    return draft !== undefined && draft !== savedFormula;
  }

  private loadLogicsOnce(): void {
    this.logicsService.getLogics().subscribe({
      next: (rows) => {
        this.logics = rows;
        this.error = null;
      },
    });
  }
}
