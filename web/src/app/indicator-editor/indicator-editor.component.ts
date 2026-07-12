import {
  Component,
  EventEmitter,
  Input,
  OnChanges,
  Output,
  SimpleChanges,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ReferencesService } from '../services/references.service';
import { AppConfigService, apiErrorMessage } from '../services/app-config.service';
import { IndicatorPayload, IndicatorRow } from '../models/lookup.model';

@Component({
  selector: 'app-indicator-editor',
  standalone: true,
  imports: [CommonModule, FormsModule],
  templateUrl: './indicator-editor.component.html',
  styleUrls: ['../shared/dialog-form.css', './indicator-editor.component.css'],
})
export class IndicatorEditorComponent implements OnChanges {
  @Input() open = false;
  @Input() indicator: IndicatorRow | null = null;

  @Output() closed = new EventEmitter<void>();
  @Output() saved = new EventEmitter<void>();

  code = '';
  name = '';
  description = '';
  category = '';
  script = '';
  isActive = true;
  seriesSummary = '';
  saving = false;
  error: string | null = null;

  constructor(
    private readonly refs: ReferencesService,
    private readonly appConfig: AppConfigService
  ) {}

  ngOnChanges(changes: SimpleChanges): void {
    if (changes['open']?.currentValue === true) {
      this.initForm();
    }
  }

  get title(): string {
    return this.indicator
      ? `Редактирование: ${this.indicator.code}`
      : 'Индикатор';
  }

  close(): void {
    if (!this.saving) this.closed.emit();
  }

  save(): void {
    this.error = null;
    const payload: IndicatorPayload = {
      name: this.name.trim(),
      description: this.description.trim() || null,
      category: this.category.trim() || null,
      script: this.script.trim() || null,
      is_active: this.isActive,
    };
    if (!payload.name) {
      this.error = 'Заполните название';
      return;
    }
    if (!this.indicator) {
      this.error = 'Индикатор не выбран';
      return;
    }
    this.saving = true;
    this.refs.updateIndicator(this.indicator.id, payload).subscribe({
      next: () => {
        this.saving = false;
        this.saved.emit();
        this.closed.emit();
      },
      error: (err) => {
        this.saving = false;
        this.error = apiErrorMessage(
          this.appConfig.apiUrl,
          err,
          'Не удалось сохранить индикатор'
        );
      },
    });
  }

  private initForm(): void {
    this.error = null;
    this.saving = false;
    if (this.indicator) {
      this.code = this.indicator.code;
      this.name = this.indicator.name;
      this.description = this.indicator.description || '';
      this.category = this.indicator.category || '';
      this.script = this.indicator.script || '';
      this.isActive = this.indicator.is_active;
      const types = this.indicator.value_types ?? [];
      this.seriesSummary = types.map((t) => t.code).join(', ');
    } else {
      this.code = '';
      this.name = '';
      this.description = '';
      this.category = '';
      this.script = '';
      this.isActive = true;
      this.seriesSummary = '';
    }
  }
}
