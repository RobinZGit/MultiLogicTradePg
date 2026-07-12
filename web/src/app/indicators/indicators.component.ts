import { Component, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { ReferencesService } from '../services/references.service';
import { IndicatorRow } from '../models/lookup.model';
import {
  AppConfigService,
  logicsLoadErrorMessage,
} from '../services/app-config.service';
import { IndicatorEditorComponent } from '../indicator-editor/indicator-editor.component';

@Component({
  selector: 'app-indicators',
  standalone: true,
  imports: [CommonModule, IndicatorEditorComponent],
  templateUrl: './indicators.component.html',
  styleUrl: './indicators.component.css',
})
export class IndicatorsComponent implements OnInit {
  indicators: IndicatorRow[] = [];
  loading = true;
  error: string | null = null;

  editorOpen = false;
  editTarget: IndicatorRow | null = null;

  constructor(
    private readonly refs: ReferencesService,
    private readonly appConfig: AppConfigService
  ) {}

  ngOnInit(): void {
    this.load();
  }

  load(): void {
    this.loading = true;
    this.refs.getIndicators(true).subscribe({
      next: (rows) => {
        this.indicators = rows;
        this.loading = false;
        this.error = null;
      },
      error: (err) => {
        this.loading = false;
        this.error = logicsLoadErrorMessage(this.appConfig.apiUrl, err);
      },
    });
  }

  openEdit(row: IndicatorRow): void {
    this.editTarget = row;
    this.editorOpen = true;
  }

  yesNo(value: boolean): string {
    return value ? 'да' : 'нет';
  }

  seriesSummary(row: IndicatorRow): string {
    const types = row.value_types ?? [];
    if (types.length === 0) return '—';
    return types.map((t) => t.code).join(', ');
  }

  scriptPreview(script: string | null): string {
    if (!script) return '—';
    return script.length > 80 ? script.slice(0, 77) + '…' : script;
  }

  descriptionPreview(description: string | null): string {
    if (!description) return '—';
    const oneLine = description.replace(/\s+/g, ' ').trim();
    return oneLine.length > 120 ? oneLine.slice(0, 117) + '…' : oneLine;
  }
}
