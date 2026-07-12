import { Component, OnDestroy, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { Subject, switchMap, takeUntil, timer } from 'rxjs';
import { LogicsService } from '../services/logics.service';
import { ReferencesService } from '../services/references.service';
import { LogicIndicatorSignalRow, LogicRow } from '../models/logic.model';
import { IndicatorRow } from '../models/lookup.model';
import {
  AppConfigService,
  logicsLoadErrorMessage,
} from '../services/app-config.service';
import {
  LogicEditorComponent,
  LogicEditorMode,
} from '../logic-editor/logic-editor.component';
import {
  buildLogicSignalFormula,
  parseSignalFormula,
  signalKindLabel,
  SignalKind,
} from '../shared/signal-formula';

const POLL_INTERVAL_MS = 2000;

type SignalPickerState = {
  logicId: number;
  kind: SignalKind;
} | null;

@Component({
  selector: 'app-logics',
  standalone: true,
  imports: [CommonModule, FormsModule, LogicEditorComponent],
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
  expandedSignalsBlocks = new Set<number>();
  logicSignals = new Map<number, LogicIndicatorSignalRow[]>();
  signalsLoading = new Set<number>();

  indicatorsCatalog: IndicatorRow[] = [];
  indicatorsLoaded = false;

  signalPicker: SignalPickerState = null;
  pickerSelectedIds = new Set<number>();

  private readonly destroy$ = new Subject<void>();
  private savingIds = new Set<number>();
  private formulaDrafts = new Map<number, string>();
  private savingFormulaIds = new Set<number>();

  constructor(
    private readonly logicsService: LogicsService,
    private readonly refs: ReferencesService,
    private readonly appConfig: AppConfigService
  ) {}

  ngOnInit(): void {
    this.loadIndicatorsCatalog();
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
            return row;
          });
          this.loading = false;
          this.error = null;
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

  isLogicExpanded(id: number): boolean {
    return this.expandedLogics.has(id);
  }

  isSignalsBlockExpanded(id: number): boolean {
    return this.expandedSignalsBlocks.has(id);
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
      this.expandedSignalsBlocks.delete(row.id);
      this.closeSignalPicker();
      return;
    }
    this.expandedLogics.add(row.id);
    this.expandedSignalsBlocks.add(row.id);
    this.loadSignalsForLogic(row.id);
  }

  toggleSignalsBlock(logicId: number, event: Event): void {
    event.stopPropagation();
    if (this.expandedSignalsBlocks.has(logicId)) {
      this.expandedSignalsBlocks.delete(logicId);
      this.closeSignalPicker();
    } else {
      this.expandedSignalsBlocks.add(logicId);
      this.loadSignalsForLogic(logicId);
    }
  }

  signalsFor(logicId: number): LogicIndicatorSignalRow[] {
    return this.logicSignals.get(logicId) ?? [];
  }

  isSignalsLoading(logicId: number): boolean {
    return this.signalsLoading.has(logicId);
  }

  openSignalPicker(logicId: number, kind: SignalKind, event: Event): void {
    event.stopPropagation();
    this.signalPicker = { logicId, kind };
    this.pickerSelectedIds.clear();
    if (!this.expandedLogics.has(logicId)) {
      this.expandedLogics.add(logicId);
    }
    this.expandedSignalsBlocks.add(logicId);
    this.loadSignalsForLogic(logicId);
  }

  closeSignalPicker(): void {
    this.signalPicker = null;
    this.pickerSelectedIds.clear();
  }

  isPickerOpen(logicId: number, kind: SignalKind): boolean {
    return (
      this.signalPicker?.logicId === logicId && this.signalPicker.kind === kind
    );
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
    const { logicId, kind } = this.signalPicker;
    const existing = new Set(
      this.signalsFor(logicId)
        .filter((s) => s.signal_kind === kind)
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
      const formula = buildLogicSignalFormula(ind, kind);
      this.logicsService
        .createLogicIndicatorSignal({
          logic_id: logicId,
          indicator_id: indicatorId,
          signal_kind: kind,
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
        this.expandedLogics.delete(row.id);
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

  private loadLogicsOnce(): void {
    this.logicsService.getLogics().subscribe({
      next: (rows) => {
        this.logics = rows;
        this.error = null;
      },
    });
  }
}
