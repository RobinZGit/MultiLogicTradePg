import { Component, OnDestroy, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, switchMap, takeUntil, timer } from 'rxjs';
import { forkJoin } from 'rxjs';
import { LogicsService } from '../services/logics.service';
import { ReferencesService } from '../services/references.service';
import { SecuritiesService } from '../services/securities.service';
import { SettingsService } from '../services/settings.service';
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
  positionSideLabel,
  PositionSide,
  signalKindLabel,
  SignalKind,
} from '../shared/signal-formula';
import {
  LOGIC_STOP_SCOPES,
  LOGIC_STOP_UNITS,
  LogicStopRuleKind,
  LogicStopScopeType,
  LogicStopValueUnit,
  ruleKindLabel,
  scopeTypeLabel,
  valueUnitLabel,
} from '../shared/logic-stop';
import {
  tradeStatusLabel,
  yesNoLabel,
  LogicTradeRow,
} from '../shared/logic-trade';

const POLL_INTERVAL_MS = 2000;

type SignalPickerState = {
  logicId: number;
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
  imports: [CommonModule, FormsModule, LogicEditorComponent, TbankTokenDialogComponent],
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
  logicSignals = new Map<number, LogicIndicatorSignalRow[]>();
  logicStops = new Map<number, LogicStopRow[]>();
  logicSecurities = new Map<number, LogicSecurityRow[]>();
  logicTrades = new Map<number, LogicTradeRow[]>();
  signalsLoading = new Set<number>();
  stopsLoading = new Set<number>();
  securitiesLoading = new Set<number>();
  tradesLoading = new Set<number>();

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

  readonly stopScopes = LOGIC_STOP_SCOPES;
  readonly stopUnits = LOGIC_STOP_UNITS;

  tbankTokenDialogOpen = false;
  private pendingEnableLogic: LogicRow | null = null;

  private readonly destroy$ = new Subject<void>();
  private savingIds = new Set<number>();
  private formulaDrafts = new Map<number, string>();
  private savingFormulaIds = new Set<number>();
  private savingStopIds = new Set<number>();
  private savingParamsIds = new Set<number>();
  paramsDrafts = new Map<
    number,
    {
      position_size_pct: string;
      max_open_positions: string;
      initial_balance: string;
      reset_balance: boolean;
    }
  >();
  paramsSaveErrors = new Map<number, string>();

  constructor(
    private readonly logicsService: LogicsService,
    private readonly refs: ReferencesService,
    private readonly securitiesService: SecuritiesService,
    private readonly settings: SettingsService,
    private readonly appConfig: AppConfigService
  ) {}

  ngOnInit(): void {
    this.loadIndicatorsCatalog();
    this.loadMoexExchangeId();
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
            if (this.savingParamsIds.has(row.id)) {
              const local = this.logics.find((x) => x.id === row.id);
              return local
                ? {
                    ...row,
                    position_size_pct: local.position_size_pct,
                    max_open_positions: local.max_open_positions,
                    initial_balance: local.initial_balance,
                    current_balance: local.current_balance,
                  }
                : row;
            }
            return row;
          });
          this.syncParamsDraftsFromLogics();
          this.loading = false;
          this.error = null;
          this.refreshExpandedTrades();
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
      this.expandedSignalsBlocks.delete(row.id);
      this.expandedStopsBlocks.delete(row.id);
      this.expandedSecuritiesBlocks.delete(row.id);
      this.expandedTradesBlocks.delete(row.id);
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

  onParamsPctChange(logicId: number, value: string): void {
    this.getParamsDraft(logicId).position_size_pct = value;
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsMaxPositionsChange(logicId: number, value: string): void {
    this.getParamsDraft(logicId).max_open_positions = value;
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsInitialBalanceChange(logicId: number, value: string): void {
    this.getParamsDraft(logicId).initial_balance = value;
    this.paramsSaveErrors.delete(logicId);
  }

  onParamsResetBalanceChange(logicId: number, value: boolean): void {
    this.getParamsDraft(logicId).reset_balance = value;
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

  private syncParamsDraftsFromLogics(): void {
    for (const logicId of this.expandedParamsBlocks) {
      if (this.savingParamsIds.has(logicId)) continue;
      this.ensureParamsDraft(logicId, true);
    }
  }

  private draftFromLogicRow(row: LogicRow) {
    return {
      position_size_pct: this.formatPctParam(row.position_size_pct),
      max_open_positions: this.formatIntParam(row.max_open_positions, 5),
      initial_balance: this.formatBalanceDraft(row.initial_balance),
      reset_balance: false,
    };
  }

  toggleParamsBlock(logicId: number, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedParamsBlocks.has(logicId)) {
      this.expandedParamsBlocks.delete(logicId);
    } else {
      this.expandedParamsBlocks.add(logicId);
      this.ensureParamsDraft(logicId);
    }
  }

  ensureParamsDraft(logicId: number, force = false): void {
    if (!force && this.paramsDrafts.has(logicId)) return;
    const row = this.logics.find((l) => l.id === logicId);
    if (!row) return;
    this.paramsDrafts.set(logicId, this.draftFromLogicRow(row));
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

    this.paramsSaveErrors.delete(row.id);
    this.savingParamsIds.add(row.id);
    this.logicsService
      .updateLogicTradingParams(row.id, {
        position_size_pct,
        max_open_positions,
        initial_balance,
        reset_balance: draft.reset_balance,
      })
      .subscribe({
        next: (updated) => {
          const idx = this.logics.findIndex((l) => l.id === row.id);
          const merged =
            idx >= 0 ? { ...this.logics[idx], ...updated } : { ...row, ...updated };
          if (idx >= 0) {
            this.logics[idx] = merged;
          }
          this.paramsDrafts.set(row.id, this.draftFromLogicRow(merged));
          this.savingParamsIds.delete(row.id);
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

  toggleTradesBlock(logicId: number, event: Event): void {
    event.preventDefault();
    event.stopPropagation();
    if (this.expandedTradesBlocks.has(logicId)) {
      this.expandedTradesBlocks.delete(logicId);
    } else {
      this.expandedTradesBlocks.add(logicId);
      this.loadTradesForLogic(logicId);
    }
  }

  tradesFor(logicId: number): LogicTradeRow[] {
    return this.logicTrades.get(logicId) ?? [];
  }

  isTradesLoading(logicId: number): boolean {
    return this.tradesLoading.has(logicId);
  }

  tradeActionLabel(trade: LogicTradeRow): string {
    return `${trade.side_name} ${trade.action_name}`;
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

  openSignalPicker(logicId: number, positionSide: PositionSide, event: Event): void {
    event.stopPropagation();
    this.signalPicker = {
      logicId,
      positionSide,
      signalKind: positionSide === 'long' ? 'trend' : 'counter',
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
    const { logicId, positionSide, signalKind } = this.signalPicker;
    const existing = new Set(
      this.signalsFor(logicId)
        .filter(
          (s) => s.position_side === positionSide && s.signal_kind === signalKind
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
      this.settings.getTbankTokenStatus().subscribe({
        next: ({ has_token }) => {
          if (!has_token) {
            this.pendingEnableLogic = row;
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
    const row = this.pendingEnableLogic;
    this.pendingEnableLogic = null;
    if (row) {
      this.applyEnabledChange(row, true);
    }
  }

  onTbankTokenCancelledForLogic(): void {
    this.tbankTokenDialogOpen = false;
    this.pendingEnableLogic = null;
  }

  private applyEnabledChange(row: LogicRow, checked: boolean): void {
    const previous = row.is_enabled;
    row.is_enabled = checked;
    this.savingIds.add(row.id);
    this.logicsService.updateLogicEnabled(row.id, checked).subscribe({
      next: () => this.savingIds.delete(row.id),
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
          this.formulaDrafts.set(r.id, r.formula);
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

  private loadTradesForLogic(logicId: number, silent = false): void {
    if (!silent && this.tradesLoading.has(logicId)) return;
    if (!silent) {
      this.tradesLoading.add(logicId);
    }
    this.logicsService.getLogicTrades(logicId).subscribe({
      next: (rows) => {
        this.logicTrades.set(logicId, rows);
        this.tradesLoading.delete(logicId);
      },
      error: () => {
        this.tradesLoading.delete(logicId);
      },
    });
  }

  private refreshExpandedTrades(): void {
    for (const logicId of this.expandedTradesBlocks) {
      this.loadTradesForLogic(logicId, true);
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

  private loadLogicsOnce(): void {
    this.logicsService.getLogics().subscribe({
      next: (rows) => {
        this.logics = rows;
        this.error = null;
      },
    });
  }
}
