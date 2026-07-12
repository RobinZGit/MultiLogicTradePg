import { Component, OnDestroy, OnInit } from '@angular/core';

import { CommonModule } from '@angular/common';

import { Subject, switchMap, takeUntil, timer } from 'rxjs';

import { LogicsService } from '../services/logics.service';

import { LogicRow } from '../models/logic.model';

import {

  AppConfigService,

  logicsLoadErrorMessage,

} from '../services/app-config.service';

import {

  LogicEditorComponent,

  LogicEditorMode,

} from '../logic-editor/logic-editor.component';



/** Интервал автообновления списка (мс). 2 с — типичный период для live-таблиц. */

const POLL_INTERVAL_MS = 2000;



@Component({

  selector: 'app-logics',

  standalone: true,

  imports: [CommonModule, LogicEditorComponent],

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



  private readonly destroy$ = new Subject<void>();

  private savingIds = new Set<number>();

  constructor(

    private readonly logicsService: LogicsService,

    private readonly appConfig: AppConfigService

  ) {}



  ngOnInit(): void {

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



  openAdd(): void {

    this.editorMode = 'add';

    this.editorLogic = null;

    this.editorOpen = true;

  }



  openEdit(row: LogicRow): void {

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



  deleteLogic(row: LogicRow): void {

    const ok = confirm(`Удалить логику «${row.name}»?`);

    if (!ok) {

      return;

    }

    this.logicsService.deleteLogic(row.id).subscribe({

      next: () => this.loadLogicsOnce(),

      error: (err) => {

        alert(err?.error?.error || 'Не удалось удалить логику');

      },

    });

  }



  onEnabledChange(row: LogicRow, checked: boolean): void {

    if (this.savingIds.has(row.id)) {

      return;

    }

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



  accountTypeLabel(type: string): string {

    return type === 'fake' ? 'фейковый' : 'реальный';

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


